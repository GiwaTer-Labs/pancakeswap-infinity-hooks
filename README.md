# PancakeSwap Infinity Hooks — Collected

All Solidity hooks found in the full history of
[`pancakeswap/infinity-hooks`](https://github.com/pancakeswap/infinity-hooks) and
[`pancakeswap/infinity-dynamic-fee-hook`](https://github.com/pancakeswap/infinity-dynamic-fee-hook)
(all branches, open and closed PRs), ported to the latest `infinity-core` / `infinity-periphery`.

## Quick Start

```bash
forge install
forge build
forge test --isolate   # --isolate: see infinity-core#35
```

## Hooks

| Hook | Path | Source | Status upstream |
|---|---|---|---|
| CLFullRange | `src/pool-cl/full-range` | infinity-hooks `main` | merged |
| CLGeomeanOracle | `src/pool-cl/geomean-oracle` | infinity-hooks `main` | merged |
| CLLimitOrder | `src/pool-cl/limit-order` | infinity-hooks `main` | merged |
| CLVeCakeExclusiveHook | `src/pool-cl/vecake-exclusive` | infinity-hooks `main` | merged |
| SampleCLDynamicFeeHook | `src/pool-cl/dynamic-fee` | infinity-hooks `main` | merged |
| BinGeomeanOracle | `src/pool-bin/geomean-oracle` | infinity-hooks `main` | merged |
| BinLimitOrder | `src/pool-bin/limit-order` | infinity-hooks `main` | merged |
| BinVeCakeExclusiveHook | `src/pool-bin/vecake-exclusive` | infinity-hooks `main` | merged |
| SampleBinDynamicFeeHook | `src/pool-bin/dynamic-fee` | infinity-hooks `main` | merged |
| CLAntiSniping | `src/pool-cl/anti-sniping` | infinity-hooks `anti-sniping` (PR #20) | open, unaudited |
| CLSwapStartTime | `src/pool-cl/swap-start-time` | infinity-hooks `feat/swap-start-time` (PR #29) | open |
| CLProxyHook | `src/pool-cl/proxy` | infinity-hooks `feat/proxy-hook` (PR #7) | open, WIP, no tests |
| CLDynamicFeeHook (ewVWAP) | `src/pool-cl/dynamic-fee/CLDynamicFeeHook.sol` | infinity-dynamic-fee-hook `master` | merged, deployed |
| CLOracleDynamicFeeHook | `src/pool-cl/dynamic-fee-oracle` | infinity-dynamic-fee-hook `feat/formula-without-oracle` (PR #5) | closed |
| CLOracleAfterSwapDynamicFeeHook | `src/pool-cl/dynamic-fee-oracle-afterswap` | infinity-dynamic-fee-hook `feat/refactor-dynamic-fee-no-simulation` (PR #4) | closed |

The oracle dynamic fee hook from infinity-hooks PR #15/#16 is an earlier snapshot of
`CLOracleDynamicFeeHook` and is not included separately.

## Porting changes

Code from branches older than the v4 → Infinity rename was adapted:

- Imports `pancake-v4-core` / `pancake-v4-periphery` / `@pancakeswap/v4-core` → `infinity-core` / `infinity-periphery`.
- `Permissions` fields renamed (`*ReturnsDelta` → `*ReturnDelta`, `Liquidiy` → `Liquidity`).
- `before/afterInitialize` lost `hookData`; `after{Add,Remove}Liquidity` gained `feesAccrued` (`CLProxyHook`).
- `CLOracleAfterSwapDynamicFeeHook` read its pool config from initialize `hookData`. It now exposes
  `initializePool(key, sqrtPriceX96, hookData)`; initializing directly on the pool manager reverts.
  The config is applied inside `initializePool` because the pool manager skips hook callbacks when the hook is the caller.
- Tests: `MockV4Router` → `MockInfinityRouter`, `CLSwapExactInputSingleParams` lost `sqrtPriceLimitX96`,
  `BinAddLiquidityParams` gained `minLiquidities`, `Hooks.Wrap__FailedHookCall` → `CustomRevert.WrappedError`,
  `forge-gas-snapshot` → `vm.startSnapshotGas`.
- Legacy dynamic fee hooks renamed to avoid clashing with the deployed `CLDynamicFeeHook`.

## Dependencies

| Library | Version |
|---|---|
| infinity-core | `3c5ef1b` (2026-10-01) |
| infinity-periphery | `56a7a4f` (2026-10-01), remapped onto the top-level infinity-core |
| prb-math | v4.2.0 |
| forge-std | v1.17.0 |
| pancake-create3-factory | `9e0b708` |

## Deployment

`script/01`–`05` come from infinity-hooks, `script/06_DeployCLDynamicFeeHook.s.sol` from infinity-dynamic-fee-hook.
`script/config/*.json` merges both repos' configs (bsc-mainnet, base-mainnet, bsc-testnet, ethereum-sepolia).

## License

Upstream licenses apply per file (UNLICENSED / BUSL-1.1 as declared in each SPDX header).
