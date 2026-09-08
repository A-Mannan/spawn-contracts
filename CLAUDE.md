# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A Uniswap v4 hook launchpad for Base. Its differentiator is the **milestone ladder**: protocol-owned,
one-sided sell-limit bands at ascending market-cap levels, JIT-deployed as price approaches them and
harvested automatically when price crosses a band's top, with proceeds routed per launch config. One
deployed hook serves every launch; per-launch state is keyed by `PoolId`.

Three documents are normative. Read the relevant parts before changing behaviour:

- **`DESIGN.md`** — product design: mechanisms, the launch-parameter bounds table (§9), and the risk
  register (§10). Source comments cite it by section.
- **`openspec/changes/add-milestone-launchpad/design.md`** — numbered implementation **Decisions 1–22**
  plus a Risks register. Source comments cite these by number ("design Decision 13"). Where reality
  forced a change, the decision carries an in-place *revision note* rather than being rewritten — keep
  that convention. Decisions 15–22 came out of a planning review and several rework earlier ones:
  **22 supersedes 14 outright**, and 1, 4, 5, 8, 9, 14 and 19 carry revision notes. Read a decision to
  its end before citing it. If an implementation reveals a design issue, amend this document; don't
  silently narrow the behaviour.
- **`openspec/changes/add-milestone-launchpad/specs/*/spec.md`** — requirements expressed as named
  `#### Scenario:` blocks. Those names are the contract with the test suite (see Testing).

**`openspec/changes/add-milestone-launchpad/tasks.md` is the work ledger.** Each task names the exact
scenarios it must cover. Mark a task `- [x]` only when it is implemented *and* a passing test exists for
every scenario it names. **84 of 85 boxes are ticked.** Groups 1–13 and 15–20 are done, and so is 14.4:
the release check passed and is recorded in `openspec/reports/release-check-g14.md` — 474 tests
across the three layers (436 unit, 18 invariant, 20 fork), all six gates green, `MilestoneHook` at 21,561
bytes with 3,015 to spare. The one open box is **14.3**, the public-testnet rehearsal: it needs
`BASE_SEPOLIA_RPC_URL`, a funded deployer key and the six addresses `script/Deploy.s.sol` reads from the
environment, so it cannot be run from a sandbox. The `openspec` CLI is on PATH and the `/opsx:*` slash
commands drive this workflow.

Some tasks still name scenarios the planning review renamed or deleted. Where a task and a spec disagree
**the spec wins** — the drift is in `tasks.md` and is tracked as an outstanding correction, not a licence
to change a spec to match a task.

## Commands

```bash
make build              # forge build
make test               # == test-unit: forge test --no-match-path 'test/fork/**'
make test-invariant     # test/invariant/** — the handler-driven suite
make test-fork          # needs BASE_RPC_URL; runs FOUNDRY_PROFILE=fork
make deep               # 10k fuzz / 1k invariant runs
make fmt / fmt-check
make release-check      # the full gate: pins fmt-check build size size-gate-selftest
                        #                lock-check layout-check test-unit test-invariant
```

`make fmt` has been run over the whole tree, so `fmt-check` is clean and `release-check` is unblocked.
Keep it that way: run `make fmt` before committing rather than letting a formatting backlog rebuild.

Single test:

```bash
forge test --match-path test/unit/MilestoneHarvest.t.sol
forge test --match-test test_crossingTheBandTopCompletesTheMilestone -vvv
forge test --match-contract MilestoneHarvestTest
```

Four custom gates matter as much as the tests, and CI runs all of them on every push:

- **`make size`** — EIP-170 gate over `src/` only. The hook has crossed the 24 KB limit twice during
  development; this is the leading structural risk in `design.md`, which is why the gate runs
  continuously rather than at release. `make size-gate-selftest` proves the gate isn't passing vacuously.
- **`make layout-check`** — asserts `MilestoneHook` and `MilestoneColdPaths` share one storage layout
  slot-for-slot (both compared against `MilestoneBase`, not against each other), and that every
  state-changing entry point on the satellite carries `onlyDelegated`. **Run this after touching state
  variables or adding a satellite entry point.**
