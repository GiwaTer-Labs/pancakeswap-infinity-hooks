# CLSharedInventoryHook: Findings Backed by Passing Tests

Prepared for an external smart-contract review. Every finding below is backed by a Foundry test that passed when
re-run for this report. Severities are **proposed** and are for the reviewer to confirm or change.

## 1. Scope

| Item | Value |
| --- | --- |
| Contracts | `src/pool-cl/shared-inventory/CLSharedInventoryHook.sol` (52 lines), `src/pool-cl/shared-inventory/CLSharedInventoryHookBase.sol` (1149 lines), `src/pool-cl/shared-inventory/interfaces/ICLSharedInventoryHook.sol` (373 lines) |
| Repository commit | `0ad98f0` (pancakeswap-infinity-hooks collection repo) |
| Core used by the main test suites | infinity-core `3c5ef1b`, which includes the `AppDeficit` change (transient app deficits in `Vault._accountDeltaForApp`) |
| Core used by the old-core test | infinity-core `7c04695`, which has no `AppDeficit` (see SIH-10) |
| On-chain deployment | BSC `0x56a78328A880c6D2b28482D9c481C0061C3D82c0` (BscScan-verified) |
| Licence of reviewed source | GPL-2.0-or-later |

**Provenance and line numbers.** The repository README ("Shared Inventory Hook provenance") and commit `6ed49b5`
record that the files were fetched with `cast source` from the BscScan-verified deployment above. They also record
that the files match byte for byte except for import paths (`infinity-hooks/src/…` → `src/…`,
`@openzeppelin/contracts/…` → `openzeppelin-contracts/contracts/…`). In the reviewed files every import is a
single-line statement: lines 6–21 of `CLSharedInventoryHookBase.sol`, 6–9 of `CLSharedInventoryHook.sol` and 4–6 of
`ICLSharedInventoryHook.sol`. Replacing a path inside a one-line import does not change the line count, so the line
numbers in this report should match the BscScan files. This was **not** re-checked against BscScan for this report,
because the verified source could not be fetched again (the BscScan API needs a key, and the web page returned HTTP
403). One independent copy of the same files (the port used for SIH-10) differs from the reviewed files only on
lines 6 and 17 of `CLSharedInventoryHookBase.sol`, both of them import lines, and has the same line count.

The README names infinity-core `7c1090e` as the build that reproduces the deployed runtime code. The old-core test
in SIH-10 runs on `7c04695`. Both commits are ancestors of `3c5ef1b`, and neither contains `AppDeficit`: `git grep`
finds no `getAppDeficit` in either tree, and `AppDeficit` first appears in `61cd131`.

## 2. Methodology

- Toolchain: Foundry `forge 1.8.3` (commit `cae51ad`), solc 0.8.26.
- All tests are local Foundry tests against a freshly deployed Vault and CLPoolManager from the pinned core
  (`Deployers.createFreshManager`). No fork tests were used.
- The test files are written by us and are not upstream. They are not committed at `0ad98f0`.
- Source excerpts are copied verbatim, and each one's line range was checked with `sed -n` against the files at
  `0ad98f0`. Test excerpts are abridged: some lines are joined, and `...` marks omitted lines.
- Commands, run from the repository root:

```bash
forge test --isolate --match-path test/pool-cl/CLSharedInventoryHook.t.sol -vv
forge test --isolate --match-path test/pool-cl/CLSharedInventoryHookSecurity.t.sol -vv
forge test --isolate --match-path test/pool-cl/CLSharedInventoryHookAccounting.t.sol -vv
forge test --isolate --match-path test/pool-cl/CLSharedInventoryHookAttack.t.sol -vv
```

| Test file | Result |
| --- | --- |
| `test/pool-cl/CLSharedInventoryHook.t.sol` (smoke test) | 2 passed, 0 failed |
| `test/pool-cl/CLSharedInventoryHookSecurity.t.sol` | 20 passed, 0 failed (fuzz: 256 runs) |
| `test/pool-cl/CLSharedInventoryHookAccounting.t.sol` | 13 passed, 0 failed |
| `test/pool-cl/CLSharedInventoryHookAttack.t.sol` | 8 passed, 0 failed |
| Old core: `test/shared-inventory-port/SharedInventoryDeferral.t.sol` (separate repository, see SIH-10) | 11 passed, 0 failed |

Common test setup: the hook owns 1,000 of each token. Pools use tick spacing 10, a JIT range of [-600, 600] and
`L = 1e21`, which is about 29.55 of each token at a 1:1 price. The pools have no resident liquidity. The Vault is
pre-funded with a plain token transfer, so the hook's in-`afterSwap` `take` has a physical balance behind it (see
SIH-11).

**The deferred-removal (`catch`) branch is not reachable through normal use on `3c5ef1b`.** Tests that need it use
`vm.mockCallRevert` to make only the removal `modifyLiquidity` call revert. After that, the hook's own catch-branch
code runs unchanged. On the pre-AppDeficit core the branch is reached naturally (SIH-10).

### Proposed severity scale

| Severity | Definition used here |
| --- | --- |
| Critical | Direct loss or permanent lock of a material share of inventory, exploitable by an unprivileged party with no preconditions. |
| High | Loss of funds or a lasting protocol-wide denial of service under realistic conditions, or a privileged-role failure with severe effect. |
| Medium | Value extraction or a lasting denial of service for a subset of pools, exploitable under specific but plausible conditions. |
| Low | Limited or conditional impact, operational hazard, or behaviour that contradicts the documentation with bounded effect. |
| Informational | No direct impact; documentation, integration or defensive-coding notes. |

## 3. Summary

