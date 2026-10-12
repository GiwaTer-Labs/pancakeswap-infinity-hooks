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
import {CLDynamicFeeHookTest} from "test/pool-cl/dynamic-fee-oracle/helpers/CLDynamicFeeHookTest.sol";
import {IPriceFeed} from "src/pool-cl/dynamic-fee-oracle/interfaces/IPriceFeed.sol";
import {PriceFeed} from "src/pool-cl/dynamic-fee-oracle/PriceFeed.sol";
import {MockAggregatorV3} from "test/pool-cl/dynamic-fee-oracle/helpers/MockAggregatorV3.sol";
import "forge-std/console2.sol";

contract CLDynamicFeeSimulateSwapNotWork is Test, PosmTestSetup {
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

        infinityRouter = new MockInfinityRouter(vault, poolManager, IBinPoolManager(address(0)));
        IERC20(Currency.unwrap(currency0)).approve(address(infinityRouter), 10000000 ether);
        IERC20(Currency.unwrap(currency1)).approve(address(infinityRouter), 10000000 ether);
    }

    function test_two_pool_same_initial_state() public {
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

    function test_swap_with_different_fee_get_different_sqrtPriceAfterSwap() public {
        bytes memory hookData = abi.encode(2500); // 0.25% fee
        ICLRouterBase.CLSwapExactInputSingleParams memory params_pool0 =
            ICLRouterBase.CLSwapExactInputSingleParams(key, true, 100 ether, 0, hookData);

        bytes memory hookData1 = abi.encode(250000); // 25% fee
        ICLRouterBase.CLSwapExactInputSingleParams memory params_pool1 =
            ICLRouterBase.CLSwapExactInputSingleParams(key2, true, 100 ether, 0, hookData1);

        planner = Planner.init().add(Actions.CL_SWAP_EXACT_IN_SINGLE, abi.encode(params_pool0));
        bytes memory data = planner.finalizeSwap(key.currency0, key.currency1, ActionConstants.MSG_SENDER);

        planner = Planner.init().add(Actions.CL_SWAP_EXACT_IN_SINGLE, abi.encode(params_pool1));
        bytes memory data2 = planner.finalizeSwap(key2.currency0, key2.currency1, ActionConstants.MSG_SENDER);

        infinityRouter.executeActions(data);
        infinityRouter.executeActions(data2);
        // 78445666986078207473990891197 [7.844e28], -199, 0, 0
        (uint160 sqrtPriceX96_pool0, int24 tick_pool0, uint24 protocolFee_pool0, uint24 lpFee_pool0) =
            poolManager.getSlot0(poolId);
        //  78638374703984454187140397356 [7.863e28], -150, 0, 0
        (uint160 sqrtPriceX96_pool1, int24 tick_pool1, uint24 protocolFee_pool1, uint24 lpFee_pool1) =
            poolManager.getSlot0(poolId2);
        // we will get different sqrtPriceX96 after swap with different fee
        assertNotEq(sqrtPriceX96_pool0, sqrtPriceX96_pool1);
        assertEq(sqrtPriceX96_pool0, 78445666986078207473990891197);
        assertEq(sqrtPriceX96_pool1, 78638374703984454187140397356);
        assertNotEq(tick_pool0, tick_pool1);
        assertEq(tick_pool0, -199);
        assertEq(tick_pool1, -150);
        assertEq(lpFee_pool0, lpFee_pool1);
        assertEq(lpFee_pool0, 0);
        assertEq(lpFee_pool1, 0);
    }

    function testFuzz_swap_with_different_fee_get_different_sqrtPriceAfterSwap(uint256 swapAmount) public {
        swapAmount = bound(swapAmount, 50 ether, 100 ether);
        bytes memory hookData = abi.encode(2500); // 0.25% fee
        ICLRouterBase.CLSwapExactInputSingleParams memory params_pool0 =
            ICLRouterBase.CLSwapExactInputSingleParams(key, true, uint128(swapAmount), 0, hookData);

        bytes memory hookData1 = abi.encode(250000); // 25% fee
        ICLRouterBase.CLSwapExactInputSingleParams memory params_pool1 =
            ICLRouterBase.CLSwapExactInputSingleParams(key2, true, uint128(swapAmount), 0, hookData1);

        planner = Planner.init().add(Actions.CL_SWAP_EXACT_IN_SINGLE, abi.encode(params_pool0));
        bytes memory data = planner.finalizeSwap(key.currency0, key.currency1, ActionConstants.MSG_SENDER);

        planner = Planner.init().add(Actions.CL_SWAP_EXACT_IN_SINGLE, abi.encode(params_pool1));
        bytes memory data2 = planner.finalizeSwap(key2.currency0, key2.currency1, ActionConstants.MSG_SENDER);

        infinityRouter.executeActions(data);
        infinityRouter.executeActions(data2);
        (uint160 sqrtPriceX96_pool0, int24 tick_pool0, uint24 protocolFee_pool0, uint24 lpFee_pool0) =
            poolManager.getSlot0(poolId);
        (uint160 sqrtPriceX96_pool1, int24 tick_pool1, uint24 protocolFee_pool1, uint24 lpFee_pool1) =
            poolManager.getSlot0(poolId2);
        // we will get different sqrtPriceX96 after swap with different fee
        assertNotEq(sqrtPriceX96_pool0, sqrtPriceX96_pool1);
        assertNotEq(tick_pool0, tick_pool1);
        assertEq(lpFee_pool0, lpFee_pool1);
    }

    function testFuzz_swap_with_same_fee_get_same_sqrtPriceAfterSwap(uint256 swapAmount, uint24 lpFee) public {
        swapAmount = bound(swapAmount, 50 ether, 100 ether);
        lpFee = uint24(bound(lpFee, 100, 200000)); // from 0.01% to 20%
        bytes memory hookData = abi.encode(lpFee);
        ICLRouterBase.CLSwapExactInputSingleParams memory params_pool0 =
            ICLRouterBase.CLSwapExactInputSingleParams(key, true, uint128(swapAmount), 0, hookData);

        bytes memory hookData1 = abi.encode(lpFee);
        ICLRouterBase.CLSwapExactInputSingleParams memory params_pool1 =
            ICLRouterBase.CLSwapExactInputSingleParams(key2, true, uint128(swapAmount), 0, hookData1);

        planner = Planner.init().add(Actions.CL_SWAP_EXACT_IN_SINGLE, abi.encode(params_pool0));
        bytes memory data = planner.finalizeSwap(key.currency0, key.currency1, ActionConstants.MSG_SENDER);

        planner = Planner.init().add(Actions.CL_SWAP_EXACT_IN_SINGLE, abi.encode(params_pool1));
        bytes memory data2 = planner.finalizeSwap(key2.currency0, key2.currency1, ActionConstants.MSG_SENDER);

        infinityRouter.executeActions(data);
        infinityRouter.executeActions(data2);
        (uint160 sqrtPriceX96_pool0, int24 tick_pool0, uint24 protocolFee_pool0, uint24 lpFee_pool0) =
            poolManager.getSlot0(poolId);
        (uint160 sqrtPriceX96_pool1, int24 tick_pool1, uint24 protocolFee_pool1, uint24 lpFee_pool1) =
            poolManager.getSlot0(poolId2);
        // we will get same sqrtPriceX96 after swap with same fee
        assertEq(sqrtPriceX96_pool0, sqrtPriceX96_pool1);
        assertEq(tick_pool0, tick_pool1);
        assertEq(lpFee_pool0, lpFee_pool1);
    }

    // allow refund of ETH
    receive() external payable {}
}
