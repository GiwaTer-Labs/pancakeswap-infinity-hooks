// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

import {PoolId} from "infinity-core/src/types/PoolId.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";

/// @title ICLSharedInventoryHook
/// @notice Interface for the just-in-time shared-inventory market-making hook.
/// @dev The owner sets an explicit `[tickLower, tickUpper]` range and a fixed liquidity `L` per pool; the hook
///      injects `L` in `beforeSwap` and removes it in `afterSwap`, all within one swap transaction.
interface ICLSharedInventoryHook {
    /*//////////////////////////////////////////////////////////////
                                 TYPES
    //////////////////////////////////////////////////////////////*/

    /// @notice Per-pool just-in-time injection parameters, configured by the owner.
    /// @dev `liquidity` is `uint128` (matching Infinity's `int128` `BalanceDelta` accounting); the whole struct
    ///      packs into a single storage slot (`enabled` + `tickLower` + `tickUpper` + `liquidity` = 23 bytes).
    struct PoolConfig {
        bool enabled; //      whether just-in-time is active for this pool
        int24 tickLower; //   lower bound of the just-in-time position (multiple of tickSpacing)
        int24 tickUpper; //   upper bound of the just-in-time position (multiple of tickSpacing)
        uint128 liquidity; // liquidity L injected on each swap (depth / slippage control)
    }

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event PoolConfigured(PoolId indexed id, PoolConfig cfg);
    /// @notice LP fees this pool's just-in-time position earned from the swap that just ran (currency0 / currency1 amounts).
    event FeesEarned(PoolId indexed id, uint256 fee0, uint256 fee1);
    event Withdrawn(Currency indexed currency, address indexed to, uint256 amount);
    /// @notice Emitted when a batch {withdraw} entry is SKIPPED (not reverted) because it would push the currency's
    ///         balance below its `minSharedReserve` floor (or exceed the balance). Other entries still process.
    ///         `balance` / `minReserve` are the current values; `amount` is the skipped request.
    event WithdrawSkipped(Currency indexed currency, uint256 balance, uint256 minReserve, uint256 amount);
    event MinSharedReserveSet(Currency indexed currency, uint256 amount);
    /// @notice Emitted when a batch {setMinSharedReserve} entry is SKIPPED (not reverted) because the requested floor
    ///         exceeds the currency's current balance. Other entries still process. `balance` is current; `amount`
    ///         is the skipped floor.
    event MinSharedReserveSkipped(Currency indexed currency, uint256 balance, uint256 amount);
    /// @notice Emitted when the owner toggles the JIT-injection pause via {setJitPaused}.
    event JitPausedSet(bool paused);
    /// @notice Emitted when the owner sets a timed swap halt via {setSwapPausedFor}; `until` is the unix time before
    ///         which ALL swaps on this hook revert.
    event SwapPausedUntilSet(uint40 until);
    event RestrictedPoolCreationSet(bool restricted);
    /// @notice Emitted when the owner toggles the require-enabled-config gate on pool creation via
    ///         {setRequireEnabledConfig}.
    event RequireEnabledConfigSet(bool required);
    /// @notice Emitted when the owner toggles whether `afterSwap` removals may be deferred via
    ///         {setDisableDeferredRemoval}.
    event DisableDeferredRemovalSet(bool disabled);
    /// @notice Emitted when an `afterSwap` position removal is deferred because unwinding it immediately would
    ///         underflow the pool manager's reservesOfApp (the swap's input isn't booked there until the swap fully
    ///         settles). The position stays live and is unwound at the start of the next swap on any pool.
    event JitRemovalDeferred(PoolId indexed id);
    /// @notice Emitted when {emergencyRemoveLiquidity} clears a deferred-removal record for the same pool — either
    ///         after burning that position, or (with `liquidity == 0`) dropping the record WITHOUT unwinding it (the
    ///         owner's recovery when the position's token became un-transferable and the per-swap flush is reverting).
    ///         `cfg` carries the parked position's tick range + liquidity so a not-yet-burned position can later be
    ///         reclaimed with {emergencyRemoveLiquidity} once transfers work again.
    event PendingRemovalAbandoned(PoolId indexed id, PoolConfig cfg);
    /// @notice Emitted when the owner removes a hook position via the {emergencyRemoveLiquidity} escape hatch.
    event OwnerLiquidityRemoved(PoolId indexed id, int24 tickLower, int24 tickUpper, uint128 liquidity);
    event PoolCreatorSet(address indexed creator, bool allowed);
    /// @notice Emitted when the owner adds/removes `recipient` from the {withdraw} recipient allowlist.
    event WithdrawRecipientSet(address indexed recipient, bool allowed);
    /// @notice Emitted when the owner sets (or clears, with 0) the approved initial price that opens pool `id` to
    ///         permissionless creation via {setInitialSqrtPrice}.
    event InitialSqrtPriceSet(PoolId indexed id, uint160 sqrtPriceX96);
    /// @notice Emitted on every {setPoolConfigs} entry with the inventory the config requires to inject at the price it was
    ///         sized against, in currency0/currency1 terms (`required0` / `required1`, by ordering). Off-chain
    ///         monitoring can track per-pool requirements from this.
    event PoolInventoryRequired(PoolId indexed id, uint256 required0, uint256 required1);

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error ZeroAddress();
    error ZeroAmount();
    error PoolNotInitialized();
    error InvalidHook();
    error InvalidPoolManager();
    error InvalidParameters();
    error InvalidSqrtPrice();
    /// @notice The two tokens are identical. Raised by the order-agnostic {getPoolIdAndKey} (which address-sorts its
    ///         args, so only equality is invalid).
    error CurrenciesEqual();
    /// @notice A pre-creation PoolKey's currencies are not strictly ascending (a valid key requires
    ///         `currency0 < currency1`). Covers both an equal pair and a swapped / mis-ordered one; an unsorted key
    ///         would hash to a different, uninitializable PoolId. Raised by the PoolKey path ({setUninitializePoolConfigs}).
    error CurrenciesOutOfOrder();
    /// @notice A swap would leave currency0's and/or currency1's persistent balance below its configured floor.
    /// @param id the pool whose swap breached a floor
    /// @param balance0 the post-swap balance of currency0
    /// @param minReserve0 the configured floor for currency0
    /// @param balance1 the post-swap balance of currency1
    /// @param minReserve1 the configured floor for currency1
    error MinSharedReserveBreached(
        PoolId id, uint256 balance0, uint256 minReserve0, uint256 balance1, uint256 minReserve1
    );
    /// @notice The hook's inventory can't fund a pool's injection (or configured worst case) on one or both sides.
    /// @param id the pool whose injection / configuration needed the inventory
    /// @param balance0 the hook's current balance of currency0
    /// @param required0 the currency0 amount that was needed
    /// @param balance1 the hook's current balance of currency1
    /// @param required1 the currency1 amount that was needed
    error InsufficientInventory(PoolId id, uint256 balance0, uint256 required0, uint256 balance1, uint256 required1);
    error InvalidTickRange();
    /// @notice A config's `tickLower` / `tickUpper` is not a multiple of the pool's tickSpacing. Core only enforces
    ///         alignment at mint time (`modifyLiquidity`), so a misaligned range would store fine and then revert
    ///         every swap on the pool — it is rejected at config time instead. Mirrors Core's TickBitmap error.
    error TickMisaligned(int24 tick, int24 tickSpacing);
    error InvalidDisabledConfig();
    error InvalidLiquidity();
    error InvalidFee();
    error InvalidTickSpacing();
    error SwapInProgress();
    /// @notice Pool creation was attempted while {requireEnabledConfig} is on but the pool has no enabled PoolConfig.
    error PoolConfigNotEnabled();
    /// @notice An `afterSwap` removal would have been deferred but {disableDeferredRemoval} is on, so the swap reverts.
    error RemovalDeferralDisabled();
    /// @notice {setDisableDeferredRemoval} was called with `true` while a deferred removal is still pending — clear it
    ///         first (via {emergencyRemoveLiquidity}), then enable.
    error PendingRemovalOutstanding();
    error NotPoolCreator();
    error ArrayLengthMismatch();
    /// @notice `withdraw` was called with a `to` that is not on the recipient allowlist (see {setWithdrawRecipient}).
    error RecipientNotWhitelisted(address to);
    /// @notice A PoolId {setPoolConfigs} entry sized the injection above the caller's `maxRequired` cap at the pool's live
    ///         price — a front-running guard: the live price was likely manipulated. Fund/quote at the true price.
    error RequiredExceedsMax(uint256 required0, uint256 maxRequired0, uint256 required1, uint256 maxRequired1);
    /// @notice A PoolKey {setUninitializePoolConfigs} entry (pre-creation only) targeted a pool that already exists — use the
    ///         PoolId overload for a live pool.
    error PoolAlreadyInitialized();
    /// @notice {emergencyRemoveLiquidity} returned less than the caller's `amount0Min` / `amount1Min` (slippage guard
    ///         — the pool price was likely manipulated so the position came back lopsided).
    error RemovalBelowMin(uint256 amount0, uint256 amount0Min, uint256 amount1, uint256 amount1Min);
    /// @notice A swap's netted settlement can't be paid: the hook's live `balance` of `currency` is below the `required`
    ///         amount it net-owes for pool `id`'s swap. Enforced in the settle path, so the whole swap reverts (no
    ///         partial fill). This is how an underfunded swap fails now that there is no per-price skip.
    error InsufficientInventoryToSettle(PoolId id, Currency currency, uint256 balance, uint256 required);
    /// @notice A swap was attempted while a timed halt is in effect — `block.timestamp < until` (see {setSwapPausedFor}).
    error SwapPaused(uint40 until);
    /// @notice {setSwapPausedFor} was called with `duration` exceeding `max` (`MAX_SWAP_PAUSE`).
    error SwapPauseTooLong(uint256 duration, uint256 max);
    /// @notice {setSwapPausedFor} was called before the once-per-day cooldown elapsed; `nextAllowedAt` is the earliest
    ///         unix time a new halt may be set (`swapPausedUntil + 1 days`).
    error SwapPauseOnCooldown(uint256 nextAllowedAt);