| ID | Title | Proposed severity | Status | PoC test |
| --- | --- | --- | --- | --- |
| SIH-01 | Cheap, persistent per-pool swap DoS through `TickLiquidityOverflow` at the JIT range boundary (wide ranges) | Medium | Verified | `CLSharedInventoryHookAttack.t.sol::test_dos_tickLiquidityOverflow_wideRange_costsDust` |
| SIH-02 | `tx.origin` creator gate lets any contract a whitelisted creator calls initialize a pre-configured pool at an arbitrary price | Medium | Verified | `CLSharedInventoryHookSecurity.t.sol::test_txOrigin_phishedCreatorInitializesAtAttackerPrice` |
| SIH-03 | Losses and drains in one pool reduce the inventory every other pool sharing the currency relies on; no per-pool accounting | Low | Verified | `CLSharedInventoryHookAccounting.t.sol::test_Q1_crossPool_lossFromPoolA_reducesInventoryAvailableToPoolB` (+3) |
| SIH-04 | A floor already breached outside a swap blocks swaps that add the token, contrary to NatSpec | Low | Verified (balance drop simulated) | `CLSharedInventoryHookAccounting.t.sol::test_Q2_floorAlreadyBreached_blocksSwapsThatAddToken` |
| SIH-05 | Fee-on-transfer tokens: silent loss on inflow, every outflow swap reverts | Low | Verified | `CLSharedInventoryHookAccounting.t.sol::test_Q4_feeOnTransfer_silentLossOneWay_revertOtherWay` |
| SIH-06 | A pending removal whose token becomes non-transferable halts swaps on every pool | Low | Verified (deferral forced) | `CLSharedInventoryHookSecurity.t.sol::test_frozenPendingToken_haltsAllPools_untilEmergencyRemove` |
| SIH-07 | Partial `emergencyRemoveLiquidity` clears the whole pending record; the remainder stays live and untracked | Low | Verified (deferral forced) | `CLSharedInventoryHookSecurity.t.sol::test_partialEmergencyRemove_dropsWholeRecord_remainderUntracked` |
| SIH-08 | `renounceOwnership` is enabled; renouncing locks inventory and recovery paths permanently | Low | Verified | `CLSharedInventoryHookSecurity.t.sol::test_ownable2Step_andRenounceLocksInventoryForever` |
| SIH-09 | Deferred path pays the full injection principal instead of the net | Informational | Verified (deferral forced) | `CLSharedInventoryHookSecurity.t.sol::test_deferral_paysFullPrincipal_thenNextSwapAnywhereRestores` |
| SIH-10 | On pre-AppDeficit cores (BSC deployment), every bufferless swap defers, and a multi-hop in one lock reverts unless the Vault holds spare input | Low | Verified on infinity-core `7c04695` | `SharedInventoryDeferral.t.sol::test_3_sameLock_multiHop_revertsWhenVaultHasNoSpareInput` |
| SIH-11 | `afterSwap` `take`s the swap input before the swapper pays, so the Vault must already hold that token physically | Low | Verified | `CLSharedInventoryHookAccounting.t.sol::test_Q9_afterSwapTake_needsPhysicalVaultBalanceOfInputToken` |
| SIH-12 | The withdraw recipient allowlist gives no protection against a compromised owner, contrary to NatSpec | Informational | Verified | `CLSharedInventoryHookAccounting.t.sol::test_Q7_withdrawAllWhilePending_flushStillSettles_allowlistNoDefence` |
| SIH-13 | `inventoryOf` reads inflated during a swap (read-only reentrancy) | Informational | Verified | `CLSharedInventoryHookAttack.t.sol::test_readOnlyReentrancy_inventoryOfInflatedMidSwap` |

## 4. Findings

### SIH-01: Cheap, persistent per-pool swap DoS through `TickLiquidityOverflow` (Medium, proposed)

**Description.** Every swap mints the configured `L` at `[tickLower, tickUpper]` in `beforeSwap`. If that mint
reverts, the whole swap reverts, because there is no fallback. Anyone can add their own liquidity on the hook's
boundary tick: `maxLiquidityPerTick - L + 1` placed at `[tickLower, tickLower + tickSpacing]`. After that, the hook's
mint pushes `liquidityGross` on `tickLower` over the per-tick maximum, and core reverts with
`Tick.TickLiquidityOverflow`. Near the extreme ticks, `sqrtPrice` is about 2^-64, so this griefing position costs
almost nothing. The attacker can withdraw it at any time.

**Affected code.** `src/pool-cl/shared-inventory/CLSharedInventoryHookBase.sol` L384–L393 (unconditional mint in
`_beforeSwap`).

```solidity
// CLSharedInventoryHookBase.sol L384-L393
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
```

**Impact.** Test config: range [-887270, 887270], `L = 1e20`, tick spacing 10.

- `maxLiquidityPerTick` is `1917559095893846719543856547154045`.
- The griefing position cost the attacker **0 wei of token0 and 51,993,074,932 wei of token1 (about 5.2e-8 of a token)**, which comes back when the position is removed.
- After it is placed, swaps on that pool revert with `TickLiquidityOverflow` in both directions.
- Other pools and the shared inventory are not affected.

The DoS lasts until the owner changes the range, and the attacker can then repeat it at the new boundary. With the
narrow [-600, 600] range, the same attack needs more than 1e29 wei of one token
(`test_dos_tickLiquidityOverflow_narrowRange_isExpensive`), so in practice it applies to wide or full-range configs.

**Proof of concept.** `test/pool-cl/CLSharedInventoryHookAttack.t.sol`,
`test_dos_tickLiquidityOverflow_wideRange_costsDust`.
Command: `forge test --isolate --match-test test_dos_tickLiquidityOverflow_wideRange_costsDust -vv`.

```solidity
assertLt(uint256(int256(-cost.amount0() - cost.amount1())), 1e12, "grief costs more than 1e-6 token");
...
assertTrue(_contains(err, Tick.TickLiquidityOverflow.selector), "not TickLiquidityOverflow");
...
_swap(victim, p1, true, -1e18);                                  // other pools keep working
attacker.run(_one(_liqOp(w, lo, lo + 10, -grief)), _cs(w));     // grief withdrawn
_swap(victim, w, true, -1e18);                                   // pool works again
```

**Recommendation.** Any of these, alone or together:

- Wrap the injection `modifyLiquidity` in `try/catch`. On failure, clear the active flag and return
  `ZERO_DELTA`, so the swap fills on resident liquidity instead of reverting. This mirrors the existing graceful
  skip at L372–L375.