- **`make lock-check`** — source-level assertion that no `modifyLiquidity` call site combines a negative
  `liquidityDelta` with `FULL_RANGE_SALT`, in either half of the hook.
- **`make pins`** — verifies `lib/v4-core @ 5f00c84` and `lib/v4-periphery @ 9628c36`.

`via_ir = true` is load-bearing (it is what fits the hook under EIP-170), so a cold build takes minutes.
Budget for that; don't assume a fast edit-compile loop.

## Architecture

### The hook is two contracts sharing one storage layout

`MilestoneBase` (abstract) declares **all** shared state, the whole event/error surface, and the
settlement primitives. `MilestoneHook` (the mined-address hook, swap path, ladder, harvest, claims) and
`MilestoneColdPaths` (launch, graduation, fee collection and routing) both inherit it. The hook reaches
the satellite by `DELEGATECALL`, so the satellite executes in the hook's storage, as the hook's address,
with the original `msg.sender`.

Consequences you must respect:

- **Never declare a state variable in either derived contract.** Add it to `MilestoneBase`. A drift
  writes one variable over another with no revert and no event; `make layout-check` is the only thing
  standing between that and silent corruption.
- Satellite entry points need `onlyDelegated`. Its immutables resolve from its *own* bytecode even under
  delegatecall, so it must be constructed with the same pool manager / NFT / launch support / template as
  the hook. `templateHash()` exists on both halves precisely so a deployment gate can prove the two
  templates match (Migration Plan step 4) — a mismatch is invisible at runtime, since neither half reads
  the other's copy.
- `coldPaths` is immutable on the hook, and the hook's address is mined against initcode that includes
  it — so replacing launch logic means deploying and re-mining a new hook. There is no upgrade path
  anywhere in v1; the only mutable protocol state is `protocolRecipient`.
- The swap path deliberately stays in the hook: the ladder runs inside `beforeSwap`, and an extra
  `DELEGATECALL` per swap is a cost every trader would pay.

`LaunchSupport` (token deployment, EIP-712 digest, config validation) and the `src/libraries/*` are
external/internal libraries **for bytecode reasons**, not layering aesthetics. Moving logic back inline
can break `make size`.

### `level = -tick` is the protocol's only coordinate

Native ETH is `address(0)`, so it is always `currency0` and the launch token is always `currency1`. Pool
price is token-per-ETH: **token price up means tick down.** Every piece of ladder, curve, graduation and
harvest arithmetic runs in `level = -tick`, which rises with token price. `src/libraries/Orientation.sol`
is the *only* place the sign flips — at `slot0` reads and when building `modifyLiquidity` params.

A sign error here is not a revert. It is a band placed on the wrong side of spot, filled instantly at the
wrong price. Keep new arithmetic in level space and convert only at the pool boundary.

A single-sided sell band is therefore a range strictly *below* the current tick, holding only `currency1`.

### Everything launch-shaped lives in one immutable template

Decision 16: band geometry, curve shape, supply split, graduation split, base fee, both fee step-downs,
the milestone-fund share and the per-swap work caps are all fields of `ProtocolTemplate`, fixed at
protocol deployment and copied into immutables. A launch chooses only its metadata, supply, dev buy
(≤10% of supply, ≤365 days vesting) and harvest split. `Bounds.defaultTemplate()` is the canonical
published set of numbers — no protocol code path reads it, so the deployment script and the test fixtures
cannot drift from each other. The constructor sanity-checks the template (`InvalidTemplate`) rather than
trusting it.

### Lifecycle

`BONDING_CURVE` → `GRADUATED`, one pool, one hook, in-place morph — no second pool, no migration path.
Graduation happens either way round: **the next swap's `beforeSwap` auto-graduates** once the level has
reached `farLevel` (Decision 18), and permissionless `graduate()` races it for a caller who would rather
pay that gas deliberately. Both read the live tick at call time, so a pool that touched the far level and
fell back has not graduated.

