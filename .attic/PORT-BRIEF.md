# Port brief — task 20.2, parked unit suites → current model

You are porting ONE parked test suite from `.attic/oldtests/` to `test/unit/`. The parked suites were
written against a design that eight numbered decisions have since changed. Your job is to bring back every
test that still describes real behaviour, and to **delete** — not paper over — every test that describes a
mechanism the protocol no longer has.

## Hard rules

1. **Never modify anything under `src/`.** If a test cannot pass because the source looks wrong, say so in
   your report and leave the test failing or removed with a note. Do not "fix" src.
2. **Do not run `forge` at all** — no `build`, no `test`, no `fmt`. Compilation is serialized centrally by
   the caller. Your deliverable is the ported `.sol` file on disk.
3. **Rebase onto the shared fixture.** The parked suites each built their own fixture inline. That is gone.
   Inherit `LaunchpadTest` from `test/Fixtures.sol`, or `HarnessLaunchpadTest` from
   `test/HarnessFixtures.sol` if you need mid-transaction state. Delete the suite's own copies of
   `TestRouter`, `setUp` protocol deployment, `_buy`/`_sell`/`_graduate`, etc. — read `test/Fixtures.sol`
   first and use what is there. Add a helper to your own suite only if the fixture lacks it; do not edit
   `test/Fixtures.sol` (the caller resolves cross-suite helper needs).
4. **Scenario names are the contract with `tasks.md`.** Keep every `// --- Scenario: ... ---` section
   comment and every test name that still maps to a scenario in
   `openspec/changes/add-milestone-launchpad/specs/*/spec.md`. If you delete a test, it is because its
   scenario is gone from the specs — check, don't assume. Never rename a surviving test.
5. **Report what you deleted and why**, by test name. That list is the audit trail for task 20.3.

## What changed in the model

| Decision | Change | Consequence for tests |
|---|---|---|
| **17** | Bonding curve is 32 nested single-sided Doppler positions derived from the template. The `Curve[]` array and the whole multi-curve `CurveLib` API (`defaultCurves`, `validate`, `curveAllocation`, `positionLevels`, `totalPositions`, `lowestStartingLevel`, `MAX_CURVES`, and their errors) are **deleted**. Only `openingLevel`, `farLevel`, `positionStart`, `positionAmount`, `positionLiquidity`, `firstPositionAbove` remain. | Tests of curve *validation* or multi-curve composition are gone. `test/unit/NestedCurve.t.sol` already covers the new shape. |
| **19** | Launch is `launch(LaunchConfig, bytes signature)` — EIP-712 over the config, relayer-submittable, plus a signature-optional creator-direct path. CREATE2 salt derives from the config hash **and** the recovered signer. | Use `_launchDirect`, `_launchRelayed`, `_launchRelayedSignedBy`, `_sign` from the fixture. `test/unit/LaunchSignature.t.sol` already covers signature mechanics — don't duplicate it. |
| **20** | **The anti-snipe decay is deleted entirely**: the block-stepped decay, the `beforeSwap` fee override, the window presets, and the override-vs-step precedence rule. `_beforeSwap` returns a zero delta and a zero fee override, always. | Every decay test, every window-preset test, every precedence test: **delete**. What survives is "the base fee applies from genesis" and "the fee does not depend on time since launch" — those are now the *positive* assertions, and they belong in the ported suite. Fixtures no longer need to `vm.warp` past a window. |
| **21** | Token-denominated fees no longer reach a claimant. Creator and protocol accrue **quote only**. Token fees split 20% milestone fund / 80% LP compounding, with an unpairable remainder carried. The token claim ledgers, entry points and events (`_creatorClaimableTokens`, `_protocolClaimableTokens`, `claimCreatorTokens`, `claimProtocolTokens`) are **deleted**. | Any test asserting a token-denominated claim: delete, or invert into "token fees never accrue to a claimant" if a spec scenario says so. CLAUDE.md's "Two claim ledgers, not one" section is **stale** — ignore it. |
| **22** | Reclaim is deleted: the entry point, `BandReclaimed`, the reclaim-period constant, and Decision 14's quote-routing branch. | Reclaim tests: delete. |
| **4 (revised)** | The single `LiveBand` record is deleted. Band state is two `uint256` bitmaps (`deployedBands`, `completedBands`) plus per-index `deployedAt`. Settlement is bounded by `maxHarvestsPerSwap` (8), not by one-live-band. **Several bands can be live at once.** | Tests asserting "only one band is live" or reading a `LiveBand` struct: delete or rewrite against `hook.bandDeployed(poolId, i)` / `hook.bandCompleted(poolId, i)`. |
| **15** | Deployment is simulation-driven: `LadderLib.Walk`/`advance` walks the incoming swap's whole price path in `beforeSwap` and deploys every band it will cross, up to `maxDeploysPerSwap` (8). **The deploy window is gone** — `LadderLib.inDeployWindow` no longer exists. | Deploy-window tests: delete. |
| **18** | Graduation auto-triggers in the **next** swap's `beforeSwap` once level ≥ `farLevel`; permissionless `graduate()` still exists and shares the internals. The crossing swap itself does not graduate. | Tests that manually call `graduate()` still work, but a test asserting a pool stays in `BONDING_CURVE` after a crossing buy must account for the next swap graduating it. |

