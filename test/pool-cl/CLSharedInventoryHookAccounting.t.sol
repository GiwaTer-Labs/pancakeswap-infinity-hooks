// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {ILockCallback} from "infinity-core/src/interfaces/ILockCallback.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {IProtocolFeeController} from "infinity-core/src/interfaces/IProtocolFeeController.sol";
import {Currency, CurrencyLibrary} from "infinity-core/src/types/Currency.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "infinity-core/src/types/PoolId.sol";
import {BalanceDelta} from "infinity-core/src/types/BalanceDelta.sol";
import {TickMath} from "infinity-core/src/pool-cl/libraries/TickMath.sol";
import {FullMath} from "infinity-core/src/pool-cl/libraries/FullMath.sol";
import {CLPoolParametersHelper} from "infinity-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";
import {SortTokens} from "infinity-core/test/helpers/SortTokens.sol";
import {Deployers} from "infinity-core/test/pool-cl/helpers/Deployers.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {CLSharedInventoryHook} from "../../src/pool-cl/shared-inventory/CLSharedInventoryHook.sol";
import {ICLSharedInventoryHook} from "../../src/pool-cl/shared-inventory/interfaces/ICLSharedInventoryHook.sol";

/// @dev Trader that holds its own funds. Settles any ERC20 (grossing up for fee-on-transfer and taking back any
///      overpayment) or native, and can donate to a pool.
contract AccSwapper is ILockCallback {
    IVault public immutable vault;
    ICLPoolManager public immutable pm;

    constructor(IVault _vault, ICLPoolManager _pm) {
        vault = _vault;
        pm = _pm;
    }

    receive() external payable {}

    function swap(PoolKey memory key, bool zeroForOne, int256 amount, uint160 limit) external returns (BalanceDelta) {
        if (limit == 0) limit = zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1;
        return abi.decode(vault.lock(abi.encode(uint8(0), key, zeroForOne, amount, limit)), (BalanceDelta));
    }

    function donate(PoolKey memory key, uint256 a0, uint256 a1) external {
        vault.lock(abi.encode(uint8(1), key, a0 != 0, int256(a0 + a1), uint160(0)));
    }

    function lockAcquired(bytes calldata data) external returns (bytes memory) {
        (uint8 op, PoolKey memory key, bool z, int256 amt, uint160 limit) =
            abi.decode(data, (uint8, PoolKey, bool, int256, uint160));
        BalanceDelta d;
        if (op == 0) {
            d = pm.swap(key, ICLPoolManager.SwapParams({zeroForOne: z, amountSpecified: amt, sqrtPriceLimitX96: limit}), "");
        } else {
            d = pm.donate(key, z ? uint256(amt) : 0, z ? 0 : uint256(amt), "");
        }
        _close(key.currency0);
        _close(key.currency1);
        return abi.encode(d);
    }

    function _close(Currency c) internal {
        int256 delta = vault.currencyDelta(address(this), c);
        while (delta < 0) {
            uint256 owe = uint256(-delta);
            vault.sync(c);
            if (c.isNative()) {
                vault.settle{value: owe}();
            } else {
                MockERC20(Currency.unwrap(c)).transfer(address(vault), owe + owe / 99 + 1); // FoT gross-up
                vault.settle();
            }
            delta = vault.currencyDelta(address(this), c);
        }
        if (delta > 0) vault.take(c, address(this), uint256(delta));
    }
}