Launch is **signed-config with permissionless relay** (Decision 19): the creator signs an EIP-712 digest
over the whole config and any address may relay it, or the creator sends their own transaction with an
empty signature. The token address is CREATE2-derived from the config hash and the recovered signer, so
it is knowable before launch. A dev buy rides **only** the creator's own transaction; a relayed launch
leaves that share as curve inventory.

Launch runs: validate → deploy token → `initialize` → `unlock` → in `unlockCallback` (`GENESIS`) mint
**curve position 0 only**, settle the token side, execute the optional dev buy. Positions 1–31 deploy
just-in-time as the simulated swap path reaches them (Decisions 15 and 17). Genesis minting cannot live
in `afterInitialize` because `initialize` does not unlock the manager and `modifyLiquidity` is
`onlyWhenUnlocked` (Decision 5).

Graduation burns the curves, splits proceeds 40 LP seed / 55 creator / 5 protocol, and seeds the single
full-range position. That position is **code-locked**: no removal path exists, which `make lock-check`
enforces structurally.

### Ladder: derived geometry, bitmap state

Bands are computed, never stored: `levelLower(i) = graduationLevel + (i+1) * bandLevelSpacing`,
`levelUpper = levelLower + bandWidthLevels`. Uniform level spacing is geometric in market cap — the
template's 2235 levels are a 1.25× step, and the 447-level wall is exactly a fifth of that gap. 30 core
bands reach roughly 800× the graduation valuation; up to 30 fee-funded extensions continue from there.

What needs storage is which bands exist and which are finished, so state is three bitmaps plus a cursor
(Decision 4, **revised** — the single-`LiveBand` invariant is gone): `deployedBands & ~completedBands` is
the live set and may hold several bands at once, `nextBandIndex` is the lowest index never deployed or
skipped, and `curveDeployed` is the same idea for curve positions. Work per swap is bounded by the
template instead (`maxDeploysPerSwap` / `maxHarvestsPerSwap`, both 8), not by there being only one band.

`beforeSwap` deploys on a **buy** only, by simulating the incoming swap's path against v4's own math and
minting every undeployed band it will cross; a sell moves away from everything above spot. A band whose
lower bound is already behind spot cannot be minted single-sided, so it is **skipped**: its share moves
into `carriedInventory` and the next band draws on it. Skipping is the specified outcome — it is also what
makes the straddle deadlock unreachable, since a band that could neither deploy nor skip would ask v4 for
a two-sided mint and revert `beforeSwap`, bricking every buy.

`afterSwap` harvests every live band whose top the swap carried the price past, up to
`maxHarvestsPerSwap`, then routes each four ways (creator / buyback / protocol / LP per the launch's
`harvestSplit`) and applies any fee step-down. Beyond the cap the remaining live bands stay live and
settle on a later swap.

### Custody: real balances, except mid-swap

Decision 2 is direct custody — the hook holds real ERC20 and ETH. **Decision 13 is the exception that
trips people up:** anything collected from the pool *while a swap is in flight* is minted as an ERC-6909
claim (`poolManager.mint`), never `take`n. v4 collects a swapper's input after `swap` returns, so inside
`afterSwap` the manager is short by exactly the amount of the swap in progress — and a band completes
precisely when a buy has consumed its whole inventory, so the shortfall is guaranteed, not incidental.
Debits raised in the same frame (buyback input, LP donation) are paid by *burning* that claim.
`_ensureEth` redeems claims to real ETH lazily, opening its own unlock, and the pull-payment entry points
call it before paying. So "hook custody" is backed by raw ETH or by a claim depending on where the value
came from, and claimants must not have to tell them apart.

### One claim ledger per party, ETH only

Decision 21: creators and the protocol are paid in ETH and nothing else. `_creatorClaimable` and
`_protocolClaimable` are the only ledgers — there are no token ledgers, no token claim entry points and
no token claim events. Token-denominated fees never reach a claimant; they build walls and liquidity
(see Fees below). Every accrual — curve proceeds, swap fees, harvests — lands in the same quote ledger,
tagged by `AccrualSource` for off-chain attribution only.

