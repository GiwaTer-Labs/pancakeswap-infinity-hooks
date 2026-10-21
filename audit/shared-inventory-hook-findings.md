# CLSharedInventoryHook: Findings Backed by Passing Tests

Prepared for an external smart-contract review. Every finding below is judged against, and backed by a Foundry test
that passes on, **infinity-core `7c1090e`**, the core revision the BSC deployment runs on. The later core `3c5ef1b`
(which adds `AppDeficit`) was never deployed and is not the basis of any claim here. Severities are **proposed** and
are for the reviewer to confirm or change.

## 1. Scope

| Item | Value |
| --- | --- |
| Contracts | `src/pool-cl/shared-inventory/CLSharedInventoryHook.sol` (52 lines), `src/pool-cl/shared-inventory/CLSharedInventoryHookBase.sol` (1149 lines), `src/pool-cl/shared-inventory/interfaces/ICLSharedInventoryHook.sol` (373 lines) |
| Repository commit | `b5685a3` (pancakeswap-infinity-hooks collection repo); the test and build changes for this revision are uncommitted on top of it |
| Core the tests run on | infinity-core `7c1090e`, submodule `lib/infinity-core-bsc`, selected by `FOUNDRY_PROFILE=bsc` |
| On-chain deployment | BSC hook `0x56a78328A880c6D2b28482D9c481C0061C3D82c0` (BscScan-verified), see section 3 |
| Licence of reviewed source | GPL-2.0-or-later |

**Provenance and line numbers.** The repository README ("Shared Inventory Hook provenance") and commit `6ed49b5`
record that the files were fetched with `cast source` from the BscScan-verified deployment above, and that the
original build (infinity-core `7c1090e`, solc 0.8.26, via-IR, 1000 runs, cancun) reproduces the deployed runtime
code exactly apart from immutables and the CBOR metadata hash. The files match byte for byte except for import paths
(`infinity-hooks/src/…` → `src/…`, `@openzeppelin/contracts/…` → `openzeppelin-contracts/contracts/…`). In the
reviewed files every import is a single-line statement: lines 6–21 of `CLSharedInventoryHookBase.sol`, 6–9 of
`CLSharedInventoryHook.sol` and 4–6 of `ICLSharedInventoryHook.sol`. Replacing a path inside a one-line import does
not change the line count, so the line numbers in this report should match the BscScan files. This was **not**
re-checked against BscScan for this report (the BscScan API needs a key, and the web page returned HTTP 403).

## 2. Methodology

- Toolchain: Foundry `forge 1.8.3` (commit `cae51ad`), solc 0.8.26.
- All tests are local Foundry tests against a freshly deployed Vault and CLPoolManager built from infinity-core
  `7c1090e` (`Deployers.createFreshManager`). No fork tests were used.