## Config and template shape

`LaunchConfig` is now only: `creator`, `name`, `symbol`, `totalSupply`, `devBuyShareWad`,
`devBuyVestingSeconds`, `harvestSplit`, `deadline`. **Everything else moved to `ProtocolTemplate`** — curve
shape, ladder geometry, supply splits, proceeds splits, fee schedule, milestone fund, per-swap caps. So
every parked `config.bandCount`, `config.ladderShareWad`, `config.curves`, `config.baseFee`… becomes
`template.coreBandCount`, `template.ladderSupplyShareWad`, etc. Read the struct in
`src/types/LaunchTypes.sol` rather than guessing field names.

## `LadderLib` signature changes

| Parked call | Current signature |
|---|---|
| `bandLevels(config, graduationLevel, i)` | `bandLevels(int24 graduationLevel, int24 levelSpacing, int24 widthLevels, uint256 index)` |
| `perBandInventory(config)` | `perBandInventory(uint256 totalSupply, uint64 ladderSupplyShareWad, uint8 coreBandCount)` |
| `ladderSupply(config)` | `ladderSupply(uint256 totalSupply, uint64 ladderSupplyShareWad)` |
| `sizeInventory(available, perBand)` | `sizeInventory(uint256 available, uint256 perBand, uint8 capMultiple)` |
| `withinLadderCap(bandCount, index, maxFeeFunded)` | `withinLadderCap(uint8 coreBandCount, uint256 index, uint32 feeFundedBandsCreated, uint8 maxFeeFunded)` |
| `inDeployWindow(...)` | **deleted** |

`MAX_LIQUIDITY_PER_TICK`, `boundedLiquidity`, `sqrtPriceAtLevel` are unchanged. `Walk`/`advance` are new.

## Empirical geometry (default template, local `PoolManager`)

Derived at real cost; do not re-derive. Graduation level **−152025**; band `i` spans
`[-149790 + 2235i, -149343 + 2235i]` — spacing 2235, width 447, and a 1788-level gap between one band's top
and the next one's floor. Reaching band 0 from graduation costs ≈ 59 ETH. `_buy(5_000 ether)` unlimited
deploys 8 bands, completes 8, and ends at level −43343, far past the ladder. `_graduate()` leaves spot
exactly at the graduation level with zero bands deployed.

More of this, including why only the first fee threshold is reachable in a unit fixture and the
conservation identity the ladder tests use, is in `openspec/reports/verification-findings-g16-g17.md` —
read §3–§7 if your suite touches the ladder, harvests, or fees.

## Gotchas that have already cost debugging time

- **`via_ir` common-subexpression-eliminates `block.timestamp`.** Two `vm.warp(block.timestamp + delta)`
  calls in one test function collapse into a single warp. Compute every warp from the fixture's absolute
  `launchTime`.
- **Which currency a swap fee lands in depends on direction.** A buy (`zeroForOne == true`) pays its fee in
  ETH/`currency0`; a sell pays in token/`currency1`. Measure a fee *rate* on the sell side — the harvest's
  LP share arrives as a `donate` of `currency0` only and is indistinguishable from quote-side swap fees.
  Collect once before a measured swap to zero the accrual.
- **A zero-accrual `collectFees` emits nothing at all.** Both early returns precede the `FeesCollected`
  emit, so that silence *is* the observable form of "collection with zero accrual is a no-op".
- **Rounding dust is specified, not a bug.** The specs say "up to rounding dust retained by the hook". Dust
  accrues to the protocol side, never against a user, and there is no sweep in v1. Assert `assertGe` or
  `assertApproxEqAbs` where the specs say dust — never exact equality.
- **Ordering and multiplicity inside one transaction need the recorded log, not getters.** The fixture has
  `_countLogs`, `_bandIndices`, `_firstLogAt`, `_lastLogAt`, `_tokenDeployed`, `_tokenReturned`,
  `_deployedInventoryOf` for exactly this.
- **`_buyToLevel(x, limit)`'s post-swap level is higher than `limit` whenever a harvest fires**, because the
  buyback runs after the fill. Target a level no harvest overshoots, or assert on the pre-harvest level.

## Report format

Return: the file you wrote; the count of tests kept; each deleted test by name with the decision number
that killed it; every place you had to guess; and anything you believe is a genuine source bug (do not fix
it).
