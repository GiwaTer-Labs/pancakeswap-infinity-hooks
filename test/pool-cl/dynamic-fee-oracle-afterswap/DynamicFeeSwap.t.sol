// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Currency, CurrencyLibrary} from "infinity-core/src/types/Currency.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {FixedPoint96} from "infinity-core/src/pool-cl/libraries/FixedPoint96.sol";
import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {Vault} from "infinity-core/src/Vault.sol";
import {PoolId, PoolIdLibrary} from "infinity-core/src/types/PoolId.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {IBinPoolManager} from "infinity-core/src/pool-bin/interfaces/IBinPoolManager.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {CLPoolManager} from "infinity-core/src/pool-cl/CLPoolManager.sol";
import {CLPoolManagerRouter} from "infinity-core/test/pool-cl/helpers/CLPoolManagerRouter.sol";
import {CLPool} from "infinity-core/src/pool-cl/libraries/CLPool.sol";
import {IBinPoolManager} from "infinity-core/src/pool-bin/interfaces/IBinPoolManager.sol";
import {TokenFixture} from "infinity-periphery/test/helpers/TokenFixture.sol";
import {MockInfinityRouter} from "infinity-periphery/test/mocks/MockInfinityRouter.sol";
import {IInfinityRouter} from "infinity-periphery/src/interfaces/IInfinityRouter.sol";
import {ICLRouterBase} from "infinity-periphery/src/pool-cl/interfaces/ICLRouterBase.sol";
import {PathKey} from "infinity-periphery/src/libraries/PathKey.sol";
import {Plan, Planner} from "infinity-periphery/src/libraries/Planner.sol";
import {Actions} from "infinity-periphery/src/libraries/Actions.sol";
import {ActionConstants} from "infinity-periphery/src/libraries/ActionConstants.sol";
import {LPFeeLibrary} from "infinity-core/src/libraries/LPFeeLibrary.sol";
import {CLPoolParametersHelper} from "infinity-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";
import {PosmTestSetup} from "infinity-periphery/test/pool-cl/shared/PosmTestSetup.sol";
import {CLDynamicFeeHookTest} from "test/pool-cl/dynamic-fee-oracle-afterswap/helpers/CLDynamicFeeHookTest.sol";
import {IPriceFeed} from "src/pool-cl/dynamic-fee-oracle-afterswap/interfaces/IPriceFeed.sol";
import {PriceFeed} from "src/pool-cl/dynamic-fee-oracle-afterswap/PriceFeed.sol";
import {MockAggregatorV3} from "test/pool-cl/dynamic-fee-oracle-afterswap/helpers/MockAggregatorV3.sol";
import "forge-std/console2.sol";

