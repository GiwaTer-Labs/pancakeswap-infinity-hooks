// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {ILockCallback} from "infinity-core/src/interfaces/ILockCallback.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "infinity-core/src/types/PoolId.sol";
import {BalanceDelta} from "infinity-core/src/types/BalanceDelta.sol";
import {TickMath} from "infinity-core/src/pool-cl/libraries/TickMath.sol";
import {CLPoolParametersHelper} from "infinity-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";
import {SortTokens} from "infinity-core/test/helpers/SortTokens.sol";
import {Deployers} from "infinity-core/test/pool-cl/helpers/Deployers.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";

import {CLSharedInventoryHook} from "../../src/pool-cl/shared-inventory/CLSharedInventoryHook.sol";
import {ICLSharedInventoryHook} from "../../src/pool-cl/shared-inventory/interfaces/ICLSharedInventoryHook.sol";

/// @dev Minimal swap entry point: one swap per vault lock, swapper side settled from `payer`. Records whether the
///      hook's own vault deltas were already zero right after `swap` returned (i.e. the hook closed its books
///      inside its callbacks). Price limit is +-1200 ticks so a drained range never runs the price to the extremes.
contract SecSwapper is ILockCallback {
    IVault public immutable vault;
    ICLPoolManager public immutable pm;
    address public immutable hook;
    bool public hookDeltaClean;

    constructor(IVault _vault, ICLPoolManager _pm, address _hook) {
        vault = _vault;
        pm = _pm;
        hook = _hook;
    }

    function swap(PoolKey memory key, bool zeroForOne, int256 amountSpecified) external returns (BalanceDelta) {
        return abi.decode(vault.lock(abi.encode(key, zeroForOne, amountSpecified, msg.sender)), (BalanceDelta));
    }

    function lockAcquired(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(vault), "not vault");
        (PoolKey memory key, bool z, int256 amt, address payer) = abi.decode(data, (PoolKey, bool, int256, address));
        BalanceDelta d = pm.swap(
            key,
            ICLPoolManager.SwapParams({
                zeroForOne: z,
                amountSpecified: amt,
                sqrtPriceLimitX96: TickMath.getSqrtRatioAtTick(z ? -1200 : int24(1200))
            }),
            ""
        );
        hookDeltaClean = vault.currencyDelta(hook, key.currency0) == 0 && vault.currencyDelta(hook, key.currency1) == 0;
        _resolve(key.currency0, d.amount0(), payer);
        _resolve(key.currency1, d.amount1(), payer);
        return abi.encode(d);
    }

    function _resolve(Currency c, int128 a, address payer) internal {
        if (a < 0) {
            vault.sync(c);
            MockERC20(Currency.unwrap(c)).transferFrom(payer, address(vault), uint128(-a));
            vault.settle();
        } else if (a > 0) {
            vault.take(c, payer, uint128(a));
        }
    }
}

