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
import {CustomRevert} from "infinity-core/src/libraries/CustomRevert.sol";
import {ICLHooks} from "infinity-core/src/pool-cl/interfaces/ICLHooks.sol";
import {Hooks} from "infinity-core/src/libraries/Hooks.sol";
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
import {CLLiquidityOperations} from "infinity-periphery/test/pool-cl/shared/CLLiquidityOperations.sol";
import {CLOracleDynamicFeeHook} from "src/pool-cl/dynamic-fee-oracle/CLOracleDynamicFeeHook.sol";
import {PriceFeed} from "src/pool-cl/dynamic-fee-oracle/PriceFeed.sol";
import {MockAggregatorV3} from "test/pool-cl/dynamic-fee-oracle/helpers/MockAggregatorV3.sol";
import {IPriceFeed} from "src/pool-cl/dynamic-fee-oracle/interfaces/IPriceFeed.sol";
// import "forge-std/console2.sol";

contract CLDynamicFeeHookTest is Test, PosmTestSetup {
    using Planner for Plan;
    using CurrencyLibrary for Currency;

    MockAggregatorV3 defaultOracle;
    PriceFeed priceFeed;
    CLOracleDynamicFeeHook dynamicFeeHook;
    CLOracleDynamicFeeHook dynamicFeeHook1;

    IVault public vault;
    ICLPoolManager public poolManager;

    MockInfinityRouter public infinityRouter;

    PoolId poolId;
    PoolId poolId1;
    PoolKey key;
    PoolKey key1;
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

        defaultOracle = new MockAggregatorV3(18, 10 ** 18);
        priceFeed =
            new PriceFeed(Currency.unwrap(currency0), Currency.unwrap(currency1), address(defaultOracle), 0, 3600 * 24);
        dynamicFeeHook = new CLOracleDynamicFeeHook(ICLPoolManager(address(poolManager)));

        dynamicFeeHook1 = new CLOracleDynamicFeeHook(ICLPoolManager(address(poolManager)));

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
            hooks: dynamicFeeHook,
            poolManager: poolManager,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            parameters: CLPoolParametersHelper.setTickSpacing(
                bytes32(uint256(dynamicFeeHook.getHooksRegistrationBitmap())), 10
            )
        });
        poolId = key.toId();
        // add pool config in hook
        dynamicFeeHook.addPoolConfig(key, priceFeed, MAX_DFF, DEFAULT_FEE);
        poolManager.initialize(key, SQRT_RATIO_1_1);

        // mint position , tokenId is 1
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
        bytes memory pool0_callData_0 = planner.finalizeModifyLiquidityWithClose(key);
        lpm.modifyLiquidities(pool0_callData_0, block.timestamp + 1);

        // mint position , tokenId is 2
        planner = Planner.init().add(
            Actions.CL_MINT_POSITION,
            abi.encode(
                key,
                -9000,
                -6000,
                10_000 ether,
                MAX_SLIPPAGE_INCREASE,
                MAX_SLIPPAGE_INCREASE,
                ActionConstants.MSG_SENDER,
                ZERO_BYTES
            )
        );
        bytes memory pool0_callData_1 = planner.finalizeModifyLiquidityWithClose(key);
        lpm.modifyLiquidities(pool0_callData_1, block.timestamp + 1);

        // mint position , tokenId is 3
        planner = Planner.init().add(
            Actions.CL_MINT_POSITION,
            abi.encode(
                key,
                6000,
                9000,
                10_000 ether,
                MAX_SLIPPAGE_INCREASE,
                MAX_SLIPPAGE_INCREASE,
                ActionConstants.MSG_SENDER,
                ZERO_BYTES
            )
        );
        bytes memory pool0_callData_2 = planner.finalizeModifyLiquidityWithClose(key);
        lpm.modifyLiquidities(pool0_callData_2, block.timestamp + 1);

        key1 = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: dynamicFeeHook1,
            poolManager: poolManager,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            parameters: CLPoolParametersHelper.setTickSpacing(
                bytes32(uint256(dynamicFeeHook.getHooksRegistrationBitmap())), 10
            )
        });
        poolId1 = key1.toId();

        infinityRouter = new MockInfinityRouter(vault, poolManager, IBinPoolManager(address(0)));
        IERC20(Currency.unwrap(currency0)).approve(address(infinityRouter), 10000000 ether);
        IERC20(Currency.unwrap(currency1)).approve(address(infinityRouter), 10000000 ether);
    }

    function test_dynamic_fee_hook_initialization() public view {
        (IPriceFeed priceFeedContract, uint24 hook_DFF_max, uint24 baseLpFee) = dynamicFeeHook.poolConfigs(poolId);
        assertEq(address(priceFeedContract), address(priceFeed));
        assertEq(hook_DFF_max, MAX_DFF);
        assertEq(baseLpFee, DEFAULT_FEE);
    }

    function test_simulate_swap_not_from_hooks_revert() public {
        ICLPoolManager.SwapParams memory params =
            ICLPoolManager.SwapParams({zeroForOne: true, amountSpecified: 0, sqrtPriceLimitX96: 0});
        vm.expectRevert(CLOracleDynamicFeeHook.NotDynamicFeeHook.selector);
        dynamicFeeHook.simulateSwap(key, params, ZERO_BYTES);
    }

    // NotDynamicFeePool
    function test_addPoolConfig_revert_NotDynamicFeePool() public {
        PoolKey memory key_not_dynamic = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: dynamicFeeHook1,
            poolManager: poolManager,
            fee: DEFAULT_FEE,
            parameters: CLPoolParametersHelper.setTickSpacing(
                bytes32(uint256(dynamicFeeHook.getHooksRegistrationBitmap())), 10
            )
        });
        vm.expectRevert(CLOracleDynamicFeeHook.NotDynamicFeePool.selector);
        dynamicFeeHook.addPoolConfig(key_not_dynamic, priceFeed, MAX_DFF, DEFAULT_FEE);
    }

    // PriceFeedTokensNotMatch
    function test_addPoolConfig_revert_PriceFeedTokensNotMatch() public {
        MockERC20 token2 = new MockERC20("T", "T", 18);
        PriceFeed priceFeed2 =
            new PriceFeed(address(token2), Currency.unwrap(currency0), address(defaultOracle), 0, 3600 * 24);
        vm.expectRevert(CLOracleDynamicFeeHook.PriceFeedTokensNotMatch.selector);
        dynamicFeeHook1.addPoolConfig(key1, priceFeed2, MAX_DFF, DEFAULT_FEE);
    }

    // DFFMaxTooLarge
    function test_addPoolConfig_revert_DFFMaxTooLarge() public {
        vm.expectRevert(CLOracleDynamicFeeHook.DFFMaxTooLarge.selector);
        dynamicFeeHook1.addPoolConfig(key1, priceFeed, LPFeeLibrary.ONE_HUNDRED_PERCENT_FEE, DEFAULT_FEE);
    }

    // BaseLpFeeTooLarge
    function test_addPoolConfig_revert_BaseLpFeeTooLarge() public {
        vm.expectRevert(CLOracleDynamicFeeHook.BaseLpFeeTooLarge.selector);
        dynamicFeeHook1.addPoolConfig(key1, priceFeed, MAX_DFF, LPFeeLibrary.ONE_HUNDRED_PERCENT_FEE);
    }

    // BaseLpFeeTooLarge
    function test_addPoolConfig_revert_BaseLpFeeTooLarge_than_DFF() public {
        vm.expectRevert(CLOracleDynamicFeeHook.BaseLpFeeTooLarge.selector);
        dynamicFeeHook1.addPoolConfig(key1, priceFeed, MAX_DFF, MAX_DFF / 5 + 1);
    }

    // addPoolConfig success
    function test_addPoolConfig_success() public {
        vm.expectEmit(true, true, true, true);
        emit CLOracleDynamicFeeHook.UpdatePoolConfig(poolId1, priceFeed, MAX_DFF, DEFAULT_FEE);
        dynamicFeeHook1.addPoolConfig(key1, priceFeed, MAX_DFF, DEFAULT_FEE);
        (IPriceFeed priceFeedContract, uint24 hook_DFF_max, uint24 baseLpFee) = dynamicFeeHook1.poolConfigs(poolId1);
        assertEq(address(priceFeedContract), address(priceFeed));
        assertEq(hook_DFF_max, MAX_DFF);
        assertEq(baseLpFee, DEFAULT_FEE);
    }

    // InvalidPoolConfig when pool initialized
    function test_afterInitialize_revert_InvalidPoolConfig() public {
        // vm.expectRevert(CLOracleDynamicFeeHook.InvalidPoolConfig.selector);
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(dynamicFeeHook1),
                ICLHooks.afterInitialize.selector,
                abi.encodeWithSelector(CLOracleDynamicFeeHook.InvalidPoolConfig.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        poolManager.initialize(key1, SQRT_RATIO_1_1);
    }

    // PriceFeedNotAvailable
    function test_afterInitialize_revert_PriceFeedNotAvailable() public {
        dynamicFeeHook1.addPoolConfig(key1, priceFeed, MAX_DFF, DEFAULT_FEE);
        defaultOracle.updateAnswer(0);
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(dynamicFeeHook1),
                ICLHooks.afterInitialize.selector,
                abi.encodeWithSelector(CLOracleDynamicFeeHook.PriceFeedNotAvailable.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        poolManager.initialize(key1, SQRT_RATIO_1_1);
    }

    function test_swap_no_dynamic_fee() external {
        uint128 liquidity = poolManager.getLiquidity(poolId);
        assertGt(liquidity, 0);

        ICLRouterBase.CLSwapExactInputSingleParams memory params =
            ICLRouterBase.CLSwapExactInputSingleParams(key, true, 1 ether, 0, bytes(""));

        planner = Planner.init().add(Actions.CL_SWAP_EXACT_IN_SINGLE, abi.encode(params));
        bytes memory data = planner.finalizeSwap(key.currency0, key.currency1, ActionConstants.MSG_SENDER);
        uint160 sqrtPriceX96AfterSwap = 79220260293300080910473130642;
        uint24 dynamic_fee = dynamicFeeHook.getDynamicFee(key, sqrtPriceX96AfterSwap);
        assertEq(dynamic_fee, 0);

        vm.expectEmit(true, true, true, true);
        emit Swap(
            poolId,
            address(infinityRouter),
            -1 ether,
            997400509299197405,
            sqrtPriceX96AfterSwap,
            10000000000000000000000,
            -2,
            DEFAULT_FEE,
            0
        );

        vm.startSnapshotGas("CLOracleDynamicFeeHook#swap_no_dynamic_fee_and_no_simulation_swap");
        infinityRouter.executeActions(data);
        vm.stopSnapshotGas();
        (uint256 feeGrowthGlobal0x128, uint256 feeGrowthGlobal1x128) = poolManager.getFeeGrowthGlobals(poolId);
        // charge tokenIn fee
        assertGt(feeGrowthGlobal0x128, 0);
        assertEq(feeGrowthGlobal1x128, 0);
    }

    function testFuzz_swap_with_dynamic_fee(uint128 swap_amount, bool is_zeroForOne, uint256 oracle_price) external {
        vm.assume(swap_amount > 0);
        defaultOracle.updateAnswer(int256(oracle_price));

        uint128 liquidity = poolManager.getLiquidity(poolId);
        assertGt(liquidity, 0);

        ICLRouterBase.CLSwapExactInputSingleParams memory params =
            ICLRouterBase.CLSwapExactInputSingleParams(key, is_zeroForOne, swap_amount, 0, bytes(""));

        planner = Planner.init().add(Actions.CL_SWAP_EXACT_IN_SINGLE, abi.encode(params));
        Currency currencyIn = is_zeroForOne ? key.currency0 : key.currency1;
        Currency currencyOut = is_zeroForOne ? key.currency1 : key.currency0;
        bytes memory data = planner.finalizeSwap(currencyIn, currencyOut, ActionConstants.MSG_SENDER);

        infinityRouter.executeActions(data);
    }

    function test_swap_with_dynamic_fee_zeroForOne() external {
        // set oracle price to 0.8
        defaultOracle.updateAnswer(80 * 10 ** 16);
        uint256 priceX96Oracle = priceFeed.getPriceX96();
        assertEq(uint256(priceX96Oracle), 8 * FixedPoint96.Q96 / 10);

        uint128 liquidity = poolManager.getLiquidity(poolId);
        assertGt(liquidity, 0);

        uint128 swap_amount = 155 ether;
        ICLRouterBase.CLSwapExactInputSingleParams memory params =
            ICLRouterBase.CLSwapExactInputSingleParams(key, true, swap_amount, 0, bytes(""));

        planner = Planner.init().add(Actions.CL_SWAP_EXACT_IN_SINGLE, abi.encode(params));
        bytes memory data = planner.finalizeSwap(key.currency0, key.currency1, ActionConstants.MSG_SENDER);
        uint160 sqrtPriceX96BySimulation = 58679377533000008502924125879;
        uint160 sqrtPriceX96AfterSwap = 78078457231530057496902067394;
        uint24 dynamic_fee = dynamicFeeHook.getDynamicFee(key, sqrtPriceX96BySimulation);
        assertGt(dynamic_fee, 0);
        /*
        Manual verification of dynamic fee calculation process

        price_oracle = 0.8
        price_before = 1 // tick = 0
        price_after = 1.0001 ^ -6006 = 0.5484989179559573 // tick = - 6006
        SF = price_after - price_before / price_oracle - price_before = 2.257505410220214
        IP = 1 - price_oracle / price_before = 0.2
        PIF = SF * IP = 0.4515010820440428
        DFF_MAX = 0.25
        F = 0.0025
        DFF = DFF_MAX * (1 - e^ -(PIF - F) / F) = 0.25
        dynamic_fee = DFF * Min(PIF, 0.2) = 0.25 * 0.2 = 0.05
        */
        assertEq(dynamic_fee, 50000);

        vm.expectEmit(true, true, true, true);
        // Simulation swap event
        emit Swap(
            poolId,
            address(dynamicFeeHook),
            -155 ether,
            150787838537480690636,
            sqrtPriceX96BySimulation,
            10000000000000000000000,
            -6006,
            DEFAULT_FEE,
            0
        );
        vm.expectEmit(true, true, true, true);
        // Real swap event
        emit Swap(
            poolId,
            address(infinityRouter),
            -155 ether,
            145113208012022961886,
            sqrtPriceX96AfterSwap,
            10000000000000000000000,
            -293,
            dynamic_fee,
            0
        );

        vm.startSnapshotGas("CLOracleDynamicFeeHook#swap_with_dynamic_fee_zeroForOne");
        infinityRouter.executeActions(data);
        vm.stopSnapshotGas();

        (uint256 feeGrowthGlobal0x128, uint256 feeGrowthGlobal1x128) = poolManager.getFeeGrowthGlobals(poolId);
        // charge tokenIn fee
        assertGt(feeGrowthGlobal0x128, 0);
        assertEq(feeGrowthGlobal1x128, 0);

        // dynamic_fee_amount = tokenInAmount * dynamic_fee / 1_000_000 - 1;
        // -1 is for calculation precision loss
        uint256 dynamic_fee_curreny0_amount = swap_amount * dynamic_fee / LPFeeLibrary.ONE_HUNDRED_PERCENT_FEE - 1;
        assertEq(dynamic_fee_curreny0_amount, 7749999999999999999);
        uint256 currency0_balance_before = currency0.balanceOfSelf();
        // collect fees
        bytes memory collect_calldata = CLLiquidityOperations.getCollectEncoded(1, ZERO_BYTES);
        lpm.modifyLiquidities(collect_calldata, block.timestamp + 1);
        bytes memory collect_calldata_2 = CLLiquidityOperations.getCollectEncoded(2, ZERO_BYTES);
        lpm.modifyLiquidities(collect_calldata_2, block.timestamp + 1);

        uint256 currency0_balance_after = currency0.balanceOfSelf();
        assertEq(currency0_balance_after - currency0_balance_before, dynamic_fee_curreny0_amount);
    }

    function test_swap_with_dynamic_fee_oneForZero() external {
        // set oracle price to 1.2
        defaultOracle.updateAnswer(120 * 10 ** 16);
        uint256 priceX96Oracle = priceFeed.getPriceX96();
        assertEq(uint256(priceX96Oracle), 12 * FixedPoint96.Q96 / 10);

        uint128 liquidity = poolManager.getLiquidity(poolId);
        assertGt(liquidity, 0);

        uint128 swap_amount = 155 ether;
        ICLRouterBase.CLSwapExactInputSingleParams memory params =
            ICLRouterBase.CLSwapExactInputSingleParams(key, false, swap_amount, 0, bytes(""));

        planner = Planner.init().add(Actions.CL_SWAP_EXACT_IN_SINGLE, abi.encode(params));
        bytes memory data = planner.finalizeSwap(key.currency1, key.currency0, ActionConstants.MSG_SENDER);
        uint160 sqrtPriceX96BySimulation = 106972875297741101112193818055;
        uint160 sqrtPriceX96AfterSwap = 80394797207286879964608885004;
        uint24 dynamic_fee = dynamicFeeHook.getDynamicFee(key, sqrtPriceX96BySimulation);
        assertGt(dynamic_fee, 0);
        /*
        Manual verification of dynamic fee calculation process

        price_oracle = 1.2
        price_before = 1 // tick = 0
        price_after = 1.0001 ^ 6005 = 1.8229753555854578 // tick = 6005
        PIF = ABS(price_after/price_before - 1) = 0.8229753555854578
        DFF_MAX = 0.25
        F = 0.0025
        DFF = DFF_MAX * (1 - e^ -(PIF - F) / F) = 0.25
        dynamic_fee = DFF * Min(PIF, 0.2) = 0.25 * 0.2 = 0.05
        */
        assertEq(dynamic_fee, 50000);

        vm.expectEmit(true, true, true, true);
        // Simulation swap event
        emit Swap(
            poolId,
            address(dynamicFeeHook),
            150787838537480690636,
            -155 ether,
            sqrtPriceX96BySimulation,
            10000000000000000000000,
            6005,
            DEFAULT_FEE,
            0
        );
        vm.expectEmit(true, true, true, true);
        // Real swap event
        emit Swap(
            poolId,
            address(infinityRouter),
            145113208012022961886,
            -155 ether,
            sqrtPriceX96AfterSwap,
            10000000000000000000000,
            292,
            dynamic_fee,
            0
        );

        vm.startSnapshotGas("CLOracleDynamicFeeHook#swap_with_dynamic_fee_oneForZero");
        infinityRouter.executeActions(data);
        vm.stopSnapshotGas();

        (uint256 feeGrowthGlobal0x128, uint256 feeGrowthGlobal1x128) = poolManager.getFeeGrowthGlobals(poolId);
        // charge tokenIn fee
        assertEq(feeGrowthGlobal0x128, 0);
        assertGt(feeGrowthGlobal1x128, 0);

        // dynamic_fee_amount = tokenInAmount * dynamic_fee / 1_000_000 - 1;
        // -1 is for calculation precision loss
        uint256 dynamic_fee_curreny1_amount = swap_amount * dynamic_fee / LPFeeLibrary.ONE_HUNDRED_PERCENT_FEE - 1;

        assertEq(dynamic_fee_curreny1_amount, 7749999999999999999);
        uint256 currency1_balance_before = currency1.balanceOfSelf();
        // collect fees
        bytes memory collect_calldata = CLLiquidityOperations.getCollectEncoded(1, ZERO_BYTES);
        lpm.modifyLiquidities(collect_calldata, block.timestamp + 1);
        bytes memory collect_calldata_2 = CLLiquidityOperations.getCollectEncoded(3, ZERO_BYTES);
        lpm.modifyLiquidities(collect_calldata_2, block.timestamp + 1);

        uint256 currency1_balance_after = currency1.balanceOfSelf();
        assertEq(currency1_balance_after - currency1_balance_before, dynamic_fee_curreny1_amount);
    }

    function test_swap_with_dynamic_fee_DFF_not_max_and_PIF_not_max() external {
        // set oracle price to 0.98
        defaultOracle.updateAnswer(98 * 10 ** 16);
        uint256 priceX96Oracle = priceFeed.getPriceX96();
        assertEq(uint256(priceX96Oracle), 98 * FixedPoint96.Q96 / 100);

        uint128 liquidity = poolManager.getLiquidity(poolId);
        assertGt(liquidity, 0);

        uint128 swap_amount = 100 ether;
        ICLRouterBase.CLSwapExactInputSingleParams memory params =
            ICLRouterBase.CLSwapExactInputSingleParams(key, true, swap_amount, 0, bytes(""));

        planner = Planner.init().add(Actions.CL_SWAP_EXACT_IN_SINGLE, abi.encode(params));
        bytes memory data = planner.finalizeSwap(key.currency0, key.currency1, ActionConstants.MSG_SENDER);
        uint160 sqrtPriceX96BySimulation = 78445666986078207473990891197;
        uint160 sqrtPriceX96AfterSwap = 78447537345937897253011017938;
        uint24 dynamic_fee = dynamicFeeHook.getDynamicFee(key, sqrtPriceX96BySimulation);
        assertGt(dynamic_fee, 0);
        /*
        Manual verification of dynamic fee calculation process

        price_oracle = 0.98
        price_before = 1 // tick = 0
        price_after = 1.0001 ^ -199 = 0.9802976734059232 // tick = - 199
        SF = price_after - price_before / price_oracle - price_before = 0.9851163297038381
        IP = 1 - price_oracle / price_before = 0.02
        PIF = SF * IP = 0.0197023265940768
        DFF_MAX = 0.25
        F = 0.0025
        DFF = DFF_MAX * (1 - e^ -(PIF - F) / F) = 0.2497432030848177
        dynamic_fee = DFF * Min(PIF, 0.2) = 0.2497432030848177 * 0.0197023265940768 = 0.004918
        diff = 4918 / 4908 = 0.00203 , 0.2% precision loss 
        */
        assertEq(dynamic_fee, 4908);

        vm.expectEmit(true, true, true, true);
        // Simulation swap event
        emit Swap(
            poolId,
            address(dynamicFeeHook),
            -100 ether,
            98764820911408698235,
            sqrtPriceX96BySimulation,
            10000000000000000000000,
            -199,
            DEFAULT_FEE,
            0
        );
        vm.expectEmit(true, true, true, true);
        // Real swap event
        emit Swap(
            poolId,
            address(infinityRouter),
            -100 ether,
            98528748307888070442,
            sqrtPriceX96AfterSwap,
            10000000000000000000000,
            -199,
            dynamic_fee,
            0
        );
        infinityRouter.executeActions(data);
        (uint256 feeGrowthGlobal0x128, uint256 feeGrowthGlobal1x128) = poolManager.getFeeGrowthGlobals(poolId);
        // charge tokenIn fee
        assertGt(feeGrowthGlobal0x128, 0);
        assertEq(feeGrowthGlobal1x128, 0);

        // dynamic_fee_amount = tokenInAmount * dynamic_fee / 1_000_000 - 1;
        // -1 is for calculation precision loss
        uint256 dynamic_fee_curreny0_amount = swap_amount * dynamic_fee / LPFeeLibrary.ONE_HUNDRED_PERCENT_FEE - 1;
        assertEq(dynamic_fee_curreny0_amount, 490799999999999999);
        uint256 currency0_balance_before = currency0.balanceOfSelf();
        // collect fees
        bytes memory collect_calldata = CLLiquidityOperations.getCollectEncoded(1, ZERO_BYTES);
        lpm.modifyLiquidities(collect_calldata, block.timestamp + 1);
        // bytes memory collect_calldata_2 = CLLiquidityOperations.getCollectEncoded(2, ZERO_BYTES);
        // lpm.modifyLiquidities(collect_calldata_2, block.timestamp + 1);

        uint256 currency0_balance_after = currency0.balanceOfSelf();
        assertEq(currency0_balance_after - currency0_balance_before, dynamic_fee_curreny0_amount);
    }

    function test_oracle_issue_not_affect_hook() external {
        defaultOracle.updateAnswer(80 * 10 ** 16);
        defaultOracle.updateMockOracleIssue(true);
        vm.expectRevert();
        priceFeed.getPriceX96();

        uint128 liquidity = poolManager.getLiquidity(poolId);
        assertGt(liquidity, 0);

        uint128 swap_amount = 170 ether;
        ICLRouterBase.CLSwapExactInputSingleParams memory params =
            ICLRouterBase.CLSwapExactInputSingleParams(key, true, swap_amount, 0, bytes(""));

        planner = Planner.init().add(Actions.CL_SWAP_EXACT_IN_SINGLE, abi.encode(params));
        bytes memory data = planner.finalizeSwap(key.currency0, key.currency1, ActionConstants.MSG_SENDER);

        infinityRouter.executeActions(data);
    }

    // setEmergencyFlag
    function test_setEmergencyFlag() public {
        bool emergencyFlag = dynamicFeeHook.emergencyFlag();
        assertEq(emergencyFlag, false);
        vm.expectEmit(true, true, true, true);
        emit CLOracleDynamicFeeHook.UpdateEmergencyFlag(true);
        dynamicFeeHook.setEmergencyFlag(true);
        emergencyFlag = dynamicFeeHook.emergencyFlag();
        assertEq(emergencyFlag, true);
    }

    receive() external payable {}
}