- In `_applyPoolConfig`, reject configs whose `liquidity` is close to
  `Tick.tickSpacingToMaxLiquidityPerTick(tickSpacing)`, or whose ticks are close to `MIN_TICK`/`MAX_TICK`, keeping
  enough headroom that griefing the boundary costs a material amount.
- Document that wide ranges are exposed to this attack.

---

### SIH-02: `tx.origin` creator gate can be satisfied through a phished whitelisted creator (Medium, proposed)

**Description.** Pool creation is gated on `isPoolCreator[tx.origin]`. A contract that is not whitelisted passes the
gate whenever a whitelisted creator signs any transaction that reaches it. Such a contract can initialize a pool the
owner has pre-configured (`setUninitializePoolConfigs`) at whatever `sqrtPriceX96` it chooses. The first JIT
injection then trades at that price.

**Affected code.** `src/pool-cl/shared-inventory/CLSharedInventoryHookBase.sol` L316–L319.

```solidity
// CLSharedInventoryHookBase.sol L316-L319
        if (_controls.restrictedPoolCreation && !isPoolCreator[tx.origin]) {
            uint160 approvedPrice = permissionlessInitSqrtPriceX96[key.toId()];
            if (approvedPrice == 0 || sqrtPriceX96 != approvedPrice) revert NotPoolCreator();
        }
```

**Impact.** In the test, the owner pre-configures (A, C) for a 1:1 price. A `Phisher` contract, called by the
whitelisted creator, initializes the pool at tick -580 instead. A 20-token swap then buys the underpriced token from
the JIT position, for a **profit of 0.705637401626320206 tokens valued at 1:1**. The NatSpec at L132–L140 describes
`tx.origin` caveats but not this flow.

**Proof of concept.** `test/pool-cl/CLSharedInventoryHookSecurity.t.sol`,
`test_txOrigin_phishedCreatorInitializesAtAttackerPrice`.
Command: `forge test --isolate --match-test test_txOrigin_phishedCreatorInitializesAtAttackerPrice -vv`.

```solidity
vm.prank(bob, bob);  vm.expectRevert();  phisher.claimAirdrop(poolManager, k, skewed);    // non-whitelisted origin blocked
vm.prank(CREATOR, CREATOR);              phisher.claimAirdrop(poolManager, k, skewed);    // passes the gate
assertEq(p, skewed, "pool live at attacker-chosen price");
assertGt(profitAt1to1, 0, "hook sold below market");
```

**Recommendation.** Gate on `sender` (the `beforeInitialize` caller passed by the pool manager) instead of
`tx.origin`, and whitelist the periphery/router contracts used for creation. Alternatively, store the intended
initial price in `setUninitializePoolConfigs` and require `sqrtPriceX96` to equal it, or fall within a bound of it,
for every initialization of a pre-configured pool, whether whitelisted or not.

---

### SIH-03: Cross-pool loss and drain propagation; no per-pool accounting (Low, proposed)

**Description.** Inventory is the hook's balance of each token (L33–L35, L83–L87). There is no per-pool ledger.
Every swap realises the JIT position's loss against holding (LVR / impermanent loss) straight into that balance, at
the moment of the swap. A loss or drain in one pool therefore reduces what every other pool sharing the currency can
pay out. Those pools then revert with `InsufficientInventoryToSettle` or `MinSharedReserveBreached`, even though
their own pair and price have not changed. The NatSpec at L92–L99 acknowledges this for the floor. No on-chain record
attributes profit or loss to individual pools.

**Affected code.** `src/pool-cl/shared-inventory/CLSharedInventoryHookBase.sol` L651–L658 (solvency checked against
the single shared balance).

```solidity
// CLSharedInventoryHookBase.sol L651-L658
    function _settleNet(PoolKey memory key, BalanceDelta delta) private {
        int128 net0 = delta.amount0();
        int128 net1 = delta.amount1();
        if (net0 < 0) {
            uint256 owe0 = uint256(uint128(-net0));
            uint256 bal0 = _balanceOf(key.currency0);
            if (bal0 < owe0) revert InsufficientInventoryToSettle(key.toId(), key.currency0, bal0, owe0);
            _settleToVault(key.currency0, owe0);
```

**Impact.** Numbers from the test logs:

- **Cross-pool test.** P1 (A,B) and P2 (A,C) share A, and the hook holds 40 A. A P2 swap that sells 15 C needs
  **14.741923962707981823 A**, and succeeds. An arbitrageur then moves P1 to tick 600 and draws
  **29.553010879137169681 A** from the shared balance. The hook's loss against holding on P1 is
  **0.801501679022112265** (in P1 currency1). Only **10.446989120862830319 A** are left, and the identical P2 swap
  now reverts with `InsufficientInventoryToSettle`. P2's price was checked and had not changed.
- **Single-pool arbitrage (`test_Q1_arbRealisesIL_paidFromSharedBalance`).** The hook's loss against holding is
  **0.851061221885851551**, and the arbitrageur's profit is **0.851061221885851547**. They differ by 4 wei. No
  position is left in the pool, so the loss is realised rather than impermanent.
- **Net-only settle (`test_Q2_Q5_settleIsExact_netOnly_noPerPoolReservation`).** The config "requires"
  29.553010879137169681 A of principal, but a 5-token swap settles only the net, 4.962748292889215041 A. With the
  hook holding exactly that much, the swap succeeds and leaves 0 A. P2 then reverts.
- **Floor contagion (`test_contagion_floorTripsOtherPool`).** A floor of 975 A is tripped on P2 by flow on P1.

**Proof of concept.** `test/pool-cl/CLSharedInventoryHookAccounting.t.sol`,
`test_Q1_crossPool_lossFromPoolA_reducesInventoryAvailableToPoolB`. Supporting tests:
`test_Q1_arbRealisesIL_paidFromSharedBalance`, `test_Q2_Q5_settleIsExact_netOnly_noPerPoolReservation`, and in
`CLSharedInventoryHookSecurity.t.sol`, `test_contagion_floorTripsOtherPool` and
`test_contagion_drainedInventoryRevertsOtherPool`.
Command: `forge test --isolate --match-test test_Q1_crossPool -vv`.