- The rest of this repository builds and tests against `lib/infinity-core` at `3c5ef1b`, unchanged. The
  Shared Inventory Hook files and tests are compiled a second time under `[profile.bsc]` in `foundry.toml`, whose
  remappings point `infinity-core/` (and periphery's view of it, OpenZeppelin and solmate) at
  `lib/infinity-core-bsc`. The default profile skips the four `CLSharedInventoryHook*` test files
  (`no_match_path`); CI runs them in a separate step with `FOUNDRY_PROFILE=bsc`.
- The test files are written by us and are not upstream.
- Source excerpts are copied verbatim, and each one's line range was checked with `sed -n`. Test excerpts are
  abridged: some lines are joined, and `...` marks omitted lines.
- Commands, run from the repository root:

```bash
git submodule update --init --recursive
FOUNDRY_PROFILE=bsc forge test --isolate -vv                         # the four files below, on 7c1090e
FOUNDRY_PROFILE=bsc forge test --isolate --match-test <name> -vv     # one test
forge test --isolate                                                 # rest of the repo, on 3c5ef1b
```

| Test file (all on `7c1090e`) | Result |
| --- | --- |
| `test/pool-cl/CLSharedInventoryHook.t.sol` (smoke test) | 2 passed, 0 failed |
| `test/pool-cl/CLSharedInventoryHookSecurity.t.sol` | 20 passed, 0 failed (fuzz: 256 runs) |
| `test/pool-cl/CLSharedInventoryHookAccounting.t.sol` | 14 passed, 0 failed |
| `test/pool-cl/CLSharedInventoryHookAttack.t.sol` | 11 passed, 0 failed |
| **Total, `FOUNDRY_PROFILE=bsc`** | **47 passed, 0 failed** |
| Rest of the repository, default profile (`3c5ef1b`) | 144 passed, 0 failed, 23 suites |

The tests are core-specific: run on `3c5ef1b` instead, 14 of the 47 fail, because on that core the long-tail swaps
below do not defer.

### When does the hook defer on `7c1090e`?

`afterSwap` removes the JIT position inside a `try`. The removal hands back the position's principal **plus the swap
input**. `7c1090e` books that input to `reservesOfApp` only after `afterSwap` returns, and subtracts with checked
arithmetic:

```solidity
// infinity-core 7c1090e, src/Vault.sol L195-L206
    function _accountDeltaForApp(Currency currency, int128 delta) internal {
        if (delta == 0) return;

        /// @dev optimization: msg.sender will always be app address, verification should be done on caller address
        if (delta >= 0) {
            /// @dev arithmetic underflow make sure trader can't withdraw too much from app
            reservesOfApp[msg.sender][currency] -= uint128(delta);
        } else {
            /// @dev arithmetic overflow make sure trader won't deposit too much into app
            reservesOfApp[msg.sender][currency] += uint128(-delta);
        }
    }
```

`reservesOfApp[CLPoolManager][token]` is the **CL-wide** reserve: the principal the hook just injected plus every
other CL pool's holding of that token. So the removal underflows, and the hook defers it, only when the swap input
exceeds that CL-wide reserve. `Accounting::test_Q9_removalDefersOnlyWhenInputExceedsClWideReserve` pins this: with
10 D of reserve, selling 5 D removes inline and selling 15 D defers. The live reserves (section 3) are tens of
millions of USDT and thousands of BNB, so for mainstream tokens deferral needs an input larger than that.

The tests therefore model the two paths separately:

- **Mainstream tokens (A, B, C).** Hookless full-range pools hold about 1e27 of each, standing in for the live CL
  reserves. Every hook swap on them removes inline.
- **Long-tail token (D, and the FOT, frozen and long-tail tokens created inside tests).** No other CL liquidity. A
  swap that sells it into a hook pool defers; the other direction (mainstream input) removes inline.

The Vault is no longer pre-funded with a plain token transfer: its balances come only from these pools, as on
chain. No test mocks the removal call any more; every deferral below is reached naturally.

Common setup otherwise: the hook owns 1,000 of each token. Hook pools use tick spacing 10, a JIT range of
[-600, 600] and `L = 1e21`, about 29.55 of each token at a 1:1 price, and have no resident liquidity.

### Proposed severity scale

| Severity | Definition used here |
| --- | --- |
| Critical | Direct loss or permanent lock of a material share of inventory, exploitable by an unprivileged party with no preconditions. |
| High | Loss of funds or a lasting protocol-wide denial of service under realistic conditions, or a privileged-role failure with severe effect. |
| Medium | Value extraction or a lasting denial of service for a subset of pools, exploitable under specific but plausible conditions. |
| Low | Limited or conditional impact, operational hazard, or a privileged precondition with bounded effect. |

## 3. Deployment context (BSC, read-only)

Queried with `cast call -b 128891861 … --rpc-url https://bsc-rpc.publicnode.com`, at block **128891861**
(2026-10-21 06:41:45 UTC). All values were re-queried for this report.

| Item | Value |
| --- | --- |
| Hook | `0x56a78328A880c6D2b28482D9c481C0061C3D82c0` |
| `poolManager()` / `vault()` | `0xa0FfB9c1CE1Fe56963B0321B32E7A0302114058b` / `0x238a358808379702088667322f80aC48bAd5e6c4` |
| `owner()` / `pendingOwner()` | `0x835e03eb2F8B5872A4F445f86E8bB604b2cc3Fb0` / `0x0` |
| Owner contract | Role-based: `supportsInterface(IAccessControl)` is true, `hook()` returns the hook above, `DEFAULT_ADMIN_ROLE` has 1 member, the Safe below; its own `owner()` is the same Safe |
| Safe | `0xfa206DAB60c014bEb6833004D8848910165e6047`, `VERSION()` 1.3.0, `getThreshold()` 3, 7 owners |
| `restrictedPoolCreation` / `requireEnabledConfig` | true / false |
| `jitPaused` / `disableDeferredRemoval` / `swapPausedUntil` | false / false / 0 |
| `pendingRemoval()` | none (`id` 0, `liquidity` 0) |
| `minSharedReserve` | 0 for BNB, USDT, WBNB, CAKE, BTCB and USDC |
| `inventoryOf` | USDT 17,127,288,137,670,557 wei (≈0.0171 USDT); BNB 10,000,000,000 wei (1e10); WBNB, CAKE, BTCB, USDC 0 |

CL-wide reserves, `Vault.reservesOfApp(CLPoolManager, token)` (18 decimals on BSC):

| Token | Reserve |
| --- | --- |
| USDT `0x55d3…7955` | ≈35,461,914 |
| USDC `0x8AC7…580d` | ≈2,111,578 |
| CAKE `0x0E09…cE82` | ≈698,048 |
| BNB (native) | ≈6,759.96 |
| WBNB `0xbb4C…095c` | ≈273.46 |
| BTCB `0x7130…ad9c` | ≈1.582 |

The BSC Vault has no `AppDeficit`. Its runtime code contains no PUSH4 for `getAppDeficitCount()` (`0x57bb1c06`),
`getAppDeficit(address,address)` (`0xa0fbec60`) or `appCurrencyDeficit(address,address)` (`0x20d9cd95`), and does
contain `reservesOfApp(address,address)` (`0x322c3620`) and `lock(bytes)` (`0x81548319`).

**Not checked:** the list of pools bound to the hook and their configured ranges and `L` (configs are keyed by pool
id and cannot be enumerated with view calls; no event scan was run), the `isPoolCreator` and `isWithdrawRecipient`
members, `permissionlessInitSqrtPriceX96` entries, balances of tokens other than those listed, the Vault's holdings
for apps other than the CL pool manager (e.g. Bin pools), and the role assignments inside the owner contract beyond
`DEFAULT_ADMIN_ROLE`.

## 4. Summary

| ID | Title | Proposed severity | PoC test (all on `7c1090e`) |
| --- | --- | --- | --- |
| SIH-01 | Persistent per-pool swap DoS through `TickLiquidityOverflow` at a near-extreme JIT boundary | Medium (conditional; Low if no live pool uses such a boundary) | `Attack::test_dos_tickLiquidityOverflow_wideRange_costsDust`, `Attack::test_dos_tickLiquidityOverflow_deferringPool_needsParkedRecordCleared`, `Attack::test_dos_griefCost_byBoundaryTick` |
| SIH-02 | `tx.origin` creator gate, and the pre-configured price is never enforced at initialize | Low | `Security::test_txOrigin_phishedCreatorInitializesAtAttackerPrice` |
| SIH-03 | Long-tail input defers the removal: full principal paid, and a later hop in the same lock reverts | Low | `Attack::test_multiHop_longTailFirstHopDefers_routeReverts`, `Attack::test_forceDeferral_longTail_pullOwnReserveInSameLock`, `Security::test_deferral_paysFullPrincipal_thenNextSwapAnywhereRestores` |

`Attack::` = `test/pool-cl/CLSharedInventoryHookAttack.t.sol`, `Security::` =
`test/pool-cl/CLSharedInventoryHookSecurity.t.sol`, `Accounting::` =
`test/pool-cl/CLSharedInventoryHookAccounting.t.sol`. Every command below is run as
`FOUNDRY_PROFILE=bsc forge test --isolate --match-test <name> -vv`.

## 5. Findings

### SIH-01: Persistent per-pool swap DoS through `TickLiquidityOverflow` (Medium, conditional)

**Description.** Every swap mints the configured `L` at `[tickLower, tickUpper]` in `beforeSwap`. If that mint
reverts, the whole swap reverts; there is no fallback. Anyone can add their own liquidity on the hook's boundary
tick: `maxLiquidityPerTick - L + 1` at `[tickLower, tickLower + tickSpacing]`. The hook's next mint then pushes
`liquidityGross` on `tickLower` over the per-tick maximum, and core reverts with `Tick.TickLiquidityOverflow`. The
griefing position is single-sided (out of range) and can be withdrawn at any time, so its cost is refundable
capital, which depends almost entirely on how close the boundary is to the extreme ticks.

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

**Impact.** Tick spacing 10, `maxLiquidityPerTick = 1917559095893846719543856547154045`, `L = 1e20`, 1:1 price,
18-decimal tokens. Refundable capital the griefing position needs (`test_dos_griefCost_byBoundaryTick`):

| Boundary tick | Capital (token1) |
| --- | --- |
| −887270 (full range) | 51,993,074,931 wei ≈ 5.2e-8 |
| −550000 | ≈1.09 |
| −400000 | ≈1,979 |
| −300000 | ≈293,572 |
| −600 (narrow) | more than 1e11 tokens (`test_dos_tickLiquidityOverflow_narrowRange_isExpensive`) |

Once placed, swaps on that pool revert with `TickLiquidityOverflow` in both directions until the owner re-ranges,
and the attacker can repeat at the new boundary. Other pools and the shared inventory are not affected.

**On `7c1090e`, a parked record must be cleared first.** On a mainstream pool every swap removes inline, so nothing
holds the hook's `L` on the tick between swaps and the attack works directly
(`test_dos_tickLiquidityOverflow_wideRange_costsDust`; cost 0 wei token0, 51,993,074,932 wei token1). On a pool
whose swaps defer, the pool's own `L` stays on the boundary tick under the pending record. The attacker can then add
only `maxLiquidityPerTick - L`: the next swap's flush removes `L` before re-injecting it, so the pool keeps working,
and one more unit reverts. A pool is immune only while its record stays parked. Any swap that removes inline clears
it, including a swap on the same pool in the mainstream-input direction or a swap on any other pool. The test
clears it with a 0.001-token inline swap and adds the last unit in the same lock; the pool is then down in both
directions (`test_dos_tickLiquidityOverflow_deferringPool_needsParkedRecordCleared`).

**Severity condition.** Medium if a live pool uses a boundary near the extreme ticks, where the capital is dust.
The live pool configs were not checked (section 3). If no live pool has such a boundary, this is Low.

**Proof of concept.**

```solidity
// test_dos_tickLiquidityOverflow_wideRange_costsDust (mainstream A/B, inline path)
assertLt(uint256(int256(-cost.amount0() - cost.amount1())), 1e12, "grief costs more than 1e-6 token");
...
assertTrue(_contains(err, Tick.TickLiquidityOverflow.selector), "not TickLiquidityOverflow");
_swap(victim, p1, true, -1e18);                                  // other pools keep working
attacker.run(_one(_liqOp(w, lo, lo + 10, -grief)), _cs(w));     // grief withdrawn
_swap(victim, w, true, -1e18);                                   // pool works again

// test_dos_tickLiquidityOverflow_deferringPool_needsParkedRecordCleared (long-tail D sold in)
_swap(victim, w, sellD, -1e18);                       assertEq(_pendingL(), l);   // L parked on the boundary
attacker.run(_one(_liqOp(w, lo, lo + 10, fill)), _cs(w));                         // maxPerTick - L fits
_swap(victim, w, sellD, -1e18);                                                   // flush -L, inject +L: works
try attacker.run(_one(_liqOp(w, lo, lo + 10, 1)), _cs(w)) { fail(); } catch ...  // +1 while parked: overflow
ops[0] = _swapOp(w, !sellD, -1e15);  ops[1] = _liqOp(w, lo, lo + 10, 1);  attacker.run(ops, _cs(w));
assertEq(_pendingL(), 0, "record cleared by the inline swap");                    // then both directions revert
```

**Recommendation.** Any of these, alone or together:

- Wrap the injection `modifyLiquidity` in `try/catch`. On failure, clear the active flag and return
  `ZERO_DELTA`, so the swap fills on resident liquidity instead of reverting. This mirrors the existing graceful
  skip at L372–L375.
- In `_applyPoolConfig`, reject ticks close to `MIN_TICK`/`MAX_TICK`, keeping enough headroom that griefing the
  boundary costs a material amount.
- Document that near-extreme ranges are exposed to this attack.

---

### SIH-02: `tx.origin` creator gate; the pre-configured price is never enforced (Low)

**Description.** Pool creation is gated on `isPoolCreator[tx.origin]`. A contract that is not whitelisted passes the
gate whenever a whitelisted creator signs any transaction that reaches it, and can then initialize a pool the owner
has pre-configured with `setUninitializePoolConfigs` at any `sqrtPriceX96`. The first JIT injection trades at that
price. This needs a whitelisted creator to be phished, and the NatSpec states "Standard `tx.origin` caveats apply"
(L140).

The understated part is the price. `setUninitializePoolConfigs` takes `sqrtPricesX96[i]` but uses it only to size
the inventory requirement (L731, L737); it is not stored, and `_beforeInitialize` never compares the initialization
price with it. So even a whitelisted creator acting honestly can open a pre-configured pool at a price different
from the one the config was sized for, and the hook's JIT liquidity is live from the first swap at that price.
`permissionlessInitSqrtPriceX96` pins the price only for non-whitelisted callers.

**Affected code.** `src/pool-cl/shared-inventory/CLSharedInventoryHookBase.sol` L316–L319 and L140.

```solidity
// CLSharedInventoryHookBase.sol L316-L319
        if (_controls.restrictedPoolCreation && !isPoolCreator[tx.origin]) {
            uint160 approvedPrice = permissionlessInitSqrtPriceX96[key.toId()];
            if (approvedPrice == 0 || sqrtPriceX96 != approvedPrice) revert NotPoolCreator();
        }
```

```solidity
// CLSharedInventoryHookBase.sol L140
    ///         this whitelist assuming its members cannot run contract code. Standard `tx.origin` caveats apply.
```

**Impact.** The owner pre-configures (A, C) at a 1:1 price. A `Phisher` contract, called by the whitelisted creator,
initializes it at tick −580. A 20-token swap then buys the underpriced token from the JIT position, for a profit of
**0.705637401626320206 tokens valued at 1:1**. A non-whitelisted origin calling the same contract is rejected. On
BSC, `restrictedPoolCreation` is true (section 3); the creator list was not checked.

**Proof of concept.** `Security::test_txOrigin_phishedCreatorInitializesAtAttackerPrice`.

```solidity
_preconfig(k, _cfg(LOWER, UPPER, L), SQRT_RATIO_1_1); // owner expects 1:1
vm.prank(bob, bob);  vm.expectRevert();  phisher.claimAirdrop(poolManager, k, skewed);    // non-whitelisted origin blocked
vm.prank(CREATOR, CREATOR);              phisher.claimAirdrop(poolManager, k, skewed);    // passes the gate
assertEq(p, skewed, "pool live at attacker-chosen price");
assertGt(profitAt1to1, 0, "hook sold below market");
```

**Recommendation.** Store the `sqrtPricesX96[i]` given to `setUninitializePoolConfigs` and, in `_beforeInitialize`,
require any initialization of a pre-configured pool to use that price (or one within a set bound), whoever the
caller is. Gating on `sender` instead of `tx.origin` is a weak fix on its own: pool creation usually goes through
periphery contracts, and whitelisting those lets anyone through them.

---

### SIH-03: Long-tail input defers the removal; a later hop in the same lock reverts (Low)

**Description.** When a swap's input exceeds the CL-wide reserve of that token (section 2), the `afterSwap` removal
underflows and the hook defers it (L41–L50, L441–L453). On the deferred path the hook takes nothing in `afterSwap`:
it pays the whole injection principal of both tokens and leaves the position parked. The next swap on any pool
flushes it in `beforeSwap` (L498–L523), which `take`s the position's tokens out of the Vault, including the
deferred swap's input.

When a router runs several swaps in one Vault lock and settles inputs at the end, which is how Infinity routers
work, and hop 1 defers, hop 2's flush tries to take hop 1's input before the trader has paid it. If the Vault holds
no other balance of that token, the token transfer underflows and the whole route reverts. In the test the Vault
holds no other D; a Vault holding the token for other apps (e.g. Bin pools) would cover the take. That case was not
tested.

This applies only where hop 1 actually defers: a long-tail input larger than the token's CL-wide reserve. For the
mainstream tokens in section 3 that would take an input of millions of USDT or thousands of BNB. The result is a
failed route with no loss of funds. The same deferral pays the full principal, so the hook needs the whole
`requiredInventory` of the pool on hand, not only the swap's net, or the swap reverts with
`InsufficientInventoryToSettle`; the value comes back on the next flush.

Whoever holds a long-tail token's CL liquidity decides whether its swaps defer: pulling that liquidity out, even in
the same lock as the swap, turns an inline swap into a deferring one
(`test_forceDeferral_longTail_pullOwnReserveInSameLock`). The only effect found is the route failure above.

On an inline swap the hook does `take` the input inside `afterSwap`, before the swapper pays; on `7c1090e` that take
only happens after the removal has passed the checked `reservesOfApp` subtraction above. On a deferring swap nothing
is taken in `afterSwap`.

**Affected code.** `src/pool-cl/shared-inventory/CLSharedInventoryHookBase.sol` L441–L453 (deferral) and L521–L523
(the flush's removal and take).

```solidity
// CLSharedInventoryHookBase.sol L441-L453
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
```

```solidity
// CLSharedInventoryHookBase.sol L521-L523
        (BalanceDelta delta, BalanceDelta feeDelta) =
            poolManager.modifyLiquidity(key, _removalParams(pending.cfg), ZERO_BYTES);
        _collectRemoval(pending.id, key, delta, feeDelta);
```

**Impact.**

- Route `D → A` on PD (defers), then `A → B` on P1, in one lock: reverts with an arithmetic Panic in the Vault's
  D transfer; the hook's D balance is unchanged.
- The same `D → A` alone succeeds and is flushed by the next swap. The route `A → D` (inline) then `A → B` succeeds.
- A deferred 5-token swap pays the full principal, about 29.553 of each token
  (`test_deferral_paysFullPrincipal_thenNextSwapAnywhereRestores`); an inline 5-token swap settles 4.962748292889215041
  net (`test_Q2_Q5_settleIsExact_netOnly_noPerPoolReservation`). The flush restores the value.

**Proof of concept.**

```solidity
// Attack::test_multiHop_longTailFirstHopDefers_routeReverts
ops[0] = _swapOp(pD, _dIs0(), -5e18); // D -> A: defers
ops[1] = _swapOp(p1, aIs0p1, -1e18); // A -> B: flush takes D the vault does not hold yet
try victim.run(ops, cs) { fail(); }
catch (bytes memory err) { assertTrue(_contains(err, bytes4(keccak256("Panic(uint256)"))), "not the vault's D transfer"); }
assertEq(tD.balanceOf(address(hook)), d0, "route reverted as a whole");

// Attack::test_forceDeferral_longTail_pullOwnReserveInSameLock
attacker.run(_one(_swapOp(pD, _dIs0(), -5e18)), cs);   assertEq(_pendingL(), 0, "reserve present: inline");
ops[0] = _liqOp(s, -887270, 887270, -100e18);  ops[1] = _swapOp(pD, _dIs0(), -5e18);
attacker.run(ops, cs);                                  assertEq(_pendingL(), L, "reserve pulled in the same lock: deferred");
```

**Recommendation.** Document that routes through a hook pool with long-tail input followed by another hook swap in
the same lock can fail, and that pools need the full `requiredInventory` on hand. Where long-tail tokens matter,
keep a resident buffer and set `disableDeferredRemoval`, or move to a core with `AppDeficit`.

---

## Appendix A: Scenarios investigated and found not exploitable on `7c1090e`

Each refutation was re-run on `7c1090e` for this report.

| Scenario | Result | Refuting test |
| --- | --- | --- |
| Sandwich / JIT extraction (inline path) | An attack sequence on the hook pool returns bit-identical deltas to a hookless twin with resident `L`. The hook's P&L equals a static LP's within 5 wei per token. | `Attack::test_sandwich_hookEqualsStaticLP_noExtraExtraction` |
| Forcing deferral through gas griefing of `try/catch` on a mainstream pool | A sweep of ±40k gas around the minimum (413,425) found no success with a pending record. (Deferral can be forced for long-tail tokens by other means, SIH-03.) | `Security::test_gasGriefing_cannotForceDeferral` |
| Token-callback reentrancy: settle hijack | The whole swap reverts with `CurrencyNotSettled`, and no balance changes. | `Attack::test_reentrancy_settleHijack_revertsWholeSwap` |
| Token-callback reentrancy: nested swap / owner withdraw / emergency removal during a swap | Rejected with `SwapInProgress` / `LockerAlreadySet`. | `Security::test_reentrancy_nestedSwapFromTokenCallbackRejected`, `Security::test_reentrancy_ownerWithdrawAndEmergencyMidSwapRejected` |
| Unauthorized pool creation / attacker-configured pool | Restricted by default. An attacker's pool gets no config, moves no inventory, and cannot be configured. | `Attack::test_attackerPool_getsNoInventory`, `Security::test_access_everyAdminFunctionRejectsNonOwner` |
| Cross-pool triangle in one lock | Hook deltas are clean after every hop, and the loop loses 1.2019 tokens to fees. | `Attack::test_crossPool_triangleInOneLock_losesFees` |
| Rounding | Swapper never ahead. At most 2 wei per swap per side, stranded in the pool: 300/299 wei after 200 zero-fee swaps, hook −200 wei over 100 one-wei claims. 6 decimals: ≤125 raw units over 100 swaps. 0-fee round trip: −4 wei. | `Security::test_roundingDust_zeroFee_leaksToPoolNotSwapper`, `Security::test_roundingDust_oneWeiClaims_swapperPaysMore`, `Accounting::test_Q4_Q5_sixDecimals_dustBounded`, `Accounting::test_Q1_roundTrip_returnsToStart_onlyFeesRemain` |
| Native BNB conservation | Inventory change mirrors trader flow within 4 wei per swap, and no position is left. | `Accounting::test_Q3_nativePool_conserves` |
| Protocol fee interaction | Settle stays exact (mirror within 2 wei), and protocol fees accrue to the manager. | `Accounting::test_Q8_protocolFee_hookEarnsLess_accountingExact` |
| Pending-removal valuation (natural deferral) | The flush returns principal at the frozen price plus third-party donations (31.590 B = 24.590 principal + 7 donated). A config change while pending burns the snapshot. Disable/JIT-pause still flush. An emergency removal on another pool keeps the record. | `Accounting::test_Q6_pendingValueFrozen_donationsAccrueToHook`, `Security::test_configChangeWhilePending_flushUsesSnapshot`, `Security::test_disableAndJitPauseWhilePending_stillFlushes`, `Security::test_emergencyRemoveOtherPool_keepsPending` |
| Donations (ERC20 / native) to the hook | The fill is identical with or without a donation, and donations are withdrawable by the owner. | `Accounting::test_Q3_donationsChangeNothing_butAreOwnerWithdrawable` |
| Random swap sequences with floors (mainstream pools) | Floor never breached after a successful swap, no deferral, no live position, and only expected revert reasons. | `Security::testFuzz_randomSwapSequence_invariantsHold` (256 runs) |
| Withdraw floor / allowlist mechanics | Skips below the floor or above the balance, rejects zero amounts and non-allowlisted recipients. | `Security::test_withdraw_onlyWhitelistedRecipient_neverBelowFloor` |
| `disableDeferredRemoval` | A long-tail swap that would defer reverts with `RemovalDeferralDisabled`; nothing is parked or paid, and the inline direction still works. | `Security::test_disableDeferredRemoval_catchRevertsWholeSwap` |

**Not applicable to the deployment.** The earlier refutation "draining `reservesOfApp` in the same lock cannot
force a deferral" held only on `3c5ef1b`, where the shortfall becomes a transient `AppDeficit`. On `7c1090e` the
opposite holds and is part of SIH-03 (`test_forceDeferral_longTail_pullOwnReserveInSameLock`).

## Appendix B: Test changes for `7c1090e`

- **Setup, all four files.** The Vault is no longer pre-funded by plain transfer. Mainstream tokens get CL-wide
  reserves from hookless full-range pools; a long-tail token gets none.
- **Natural deferral replaces `vm.mockCallRevert`.** `test_deferral_paysFullPrincipal…`,
  `test_frozenPendingToken…`, `test_configChangeWhilePending…`, `test_disableAndJitPauseWhilePending…`,
  `test_partialEmergencyRemove…`, `test_emergencyRemoveOtherPool…`, `test_disableDeferredRemoval…`,
  `test_Q6_…` and `test_Q7_…` now defer by selling a long-tail token.
- **Reserve seeded so the inline path is exercised.** The reentrancy tests and the `inventoryOf` probe pair their
  special token with a reserve pool; the native, 6-decimal and FOT tests seed their own.
- **Replaced.** `test_forceCatch_reserveDrainInSameLock_noDeferral` (held only on `3c5ef1b`) became
  `test_forceDeferral_longTail_pullOwnReserveInSameLock`. `test_Q9_afterSwapTake_needsPhysicalVaultBalanceOfInputToken`
  (pre-funding model of `3c5ef1b`) became `test_Q9_removalDefersOnlyWhenInputExceedsClWideReserve`.
  `test_readOnlyReentrancy_inventoryOfInflatedMidSwap` was renamed `test_inventoryOfMidSwap_inputCreditedBeforeOutputPaid`.
- **Added.** `test_multiHop_longTailFirstHopDefers_routeReverts`,
  `test_dos_tickLiquidityOverflow_deferringPool_needsParkedRecordCleared` (from the reviewer's scratch test),
  `test_dos_griefCost_byBoundaryTick`, `test_Q4_feeOnTransfer_deferringPool_bothDirectionsRevert`.

## Appendix C: Not verified / limitations

- **Live pool set.** The pools bound to the hook, their ranges and `L`, the creator list and the withdraw recipients
  were not read (section 3). SIH-01's severity depends on the ranges.
- **Vault holdings for other apps.** SIH-03's route failure assumes the Vault holds no other balance of the hop-1
  token; balances held for Bin pools or other apps were not read.
- **Router behaviour.** Only "swap, then settle at the end of the lock" was tested.
- **BscScan line numbers.** Not re-verified against the BscScan source in this session (see Scope).
- **Out of scope.** Upgradeability, deployment scripts, the owner contract's code, the periphery/universal router,
  and the helper libraries `CurrencySettler` and `TransientStorage` beyond their use by the hook.