All accrual is **pull-based bookkeeping** — nothing is ever pushed to a creator or the protocol during
settlement, which is what makes a harvest independent of whether the recipient reverts on receive.
Creator claims are gated on current `RevenueNFT` ownership (`tokenId == PoolId`), so unclaimed balance
follows the NFT on transfer.

### Fees: one static base, stepped down by milestones

Decision 20 removed the anti-snipe decay and with it every `beforeSwap` fee override — that callback now
always returns a zero fee. What remains is a static base fee (template default 1%) and **two permanent
step-downs**, applied by `updateDynamicLPFee` at the harvest that crosses a completion threshold (8
completions → 0.5%, 16 → 0.25%). `DYNAMIC_FEE_FLAG` in `PoolKey.fee` is retained *solely* so those
step-downs can act; the flag is not part of the hook address.

Fee collection is permissionless (`collectFees`) and routes **per currency**. The quote side splits 60 LP
/ 30 creator / 10 protocol. The token side goes 20% to the milestone fund — the next band's inventory —
and the rest to full-range compounding, with **nothing** reaching a claimant. Diversion happens only on
the token side, because funding a band from quote would mean buying token, and the `milestone-ladder`
requirement that inventory accrue "with no swap performed and no price impact" rules that out; past the
ladder cap there is no next band, so the whole token amount compounds. The LP share that cannot be paired
at spot is carried in `pendingLpQuote`/`pendingLpToken` to the next collection rather than discarded.

### Other cross-cutting mechanisms

- **Transient locks** (`src/libraries/TransientLock.sol`, Decision 7) have two semantics on purpose:
  `enter`/`exit` *reject* re-entry (external entry points, where concurrency is always a bug); `held`
  lets the swap callbacks *suppress* their own work (reverting there would abort the very harvest that
  opened the lock).
- **Position salts** are deterministic and the three families are disjoint by construction:
  `FULL_RANGE_SALT` (a hash), band salts (top bit set), curve salts (indices in the low bits). Recompute,
  never store.
- **Every manager interaction routes through `unlockCallback`** dispatching on `UnlockAction`
  (`GENESIS`, `GRADUATE`, `REDEEM_QUOTE`, `COLLECT_FEES`); unrecognised values fail closed.

## Testing

Unit tests live in `test/unit/` against a locally deployed `PoolManager`. The fork layer (`test/fork/`)
re-runs the specs against the *deployed* Base v4 singleton at a pinned block — `make test-fork`, which
needs `BASE_RPC_URL` in the environment and nowhere else (`foundry.toml` resolves the `base` alias from
it, so no endpoint is ever committed). The invariant layer (`test/invariant/`) is handler-driven:
`LaunchpadHandler.sol` bounds the actions, `LaunchpadInvariants.t.sol` states the properties.

Conventions to follow when adding tests:

- **Test names and `// --- Scenario: ... ---` section comments mirror spec scenario names.** That
  correspondence is how `tasks.md` completion is verified, so keep it literal. Where a test serves a
  scenario from another capability's spec, name the spec in the header:
  `// --- Scenario (revenue-claims): ... ---`. A test that is genuinely derived rather than specified
  says so — `// --- <claim>: derived, no scenario of its own ---` — so the header set stays a faithful
  index of the specs.
- **Inherit the shared fixture, don't rebuild it.** `test/Fixtures.sol` defines `LaunchpadTest`: it
  deploys the manager, NFT, `LaunchSupport`, the satellite and the hook, launches a default pool, and
  exposes `_launchDirect` / `_launchRelayed` / `_launchRelayedSignedBy` / `_sign` plus level helpers.
  `test/HarnessFixtures.sol` defines `HarnessLaunchpadTest`, which is the same wiring with the harness
  artifact at the hook address (it overrides `_hookArtifact()`; the address encodes the permission flags,
  so a harness cannot simply be `new`ed elsewhere).
  `test/fork/ForkFixtures.sol` defines `BaseForkTest` / `BaseForkHarnessTest`, the same wiring again with
  the *live* Base singleton as the manager: the fork suites inherit those, never `LaunchpadTest` directly.