    /*//////////////////////////////////////////////////////////////
                             OWNER ACTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Set EXISTING pools' configs by PoolId — applies `cfgs[i]` to `ids[i]`, sized at each pool's CURRENT
    ///         price (read from slot0). Currencies and hook are resolved from the pool manager; an unregistered id
    ///         reverts {PoolNotInitialized}, and an id bound to a different hook reverts {InvalidHook}. To configure
    ///         a pool before it is created, use {setUninitializePoolConfigs}. All arrays must be equal length; the
    ///         single `checkSolvency` applies to every entry. There is no single-entry variant (bytecode economy):
    ///         pass one-element arrays, or use the owner contract's single-entry convenience wrapper.
    /// @param checkSolvency when true, each entry reverts unless the hook's current inventory covers what injecting
    ///        that config costs at its pool's current price. When false, the config is stored without the balance
    ///        check (its requirement is still emitted via {PoolInventoryRequired}). Ignored when `cfgs[i].enabled`
    ///        is false.
    /// @param maxRequired0 per-entry front-running guard: reverts {RequiredExceedsMax} if the currency0 amount the
    ///        config needs at the pool's LIVE price exceeds this. Size it off-chain at the expected price (+ margin);
    ///        a manipulated live price then makes the call revert instead of committing the config at a bad price.
    ///        `type(uint256).max` opts out. When DISABLING a currently-enabled pool (incoming `cfgs[i].enabled ==
    ///        false`), the guard instead caps the OUTGOING config's requirement at the live price — so a disable can
    ///        likewise be refused while the price is manipulated (pass `type(uint256).max` to force an
    ///        unconditional/emergency disable).
    /// @param maxRequired1 same guard for currency1.
    /// @return required0 per-pool currency0 requirement at the current price (funding reference)
    /// @return required1 per-pool currency1 requirement at the current price (funding reference)
    function setPoolConfigs(
        PoolId[] calldata ids,
        PoolConfig[] calldata cfgs,
        bool checkSolvency,
        uint256[] calldata maxRequired0,
        uint256[] calldata maxRequired1
    ) external returns (uint256[] memory required0, uint256[] memory required1);

    /// @notice Set NOT-YET-CREATED pools' configs by PoolKey (pre-configuration) — applies `cfgs[i]` to `keys[i]`,
    ///         sized at the intended initial price `sqrtPricesX96[i]`. `keys`, `cfgs` and `sqrtPricesX96` must be
    ///         equal length; the single `checkSolvency` applies to every entry. There is no single-entry variant
    ///         (bytecode economy): pass one-element arrays, or use the owner contract's single-entry convenience
    ///         wrapper.
    /// @dev PRE-CREATION ONLY: an entry reverts {PoolAlreadyInitialized} if its pool already exists — a live pool
    ///      must be (re)configured via {setPoolConfigs}, whose `maxRequired` caps guard against live-price
    ///      manipulation (this path reads no live price, so it cannot). `keys[i].hooks` must be this hook, else
    ///      {InvalidHook}.
    /// @param checkSolvency see {setPoolConfigs}; sized against `sqrtPricesX96[i]`.
    /// @return required0 per-pool currency0 requirement at the given price (funding reference)
    /// @return required1 per-pool currency1 requirement at the given price (funding reference)
    function setUninitializePoolConfigs(
        PoolKey[] calldata keys,
        PoolConfig[] calldata cfgs,
        uint160[] calldata sqrtPricesX96,
        bool checkSolvency
    ) external returns (uint256[] memory required0, uint256[] memory required1);

    /// @notice Withdraw `amounts[i]` of `currencies[i]` (any token the hook holds, ERC-20 or native) from the hook,
    ///         all to the single recipient `to`. `to` MUST be on the recipient allowlist ({setWithdrawRecipient}),
    ///         else the whole call reverts {RecipientNotWhitelisted}. `currencies` and `amounts` must be equal length.
    ///         Only the hook's live held balance is withdrawable — tokens parked in a deferred removal (see
    ///         {pendingRemoval}) sit in the pool, not here, until unwound, so they aren't withdrawable until reclaimed.
    /// @dev Any entry that would push a currency below its `minSharedReserve` floor (or exceed its balance) is SKIPPED
    ///      — it emits {WithdrawSkipped} and moves on, rather than reverting the whole batch. Lower that currency's
    ///      floor first to withdraw below it. Inventory is funded by transferring tokens directly to the hook (no
    ///      deposit function).
    function withdraw(Currency[] calldata currencies, uint256[] calldata amounts, address to) external;
    /// @notice EMERGENCY ONLY (not used in normal operation — removals happen automatically): remove a hook position
    ///         (always under the hook's fixed position salt) from ANY pool and fold the returned tokens (+ accrued
    ///         fees) back into inventory. Reverts {InvalidHook} if `key` is not bound to this hook. A deferred removal
    ///         pending for the SAME pool is cleared first (emitting {PendingRemovalAbandoned}); otherwise, after this
    ///         call burns the position, the next swap's flush would try to unwind a non-existent position and revert,
    ///         bricking swaps on every pool. A pending removal for a different pool is untouched. This is also the
    ///         recovery path when a deferred position's token became un-transferable and the per-swap flush is now
    ///         reverting: call it with `liquidity == 0` (see below) to drop the record and un-brick swaps.
    /// @param liquidity amount to burn; `0` is a no-op burn (does NOT revert) — it still clears any same-pool pending
    ///        record above, so it can be used purely to drop a stuck record without any vault interaction (leaving the
    ///        position live to reclaim later once its token is transferable again).
    /// @param amount0Min slippage guard: reverts {RemovalBelowMin} unless at least this much currency0 is returned.
    ///        A removal's token split depends on the current price (a position out of range comes back single-sided),
    ///        so size these at the expected price to reject a manipulated one. Pass 0 to opt out.
    /// @param amount1Min same guard for currency1.
    function emergencyRemoveLiquidity(
        PoolKey calldata key,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint256 amount0Min,
        uint256 amount1Min
    ) external;
    /// @notice Set the persistent-balance reserve floor for each `currencies[i]` to `amounts[i]` (0 disables that
    ///         currency's floor). Any swap that would leave a currency's post-swap balance below its floor reverts.
    ///         `currencies` and `amounts` must be equal length. Read the current floors via the
    ///         `minSharedReserve(Currency)` getter.
    /// @dev Any entry whose requested floor exceeds that currency's current balance is SKIPPED — it emits
    ///      {MinSharedReserveSkipped} and moves on, rather than reverting the whole batch (a floor above the balance
    ///      would be instantly "breached", bricking that currency's swaps). Fund the currency first, then set it.
    /// @dev CROSS-POOL CONTAGION: the floor is keyed by currency, so every pool sharing that token shares the same
    ///      floor and its circuit-breaker behavior — one pool draining the shared balance to the floor (e.g. during
    ///      a depeg) blocks further outflows of that token on ALL pools using it (inflows still pass and can lift
    ///      the breach). See the note on the `minSharedReserve` mapping.
    function setMinSharedReserve(Currency[] calldata currencies, uint256[] calldata amounts) external;
    /// @notice Toggle the GLOBAL JIT-injection pause. When on, swaps still fill on resident liquidity but the hook
    ///         injects no just-in-time liquidity anywhere. This is NOT a trading halt — for that, use {setSwapPausedFor}.
    /// @dev    EMERGENCY USE ONLY. Flipping this directly (pause or resume) is attackable: while JIT is off an attacker
    ///         can displace a pool's price with thin liquidity, then have the resume inject full `L` at the manipulated
    ///         price (and the pause itself can be front-run). It is meant only for a serious incident where market-making
    ///         must stop across every pool at once. In normal operation, to stop JIT for a single pool, DISABLE that
    ///         pool via `setPoolConfigs(..., enabled=false)` instead. If this flag is used, first hard-halt swaps with
    ///         {setSwapPausedFor}, flip it, then let the halt expire so no swap can sandwich the toggle; on resume,
    ///         re-validate each pool's price before re-enabling.
    function setJitPaused(bool paused) external;
    /// @notice Halt ALL swaps on this hook for `duration` seconds from now (a timed hard kill-switch, e.g. around an
    ///         incident). Sets `swapPausedUntil = block.timestamp + duration`; while it is in the future, `beforeSwap`
    ///         reverts {SwapPaused}. `duration` must be <= `MAX_SWAP_PAUSE` (10 minutes), else {SwapPauseTooLong}.
    ///         Rate-limited to once per day: reverts {SwapPauseOnCooldown} unless a full day has elapsed past the
    ///         previous halt's end (`swapPausedUntil + 1 days < block.timestamp`).
    function setSwapPausedFor(uint256 duration) external;
    /// @notice Enable/disable the pool-creation whitelist. When enabled (default), only {isPoolCreator} addresses
    ///         may initialize a pool bound to this hook.
    function setRestrictedPoolCreation(bool restricted) external;
    /// @notice Enable/disable the require-enabled-config gate (default off). When on, a pool may only be initialized
    ///         if it already has an ENABLED PoolConfig (pre-configured via {setUninitializePoolConfigs}), else the
    ///         `beforeInitialize` reverts {PoolConfigNotEnabled}.
    function setRequireEnabledConfig(bool required) external;
    /// @notice Enable/disable deferring `afterSwap` removals (default off = deferral allowed). When on, a removal that
    ///         would underflow reservesOfApp is NOT deferred; the swap reverts {RemovalDeferralDisabled} instead, so
    ///         pools must carry enough resident liquidity for removals to always settle inline. While on, `beforeSwap`
    ///         skips the pending-removal flush entirely (nothing can be pending). Enabling therefore reverts
    ///         {PendingRemovalOutstanding} if a deferred removal is still pending — clear it first via
    ///         {emergencyRemoveLiquidity}, then enable.
    function setDisableDeferredRemoval(bool disabled) external;
    /// @notice Batch add/remove `creators` from the pool-creation whitelist (checked against `tx.origin` on
    ///         initialize). `creators` and `allowed` must be equal length.
    function setPoolCreator(address[] calldata creators, bool[] calldata allowed) external;
    /// @notice Batch add/remove `recipients` from the {withdraw} recipient allowlist — only whitelisted addresses
    ///         may be a withdrawal's `to`. `recipients` and `allowed` must be equal length; the zero address is
    ///         rejected. Read membership via the `isWithdrawRecipient(address)` getter.
    function setWithdrawRecipient(address[] calldata recipients, bool[] calldata allowed) external;
    /// @notice Open pool `id` to permissionless creation by pinning its approved initial price: once set, anyone may
    ///         initialize that pool WITHOUT being a whitelisted {isPoolCreator}, but only at exactly `sqrtPriceX96`.
    ///         Set to 0 to revoke (re-locking creation behind the whitelist). A non-zero price must be within the
    ///         valid range, else {InvalidSqrtPrice}. Read the current value via the
    ///         `permissionlessInitSqrtPriceX96(PoolId)` getter.
    /// @dev SECURITY: before opening a pool this way, pre-configure it ({setPoolConfigs}) and transfer the tokens its
    ///      config needs into the hook, so just-in-time liquidity is live from the first swap. A pool opened but left
    ///      unfunded / unconfigured — even at the approved price — has little liquidity and could be swapped to skew
    ///      its price cheaply before the owner reacts; pinning the price only fixes the starting point.
    function setInitialSqrtPrice(PoolId id, uint160 sqrtPriceX96) external;

    /*//////////////////////////////////////////////////////////////
                                 VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @notice When true, swaps proceed on resident liquidity but the hook injects no just-in-time liquidity
    ///         anywhere. Toggled via {setJitPaused}.
    function jitPaused() external view returns (bool);
    /// @notice When true, only whitelisted creators may initialize a pool with this hook. Toggled via
    ///         {setRestrictedPoolCreation}.
    function restrictedPoolCreation() external view returns (bool);
    /// @notice When true, a pool may only be initialized if it already has an ENABLED PoolConfig. Toggled via
    ///         {setRequireEnabledConfig}.
    function requireEnabledConfig() external view returns (bool);
    /// @notice When true, an `afterSwap` removal that would underflow reverts instead of being deferred. Toggled via
    ///         {setDisableDeferredRemoval}.
    function disableDeferredRemoval() external view returns (bool);
    /// @notice Unix time before which ALL swaps on this hook revert (0 = no halt). Set via {setSwapPausedFor}.
    function swapPausedUntil() external view returns (uint40);
    /// @notice The longest a timed swap halt ({setSwapPausedFor}) may last: 10 minutes.
    function MAX_SWAP_PAUSE() external view returns (uint256);
    /// @notice The minimum spacing between timed swap halts: a new halt may only be set once a full day has elapsed
    ///         past the previous halt's end (see {setSwapPausedFor}).
    function SWAP_PAUSE_COOLDOWN() external view returns (uint256);
    /// @notice Per-currency reserve floor a swap's persistent (post-swap) balance may never dip below (circuit
    ///         breaker); 0 (the default) disables the floor for that currency. Set via {setMinSharedReserve}.
    function minSharedReserve(Currency currency) external view returns (uint256);
    /// @notice Whether `creator` is on the pool-creation whitelist (checked against `tx.origin` on initialize).
    ///         Managed via {setPoolCreator}.
    function isPoolCreator(address creator) external view returns (bool);
    /// @notice Whether `recipient` is an allowed {withdraw} destination. Managed via {setWithdrawRecipient}.
    function isWithdrawRecipient(address recipient) external view returns (bool);
    /// @notice The owner-approved initial price that opens pool `id` to permissionless creation (0 = whitelist-only).
    ///         Set via {setInitialSqrtPrice}.
    function permissionlessInitSqrtPriceX96(PoolId id) external view returns (uint160);
    /// @notice The hook's live balance of `currency` — i.e. the inventory available to fund just-in-time injections.
    ///         There is one balance per token, shared by every pool that uses it (a swap on any of those pools draws
    ///         from it). Excludes tokens parked in a deferred removal (see {pendingRemoval}), which live in the pool
    ///         until unwound — so right after a deferral this can read below the hook's true holdings.
    function inventoryOf(Currency currency) external view returns (uint256);
    function getPoolConfig(PoolId id) external view returns (PoolConfig memory);
    /// @notice The single outstanding deferred removal, if any (see §6 of the design doc). `cfg.liquidity == 0`
    ///         means nothing is pending; otherwise `id` is the pool with a parked position and `cfg` is the snapshot
    ///         of the config (tick range + liquidity) identifying the exact position awaiting removal.
    function pendingRemoval() external view returns (PoolId id, PoolConfig memory cfg);

