# Release check — task 14.4

Scope: task 14.4 of `openspec/changes/add-milestone-launchpad/tasks.md`, *"Run the full suite plus the
size gate as a release check and record the results"*. This is that record. Nothing here is a new
finding; it is the state of the gates and the three test layers at the point the change was declared
ready, plus the one box 14.4 cannot close on its own.

Status at time of writing: 14.4 complete on the evidence below. **14.3 remains open and is blocked, not
skipped** — see the last section.

The run was the release target itself, followed by the two things it deliberately leaves out:

```
make release-check
forge build --sizes --skip 'test/**' --skip 'script/**'
BASE_RPC_URL=... make test-fork
```

`release-check` is `pins fmt-check build size size-gate-selftest lock-check layout-check test-unit
test-invariant`, and its own closing line says why the fork layer is separate: it needs a Base endpoint
in the environment, which the target refuses to invent.

---

## 1. The four custom gates

All four pass. They are listed first because CLAUDE.md rates them "as much as the tests", and two of
them assert things no runtime test can reach.

**`make pins`** — `pin ok v4-core@5f00c84`, `pin ok v4-periphery@9628c36`. Both submodules sit on the
pinned commits, so every number below was produced against the intended v4.

**`make size`** — the EIP-170 gate over `src/` only, at the 24,576-byte limit:

| Contract | Runtime bytes | Headroom |
| --- | --- | --- |
| `MilestoneHook` | 21,561 | 3,015 |
| `MilestoneColdPaths` | 21,916 | 2,660 |
| `LaunchSupport` | 5,858 | 18,718 |
| `RevenueNFT` | 3,584 | 20,992 |
| `MilestoneToken` | 1,790 | 22,786 |

`size_gate: OK, 5 contract(s) within the 24576 byte limit`. The two delegatecall halves are the whole
story here: together they hold the launchpad, and each is within 2.6-3.0 KB of the ceiling. That is the
margin the design's leading structural risk is about, and it is why the gate runs on every push rather
than at release.

**`make size-gate-selftest`** — proves the gate is not passing vacuously. It builds a deliberately
oversized fixture and requires rejection: `FAIL Oversized: 25214 bytes, 638 over the 24576 limit`, then
`size-gate-selftest: PASS (gate rejected the oversized fixture)`. So the OK above is a measurement, not
an empty loop.

**`make lock-check`** — `OK, 7 modifyLiquidity site(s) across 3 file(s), 3 on the full range, none
reduces it`. This is the structural form of the graduation spec's code-lock: no path anywhere in either
half combines a negative `liquidityDelta` with `FULL_RANGE_SALT`. It reads source, so it covers paths a
test would have to reach first.

**`make layout-check`** — both halves of the delegatecall pair, compared against `MilestoneBase`:
`check_storage_layout: OK, MilestoneHook and MilestoneColdPaths both match MilestoneBase across 5
slot(s)`, and `check_cold_path_guards: OK, 5 entry point(s) all guarded (collectFees, dispatchUnlock,
graduate, graduateWhileUnlocked, launch)`. Five slots, five guarded entry points, no unguarded satellite
surface. A layout drift here would write one variable over another with no revert and no event, which is
why this gate exists rather than a test.

---

## 2. Build

`forge fmt --check` clean, then `forge build` over all 35 changed files: **`Compiler run successful with
warnings`** — no errors, `via_ir` on, and the full tree recompiled from cold because `make fmt` had just
touched every file.

Two solc warnings, both in tests and both cosmetic: an unused local at `test/unit/DevBuy.t.sol:86`
(the `MilestoneToken t` half of a destructuring), and `test/unit/Graduation.t.sol:38`'s
`_graduatedEvent()` being restrictable to `view`.

`forge lint` runs inside the build and is advisory. Of its distinct findings, eight land in `src/`:
seven `asm-keccak256` gas suggestions (`src/libraries/LaunchSignature.sol` at six sites,
`src/LaunchSupport.sol:54`) and one unused import, `TickMath` at `src/MilestoneBase.sol:6`. The single
`divide-before-multiply` warning is in a test (`test/unit/DevBuy.t.sol:244`), not in production math.
None of these were touched: source changes are out of scope for a release check, and the unused import
costs no bytecode. They are recorded here so the next person does not have to re-derive them.