```solidity
assertGt(hookLoss, 0, "P1 arb realised a loss");
assertLt(_bal(a), p2Needs, "P1's loss left less A than P2 needs");
assertEq(p2PriceNow, p2Price, "P2 itself untouched");
assertTrue(_contains(err, ICLSharedInventoryHook.InsufficientInventoryToSettle.selector));
```

**Recommendation.** If per-pool isolation is wanted, track a per-pool, per-currency allocation (credited and debited
in `_settleNet` by pool id) and check solvency against that allocation, not the global balance. Alternatively, emit
per-swap net flows per pool (for example, add the net deltas to `FeesEarned` or a new event) so operators can
attribute P&L off-chain. As a minimum, operators should be told in the documentation that a token shared by
several pools makes those pools share losses.

---

### SIH-04: A floor already breached outside a swap blocks swaps that add the token (Low, proposed)

**Description.** The NatSpec says that swaps adding the token back "still succeed and can lift the breach"
(L96–L97). The check at L487 is absolute: it compares the post-swap balance with the floor, not with the pre-swap
balance. If the balance drops below the floor outside a swap, every swap whose result stays below the floor reverts,
including swaps that increase the balance. This can happen through a negative rebase, slashing or a token-level
seizure. The floor setter refuses floors above the balance (L930–L935), and `withdraw` respects the floor, so for
standard tokens this state is not reachable through the hook itself.

**Affected code.** `src/pool-cl/shared-inventory/CLSharedInventoryHookBase.sol` L96–L97 and L480–L487.

```solidity
// CLSharedInventoryHookBase.sol L96-L97
    ///      pools sharing it, including pools whose own pair is unaffected. The block is one-directional: swaps that
    ///      ADD the token back still succeed and can lift the breach. This is inherent to shared inventory — the
```

```solidity
// CLSharedInventoryHookBase.sol L480-L487
        uint256 bal0 = _balanceOf(key.currency0);
        uint256 bal1 = _balanceOf(key.currency1);
        if (positionStillLive) {
            (uint256 positionAmount0, uint256 positionAmount1) = _requiredAmounts(id, cfg);
            bal0 += positionAmount0;
            bal1 += positionAmount1;
        }
        if (bal0 < min0 || bal1 < min1) revert MinSharedReserveBreached(id, bal0, min0, bal1, min1);
```

**Impact.** With a floor of 990 A and the balance moved to 985 A, a swap selling 1 A into P1 reverts with
`MinSharedReserveBreached`. Only a single swap large enough to lift the balance above 990 A (6 A in the test)
passes. Every pool using that token is blocked in both directions until that happens or the owner lowers the floor.

**Proof of concept.** `test/pool-cl/CLSharedInventoryHookAccounting.t.sol`,
`test_Q2_floorAlreadyBreached_blocksSwapsThatAddToken`.
Command: `forge test --isolate --match-test test_Q2_floorAlreadyBreached -vv`. The balance reduction is simulated
with `deal`.

```solidity
deal(address(tA), address(hook), 985e18); // balance shrinks under the floor outside any swap
try trader.swap(p1, aIs0, -1e18, 0) { fail(); }            // SELL 1 A into P1: raises A
catch (bytes memory err) { assertTrue(_contains(err, ICLSharedInventoryHook.MinSharedReserveBreached.selector)); }
_swap(p1, aIs0, -6e18); // a single swap big enough to clear the floor passes
```

**Recommendation.** Snapshot the per-currency balances in `beforeSwap`, in transient storage. Revert only when the
post-swap balance is below the floor **and** below the pre-swap balance, for example
`if (bal0 < min0 && bal0 < pre0) revert ...`. If the absolute behaviour is intended, correct the NatSpec instead.

---

### SIH-05: Fee-on-transfer tokens: silent loss on inflow, every outflow swap reverts (Low, proposed)

**Description.** `_settleToVault` and `_takeFromVault` move the nominal amount and do not account for transfer fees.
When the hook receives a fee-on-transfer token through `vault.take`, it gets less than the pool booked. When it pays
one through `settle`, the Vault credits less than owed, the hook's delta stays open, and the lock fails with
`CurrencyNotSettled`. Nothing prevents the owner from configuring such a pool.

**Affected code.** `src/pool-cl/shared-inventory/CLSharedInventoryHook.sol` L36–L44.

```solidity
// CLSharedInventoryHook.sol L36-L44
    function _settleToVault(Currency currency, uint256 amount) internal override {
        currency.settle(vault, address(this), amount, false);
    }

    /// @inheritdoc CLSharedInventoryHookBase
    /// @dev Receives straight into the hook's own balance via flash-accounting `take`.
    function _takeFromVault(Currency currency, uint256 amount) internal override {
        vault.take(currency, address(this), amount);
    }
```

**Impact.** With a 1% fee token, a trader sells 10 FOT. The pool books **10.000000000000000000** to the hook, which
receives **9.899999999999999999**, a silent 1% loss per inflow. Any swap where the hook must pay FOT reverts, so one
direction of the pool cannot be used.

**Proof of concept.** `test/pool-cl/CLSharedInventoryHookAccounting.t.sol`,
`test_Q4_feeOnTransfer_silentLossOneWay_revertOtherWay`.
Command: `forge test --isolate --match-test test_Q4_feeOnTransfer -vv`.

```solidity
assertApproxEqAbs(received, booked * 99 / 100, 2, "hook silently eats the transfer fee");
vm.expectRevert(); // CurrencyNotSettled: hook's settle of FOT credits 99%
_swap(pf, !fIs0, -1e18); // trader buys FOT
```

**Recommendation.** State in the NatSpec of `setPoolConfigs` / `setUninitializePoolConfigs` that fee-on-transfer
and rebasing tokens are unsupported. Optionally, in `_applyPoolConfig` (or a dedicated check), transfer 1 wei
through `settle`/`take` and verify the Vault credit matches before enabling a pool.

---

### SIH-06: A pending removal whose token becomes non-transferable halts every pool (Low, proposed)

