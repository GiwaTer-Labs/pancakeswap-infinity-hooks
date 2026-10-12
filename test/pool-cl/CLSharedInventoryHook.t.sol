// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "infinity-core/src/types/PoolId.sol";
import {CLPoolParametersHelper} from "infinity-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";
import {SortTokens} from "infinity-core/test/helpers/SortTokens.sol";
import {Deployers} from "infinity-core/test/pool-cl/helpers/Deployers.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {ICLRouterBase} from "infinity-periphery/src/pool-cl/interfaces/ICLRouterBase.sol";

import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {CLPoolManagerRouter} from "infinity-core/test/pool-cl/helpers/CLPoolManagerRouter.sol";
import {MockCLSwapRouter} from "./helpers/MockCLSwapRouter.sol";
import {CLSharedInventoryHook} from "../../src/pool-cl/shared-inventory/CLSharedInventoryHook.sol";
import {ICLSharedInventoryHook} from "../../src/pool-cl/shared-inventory/interfaces/ICLSharedInventoryHook.sol";

/// @notice Smoke test: the verified BSC SharedInventoryHook still runs its JIT swap lifecycle on the latest
///         infinity-core. The hooked pool has no resident liquidity, so every swap is filled from hook inventory only.
///         A separate hookless pool on the same tokens seeds the vault's balances, as other pools do on mainnet: the
///         hook takes its JIT proceeds in afterSwap, before the swapper's input has been settled.
contract CLSharedInventoryHookTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CLPoolParametersHelper for bytes32;

    uint256 constant INVENTORY = 1_000e18;

    IVault vault;
    ICLPoolManager poolManager;
    MockCLSwapRouter swapRouter;
    CLSharedInventoryHook hook;

    Currency currency0;
    Currency currency1;
    PoolKey key;
    PoolId id;

    function setUp() public {
        (vault, poolManager) = createFreshManager();
        hook = new CLSharedInventoryHook(poolManager, address(this));
        swapRouter = new MockCLSwapRouter(vault, poolManager);

        MockERC20[] memory tokens = deployTokens(2, type(uint256).max);
        (currency0, currency1) = SortTokens.sort(tokens[0], tokens[1]);
        CLPoolManagerRouter lpRouter = new CLPoolManagerRouter(vault, poolManager);
        for (uint256 i; i < 2; i++) {
            tokens[i].approve(address(swapRouter), type(uint256).max);
            tokens[i].approve(address(lpRouter), type(uint256).max);
            tokens[i].transfer(address(hook), INVENTORY);
        }

        key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: hook,
            poolManager: poolManager,
            fee: 2500,
            parameters: bytes32(uint256(hook.getHooksRegistrationBitmap())).setTickSpacing(10)
        });
        id = key.toId();

        PoolKey[] memory keys = new PoolKey[](1);
        keys[0] = key;
        ICLSharedInventoryHook.PoolConfig[] memory cfgs = new ICLSharedInventoryHook.PoolConfig[](1);
        cfgs[0] = ICLSharedInventoryHook.PoolConfig({enabled: true, tickLower: -600, tickUpper: 600, liquidity: 1e21});
        uint160[] memory prices = new uint160[](1);
        prices[0] = SQRT_RATIO_1_1;
        hook.setUninitializePoolConfigs(keys, cfgs, prices, true);

        PoolKey memory seedKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: IHooks(address(0)),
            poolManager: poolManager,
            fee: 500,
            parameters: bytes32(0).setTickSpacing(10)
        });
        poolManager.initialize(seedKey, SQRT_RATIO_1_1);
        lpRouter.modifyPosition(
            seedKey,
            ICLPoolManager.ModifyLiquidityParams({tickLower: -600, tickUpper: 600, liquidityDelta: 1e22, salt: 0}),
            ZERO_BYTES
        );

        hook.setRestrictedPoolCreation(false);
        poolManager.initialize(key, SQRT_RATIO_1_1);
    }

    function _swap(bool zeroForOne, uint128 amountIn) internal {
        swapRouter.exactInputSingle(
            ICLRouterBase.CLSwapExactInputSingleParams({
                poolKey: key,
                zeroForOne: zeroForOne,
                amountIn: amountIn,
                amountOutMinimum: 0,
                hookData: ZERO_BYTES
            }),
            block.timestamp + 1
        );
    }

    function test_swapIsFilledFromInventory() public {
        assertEq(poolManager.getLiquidity(id), 0, "no resident liquidity");

        uint256 out1Before = currency1.balanceOfSelf();
        _swap(true, 1e18);
        uint256 received = currency1.balanceOfSelf() - out1Before;

        assertGt(received, 0, "swapper received token1");
        assertLt(received, 1e18, "fee and price impact applied");
        // The hook was the only liquidity: it gains the token0 sold and pays out the token1 bought.
        assertGt(hook.inventoryOf(currency0), INVENTORY, "token0 inventory grew");
        // mint rounds up / burn rounds down, so the hook may be short a wei or two of the exact payout
        assertApproxEqAbs(hook.inventoryOf(currency1), INVENTORY - received, 2, "token1 inventory paid the swapper");
        assertEq(poolManager.getLiquidity(id), 0, "JIT liquidity removed after swap");
    }

    function test_consecutiveSwapsBothDirections() public {
        _swap(true, 1e18);
        _swap(false, 1e18);
        _swap(true, 5e17);

        assertEq(poolManager.getLiquidity(id), 0, "no JIT liquidity left in the pool");
        // Round trips at a 0.25% fee leave the hook with more combined inventory than it started with.
        assertGt(hook.inventoryOf(currency0) + hook.inventoryOf(currency1), 2 * INVENTORY, "hook earned fees");
    }

}