/// @dev Token whose transfers can be frozen (pause / blacklist stand-in).
contract FreezableToken is MockERC20 {
    bool public frozen;

    constructor() MockERC20("FRZ", "FRZ", 18) {}

    function setFrozen(bool f) external {
        frozen = f;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        require(!frozen, "FROZEN");
        return super.transfer(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        require(!frozen, "FROZEN");
        return super.transferFrom(from, to, amount);
    }
}

/// @dev Token that, once armed, makes one arbitrary call when tokens are transferred TO `watch` (i.e. while the
///      vault pays the hook inside afterSwap) and records the outcome.
contract ReentrantToken is MockERC20 {
    address public watch;
    address public target;
    bytes public payload;
    bool public armed;
    bool public fired;
    bool public callOk;
    bytes public callRet;

    constructor() MockERC20("EVIL", "EVIL", 18) {}

    function arm(address _watch, address _target, bytes calldata _payload) external {
        (watch, target, payload, armed, fired) = (_watch, _target, _payload, true, false);
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        bool r = super.transfer(to, amount);
        if (armed && to == watch) {
            armed = false;
            fired = true;
            (callOk, callRet) = target.call(payload);
        }
        return r;
    }
}

/// @dev Stand-in for any contract a whitelisted creator might be lured into calling.
contract Phisher {
    function claimAirdrop(ICLPoolManager pm, PoolKey calldata key, uint160 sqrtPriceX96) external {
        pm.initialize(key, sqrtPriceX96);
    }
}

/// @notice Adversarial / invariant suite for CLSharedInventoryHook on the pinned infinity-core.
/// @dev Pools: P1 (A,B), P2 (A,C), P3 (B,C) — A is shared by P1 and P2, every token by two pools. No pool has
///      resident liquidity; every swap is filled by the hook's JIT position only. The vault is pre-seeded with a
///      plain token transfer of each token so the hook's in-afterSwap `take` is backed by physical balance (on a
///      live chain other pools' reserves play that role).
contract CLSharedInventoryHookSecurityTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CLPoolParametersHelper for bytes32;

    uint256 constant INVENTORY = 1_000e18;
    uint128 constant L = 1e21;
    int24 constant LOWER = -600;
    int24 constant UPPER = 600;
    bytes32 constant SALT = 0x2dd421f327b24150303d8f1213699124a1c7bb24e1d9d96ac0280c16e513b260;

    IVault vault;
    ICLPoolManager poolManager;
    CLSharedInventoryHook hook;
    SecSwapper swapper;

    MockERC20 tA;
    MockERC20 tB;
    MockERC20 tC;
    PoolKey p1;
    PoolKey p2;
    PoolKey p3;

    address CREATOR = makeAddr("creator");
    address TREASURY = makeAddr("treasury");
    address ATTACKER = makeAddr("attacker");

    function setUp() public {
        (vault, poolManager) = createFreshManager();
        hook = new CLSharedInventoryHook(poolManager, address(this));
        swapper = new SecSwapper(vault, poolManager, address(hook));

        MockERC20[] memory ts = deployTokens(3, type(uint256).max);
        (tA, tB, tC) = (ts[0], ts[1], ts[2]);
        for (uint256 i; i < 3; i++) _fund(ts[i]);

        address[] memory who = new address[](1);
        bool[] memory yes = new bool[](1);
        yes[0] = true;
        who[0] = CREATOR;
        hook.setPoolCreator(who, yes);
        who[0] = TREASURY;
        hook.setWithdrawRecipient(who, yes);

        p1 = _createPool(tA, tB, 2500, L);
        p2 = _createPool(tA, tC, 2500, L);
        p3 = _createPool(tB, tC, 2500, L);
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _fund(MockERC20 t) internal {
        t.approve(address(swapper), type(uint256).max);
        t.transfer(address(hook), INVENTORY);
        t.transfer(address(vault), 1e27);
    }

    function _cfg(int24 lo, int24 hi, uint128 liq) internal pure returns (ICLSharedInventoryHook.PoolConfig memory) {
        return ICLSharedInventoryHook.PoolConfig({enabled: true, tickLower: lo, tickUpper: hi, liquidity: liq});
    }

    function _keyFor(MockERC20 a, MockERC20 b, uint24 fee) internal view returns (PoolKey memory k) {
        (Currency c0, Currency c1) = SortTokens.sort(a, b);
        k = PoolKey({
            currency0: c0,
            currency1: c1,
            hooks: IHooks(address(hook)),
            poolManager: poolManager,
            fee: fee,
            parameters: bytes32(uint256(hook.getHooksRegistrationBitmap())).setTickSpacing(10)
        });
    }

    function _preconfig(PoolKey memory k, ICLSharedInventoryHook.PoolConfig memory c, uint160 price) internal {
        PoolKey[] memory keys = new PoolKey[](1);
        keys[0] = k;
        ICLSharedInventoryHook.PoolConfig[] memory cfgs = new ICLSharedInventoryHook.PoolConfig[](1);
        cfgs[0] = c;
        uint160[] memory prices = new uint160[](1);
        prices[0] = price;
        hook.setUninitializePoolConfigs(keys, cfgs, prices, false);
    }

    function _setConfig(PoolKey memory k, ICLSharedInventoryHook.PoolConfig memory c) internal {
        PoolId[] memory ids = new PoolId[](1);
        ids[0] = k.toId();
        ICLSharedInventoryHook.PoolConfig[] memory cfgs = new ICLSharedInventoryHook.PoolConfig[](1);
        cfgs[0] = c;
        uint256[] memory mx = new uint256[](1);
        mx[0] = type(uint256).max;
        hook.setPoolConfigs(ids, cfgs, false, mx, mx);
    }

    function _createPool(MockERC20 a, MockERC20 b, uint24 fee, uint128 liq) internal returns (PoolKey memory k) {
        k = _keyFor(a, b, fee);
        _preconfig(k, _cfg(LOWER, UPPER, liq), SQRT_RATIO_1_1);
        vm.prank(CREATOR, CREATOR);
        poolManager.initialize(k, SQRT_RATIO_1_1);
    }

    function _swap(PoolKey memory k, bool zeroForOne, int256 amount) internal returns (BalanceDelta) {
        return swapper.swap(k, zeroForOne, amount);
    }

    function _bal(Currency c) internal view returns (uint256) {
        return hook.inventoryOf(c);
    }

    function _posL(PoolKey memory k, int24 lo, int24 hi) internal view returns (uint128) {
        return poolManager.getLiquidity(k.toId(), address(hook), lo, hi, SALT);
    }

    function _pendingL() internal view returns (uint128) {
        (, ICLSharedInventoryHook.PoolConfig memory c) = hook.pendingRemoval();
        return c.liquidity;
    }

    function _removalCall(PoolKey memory k, ICLSharedInventoryHook.PoolConfig memory c)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodeCall(
            ICLPoolManager.modifyLiquidity,
            (
                k,
                ICLPoolManager.ModifyLiquidityParams({
                    tickLower: c.tickLower,
                    tickUpper: c.tickUpper,
                    liquidityDelta: -int256(uint256(c.liquidity)),
                    salt: SALT
                }),
                ""
            )
        );
    }

    /// @dev Drive the REAL catch branch of afterSwap: make exactly the removal call revert (the injection call has
    ///      different calldata and is untouched), swap, then lift the mock. On the pinned core nothing else reaches
    ///      that branch (see the gas-griefing test), so this only substitutes the cause, not the handling.
    function _forceDeferredSwap(PoolKey memory k, bool zeroForOne, int256 amount) internal returns (BalanceDelta d) {
        vm.mockCallRevert(address(poolManager), _removalCall(k, hook.getPoolConfig(k.toId())), "forced");
        d = _swap(k, zeroForOne, amount);
        vm.clearMockedCalls();
    }

    function _contains(bytes memory hay, bytes4 sel) internal pure returns (bool) {
        if (hay.length < 4) return false;
        for (uint256 i; i + 4 <= hay.length; i++) {
            if (hay[i] == sel[0] && hay[i + 1] == sel[1] && hay[i + 2] == sel[2] && hay[i + 3] == sel[3]) return true;
        }
        return false;
    }

    function _one(Currency c) internal pure returns (Currency[] memory a) {
        a = new Currency[](1);
        a[0] = c;
    }

    function _one(uint256 v) internal pure returns (uint256[] memory a) {
        a = new uint256[](1);
        a[0] = v;
    }

    /// @dev Is token A currency0 of `k`? Used to pick the direction that sells / buys A.
    function _aIs0(PoolKey memory k) internal view returns (bool) {
        return Currency.unwrap(k.currency0) == address(tA);
    }

    /*//////////////////////////////////////////////////////////////
                         1. HAPPY PATH
    //////////////////////////////////////////////////////////////*/

    /// Several swaps, both directions, on P1 and P2 (sharing A). After each: no live hook position, hook deltas
    /// closed inside the swap, inventory change == mirror of the swapper's flow (within mint/burn rounding), and the
    /// swapper's input-side LP fee is reported via FeesEarned.
    function test_happyPath_sharedCurrencyAcrossTwoPools() public {
        PoolKey[4] memory ks = [p1, p2, p1, p2];
        bool[4] memory dirs = [true, false, false, true];
        int256[4] memory amts = [int256(-5e18), -3e18, int256(4e18), -2e18]; // last-but-one is exact-out
        for (uint256 i; i < 4; i++) {
            PoolKey memory k = ks[i];
            uint256 h0 = _bal(k.currency0);
            uint256 h1 = _bal(k.currency1);

            vm.expectEmit(true, false, false, false, address(hook));
            emit ICLSharedInventoryHook.FeesEarned(k.toId(), 0, 0);
            BalanceDelta d = _swap(k, dirs[i], amts[i]);

            assertTrue(swapper.hookDeltaClean(), "hook delta open at end of swap");
            assertEq(_posL(k, LOWER, UPPER), 0, "JIT position left live");
            assertEq(_pendingL(), 0, "unexpected deferral");
            int256 dh0 = int256(_bal(k.currency0)) - int256(h0);
            int256 dh1 = int256(_bal(k.currency1)) - int256(h1);
            // hook gets what the swapper pays and pays what the swapper gets, minus <=2 wei rounding per side
            assertApproxEqAbs(dh0, -int256(d.amount0()), 2, "token0 mirror");
            assertApproxEqAbs(dh1, -int256(d.amount1()), 2, "token1 mirror");
            assertLe(dh0 + d.amount0(), 0, "hook never gains more than swapper pays (0)");
            assertLe(dh1 + d.amount1(), 0, "hook never gains more than swapper pays (1)");
        }
        // round trips at 0.25% leave combined inventory up
        uint256 total = tA.balanceOf(address(hook)) + tB.balanceOf(address(hook)) + tC.balanceOf(address(hook));
        assertGt(total, 3 * INVENTORY, "fees accrued to shared inventory");
    }

    /*//////////////////////////////////////////////////////////////
                         2. FUZZ INVARIANTS
    //////////////////////////////////////////////////////////////*/

    /// Random sequences over P1/P2/P3 with floors on every token. After every successful swap: every token at or
    /// above its floor, no deferred record, no hook position left in any pool, hook deltas closed in-lock.
    /// A reverting swap must revert for an expected reason only.
    function testFuzz_randomSwapSequence_invariantsHold(uint256 seed) public {
        uint256 floor = 985e18;
        Currency[] memory cs = new Currency[](3);
        (cs[0], cs[1], cs[2]) =
            (Currency.wrap(address(tA)), Currency.wrap(address(tB)), Currency.wrap(address(tC)));
        uint256[] memory fl = new uint256[](3);
        (fl[0], fl[1], fl[2]) = (floor, floor, floor);
        hook.setMinSharedReserve(cs, fl);

        PoolKey[3] memory ks = [p1, p2, p3];
        uint256 ok;
        for (uint256 i; i < 16; i++) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            PoolKey memory k = ks[r % 3];
            bool z = (r >> 8) & 1 == 1;
            int256 amt = int256(bound(r >> 16, 1, 25e18));
            if ((r >> 128) & 1 == 1) amt = -amt; // exact-in vs exact-out

            try swapper.swap(k, z, amt) {
                ok++;
                assertTrue(swapper.hookDeltaClean(), "hook delta open");
                assertEq(_pendingL(), 0, "deferral reached");
                for (uint256 j; j < 3; j++) {
                    assertGe(_bal(cs[j]), floor, "floor breached");
                    assertEq(_posL(ks[j], LOWER, UPPER), 0, "position left live");
                }
            } catch (bytes memory err) {
                bool expected = _contains(err, ICLSharedInventoryHook.MinSharedReserveBreached.selector)
                    || _contains(err, ICLSharedInventoryHook.InsufficientInventoryToSettle.selector)
                    || bytes4(err) == bytes4(keccak256("InvalidSqrtPriceLimit(uint160,uint160)"))
                    || bytes4(err) == bytes4(keccak256("SwapAmountCannotBeZero()"));
                if (!expected) {
                    emit log_named_bytes("unexpected revert", err);
                    fail();
                }
            }
        }
        assertGt(ok, 0, "sequence never exercised a swap");
    }

    /*//////////////////////////////////////////////////////////////
                    3. GAS GRIEFING OF THE CATCH-ALL
    //////////////////////////////////////////////////////////////*/

    function _gasSwap(uint256 g) internal returns (bool ok) {
        (ok,) = address(swapper).call{gas: g}(abi.encodeCall(SecSwapper.swap, (p1, true, -int256(5e18))));
    }

    /// Sweep the outer gas limit across the whole success boundary. If a limit existed where modifyLiquidity(-L)
    /// OOGs but the catch still completes, some limit would succeed WITH a pending record. None does: the catch
    /// arm (settle 2 legs + 3 SSTOREs + event) needs far more than 1/64 of what the removal needs.
    function test_gasGriefing_cannotForceDeferral() public {
        uint256 lo = 50_000;
        uint256 hi = 5_000_000;
        uint256 snap = vm.snapshotState();
        assertTrue(_gasSwap(hi), "baseline swap must succeed");
        vm.revertToState(snap);
        while (hi - lo > 1) {
            uint256 mid = (lo + hi) / 2;
            snap = vm.snapshotState();
            bool ok = _gasSwap(mid);
            vm.revertToState(snap);
            if (ok) hi = mid;
            else lo = mid;
        }
        emit log_named_uint("minimum gas for the swap", hi);

        uint256 successes;
        for (uint256 g = hi - 40_000; g <= hi + 40_000; g += 97) {
            snap = vm.snapshotState();
            if (_gasSwap(g)) {
                successes++;
                assertEq(_pendingL(), 0, "gas limit forced a deferral");
                assertEq(_posL(p1, LOWER, UPPER), 0, "position parked");
            }
            vm.revertToState(snap);
        }
        assertGt(successes, 0);
    }

    /// If the catch is reached while deferral is disabled, the whole swap reverts — nothing is parked or paid.
    function test_disableDeferredRemoval_catchRevertsWholeSwap() public {
        hook.setDisableDeferredRemoval(true);
        uint256 a0 = _bal(p1.currency0);
        vm.mockCallRevert(address(poolManager), _removalCall(p1, hook.getPoolConfig(p1.toId())), "forced");
        vm.expectRevert();
        _swap(p1, true, -5e18);
        vm.clearMockedCalls();
        assertEq(_pendingL(), 0);
        assertEq(_bal(p1.currency0), a0);
        assertEq(_posL(p1, LOWER, UPPER), 0);
    }

    /// Economics of a deferral if one were forced: the hook pays the full principal now, the position stays parked
    /// at the swap's ending price, and the next swap on ANY pool returns it with the trade + fee. No value lost.
    function test_deferral_paysFullPrincipal_thenNextSwapAnywhereRestores() public {
        uint256 a = _bal(p1.currency0);
        uint256 b = _bal(p1.currency1);
        vm.expectEmit(true, false, false, false, address(hook));
        emit ICLSharedInventoryHook.JitRemovalDeferred(p1.toId());
        _forceDeferredSwap(p1, true, -5e18);

        (uint256 req0, uint256 req1) = hook.requiredInventory(_cfg(LOWER, UPPER, L), SQRT_RATIO_1_1);
        assertApproxEqAbs(a - _bal(p1.currency0), req0, 2, "paid full token0 principal");
        assertApproxEqAbs(b - _bal(p1.currency1), req1, 2, "paid full token1 principal");
        assertEq(_posL(p1, LOWER, UPPER), L, "position parked");
        (PoolId pid,) = hook.pendingRemoval();
        assertEq(PoolId.unwrap(pid), PoolId.unwrap(p1.toId()));

        // a swap on P3 (no token in common with P1's leg A) flushes P1's position
        vm.expectEmit(true, false, false, false, address(hook));
        emit ICLSharedInventoryHook.FeesEarned(p1.toId(), 0, 0);
        _swap(p3, true, -1e18);
        assertEq(_pendingL(), 0, "flushed");
        assertEq(_posL(p1, LOWER, UPPER), 0);
        assertGt(_bal(p1.currency0) + _bal(p1.currency1) + 1e18, a + b, "value restored");
    }

    /*//////////////////////////////////////////////////////////////
                  4. PENDING REMOVAL LIVENESS (frozen token)
    //////////////////////////////////////////////////////////////*/

    function test_frozenPendingToken_haltsAllPools_untilEmergencyRemove() public {
        FreezableToken f = new FreezableToken();
        f.mint(address(this), 1e30);
        _fund(MockERC20(address(f)));
        PoolKey memory pf = _createPool(MockERC20(address(f)), tA, 2500, L);

        _forceDeferredSwap(pf, true, -5e18);
        assertEq(_pendingL(), L);
        f.setFrozen(true);

        // every pool on the hook is bricked, including P3 which shares nothing with pf
        vm.expectRevert();
        _swap(p1, true, -1e18);
        vm.expectRevert();
        _swap(p2, true, -1e18);
        vm.expectRevert();
        _swap(p3, true, -1e18);

        // burning the position while frozen also reverts (it must take the frozen token)
        vm.expectRevert();
        hook.emergencyRemoveLiquidity(pf, LOWER, UPPER, L, 0, 0);

        // liquidity == 0 drops the record without touching the vault -> other pools resume
        vm.expectEmit(true, false, false, true, address(hook));
        emit ICLSharedInventoryHook.PendingRemovalAbandoned(pf.toId(), _cfg(LOWER, UPPER, L));
        hook.emergencyRemoveLiquidity(pf, 0, 0, 0, 0, 0);
        assertEq(_pendingL(), 0);
        _swap(p3, true, -1e18);
        _swap(p2, false, -1e18);
        vm.expectRevert(); // pf itself still moves the frozen token
        _swap(pf, true, -1e18);

        // after unfreezing, the parked position is fully reclaimed
        f.setFrozen(false);
        uint256 bf = f.balanceOf(address(hook));
        uint256 ba = tA.balanceOf(address(hook));
        hook.emergencyRemoveLiquidity(pf, LOWER, UPPER, L, 0, 0);
        assertEq(_posL(pf, LOWER, UPPER), 0, "position reclaimed");
        assertGt(f.balanceOf(address(hook)) + tA.balanceOf(address(hook)), bf + ba + 50e18, "principal back");
    }

    /*//////////////////////////////////////////////////////////////
                           5. ACCESS CONTROL
    //////////////////////////////////////////////////////////////*/

    function test_access_everyAdminFunctionRejectsNonOwner() public {
        bytes memory err = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, ATTACKER);
        PoolId[] memory ids = new PoolId[](0);
        ICLSharedInventoryHook.PoolConfig[] memory cfgs = new ICLSharedInventoryHook.PoolConfig[](0);
        uint256[] memory u = new uint256[](0);
        PoolKey[] memory keys = new PoolKey[](0);
        uint160[] memory pr = new uint160[](0);
        address[] memory addrs = new address[](0);
        bool[] memory bs = new bool[](0);
        Currency[] memory cs = new Currency[](0);

        bytes[] memory calls = new bytes[](15);
        calls[0] = abi.encodeCall(hook.setPoolConfigs, (ids, cfgs, false, u, u));
        calls[1] = abi.encodeCall(hook.setUninitializePoolConfigs, (keys, cfgs, pr, false));
        calls[2] = abi.encodeCall(hook.withdraw, (_one(p1.currency0), _one(1), TREASURY));
        calls[3] = abi.encodeCall(hook.emergencyRemoveLiquidity, (p1, LOWER, UPPER, 0, 0, 0));
        calls[4] = abi.encodeCall(hook.setMinSharedReserve, (cs, u));
        calls[5] = abi.encodeCall(hook.setJitPaused, (true));
        calls[6] = abi.encodeCall(hook.setSwapPausedFor, (60));
        calls[7] = abi.encodeCall(hook.setRestrictedPoolCreation, (false));
        calls[8] = abi.encodeCall(hook.setRequireEnabledConfig, (true));
        calls[9] = abi.encodeCall(hook.setDisableDeferredRemoval, (true));
        calls[10] = abi.encodeCall(hook.setPoolCreator, (addrs, bs));
        calls[11] = abi.encodeCall(hook.setWithdrawRecipient, (addrs, bs));
        calls[12] = abi.encodeCall(hook.setInitialSqrtPrice, (p1.toId(), SQRT_RATIO_1_1));
        calls[13] = abi.encodeWithSignature("transferOwnership(address)", ATTACKER);
        calls[14] = abi.encodeWithSignature("renounceOwnership()");
        for (uint256 i; i < calls.length; i++) {
            vm.prank(ATTACKER);
            (bool ok, bytes memory ret) = address(hook).call(calls[i]);
            assertFalse(ok, "non-owner call succeeded");
            assertEq(ret, err, "wrong revert");
        }

        // self-only / vault-only / pool-manager-only entry points
        vm.prank(ATTACKER);
        vm.expectRevert();
        hook.emergencyRemoveLiquidityCallback(p1, LOWER, UPPER, 1, 0, 0);
        vm.prank(ATTACKER);
        vm.expectRevert();
        hook.lockAcquired("");
        vm.prank(ATTACKER);
        vm.expectRevert();
        hook.beforeSwap(ATTACKER, p1, ICLPoolManager.SwapParams(true, -1, 0), "");
        vm.prank(ATTACKER);
        vm.expectRevert();
        hook.afterSwap(ATTACKER, p1, ICLPoolManager.SwapParams(true, -1, 0), BalanceDelta.wrap(0), "");
    }

    function test_withdraw_onlyWhitelistedRecipient_neverBelowFloor() public {
        Currency a = Currency.wrap(address(tA));
        vm.expectRevert(abi.encodeWithSelector(ICLSharedInventoryHook.RecipientNotWhitelisted.selector, ATTACKER));
        hook.withdraw(_one(a), _one(1e18), ATTACKER);

        vm.expectRevert(ICLSharedInventoryHook.ZeroAmount.selector);
        hook.withdraw(_one(a), _one(0), TREASURY);

        hook.setMinSharedReserve(_one(a), _one(900e18));
        // 200 would leave 800 < 900: skipped, not sent
        vm.expectEmit(true, false, false, true, address(hook));
        emit ICLSharedInventoryHook.WithdrawSkipped(a, INVENTORY, 900e18, 200e18);
        hook.withdraw(_one(a), _one(200e18), TREASURY);
        assertEq(tA.balanceOf(TREASURY), 0);
        // more than the balance: skipped
        hook.withdraw(_one(a), _one(INVENTORY + 1), TREASURY);
        assertEq(tA.balanceOf(TREASURY), 0);
        // exactly down to the floor: allowed
        hook.withdraw(_one(a), _one(100e18), TREASURY);
        assertEq(tA.balanceOf(TREASURY), 100e18);
        assertEq(_bal(a), 900e18);

        // a floor above the balance is skipped, not set
        hook.setMinSharedReserve(_one(a), _one(901e18));
        assertEq(hook.minSharedReserve(a), 900e18);
    }

    function test_ownable2Step_andRenounceLocksInventoryForever() public {
        address next = makeAddr("next");
        hook.transferOwnership(next);
        assertEq(hook.owner(), address(this), "owner unchanged until accept");
        vm.prank(ATTACKER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, ATTACKER));
        hook.acceptOwnership();
        vm.prank(next);
        hook.acceptOwnership();
        assertEq(hook.owner(), next);

        // renounce is NOT disabled: it succeeds, and afterwards no one can withdraw, unpark or pause ever again
        vm.prank(next);
        hook.renounceOwnership();
        assertEq(hook.owner(), address(0));
        vm.prank(next);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, next));
        hook.withdraw(_one(p1.currency0), _one(1), TREASURY);
        vm.prank(next);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, next));
        hook.emergencyRemoveLiquidity(p1, LOWER, UPPER, 0, 0, 0);
        // swaps still run on the now-unmanaged inventory
        _swap(p1, true, -1e18);
    }

    /*//////////////////////////////////////////////////////////////
                    6. POOL CREATION GATE (tx.origin)
    //////////////////////////////////////////////////////////////*/

    /// A non-whitelisted contract creates a hook pool at a price of its choosing, because the whitelisted creator
    /// signed a transaction to it (for anything). Then it extracts value from the pre-configured JIT at that price.
    function test_txOrigin_phishedCreatorInitializesAtAttackerPrice() public {
        Phisher phisher = new Phisher();
        PoolKey memory k = _keyFor(tA, tC, 3000);
        _preconfig(k, _cfg(LOWER, UPPER, L), SQRT_RATIO_1_1); // owner expects 1:1
        uint160 skewed = TickMath.getSqrtRatioAtTick(-580); // token0 ~5.6% cheap

        // non-whitelisted origin: blocked
        address bob = makeAddr("bob");
        vm.prank(bob, bob);
        vm.expectRevert();
        phisher.claimAirdrop(poolManager, k, skewed);

        // whitelisted origin, malicious msg.sender: passes the gate
        vm.prank(CREATOR, CREATOR);
        phisher.claimAirdrop(poolManager, k, skewed);
        (uint160 p,,,) = poolManager.getSlot0(k.toId());
        assertEq(p, skewed, "pool live at attacker-chosen price");

        // attacker buys the cheap token0 from the hook's JIT; value at the 1:1 market price
        BalanceDelta d = _swap(k, false, -20e18);
        int256 profitAt1to1 = int256(d.amount0()) + int256(d.amount1());
        emit log_named_decimal_int("attacker profit at market (1:1), tokens", profitAt1to1, 18);
        assertGt(profitAt1to1, 0, "hook sold below market");
    }

    /*//////////////////////////////////////////////////////////////
                             7. REENTRANCY
    //////////////////////////////////////////////////////////////*/

    function _evilPool() internal returns (ReentrantToken evil, PoolKey memory k, bool sellEvil) {
        evil = new ReentrantToken();
        evil.mint(address(this), 1e30);
        _fund(MockERC20(address(evil)));
        k = _createPool(MockERC20(address(evil)), tA, 2500, L);
        sellEvil = Currency.unwrap(k.currency0) == address(evil); // zeroForOne sells evil
    }

    /// A token callback fired while the vault pays the hook in afterSwap tries to start a nested swap on another
    /// hook pool directly through the pool manager (the outer lock is open). The hook's in-swap flag rejects it.
    function test_reentrancy_nestedSwapFromTokenCallbackRejected() public {
        (ReentrantToken evil, PoolKey memory k, bool z) = _evilPool();
        bytes memory nested = abi.encodeCall(
            ICLPoolManager.swap,
            (p2, ICLPoolManager.SwapParams(true, -1e18, TickMath.getSqrtRatioAtTick(-1200)), bytes(""))
        );
        evil.arm(address(hook), address(poolManager), nested);
        _swap(k, z, -5e18);
        assertTrue(evil.fired(), "callback ran");
        assertFalse(evil.callOk(), "nested swap went through");
        assertTrue(_contains(evil.callRet(), ICLSharedInventoryHook.SwapInProgress.selector), "not SwapInProgress");
        assertEq(_posL(k, LOWER, UPPER), 0);
        assertEq(_posL(p2, LOWER, UPPER), 0);
    }

    /// Even the OWNER cannot withdraw or run an emergency removal from inside a swap.
    function test_reentrancy_ownerWithdrawAndEmergencyMidSwapRejected() public {
        (ReentrantToken evil, PoolKey memory k, bool z) = _evilPool();
        hook.transferOwnership(address(evil));
        vm.prank(address(evil));
        hook.acceptOwnership();

        evil.arm(address(hook), address(hook), abi.encodeCall(hook.withdraw, (_one(p1.currency0), _one(1e18), TREASURY)));
        _swap(k, z, -5e18);
        assertTrue(evil.fired());
        assertFalse(evil.callOk(), "withdraw mid-swap succeeded");
        assertEq(bytes4(evil.callRet()), ICLSharedInventoryHook.SwapInProgress.selector);

        evil.arm(address(hook), address(hook), abi.encodeCall(hook.emergencyRemoveLiquidity, (p1, LOWER, UPPER, 1, 0, 0)));
        _swap(k, z, -5e18);
        assertTrue(evil.fired());
        assertFalse(evil.callOk(), "emergency removal mid-swap succeeded");
        assertEq(bytes4(evil.callRet()), IVault.LockerAlreadySet.selector);
    }

    /*//////////////////////////////////////////////////////////////
                         8. CROSS-POOL CONTAGION
    //////////////////////////////////////////////////////////////*/

    /// An arbitrageur drains A from the hook through P1; P2 (whose own pair is untouched) can then no longer pay A
    /// out: floor breach. The opposite direction (A in) still works.
    function test_contagion_floorTripsOtherPool() public {
        Currency a = Currency.wrap(address(tA));
        hook.setMinSharedReserve(_one(a), _one(975e18));
        _swap(p1, !_aIs0(p1), -20e18); // sell B into P1, hook pays out ~20 A
        assertLt(_bal(a), 985e18);

        vm.expectRevert(); // MinSharedReserveBreached wrapped by the pool manager
        _swap(p2, !_aIs0(p2), -10e18); // buy A from P2
        try swapper.swap(p2, !_aIs0(p2), -10e18) {
            fail();
        } catch (bytes memory err) {
            assertTrue(_contains(err, ICLSharedInventoryHook.MinSharedReserveBreached.selector));
        }
        _swap(p2, _aIs0(p2), -10e18); // selling A into P2 still works
    }

    function test_contagion_drainedInventoryRevertsOtherPool() public {
        Currency a = Currency.wrap(address(tA));
        hook.withdraw(_one(a), _one(INVENTORY - 40e18), TREASURY); // hook holds 40 A
        _swap(p1, !_aIs0(p1), -int256(100e18)); // push P1 past its range: hook pays out all ~29.6 A in range
        assertLt(_bal(a), 12e18);
        (, int24 tick,,) = poolManager.getSlot0(p1.toId());
        assertTrue(tick >= UPPER || tick <= LOWER, "P1 range now stale");

        try swapper.swap(p2, !_aIs0(p2), -15e18) {
            fail();
        } catch (bytes memory err) {
            assertTrue(_contains(err, ICLSharedInventoryHook.InsufficientInventoryToSettle.selector));
        }
    }

    /*//////////////////////////////////////////////////////////////
                           9. ROUNDING DUST
    //////////////////////////////////////////////////////////////*/

    /// 200 alternating small swaps on a 0-fee pool. Per token: hook + swapper + stranded-in-pool == 0 exactly, the
    /// stranded dust is <= 2 wei per swap, and the swapper never ends up ahead.
    function test_roundingDust_zeroFee_leaksToPoolNotSwapper() public {
        PoolKey memory k = _createPool(tA, tB, 0, L);
        int256[2] memory hookD;
        int256[2] memory swapD;
        uint256 r0 = vault.reservesOfApp(address(poolManager), k.currency0);
        uint256 r1 = vault.reservesOfApp(address(poolManager), k.currency1);
        uint256 h0 = _bal(k.currency0);
        uint256 h1 = _bal(k.currency1);
        uint256 n = 200;
        for (uint256 i; i < n; i++) {
            BalanceDelta d = _swap(k, i % 2 == 0, -int256(1e15 + i));
            swapD[0] += d.amount0();
            swapD[1] += d.amount1();
        }
        hookD[0] = int256(_bal(k.currency0)) - int256(h0);
        hookD[1] = int256(_bal(k.currency1)) - int256(h1);
        int256 s0 = int256(vault.reservesOfApp(address(poolManager), k.currency0)) - int256(r0);
        int256 s1 = int256(vault.reservesOfApp(address(poolManager), k.currency1)) - int256(r1);
        emit log_named_int("hook delta token0 (wei)", hookD[0]);
        emit log_named_int("hook delta token1 (wei)", hookD[1]);
        emit log_named_int("swapper delta token0 (wei)", swapD[0]);
        emit log_named_int("swapper delta token1 (wei)", swapD[1]);
        emit log_named_int("stranded in pool token0 (wei)", s0);
        emit log_named_int("stranded in pool token1 (wei)", s1);
        assertEq(hookD[0] + swapD[0] + s0, 0, "conservation 0");
        assertEq(hookD[1] + swapD[1] + s1, 0, "conservation 1");
        assertLe(s0, int256(2 * n));
        assertLe(s1, int256(2 * n));
        assertGe(s0 + s1, 0, "pool never short");
        assertEq(_posL(k, LOWER, UPPER), 0);
    }

    /// 1-wei exact-out claims on a fee pool: the swapper always pays more than it gets and the hook nets positive.
    function test_roundingDust_oneWeiClaims_swapperPaysMore() public {
        uint256 h0 = _bal(p1.currency0);
        uint256 h1 = _bal(p1.currency1);
        int256 paid;
        for (uint256 i; i < 100; i++) {
            BalanceDelta d = _swap(p1, i % 2 == 0, 1); // exact-out 1 wei
            paid += d.amount0() + d.amount1();
        }
        int256 hookNet = int256(_bal(p1.currency0) + _bal(p1.currency1)) - int256(h0 + h1);
        emit log_named_int("swapper net over 100 one-wei claims (wei)", paid);
        emit log_named_int("hook net (wei)", hookNet);
        assertLt(paid, 0, "swapper ahead");
        assertGe(hookNet, -200, "hook leaks at most 2 wei per claim");
    }

    /*//////////////////////////////////////////////////////////////
                  10. CONFIG CHANGE WITH A PENDING REMOVAL
    //////////////////////////////////////////////////////////////*/

    /// Owner re-ranges P1 while P1's deferred position is parked. The flush burns the OLD (snapshotted) position
    /// exactly; the next P1 swap uses the new config; nothing is stranded.
    function test_configChangeWhilePending_flushUsesSnapshot() public {
        _forceDeferredSwap(p1, true, -5e18);
        _setConfig(p1, _cfg(-1200, 1200, L / 2));
        vm.expectRevert(ICLSharedInventoryHook.PendingRemovalOutstanding.selector);
        hook.setDisableDeferredRemoval(true);

        _swap(p2, true, -1e18); // flush on another pool
        assertEq(_pendingL(), 0);
        assertEq(_posL(p1, LOWER, UPPER), 0, "old position burned");

        _swap(p1, false, -1e18);
        assertEq(_posL(p1, -1200, 1200), 0, "new position removed inline");
        assertEq(_posL(p1, LOWER, UPPER), 0);
    }

    /// Disabling the pool or pausing JIT does not stop the flush.
    function test_disableAndJitPauseWhilePending_stillFlushes() public {
        _forceDeferredSwap(p1, true, -5e18);
        ICLSharedInventoryHook.PoolConfig memory off;
        _setConfig(p1, off);
        hook.setJitPaused(true);
        _swap(p1, false, -1); // no JIT and no resident liquidity: fills nothing, but flushes
        assertEq(_pendingL(), 0);
        assertEq(_posL(p1, LOWER, UPPER), 0);
    }

    /// emergencyRemoveLiquidity for the pending pool clears the WHOLE record even when it burns only part of the
    /// position: the remainder is no longer tracked, is never flushed, and sits as hook-owned resident liquidity
    /// until the owner removes it by hand.
    function test_partialEmergencyRemove_dropsWholeRecord_remainderUntracked() public {
        _forceDeferredSwap(p1, true, -5e18);
        hook.emergencyRemoveLiquidity(p1, LOWER, UPPER, L / 2, 0, 0);
        assertEq(_pendingL(), 0, "record dropped");
        assertEq(_posL(p1, LOWER, UPPER), L / 2, "half still live");

        _swap(p2, true, -1e18);
        _swap(p1, false, -1e18); // injects L on top, removes L: the untracked half survives every swap
        assertEq(_posL(p1, LOWER, UPPER), L / 2, "remainder never flushed");

        hook.emergencyRemoveLiquidity(p1, LOWER, UPPER, L / 2, 0, 0);
        assertEq(_posL(p1, LOWER, UPPER), 0, "manual recovery works");
    }

    /// An emergency removal on a DIFFERENT pool leaves the pending record alone.
    function test_emergencyRemoveOtherPool_keepsPending() public {
        _forceDeferredSwap(p1, true, -5e18);
        hook.emergencyRemoveLiquidity(p2, LOWER, UPPER, 0, 0, 0);
        assertEq(_pendingL(), L);
    }
}