**Description.** `_flushPendingRemoval` runs at the top of every `beforeSwap`, on every pool, and does not catch
failures (a deliberate choice, explained at L517–L520). If the token of a parked position becomes non-transferable
(pause, blacklist, freeze), the flush reverts and every swap on the hook reverts with it, including pools that share
no token with the parked one. Burning the position with `emergencyRemoveLiquidity` also reverts while the token is
frozen. The only way to resume is `emergencyRemoveLiquidity(key, 0, 0, 0, 0, 0)`, which drops the record. The
behaviour is documented (L493–L497) and the owner can recover. It is listed because one token's state halts the
entire hook. On `3c5ef1b` a deferral could only be produced with a mock. On a pre-AppDeficit core, every bufferless
swap defers (SIH-10), so a pending record exists almost all the time.

**Affected code.** `src/pool-cl/shared-inventory/CLSharedInventoryHookBase.sol` L514–L523.

```solidity
// CLSharedInventoryHookBase.sol L514-L523
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
```

**Impact.** P1, P2 and P3, the last of which shares nothing with the frozen pool, all revert until the owner
intervenes. After the record is dropped, the other pools resume, and the parked position can be reclaimed once
transfers work again (the test asserts more than 50 tokens of principal come back).

**Proof of concept.** `test/pool-cl/CLSharedInventoryHookSecurity.t.sol`,
`test_frozenPendingToken_haltsAllPools_untilEmergencyRemove`. The deferral is forced with `vm.mockCallRevert` on the
removal call.
Command: `forge test --isolate --match-test test_frozenPendingToken -vv`.

```solidity
vm.expectRevert(); _swap(p1, true, -1e18);
vm.expectRevert(); _swap(p2, true, -1e18);
vm.expectRevert(); _swap(p3, true, -1e18);
vm.expectRevert(); hook.emergencyRemoveLiquidity(pf, LOWER, UPPER, L, 0, 0);
hook.emergencyRemoveLiquidity(pf, 0, 0, 0, 0, 0);   // drops the record
_swap(p3, true, -1e18);  _swap(p2, false, -1e18);    // others resume
```

**Recommendation.** Keep the revert-by-default design, but let anyone, after a timeout, or a non-owner guardian move
a pending record that has failed for N blocks into a "stranded positions" list instead of blocking all pools.
Alternatively, flush only when the incoming swap is on the pending pool or shares a currency with it. Document the
monitoring requirement either way.

---

### SIH-07: Partial `emergencyRemoveLiquidity` clears the whole pending record (Low, proposed)

**Description.** When the call targets the pending pool, `emergencyRemoveLiquidity` deletes the entire pending
record before it burns, whatever `liquidity` is passed. If the owner burns less than the parked `L`, the rest stays
live under `POSITION_SALT`, but it is no longer tracked. The flush never removes it, and later swaps inject and
remove `L` on top of it, so it remains as resident hook liquidity until the owner notices and removes it by hand.

**Affected code.** `src/pool-cl/shared-inventory/CLSharedInventoryHookBase.sol` L563–L567.

```solidity
// CLSharedInventoryHookBase.sol L563-L567
        if (_pendingRemoval.cfg.liquidity != 0 && PoolId.unwrap(_pendingRemoval.id) == PoolId.unwrap(key.toId())) {
            PoolConfig memory pendingCfg = _pendingRemoval.cfg;
            delete _pendingRemoval;
            emit PendingRemovalAbandoned(key.toId(), pendingCfg);
        }
```

**Impact.** After burning `L/2` of a parked `L = 1e21`, the record is cleared and `5e20` stays live. It survives
later swaps on P2 and P1 and is not reflected in `inventoryOf` or `pendingRemoval()`. A second manual call recovers
it.

**Proof of concept.** `test/pool-cl/CLSharedInventoryHookSecurity.t.sol`,
`test_partialEmergencyRemove_dropsWholeRecord_remainderUntracked`. The deferral is forced with a mock.
Command: `forge test --isolate --match-test test_partialEmergencyRemove -vv`.

```solidity
hook.emergencyRemoveLiquidity(p1, LOWER, UPPER, L / 2, 0, 0);
assertEq(_pendingL(), 0, "record dropped");
assertEq(_posL(p1, LOWER, UPPER), L / 2, "half still live");
...
assertEq(_posL(p1, LOWER, UPPER), L / 2, "remainder never flushed");
```

**Recommendation.** When `liquidity != 0` and the call matches the pending pool, require `tickLower`/`tickUpper` to
equal the snapshot, and either require `liquidity == pendingCfg.liquidity` or reduce `_pendingRemoval.cfg.liquidity`
by `liquidity` and delete the record only when it reaches 0.

---

### SIH-08: `renounceOwnership` is enabled (Low, proposed)

**Description.** The contract inherits `Ownable2Step` and does not override `renounceOwnership`. One call by the
owner sets the owner to `address(0)`. After that, `withdraw`, `emergencyRemoveLiquidity`, config changes, floors and
pauses can never be called again, while swaps keep trading the inventory with no one managing it.

**Affected code.** `src/pool-cl/shared-inventory/CLSharedInventoryHookBase.sol` L57–L62. A search of
`src/pool-cl/shared-inventory/` finds no `renounceOwnership` override.

```solidity
// CLSharedInventoryHookBase.sol L57-L62
abstract contract CLSharedInventoryHookBase is
    CLBaseHook,
    Ownable2Step,
    ReentrancyGuardTransient,
    ICLSharedInventoryHook
{
```

**Impact.** After the renounce, `withdraw` and `emergencyRemoveLiquidity` revert with
`OwnableUnauthorizedAccount`, and the test shows a swap still running on the unmanaged inventory. All inventory
becomes permanently impossible to withdraw.

**Proof of concept.** `test/pool-cl/CLSharedInventoryHookSecurity.t.sol`,
`test_ownable2Step_andRenounceLocksInventoryForever`.
Command: `forge test --isolate --match-test test_ownable2Step_andRenounceLocksInventoryForever -vv`.

```solidity
hook.renounceOwnership();
assertEq(hook.owner(), address(0));
vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, next));
hook.withdraw(_one(p1.currency0), _one(1), TREASURY);
...
_swap(p1, true, -1e18);
```

**Recommendation.** Override `renounceOwnership` to revert:
`function renounceOwnership() public pure override { revert(); }`.

---

