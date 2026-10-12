// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {CLBaseHook} from "src/pool-cl/CLBaseHook.sol";
import {FullMath} from "infinity-core/src/pool-cl/libraries/FullMath.sol";
import {FixedPoint96} from "infinity-core/src/pool-cl/libraries/FixedPoint96.sol";
import {LPFeeLibrary} from "infinity-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "infinity-core/src/types/PoolId.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "infinity-core/src/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "infinity-core/src/types/Currency.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "infinity-core/src/types/BeforeSwapDelta.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {CLPoolManager} from "infinity-core/src/pool-cl/CLPoolManager.sol";
import {SafeCast} from "infinity-core/src/libraries/SafeCast.sol";
import {
    SD59x18,
    uUNIT,
    UNIT,
    convert,
    inv,
    exp,
    lt,
    gt,
    sub,
    uEXP_MIN_THRESHOLD,
    EXP_MAX_INPUT
} from "prb-math/SD59x18.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {SqrtPriceBeforeLib} from "./libraries/SqrtPriceBeforeLib.sol";

import {IPriceFeed} from "./interfaces/IPriceFeed.sol";

contract CLOracleAfterSwapDynamicFeeHook is CLBaseHook, Ownable {
    using PoolIdLibrary for PoolKey;
    using LPFeeLibrary for uint24;
    using BalanceDeltaLibrary for BalanceDelta;
    using SafeCast for *;
    using CurrencyLibrary for Currency;

    struct PoolConfig {
        IPriceFeed priceFeed;
        uint24 DFF_max; // in hundredth of bips
        uint24 baseLpFee;
    }

    struct CallbackData {
        address sender;
        PoolKey key;
        ICLPoolManager.SwapParams params;
        bytes hookData;
    }

    // ============================== Variables ================================

    // will be set to true when emergency status
    // hooks will do nothing when this flag is true
    bool public emergencyFlag;

    mapping(PoolId id => PoolConfig) public poolConfigs;

    // TODO: Make it transient
    bool private _isSim;

    // ============================== Events ===================================
    event EmergencyFlagSet(bool flag);

    // ============================== Errors ===================================

    error NotDynamicFeePool();
    error PriceFeedTokensNotMatch();
    error DFFMaxTooLarge();
    error BaseLpFeeTooLarge();
    error DFFTooLarge();
    error SwapAndRevert(uint160 sqrtPriceX96);
    error NotDynamicFeeHook();
    error MissingInitializeHookData();

    // ============================== Modifiers ================================

    // ========================= External Functions ============================

    constructor(ICLPoolManager poolManager) Ownable(msg.sender) CLBaseHook(poolManager) {}

    /// @dev Set the emergency flag
    /// @param flag The emergency flag
    function setEmergencyFlag(bool flag) external onlyOwner {
        emergencyFlag = flag;
        emit EmergencyFlagSet(flag);
    }

    /// @dev Develpers can call this function to generate the hook data when initializing the pool
    /// @param priceFeed The price feed contract
    /// @param DFF_max The maximum dynamic fee
    /// @param baseLpFee The base LP fee
    function generateInitializeHookData(IPriceFeed priceFeed, uint24 DFF_max, uint24 baseLpFee)
        external
        pure
        returns (bytes memory)
    {
        if (DFF_max > LPFeeLibrary.ONE_HUNDRED_PERCENT_FEE) {
            revert DFFMaxTooLarge();
        }

        if (baseLpFee > LPFeeLibrary.ONE_HUNDRED_PERCENT_FEE) {
            revert BaseLpFeeTooLarge();
        }
        return abi.encode(PoolConfig({priceFeed: priceFeed, DFF_max: DFF_max, baseLpFee: baseLpFee}));
    }

    /// @dev Initialize a pool with this hook. Replaces passing hookData to poolManager.initialize (removed in Infinity).
    /// The pool manager skips hook callbacks when the hook itself is the caller, so the pool is configured here
    /// instead of in afterInitialize.
    /// @param hookData The output of generateInitializeHookData
    function initializePool(PoolKey calldata key, uint160 sqrtPriceX96, bytes calldata hookData)
        external
        returns (int24 tick)
    {
        if (!key.fee.isDynamicLPFee()) {
            revert NotDynamicFeePool();
        }

        PoolConfig memory initializeHookData = abi.decode(hookData, (PoolConfig));

        IPriceFeed priceFeed = IPriceFeed(initializeHookData.priceFeed);
        if (
            address(priceFeed.token0()) != Currency.unwrap(key.currency0)
                || address(priceFeed.token1()) != Currency.unwrap(key.currency1)
        ) {
            revert PriceFeedTokensNotMatch();
        }

        if (initializeHookData.DFF_max > LPFeeLibrary.ONE_HUNDRED_PERCENT_FEE) {
            revert DFFMaxTooLarge();
        }

        if (initializeHookData.baseLpFee > LPFeeLibrary.ONE_HUNDRED_PERCENT_FEE) {
            revert BaseLpFeeTooLarge();
        }

        poolConfigs[key.toId()] = PoolConfig({
            priceFeed: priceFeed,
            DFF_max: initializeHookData.DFF_max,
            baseLpFee: initializeHookData.baseLpFee
        });

        tick = poolManager.initialize(key, sqrtPriceX96);
        poolManager.updateDynamicLPFee(key, initializeHookData.baseLpFee);
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
                afterSwapReturnDelta: true,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            })
        );
    }

    /// @dev Only reached when the pool is initialized directly on the pool manager, which has no way to pass the config
    function afterInitialize(address, PoolKey calldata, uint160, int24)
        external
        view
        override
        poolManagerOnly
        returns (bytes4)
    {
        revert MissingInitializeHookData();
    }

    function beforeSwap(address, PoolKey calldata key, ICLPoolManager.SwapParams calldata, bytes calldata)
        external
        override
        poolManagerOnly
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId id = key.toId();
        (uint160 sqrtPriceX96Before,,,) = poolManager.getSlot0(id);
        SqrtPriceBeforeLib.setSqrtPriceBefore(sqrtPriceX96Before);

        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function afterSwap(
        address,
        PoolKey calldata key,
        ICLPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) external override poolManagerOnly returns (bytes4, int128) {
        if (emergencyFlag) {
            return (this.afterSwap.selector, 0);
        }

        PoolId id = key.toId();
        PoolConfig memory poolConfig = poolConfigs[id];

        uint160 sqrtPriceX96Before = SqrtPriceBeforeLib.getSqrtPriceBefore().toUint160();
        // TODO: Can check oracle price and sqrtPriceX96Before to skip the calculation, can save a lot of gas
        // if oracle_price  > sqrtPriceX96Before && zeroForOne == true , no need to calculate dynamic fee
        // if oracle_price  < sqrtPriceX96Before && zeroForOne == false , no need to calculate dynamic fee
        (uint160 sqrtPriceX96After,,,) = poolManager.getSlot0(id);

        // Fix TODO : Can not use priceX96
        // when tick is -887272, sqrtPrice is 4295128739 , priceX96 is 4295128739 * 4295128739 / 2^96 = 0
        // when tick between -665430 and -887272, priceX96 will be zero
        uint160 priceX96Before = uint160(FullMath.mulDiv(sqrtPriceX96Before, sqrtPriceX96Before, FixedPoint96.Q96));
        uint160 priceX96After = uint160(FullMath.mulDiv(sqrtPriceX96After, sqrtPriceX96After, FixedPoint96.Q96));

        uint24 lpFee = _calculateDynamicFee(
            poolConfig.priceFeed, priceX96Before, priceX96After, poolConfig.baseLpFee, poolConfig.DFF_max
        );
        if (lpFee == 0) {
            return (this.afterSwap.selector, 0);
        }
        uint256 tokenOut = params.zeroForOne ? int256(delta.amount1()).toUint256() : int256(delta.amount0()).toUint256();

        uint256 dynamicFeeAmount = tokenOut * lpFee / LPFeeLibrary.ONE_HUNDRED_PERCENT_FEE;
        vault.take(params.zeroForOne ? key.currency1 : key.currency0, address(this), dynamicFeeAmount);
        // TODO: How to use dynamic fee
        // 1. donate to v4 pool
        // 2. distribute by off-chain farming
        return (this.afterSwap.selector, dynamicFeeAmount.toInt128());
    }

    /// @dev Get the dynamic fee for a swap
    /// @param key The pool key
    /// @param sqrtPriceX96AfterSwap The sqrt price after the swap
    function getDynamicFee(PoolKey calldata key, uint160 sqrtPriceX96AfterSwap) external view returns (uint24) {
        PoolId id = key.toId();
        PoolConfig memory poolConfig = poolConfigs[id];

        (uint160 sqrtPriceX96Before,,,) = poolManager.getSlot0(id);
        uint160 priceX96Before = uint160(FullMath.mulDiv(sqrtPriceX96Before, sqrtPriceX96Before, FixedPoint96.Q96));
        uint160 priceX96After = uint160(FullMath.mulDiv(sqrtPriceX96AfterSwap, sqrtPriceX96AfterSwap, FixedPoint96.Q96));

        return _calculateDynamicFee(
            poolConfig.priceFeed, priceX96Before, priceX96After, poolConfig.baseLpFee, poolConfig.DFF_max
        );
    }

    // ========================= Internal Functions ============================

    function _calculateDynamicFee(
        IPriceFeed priceFeed,
        uint160 priceX96Before,
        uint160 priceX96After,
        uint24 baseLpFee,
        uint24 DFF_max
    ) internal view returns (uint24) {
        uint256 priceX96Oracle = priceFeed.getPriceX96();
        // If the oracle price is not available, we can't calculate the dynamic fee
        if (priceX96Oracle == 0) {
            return 0;
        }

        // ScaledFactor(SF) = max{priceX96After - priceX96Before / priceX96Oracle - priceX96Before , 0}
        // sfX96 = SF * 2 ** 96
        uint256 sfX96;
        {
            if (priceX96After > priceX96Before && priceX96Oracle > priceX96Before) {
                sfX96 =
                    FullMath.mulDiv(priceX96After - priceX96Before, FixedPoint96.Q96, priceX96Oracle - priceX96Before);
            }
            if (priceX96After < priceX96Before && priceX96Oracle < priceX96Before) {
                sfX96 =
                    FullMath.mulDiv(priceX96Before - priceX96After, FixedPoint96.Q96, priceX96Before - priceX96Oracle);
            }
        }

        // IndexPremium(IP) = ABS (priceX96Oracle/priceX96Before - -1)
        // ipX96 = ABS(priceX96Oracle * 2 ** 96 / priceX96Before - 2 ** 96)
        uint256 ipX96;
        {
            uint256 r = FullMath.mulDiv(priceX96Oracle, FixedPoint96.Q96, priceX96Before);
            ipX96 = r > FixedPoint96.Q96 ? r - FixedPoint96.Q96 : FixedPoint96.Q96 - r;
        }

        // PriceImpactFactor(PIF) = SF * IP
        // pifX96 = PIF * 2 ** 96
        //        = SF * IP * 2 ** 96
        //        = sfX96 / FixedPoint96.Q96 * ipX96 / FixedPoint96.Q96 * FixedPoint96.Q96
        //        = sfX96 * ipX96 / FixedPoint96.Q96
        uint256 pifX96 = FullMath.mulDiv(sfX96, ipX96, FixedPoint96.Q96);

        // DFF = max{DFF_max * (1 - e ^ -(pifX96 - fX96) / fx96), 0}
        //     = max{DFF_max * (1 - 1/ e ^ (pifX96 - fX96) / fx96), 0}
        SD59x18 DFF;
        // convert(int256 x) : Converts a simple integer to SD59x18 by multiplying it by `UNIT(1e18)`.
        // SD59x18 x =  SD59x18.wrap(x_int256 * uUNIT)
        SD59x18 DFF_MAX = convert(int256(int24(DFF_max)));
        // fx: fixed fee tier
        // fX96 = fx * 2 ** 96 = baseLpFee * 2 ** 96 / ONE_HUNDRED_PERCENT_FEE
        uint256 fX96 = FullMath.mulDiv(baseLpFee, FixedPoint96.Q96, LPFeeLibrary.ONE_HUNDRED_PERCENT_FEE);
        if (pifX96 > fX96) {
            // inv(SD59x18 x) : 1/x, Calculates the inverse of x.
            // exp(SD59x18 x) : e^x, Calculates the natural exponent of x.
            // exponent_uint256 = (pifX96 - fX96) / fx96
            // exponent_SD59x18_int256 =  int256( (pifX96 - fX96) * uUNIT / fx96 )
            // exponent = SD59x18.wrap(exponent_SD59x18_int256)
            SD59x18 exponent = SD59x18.wrap(int256(FullMath.mulDiv(pifX96 - fX96, uint256(uUNIT), fX96)));
            // when exponent > EXP_MAX_INPUT - UNIT, inter(1/e^exponent) will be almost equal to 0, so DFF will be be almost equal to DFF_MAX
            if (gt(exponent, sub(EXP_MAX_INPUT, UNIT))) {
                DFF = DFF_MAX;
            } else {
                SD59x18 inter = inv(exp(exponent));
                if (inter < UNIT) {
                    DFF = DFF_MAX * (UNIT - inter);
                }
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
        uint24 DFF_uint24 = uint24(int24(convert(DFF)));
        // LPFee = DFF_uint24 * PIF = DFF_uint24 * pifX96 / 2 ** 96
        uint24 lpFee = uint24(FullMath.mulDiv(DFF_uint24, pifX96, FixedPoint96.Q96));
        // TODO : Need to add one more parameter about max dynamic fee
        // DF_max : dynamic fee max
        // if (lpFee > DF_max) {lpFee = DF_max;}
        if (lpFee < baseLpFee) {
            return 0;
        }
        return lpFee;
    }

    function collectDynamicFee(Currency currency) external onlyOwner {
        currency.transfer(msg.sender, currency.balanceOfSelf());
    }

    receive() external payable {}
}