/// @dev 1% fee-on-transfer token (fee burned).
contract FeeOnTransferToken is MockERC20 {
    constructor() MockERC20("FOT", "FOT", 18) {}

    function _move(address from, address to, uint256 amount) internal {
        uint256 fee = amount / 100;
        balanceOf[from] -= amount;
        unchecked {
            balanceOf[to] += amount - fee;
            totalSupply -= fee;
        }
        emit Transfer(from, to, amount - fee);
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        _move(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        _move(from, to, amount);
        return true;
    }
}

/// @notice Accounting PoCs: where the hook's books (its live balance) and economic reality diverge, and who gains.
/// @dev Pools P1 (A,B) and P2 (A,C) share A. No resident liquidity: every swap is filled by the JIT position only.
///      The vault is pre-funded so the hook's in-afterSwap `take` is backed (other pools play that role on chain).
contract CLSharedInventoryHookAccountingTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CLPoolParametersHelper for bytes32;

    uint256 constant INVENTORY = 1_000e18;
    uint128 constant L = 1e21;
    int24 constant LOWER = -600;
    int24 constant UPPER = 600;
    bytes32 constant SALT = 0x2dd421f327b24150303d8f1213699124a1c7bb24e1d9d96ac0280c16e513b260;
    uint256 constant Q96 = 1 << 96;

    IVault vault;
    ICLPoolManager poolManager;
    CLSharedInventoryHook hook;
    AccSwapper trader;

    MockERC20 tA;
    MockERC20 tB;
    MockERC20 tC;
    PoolKey p1;
    PoolKey p2;

    address TREASURY = makeAddr("treasury");
    address ATTACKER = makeAddr("attacker");

    function setUp() public {
        (vault, poolManager) = createFreshManager();
        hook = new CLSharedInventoryHook(poolManager, address(this));
        trader = new AccSwapper(vault, poolManager);
        hook.setRestrictedPoolCreation(false);

        MockERC20[] memory ts = deployTokens(3, type(uint256).max);
        (tA, tB, tC) = (ts[0], ts[1], ts[2]);
        for (uint256 i; i < 3; i++) _fund(ts[i]);

        address[] memory who = new address[](1);
        bool[] memory yes = new bool[](1);
        (who[0], yes[0]) = (TREASURY, true);
        hook.setWithdrawRecipient(who, yes);

        p1 = _createPool(Currency.wrap(address(tA)), Currency.wrap(address(tB)), 2500, _cfg(LOWER, UPPER, L), SQRT_RATIO_1_1);
        p2 = _createPool(Currency.wrap(address(tA)), Currency.wrap(address(tC)), 2500, _cfg(LOWER, UPPER, L), SQRT_RATIO_1_1);
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _fund(MockERC20 t) internal {
        t.transfer(address(hook), INVENTORY);
        t.transfer(address(vault), 1e27);
        t.transfer(address(trader), 1e27);
    }

    function _cfg(int24 lo, int24 hi, uint128 liq) internal pure returns (ICLSharedInventoryHook.PoolConfig memory) {
        return ICLSharedInventoryHook.PoolConfig({enabled: true, tickLower: lo, tickUpper: hi, liquidity: liq});
    }

    function _createPool(Currency a, Currency b, uint24 fee, ICLSharedInventoryHook.PoolConfig memory c, uint160 price)
        internal
        returns (PoolKey memory k)
    {
        (Currency c0, Currency c1) = Currency.unwrap(a) < Currency.unwrap(b) ? (a, b) : (b, a);
        k = PoolKey({
            currency0: c0,
            currency1: c1,
            hooks: IHooks(address(hook)),
            poolManager: poolManager,
            fee: fee,
            parameters: bytes32(uint256(hook.getHooksRegistrationBitmap())).setTickSpacing(10)
        });
        PoolKey[] memory keys = new PoolKey[](1);
        keys[0] = k;
        ICLSharedInventoryHook.PoolConfig[] memory cfgs = new ICLSharedInventoryHook.PoolConfig[](1);
        cfgs[0] = c;
        uint160[] memory prices = new uint160[](1);
        prices[0] = price;
        hook.setUninitializePoolConfigs(keys, cfgs, prices, false);
        poolManager.initialize(k, price);
    }

    function _swap(PoolKey memory k, bool zeroForOne, int256 amount) internal returns (BalanceDelta) {
        return trader.swap(k, zeroForOne, amount, 0);
    }

    function _swapTo(PoolKey memory k, bool zeroForOne, int24 tick) internal returns (BalanceDelta) {
        return trader.swap(k, zeroForOne, -1e24, TickMath.getSqrtRatioAtTick(tick));
    }

    function _bal(Currency c) internal view returns (uint256) {
        return hook.inventoryOf(c);
    }

    /// @dev value of the hook's two balances of `k` in currency1, at `sqrtP`
    function _value(PoolKey memory k, uint160 sqrtP) internal view returns (uint256) {
        return FullMath.mulDiv(FullMath.mulDiv(_bal(k.currency0), sqrtP, Q96), sqrtP, Q96) + _bal(k.currency1);
    }

    function _posL(PoolKey memory k, int24 lo, int24 hi) internal view returns (uint128) {
        return poolManager.getLiquidity(k.toId(), address(hook), lo, hi, SALT);
    }

    function _pendingL() internal view returns (uint128) {
        (, ICLSharedInventoryHook.PoolConfig memory c) = hook.pendingRemoval();
        return c.liquidity;
    }

    /// @dev Drive the real catch branch of afterSwap (nothing reaches it naturally on the pinned core).
    function _forceDeferredSwap(PoolKey memory k, bool zeroForOne, int256 amount) internal {
        ICLSharedInventoryHook.PoolConfig memory c = hook.getPoolConfig(k.toId());
        vm.mockCallRevert(
            address(poolManager),
            abi.encodeCall(
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
            ),
            "forced"
        );
        _swap(k, zeroForOne, amount);
        vm.clearMockedCalls();
    }

    function _one(Currency c) internal pure returns (Currency[] memory a) {
        a = new Currency[](1);
        a[0] = c;
    }

    function _one(uint256 v) internal pure returns (uint256[] memory a) {
        a = new uint256[](1);
        a[0] = v;
    }

    function _contains(bytes memory hay, bytes4 sel) internal pure returns (bool) {
        for (uint256 i; i + 4 <= hay.length; i++) {
            if (hay[i] == sel[0] && hay[i + 1] == sel[1] && hay[i + 2] == sel[2] && hay[i + 3] == sel[3]) return true;
        }
        return false;
    }

    /*//////////////////////////////////////////////////////////////
          Q1. IMPERMANENT LOSS IS REALISED INTO SHARED INVENTORY
    //////////////////////////////////////////////////////////////*/

    /// External price moves 1.0 -> 1.0618 (tick 600). An arbitrageur buys token0 from P1 up to that price. Every swap
    /// realises the move into the hook's balance; valued at the new price the hook is worse off than holding, by the
    /// arber's profit. The token0 that left came out of the balance P2 also draws on.
    function test_Q1_arbRealisesIL_paidFromSharedBalance() public {
        uint160 pNew = TickMath.getSqrtRatioAtTick(UPPER);
        uint256 holdValue = _value(p1, pNew);
        uint256 t0Before = _bal(p1.currency0);

        BalanceDelta d = _swapTo(p1, false, UPPER); // buy token0 until price = external
        uint256 got0 = uint256(int256(d.amount0()));
        uint256 paid1 = uint256(-int256(d.amount1()));
        uint256 arbProfit = FullMath.mulDiv(FullMath.mulDiv(got0, pNew, Q96), pNew, Q96) - paid1;
        uint256 hookLoss = holdValue - _value(p1, pNew);

        emit log_named_decimal_uint("token0 sold by hook", got0, 18);
        emit log_named_decimal_uint("token1 paid by arber (incl 0.25% fee)", paid1, 18);
        emit log_named_decimal_uint("hook loss vs holding, in token1", hookLoss, 18);
        emit log_named_decimal_uint("arber profit, in token1", arbProfit, 18);
        emit log_named_decimal_uint("token0 drawn from the shared balance", t0Before - _bal(p1.currency0), 18);

        assertGt(hookLoss, 0, "hook loses to the arb");
        assertApproxEqAbs(hookLoss, arbProfit, 4, "hook loss == arber profit (minus rounding dust)");
        assertEq(_posL(p1, LOWER, UPPER), 0, "nothing left in the pool: loss is realised, not impermanent");
        assertEq(_pendingL(), 0);
    }

    /// Cross-pool: P1 (A,B) and P2 (A,C) share A. The hook holds 40 A. A swap on P2 that buys A works. Then the
    /// external price of A moves and an arbitrageur buys A from P1 until P1's price matches; the hook realises a
    /// loss vs holding and pays the A out of the one shared balance. The SAME P2 swap now reverts
    /// InsufficientInventoryToSettle, although nothing about P2 (its config, its price) changed.
    function test_Q1_crossPool_lossFromPoolA_reducesInventoryAvailableToPoolB() public {
        Currency a = Currency.wrap(address(tA));
        bool aIs0p1 = Currency.unwrap(p1.currency0) == address(tA);
        bool aIs0p2 = Currency.unwrap(p2.currency0) == address(tA);
        hook.withdraw(_one(a), _one(INVENTORY - 40e18), TREASURY); // hook holds 40 A

        // P2 buys A (sells 15 C): succeeds against the full 40 A
        uint256 snap = vm.snapshotState();
        uint256 aBefore = _bal(a);
        _swap(p2, !aIs0p2, -15e18);
        uint256 p2Needs = aBefore - _bal(a);
        vm.revertToState(snap);
        (uint160 p2Price,,,) = poolManager.getSlot0(p2.toId());

        // arb on P1: buy A until P1's price is the new external price (tick +-600)
        int24 tNew = aIs0p1 ? UPPER : LOWER;
        uint160 pNew = TickMath.getSqrtRatioAtTick(tNew);
        uint256 holdValue = _value(p1, pNew);
        _swapTo(p1, !aIs0p1, tNew);
        uint256 hookLoss = holdValue - _value(p1, pNew);
        uint256 aDrawn = aBefore - _bal(a);

        emit log_named_decimal_uint("A the P2 swap needs from the hook", p2Needs, 18);
        emit log_named_decimal_uint("A drawn from the shared balance by the P1 arb", aDrawn, 18);
        emit log_named_decimal_uint("hook loss vs holding on P1, in P1 currency1", hookLoss, 18);
        emit log_named_decimal_uint("A left for P2", _bal(a), 18);

        assertGt(hookLoss, 0, "P1 arb realised a loss");
        assertGt(aDrawn, 0);
        assertLt(_bal(a), p2Needs, "P1's loss left less A than P2 needs");
        (uint160 p2PriceNow,,,) = poolManager.getSlot0(p2.toId());
        assertEq(p2PriceNow, p2Price, "P2 itself untouched");

        try trader.swap(p2, !aIs0p2, -15e18, 0) {
            fail();
        } catch (bytes memory err) {
            assertTrue(_contains(err, ICLSharedInventoryHook.InsufficientInventoryToSettle.selector));
        }
    }

    /// Same range, fee 0, swapped out and back to the starting price: the hook ends within rounding of where it
    /// started. With a fee it ends ahead by the fees. IL is path-independent: it reverses only if price returns.
    function test_Q1_roundTrip_returnsToStart_onlyFeesRemain() public {
        PoolKey memory pz = _createPool(Currency.wrap(address(tB)), Currency.wrap(address(tC)), 0, _cfg(LOWER, UPPER, L), SQRT_RATIO_1_1);
        uint256 vz = _value(pz, SQRT_RATIO_1_1);
        _swapTo(pz, false, 300);
        _swapTo(pz, true, 0);
        int256 dz = int256(_value(pz, SQRT_RATIO_1_1)) - int256(vz);

        uint256 v1 = _value(p1, SQRT_RATIO_1_1);
        BalanceDelta l1 = _swapTo(p1, false, 300);
        BalanceDelta l2 = _swapTo(p1, true, 0);
        int256 d1 = int256(_value(p1, SQRT_RATIO_1_1)) - int256(v1);
        uint256 volume = uint256(-int256(l1.amount1())) + uint256(-int256(l2.amount0()));

        emit log_named_int("0-fee round trip, hook value change (wei)", dz);
        emit log_named_decimal_int("0.25% round trip, hook value change", d1, 18);
        emit log_named_decimal_uint("round trip input volume", volume, 18);
        assertLe(dz, 0);
        assertGe(dz, -4, "0-fee: only rounding dust lost");
        assertApproxEqRel(uint256(d1), volume * 2500 / 1e6, 0.01e18, "fee pool: gain == 0.25% of volume");
    }

    /*//////////////////////////////////////////////////////////////
          Q2. CROSS-POOL: SOLVENCY IS NET-ONLY, PRINCIPAL IS NOT RESERVED
    //////////////////////////////////////////////////////////////*/

    /// The settle is exact: with the hook holding EXACTLY the swap's net token-A outflow it succeeds and ends at 0 A;
    /// one wei less reverts. So the "required inventory" (principal ~29.6 A) is never reserved per pool — P1 and P2
    /// both run on whatever single A balance exists, first come first served.
    function test_Q2_Q5_settleIsExact_netOnly_noPerPoolReservation() public {
        Currency a = Currency.wrap(address(tA));
        bool aIs0 = Currency.unwrap(p1.currency0) == address(tA);
        uint256 snap = vm.snapshotState();
        uint256 before = _bal(a);
        _swap(p1, !aIs0, -5e18); // buy A
        uint256 owe = before - _bal(a);
        vm.revertToState(snap);

        (uint256 req0, uint256 req1) = hook.requiredInventory(_cfg(LOWER, UPPER, L), SQRT_RATIO_1_1);
        emit log_named_decimal_uint("A principal the config 'requires'", aIs0 ? req0 : req1, 18);
        emit log_named_decimal_uint("A the swap actually needs", owe, 18);

        snap = vm.snapshotState();
        deal(address(tA), address(hook), owe - 1);
        try trader.swap(p1, !aIs0, -5e18, 0) {
            fail();
        } catch (bytes memory err) {
            assertTrue(_contains(err, ICLSharedInventoryHook.InsufficientInventoryToSettle.selector));
        }
        vm.revertToState(snap);

        deal(address(tA), address(hook), owe);
        _swap(p1, !aIs0, -5e18);
        assertEq(_bal(a), 0, "exact net settle, hook A fully drained");
        // P2 now cannot sell A at all, though its own config's principal was 'checked' at config time
        bool aIs0p2 = Currency.unwrap(p2.currency0) == address(tA);
        vm.expectRevert();
        _swap(p2, !aIs0p2, -1e15);
    }

    /// The floor blocks only swaps whose post-swap balance is below it. A balance that is already below (negative
    /// rebase / slashing stand-in via `deal`) blocks even swaps that ADD the token, unless one swap lifts it fully —
    /// contrary to the doc ("swaps that ADD the token back still succeed").
    function test_Q2_floorAlreadyBreached_blocksSwapsThatAddToken() public {
        Currency a = Currency.wrap(address(tA));
        bool aIs0 = Currency.unwrap(p1.currency0) == address(tA);
        hook.setMinSharedReserve(_one(a), _one(990e18));
        deal(address(tA), address(hook), 985e18); // balance shrinks under the floor outside any swap

        try trader.swap(p1, aIs0, -1e18, 0) { // SELL 1 A into P1: raises A
            fail();
        } catch (bytes memory err) {
            assertTrue(_contains(err, ICLSharedInventoryHook.MinSharedReserveBreached.selector));
        }
        _swap(p1, aIs0, -6e18); // a single swap big enough to clear the floor passes
        assertGe(_bal(a), 990e18);
    }

    /*//////////////////////////////////////////////////////////////
                   Q3. DONATIONS / NATIVE
    //////////////////////////////////////////////////////////////*/

    /// Direct ERC20 and native transfers just become owner-withdrawable inventory; the next swap's fill is identical
    /// (L is fixed, nothing is sized off the balance).
    function test_Q3_donationsChangeNothing_butAreOwnerWithdrawable() public {
        uint256 snap = vm.snapshotState();
        BalanceDelta ref = _swap(p1, true, -3e18);
        vm.revertToState(snap);

        tA.transfer(address(hook), 50e18);
        tB.transfer(address(hook), 50e18);
        (bool ok,) = address(hook).call{value: 1 ether}("");
        assertTrue(ok, "anyone can send ETH");
        BalanceDelta d = _swap(p1, true, -3e18);
        assertEq(BalanceDelta.unwrap(d), BalanceDelta.unwrap(ref), "same fill with or without donation");

        hook.withdraw(_one(CurrencyLibrary.NATIVE), _one(1 ether), TREASURY);
        assertEq(TREASURY.balance, 1 ether, "donated ETH goes to the owner's treasury");
    }

    /// Native-currency pool: native settle/take paths conserve value like ERC20.
    function test_Q3_nativePool_conserves() public {
        (bool ok,) = address(hook).call{value: 1_000 ether}("");
        assertTrue(ok);
        vm.deal(address(vault), 1e27);
        vm.deal(address(trader), 1e27);
        PoolKey memory pn =
            _createPool(CurrencyLibrary.NATIVE, Currency.wrap(address(tB)), 2500, _cfg(LOWER, UPPER, L), SQRT_RATIO_1_1);
        for (uint256 i; i < 4; i++) {
            uint256 h0 = _bal(pn.currency0);
            uint256 h1 = _bal(pn.currency1);
            BalanceDelta d = _swap(pn, i % 2 == 0, -int256(2e18 + i));
            assertApproxEqAbs(int256(_bal(pn.currency0)) - int256(h0), -int256(d.amount0()), 4);
            assertApproxEqAbs(int256(_bal(pn.currency1)) - int256(h1), -int256(d.amount1()), 4);
        }
        assertEq(_posL(pn, LOWER, UPPER), 0);
    }

    /*//////////////////////////////////////////////////////////////
                    Q4. FEE-ON-TRANSFER / DECIMALS
    //////////////////////////////////////////////////////////////*/

    /// FoT: when the hook RECEIVES the token (trader sells it), the vault's take sends `x` and the hook gets 0.99x —
    /// a silent 1% loss per inflow. When the hook must PAY it (trader buys it), `settle` credits only 0.99x, the
    /// hook's vault delta stays open and the whole swap reverts: one direction of the pool is bricked.
    function test_Q4_feeOnTransfer_silentLossOneWay_revertOtherWay() public {
        FeeOnTransferToken f = new FeeOnTransferToken();
        f.mint(address(hook), 1_000e18);
        f.mint(address(vault), 1e27);
        f.mint(address(trader), 1e27);
        PoolKey memory pf =
            _createPool(Currency.wrap(address(f)), Currency.wrap(address(tB)), 2500, _cfg(LOWER, UPPER, L), SQRT_RATIO_1_1);
        bool fIs0 = Currency.unwrap(pf.currency0) == address(f);
        Currency cf = Currency.wrap(address(f));

        uint256 h = _bal(cf);
        BalanceDelta d = _swap(pf, fIs0, -10e18); // trader sells 10 FOT
        uint256 booked = uint256(-int256(fIs0 ? d.amount0() : d.amount1()));
        uint256 received = _bal(cf) - h;
        emit log_named_decimal_uint("FOT the pool booked to the hook", booked, 18);
        emit log_named_decimal_uint("FOT the hook actually received", received, 18);
        assertApproxEqAbs(received, booked * 99 / 100, 2, "hook silently eats the transfer fee");

        vm.expectRevert(); // CurrencyNotSettled: hook's settle of FOT credits 99%
        _swap(pf, !fIs0, -1e18); // trader buys FOT
    }

    /// 6-decimal token1 at a realistic 18/6 price (tick -276320): settle is in raw units, nothing assumes decimals;
    /// rounding dust stays <= 2 raw units per swap per side (2e-6 of a 6-dec token).
    function test_Q4_Q5_sixDecimals_dustBounded() public {
        MockERC20 usd = new MockERC20("USD", "USD", 6);
        usd.mint(address(hook), 1_000e6);
        usd.mint(address(vault), 1e24);
        usd.mint(address(trader), 1e24);
        int24 t = -276320;
        uint160 px = TickMath.getSqrtRatioAtTick(t);
        PoolKey memory pu = _createPool(
            Currency.wrap(address(tA)), Currency.wrap(address(usd)), 0, _cfg(t - 600, t + 600, 1e15), px
        );
        require(Currency.unwrap(pu.currency1) == address(usd) || Currency.unwrap(pu.currency0) == address(usd));
        uint256 h0 = _bal(pu.currency0);
        uint256 h1 = _bal(pu.currency1);
        int256 s0;
        int256 s1;
        uint256 n = 100;
        for (uint256 i; i < n; i++) {
            bool z = i % 2 == 0;
            BalanceDelta d = _swap(pu, z, Currency.unwrap(z ? pu.currency0 : pu.currency1) == address(usd) ? -1e6 : -1e18);
            s0 += d.amount0();
            s1 += d.amount1();
        }
        int256 dh0 = int256(_bal(pu.currency0)) - int256(h0);
        int256 dh1 = int256(_bal(pu.currency1)) - int256(h1);
        emit log_named_int("hook+trader leak token0 (raw)", -(dh0 + s0));
        emit log_named_int("hook+trader leak token1 (raw)", -(dh1 + s1));
        assertLe(-(dh0 + s0), int256(2 * n));
        assertLe(-(dh1 + s1), int256(2 * n));
        assertEq(_posL(pu, t - 600, t + 600), 0);
    }

    /*//////////////////////////////////////////////////////////////
                    Q6. DEFERRED REMOVAL WHILE PENDING
    //////////////////////////////////////////////////////////////*/

    /// While a removal is pending, nothing can move the pool's price (every swap flushes first), so the parked value
    /// is fixed. But the position is live in-range liquidity: a third party's `donate` is credited to it, and the
    /// flush hands the donation to the hook.
    function test_Q6_pendingValueFrozen_donationsAccrueToHook() public {
        bool aIs0 = Currency.unwrap(p1.currency0) == address(tA);
        _forceDeferredSwap(p1, aIs0, -5e18); // sell A into P1, deferred
        (uint160 pAfter,,,) = poolManager.getSlot0(p1.toId());
        assertEq(_pendingL(), L);

        Currency b = Currency.wrap(address(tB));
        trader.donate(p1, aIs0 ? 0 : 7e18, aIs0 ? 7e18 : 0); // donate 7 B to the parked position
        (uint160 pNow,,,) = poolManager.getSlot0(p1.toId());
        assertEq(pNow, pAfter, "price unchanged while pending");

        uint256 bBefore = _bal(b);
        _swap(p2, true, -1e15); // P2 (no B) flushes P1's position
        assertEq(_pendingL(), 0);
        (uint256 r0, uint256 r1) = hook.requiredInventory(_cfg(LOWER, UPPER, L), pAfter);
        uint256 principalB = (aIs0 ? r1 : r0) - 1;
        uint256 gotB = _bal(b) - bBefore;
        emit log_named_decimal_uint("B returned by flush", gotB, 18);
        emit log_named_decimal_uint("B principal at deferral price", principalB, 18);
        assertApproxEqAbs(gotB, principalB + 7e18, 2, "flush = principal at frozen price + donation");
    }

    /*//////////////////////////////////////////////////////////////
                 Q7. OWNER WITHDRAWALS WHILE PENDING
    //////////////////////////////////////////////////////////////*/

    /// The owner can only withdraw the live balance; the parked position is invisible to `withdraw` and its flush is
    /// pure credit, so draining everything does not break the next swap. Separately: the recipient allowlist and
    /// the floor are set by the same owner, so a compromised owner key empties the hook in one batch.
    function test_Q7_withdrawAllWhilePending_flushStillSettles_allowlistNoDefence() public {
        bool aIs0 = Currency.unwrap(p1.currency0) == address(tA);
        Currency a = Currency.wrap(address(tA));
        Currency b = Currency.wrap(address(tB));
        hook.setMinSharedReserve(_one(a), _one(500e18));
        _forceDeferredSwap(p1, aIs0, -5e18);

        // "compromised owner": allowlist itself, zero the floor, withdraw everything live
        address[] memory who = new address[](1);
        bool[] memory yes = new bool[](1);
        (who[0], yes[0]) = (ATTACKER, true);
        hook.setWithdrawRecipient(who, yes);
        hook.setMinSharedReserve(_one(a), _one(0));
        Currency[] memory cs = new Currency[](2);
        uint256[] memory amts = new uint256[](2);
        (cs[0], cs[1], amts[0], amts[1]) = (a, b, _bal(a), _bal(b));
        hook.withdraw(cs, amts, ATTACKER);
        assertEq(_bal(a), 0);
        assertEq(_bal(b), 0);

        // next swap anywhere: the flush (pure take) succeeds and the parked funds come back as inventory
        _swap(p2, Currency.unwrap(p2.currency0) == address(tA), -1e18); // sell A into P2
        assertEq(_pendingL(), 0);
        assertGt(_bal(b), 0, "parked B recovered by flush");
    }

    /*//////////////////////////////////////////////////////////////
          Q9. afterSwap TAKE RUNS BEFORE THE SWAPPER PAYS
    //////////////////////////////////////////////////////////////*/

    /// The hook `take`s its net credit (the swap's input token) inside afterSwap, i.e. before the swapper's own
    /// settle. `take` is a physical transfer out of the vault, so the vault must already hold that much of the INPUT
    /// token from someone else. With the vault's physical balance of the input token at 0 the swap reverts; with the
    /// output token at 0 (input present) it succeeds.
    function test_Q9_afterSwapTake_needsPhysicalVaultBalanceOfInputToken() public {
        bool aIs0 = Currency.unwrap(p1.currency0) == address(tA);
        bytes4 panic = bytes4(keccak256("Panic(uint256)"));

        uint256 snap = vm.snapshotState();
        deal(address(tA), address(vault), 0); // input token (trader sells A)
        try trader.swap(p1, aIs0, -5e18, 0) {
            fail();
        } catch (bytes memory err) {
            assertTrue(_contains(err, panic), "vault transfer of A underflows");
        }
        vm.revertToState(snap);

        snap = vm.snapshotState();
        deal(address(tA), address(vault), 4e18); // less than the 5 A the hook takes
        vm.expectRevert();
        trader.swap(p1, aIs0, -5e18, 0);
        vm.revertToState(snap);

        deal(address(tB), address(vault), 0); // output token absent, input present: fine
        uint256 aHook = _bal(Currency.wrap(address(tA)));
        _swap(p1, aIs0, -5e18);
        assertApproxEqAbs(_bal(Currency.wrap(address(tA))) - aHook, 5e18, 2, "hook took the full input");
    }

    /*//////////////////////////////////////////////////////////////
                         Q8. PROTOCOL FEE
    //////////////////////////////////////////////////////////////*/

    /// A protocol fee is carved out of the swap fee before LP fee growth; the hook just earns less. The settle stays
    /// exact (same mirror as without), the hook's position is fully removed, and protocol fees accrue to the manager.
    function test_Q8_protocolFee_hookEarnsLess_accountingExact() public {
        uint256 snap = vm.snapshotState();
        uint256 v0 = _value(p1, SQRT_RATIO_1_1);
        _swapTo(p1, false, 300);
        _swapTo(p1, true, 0);
        uint256 gainNoPF = _value(p1, SQRT_RATIO_1_1) - v0;
        vm.revertToState(snap);

        address ctrl = makeAddr("pfController");
        poolManager.setProtocolFeeController(IProtocolFeeController(ctrl));
        vm.prank(ctrl);
        poolManager.setProtocolFee(p1, 1000 | (uint24(1000) << 12)); // 0.1% each direction

        v0 = _value(p1, SQRT_RATIO_1_1);
        uint256 h0 = _bal(p1.currency0);
        uint256 h1 = _bal(p1.currency1);
        BalanceDelta l1 = _swapTo(p1, false, 300);
        assertApproxEqAbs(int256(_bal(p1.currency0)) - int256(h0), -int256(l1.amount0()), 2, "mirror0");
        uint256 pf1 = poolManager.protocolFeesAccrued(p1.currency1);
        // hook receives the trader's input minus exactly the protocol fee the manager kept
        assertApproxEqAbs(int256(_bal(p1.currency1)) - int256(h1), -int256(l1.amount1()) - int256(pf1), 2, "mirror1");
        _swapTo(p1, true, 0);
        uint256 gainPF = _value(p1, SQRT_RATIO_1_1) - v0;
        uint256 pf = poolManager.protocolFeesAccrued(p1.currency0) + poolManager.protocolFeesAccrued(p1.currency1);

        emit log_named_decimal_uint("hook round-trip gain, no protocol fee", gainNoPF, 18);
        emit log_named_decimal_uint("hook round-trip gain, 0.1% protocol fee", gainPF, 18);
        emit log_named_decimal_uint("protocol fees accrued", pf, 18);
        assertGt(pf, 0);
        assertEq(_posL(p1, LOWER, UPPER), 0);
        assertGt(gainPF, 0);
    }
}