### SIH-09: Deferred path pays the full injection principal (Informational, proposed)

**Description.** When the removal is deferred, the hook settles the whole injection (`injectDelta`) alone, with no
removal delta to net it against. The swap therefore needs the hook to hold the full principal of both legs, not just
the swap's net. Value comes back on the next flush, but solvency at deferral time is many times stricter. On
`3c5ef1b` this needs a forced deferral. On a pre-AppDeficit core, it happens on every bufferless swap (SIH-10,
`test_1_isolated_anySwapDefers_hookPaysInjectionInFull`: 29553010879137169681 of each currency paid for a 1-token
swap).

**Affected code.** `src/pool-cl/shared-inventory/CLSharedInventoryHookBase.sol` L446–L453.

```solidity
// CLSharedInventoryHookBase.sol L446-L453
            // Deferred: the removal would underflow, so the position stays live and there is no removal delta to net.
            // Pay the injection alone now (it is still unpaid), enforce the floors on the EFFECTIVE holdings (live
            // balance + the still-parked position), then record the position for the next swap to unwind.
            _settleNet(key, injectDelta);
            _enforceFloors(id, key, cfg, true);

            _pendingRemoval = PendingRemoval({id: id, cfg: cfg});
            emit JitRemovalDeferred(id);
```

**Impact.** For a 5-token swap, the inline path settles 4.962748292889215041 A net (SIH-03). The deferred path pays
the full principal of about 29.553 of each token. A hook funded for net flows reverts with
`InsufficientInventoryToSettle` on the deferred path. The tests found no loss of value.

**Proof of concept.** `test/pool-cl/CLSharedInventoryHookSecurity.t.sol`,
`test_deferral_paysFullPrincipal_thenNextSwapAnywhereRestores`. The deferral is forced with a mock.

```solidity
assertApproxEqAbs(a - _bal(p1.currency0), req0, 2, "paid full token0 principal");
assertApproxEqAbs(b - _bal(p1.currency1), req1, 2, "paid full token1 principal");
assertEq(_posL(p1, LOWER, UPPER), L, "position parked");
```

**Recommendation.** Document that deferral-capable deployments must fund at least the full `requiredInventory` of
the largest config, and not only the expected net flow.

---

### SIH-10: Pre-AppDeficit cores: every bufferless swap defers, and multi-hop in one lock reverts (Low, proposed)

**Description.** Before `AppDeficit`, `Vault._accountDeltaForApp` used checked arithmetic. Removing the JIT position
in `afterSwap` then underflows `reservesOfApp` whenever the swap input exceeds the manager's booked reserves, so the
hook defers (L41–L50). In a pool with no resident buffer, every swap defers. When a router runs several swaps
through hook pools inside one Vault lock and settles the input at the end, which is how Infinity routers work, the
second hop's `beforeSwap` flush `take`s tokens from hop 1's parked position. The Vault's ledger says those tokens
are there, but physically they are not, because the trader has not paid hop 1's input yet. The token transfer
underflows (Panic 0x11) and the whole route reverts. This happens unless the Vault happens to hold spare physical
balance of that token from other apps.

**Deployment relevance.** The BSC Vault `0x238a358808379702088667322f80aC48bAd5e6c4` has no `AppDeficit`. Its
deployed bytecode contains no PUSH4 for `getAppDeficitCount()` (`0x57bb1c06`), for `0xa0fbec60` (the
`getAppDeficit(address,address)` selector), or for `appCurrencyDeficit(address,address)` (`0x20d9cd95`, the name
used in `3c5ef1b`). It does contain `reservesOfApp(address,address)` (`0x322c3620`) and `lock(bytes)`
(`0x81548319`). This was checked with `cast code` against a public BSC RPC endpoint for this report. That the BSC
hook binds to this Vault is taken from the brief for this report and was not re-checked here.

**Affected code.** `src/pool-cl/shared-inventory/CLSharedInventoryHookBase.sol` L521–L523, the flush that performs
the failing `take` (see the SIH-06 excerpt for L514–L523), together with the `_settleNet` take at L659–L660:

```solidity
// CLSharedInventoryHookBase.sol L521-L523
        (BalanceDelta delta, BalanceDelta feeDelta) =
            poolManager.modifyLiquidity(key, _removalParams(pending.cfg), ZERO_BYTES);
        _collectRemoval(pending.id, key, delta, feeDelta);
```

**Impact.** Multi-hop routes that touch hook pools twice or more in one lock revert when the Vault has no spare
balance of the hop-1 input token. With spare balance, the same route succeeds and exactly one `L` stays parked
(`test_3_sameLock_multiHop_withSpareVaultBalance_oneSlot`). In isolated pools, every swap pays the full injection
(SIH-09) and leaves a pending record, which widens the exposure in SIH-06.

**Proof of concept.** Separate repository `giwaswap-contracts`, branch `experiment/shared-inventory-port`, commit
`d6ab38b`, file `test/shared-inventory-port/SharedInventoryDeferral.t.sol`. That file holds the hook files verbatim
(only two import lines differ, see Scope) and infinity-core `7c04695` vendored under `src/core/`.
Command: `forge test --isolate --match-path test/shared-inventory-port/SharedInventoryDeferral.t.sol -vv`
(11 passed).

```solidity
// test_3_sameLock_multiHop_revertsWhenVaultHasNoSpareInput
vm.expectRevert(abi.encodeWithSelector(CustomRevert.WrappedError.selector, address(hook),
    ICLHooks.beforeSwap.selector, // _flushPendingRemoval
    abi.encodeWithSelector(CustomRevert.WrappedError.selector, Currency.unwrap(c0),
        bytes4(keccak256("transfer(address,uint256)")), // Vault.take -> token.transfer
        abi.encodeWithSignature("Panic(uint256)", 0x11), // Vault lacks the unpaid hop-1 input
        abi.encodeWithSignature("ERC20TransferFailed()")),
    abi.encodeWithSelector(Hooks.HookCallFailed.selector)));
ms.run(_legs()); // legs: keyA, keyB, keyA, each zeroForOne, -2e18
```

**Recommendation.** For deployments on pre-AppDeficit Vaults, choose one or more of:

