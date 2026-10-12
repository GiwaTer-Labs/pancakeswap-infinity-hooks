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
import {IPriceFeed} from "./interfaces/IPriceFeed.sol";

contract CLOracleDynamicFeeHook is CLBaseHook, Ownable {
    using PoolIdLibrary for PoolKey;
    using LPFeeLibrary for uint24;

    // maxDynamicFee would be DFF_max * PIF_MAX. eg. if PIF_MAX is 200_000(0.2) and DFF_MAX is 100_000(0.1), it means max dynamicFee is 20_000(0.02) (2%)
    struct PoolConfig {
        IPriceFeed priceFeed;
        uint24 DFF_max; // in hundredth of bips
        uint24 baseLpFee; // 3_000 means 0.3%
    }

    struct CallbackData {
        address sender;
        PoolKey key;
        ICLPoolManager.SwapParams params;
        bytes hookData;
    }

    // ============================== Variables ================================
    // 0.2 * ONE_HUNDRED_PERCENT_FEE
    uint256 private constant PIF_MAX = 200_000;

    // will be set to true when emergency status
    // hooks will do nothing when this flag is true
    bool public emergencyFlag;

    mapping(PoolId id => PoolConfig) public poolConfigs;

    // ============================== Events ===================================
    event UpdateEmergencyFlag(bool flag);
    event UpdatePoolConfig(PoolId indexed id, IPriceFeed priceFeed, uint24 DFF_max, uint24 baseLpFee);

    // ============================== Errors ===================================

    error NotDynamicFeePool();
    error PriceFeedTokensNotMatch();
    error DFFMaxTooLarge();
    error BaseLpFeeTooLarge();
    error DFFTooLarge();
    error SwapAndRevert(uint160 sqrtPriceX96);
    error NotDynamicFeeHook();
    error PriceFeedNotAvailable();
    error PoolAlreadyInitialized();
    error InvalidPoolConfig();

    // ============================== Modifiers ================================

    // ========================= External Functions ============================

    constructor(ICLPoolManager poolManager) Ownable(msg.sender) CLBaseHook(poolManager) {}

    /// @dev Set the emergency flag
    /// @param flag The emergency flag
    function setEmergencyFlag(bool flag) external onlyOwner {
        emergencyFlag = flag;
        emit UpdateEmergencyFlag(flag);
    }

    /// @notice Add new dynamic fee configuration for a pool
    /// @dev Only owner can call this function
    /// @dev The pool must be a dynamic fee pool
    /// @dev The pool must not be initialized
    /// @dev Can update config before the pool is initialized
    /// @param key The pool key
    /// @param priceFeed The price feed contract
    /// @param DFF_max The maximum dynamic fee
    /// @param baseLpFee The base LP fee
    function addPoolConfig(PoolKey calldata key, IPriceFeed priceFeed, uint24 DFF_max, uint24 baseLpFee)
        external
        onlyOwner
    {
        if (!key.fee.isDynamicLPFee() || key.hooks != IHooks(address(this))) {
            revert NotDynamicFeePool();
        }

        if (
            address(priceFeed.token0()) != Currency.unwrap(key.currency0)
                || address(priceFeed.token1()) != Currency.unwrap(key.currency1)
        ) {
            revert PriceFeedTokensNotMatch();
        }

        PoolId id = key.toId();
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(id);
        if (sqrtPriceX96 != 0) {
            revert PoolAlreadyInitialized();
        }

        if (DFF_max >= LPFeeLibrary.ONE_HUNDRED_PERCENT_FEE) {
            revert DFFMaxTooLarge();
        }

        if (baseLpFee >= LPFeeLibrary.ONE_HUNDRED_PERCENT_FEE) {
            revert BaseLpFeeTooLarge();
        }

        // baseLpFee should be smaller than max dynamic fee
        uint256 maxDynamicFee = DFF_max * PIF_MAX / LPFeeLibrary.ONE_HUNDRED_PERCENT_FEE;
        if (maxDynamicFee < baseLpFee) {
            revert BaseLpFeeTooLarge();
        }

        poolConfigs[id] = PoolConfig({priceFeed: priceFeed, DFF_max: DFF_max, baseLpFee: baseLpFee});
        emit UpdatePoolConfig(id, priceFeed, DFF_max, baseLpFee);
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
                afterSwap: false,
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
        PoolConfig memory poolConfig = poolConfigs[id];
        if (poolConfig.DFF_max == 0 || poolConfig.baseLpFee == 0 || address(poolConfig.priceFeed) == address(0)) {
            revert InvalidPoolConfig();
        }

        uint256 priceX96Oracle = poolConfig.priceFeed.getPriceX96();
        if (priceX96Oracle == 0) {
            revert PriceFeedNotAvailable();
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
    ) external override returns (bytes4, BeforeSwapDelta, uint24) {
        if (emergencyFlag) {
            return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        PoolId id = key.toId();
        PoolConfig memory poolConfig = poolConfigs[id];

        uint256 priceX96Oracle = _getOraclePriceX96(poolConfig.priceFeed);
        // If the oracle price is not available, we will skip dynamic fee calculation
        if (priceX96Oracle == 0) {
            return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        (uint160 sqrtPriceX96Before,,,) = poolManager.getSlot0(id);
        // Fix TODO : should we skip cases when tick is smaller than -665454?  this situation will hardly occur in a normal pool。
        // when tick is -665454, sqrtPrice is 281482911877014 , priceX96 is 281482911877014 * 281482911877014 / 2^96 = 1
        // priceX96 will not be available when tick is smaller than -665454
        // pool_price = token1/token0 = 1/2 ** 96, which is very small
        // oracle max decimals is 18, so min price is 1/10^18
        // when tick is -414486, pool price is 1/10^18, so we can use priceX96.
        // oracle will not work when tick is smaller than -414486
        uint256 priceX96Before = uint160(FullMath.mulDiv(sqrtPriceX96Before, sqrtPriceX96Before, FixedPoint96.Q96));

        // Only charge dynamic fee when price_after_swap and price_oracle are on the same side compared to price_before_swap
        // when zeroForOne is true, priceX96After is smaller than priceX96Before, so we can skip the calculation when priceX96Oracle is bigger than priceX96Before
        // when zeroForOne is false, priceX96After is larger than priceX96Before, so we can skip the calculation when priceX96Oracle is smaller than priceX96Before
        // SF = max{priceX96After - priceX96Before / priceX96Oracle - priceX96Before , 0}
        // priceX96After - priceX96Before / priceX96Oracle - priceX96Before is negative in this case
        // so SF is 0, we can skip simualtion, will save some gas
        if (
            params.zeroForOne && priceX96Oracle >= priceX96Before
                || !params.zeroForOne && priceX96Oracle <= priceX96Before
        ) {
            return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }
        // get the sqrt price after the swap by simulating the swap
        // NOTICE: The swap simulation uses the base LP fee, so the simulated price may differ from the actual swap price, which uses a dynamic fee.
        uint160 sqrtPriceX96After = _simulateSwap(key, params, hookData);
        uint24 lpFee =
            _calculateDynamicFee(sqrtPriceX96Before, sqrtPriceX96After, poolConfig.baseLpFee, poolConfig.DFF_max);
        if (lpFee == 0) {
            return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, lpFee | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    /// @dev Get the dynamic fee for a swap
    /// @param key The pool key
    /// @param sqrtPriceX96AfterSwap The sqrt price after the swap
    function getDynamicFee(PoolKey calldata key, uint160 sqrtPriceX96AfterSwap) external view returns (uint24) {
        if (emergencyFlag) {
            return 0;
        }
        PoolId id = key.toId();
        PoolConfig memory poolConfig = poolConfigs[id];

        uint256 priceX96Oracle = _getOraclePriceX96(poolConfig.priceFeed);
        // If the oracle price is not available, we will skip dynamic fee calculation
        if (priceX96Oracle == 0) {
            return 0;
        }

        (uint160 sqrtPriceX96Before,,,) = poolManager.getSlot0(id);
        uint256 priceX96Before = uint160(FullMath.mulDiv(sqrtPriceX96Before, sqrtPriceX96Before, FixedPoint96.Q96));
        uint256 priceX96After = uint160(FullMath.mulDiv(sqrtPriceX96AfterSwap, sqrtPriceX96AfterSwap, FixedPoint96.Q96));
        if (
            !(priceX96After > priceX96Before && priceX96Oracle > priceX96Before)
                && !(priceX96After < priceX96Before && priceX96Oracle < priceX96Before)
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

    /// @dev Get the oracle price , and make sure hook can still work even if the oracle is not available
    function _getOraclePriceX96(IPriceFeed priceFeed) internal view returns (uint256 priceX96Oracle) {
        try priceFeed.getPriceX96() returns (uint256 priceX96) {
            priceX96Oracle = priceX96;
        } catch {
            // Do nothing
        }
    }
}