---

## 3. The three test layers

**Unit — `make test-unit`, 33 suites, 436 tests, all passing.**

```
Ran 33 test suites in 19.12s (40.09s CPU time): 436 tests passed, 0 failed, 0 skipped (436 total tests)
```

This is the specs re-stated against a locally deployed `PoolManager`. Every `// --- Scenario: ... ---`
header in the tree was audited against `specs/*/spec.md` as part of this release check and the header set
is now a faithful index: **zero mismatches** across the unit, invariant and fork layers. Three fork
headers named scenarios that do not exist in any spec and were corrected (see section 5).

**Invariant — `make test-invariant`, 18 tests, all passing.**

```
Ran 1 test suite in 166.77s (166.73s CPU time): 18 tests passed, 0 failed, 0 skipped (18 total tests)
```

Seventeen of those are `invariant_` properties driven by `LaunchpadHandler`; the eighteenth,
`test_handlerDrivesEveryActionToEffect`, is the coverage guard that keeps the other seventeen honest — a
handler that never reached an action would leave every property trivially true. 167s wall against 1,462s
CPU is the randomised campaign fanning out across cores.

The properties fall into the three groups the tasks asked for: conservation (every token held by a known
party, supply falling only by routed buyback burns, hook custody covering its obligations in both
currencies, ETH conserved, routed amounts summing to harvested amounts), structure (harvest shares summing
to one whole, band deployment ascending and single-use, per-swap work caps respected, full-range liquidity
never decreasing and matching its stored value, progress never regressing), and isolation (creator vs
protocol, across pools, per-pool protocol balances, per-pool state, and only the entitled party claiming).

**Fork — `make test-fork` against the live Base v4 singleton, 5 suites, 20 tests, all passing.**

```
Ran 5 test suites in 581.86ms (2.48s CPU time): 20 tests passed, 0 failed, 0 skipped (20 total tests)
```

| Suite | Tests |
| --- | --- |
| `ForkSmoke` | 9 |
| `ForkOrientation` | 5 |
| `ForkAdversarial` | 4 |
| `ForkLifecycle` | 1 |
| `ForkBuybackPush` | 1 |

Run with `FOUNDRY_PROFILE=fork` at the pinned block against `PoolManager`
`0x498581fF718922c3f8e6A244956aF099B2652b2b` on chain 8453. The endpoint came from `BASE_RPC_URL` in the
process environment and appears in no committed file, which is what `foundry.toml`'s `[rpc_endpoints]`
indirection is for.

---

## 4. Sizes against both limits

`forge build --sizes --skip 'test/**' --skip 'script/**'` reports 39 artifacts. Thirty-four are
internal-only libraries that compile to a 3-byte stub and are never deployed; the five that are deployed
are the five the gate measures. Runtime is against EIP-170's 24,576 bytes, initcode against EIP-3860's
49,152:

| Contract | Runtime (B) | Runtime margin | Initcode (B) | Initcode margin |
| --- | --- | --- | --- | --- |
| `MilestoneHook` | 21,561 | 3,015 | 25,046 | 24,106 |
| `MilestoneColdPaths` | 21,916 | 2,660 | 24,530 | 24,622 |
| `LaunchSupport` | 5,858 | 18,718 | 5,884 | 43,268 |
| `RevenueNFT` | 3,584 | 20,992 | 4,412 | 44,740 |
| `MilestoneToken` | 1,790 | 22,786 | 2,911 | 46,241 |

Initcode is worth recording as well as runtime because the hook's address is mined: it is deployed by
CREATE2 over initcode that embeds the satellite's address, and EIP-3860 both caps initcode at 49,152 bytes
and charges gas per word of it. At 25,046 bytes the hook uses just over half that budget.

The two halves are the only contracts near any limit, and the split is the reason they fit at all: the
launchpad's logic is about 43 KB of runtime code across a pair that shares one storage layout. `via_ir`
is load-bearing here, not a preference.

