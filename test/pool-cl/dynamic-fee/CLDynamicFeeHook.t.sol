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
import {ICLHooks} from "infinity-core/src/pool-cl/interfaces/ICLHooks.sol";
import {CustomRevert} from "infinity-core/src/libraries/CustomRevert.sol";
import {IBinPoolManager} from "infinity-core/src/pool-bin/interfaces/IBinPoolManager.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {CLPoolManager} from "infinity-core/src/pool-cl/CLPoolManager.sol";
import {CLPoolManagerRouter} from "infinity-core/test/pool-cl/helpers/CLPoolManagerRouter.sol";
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
import {FullMath} from "infinity-core/src/pool-cl/libraries/FullMath.sol";
import {CLDynamicFeeHook} from "src/pool-cl/dynamic-fee/CLDynamicFeeHook.sol";

contract CLDynamicFeeHookTest is Test, PosmTestSetup {
    using Planner for Plan;
    using CurrencyLibrary for Currency;

    uint256 public PRICE_PRECISION = 18448130884583730000;

    CLDynamicFeeHook dynamicFeeHook;
    CLDynamicFeeHook dynamicFeeHook1;

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

    // default alpha is 0.5
    uint24 DEFAULT_Alpha = LPFeeLibrary.ONE_HUNDRED_PERCENT_FEE / 2;
    // 0.25% fee
    uint24 DEFAULT_FEE = LPFeeLibrary.ONE_HUNDRED_PERCENT_FEE / 400;
    // MAX DFF 25%
    uint24 MAX_DFF = LPFeeLibrary.ONE_HUNDRED_PERCENT_FEE / 4;

    // infinity version swap event
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

        CLDynamicFeeHook.PoolConfig memory poolConfig =
            CLDynamicFeeHook.PoolConfig({alpha: DEFAULT_Alpha, DFF_max: MAX_DFF, baseLpFee: DEFAULT_FEE});

        dynamicFeeHook = new CLDynamicFeeHook(ICLPoolManager(address(poolManager)), poolConfig);

        dynamicFeeHook1 = new CLDynamicFeeHook(ICLPoolManager(address(poolManager)), poolConfig);

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

    function test_dynamic_fee_hook_defaultPoolConfig() public view {
        (uint24 alpha, uint24 hook_DFF_max, uint24 baseLpFee) = dynamicFeeHook.defaultPoolConfig();
        assertEq(alpha, DEFAULT_Alpha);
        assertEq(hook_DFF_max, MAX_DFF);
        assertEq(baseLpFee, DEFAULT_FEE);
    }

    function test_dynamic_fee_hook_initialization() public view {
        (uint24 alpha, uint24 hook_DFF_max, uint24 baseLpFee) = dynamicFeeHook.poolConfigs(poolId);
        assertEq(alpha, DEFAULT_Alpha);
        assertEq(hook_DFF_max, MAX_DFF);
        assertEq(baseLpFee, DEFAULT_FEE);
    }

    function test_simulate_swap_not_from_hooks_revert() public {
        ICLPoolManager.SwapParams memory params =
            ICLPoolManager.SwapParams({zeroForOne: true, amountSpecified: 0, sqrtPriceLimitX96: 0});
        vm.expectRevert(CLDynamicFeeHook.NotDynamicFeeHook.selector);
        dynamicFeeHook.simulateSwap(key, params, ZERO_BYTES);
    }

    function test_updatePoolConfig_revert_NotDynamicFeePool() public {
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
        CLDynamicFeeHook.PoolConfig memory poolConfig =
            CLDynamicFeeHook.PoolConfig({alpha: DEFAULT_Alpha, DFF_max: MAX_DFF, baseLpFee: DEFAULT_FEE});
        vm.expectRevert(CLDynamicFeeHook.NotDynamicFeePool.selector);
        dynamicFeeHook.updatePoolConfig(key_not_dynamic, poolConfig);
    }

    function test_updatePoolConfig_revert_InvalidDFFMax() public {
        CLDynamicFeeHook.PoolConfig memory poolConfig = CLDynamicFeeHook.PoolConfig({
            alpha: DEFAULT_Alpha,
            DFF_max: LPFeeLibrary.ONE_HUNDRED_PERCENT_FEE,
            baseLpFee: DEFAULT_FEE
        });
        vm.expectRevert(CLDynamicFeeHook.InvalidDFFMax.selector);
        dynamicFeeHook1.updatePoolConfig(key1, poolConfig);
    }

    function test_updatePoolConfig_revert_InvalidBaseLpFee() public {
        CLDynamicFeeHook.PoolConfig memory poolConfig = CLDynamicFeeHook.PoolConfig({
            alpha: DEFAULT_Alpha,
            DFF_max: MAX_DFF,
            baseLpFee: LPFeeLibrary.ONE_HUNDRED_PERCENT_FEE
        });
        vm.expectRevert(CLDynamicFeeHook.InvalidBaseLpFee.selector);
        dynamicFeeHook1.updatePoolConfig(key1, poolConfig);
    }

    function test_updatePoolConfig_revert_BaseLpFee_larger_than_DFF() public {
        CLDynamicFeeHook.PoolConfig memory poolConfig =
            CLDynamicFeeHook.PoolConfig({alpha: DEFAULT_Alpha, DFF_max: MAX_DFF, baseLpFee: (MAX_DFF / 5 + 1)});
        vm.expectRevert(CLDynamicFeeHook.InvalidBaseLpFee.selector);
        dynamicFeeHook1.updatePoolConfig(key1, poolConfig);
    }

    function test_updatePoolConfig_revert_InvalidAlpha() public {
        CLDynamicFeeHook.PoolConfig memory poolConfig = CLDynamicFeeHook.PoolConfig({
            alpha: LPFeeLibrary.ONE_HUNDRED_PERCENT_FEE,
            DFF_max: MAX_DFF,
            baseLpFee: DEFAULT_FEE
        });
        vm.expectRevert(CLDynamicFeeHook.InvalidAlpha.selector);
        dynamicFeeHook1.updatePoolConfig(key1, poolConfig);
    }

    function test_updatePoolConfig_success() public {
        CLDynamicFeeHook.PoolConfig memory poolConfig =
            CLDynamicFeeHook.PoolConfig({alpha: DEFAULT_Alpha, DFF_max: MAX_DFF, baseLpFee: DEFAULT_FEE});
        vm.expectEmit(true, true, true, true);
        emit CLDynamicFeeHook.UpdatePoolConfig(poolId1, DEFAULT_Alpha, MAX_DFF, DEFAULT_FEE);
        dynamicFeeHook1.updatePoolConfig(key1, poolConfig);
        (uint24 alpha, uint24 hook_DFF_max, uint24 baseLpFee) = dynamicFeeHook1.poolConfigs(poolId1);
        assertEq(alpha, DEFAULT_Alpha);
        assertEq(hook_DFF_max, MAX_DFF);
        assertEq(baseLpFee, DEFAULT_FEE);
    }

    function test_afterInitialize_revert_NotDynamicFeePool() public {
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

        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(dynamicFeeHook1),
                ICLHooks.afterInitialize.selector,
                abi.encodeWithSelector(CLDynamicFeeHook.NotDynamicFeePool.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        poolManager.initialize(key_not_dynamic, SQRT_RATIO_1_1);
    }

    function test_first_swap_no_dynamic_fee() external {
        uint128 liquidity = poolManager.getLiquidity(poolId);
        assertGt(liquidity, 0);
        {
            (uint256 weightedVolume, uint256 weightedPriceVolume, uint256 ewVWAPX) =
                dynamicFeeHook.poolEWVWAPParams(poolId);
            assertEq(weightedVolume, 0);
            assertEq(weightedPriceVolume, 0);
            assertEq(ewVWAPX, 0);
        }

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

        infinityRouter.executeActions(data);
        vm.snapshotGasLastCall("swap_no_dynamic_fee_and_no_simulation_swap");
        (uint256 feeGrowthGlobal0x128, uint256 feeGrowthGlobal1x128) = poolManager.getFeeGrowthGlobals(poolId);
        // charge tokenIn fee
        assertGt(feeGrowthGlobal0x128, 0);
        assertEq(feeGrowthGlobal1x128, 0);

        // poolEWVWAPParams was updated after swap
        {
            (uint256 weightedVolume, uint256 weightedPriceVolume, uint256 ewVWAPX) =
                dynamicFeeHook.poolEWVWAPParams(poolId);
            assertGt(weightedVolume, 0);
            assertGt(weightedPriceVolume, 0);
            assertGt(ewVWAPX, 0);
        }
    }

    function testFuzz_swap_with_dynamic_fee(uint128 swap_amount, bool is_zeroForOne) external {
        vm.assume(swap_amount > 0);

        uint128 liquidity = poolManager.getLiquidity(poolId);
        assertGt(liquidity, 0);

        // execute first swap which is no dynamic fee
        executeOneSwap(1 ether, true);

        ICLRouterBase.CLSwapExactInputSingleParams memory params =
            ICLRouterBase.CLSwapExactInputSingleParams(key, is_zeroForOne, swap_amount, 0, bytes(""));

        planner = Planner.init().add(Actions.CL_SWAP_EXACT_IN_SINGLE, abi.encode(params));
        Currency currencyIn = is_zeroForOne ? key.currency0 : key.currency1;
        Currency currencyOut = is_zeroForOne ? key.currency1 : key.currency0;
        bytes memory data = planner.finalizeSwap(currencyIn, currencyOut, ActionConstants.MSG_SENDER);

        infinityRouter.executeActions(data);
    }

    function test_swap_with_dynamic_fee_zeroForOne() external {
        uint128 liquidity = poolManager.getLiquidity(poolId);
        assertGt(liquidity, 0);

        // execute first swap which is no dynamic fee
        executeOneSwap(1 ether, true);
        executeOneSwap(1 ether, true);
        // collect fees
        bytes memory collect_calldata = CLLiquidityOperations.getCollectEncoded(1, ZERO_BYTES);
        lpm.modifyLiquidities(collect_calldata, block.timestamp + 1);
        bytes memory collect_calldata_2 = CLLiquidityOperations.getCollectEncoded(2, ZERO_BYTES);
        lpm.modifyLiquidities(collect_calldata_2, block.timestamp + 1);

        (,, uint256 ewVWAPX) = dynamicFeeHook.poolEWVWAPParams(poolId);
        (uint160 sqrtPriceX96Before,,,) = poolManager.getSlot0(poolId);
        uint256 priceXBefore = FullMath.mulDiv(sqrtPriceX96Before, sqrtPriceX96Before, PRICE_PRECISION);
        // swap isZeroForOne is true , so it means priceAfter is smaller than priceBefore
        // so only when ewVWAPX is bigger than priceXBefore, the dynamic fee will be charged
        assertGt(ewVWAPX, priceXBefore);

        uint128 swap_amount = 155 ether;
        ICLRouterBase.CLSwapExactInputSingleParams memory params =
            ICLRouterBase.CLSwapExactInputSingleParams(key, true, swap_amount, 0, bytes(""));

        planner = Planner.init().add(Actions.CL_SWAP_EXACT_IN_SINGLE, abi.encode(params));
        bytes memory data = planner.finalizeSwap(key.currency0, key.currency1, ActionConstants.MSG_SENDER);
        uint160 sqrtPriceX96BySimulation = 58670708510157175741874621487;
        uint160 sqrtPriceX96AfterSwap = 78063109634523885859040697448;
        uint24 dynamic_fee = dynamicFeeHook.getDynamicFee(key, sqrtPriceX96BySimulation);
        assertGt(dynamic_fee, 0);

        assertEq(dynamic_fee, 50000);

        vm.expectEmit(true, true, true, true);
        // Simulation swap event
        emit Swap(
            poolId,
            address(dynamicFeeHook),
            -155 ether,
            149887420973743618291,
            sqrtPriceX96BySimulation,
            10000000000000000000000,
            -6009,
            DEFAULT_FEE,
            0
        );
        vm.expectEmit(true, true, true, true);
        // Real swap event
        emit Swap(
            poolId,
            address(infinityRouter),
            -155 ether,
            145055745017898236407,
            sqrtPriceX96AfterSwap,
            10000000000000000000000,
            -297,
            dynamic_fee,
            0
        );

        infinityRouter.executeActions(data);
        vm.snapshotGasLastCall("swap_with_dynamic_fee_zeroForOne");

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
        lpm.modifyLiquidities(collect_calldata, block.timestamp + 1);
        lpm.modifyLiquidities(collect_calldata_2, block.timestamp + 1);

        uint256 currency0_balance_after = currency0.balanceOfSelf();
        assertEq(currency0_balance_after - currency0_balance_before, dynamic_fee_curreny0_amount);
    }

    function test_swap_with_dynamic_fee_oneForZero() external {
        uint128 liquidity = poolManager.getLiquidity(poolId);
        assertGt(liquidity, 0);

        // execute first swap which is no dynamic fee
        executeOneSwap(1 ether, false);
        executeOneSwap(1 ether, false);
        // collect fees
        bytes memory collect_calldata = CLLiquidityOperations.getCollectEncoded(1, ZERO_BYTES);
        lpm.modifyLiquidities(collect_calldata, block.timestamp + 1);
        bytes memory collect_calldata_2 = CLLiquidityOperations.getCollectEncoded(3, ZERO_BYTES);
        lpm.modifyLiquidities(collect_calldata_2, block.timestamp + 1);

        (,, uint256 ewVWAPX) = dynamicFeeHook.poolEWVWAPParams(poolId);
        (uint160 sqrtPriceX96Before,,,) = poolManager.getSlot0(poolId);
        uint256 priceXBefore = FullMath.mulDiv(sqrtPriceX96Before, sqrtPriceX96Before, PRICE_PRECISION);
        // swap isZeroForOne is false , so it means priceAfter is bigger than priceBefore
        // so only when ewVWAPX is smaller than priceXBefore, the dynamic fee will be charged
        assertLt(ewVWAPX, priceXBefore);

        uint128 swap_amount = 155 ether;
        ICLRouterBase.CLSwapExactInputSingleParams memory params =
            ICLRouterBase.CLSwapExactInputSingleParams(key, false, swap_amount, 0, bytes(""));

        planner = Planner.init().add(Actions.CL_SWAP_EXACT_IN_SINGLE, abi.encode(params));
        bytes memory data = planner.finalizeSwap(key.currency1, key.currency0, ActionConstants.MSG_SENDER);
        uint160 sqrtPriceX96BySimulation = 106988681316162696847543730073;
        uint160 sqrtPriceX96AfterSwap = 80410603225708475699958797022;
        uint24 dynamic_fee = dynamicFeeHook.getDynamicFee(key, sqrtPriceX96BySimulation);
        assertGt(dynamic_fee, 0);

        assertEq(dynamic_fee, 50000);

        vm.expectEmit(true, true, true, true);
        // Simulation swap event
        emit Swap(
            poolId,
            address(dynamicFeeHook),
            149887420973743618291,
            -155 ether,
            sqrtPriceX96BySimulation,
            10000000000000000000000,
            6008,
            DEFAULT_FEE,
            0
        );
        vm.expectEmit(true, true, true, true);
        // Real swap event
        emit Swap(
            poolId,
            address(infinityRouter),
            145055745017898236407,
            -155 ether,
            sqrtPriceX96AfterSwap,
            10000000000000000000000,
            296,
            dynamic_fee,
            0
        );

        infinityRouter.executeActions(data);
        vm.snapshotGasLastCall("swap_with_dynamic_fee_oneForZero");

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
        lpm.modifyLiquidities(collect_calldata, block.timestamp + 1);
        lpm.modifyLiquidities(collect_calldata_2, block.timestamp + 1);

        uint256 currency1_balance_after = currency1.balanceOfSelf();
        assertEq(currency1_balance_after - currency1_balance_before, dynamic_fee_curreny1_amount);
    }

    function test_swap_with_dynamic_fee_DFF_not_max_and_PIF_not_max() external {
        uint128 liquidity = poolManager.getLiquidity(poolId);
        assertGt(liquidity, 0);

        // execute first swap which is no dynamic fee
        executeOneSwap(1 ether, true);
        executeOneSwap(1 ether, true);

        bytes memory collect_calldata = CLLiquidityOperations.getCollectEncoded(1, ZERO_BYTES);
        lpm.modifyLiquidities(collect_calldata, block.timestamp + 1);
        bytes memory collect_calldata_2 = CLLiquidityOperations.getCollectEncoded(2, ZERO_BYTES);
        lpm.modifyLiquidities(collect_calldata_2, block.timestamp + 1);

        uint128 swap_amount = 100 ether;
        ICLRouterBase.CLSwapExactInputSingleParams memory params =
            ICLRouterBase.CLSwapExactInputSingleParams(key, true, swap_amount, 0, bytes(""));

        planner = Planner.init().add(Actions.CL_SWAP_EXACT_IN_SINGLE, abi.encode(params));
        bytes memory data = planner.finalizeSwap(key.currency0, key.currency1, ActionConstants.MSG_SENDER);
        uint160 sqrtPriceX96BySimulation = 78430174701761267576585976321;
        uint160 sqrtPriceX96AfterSwap = 78432043546488751772885896151;
        uint24 dynamic_fee = dynamicFeeHook.getDynamicFee(key, sqrtPriceX96BySimulation);
        assertGt(dynamic_fee, 0);

        assertEq(dynamic_fee, 4907);

        vm.expectEmit(true, true, true, true);
        // Simulation swap event
        emit Swap(
            poolId,
            address(dynamicFeeHook),
            -100 ether,
            98725620023355435648,
            sqrtPriceX96BySimulation,
            10000000000000000000000,
            -203,
            DEFAULT_FEE,
            0
        );
        vm.expectEmit(true, true, true, true);
        // Real swap event
        emit Swap(
            poolId,
            address(infinityRouter),
            -100 ether,
            98489738656404923934,
            sqrtPriceX96AfterSwap,
            10000000000000000000000,
            -202,
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
        assertEq(dynamic_fee_curreny0_amount, 490699999999999999);
        uint256 currency0_balance_before = currency0.balanceOfSelf();
        // collect fees
        lpm.modifyLiquidities(collect_calldata, block.timestamp + 1);
        lpm.modifyLiquidities(collect_calldata_2, block.timestamp + 1);

        uint256 currency0_balance_after = currency0.balanceOfSelf();
        assertEq(currency0_balance_after - currency0_balance_before, dynamic_fee_curreny0_amount);
    }

    function test_updatePoolConfig_afterPoolInitialized() public {
        (uint24 alpha_old, uint24 hook_DFF_max_old, uint24 baseLpFee_old) = dynamicFeeHook.poolConfigs(poolId);
        assertEq(alpha_old, DEFAULT_Alpha);
        assertEq(hook_DFF_max_old, MAX_DFF);
        assertEq(baseLpFee_old, DEFAULT_FEE);
        (,,, uint24 lpFee_old) = poolManager.getSlot0(poolId);
        assertEq(lpFee_old, DEFAULT_FEE);

        uint24 newLPFee = DEFAULT_FEE + 1000;
        uint24 newAlpha = DEFAULT_Alpha + 1000;
        uint24 newDFF = MAX_DFF + 1000;
        CLDynamicFeeHook.PoolConfig memory poolConfig =
            CLDynamicFeeHook.PoolConfig({alpha: newAlpha, DFF_max: newDFF, baseLpFee: newLPFee});
        vm.expectEmit(true, true, true, true);
        emit CLDynamicFeeHook.UpdatePoolConfig(poolId, newAlpha, newDFF, newLPFee);
        dynamicFeeHook.updatePoolConfig(key, poolConfig);
        (uint24 alpha, uint24 hook_DFF_max, uint24 baseLpFee) = dynamicFeeHook.poolConfigs(poolId);
        assertEq(alpha, newAlpha);
        assertEq(hook_DFF_max, newDFF);
        assertEq(baseLpFee, newLPFee);
        (,,, uint24 lpFee) = poolManager.getSlot0(poolId);
        assertEq(lpFee, newLPFee);
    }

    function test_updateDefaultPoolConfig() public {
        (uint24 alpha_old, uint24 hook_DFF_max_old, uint24 baseLpFee_old) = dynamicFeeHook.defaultPoolConfig();
        assertEq(alpha_old, DEFAULT_Alpha);
        assertEq(hook_DFF_max_old, MAX_DFF);
        assertEq(baseLpFee_old, DEFAULT_FEE);

        uint24 newLPFee = DEFAULT_FEE + 1000;
        uint24 newAlpha = DEFAULT_Alpha + 1000;
        uint24 newDFF = MAX_DFF + 1000;
        CLDynamicFeeHook.PoolConfig memory poolConfig =
            CLDynamicFeeHook.PoolConfig({alpha: newAlpha, DFF_max: newDFF, baseLpFee: newLPFee});
        vm.expectEmit(true, true, true, true);
        emit CLDynamicFeeHook.UpdateDefaultPoolConfig(newAlpha, newDFF, newLPFee);
        dynamicFeeHook.updateDefaultPoolConfig(poolConfig);
        (uint24 alpha, uint24 hook_DFF_max, uint24 baseLpFee) = dynamicFeeHook.defaultPoolConfig();
        assertEq(alpha, newAlpha);
        assertEq(hook_DFF_max, newDFF);
        assertEq(baseLpFee, newLPFee);
    }

    function test_setEmergencyFlag() public {
        bool emergencyFlag = dynamicFeeHook.emergencyFlag();
        assertEq(emergencyFlag, false);
        vm.expectEmit(true, true, true, true);
        emit CLDynamicFeeHook.UpdateEmergencyFlag(true);
        dynamicFeeHook.setEmergencyFlag(true);
        emergencyFlag = dynamicFeeHook.emergencyFlag();
        assertEq(emergencyFlag, true);
    }

    function test_getDynamicFee_revert_PoolNotInitialized() public {
        PoolKey memory key_not_initialized = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: dynamicFeeHook,
            poolManager: poolManager,
            fee: DEFAULT_FEE,
            parameters: CLPoolParametersHelper.setTickSpacing(
                bytes32(uint256(dynamicFeeHook.getHooksRegistrationBitmap())), 10
            )
        });
        vm.expectRevert(CLDynamicFeeHook.PoolNotInitialized.selector);
        dynamicFeeHook.getDynamicFee(key_not_initialized, 0);
    }

    function executeOneSwap(uint128 amountIn, bool zeroForOne) internal {
        ICLRouterBase.CLSwapExactInputSingleParams memory params =
            ICLRouterBase.CLSwapExactInputSingleParams(key, zeroForOne, amountIn, 0, bytes(""));

        planner = Planner.init().add(Actions.CL_SWAP_EXACT_IN_SINGLE, abi.encode(params));
        bytes memory data = planner.finalizeSwap(
            zeroForOne ? key.currency0 : key.currency1,
            zeroForOne ? key.currency1 : key.currency0,
            ActionConstants.MSG_SENDER
        );
        infinityRouter.executeActions(data);
    }

    receive() external payable {}
}