    /// @notice Compute the PoolId and PoolKey of a `tokenA` / `tokenB` pool bound to this hook, without the pool
    ///         needing to exist yet. Useful to pre-compute the id/key for {setPoolConfigs} or for creating the pool.
    /// @param tokenA one of the pool's currencies (either may be `address(0)` = native); must differ from `tokenB`
    /// @param tokenB the other currency
    /// @param fee the pool's LP fee
    /// @param tickSpacing the pool's tick spacing
    /// @return id the pool's id
    /// @return key the fully-formed pool key (currencies address-sorted, this hook, encoded parameters)
    function getPoolIdAndKey(address tokenA, address tokenB, uint24 fee, int24 tickSpacing)
        external
        view
        returns (PoolId id, PoolKey memory key);

    /// @notice The currency0 / currency1 amounts injecting `cfg` costs at price `sqrtPriceX96` — what a `beforeSwap`
    ///         injection would owe at that price. Use it to size funding before calling {setPoolConfigs}, or to
    ///         preview the requirement at a hypothetical price. Returns amounts in currency0/currency1 order (a +1
    ///         per side rounds up to a safe upper bound).
    /// @dev FUNDING TIP: fund the hook to a bit MORE than this, not exactly. A single pool is self-sustaining
    ///      (each swap's removal returns essentially what the next injection needs), but a JIT round trip returns
    ///      floor() of the position while the next injection needs ceil(), so each swap can shed up to ~1 wei on the
    ///      token being paid OUT — and LP fees, which accrue on the token paid IN, don't offset that leg during
    ///      one-directional flow. The shortfall is tiny (order 1 wei per swap) but accumulates, so top up with a
    ///      small margin above the figure returned here to keep injections funded indefinitely.
    /// @param cfg the pool config (range + liquidity) to size
    /// @param sqrtPriceX96 the price to evaluate at
    function requiredInventory(PoolConfig calldata cfg, uint160 sqrtPriceX96)
        external
        pure
        returns (uint256 amount0, uint256 amount1);
}