---

## 5. Corrections made while running this check

Three scenario headers in the fork layer named scenarios that exist in no spec. CLAUDE.md's convention is
that the header set is "a faithful index of the specs", so an invented name is a false coverage claim.
All three were corrected, and a sweep of every `// --- Scenario ... ---` header in `test/` against
`specs/*/spec.md` now reports zero mismatches in all three layers:

- `ForkBuybackPush.t.sol` claimed *"Simulated deployment mints every band the swap will reach"*. It now
  claims `milestone-ladder`'s **"A deployed band cannot be jumped without filling"**, which is what the
  test actually exercises: the buyback push enters band 1's range and partially fills it, and the closing
  buy exits its top and completes it.
- `ForkLifecycle.t.sol:363` claimed *"Collection is permissionless"*. The real name in `swap-fees` is
  **"Any address can trigger collection"** — a straight rename, same behaviour asserted.
- `ForkLifecycle.t.sol:110` claimed *"Launch with a valid signature succeeds"*, which `token-launch` does
  not contain in any of its 30 scenarios. The helper asserts a creator-sent signed launch carrying its dev
  buy; the two scenarios it comes closest to, *"Dev buy is observable on chain"* and *"Zero vesting
  releases immediately"*, are already claimed by `test/unit/DevBuy.t.sol:156` and `:193`. Rather than
  duplicate a claim across layers, the header is now marked derived:
  `// --- A signed config sent by the creator carries its dev buy: derived, no scenario of its own ---`.

No test was renamed and no spec was edited. The suites' behaviour is unchanged — all three edits are
comments, which is why the fork layer recompiled 6 files and produced identical results.

---

## 6. What this check does not close: 14.3

**14.3 is blocked, not skipped.** It asks for a rehearsal on a public testnet with a transcript showing a
relayed launch, graduation, at least one harvest, and successful creator and protocol claims. Three things
are missing from this environment, none of which can be substituted:

1. **A Base Sepolia endpoint.** `foundry.toml` resolves the `base_sepolia` alias from
   `BASE_SEPOLIA_RPC_URL`, which is unset. As with the fork profile, the endpoint is deliberately not
   committed, so there is nothing to fall back on.
2. **A funded deployer key.** The rehearsal broadcasts real transactions and the lifecycle needs ETH to
   buy through the curve to `farLevel`; a rehearsal that cannot graduate cannot show a harvest or a claim.
3. **The six addresses `script/Deploy.s.sol` reads from the environment** — `POOL_MANAGER`,
   `PROTOCOL_ADMIN`, `PROTOCOL_RECIPIENT`, and then `REVENUE_NFT`, `LAUNCH_SUPPORT` and `COLD_PATHS` for
   the later steps, which is the Migration Plan's ordering expressed as script inputs.

What *is* verified without a testnet: the scripts compile as part of the build above, `MineHookSalt.s.sol`
and `Deploy.s.sol` are both in place from 14.1 and 14.2, and the fork layer already re-runs the full
lifecycle — relayed signed launch, graduation, harvest, and claims — against the live Base singleton at a
pinned block. The rehearsal's remaining value is the part a fork cannot give: real broadcast, real gas,
real block times, and the deployment gate that proves both halves were constructed against the same
template (`templateHash()`).

So 14.3 stays unticked, and the honest statement of the change's readiness is: everything verifiable
without a funded testnet key is verified.

---

## 7. Summary

| | |
| --- | --- |
| `make release-check` | **exit 0** |
| `make test-fork` | **exit 0** |
| Gates | pins, fmt-check, size, size-gate-selftest, lock-check, layout-check — all pass |
| Unit | 33 suites, 436 tests, 0 failed |
| Invariant | 17 properties + 1 coverage test, 0 failed |
| Fork | 5 suites, 20 tests, 0 failed |
| **Total** | **474 tests, 0 failed, 0 skipped** |
| Largest deployed contract | `MilestoneHook`, 21,561 B runtime — 3,015 B under EIP-170 |

Task 14.4 is complete on this evidence. 14.3 remains open and blocked as described above, which leaves the
change at **84 of 85** boxes.