- Upgrade the Vault and pool manager to a core with `AppDeficit` (`61cd131` or later).
- Keep a resident buffer in each hook pool and set `disableDeferredRemoval`.
- Document that multi-hop routes through several hook pools depend on spare Vault balance.

---

### SIH-11: `afterSwap` `take` runs before the swapper pays, so the Vault must hold the input token physically (Low, proposed)

**Description.** On the inline path, the hook's net delta is a credit in the swap's input token. `_settleNet` takes
it with `vault.take`, which transfers tokens out of the Vault, inside `afterSwap`. That is before the swapper's own
`settle`, for routers that settle after the swap. At that point the Vault must already hold at least that amount of
the input token from other sources. For a token whose only liquidity is this hook (the hook keeps inventory in its
own balance, not in the Vault), swaps that sell the token into the pool revert. The output token has no such
requirement. The test establishes the input-token requirement; the brief for this report had described it as an
output-token requirement.

**Affected code.** `src/pool-cl/shared-inventory/CLSharedInventoryHookBase.sol` L659–L660 and L667–L668, and
`src/pool-cl/shared-inventory/CLSharedInventoryHook.sol` L42–L44.

```solidity
// CLSharedInventoryHookBase.sol L659-L660
        } else if (net0 > 0) {
            _takeFromVault(key.currency0, uint256(uint128(net0)));
```

```solidity
// CLSharedInventoryHook.sol L42-L44
    function _takeFromVault(Currency currency, uint256 amount) internal override {
        vault.take(currency, address(this), amount);
    }
```

**Impact.** A trader sells 5 A.

- Vault physical A = 0: the swap reverts with an arithmetic Panic in the token transfer.
- Vault physical A = 4: the swap reverts.
- Vault physical B (the output) = 0, with A present: the swap succeeds, and the hook takes 4.999999999999999998 A.

The test uses a swapper that pays after the swap. A router that settles input before swapping was not tested.

**Proof of concept.** `test/pool-cl/CLSharedInventoryHookAccounting.t.sol`,
`test_Q9_afterSwapTake_needsPhysicalVaultBalanceOfInputToken` (added for this report).
Command: `forge test --isolate --match-test test_Q9 -vv`.

```solidity
deal(address(tA), address(vault), 0); // input token (trader sells A)
try trader.swap(p1, aIs0, -5e18, 0) { fail(); }
catch (bytes memory err) { assertTrue(_contains(err, panic), "vault transfer of A underflows"); }
...
deal(address(tB), address(vault), 0); // output token absent, input present: fine
_swap(p1, aIs0, -5e18);
assertApproxEqAbs(_bal(Currency.wrap(address(tA))) - aHook, 5e18, 2, "hook took the full input");
```

**Recommendation.** Instead of `take`, leave the hook's positive delta as a Vault claim with
`vault.mint(address(this), currency, amount)` (ERC-6909 claims) and redeem it later (e.g. on `withdraw` or the next
swap). Alternatively, document that every token used by the hook must hold real Vault balance from other pools, and
check this when pools are configured.

---

### SIH-12: Withdraw recipient allowlist does not limit a compromised owner (Informational, proposed)

**Description.** The NatSpec says the allowlist means "a compromised withdraw key can only move funds to a
pre-approved destination". The allowlist (`setWithdrawRecipient`), the floors (`setMinSharedReserve`) and `withdraw`
are all `onlyOwner`, so a compromised owner key can add its own address, set floors to 0 and withdraw everything in
one batch.

**Affected code.** `src/pool-cl/shared-inventory/CLSharedInventoryHookBase.sol` L143–L147 and L1072.

```solidity
// CLSharedInventoryHookBase.sol L143-L147
    /// @notice Addresses {withdraw} is allowed to send to. A withdrawal to a non-whitelisted `to` reverts. This caps
    ///         where inventory can leave the hook, so a compromised withdraw key can only move funds to a
    ///         pre-approved destination (treasury). Managed via {setWithdrawRecipient}; empty by default (so no
    ///         withdrawal is possible until the owner approves a recipient).
    mapping(address recipient => bool allowed) public isWithdrawRecipient;
```

**Impact.** In the test, the owner adds `ATTACKER`, sets the A floor (500 A) to 0, and withdraws the entire live A
and B balances. Both end at 0.

**Proof of concept.** `test/pool-cl/CLSharedInventoryHookAccounting.t.sol`,
`test_Q7_withdrawAllWhilePending_flushStillSettles_allowlistNoDefence`.

```solidity
hook.setWithdrawRecipient(who, yes);           // ATTACKER
hook.setMinSharedReserve(_one(a), _one(0));
hook.withdraw(cs, amts, ATTACKER);
assertEq(_bal(a), 0);
assertEq(_bal(b), 0);
```

**Recommendation.** Put allowlist additions and floor reductions behind a separate role, or a timelock, from the
withdraw caller. Otherwise correct the NatSpec to say the allowlist only protects against mistakes, not against a
compromised owner.

---

### SIH-13: `inventoryOf` reads inflated during a swap (Informational, proposed)

**Description.** `_settleNet` resolves currency0 first. If currency0 is the swap input, the hook receives it through
`take` before it pays the currency1 output through `settle`. A token callback in that window, or any external call
made in it, sees `inventoryOf` with the input credited and the output not yet paid. Mutating entry points are
guarded by `SwapInProgress` (see Appendix A), but `inventoryOf` is a plain view.

**Affected code.** `src/pool-cl/shared-inventory/CLSharedInventoryHookBase.sol` L1105–L1107 (view) and L659–L668
(settle order).

```solidity
// CLSharedInventoryHookBase.sol L1105-L1107
    function inventoryOf(Currency currency) external view override returns (uint256) {
        return _balanceOf(currency);
    }
```

**Impact.** For a 10-token swap, the pair sum is 2000.000000000000000000 before the swap,
**2009.999999999999999998** mid-swap, and 2000.123517908859130174 after. The mid-swap reading is inflated by the
swap output. Only integrators that price something off `inventoryOf` during a swap are affected.

**Proof of concept.** `test/pool-cl/CLSharedInventoryHookAttack.t.sol`,
`test_readOnlyReentrancy_inventoryOfInflatedMidSwap`.

