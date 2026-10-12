// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {CLBaseHook} from "src/pool-cl/CLBaseHook.sol";
import {FullMath} from "infinity-core/src/pool-cl/libraries/FullMath.sol";
import {FixedPoint96} from "infinity-core/src/pool-cl/libraries/FixedPoint96.sol";
import {LPFeeLibrary} from "infinity-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {PoolId, PoolIdLibrary} from "infinity-core/src/types/PoolId.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "infinity-core/src/types/BalanceDelta.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "infinity-core/src/types/BeforeSwapDelta.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {CLPoolManager} from "infinity-core/src/pool-cl/CLPoolManager.sol";
import {
    SD59x18, uUNIT, UNIT, convert, inv, exp, lt, gt, uEXP_MIN_THRESHOLD, EXP_MAX_INPUT
} from "prb-math/SD59x18.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";

/**
 * CLDynamicFeeHook use ewVWAP to determine whether will charge the dynamic fee
 * weighted_volume = alpha * volume_token0_amount + (1 - alpha) * previous_weighted_volume
 * weighted_price_volume = alpha * volume_token0_amount * price + (1 - alpha) * previous_weighted_price_volume
 * ewVWAP = weighted_price_volume / weighted_volume
 * if infinity pool price move in the same direction as ewVWAP, we will not charge dynamic fee
 * if infinity pool price move in the opposite direction as ewVWAP, we will charge dynamic fee
 */
