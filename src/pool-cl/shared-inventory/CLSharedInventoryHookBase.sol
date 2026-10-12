// SPDX-License-Identifier: GPL-2.0-or-later
// Transient storage (`tstore`/`tload`, EIP-1153) requires Solidity >= 0.8.24 on a Cancun EVM. Pinned to 0.8.26
// to match the infinity-core dependency (which pins `pragma solidity 0.8.26`).
pragma solidity 0.8.26;

import {CLBaseHook} from "src/pool-cl/CLBaseHook.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {CLPoolParametersHelper} from "infinity-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "infinity-core/src/types/PoolId.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";
import {BalanceDelta} from "infinity-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "infinity-core/src/types/BeforeSwapDelta.sol";
import {TickMath} from "infinity-core/src/pool-cl/libraries/TickMath.sol";
import {LPFeeLibrary} from "infinity-core/src/libraries/LPFeeLibrary.sol";
import {LiquidityAmounts} from "src/pool-cl/full-range/libraries/LiquidityAmounts.sol";
import {Ownable, Ownable2Step} from "openzeppelin-contracts/contracts/access/Ownable2Step.sol";
import {ReentrancyGuardTransient} from "openzeppelin-contracts/contracts/utils/ReentrancyGuardTransient.sol";
import {TransientStorage} from "./libraries/TransientStorage.sol";
import {ICLSharedInventoryHook} from "./interfaces/ICLSharedInventoryHook.sol";