```solidity
assertApproxEqAbs(mid - post, int256(d.amount1()), 2, "mid-swap inflation == swap output");
```

**Recommendation.** Make `inventoryOf` revert (or return a flagged value) while `_isActive()` is true, and document
it as unsafe for on-chain pricing.

---

## Appendix A: Scenarios investigated and found not exploitable

| Scenario | Result | Refuting test |
| --- | --- | --- |
| Sandwich / JIT extraction | An attack sequence on the hook pool returns bit-identical deltas to a hookless twin with resident `L`. The hook's P&L equals a static LP's within 12 wei. Nothing extra can be extracted. | `Attack::test_sandwich_hookEqualsStaticLP_noExtraExtraction` |
| Forcing the `catch`/deferral on the fixed core by draining `reservesOfApp` in the same lock | The shortfall becomes a transient AppDeficit, and the removal succeeds inline. | `Attack::test_forceCatch_reserveDrainInSameLock_noDeferral` |
| Forcing deferral through gas griefing of `try/catch` | A sweep of ±40k gas around the minimum (471,989) found no success with a pending record. | `Security::test_gasGriefing_cannotForceDeferral` |
| Token-callback reentrancy: settle hijack | The whole swap reverts with `CurrencyNotSettled`, and no balance changes. | `Attack::test_reentrancy_settleHijack_revertsWholeSwap` |
| Token-callback reentrancy: nested swap / owner withdraw / emergency removal during a swap | Rejected with `SwapInProgress` / `LockerAlreadySet`. | `Security::test_reentrancy_nestedSwapFromTokenCallbackRejected`, `Security::test_reentrancy_ownerWithdrawAndEmergencyMidSwapRejected` |
| Unauthorized pool creation / attacker-configured pool | Restricted by default. An attacker's pool gets no config, moves no inventory, and cannot be configured. | `Attack::test_attackerPool_getsNoInventory`, `Security::test_access_everyAdminFunctionRejectsNonOwner` |
| Cross-pool triangle in one lock | Hook deltas are clean after every hop, and the loop loses 1.2019 tokens to fees. | `Attack::test_crossPool_triangleInOneLock_losesFees` |
| Rounding | Swapper never ahead. At most 2 wei per swap per side, stranded in the pool: 300/299 wei after 200 zero-fee swaps, hook -200 wei over 100 one-wei claims. 6-decimals: ≤125 raw units over 100 swaps. 0-fee round trip: -4 wei. | `Security::test_roundingDust_zeroFee_leaksToPoolNotSwapper`, `Security::test_roundingDust_oneWeiClaims_swapperPaysMore`, `Accounting::test_Q4_Q5_sixDecimals_dustBounded`, `Accounting::test_Q1_roundTrip_returnsToStart_onlyFeesRemain` |
| Native ETH conservation | Inventory change mirrors trader flow within 4 wei per swap, and no position is left. | `Accounting::test_Q3_nativePool_conserves` |
| Protocol fee interaction | Settle stays exact (mirror within 2 wei), and protocol fees accrue to the manager. | `Accounting::test_Q8_protocolFee_hookEarnsLess_accountingExact` |
| Pending-removal valuation | The flush returns principal at the frozen price plus third-party donations (31.590 B = 24.590 principal + 7 donated). A config change while pending burns the snapshot. Disable/JIT-pause still flush. An emergency removal on another pool keeps the record. | `Accounting::test_Q6_pendingValueFrozen_donationsAccrueToHook`, `Security::test_configChangeWhilePending_flushUsesSnapshot`, `Security::test_disableAndJitPauseWhilePending_stillFlushes`, `Security::test_emergencyRemoveOtherPool_keepsPending` |
| Donations (ERC20 / native) to the hook | The fill is identical with or without a donation, and donations are withdrawable by the owner. | `Accounting::test_Q3_donationsChangeNothing_butAreOwnerWithdrawable` |
| Random swap sequences with floors | Floor never breached after a successful swap, no deferral, no live position, and only expected revert reasons. | `Security::testFuzz_randomSwapSequence_invariantsHold` (256 runs) |
| Withdraw floor / allowlist mechanics | Skips below the floor or above the balance, rejects zero amounts and non-allowlisted recipients. | `Security::test_withdraw_onlyWhitelistedRecipient_neverBelowFloor` |
| `disableDeferredRemoval` | A `catch` reached while disabled reverts the whole swap, and nothing is parked. | `Security::test_disableDeferredRemoval_catchRevertsWholeSwap` |

`Attack::` = `test/pool-cl/CLSharedInventoryHookAttack.t.sol`, `Security::` =
`test/pool-cl/CLSharedInventoryHookSecurity.t.sol`, `Accounting::` = `test/pool-cl/CLSharedInventoryHookAccounting.t.sol`.

## Appendix B: Not verified / limitations

- **Deferral on `3c5ef1b`.** Natural deferral was not reached on `3c5ef1b`. SIH-06, SIH-07 and SIH-09 force the
  `catch` branch by mocking the removal `modifyLiquidity` to revert. The hook's handling code runs unmodified, but
  the cause is simulated. On the pre-AppDeficit core the branch is reached naturally (SIH-10).
- **Rebasing / slashing.** Negative-rebase and slashing tokens were not deployed. SIH-04 simulates the balance drop
  with `deal`.
- **Vault funding.** The Vault's physical balance is pre-funded by plain transfer in most tests, standing in for
  other apps' reserves. SIH-11 removes that funding to show the dependency.
- **Router behaviour.** Router behaviour other than "swap, then settle" (for example, settling input before the
  swap) was not tested for SIH-11.
- **BscScan line numbers.** Not re-verified against the BscScan source in this session (see Scope).
- **BSC on-chain state.** The BSC Vault bytecode was inspected for selectors only. No fork test was run against the
  BSC deployment, and the BSC hook's configuration, inventory and pool set were not examined.
- **Out of scope.** Upgradeability, deployment scripts, the periphery/universal router, and the helper libraries
  `CurrencySettler` and `TransientStorage` were not reviewed beyond their use by the hook.