contract CLDynamicFeeHook is CLBaseHook, Ownable {
    using PoolIdLibrary for PoolKey;
    using LPFeeLibrary for uint24;

    // maxDynamicFee would be DFF_max * PIF_MAX. eg. if PIF_MAX is 200_000(0.2) and DFF_MAX is 100_000(0.1), it means max dynamicFee is 20_000(0.02) (2%)
    struct PoolConfig {
        uint24 alpha; // weight allocated to latest data point , 500_000 means 0.5
        uint24 DFF_max; // 250_000 means 0.25
        uint24 baseLpFee; // 3_000 means 0.3%
    }

    struct EWVWAPParams {
        // exponentially weighted sum of each volume data point
        uint256 weightedVolume;
        // exponentially weighted sum of each (price x volume) data point
        uint256 weightedPriceVolume;
        // Exponentially Weighted VWAP (Volume weighted average price)
        // ewVWAP = weighted_price_volume / weighted_volume
        // ewVWAPX = ewVWAP * (Q96 * Q96 / PRICE_PRECISION)
        // ewVWAPX =  ewVWAP * VWAPX_A
        uint256 ewVWAPX;
    }

    // ============================== Variables ================================

    // CL tick range is between -887272 and 887272
    // sqrtPriceX96[-887272] is 4295128739
    // sqrtPriceX96[887272] is 1461446703485210103287273052203988822378723970342
    // So use sqrtPriceX96[-887272] * sqrtPriceX96[-887272] as precision
    // PRICE_PRECISION = sqrtPriceX96[-887272] * sqrtPriceX96[-887272] = 18448130884583730000
    // priceX = sqrtPriceX96 * sqrtPriceX96 / PRICE_PRECISION
    // priceX[-887272] = sqrtPriceX96[-887272] * sqrtPriceX96[-887272] / PRICE_PRECISION = 1
    // priceX[887272] = sqrtPriceX96[887272] * sqrtPriceX96[887272] / PRICE_PRECISION = 115774680941395604863474304587699109860222437082614414580284557381589562228688 , which is smaller than type(uint256).max
    // then we can check whole infinity pool price range using ewVWAPX
    uint256 public constant PRICE_PRECISION = 18448130884583730000;

    // infinity_pool_price = (sqrtPriceX96 / Q96) * (sqrtPriceX96 / Q96)
    // priceX = sqrtPriceX96 * sqrtPriceX96 / PRICE_PRECISION
    // priceX = infinity_pool_price * (Q96 * Q96 / PRICE_PRECISION)
    // ewVWAPX = ewVWAP * (Q96 * Q96 / PRICE_PRECISION)
    // VWAPX_A = Q96 * Q96 / PRICE_PRECISION
    // A menas amplification factor
    uint256 public constant VWAPX_A = 340256786698763678858396856460488307819;

    // MAX_PRICE = sqrtPriceX96[887272] * sqrtPriceX96[887272] / Q96^2
    uint256 public constant MAX_PRICE = 340256786836388094070642339899681172762;

    // MAX_EWVWAPX = MAX_PRICE * VWAPX_A
    uint256 public constant MAX_EWVWAPX = 115774680941395604863474304587699109859826404561446891284072445734786774426078;

    uint256 public constant ALPHA_100_PERCENT = 1_000_000;

    uint256 private constant MAX_U256 = type(uint256).max;

    uint256 private constant DEFAULT_OVERFLOW_FACTOR = 1;

    uint256 private constant OVERFLOW_FACTOR = 10 ** 10;

    // Q96_SQUARED = FixedPoint96.Q96 * FixedPoint96.Q96
    uint256 private constant Q96_SQUARED = 6277101735386680763835789423207666416102355444464034512896;

    // 0.2 * ONE_HUNDRED_PERCENT_FEE
    uint256 private constant PIF_MAX = 200_000;

    // will be set to true when emergency status
    // hooks will do nothing when this flag is true
    bool public emergencyFlag;

    PoolConfig public defaultPoolConfig;

    mapping(PoolId id => EWVWAPParams) public poolEWVWAPParams;

    mapping(PoolId id => PoolConfig) public poolConfigs;

    // ============================== Events ===================================
    event UpdateEmergencyFlag(bool flag);
    event UpdateDefaultPoolConfig(uint24 alpha, uint24 DFF_max, uint24 baseLpFee);
    event UpdatePoolConfig(PoolId indexed id, uint24 alpha, uint24 DFF_max, uint24 baseLpFee);

    // ============================== Errors ===================================

    error NotDynamicFeePool();
    error InvalidDFFMax();
    error InvalidBaseLpFee();
    error InvalidAlpha();
    error SwapAndRevert(uint160 sqrtPriceX96);
    error NotDynamicFeeHook();
    error PoolNotInitialized();
    error InvalidPoolConfig();

    // ============================== Modifiers ================================

    // ========================= External Functions ============================

    constructor(ICLPoolManager poolManager, PoolConfig memory config) Ownable(msg.sender) CLBaseHook(poolManager) {
        _checkPoolConfig(config);
        defaultPoolConfig = config;
    }

    /// @dev Update the default pool configuration
    /// @param config The new default pool configuration
    function updateDefaultPoolConfig(PoolConfig memory config) external onlyOwner {
        _checkPoolConfig(config);
        defaultPoolConfig = config;
        emit UpdateDefaultPoolConfig(config.alpha, config.DFF_max, config.baseLpFee);
    }

    /// @dev Set the emergency flag
    /// @param flag The emergency flag
    function setEmergencyFlag(bool flag) external onlyOwner {
        emergencyFlag = flag;
        emit UpdateEmergencyFlag(flag);
    }

    /// @notice Update dynamic fee configuration for a pool
    /// @dev Only owner can call this function
    /// @dev The pool must be a dynamic fee pool and the hook must be this contract
    /// @param key The pool key
    /// @param config The new pool configuration
    function updatePoolConfig(PoolKey calldata key, PoolConfig memory config) external onlyOwner {
        _checkPoolConfig(config);
        if (!key.fee.isDynamicLPFee() || key.hooks != IHooks(address(this))) {
            revert NotDynamicFeePool();
        }

        PoolId id = key.toId();
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(id);
        // sqrtPriceX96 != 0 indicate that pool is initialized, so update base lp fee
        if (sqrtPriceX96 != 0) {
            poolManager.updateDynamicLPFee(key, config.baseLpFee);
        }
        poolConfigs[id] = config;
        emit UpdatePoolConfig(id, config.alpha, config.DFF_max, config.baseLpFee);
    }

    function getHooksRegistrationBitmap() external pure override returns (uint16) {
        return _hooksRegistrationBitmapFrom(
            Permissions({
                beforeInitialize: false,
                afterInitialize: true,
                beforeAddLiquidity: false,
                afterAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterRemoveLiquidity: false,
                beforeSwap: true,
                afterSwap: true,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: false,
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            })
        );
    }

    /// @dev Initialize the dynamic fee pool
    function afterInitialize(address, PoolKey calldata key, uint160, int24)
        external
        override
        poolManagerOnly
        returns (bytes4)
    {
        if (!key.fee.isDynamicLPFee()) {
            revert NotDynamicFeePool();
        }

        PoolId id = key.toId();
        PoolConfig storage poolConfig = poolConfigs[id];
        // use default pool config when pool config is empty
        if (poolConfig.DFF_max == 0 || poolConfig.baseLpFee == 0 || poolConfig.alpha == 0) {
            PoolConfig memory defaultConfig = defaultPoolConfig;
            poolConfig.alpha = defaultConfig.alpha;
            poolConfig.DFF_max = defaultConfig.DFF_max;
            poolConfig.baseLpFee = defaultConfig.baseLpFee;
        }

        poolManager.updateDynamicLPFee(key, poolConfig.baseLpFee);

        return this.afterInitialize.selector;
    }

    /// @dev Do not need to check whether it is simulation swap.
    /// @dev msg.sender will be this contract address when it is simulation swap, pool will not call hook beforeSwap in swap function
    function beforeSwap(
        address,
        PoolKey calldata key,
        ICLPoolManager.SwapParams calldata params,
        bytes calldata hookData
    ) external override poolManagerOnly returns (bytes4, BeforeSwapDelta, uint24) {
        if (emergencyFlag) {
            return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        PoolId id = key.toId();

        EWVWAPParams memory latestEWVWAPParams = poolEWVWAPParams[id];
        uint256 latestEWVWAPX = latestEWVWAPParams.ewVWAPX;
        // if latestEWVWAPParams is empty , it means it is first swap , no dynamic fee
        if (latestEWVWAPParams.weightedVolume == 0 && latestEWVWAPParams.weightedPriceVolume == 0 && latestEWVWAPX == 0)
        {
            return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        (uint160 sqrtPriceX96Before,,,) = poolManager.getSlot0(id);
        // priceX = sqrtPriceX96 * sqrtPriceX96 / PRICE_PRECISION
        uint256 priceXBefore = FullMath.mulDiv(sqrtPriceX96Before, sqrtPriceX96Before, PRICE_PRECISION);

        // Only charge dynamic fee when price_after_swap and ewVWAP are not on the same side compared to price_before_swap
        // when zeroForOne is true, priceXAfter is smaller than priceXBefore, so we can skip the calculation when ewVWAPX is less than or equal to priceXBefore
        // when zeroForOne is false, priceXAfter is bigger than priceXBefore, so we can skip the calculation when ewVWAPX is greater than or equal to priceXBefore
        //  we can skip simualtion, will save some gas
        if (params.zeroForOne && latestEWVWAPX <= priceXBefore || !params.zeroForOne && latestEWVWAPX >= priceXBefore) {
            return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }
        // get the sqrt price after the swap by simulating the swap
        // NOTICE: The swap simulation uses the base LP fee, so the simulated price may differ from the actual swap price, which uses a dynamic fee.
        uint160 sqrtPriceX96After = _simulateSwap(key, params, hookData);
        PoolConfig memory poolConfig = poolConfigs[id];
        uint24 lpFee =
            _calculateDynamicFee(sqrtPriceX96Before, sqrtPriceX96After, poolConfig.baseLpFee, poolConfig.DFF_max);
        if (lpFee == 0) {
            return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, lpFee | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    function afterSwap(
        address,
        PoolKey calldata key,
        ICLPoolManager.SwapParams calldata,
        BalanceDelta delta,
        bytes calldata
    ) external override poolManagerOnly returns (bytes4, int128) {
        // alpha : weight allocated to latest data point
        // weighted_volume : exponentially weighted sum of each volume data point
        // weighted_volume = alpha * latest_volume_token0_amount + (1 - alpha) * previous_weighted_volume
        // weighted_price_volume : exponentially weighted sum of each (price x volume) data point
        // weighted_price_volume = alpha * latest_volume_token0_amount * price + (1 - alpha) * previous_weighted_price_volume
        // weighted_price_volume = alpha * latest_volume_token0_amount * sqrtPriceX96 * sqrtPriceX96 / (Q96 * Q96) + (1 - alpha) * previous_weighted_price_volume
        // ewVWAP = weighted_price_volume / weighted_volume
        // ewVWAP_X= weighted_price_volume * VWAPX_A / weighted_volume
        int128 delta0 = delta.amount0();
        // will skip when delta0 is 0
        if (delta0 == 0) {
            return (this.afterSwap.selector, 0);
        }
        uint256 volumeToken0Amount = delta0 < 0 ? uint256(uint128(-delta0)) : uint256(uint128(delta0));

        PoolId id = key.toId();
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(id);
        uint256 alpha = poolConfigs[id].alpha;

        EWVWAPParams storage latestEWVWAPParams = poolEWVWAPParams[id];
        // last weightedVolume calculation alpha factor
        uint256 lastWVAlpha = ALPHA_100_PERCENT - alpha;
        // TODO: check oveflow cases about weightedVolume and weightedPriceVolume
        // because max volumeToken0Amount is type(int128).max ,so weightedVolume will not be overflow
        // weightedVolume = alpha * volumeToken0Amount + (1 - alpha) * last_weightedVolume
        uint256 weightedVolume =
            (alpha * volumeToken0Amount + lastWVAlpha * latestEWVWAPParams.weightedVolume) / ALPHA_100_PERCENT;

        // will skip the calculation when weightedVolume is 0
        if (weightedVolume == 0) {
            return (this.afterSwap.selector, 0);
        }

        // max volumeToken0Amount is type(int128).max , max sqrtPriceX96 is sqrtPriceX96[887272]
        // volumeToken0Amount * sqrtPriceX96 will be overflow in some cases
        // so we will use overflowFactor to avoid overflow
        // Why not directly use OVERFLOW_FACTOR? When volumeToken0Amount and sqrtPriceX96 are very small, some precision might be lost.
        uint256 overflowFactorOne = DEFAULT_OVERFLOW_FACTOR;
        if (MAX_U256 / sqrtPriceX96 < volumeToken0Amount) {
            overflowFactorOne = OVERFLOW_FACTOR;
        }

        // weightedPriceVolume = alpha * volumeToken0Amount * infinity_price + (1 - alpha) * last_weightedPriceVolume
        // weightedPriceVolume = alpha * volumeToken0Amount * sqrtPriceX96 * sqrtPriceX96 / (Q96 * Q96) + (1 - alpha) * last_weightedPriceVolume
        // weightedPriceVolumeDelta = alpha * volumeToken0Amount * sqrtPriceX96 * sqrtPriceX96 / (Q96 * Q96)
        uint256 weightedPriceVolumeDelta = FullMath.mulDiv(
            FullMath.mulDiv(volumeToken0Amount, sqrtPriceX96, overflowFactorOne),
            alpha * sqrtPriceX96,
            Q96_SQUARED * ALPHA_100_PERCENT / overflowFactorOne
        );

        uint256 weightedPriceVolume = weightedPriceVolumeDelta
            + FullMath.mulDiv(lastWVAlpha, latestEWVWAPParams.weightedPriceVolume, ALPHA_100_PERCENT);

        // ewVWAPX = ewVWAP * (Q96 * Q96 / PRICE_PRECISION)
        // ewVWAPX =  ewVWAP * VWAPX_A
        // if weightedPriceVolume / weightedVolume is greater than MAX_PRICE, we will set ewVWAPX as MAX_EWVWAPX(MAX_PRICE * VWAPX_A)
        if (weightedPriceVolume / MAX_PRICE > weightedVolume) {
            latestEWVWAPParams.ewVWAPX = MAX_EWVWAPX;
        } else {
            latestEWVWAPParams.ewVWAPX = FullMath.mulDiv(weightedPriceVolume, VWAPX_A, weightedVolume);
        }

        latestEWVWAPParams.weightedVolume = weightedVolume;
        latestEWVWAPParams.weightedPriceVolume = weightedPriceVolume;
        return (this.afterSwap.selector, 0);
    }

    /// @dev Get the dynamic fee for a swap
    /// @param key The pool key
    /// @param sqrtPriceX96AfterSwap The sqrt price after the swap
    function getDynamicFee(PoolKey calldata key, uint160 sqrtPriceX96AfterSwap) external view returns (uint24) {
        if (emergencyFlag) {
            return 0;
        }
        PoolId id = key.toId();

        (uint160 sqrtPriceX96Before,,,) = poolManager.getSlot0(id);
        if (sqrtPriceX96Before == 0) {
            revert PoolNotInitialized();
        }

        PoolConfig memory poolConfig = poolConfigs[id];

        EWVWAPParams memory latestEWVWAPParams = poolEWVWAPParams[id];
        uint256 latestEWVWAPX = poolEWVWAPParams[id].ewVWAPX;
        // if latestEWVWAPParams is empty , it means it is first swap , no dynamic fee
        if (latestEWVWAPParams.weightedVolume == 0 && latestEWVWAPParams.weightedPriceVolume == 0 && latestEWVWAPX == 0)
        {
            return 0;
        }

        uint256 priceXBefore = FullMath.mulDiv(sqrtPriceX96Before, sqrtPriceX96Before, PRICE_PRECISION);
        uint256 priceXAfter = FullMath.mulDiv(sqrtPriceX96AfterSwap, sqrtPriceX96AfterSwap, PRICE_PRECISION);
        if (
            !(priceXAfter > priceXBefore && latestEWVWAPX <= priceXBefore)
                && !(priceXAfter < priceXBefore && latestEWVWAPX >= priceXAfter)
        ) {
            return 0;
        }
        return _calculateDynamicFee(sqrtPriceX96Before, sqrtPriceX96AfterSwap, poolConfig.baseLpFee, poolConfig.DFF_max);
    }

    /// @dev Revert a custom error on purpose to achieve simulation of `swap`
    function simulateSwap(PoolKey calldata key, ICLPoolManager.SwapParams calldata params, bytes calldata hookData)
        external
    {
        // Only this contract can call this function
        if (msg.sender != address(this)) {
            revert NotDynamicFeeHook();
        }
        poolManager.swap(key, params, hookData);
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(key.toId());
        revert SwapAndRevert(sqrtPriceX96);
    }

    // ========================= Internal Functions ============================

    /**
     * @notice Calculates the dynamic liquidity provider (LP) fee for a swap based on the price impact factor (PIF).
     * The function ensures that the fee increases with the price impact, but is capped at a maximum value. It applies an
     * exponential decay formula to gradually increase the fee as the price impact grows, protecting liquidity providers from
     * significant price shifts due to large swaps.
     * @param sqrtPriceX96Before The square root of the price before the swap, expressed as a fixed-point number with 96 bits of precision.
     * @param sqrtPriceX96After The square root of the price after the swap, expressed as a fixed-point number with 96 bits of precision.
     * @param baseLpFee The base liquidity provider fee, expressed in hundredths of basis points (bips), which will always be charged.
     * @param DFF_max The maximum dynamic fee factor, expressed in hundredths of bips, which limits how high the dynamic fee can rise.
     * @return lpFee The dynamically adjusted liquidity provider fee for the swap, expressed in hundredths of basis points (bips). The
     *               dynamic fee is added on top of the base LP fee if the calculated fee is greater than the base fee.
     */
    function _calculateDynamicFee(
        uint160 sqrtPriceX96Before,
        uint160 sqrtPriceX96After,
        uint24 baseLpFee,
        uint24 DFF_max
    ) internal pure returns (uint24) {
        /**
         * Dynamic Fee Formula:
         *         PriceImpactFactor(PIF) = ABS( (price_after - price_before) / price_before )
         *         will use real PIF number to calculate DFF
         *         DFF = max{DFF_max * (1 - e ^ -(PIF - baseLpFee) / baseLpFee ), 0}
         *         Dynamic_fee = DFF * min(PIF, 0.2)
         */
        uint24 DFF_uint24;
        /**
         * PriceImpactFactor(PIF) = SF * IP = ABS( (price_after - price_before) / price_before )
         *         PIF = (price_after - price_before) / price_before
         *         PIF = (sqrtPriceX96After^2 / Q96^2 - sqrtPriceX96Before^2 / Q96^2) / sqrtPriceX96Before^2 / Q96^2
         *         PIF = (sqrtPriceX96After^2 - sqrtPriceX96Before^2) / sqrtPriceX96Before^2
         *         PIF = (sqrtPriceX96After + sqrtPriceX96Before) * (sqrtPriceX96After - sqrtPriceX96Before) / sqrtPriceX96Before^2
         *         PIF_fee_decimals = (sqrtPriceX96After + sqrtPriceX96Before) * (sqrtPriceX96After - sqrtPriceX96Before) * ONE_HUNDRED_PERCENT_FEE / sqrtPriceX96Before^2
         *         PIF_fee_decimals = (sqrtPriceX96After + sqrtPriceX96Before) * ONE_HUNDRED_PERCENT_FEE / sqrtPriceX96Before *
         *                             (sqrtPriceX96After - sqrtPriceX96Before) / sqrtPriceX96Before
         */

        /**
         * PIF = ABS( (price_after - price_before) / price_before )
         *      PIF = ABS( (price_after/price_before - 1 )
         *      It means swap direction will affect PIF value.
         *      1. when zeroForOne is true, priceX96After is smaller than priceX96Before, so PIF is smaller than 1(ONE_HUNDRED_PERCENT_FEE)
         *      2. when zeroForOne is false, priceX96After is larger than priceX96Before
         *         2.1 when price_after/price_before < 2 , PIF is smaller than 1(ONE_HUNDRED_PERCENT_FEE)
         *         2.2 when price_after/price_before > 2 , PIF is bigger than 1(ONE_HUNDRED_PERCENT_FEE)
         */
        uint256 PIF;
        /**
         * When PIF is greater than 144, exponent:( (PIF - baseLpFee) / baseLpFee ) will be bigger than 143 , because baseLpFee is smaller than 1
         *         1- 1/e^143 is almost equal to 1, so DFF will be almost equal to DFF_max
         *         PIF = (sqrtPriceX96After / sqrtPriceX96Before)^ 2 - 1
         *         when sqrtPriceX96After / sqrtPriceX96Before > 12 , we will set DFF as DFF_max
         *
         *         Why check this ? because PIF_fee_decimals will be overlflow in some extreme cases when sqrtPriceX96After > sqrtPriceX96Before
         */
        if (sqrtPriceX96After / sqrtPriceX96Before >= 12) {
            DFF_uint24 = DFF_max;
            PIF = PIF_MAX;
        } else {
            // TODO: Need to check whether wil have some cases which will be overflow
            PIF = FullMath.mulDiv(
                sqrtPriceX96After + sqrtPriceX96Before, LPFeeLibrary.ONE_HUNDRED_PERCENT_FEE, sqrtPriceX96Before
            );
            uint256 sqrtPriceX96Diff;
            if (sqrtPriceX96After > sqrtPriceX96Before) {
                sqrtPriceX96Diff = sqrtPriceX96After - sqrtPriceX96Before;
            } else {
                sqrtPriceX96Diff = sqrtPriceX96Before - sqrtPriceX96After;
            }
            PIF = FullMath.mulDiv(PIF, sqrtPriceX96Diff, sqrtPriceX96Before);

            // DFF = max{DFF_max * (1 - e ^ -(PIF - baseLpFee) / baseLpFee ), 0} = max{DFF_max * (1 - 1/ e ^ (PIF - baseLpFee) / baseLpFee ), 0}
            // So only PIF is greater than baseLpFee, we will charge the dynamic fee
            if (PIF <= baseLpFee) {
                return 0;
            }
        }

        if (DFF_uint24 == 0) {
            SD59x18 DFF;
            // convert(int256 x) : Converts a simple integer to SD59x18 by multiplying it by `UNIT(1e18)`.
            // SD59x18 x =  SD59x18.wrap(x_int256 * uUNIT)
            SD59x18 DFF_MAX = convert(int256(int24(DFF_max)));

            // inv(SD59x18 x) : 1/x, Calculates the inverse of x.
            // exp(SD59x18 x) : e^x, Calculates the natural exponent of x.
            // exponent_uint256 = (PIF - baseLpFee) / baseLpFee
            // exponent_SD59x18_int256 =  int256( (PIF - baseLpFee) * uUNIT / baseLpFee )
            // exponent = SD59x18.wrap(exponent_SD59x18_int256)
            SD59x18 exponent = SD59x18.wrap(int256(FullMath.mulDiv(PIF - baseLpFee, uint256(uUNIT), baseLpFee)));
            // when exponent > EXP_MAX_INPUT, inter(1/e^exponent) will be almost equal to 0, so DFF will be be almost equal to DFF_MAX
            if (gt(exponent, EXP_MAX_INPUT)) {
                DFF = DFF_MAX;
            } else {
                SD59x18 inter = inv(exp(exponent));
                if (inter < UNIT) {
                    DFF = DFF_MAX * (UNIT - inter);
                }
            }

            if (DFF.isZero()) {
                return 0;
            }

            // Will return DFF_MAX if DFF > DFF_MAX
            if (DFF > DFF_MAX) {
                DFF = DFF_MAX;
            }

            // convert(SD59x18 x) : Converts an SD59x18 number to a simple integer by dividing it by `UNIT(1e18)`.
            DFF_uint24 = uint24(int24(convert(DFF)));
        }

        if (PIF > PIF_MAX) {
            PIF = PIF_MAX;
        }
        // LPFee = DFF_uint24 * Min(PIF, 0.2 * ONE_HUNDRED_PERCENT_FEE) / ONE_HUNDRED_PERCENT_FEE
        uint24 lpFee = uint24(FullMath.mulDiv(DFF_uint24, PIF, LPFeeLibrary.ONE_HUNDRED_PERCENT_FEE));
        if (lpFee < baseLpFee) {
            return 0;
        }
        return lpFee;
    }

    /// @dev The swap simulation uses the base LP fee, so the simulated price may differ from the actual swap price, which uses a dynamic fee.
    function _simulateSwap(PoolKey calldata key, ICLPoolManager.SwapParams calldata params, bytes calldata hookData)
        internal
        returns (uint160 sqrtPriceX96)
    {
        try this.simulateSwap(key, params, hookData) {
            revert();
        } catch (bytes memory reason) {
            bytes4 selector;
            assembly ("memory-safe") {
                selector := mload(add(reason, 0x20))
            }
            if (selector != SwapAndRevert.selector) {
                revert();
            }

            assembly {
                sqrtPriceX96 := mload(add(reason, 0x24))
            }
        }
    }

    /// @dev Check pool coinfiguration
    function _checkPoolConfig(PoolConfig memory config) internal pure {
        if (config.DFF_max >= LPFeeLibrary.ONE_HUNDRED_PERCENT_FEE || config.DFF_max == 0) {
            revert InvalidDFFMax();
        }

        if (config.baseLpFee >= LPFeeLibrary.ONE_HUNDRED_PERCENT_FEE || config.baseLpFee == 0) {
            revert InvalidBaseLpFee();
        }

        if (config.alpha >= ALPHA_100_PERCENT || config.alpha == 0) {
            revert InvalidAlpha();
        }

        // baseLpFee should be smaller than max dynamic fee
        uint256 maxDynamicFee = config.DFF_max * PIF_MAX / LPFeeLibrary.ONE_HUNDRED_PERCENT_FEE;
        if (maxDynamicFee < config.baseLpFee) {
            revert InvalidBaseLpFee();
        }
    }
}