- The hook must live at an address encoding its permission flags:
  `address(uint160((uint160(0xBEEF) << 20) | 15040))`, placed with
  `deployCodeTo("MilestoneHook.sol:MilestoneHook", ctorArgs, HOOK_ADDR)`. Deploy `MilestoneColdPaths`
  first (the hook's constructor rejects a codeless satellite), then `nft.setMinter(HOOK_ADDR)`. The
  fixture already does all of this — this is here for when you need to understand it, not repeat it.
- `TestRouter` (`test/Fixtures.sol:32`) stands in for a third-party integrator, driving the plainest
  `unlock`/`swap`/`settle` sequence an integrator would write. `swapToLimit` is what you want for large
  buys — a plain `swap` runs the price to the extreme, because nothing provides liquidity above the far
  level until graduation. Negative `amountSpecified` is exact-input.
- `test/harness/MilestoneHookHarness.sol` exposes internals and adds test-only `UnlockAction`s
  **numbered from 200** so they cannot collide with production ones; `_dispatchUnlock` delegates anything
  below 200 to `super`.
- The fixture launches at `t = 0` and records `launchTime`. There is no anti-snipe window to warp past
  any more (Decision 20), but every warp should still be computed from `launchTime` — see the gotcha
  below.

### Gotchas that have cost real debugging time

- **`via_ir` common-subexpression-eliminates `block.timestamp`.** Two `vm.warp(block.timestamp + delta)`
  calls in the same test function collapse into one warp. Compute every warp from the fixture's absolute
  `launchTime` instead. See `test/Fixtures.sol:189` and `test/unit/DevBuy.t.sol:238`.
- **Which currency a fee lands in depends on swap direction.** A buy (`zeroForOne == true`) pays its fee
  in ETH/`currency0`; a sell pays in token/`currency1`. Any test that measures a fee *rate* should do it on
  the sell side, because the harvest's LP share arrives as a `donate` of `currency0` only and is
  indistinguishable from quote-side swap fees. Collect once before a measured swap to zero the accrual.
- **A zero-accrual `collectFees` emits nothing at all** — both early returns precede the `FeesCollected`
  emit. That absence is the observable form of "collection with zero accrual is a no-op".
- **Rounding dust is specified, not a bug.** Conservation requirements are written as "up to rounding dust
  retained by the hook". Dust accrues to the protocol side, never against a user, and there is no sweep
  function in v1. Assert `assertGe`/approximate equality where the specs say dust, not exact equality.
- **A harvest's token-side residue is not a leak.** It goes to `carriedInventory` for the next band, so
  assert against that rather than expecting the hook's token balance to fall to zero.
- **A price-limited buy stops one level *above* its limit.** v4 leaves a `zeroForOne` swap that crosses an
  initialised tick at `tickNext - 1`, so `_buyToLevel(budget, L)` ends at `L` or `L + 1` depending on
  whether the target's tick was initialised. Assert `assertGe(_level(), L)`, never `assertEq`.
  `test/Fixtures.sol:_graduate()` says the same thing about the far level.
- **`using StateLibrary for IPoolManager` in `test/Fixtures.sol` is file-scoped** and does not reach an
  inheriting suite (the fixture notes this at line 312). A suite that must read the manager directly —
  `getSlot0`, `getPositionLiquidity` at raw ticks — declares its own `using` directive; the fixture's own
  level-taking helpers cover everything else.
- **Solidity string literals must be pure ASCII.** An em dash in an `assert*` message is
  `Error (8936): Invalid character in string`, and with `via_ir` you wait minutes to find out. Keep the
  typography in comments.

## Other agent configs present

A user-level Codex config (`~/.codex/config.toml`) and Gemini CLI config (`~/.gemini/settings.json`)
exist on this machine. To bring over MCP servers, slash commands, subagents, skills, or instructions from
them, reply `/import` to see what's importable, then `/import --yes=<digest>` to apply the user-level
items. (If `/import` isn't available on this surface, run `claude import` from a terminal.)