/// @title CLSharedInventoryHookBase
/// @notice PancakeSwap Infinity (CLAMM) hook that market-makes pools out of a **shared inventory**. Liquidity
///         is injected just-in-time in `beforeSwap` and withdrawn in `afterSwap`, all inside the same swap
///         transaction, so tokens are never idle-locked per pool.
/// @dev Mechanics:
///        - Any token pair may bind to this hook — there is no designated hub token.
///        - Owner sets an explicit `[tickLower, tickUpper]` range + fixed liquidity `L` per pool.
///        - `beforeSwap`: mint L into the pool; the owed payment is stashed, not paid yet.
///        - `afterSwap`: burn L and settle the injection netted against the removal — one settle/take per currency
///          (principal ± swap flow + LP fees), so each token moves at most once.
///        - Inventory is just the hook's live balance — no storage bookkeeping. There is one balance per token, so a
///          token common to several pools is inherently shared across them (a swap on any of those pools draws from
///          that balance); isolate a pool only by pairing tokens no other pool uses.
///        - Insufficient inventory or a breached cap reverts the swap.
///
///      All swap-path token movement uses the vault's flash-accounting: the swap runs inside a vault lock, and
///      the hook resolves its own currency deltas with `settle` (pay) / `take` (receive) within that same lock.
///
/// @dev Deferred removal (Infinity `reservesOfApp` ordering):
///      Infinity books a swap's incoming token to the pool manager's `reservesOfApp` only *after* `afterSwap`
///      returns (see `CLPoolManager.swap`). But when this hook removes its just-in-time position in `afterSwap`, the
///      position already holds the swap-in token the trader just pushed in — so removing it there would decrement
///      `reservesOfApp` below what has been booked and revert with an arithmetic underflow. Rather than require a
///      standing resident-liquidity buffer, the hook DEFERS: `afterSwap` tries the removal and, if it would
///      underflow, catches it, leaves the position live, and snapshots it (with its pool id) in `_pendingRemoval`.
///      The next swap's `beforeSwap` on ANY pool unwinds it first — by then the earlier swap has fully settled, its
///      input is booked to `reservesOfApp`, and the burn nets out safely. So a pool with only just-in-time liquidity
///      and no resident depth still swaps fine; at most one removal is ever pending across all pools.
///
/// @dev Inventory custody is abstract. This contract owns the full JIT lifecycle, config, controls and solvency
///      logic but does NOT hard-code WHERE inventory lives or HOW it moves: {_balanceOf}, {_settleToVault},
///      {_takeFromVault} and {_payOut} are `virtual` extension points a subclass implements. The standard
///      self-custody implementation ({CLSharedInventoryHook}) holds tokens in the hook itself; a future
///      subclass could instead route idle funds into a yield vault, overriding only those four hooks.
abstract contract CLSharedInventoryHookBase is
    CLBaseHook,
    Ownable2Step,
    ReentrancyGuardTransient,
    ICLSharedInventoryHook
{
    using PoolIdLibrary for PoolKey;
    using TransientStorage for bytes32;
    using CLPoolParametersHelper for bytes32;
    using LPFeeLibrary for uint24;

    /// @dev Empty hook data for `modifyLiquidity` calls.
    bytes internal constant ZERO_BYTES = "";

    /// @dev Salt for the hook's just-in-time position. It injects and fully removes within a single swap, so one
    ///      fixed salt suffices; a namespaced constant keeps this position distinct from any other position the
    ///      hook might ever open at the same tick range.
    /// @dev = keccak256("CLSharedInventoryHook.position")
    bytes32 internal constant POSITION_SALT = 0x2dd421f327b24150303d8f1213699124a1c7bb24e1d9d96ac0280c16e513b260;

    /// @dev This hook's fixed registration bitmap (`beforeInitialize | beforeSwap | afterSwap`), derived once at
    ///      deploy from {_hookPermissions}. Cached as an immutable so the config/validation paths read it straight
    ///      from bytecode instead of rebuilding the 14-field `Permissions` struct on every call (measured ~1.3k gas
    ///      cheaper per bitmap-using call — the memory-struct build isn't fully folded even under via_ir).
    uint16 private immutable _registrationBitmap;

    /// @dev Inventory is not tracked in storage — it is simply the hook's live balance of each token
    ///      ({inventoryOf} reads it on demand). There is no designated hub token: the hook holds one balance per
    ///      currency, and any token common to several pools is inherently shared across them — a swap on any of those
    ///      pools draws from that common per-token balance. Give a pool an isolated reserve only by pairing tokens no
    ///      other pool uses.

    /// @notice Per-currency reserve floor a swap's persistent (post-swap) balance may never dip below (circuit
    ///         breaker). Keyed by currency, so the owner can protect each token's shared balance independently;
    ///         0 (the default) disables the floor for that currency.
    /// @dev CROSS-POOL CONTAGION: because the floor is keyed by CURRENCY (matching the one shared balance per
    ///      token), every pool using that token shares the same floor — and therefore its circuit-breaker behavior.
    ///      If one pool's flow drains the shared balance to the floor (e.g. panic selling into it during a depeg of
    ///      its paired token), swaps that would further reduce that token revert {MinSharedReserveBreached} on ALL
    ///      pools sharing it, including pools whose own pair is unaffected. The block is one-directional: swaps that
    ///      ADD the token back still succeed and can lift the breach. This is inherent to shared inventory — the
    ///      floor protects the common balance, not any single pool's availability; the only isolation is to avoid
    ///      token overlap across pools.
    mapping(Currency currency => uint256 minReserve) public minSharedReserve;

    /// @notice The longest a timed swap halt ({setSwapPausedFor}) may last: 10 minutes.
    uint256 public constant MAX_SWAP_PAUSE = 10 minutes;

    /// @notice The minimum spacing between timed swap halts: a new halt may only be set once a full day has
    ///         elapsed past the previous halt's end (see {setSwapPausedFor}).
    uint256 public constant SWAP_PAUSE_COOLDOWN = 1 days;

    /// @dev Global control switches, packed into a single storage slot (bool + bool + bool + bool + uint40 = 9 bytes).
    /// @param jitPaused              when true, swaps still fill on resident liquidity but the hook injects NO
    ///                               just-in-time liquidity (a soft kill-switch for market-making, not for trading).
    /// @param restrictedPoolCreation when true, only whitelisted creators may initialize a pool with this hook.
    /// @param requireEnabledConfig   when true, a pool may only be initialized if it already has an ENABLED PoolConfig
    ///                               (pre-configured via {setUninitializePoolConfigs}); default false.
    /// @param disableDeferredRemoval when true, an `afterSwap` removal that would underflow is NOT deferred — the swap
    ///                               reverts {RemovalDeferralDisabled} instead (so pools must carry a resident buffer);
    ///                               default false.
    /// @param swapPausedUntil        unix time before which ALL swaps on this hook revert — a short, timed hard halt
    ///                               (max {MAX_SWAP_PAUSE}); 0 means no halt.
    struct Controls {
        bool jitPaused;
        bool restrictedPoolCreation;
        bool requireEnabledConfig;
        bool disableDeferredRemoval;
        uint40 swapPausedUntil;
    }

    /// @dev The packed global switches. Read via {jitPaused} / {restrictedPoolCreation} / {requireEnabledConfig} /
    ///      {disableDeferredRemoval} / {swapPausedUntil}.
    Controls private _controls;

    /// @notice Addresses allowed to create (initialize) pools with this hook. The gate checks `tx.origin` (pool
    ///         creation usually routes through periphery), so the whitelist is keyed by the ORIGINATING account —
    ///         the account that signed the outer transaction. A contract / multisig can never be `tx.origin`, so
    ///         it cannot act as the whitelisted creator, and account-abstraction / EIP-4337 flows (where
    ///         `tx.origin` is a bundler / entry point) won't match either. NOTE (EIP-7702 / Pectra): an
    ///         originating account is no longer necessarily a plain EOA — a whitelisted account may carry a 7702
    ///         delegation, making it a programmable smart account that is still `tx.origin`. The gate itself is
    ///         unaffected (a non-whitelisted attacker cannot forge a whitelisted origin), but do NOT reason about
    ///         this whitelist assuming its members cannot run contract code. Standard `tx.origin` caveats apply.
    mapping(address creator => bool allowed) public isPoolCreator;

    /// @notice Addresses {withdraw} is allowed to send to. A withdrawal to a non-whitelisted `to` reverts. This caps
    ///         where inventory can leave the hook, so a compromised withdraw key can only move funds to a
    ///         pre-approved destination (treasury). Managed via {setWithdrawRecipient}; empty by default (so no
    ///         withdrawal is possible until the owner approves a recipient).
    mapping(address recipient => bool allowed) public isWithdrawRecipient;

    /// @notice Per-pool owner-approved initial price that OPENS a pool to permissionless creation. When
    ///         `permissionlessInitSqrtPriceX96[id]` is non-zero, anyone may initialize that pool WITHOUT being a
    ///         whitelisted {isPoolCreator} — but only at exactly that `sqrtPriceX96`. Any other starting price still
    ///         falls back to the whitelist gate, so a permissionless creator can never pick an arbitrary/manipulated
    ///         initial price. 0 (the default) leaves the pool behind the normal whitelist. Set via
    ///         {setInitialSqrtPrice}.
    /// @dev SECURITY — before opening a pool this way, do BOTH: (1) pre-configure it with {setPoolConfigs}, and
    ///      (2) transfer the two tokens that config needs into this hook. That makes the hook's just-in-time
    ///      liquidity live from the very first swap. Pinning the initial price only fixes the STARTING point; a pool
    ///      that is initialized (even at the approved price) but left unfunded / unconfigured sits with little or no
    ///      liquidity, and anyone could then swap it to skew the price cheaply before the owner reacts. Pre-funding
    ///      plus pre-config are what keep the price defensible from swap one.
    mapping(PoolId poolId => uint160 sqrtPriceX96) public permissionlessInitSqrtPriceX96;

    /// @dev Per-pool config; exposed via {getPoolConfig}.
    mapping(PoolId => PoolConfig) internal _poolConfig;

    /// @dev A deferred just-in-time removal: which pool's position is parked (`id`), plus a snapshot of the injected
    ///      config (`cfg`) identifying the exact position to burn. See {_pendingRemoval}.
    struct PendingRemoval {
        PoolId id;
        PoolConfig cfg;
    }

    /// @dev The single outstanding deferred removal across ALL pools — at most one exists at a time, because every
    ///      `beforeSwap` flushes it before its own `afterSwap` could record a new one. Recorded on defer in
    ///      `_afterSwap` (Infinity books a swap's input token to the pool manager's reservesOfApp only after the swap
    ///      fully settles, so removing in `afterSwap` can underflow that ledger; when it would, the position is left
    ///      live and snapshotted here) and unwound at the start of the NEXT swap on ANY pool. The pool id is stored
    ///      precisely because that flushing swap may be on a DIFFERENT pool: its key is rebuilt from `id` via
    ///      {_keyOf}. `cfg` snapshots the injected tick range + liquidity so the exact live position is burned even
    ///      if that pool's config changed since; `cfg.liquidity == 0` means nothing is pending. Persistent storage —
    ///      it intentionally survives across transactions, unlike the in-swap active flag.
    PendingRemoval internal _pendingRemoval;

    /// @dev Transient-storage (EIP-1153) slot for the in-swap guard flag. It is set true while a just-in-time position
    ///      injected in `beforeSwap` awaits removal in `afterSwap`, and auto-clears at end of tx. Because it lives
    ///      only for the current transaction there is no cross-tx state to reset. Everything needed to unwind the
    ///      position (tick range, liquidity, currency ordering) is re-derived in `afterSwap` from the pool config
    ///      and key — the swap is atomic, so none of it can change in between. Also doubles as a nested-swap /
    ///      in-swap-withdrawal guard.
    /// @dev = keccak256("CLSharedInventoryHook._active")
    bytes32 private constant _ACTIVE_SLOT = 0x31c99ba5c98d3b67c3624eeceb1136aa211af0b6ad3c1b86da04e5f639f4bc07;

    /// @dev Transient-storage (EIP-1153) slot holding the `beforeSwap` injection's `BalanceDelta` (what the hook
    ///      owes for minting L). Payment is deferred: `afterSwap` reads it and settles it netted against the removal
    ///      delta (or alone if the removal is deferred), so each currency moves at most once. Only read while the
    ///      active flag is set (i.e. we actually injected this swap), so a stale value is never used; auto-clears at
    ///      end of tx.
    /// @dev = keccak256("CLSharedInventoryHook.injectDelta")
    bytes32 private constant _INJECT_DELTA_SLOT = 0x6465497318df1b27041d905f1ae053ac0b694d055237764aa05464adba4bca0c;

    /// @param _poolManager the Infinity CL pool manager this hook binds to
    /// @param _owner the initial owner (Ownable2Step); pass the intended owner directly rather than relying on the
    ///        deployer, e.g. a factory can set a multisig / the role-based owner contract as owner at deploy time.
    ///        Reverts (via Ownable) if zero.
    constructor(ICLPoolManager _poolManager, address _owner) CLBaseHook(_poolManager) Ownable(_owner) {
        _registrationBitmap = _hooksRegistrationBitmapFrom(_hookPermissions());
        _controls.restrictedPoolCreation = true; // pool creation is whitelisted by default
    }

    /// @notice Accepts native currency, both for owner funding and for `vault.take` payouts on native pools.
    receive() external payable {}

    function _isActive() private view returns (bool) {
        return _ACTIVE_SLOT.tloadBool();
    }

    function _setActive(bool value) private {
        _ACTIVE_SLOT.tstore(value);
    }

    /// @dev Resolve a REGISTERED pool's currencies, hook and parameters from its id via the pool manager's registry,
    ///      asserting the pool exists and is bound to THIS hook. Reverts {PoolNotInitialized} if the id is
    ///      unregistered (both currencies zero), or {InvalidHook} if it maps to a pool bound to a different hook.
    /// @dev Unlike the PoolKey path ({_validatePoolKey}), the rest of the key (fee, tickSpacing, parameters bitmap,
    ///      currency ordering) is NOT re-validated here: the pool manager already validated all of it against this
    ///      hook when the pool was initialized. So once `hooks == address(this)`, the whole key is known-good — the
    ///      hooks address being ours is sufficient proof. `parameters` is returned so the caller can read the pool's
    ///      tickSpacing (for the config-time alignment check) without a second registry read.
    function _resolvePool(PoolId id)
        private
        view
        returns (Currency currency0, Currency currency1, IHooks hooks, bytes32 parameters)
    {
        (currency0, currency1, hooks,,, parameters) = poolManager.poolIdToPoolKey(id);
        if (Currency.unwrap(currency0) == address(0) && Currency.unwrap(currency1) == address(0)) {
            revert PoolNotInitialized();
        }
        if (address(hooks) != address(this)) revert InvalidHook();
    }

    /*//////////////////////////////////////////////////////////////
                   INVENTORY CUSTODY (virtual extension points)
    //////////////////////////////////////////////////////////////*/

    /// @dev VIRTUAL. The available inventory of `currency` — the figure all solvency / floor checks and the
    ///      {inventoryOf} view read against. The default self-custody implementation returns the hook's own live
    ///      balance (native-aware); an override may custody inventory elsewhere (e.g. idle funds parked in a yield
    ///      vault) and report the amount currently drawable here.
    function _balanceOf(Currency currency) internal view virtual returns (uint256);

    /// @dev VIRTUAL. Pay `amount` of `currency` from inventory to the vault, resolving a negative swap-path delta
    ///      (an injection the hook owes). The default settles straight from the hook's own balance; an override must
    ///      first make the funds available to the vault (e.g. redeeming them from wherever inventory is custodied).
    ///      Called only after {_settleNet} has checked `_balanceOf(currency) >= amount`.
    function _settleToVault(Currency currency, uint256 amount) internal virtual;

    /// @dev VIRTUAL. Receive `amount` of `currency` from the vault into inventory, resolving a positive swap-path
    ///      delta (a removal credit). The default takes into the hook's own balance; an override may forward the
    ///      received funds on to wherever inventory is custodied.
    function _takeFromVault(Currency currency, uint256 amount) internal virtual;

    /// @dev VIRTUAL. Send `amount` of `currency` out of inventory to `to`, for the owner {withdraw} path. The
    ///      default transfers from the hook's own balance; an override must source it from wherever inventory is
    ///      custodied. Called only after {_withdraw} has checked the balance and reserve floor.
    function _payOut(Currency currency, address to, uint256 amount) internal virtual;

    /*//////////////////////////////////////////////////////////////
                              HOOK PERMISSIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Registers `beforeInitialize`, `beforeSwap` and `afterSwap`; this bitmap must equal the first
    ///         16 bits of every pool's `PoolKey.parameters` (validated on initialize).
    function getHooksRegistrationBitmap() external view override returns (uint16) {
        return _registrationBitmap;
    }

    function _hookPermissions() private pure returns (Permissions memory) {
        return Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /*//////////////////////////////////////////////////////////////
                               INITIALIZE
    //////////////////////////////////////////////////////////////*/

    /// @dev Gates pool creation on the creator whitelist and rejects dynamic-fee pools (unsupported). Any token pair
    ///      may bind — there is no designated hub token; inventory is shared across pools through whatever tokens
    ///      they have in common (see the inventory note above).
    /// @dev Creation gate: normally the creator must be whitelisted ({isPoolCreator}, checked against `tx.origin` —
    ///      the outer-transaction signer, which since EIP-7702 may be a delegated smart account rather than a plain
    ///      EOA; contract / multisig creators and account-abstraction flows don't satisfy it). The whitelist is
    ///      BYPASSED for a pool the owner has explicitly opened via {permissionlessInitSqrtPriceX96}, but only when
    ///      the pool is initialized at EXACTLY that approved price — pinning the price stops a permissionless creator
    ///      from opening the pool at an arbitrary/manipulated starting point. See the security note on that mapping
    ///      for the recommended pre-config + pre-funding steps.
    function _beforeInitialize(address, PoolKey calldata key, uint160 sqrtPriceX96)
        internal
        view
        override
        returns (bytes4)
    {
        if (_controls.restrictedPoolCreation && !isPoolCreator[tx.origin]) {
            uint160 approvedPrice = permissionlessInitSqrtPriceX96[key.toId()];
            if (approvedPrice == 0 || sqrtPriceX96 != approvedPrice) revert NotPoolCreator();
        }
        // When enabled, a pool may only be created if it already has an ENABLED PoolConfig (pre-configured via
        // {setUninitializePoolConfigs}) — so no pool bound to this hook can go live without JIT market-making set up.
        if (_controls.requireEnabledConfig && !_poolConfig[key.toId()].enabled) revert PoolConfigNotEnabled();
        if (key.fee.isDynamicLPFee()) revert InvalidFee();
        return this.beforeInitialize.selector;
    }

    /*//////////////////////////////////////////////////////////////
                          POSITION INJECT / WITHDRAW
    //////////////////////////////////////////////////////////////*/

    /// @dev Injects the configured just-in-time liquidity and pays for it out of inventory. If just-in-time is unavailable for this
    ///      pool (paused / disabled / no config), the swap is left to proceed untouched on any resident liquidity.
    function _beforeSwap(address, PoolKey calldata key, ICLPoolManager.SwapParams calldata, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        // Load the packed global switches once (one SLOAD).
        Controls memory ctrl = _controls;

        // Timed hard halt: while `swapPausedUntil` is in the future, ALL swaps on this hook revert (the owner can
        // freeze trading for up to `MAX_SWAP_PAUSE`, e.g. around an incident). Distinct from `jitPaused`, which only
        // stops injection but lets swaps fill on resident liquidity.
        if (block.timestamp < ctrl.swapPausedUntil) revert SwapPaused(ctrl.swapPausedUntil);

        // Re-entrant / nested swap into the same hook would break the inject/remove pairing; reject it.
        if (_isActive()) revert SwapInProgress();

        // Raise the in-swap guard up front, BEFORE the pending-removal flush below — the flush moves tokens
        // (`settle` / `take`), and a token callback must not be able to re-enter this hook's swap path in that
        // window. The flag does double duty: it is also `_afterSwap`'s signal that an injection is live and must be
        // removed. So every early `return` that does NOT inject (paused/disabled/L==0, or the underfunded skip) MUST
        // clear it again before returning, or `_afterSwap` would try to remove a position that was never minted. The
        // flag lives in transient storage; it clears at tx end.
        _setActive(true);

        // Flush the outstanding deferred removal (if any) BEFORE doing anything else. It may belong to a DIFFERENT
        // pool than this swap's — that earlier swap has fully settled, so its input token is now booked to the pool
        // manager's reservesOfApp and unwinding the parked position is safe here (see the deferred-removal note in
        // `_afterSwap`). Run independent of paused/disabled — a deferred position must always remain reclaimable, and
        // flushing it now keeps at most one pending across all pools. Skipped only when `disableDeferredRemoval` is on:
        // in that mode `_afterSwap` never defers, and the setter forbids enabling it while a pending exists, so there
        // is provably nothing to flush — skipping saves the `_pendingRemoval` SLOAD on every swap.
        if (!ctrl.disableDeferredRemoval) _flushPendingRemoval();

        PoolId id = key.toId();
        PoolConfig memory cfg = _poolConfig[id];

        // Graceful skip: never brick trading just because just-in-time is off for this pool. Nothing was injected,
        // so clear the guard raised above — otherwise `_afterSwap` would try to remove a position that was never
        // minted (its `!_isActive()` check must see the flag cleared here).
        if (ctrl.jitPaused || !cfg.enabled || cfg.liquidity == 0) {
            _setActive(false);
            return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        // Mint L into the pool. Adding liquidity yields a non-positive delta (the hook owes both legs). Nothing is
        // paid here: injecting L only books the owed amount to reservesOfApp and leaves the hook a vault delta.
        // Payment is deferred to `afterSwap`, where this delta is netted against the removal and settled once per
        // currency — and it is THERE ({_settleNet}) that solvency is enforced: the hook only ever needs to cover the
        // NET movement, and if it can't, the settle reverts and the whole swap unwinds. There is no per-price
        // "skip when underfunded" preflight (it made JIT flip on/off with the price, which was front-runnable):
        // a swap either injects and settles, or reverts as a whole.
        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            key,
            ICLPoolManager.ModifyLiquidityParams({
                tickLower: cfg.tickLower,
                tickUpper: cfg.tickUpper,
                liquidityDelta: int256(uint256(cfg.liquidity)),
                salt: POSITION_SALT
            }),
            ZERO_BYTES
        );

        // Stash the injection delta for `afterSwap` to settle. It survives to `afterSwap` in the same tx and is only
        // read while the active flag (raised at the top of this call and, on this successful path, never cleared) is
        // on, so it can't be mistaken for a stale value.
        _INJECT_DELTA_SLOT.tstore(BalanceDelta.unwrap(delta));

        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /// @dev Removes the just-in-time position and folds the returned tokens (principal ± swap flow + LP fees) back into
    ///      inventory. No-op if `beforeSwap` skipped injection for this swap. If the removal can't settle yet (see the
    ///      deferred-removal note below) it is deferred to the next swap's `beforeSwap` instead of reverting.
    function _afterSwap(address, PoolKey calldata key, ICLPoolManager.SwapParams calldata, BalanceDelta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        // Nothing to remove unless `beforeSwap` actually injected. It raises the active flag up front (to guard the
        // flush) but CLEARS it again on every skip path (paused/disabled/L==0 or the underfunded preflight), so the
        // flag is still set here iff an injection is live — otherwise no-op and keep whatever filled on resident
        // liquidity.
        if (!_isActive()) return (this.afterSwap.selector, int128(0));

        PoolId id = key.toId();
        PoolConfig memory cfg = _poolConfig[id];

        // The `beforeSwap` injection was booked but NOT paid; its (owed) delta is stashed here. Payment happens
        // below, netted against the removal so each currency moves at most once.
        BalanceDelta injectDelta = BalanceDelta.wrap(_INJECT_DELTA_SLOT.tloadInt256());

        // Unwind the just-in-time position, then enforce the reserve floors.
        //
        // Infinity books a swap's input token to the pool manager's reservesOfApp only AFTER this callback returns,
        // but the position we're removing already holds that just-swapped-in token — so unwinding it here would
        // drive reservesOfApp negative and revert with an arithmetic underflow. If that happens, don't fail the
        // swap: leave the position live, snapshot it, and unwind it at the start of the next swap on ANY pool (by
        // then the input is booked and the removal nets out safely). This removes the need for any standing
        // resident-liquidity buffer. Removing the exact L injected: tick range + liquidity come from config, and the
        // swap is atomic so they match what `beforeSwap` injected.
        try poolManager.modifyLiquidity(key, _removalParams(cfg), ZERO_BYTES) returns (
            BalanceDelta removeDelta, BalanceDelta feeDelta
        ) {
            // Removed inline: settle the injection netted against the removal — one settle/take per currency instead
            // of paying the injection then taking the removal separately — then check the floors on the REAL
            // persistent post-swap balances (the position is fully unwound into them; exact, fees included).
            _collectRemoval(id, key, injectDelta + removeDelta, feeDelta);
            _enforceFloors(id, key, cfg, false);
        } catch {
            // The removal would underflow. Normally we defer it (below); but if the owner has disabled deferral, fail
            // the whole swap instead — pools must then carry a resident buffer so removals always settle inline.
            if (_controls.disableDeferredRemoval) revert RemovalDeferralDisabled();

            // Deferred: the removal would underflow, so the position stays live and there is no removal delta to net.
            // Pay the injection alone now (it is still unpaid), enforce the floors on the EFFECTIVE holdings (live
            // balance + the still-parked position), then record the position for the next swap to unwind.
            _settleNet(key, injectDelta);
            _enforceFloors(id, key, cfg, true);

            _pendingRemoval = PendingRemoval({id: id, cfg: cfg});
            emit JitRemovalDeferred(id);
        }

        _setActive(false);

        return (this.afterSwap.selector, int128(0));
    }

    /// @dev Enforce the per-currency `minSharedReserve` floors, reverting {MinSharedReserveBreached} if either side's
    ///      post-swap holdings fall below its floor. Reads the floors FIRST and returns immediately when both are 0
    ///      (the default) — so the balance reads, and on the deferred path the slot0 + amount math, are skipped
    ///      entirely when floors are disabled.
    /// @param positionStillLive distinguishes the callers:
    ///        - false (inline removal): the position is unwound into the balance, so the live balance IS the holding.
    ///        - true (deferred removal): the position is still parked, so its PRINCIPAL at the current price is added
    ///          to the live balance. That principal omits this swap's LP fees (still uncollected in the position), so
    ///          the effective figure is a slight UNDER-count — deliberately conservative for a floor (it can only
    ///          trip up to ~one swap's fee early, never miss a real breach; the exact fee can't be read without
    ///          realizing the position, which would hit the very underflow we're deferring around).
    function _enforceFloors(PoolId id, PoolKey calldata key, PoolConfig memory cfg, bool positionStillLive)
        private
        view
    {
        uint256 min0 = minSharedReserve[key.currency0];
        uint256 min1 = minSharedReserve[key.currency1];
        if (min0 == 0 && min1 == 0) return; // floors disabled — skip the balance reads (and price/amount math) below

        uint256 bal0 = _balanceOf(key.currency0);
        uint256 bal1 = _balanceOf(key.currency1);
        if (positionStillLive) {
            (uint256 positionAmount0, uint256 positionAmount1) = _requiredAmounts(id, cfg);
            bal0 += positionAmount0;
            bal1 += positionAmount1;
        }
        if (bal0 < min0 || bal1 < min1) revert MinSharedReserveBreached(id, bal0, min0, bal1, min1);
    }

    /// @dev Unwinds the single outstanding deferred removal, if any. Called at the top of every `beforeSwap`. The
    ///      pending pool may differ from the swapping pool, so its key is rebuilt from the stored id. Safe: the swap
    ///      that deferred it has fully settled (its input is booked to reservesOfApp), so the burn nets out without
    ///      underflow. If the removal DOES revert (e.g. the position's token became un-transferable — freeze /
    ///      blacklist / pause — after it was deferred), this reverts and, since it runs at the top of every
    ///      `beforeSwap`, halts swaps on every pool until the owner clears the record. Recovery: the owner calls
    ///      {emergencyRemoveLiquidity} — with `liquidity == 0` it drops the record without any vault interaction (so
    ///      it cannot itself revert on the stuck token), leaving the position live to reclaim once transfers work again.
    function _flushPendingRemoval() private {
        // Fast path: nothing pending. Read only the sentinel field (`cfg.liquidity`, one storage slot) and bail
        // before touching the `id` slot — a live position always has liquidity > 0, so this is an exact test. Every
        // swap runs this; a pool that isn't carrying a deferred removal (e.g. any pool with a resident buffer) thus
        // pays just a single SLOAD here instead of loading the whole struct.
        if (_pendingRemoval.cfg.liquidity == 0) return;

        // Possible optimization we deliberately skip: when the incoming swap is on the SAME pool as `pending` AND
        // its config is unchanged (same tick range + liquidity), the still-live pending position is byte-for-byte
        // what `beforeSwap` is about to re-inject — already paid for, at the right range/L, at the same price (no
        // swaps happened in between). One could then skip BOTH this removal and the re-injection and just reuse the
        // live position (a busy bufferless pool would inject once and reuse it across many swaps, rather than churn
        // remove+take+re-add every swap). We don't: it only ever helps pools that defer, and it costs real
        // complexity — a same-pool/same-config branch in `beforeSwap`, a "no injection delta to settle" path in
        // `afterSwap` (the reused position is already paid), and a fallback to remove+re-inject when the config did
        // change. We always remove here for one uniform, easy-to-audit path.
        PendingRemoval memory pending = _pendingRemoval;
        delete _pendingRemoval;
        PoolKey memory key = _keyOf(pending.id);
        // Remove inline and let any failure REVERT the whole swap. We intentionally do NOT catch-and-abandon here: an
        // auto-abandon path can be griefed (an attacker can transiently drain the vault so this take reverts, forcing
        // the record to be dropped and the position stranded). If the burn/settle ever genuinely fails, the swap
        // reverts and the owner recovers via {emergencyRemoveLiquidity} (see the doc above).
        (BalanceDelta delta, BalanceDelta feeDelta) =
            poolManager.modifyLiquidity(key, _removalParams(pending.cfg), ZERO_BYTES);
        _collectRemoval(pending.id, key, delta, feeDelta);
    }

    /// @dev Rebuilds a pool's key from its id, to flush a deferred removal that may belong to a different pool.
    ///      `hooks` is this contract and `poolManager` is ours; currencies/fee/parameters come from the registry.
    function _keyOf(PoolId id) private view returns (PoolKey memory key) {
        (Currency currency0, Currency currency1,,, uint24 fee, bytes32 parameters) = poolManager.poolIdToPoolKey(id);
        key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: IHooks(address(this)),
            poolManager: poolManager,
            fee: fee,
            parameters: parameters
        });
    }

    /// @inheritdoc ICLSharedInventoryHook
    /// @dev EMERGENCY ONLY — not used in normal operation (removals happen automatically in `afterSwap` / the flush).
    ///      Acquires a vault lock (removals must run inside one). Only the hook's own positions exist, all under
    ///      `POSITION_SALT`, so the salt is fixed and only the pool + range + liquidity are supplied. If a deferred
    ///      removal is pending for this SAME pool, it is cleared here (see the inline comment); a pending removal for a
    ///      DIFFERENT pool is left untouched. Passing `liquidity == 0` does NOT revert — it just clears any same-pool
    ///      pending record and skips the burn (a way to drop a stuck record without touching the vault).
    function emergencyRemoveLiquidity(
        PoolKey calldata key,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint256 amount0Min,
        uint256 amount1Min
    ) external override onlyOwner nonReentrant {
        if (address(key.hooks) != address(this)) revert InvalidHook();

        // Clear a deferred removal pending for this SAME pool. Do it up front: if this call burns the position below,
        // the record would otherwise point at a position that no longer exists, so the next swap's
        // `_flushPendingRemoval` would call `modifyLiquidity(-L)` on it and revert — and since the flush runs at the
        // top of every `beforeSwap`, that would brick swaps on EVERY pool until the record is cleared. Matching by pool
        // id is enough: the hook keeps a single deferred position, tracked by its pool id. (The whole function is
        // atomic, so if the burn below reverts this delete rolls back with it.) A pending for a DIFFERENT pool stays.
        if (_pendingRemoval.cfg.liquidity != 0 && PoolId.unwrap(_pendingRemoval.id) == PoolId.unwrap(key.toId())) {
            PoolConfig memory pendingCfg = _pendingRemoval.cfg;
            delete _pendingRemoval;
            emit PendingRemovalAbandoned(key.toId(), pendingCfg);
        }

        // Nothing to burn: `liquidity == 0` is a no-op removal (used to only clear the pending record above), so skip
        // the vault lock rather than reverting.
        if (liquidity == 0) return;

        vault.lock(
            abi.encodeCall(
                this.emergencyRemoveLiquidityCallback, (key, tickLower, tickUpper, liquidity, amount0Min, amount1Min)
            )
        );
    }

    /// @dev Vault lock callback for {emergencyRemoveLiquidity}. Reached only through this contract's own `vault.lock`
    ///      (routed via the inherited `lockAcquired`), hence `selfOnly`.
    function emergencyRemoveLiquidityCallback(
        PoolKey calldata key,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint256 amount0Min,
        uint256 amount1Min
    ) external selfOnly {
        (BalanceDelta delta, BalanceDelta feeDelta) = poolManager.modifyLiquidity(
            key,
            ICLPoolManager.ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: -int256(uint256(liquidity)),
                salt: POSITION_SALT
            }),
            ZERO_BYTES
        );
        // Slippage guard: the tokens a removal returns depend on the CURRENT pool price (a position pushed out of
        // range comes back single-sided), so a front-runner could move the price so the owner reclaims a lopsided
        // split. `delta` is a pure credit (principal + fees, both legs >= 0); require each leg to meet the caller's
        // minimum. Size the mins at the expected price; pass 0 to opt out (e.g. a token that only allows one side).
        uint256 got0 = delta.amount0() > 0 ? uint256(uint128(delta.amount0())) : 0;
        uint256 got1 = delta.amount1() > 0 ? uint256(uint128(delta.amount1())) : 0;
        if (got0 < amount0Min || got1 < amount1Min) revert RemovalBelowMin(got0, amount0Min, got1, amount1Min);

        // Take principal + any accrued fees back into inventory (removal delta is a pure credit → all takes), and
        // emit FeesEarned when the position had accrued LP fees — same reporting as the normal removal paths.
        PoolId id = key.toId();
        _collectRemoval(id, key, delta, feeDelta);
        emit OwnerLiquidityRemoved(id, tickLower, tickUpper, liquidity);
    }

    /// @dev Params to burn the just-in-time position described by `cfg` (the one injected under `POSITION_SALT`).
    function _removalParams(PoolConfig memory cfg) private pure returns (ICLPoolManager.ModifyLiquidityParams memory) {
        return ICLPoolManager.ModifyLiquidityParams({
            tickLower: cfg.tickLower,
            tickUpper: cfg.tickUpper,
            liquidityDelta: -int256(uint256(cfg.liquidity)),
            salt: POSITION_SALT
        });
    }

    /// @dev Reports the LP fees earned on a removal and resolves the given net `delta` with the vault. `feeDelta` is
    ///      the LP-fee portion (reported via {FeesEarned}). `delta` is the amount to close out per currency: the raw
    ///      removal delta on the flush path (always a credit → all takes), or the injection+removal net on the inline
    ///      `afterSwap` path (one settle + one take).
    function _collectRemoval(PoolId id, PoolKey memory key, BalanceDelta delta, BalanceDelta feeDelta) private {
        // Report LP fees only when the removal actually earned some. `feeDelta` is non-negative (fees are owed TO the
        // position), so a nonzero packed delta ⟺ at least one leg is positive — one int256 compare on the whole
        // delta both gates the LOG and lets us skip the per-leg extraction on a zero-fee removal (e.g. a zero-fee
        // pool, or a swap too small to accrue a wei).
        if (feeDelta != BalanceDelta.wrap(0)) {
            uint256 fee0 = feeDelta.amount0() > 0 ? uint256(uint128(feeDelta.amount0())) : 0;
            uint256 fee1 = feeDelta.amount1() > 0 ? uint256(uint128(feeDelta.amount1())) : 0;
            emit FeesEarned(id, fee0, fee1);
        }

        _settleNet(key, delta);
    }

    /// @dev Closes out a net `BalanceDelta` with the vault, per currency: {_settleToVault} (pay from inventory) a
    ///      negative leg, {_takeFromVault} (receive into inventory) a positive one, skip a zero leg. Where inventory
    ///      physically lives is delegated to those virtual hooks; the default self-custody impl uses the hook's own
    ///      ERC-20 / native balance with no separate bookkeeping.
    /// @dev This is where swap-path solvency is enforced: before paying a leg, require the hook's live balance to
    ///      cover it, reverting {InsufficientInventoryToSettle} otherwise. The hook only ever needs to fund the NET
    ///      movement (injection netted against removal), so this is both the correct and least-restrictive place to
    ///      check — an underfunded swap reverts as a whole rather than partially settling.
    function _settleNet(PoolKey memory key, BalanceDelta delta) private {
        int128 net0 = delta.amount0();
        int128 net1 = delta.amount1();
        if (net0 < 0) {
            uint256 owe0 = uint256(uint128(-net0));
            uint256 bal0 = _balanceOf(key.currency0);
            if (bal0 < owe0) revert InsufficientInventoryToSettle(key.toId(), key.currency0, bal0, owe0);
            _settleToVault(key.currency0, owe0);
        } else if (net0 > 0) {
            _takeFromVault(key.currency0, uint256(uint128(net0)));
        }
        if (net1 < 0) {
            uint256 owe1 = uint256(uint128(-net1));
            uint256 bal1 = _balanceOf(key.currency1);
            if (bal1 < owe1) revert InsufficientInventoryToSettle(key.toId(), key.currency1, bal1, owe1);
            _settleToVault(key.currency1, owe1);
        } else if (net1 > 0) {
            _takeFromVault(key.currency1, uint256(uint128(net1)));
        }
    }

    /*//////////////////////////////////////////////////////////////
                            CONFIG (owner)
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ICLSharedInventoryHook
    /// @dev PoolId path: resolves each pool's currencies and hook from the pool manager (so the pool MUST already
    ///      exist — an unregistered id reverts {PoolNotInitialized}) and reads its CURRENT price from slot0. Because
    ///      that live price is manipulable, the caller passes `maxRequired0[i]` / `maxRequired1[i]` (sized off-chain
    ///      at the expected price): if the observed price yields a larger requirement the call reverts
    ///      {RequiredExceedsMax}, so a front-runner can't get the config (and its `L`) committed at a manipulated
    ///      price. Pass `type(uint256).max` to opt out. To configure pools ahead of their creation, use
    ///      {setUninitializePoolConfigs}. There is no single-entry variant (bytecode economy): pass one-element
    ///      arrays, or use the owner contract's single-entry convenience wrapper.
    function setPoolConfigs(
        PoolId[] calldata ids,
        PoolConfig[] calldata cfgs,
        bool checkSolvency,
        uint256[] calldata maxRequired0,
        uint256[] calldata maxRequired1
    ) external override onlyOwner returns (uint256[] memory required0, uint256[] memory required1) {
        if (ids.length != cfgs.length || ids.length != maxRequired0.length || ids.length != maxRequired1.length) {
            revert ArrayLengthMismatch();
        }
        required0 = new uint256[](ids.length);
        required1 = new uint256[](ids.length);
        for (uint256 i = 0; i < ids.length; i++) {
            (Currency currency0, Currency currency1,, bytes32 parameters) = _resolvePool(ids[i]);
            (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(ids[i]);
            (required0[i], required1[i]) = _applyPoolConfig(
                ids[i],
                currency0,
                currency1,
                sqrtPriceX96,
                parameters.getTickSpacing(),
                cfgs[i],
                checkSolvency,
                maxRequired0[i],
                maxRequired1[i]
            );
        }
    }

    /// @inheritdoc ICLSharedInventoryHook
    /// @dev PoolKey path: reads the two currencies straight from each `keys[i]` and sizes the requirement at the
    ///      caller-supplied `sqrtPricesX96[i]`. It is for PRE-CREATION ONLY — an entry reverts
    ///      {PoolAlreadyInitialized} if its pool already exists, because this path reads no live price and so can't
    ///      police a manipulated one; a live pool must be (re)configured via {setPoolConfigs} (which does). No live
    ///      price is read, so no `maxRequired` caps are needed here. There is no single-entry variant (bytecode
    ///      economy): pass one-element arrays, or use the owner contract's single-entry convenience wrapper.
    function setUninitializePoolConfigs(
        PoolKey[] calldata keys,
        PoolConfig[] calldata cfgs,
        uint160[] calldata sqrtPricesX96,
        bool checkSolvency
    ) external override onlyOwner returns (uint256[] memory required0, uint256[] memory required1) {
        if (keys.length != cfgs.length || keys.length != sqrtPricesX96.length) revert ArrayLengthMismatch();
        required0 = new uint256[](keys.length);
        required1 = new uint256[](keys.length);
        for (uint256 i = 0; i < keys.length; i++) {
            _validatePoolKey(keys[i], sqrtPricesX96[i]);
            _requireUninitialized(keys[i].toId());
            (required0[i], required1[i]) = _applyPoolConfig(
                keys[i].toId(),
                keys[i].currency0,
                keys[i].currency1,
                sqrtPricesX96[i],
                keys[i].parameters.getTickSpacing(),
                cfgs[i],
                checkSolvency,
                type(uint256).max,
                type(uint256).max
            );
        }
    }

    /// @dev Validates a caller-supplied `PoolKey` (and the price it will be sized against) matches what a pool bound
    ///      to this hook must look like — used by the PoolKey overloads, where (unlike the PoolId path) nothing has
    ///      been checked by the pool manager yet. Checks: `hooks` is this hook, `poolManager` is ours, the two
    ///      currencies are strictly ascending (`currency0 < currency1`, so also distinct), `fee` is a valid static
    ///      fee, `parameters` encodes exactly this hook's registration bitmap and a valid tickSpacing, and
    ///      `sqrtPriceX96` is within the valid price range.
    function _validatePoolKey(PoolKey calldata key, uint160 sqrtPriceX96) private view {
        if (address(key.hooks) != address(this)) revert InvalidHook();
        if (address(key.poolManager) != address(poolManager)) revert InvalidPoolManager();
        // A valid pool key is strictly ascending, so `currency0 < currency1`; `>=` rejects both an equal pair and a
        // mis-ordered one (an unsorted key would hash to a different, uninitializable PoolId).
        if (Currency.unwrap(key.currency0) >= Currency.unwrap(key.currency1)) revert CurrenciesOutOfOrder();
        if (key.fee.isDynamicLPFee() || key.fee > LPFeeLibrary.ONE_HUNDRED_PERCENT_FEE) revert InvalidFee();
        // `parameters` low 16 bits are the hooks-registration bitmap; bits [16,40) are the tickSpacing.
        if (uint16(uint256(key.parameters)) != _registrationBitmap) {
            revert InvalidParameters();
        }
        int24 tickSpacing = key.parameters.getTickSpacing();
        if (tickSpacing < TickMath.MIN_TICK_SPACING || tickSpacing > TickMath.MAX_TICK_SPACING) {
            revert InvalidTickSpacing();
        }
        // Same bound the pool manager enforces at initialize: MIN_SQRT_RATIO <= price < MAX_SQRT_RATIO.
        if (sqrtPriceX96 < TickMath.MIN_SQRT_RATIO || sqrtPriceX96 >= TickMath.MAX_SQRT_RATIO) {
            revert InvalidSqrtPrice();
        }
    }

    /// @dev Reverts {PoolAlreadyInitialized} if a pool with this id is already registered with the manager. Used by
    ///      the PoolKey (pre-creation) config path to reject use on a live pool — a live pool has a manipulable price
    ///      and must be configured through the PoolId path (which guards it with the `maxRequired` caps).
    function _requireUninitialized(PoolId id) private view {
        (Currency e0, Currency e1,,,,) = poolManager.poolIdToPoolKey(id);
        if (Currency.unwrap(e0) != address(0) || Currency.unwrap(e1) != address(0)) revert PoolAlreadyInitialized();
    }

    /// @dev Shared body of the {setPoolConfig} / {setPoolConfigs} overloads. Validates the range, emits the pool's
    ///      inventory requirement AT `sqrtPriceX96` ({PoolInventoryRequired}), optionally checks solvency against live
    ///      balances, then stores the config. Returns that requirement (`required0` / `required1`, in currency0 /
    ///      currency1 terms) as a funding reference for the caller.
    /// @dev The requirement is computed at the CURRENT price (`sqrtPriceX96`) — what injecting `L` costs right now.
    ///      For a single pool this is self-sustaining: once the current-price injection is funded, the afterSwap
    ///      removal always returns enough for the next one (the "surplus" invariant). Preview any price via the
    ///      {requiredInventory} view.
    /// @dev The pool's binding to this hook is already verified by the caller — {_resolvePool} for the PoolId path,
    ///      {_validatePoolKey} for the PoolKey path — so it is not re-checked here.
    function _applyPoolConfig(
        PoolId id,
        Currency currency0,
        Currency currency1,
        uint160 sqrtPriceX96,
        int24 tickSpacing,
        PoolConfig calldata cfg,
        bool checkSolvency,
        uint256 maxRequired0,
        uint256 maxRequired1
    ) internal returns (uint256 required0, uint256 required1) {
        // A disabled config injects nothing, so it must carry no range/liquidity — this keeps the stored config
        // canonical and its requirement unambiguously zero. Store it, report a zero requirement, done.
        // `checkSolvency` is ignored here (true or false): a disabled pool never injects, so it needs no inventory.
        if (!cfg.enabled) {
            if (cfg.tickLower != 0 || cfg.tickUpper != 0 || cfg.liquidity != 0) revert InvalidDisabledConfig();
            // Optional price-sanity guard when disabling a currently-ENABLED pool: the incoming (disabled) config
            // has zero requirement, so instead check the OUTGOING config's requirement at the current live price
            // against the caller's caps. This lets the owner refuse to flip the config while the price is being
            // manipulated (so the change lands at a sane price). Pass `type(uint256).max` for both caps to skip it —
            // e.g. an emergency disable that must ALWAYS go through regardless of price. Skipped when there was no
            // enabled config to begin with (nothing to protect); the PoolKey pre-creation path passes max, so it
            // never trips here.
            PoolConfig memory prev = _poolConfig[id];
            if (prev.enabled) {
                (uint256 prevReq0, uint256 prevReq1) = _requiredAmountsAt(sqrtPriceX96, prev);
                if (prevReq0 > maxRequired0 || prevReq1 > maxRequired1) {
                    revert RequiredExceedsMax(prevReq0, maxRequired0, prevReq1, maxRequired1);
                }
            }
            _poolConfig[id] = cfg;
            emit PoolInventoryRequired(id, 0, 0);
            emit PoolConfigured(id, cfg);
            return (0, 0);
        }

        // An enabled config must actually inject something; `L == 0` would inject nothing (beforeSwap skips it).
        if (cfg.liquidity == 0) revert InvalidLiquidity();

        // Range must be ordered and within the globally valid tick bounds.
        if (cfg.tickLower >= cfg.tickUpper || cfg.tickLower < TickMath.MIN_TICK || cfg.tickUpper > TickMath.MAX_TICK) {
            revert InvalidTickRange();
        }

        // Range must align to the pool's tickSpacing. Core only enforces alignment at mint time (`modifyLiquidity`),
        // so a misaligned range would store fine here and then revert EVERY swap on the pool — a silent
        // misconfiguration with no on-chain feedback. Reject it at config time instead.
        if (cfg.tickLower % tickSpacing != 0) revert TickMisaligned(cfg.tickLower, tickSpacing);
        if (cfg.tickUpper % tickSpacing != 0) revert TickMisaligned(cfg.tickUpper, tickSpacing);

        // Amounts injecting `L` costs at the current price, in currency0/currency1 terms — returned as-is and
        // reported via the event.
        (required0, required1) = _requiredAmountsAt(sqrtPriceX96, cfg);

        // Front-running guard: the PoolId path sizes this at a manipulable live price, so if either side exceeds the
        // caller's expected cap the price was likely moved — revert instead of committing the config (and its `L`) at
        // a bad price, which is what would let an attacker inject deep liquidity at a manipulated price and arb it.
        // The PoolKey (pre-creation) path reads no live price and passes `type(uint256).max` (no cap).
        if (required0 > maxRequired0 || required1 > maxRequired1) {
            revert RequiredExceedsMax(required0, maxRequired0, required1, maxRequired1);
        }
        emit PoolInventoryRequired(id, required0, required1);

        if (checkSolvency) {
            // Checked against live balances. Note this inventory is common — a token appearing in several pools is
            // one shared balance — so this only proves solvency for a single in-flight injection at the current price.
            uint256 bal0 = _balanceOf(currency0);
            uint256 bal1 = _balanceOf(currency1);
            if (required0 > bal0 || required1 > bal1) {
                revert InsufficientInventory(id, bal0, required0, bal1, required1);
            }
        }

        _poolConfig[id] = cfg;
        emit PoolConfigured(id, cfg);
    }

    /// @inheritdoc ICLSharedInventoryHook
    function requiredInventory(PoolConfig calldata cfg, uint160 sqrtPriceX96)
        external
        pure
        override
        returns (uint256 amount0, uint256 amount1)
    {
        return _requiredAmountsAt(sqrtPriceX96, cfg);
    }

    /// @dev Amounts of currency0 / currency1 needed to mint `cfg.liquidity` over `[tickLower, tickUpper]` at the
    ///      pool's CURRENT price (read from slot0), in the pool's currency0/currency1 terms — what the next
    ///      injection actually costs now.
    /// @dev `getAmountsForLiquidity` rounds DOWN while the pool rounds UP when minting, so the real owed can be up
    ///      to 1 wei larger per side; we add +1 to each so this is a safe upper bound for a pre-injection check.
    function _requiredAmounts(PoolId id, PoolConfig memory cfg)
        internal
        view
        returns (uint256 amount0, uint256 amount1)
    {
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(id);
        return _requiredAmountsAt(sqrtPriceX96, cfg);
    }

    /// @dev Amounts of currency0 / currency1 needed to mint `cfg.liquidity` over `[tickLower, tickUpper]` at a given
    ///      `sqrtPriceX96`. Same rounding note as {_requiredAmounts}: +1 per side for the mint's round-up.
    /// @dev This is the current-price cost of ONE injection, not a standing requirement. It is also the figure the
    ///      {requiredInventory} view returns — see its FUNDING TIP: fund a little above it so the ~1-wei-per-swap
    ///      output-leg rounding dust (unoffset by the input-leg fee during one-directional flow) can't starve
    ///      injections over time.
    function _requiredAmountsAt(uint160 sqrtPriceX96, PoolConfig memory cfg)
        internal
        pure
        returns (uint256 amount0, uint256 amount1)
    {
        (amount0, amount1) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96,
            TickMath.getSqrtRatioAtTick(cfg.tickLower),
            TickMath.getSqrtRatioAtTick(cfg.tickUpper),
            cfg.liquidity
        );
        amount0 += 1;
        amount1 += 1;
    }

    /// @inheritdoc ICLSharedInventoryHook
    function setMinSharedReserve(Currency[] calldata currencies, uint256[] calldata amounts)
        external
        override
        onlyOwner
    {
        if (currencies.length != amounts.length) revert ArrayLengthMismatch();
        for (uint256 i = 0; i < currencies.length; i++) {
            _setMinSharedReserve(currencies[i], amounts[i]);
        }
    }

    /// @dev Set the reserve floor for one currency. Set to 0 to disable it. A floor above the current balance is
    ///      meaningless — the reserve would already be "breached", so every swap drawing it would revert. Rather than
    ///      revert the whole batch, such an entry is SKIPPED: emit {MinSharedReserveSkipped} and leave the floor
    ///      unchanged, so the other entries still apply.
    function _setMinSharedReserve(Currency currency, uint256 amount) private {
        uint256 bal = _balanceOf(currency);
        if (amount > bal) {
            emit MinSharedReserveSkipped(currency, bal, amount);
            return;
        }
        minSharedReserve[currency] = amount;
        emit MinSharedReserveSet(currency, amount);
    }

    /// @inheritdoc ICLSharedInventoryHook
    /// @dev EMERGENCY USE ONLY. This is a GLOBAL flag; flipping it directly (pause or resume) can be attacked — an
    ///      attacker can displace a pool's price with thin liquidity while JIT is off, then let the resume inject full
    ///      `L` at that manipulated price (and pausing can likewise be front-run). It is intended only for a serious
    ///      incident where market-making must stop across every pool at once. To pause JIT for a single pool in normal
    ///      operation, DISABLE that pool instead via `setPoolConfigs(..., enabled=false)`. If this flag must be used,
    ///      first hard-halt swaps with {setSwapPausedFor}, flip it, then let the halt expire so no swap can sandwich
    ///      the toggle; on resume, re-validate each pool's price before re-enabling.
    function setJitPaused(bool paused_) external override onlyOwner {
        _controls.jitPaused = paused_;
        emit JitPausedSet(paused_);
    }

    /// @inheritdoc ICLSharedInventoryHook
    function setSwapPausedFor(uint256 duration) external override onlyOwner {
        if (duration > MAX_SWAP_PAUSE) revert SwapPauseTooLong(duration, MAX_SWAP_PAUSE);
        // Rate-limit to at most one halt per day: a new halt is only allowed once a full `SWAP_PAUSE_COOLDOWN`
        // has elapsed past the previous halt's end (`swapPausedUntil + 1 days < block.timestamp`), so the owner
        // cannot chain halts to keep trading frozen indefinitely.
        uint256 nextAllowedAt = uint256(_controls.swapPausedUntil) + SWAP_PAUSE_COOLDOWN;
        if (block.timestamp <= nextAllowedAt) revert SwapPauseOnCooldown(nextAllowedAt);
        uint40 until = uint40(block.timestamp + duration);
        _controls.swapPausedUntil = until;
        emit SwapPausedUntilSet(until);
    }

    /// @inheritdoc ICLSharedInventoryHook
    function setRestrictedPoolCreation(bool restricted) external override onlyOwner {
        _controls.restrictedPoolCreation = restricted;
        emit RestrictedPoolCreationSet(restricted);
    }

    /// @inheritdoc ICLSharedInventoryHook
    function setRequireEnabledConfig(bool required) external override onlyOwner {
        _controls.requireEnabledConfig = required;
        emit RequireEnabledConfigSet(required);
    }

    /// @inheritdoc ICLSharedInventoryHook
    function setDisableDeferredRemoval(bool disabled) external override onlyOwner {
        // When enabling, there must be NO outstanding deferred removal. While this is on, `beforeSwap` skips the flush
        // (nothing can be pending), so a record left over from before would never be unwound and its position would be
        // stranded. If there is a pending, remove it first with `emergencyRemoveLiquidity` (pass its tick range + L to
        // burn it, or `liquidity == 0` to just drop the record), THEN set `disabled = true`.
        if (disabled && _pendingRemoval.cfg.liquidity != 0) revert PendingRemovalOutstanding();
        _controls.disableDeferredRemoval = disabled;
        emit DisableDeferredRemovalSet(disabled);
    }

    /// @notice When true, swaps proceed on resident liquidity but the hook injects no just-in-time liquidity.
    function jitPaused() external view returns (bool) {
        return _controls.jitPaused;
    }

    /// @notice When true, only whitelisted creators may initialize a pool with this hook.
    function restrictedPoolCreation() external view returns (bool) {
        return _controls.restrictedPoolCreation;
    }

    /// @notice When true, a pool may only be initialized if it already has an ENABLED PoolConfig.
    function requireEnabledConfig() external view returns (bool) {
        return _controls.requireEnabledConfig;
    }

    /// @notice When true, an `afterSwap` removal that would underflow reverts instead of being deferred.
    function disableDeferredRemoval() external view returns (bool) {
        return _controls.disableDeferredRemoval;
    }

    /// @notice Unix time before which ALL swaps on this hook revert (0 = no halt). See {setSwapPausedFor}.
    function swapPausedUntil() external view returns (uint40) {
        return _controls.swapPausedUntil;
    }

    /// @inheritdoc ICLSharedInventoryHook
    function setInitialSqrtPrice(PoolId id, uint160 sqrtPriceX96) external override onlyOwner {
        // A non-zero value must be a valid price (same bound the pool manager enforces at initialize); 0 clears the
        // approval, re-locking that pool's creation behind the whitelist.
        if (sqrtPriceX96 != 0 && (sqrtPriceX96 < TickMath.MIN_SQRT_RATIO || sqrtPriceX96 >= TickMath.MAX_SQRT_RATIO)) {
            revert InvalidSqrtPrice();
        }
        permissionlessInitSqrtPriceX96[id] = sqrtPriceX96;
        emit InitialSqrtPriceSet(id, sqrtPriceX96);
    }

    /// @inheritdoc ICLSharedInventoryHook
    function setPoolCreator(address[] calldata creators, bool[] calldata allowed) external override onlyOwner {
        uint256 len = creators.length;
        if (len != allowed.length) revert ArrayLengthMismatch();
        for (uint256 i = 0; i < len; i++) {
            address creator = creators[i];
            if (creator == address(0)) revert ZeroAddress();
            isPoolCreator[creator] = allowed[i];
            emit PoolCreatorSet(creator, allowed[i]);
        }
    }

    /// @inheritdoc ICLSharedInventoryHook
    function setWithdrawRecipient(address[] calldata recipients, bool[] calldata allowed) external override onlyOwner {
        uint256 len = recipients.length;
        if (len != allowed.length) revert ArrayLengthMismatch();
        for (uint256 i = 0; i < len; i++) {
            address recipient = recipients[i];
            if (recipient == address(0)) revert ZeroAddress();
            isWithdrawRecipient[recipient] = allowed[i];
            emit WithdrawRecipientSet(recipient, allowed[i]);
        }
    }

    /*//////////////////////////////////////////////////////////////
                          INVENTORY (owner)
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ICLSharedInventoryHook
    /// @dev Since inventory is just the hook's balance, one generic withdrawal covers any token the hook holds
    ///      (ERC-20 or native currency). `Currency.transfer` is native-aware and reverts on insufficient balance.
    /// @dev Only the hook's LIVE held balance is withdrawable. Tokens currently parked in a deferred just-in-time
    ///      position (see {pendingRemoval}) are NOT counted or withdrawable here — they sit in the pool, not in this
    ///      contract, until that position is unwound (the next swap's flush, or {emergencyRemoveLiquidity}), at which
    ///      point they return to the balance and become withdrawable. So a deferral can temporarily reduce how much
    ///      is available to withdraw. (`_isActive()` only blocks a withdrawal DURING a swap; it does not reflect a
    ///      cross-transaction pending removal.)
    function withdraw(Currency[] calldata currencies, uint256[] calldata amounts, address to)
        external
        override
        onlyOwner
        nonReentrant
    {
        if (_isActive()) revert SwapInProgress();
        if (to == address(0)) revert ZeroAddress();
        // Recipient allowlist: funds may only leave to a pre-approved destination. Unlike the per-entry floor check
        // (which skips), a bad recipient is a hard revert — it applies to the whole batch (`to` is shared).
        if (!isWithdrawRecipient[to]) revert RecipientNotWhitelisted(to);
        if (currencies.length != amounts.length) revert ArrayLengthMismatch();
        for (uint256 i = 0; i < currencies.length; i++) {
            _withdraw(currencies[i], to, amounts[i]);
        }
    }

    /// @dev Send `amount` of `currency` to `to`. A withdrawal may not push the currency's balance below its reserve
    ///      floor (or exceed the balance): such an entry is SKIPPED — emit {WithdrawSkipped} and move on, rather than
    ///      reverting the whole batch. To pull below a floor, lower that currency's `minSharedReserve` first. A zero
    ///      `amount` is still a hard error (caller mistake), not a skip.
    function _withdraw(Currency currency, address to, uint256 amount) private {
        if (amount == 0) revert ZeroAmount();
        uint256 bal = _balanceOf(currency);
        uint256 floor = minSharedReserve[currency];
        if (amount > bal || bal - amount < floor) {
            emit WithdrawSkipped(currency, bal, floor, amount);
            return;
        }
        _payOut(currency, to, amount);
        emit Withdrawn(currency, to, amount);
    }

    /*//////////////////////////////////////////////////////////////
                                 VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ICLSharedInventoryHook
    /// @dev Returns ONLY the hook's live held balance of `currency`. It does not include tokens parked in a deferred
    ///      just-in-time position (see {pendingRemoval}): while a removal is pending, that position is still live in
    ///      the pool, so its content isn't in this balance yet — it returns to inventory on the next swap's flush (or
    ///      via {emergencyRemoveLiquidity}). So right after a deferral this can read lower than the hook's true
    ///      economic holdings; add `pendingRemoval()`'s position content if you need the full picture.
    function inventoryOf(Currency currency) external view override returns (uint256) {
        return _balanceOf(currency);
    }

    /// @inheritdoc ICLSharedInventoryHook
    function getPoolConfig(PoolId id) external view override returns (PoolConfig memory) {
        return _poolConfig[id];
    }

    /// @inheritdoc ICLSharedInventoryHook
    function pendingRemoval() external view override returns (PoolId id, PoolConfig memory cfg) {
        return (_pendingRemoval.id, _pendingRemoval.cfg);
    }

    /// @inheritdoc ICLSharedInventoryHook
    function getPoolIdAndKey(address tokenA, address tokenB, uint24 fee, int24 tickSpacing)
        external
        view
        override
        returns (PoolId id, PoolKey memory key)
    {
        // Either token may be address(0) (the native currency); they must differ.
        if (tokenA == tokenB) revert CurrenciesEqual();
        // Static fee only (this hook does not support dynamic-fee pools), <= 100%; tickSpacing within valid bounds.
        if (fee > LPFeeLibrary.ONE_HUNDRED_PERCENT_FEE) revert InvalidFee();
        if (tickSpacing < TickMath.MIN_TICK_SPACING || tickSpacing > TickMath.MAX_TICK_SPACING) {
            revert InvalidTickSpacing();
        }

        // Pool currencies are address-sorted.
        (Currency currency0, Currency currency1) = tokenA < tokenB
            ? (Currency.wrap(tokenA), Currency.wrap(tokenB))
            : (Currency.wrap(tokenB), Currency.wrap(tokenA));

        key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: IHooks(address(this)),
            poolManager: poolManager,
            fee: fee,
            parameters: bytes32(uint256(_registrationBitmap)).setTickSpacing(tickSpacing)
        });
        id = key.toId();
    }
}