contract DynamicFeeSwapTest is Test, PosmTestSetup {
    using Planner for Plan;

    MockAggregatorV3 defaultOracle;
    PriceFeed priceFeed;
    CLDynamicFeeHookTest dynamicFeeHook0;
    CLDynamicFeeHookTest dynamicFeeHook1;

    IVault public vault;
    ICLPoolManager public poolManager;

    MockInfinityRouter public infinityRouter;

    PoolId poolId;
    PoolId poolId2;
    PoolKey key;
    PoolKey key2;
    Plan planner;

    address alice = makeAddr("ALICE");
    address bob = makeAddr("BOB");

    // 0.25% fee
    uint24 DEFAULT_FEE = LPFeeLibrary.ONE_HUNDRED_PERCENT_FEE / 400;
    // MAX DFF 25%
    uint24 MAX_DFF = LPFeeLibrary.ONE_HUNDRED_PERCENT_FEE / 4;

    // v4 swap event
    event Swap(
        PoolId indexed id,
        address indexed sender,
        int128 amount0,
        int128 amount1,
        uint160 sqrtPriceX96,
        uint128 liquidity,
        int24 tick,
        uint24 fee,
        uint16 protocolFee
    );

    function setUp() public {
        planner = Planner.init();
        (currency0, currency1) = deployCurrencies(10 ** 30);

        (vault, poolManager) = createFreshManager();

        dynamicFeeHook0 = new CLDynamicFeeHookTest(ICLPoolManager(address(poolManager)));
        dynamicFeeHook1 = new CLDynamicFeeHookTest(ICLPoolManager(address(poolManager)));

        deployAndApprovePosm(vault, poolManager);

        seedBalance(address(this));
        // Give tokens to Alice and Bob.
        seedBalance(alice);
        seedBalance(bob);

        // Approve posm for Alice and bob.
        approvePosmFor(alice);
        approvePosmFor(bob);

        key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: dynamicFeeHook0,
            poolManager: poolManager,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            parameters: CLPoolParametersHelper.setTickSpacing(
                bytes32(uint256(dynamicFeeHook0.getHooksRegistrationBitmap())), 10
            )
        });
        poolId = key.toId();
        poolManager.initialize(key, SQRT_RATIO_1_1);

        // mint position
        planner = Planner.init().add(
            Actions.CL_MINT_POSITION,
            abi.encode(
                key,
                -300,
                300,
                10_000 ether,
                MAX_SLIPPAGE_INCREASE,
                MAX_SLIPPAGE_INCREASE,
                ActionConstants.MSG_SENDER,
                ZERO_BYTES
            )
        );
        bytes memory calls = planner.finalizeModifyLiquidityWithClose(key);
        lpm.modifyLiquidities(calls, block.timestamp + 1);

        // mint another positions
        planner = Planner.init().add(
            Actions.CL_MINT_POSITION,
            abi.encode(
                key,
                -10000,
                -9000,
                10_000 ether,
                MAX_SLIPPAGE_INCREASE,
                MAX_SLIPPAGE_INCREASE,
                ActionConstants.MSG_SENDER,
                ZERO_BYTES
            )
        );
        bytes memory calls_0 = planner.finalizeModifyLiquidityWithClose(key);
        lpm.modifyLiquidities(calls_0, block.timestamp + 1);

        key2 = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: dynamicFeeHook1,
            poolManager: poolManager,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            parameters: CLPoolParametersHelper.setTickSpacing(
                bytes32(uint256(dynamicFeeHook0.getHooksRegistrationBitmap())), 10
            )
        });
        poolId2 = key2.toId();
        poolManager.initialize(key2, SQRT_RATIO_1_1);

        // mint position
        planner = Planner.init().add(
            Actions.CL_MINT_POSITION,
            abi.encode(
                key2,
                -300,
                300,
                10_000 ether,
                MAX_SLIPPAGE_INCREASE,
                MAX_SLIPPAGE_INCREASE,
                ActionConstants.MSG_SENDER,
                ZERO_BYTES
            )
        );
        bytes memory calls2 = planner.finalizeModifyLiquidityWithClose(key2);
        lpm.modifyLiquidities(calls2, block.timestamp + 1);

        // mint another position
        planner = Planner.init().add(
            Actions.CL_MINT_POSITION,
            abi.encode(
                key2,
                -10000,
                -9000,
                10_000 ether,
                MAX_SLIPPAGE_INCREASE,
                MAX_SLIPPAGE_INCREASE,
                ActionConstants.MSG_SENDER,
                ZERO_BYTES
            )
        );
        bytes memory calls2_0 = planner.finalizeModifyLiquidityWithClose(key2);
        lpm.modifyLiquidities(calls2_0, block.timestamp + 1);

        infinityRouter = new MockInfinityRouter(vault, poolManager, IBinPoolManager(address(0)));
        IERC20(Currency.unwrap(currency0)).approve(address(infinityRouter), 10000000 ether);
        IERC20(Currency.unwrap(currency1)).approve(address(infinityRouter), 10000000 ether);
    }

    function test_two_pool_same_initial_state_t2() public {
        uint128 liquidity_Pool0 = poolManager.getLiquidity(poolId);
        uint128 liquidity_Pool1 = poolManager.getLiquidity(poolId2);
        assertEq(liquidity_Pool0, liquidity_Pool1);
        // (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee) = poolManager.getSlot0(poolId);
        // rename all with _pool0
        (uint160 sqrtPriceX96_pool0, int24 tick_pool0, uint24 protocolFee_pool0, uint24 lpFee_pool0) =
            poolManager.getSlot0(poolId);
        (uint160 sqrtPriceX96_pool1, int24 tick_pool1, uint24 protocolFee_pool1, uint24 lpFee_pool1) =
            poolManager.getSlot0(poolId2);
        assertEq(sqrtPriceX96_pool0, sqrtPriceX96_pool1);
        assertEq(tick_pool0, tick_pool1);
        assertEq(protocolFee_pool0, protocolFee_pool1);
        assertEq(lpFee_pool0, lpFee_pool1);
        assertEq(lpFee_pool0, 0);
    }

    // two pool with same tokens , same dynamic test hooks and same initial state
    // Swap using same swap parameters but different dynamic fee
    // the pools add two positions 1[-300, 300] and 2[-10000, -9000]
    // you can see the price gap after swap will be very large because of the different dynamic fee
    // tick_pool0_after_swap = -9005, tick_pool1_after_swap = -293
    function test_swap_with_different_dynamic_fee() public {
        uint128 swap_amount = 155 ether;

        bytes memory hookData = abi.encode(2500); // 0.25% fee
        ICLRouterBase.CLSwapExactInputSingleParams memory params_pool0 =
            ICLRouterBase.CLSwapExactInputSingleParams(key, true, swap_amount, 0, hookData);

        bytes memory hookData1 = abi.encode(50000); // 5% fee
        ICLRouterBase.CLSwapExactInputSingleParams memory params_pool1 =
            ICLRouterBase.CLSwapExactInputSingleParams(key2, true, swap_amount, 0, hookData1);

        planner = Planner.init().add(Actions.CL_SWAP_EXACT_IN_SINGLE, abi.encode(params_pool0));
        bytes memory data = planner.finalizeSwap(key.currency0, key.currency1, ActionConstants.MSG_SENDER);

        planner = Planner.init().add(Actions.CL_SWAP_EXACT_IN_SINGLE, abi.encode(params_pool1));
        bytes memory data2 = planner.finalizeSwap(key2.currency0, key2.currency1, ActionConstants.MSG_SENDER);

        infinityRouter.executeActions(data);
        infinityRouter.executeActions(data2);
        // 50508005220733188060893428755 [5.05e28], -9005, 0, 0
        (uint160 sqrtPriceX96_pool0, int24 tick_pool0, uint24 protocolFee_pool0, uint24 lpFee_pool0) =
            poolManager.getSlot0(poolId);
        //  78078457231530057496902067394 [7.807e28], -293, 0, 0
        (uint160 sqrtPriceX96_pool1, int24 tick_pool1, uint24 protocolFee_pool1, uint24 lpFee_pool1) =
            poolManager.getSlot0(poolId2);
        // we will get different sqrtPriceX96 after swap with different fee
        assertNotEq(sqrtPriceX96_pool0, sqrtPriceX96_pool1);
        assertEq(sqrtPriceX96_pool0, 50508005220733188060893428755);
        assertEq(sqrtPriceX96_pool1, 78078457231530057496902067394);
        assertNotEq(tick_pool0, tick_pool1);
        assertEq(tick_pool0, -9005);
        assertEq(tick_pool1, -293);
        assertEq(lpFee_pool0, lpFee_pool1);
        assertEq(lpFee_pool0, 0);
        assertEq(lpFee_pool1, 0);
    }

    // allow refund of ETH
    receive() external payable {}
}
