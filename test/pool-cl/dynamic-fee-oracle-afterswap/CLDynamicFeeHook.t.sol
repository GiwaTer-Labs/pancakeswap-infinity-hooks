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
import {CLOracleAfterSwapDynamicFeeHook} from "src/pool-cl/dynamic-fee-oracle-afterswap/CLOracleAfterSwapDynamicFeeHook.sol";
import {IPriceFeed} from "src/pool-cl/dynamic-fee-oracle-afterswap/interfaces/IPriceFeed.sol";
import {PriceFeed} from "src/pool-cl/dynamic-fee-oracle-afterswap/PriceFeed.sol";
import {MockAggregatorV3} from "test/pool-cl/dynamic-fee-oracle-afterswap/helpers/MockAggregatorV3.sol";
// import "forge-std/console2.sol";

contract CLDynamicFeeHookTest is Test, PosmTestSetup {
    using Planner for Plan;
    using CurrencyLibrary for Currency;

    MockAggregatorV3 defaultOracle;
    PriceFeed priceFeed;
    CLOracleAfterSwapDynamicFeeHook dynamicFeeHook;

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
    address hookOwner = makeAddr("HOOK_OWNER");

    // 0.25% fee
    uint24 DEFAULT_FEE = LPFeeLibrary.ONE_HUNDRED_PERCENT_FEE / 400;
    // MAX DFF 5%
    uint24 MAX_DFF = LPFeeLibrary.ONE_HUNDRED_PERCENT_FEE / 20;

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
        dynamicFeeHook = new CLOracleAfterSwapDynamicFeeHook(ICLPoolManager(address(poolManager)));

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
        bytes memory initializeHookData = dynamicFeeHook.generateInitializeHookData(priceFeed, MAX_DFF, DEFAULT_FEE);
        dynamicFeeHook.initializePool(key, SQRT_RATIO_1_1, initializeHookData);

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
            hooks: IHooks(address(0)),
            poolManager: poolManager,
            fee: DEFAULT_FEE,
            parameters: CLPoolParametersHelper.setTickSpacing(bytes32(0), 10)
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

    function test_dynamic_fee_hook_initialization() public view {
        (IPriceFeed priceFeedContract, uint24 hook_DFF_max, uint24 baseLpFee) = dynamicFeeHook.poolConfigs(poolId);
        assertEq(address(priceFeedContract), address(priceFeed));
        assertEq(hook_DFF_max, MAX_DFF);
        assertEq(baseLpFee, DEFAULT_FEE);
    }

    function test_swap_no_DFF() external {
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
        infinityRouter.executeActions(data);
        (uint256 feeGrowthGlobal0x128, uint256 feeGrowthGlobal1x128) = poolManager.getFeeGrowthGlobals(poolId);
        // charge tokenIn fee
        assertGt(feeGrowthGlobal0x128, 0);
        assertEq(feeGrowthGlobal1x128, 0);
    }

    function test_swap_dynamic_fee() external {
        // set oracle price to 0.97
        defaultOracle.updateAnswer(97 * 10 ** 16);

        uint128 liquidity = poolManager.getLiquidity(poolId);
        assertGt(liquidity, 0);

        ICLRouterBase.CLSwapExactInputSingleParams memory params =
            ICLRouterBase.CLSwapExactInputSingleParams(key, true, 180 ether, 0, bytes(""));

        planner = Planner.init().add(Actions.CL_SWAP_EXACT_IN_SINGLE, abi.encode(params));
        bytes memory data = planner.finalizeSwap(key.currency0, key.currency1, ActionConstants.MSG_SENDER);
        uint160 sqrtPriceX96AfterSwap = 4295128740;
        uint24 dynamic_fee = dynamicFeeHook.getDynamicFee(key, sqrtPriceX96AfterSwap);
        assertGt(dynamic_fee, 0);
        assertEq(dynamic_fee, 49999);

        int128 tokenOut = 148873216119575134690;

        vm.expectEmit(true, true, true, true);
        emit Swap(
            poolId,
            address(infinityRouter),
            -151501787789050894882,
            tokenOut,
            sqrtPriceX96AfterSwap,
            0,
            -887272,
            DEFAULT_FEE,
            0
        );
        infinityRouter.executeActions(data);
        (uint256 feeGrowthGlobal0x128, uint256 feeGrowthGlobal1x128) = poolManager.getFeeGrowthGlobals(poolId);
        // charge tokenIn fee
        assertGt(feeGrowthGlobal0x128, 0);
        assertEq(feeGrowthGlobal1x128, 0);
        uint256 dynamicFeeInHook = currency1.balanceOf(address(dynamicFeeHook));
        uint256 dynamicFeeAmount = uint256(uint128(tokenOut)) * dynamic_fee / LPFeeLibrary.ONE_HUNDRED_PERCENT_FEE;
        assertEq(dynamicFeeInHook, dynamicFeeAmount);
    }

    function test_collect_swap_dynamic_fee() external {
        // set oracle price to 0.97
        defaultOracle.updateAnswer(97 * 10 ** 16);

        uint128 liquidity = poolManager.getLiquidity(poolId);
        assertGt(liquidity, 0);

        ICLRouterBase.CLSwapExactInputSingleParams memory params =
            ICLRouterBase.CLSwapExactInputSingleParams(key, true, 180 ether, 0, bytes(""));

        planner = Planner.init().add(Actions.CL_SWAP_EXACT_IN_SINGLE, abi.encode(params));
        bytes memory data = planner.finalizeSwap(key.currency0, key.currency1, ActionConstants.MSG_SENDER);
        uint160 sqrtPriceX96AfterSwap = 4295128740;
        uint24 dynamic_fee = dynamicFeeHook.getDynamicFee(key, sqrtPriceX96AfterSwap);
        assertGt(dynamic_fee, 0);
        assertEq(dynamic_fee, 49999);

        int128 tokenOut = 148873216119575134690;

        vm.expectEmit(true, true, true, true);
        emit Swap(
            poolId,
            address(infinityRouter),
            -151501787789050894882,
            tokenOut,
            sqrtPriceX96AfterSwap,
            0,
            -887272,
            DEFAULT_FEE,
            0
        );
        infinityRouter.executeActions(data);
        (uint256 feeGrowthGlobal0x128, uint256 feeGrowthGlobal1x128) = poolManager.getFeeGrowthGlobals(poolId);
        // charge tokenIn fee
        assertGt(feeGrowthGlobal0x128, 0);
        assertEq(feeGrowthGlobal1x128, 0);
        uint256 dynamicFeeInHook = currency1.balanceOf(address(dynamicFeeHook));
        uint256 dynamicFeeAmount = uint256(uint128(tokenOut)) * dynamic_fee / LPFeeLibrary.ONE_HUNDRED_PERCENT_FEE;
        assertEq(dynamicFeeInHook, dynamicFeeAmount);

        dynamicFeeHook.transferOwnership(hookOwner);
        vm.startPrank(hookOwner);
        uint256 hookOwnerCurreny1BalanceBefore = currency1.balanceOf(hookOwner);
        assertEq(hookOwnerCurreny1BalanceBefore, 0);
        dynamicFeeHook.collectDynamicFee(currency1);
        uint256 hookOwnerCurreny1BalanceAfter = currency1.balanceOf(hookOwner);
        assertEq(hookOwnerCurreny1BalanceAfter, dynamicFeeAmount);
    }

    // allow refund of ETH
    receive() external payable {}
}
