# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A Uniswap v4 hook launchpad for Base. Its differentiator is the **milestone ladder**: protocol-owned,
one-sided sell-limit bands at ascending market-cap levels, JIT-deployed as price approaches them and
harvested automatically when price crosses a band's top. Harvests fund isolated payout pots that are
later delivered through each launch's immutable registry-index plan. One deployed hook serves every
launch; per-launch state is keyed by `PoolId`.

Three documents are normative. Read the relevant parts before changing behaviour:

- **`DESIGN.md`** — the current product design, economics, custody model, and risk register.
- **`openspec/changes/add-payout-plugins/design.md`** — numbered implementation decisions for the
  replacement generation. It supersedes conflicting legacy launchpad guidance.
- **`openspec/changes/add-payout-plugins/specs/*/spec.md`** — requirements expressed as named
  `#### Scenario:` blocks. Those names are the contract with the test suite (see Testing).

`docs/` is the published-documentation space (GitBook-ready; `docs/SUMMARY.md` is the index):
`docs/user/` for protocol users, `docs/technical/` for integrators, with
`docs/technical/integration.md` as the frontend/data-layer handoff. Keep those pages in sync when
changing user-visible behavior.

**`openspec/changes/add-payout-plugins/tasks.md` is the current work ledger.** Mark a task `- [x]` only
when its behavior is implemented and every scenario it names has literal passing evidence. Do not infer
completion from an earlier generation's reports. Fork and public-testnet boxes stay open until their RPC,
address, and funded-credential prerequisites exist. The `openspec` CLI is on PATH and the `/opsx:*`
commands drive this workflow.

If a task and a spec disagree, **the spec wins**. Treat task drift as a ledger defect to correct, never as
permission to weaken a requirement.

## Commands

```bash
make build              # forge build
make test               # == test-unit: forge test --no-match-path '{test/fork/**,test/invariant/**}'
make test-fast          # same suite under FOUNDRY_PROFILE=fast: no via_ir, seconds not minutes.
                        # Semantics are identical (via_ir only affects deployed bytecode size);
                        # use it for iteration. Artifacts land in out-fast/cache-fast.
make test-invariant     # test/invariant/** — the handler-driven suite
make test-fork          # needs BASE_RPC_URL; runs FOUNDRY_PROFILE=fork
make deep               # 10k fuzz / 1k invariant runs
make fmt / fmt-check
make abis               # export curated ABIs to abi/ for the frontend/data-layer handoff
                        # (docs/technical/integration.md; satellites deliberately excluded)
make release-check      # the full gate: pins fmt-check build size size-gate-selftest
                        #   structural-gate-selftest scenario-tool-selftest lock-check layout-check
                        #   abis test-unit test-invariant
```

`make fmt` has been run over the whole tree, so `fmt-check` is clean and `release-check` is unblocked.
Keep it that way: run `make fmt` before committing rather than letting a formatting backlog rebuild.

Single test:

```bash
forge test --match-path test/unit/MilestoneHarvest.t.sol
forge test --match-test test_crossingTheBandTopCompletesAndAccountsForTheMilestone -vvv
forge test --match-contract MilestoneHarvestTest
```

Four custom gates matter as much as the tests, and CI runs all of them on every push:

- **`make size`** — EIP-170 gate over `src/` only. The hook has crossed the 24 KB limit twice during
  development; this is the leading structural risk in `design.md`, which is why the gate runs
  continuously rather than at release. `make size-gate-selftest` proves the gate isn't passing vacuously.
- **`make layout-check`** — asserts `MilestoneHook`, `MilestoneColdPaths`, and `MilestonePayoutPaths`
  match `MilestoneBase` slot-for-slot and that every state-changing satellite entry carries
  `onlyDelegated`. **Run this after touching state variables or adding a satellite entry point.**
- **`make lock-check`** — source-level assertion that no `modifyLiquidity` call site combines a negative
  `liquidityDelta` with `FULL_RANGE_SALT` or `WALL_SALT` anywhere in the three-implementation
  architecture, and that the only positive mints under either salt are the two graduation seeds.
- **`make pins`** — verifies `lib/v4-core @ 5f00c84` and `lib/v4-periphery @ 9628c36`.

`via_ir = true` is load-bearing (it is what fits the hook under EIP-170), so a cold build takes minutes.
For test iteration use `make test-fast` instead: the `fast` profile compiles without via_ir — semantics
identical, seconds per run — and its artifacts live in `out-fast`/`cache-fast` so they never mix with
the release build. The size and layout gates run under the DEFAULT profile, so never audit or deploy
`out-fast` artifacts.

## Architecture

### The hook and two satellites share one storage layout

`MilestoneBase` declares **all** shared mutable state, events, errors, settlement primitives, economics,
and liability counters. `MilestoneHook` owns callbacks, the hot swap path, ladder harvesting, and public
wrappers. `MilestoneColdPaths` owns launch, graduation, fee collection, and unlock dispatch.
`MilestonePayoutPaths` owns pot redemption, isolated plugin delivery, carry retry, and creator-path
claims. Both satellites execute by immutable `DELEGATECALL`, in the hook's storage and address, with the
original `msg.sender`.

Consequences you must respect:

- **Never declare mutable state in the hook or either satellite.** Add it to `MilestoneBase`; silent slot
  aliasing is otherwise possible.
- Every state-changing satellite entry needs `onlyDelegated`. Construct both satellites with the same
  PoolManager, RevenueNFT, LaunchSupport, template, and controller dependencies as the hook, then verify
  immutable parity before deployment.
- `coldPaths` and `payoutPaths` are immutable inputs to hook initcode. Replacing either requires a newly
  mined hook; there is no upgrade path.
- The swap path stays in the hook. Harvesting only retires a band, records gross attribution, snapshots
  economics, and funds claim-backed liabilities. Redemption and untrusted delivery are always cold.
- Global mutable protocol policy is limited to the versioned economic tuple, protocol recipient,
  registry suspension/append operations, timelock delay, and two-step administrator transfer through the
  typed `ProtocolController`.

`LaunchSupport` and `src/libraries/*` remain external/internal helpers for bytecode reasons. Moving logic
back inline can break `make size`.

### `level = -tick` is the protocol's only coordinate

Native ETH is `address(0)`, so it is always `currency0` and the launch token is always `currency1`. Pool
price is token-per-ETH: **token price up means tick down.** Every piece of ladder, curve, graduation and
harvest arithmetic runs in `level = -tick`, which rises with token price. `src/libraries/Orientation.sol`
is the *only* place the sign flips — at `slot0` reads and when building `modifyLiquidity` params.

A sign error here is not a revert. It is a band placed on the wrong side of spot, filled instantly at the
wrong price. Keep new arithmetic in level space and convert only at the pool boundary.

A single-sided sell band is therefore a range strictly *below* the current tick, holding only `currency1`.

### Immutable template, signed plan, global economics

Band geometry (including the decaying ladder schedule), curve shape, supply split, the 10/20/70
graduation split, literal 1% trading fee, and per-swap work caps live in `ProtocolTemplate` and are
immutable across the generation. Total supply is pinned to a protocol constant (1B), so a launch chooses
only creator, metadata, an immediate dev buy of at most 10%, an exact registry-index bitset, and
deadline. The bitset is signed and CREATE2-bound; at most eight active payout entries may be selected and
their immutable takes may total at most `WAD`. The creator is the mandatory arithmetic remainder.

The versioned global `EconomicConfig` separately controls prospective distribution: 10% default harvest
service fee, 75% default quote-fee creator share, and 100% default token-fee milestone-fund share, under
immutable 20%/90%/100% caps. Governance cannot change pool geometry, the trading fee, graduation split,
plugin terms, or a launched pool's plan.

### Lifecycle

`BONDING_CURVE` → `GRADUATED`, one pool, one hook, in-place morph — no second pool, no migration path.
Graduation happens either way round: **the next swap's `beforeSwap` auto-graduates** once the level has
reached `farLevel` (Decision 18), and permissionless `graduate()` races it for a caller who would rather
pay that gas deliberately. Both read the live tick at call time, so a pool that touched the far level and
fell back has not graduated.

Launch is **operator-signed config with permissionless relay** (Decision 19): the protocol's trusted
operator (an off-chain server key, stored on chain and rotatable through typed governance) signs an
EIP-712 digest over the whole config and any address may relay it, or the creator sends their own
transaction with an empty signature. The token address is CREATE2-derived from the config hash and the
declared creator, so it is knowable before launch. A dev buy rides **only** the creator's own
transaction; a relayed launch leaves that share as curve inventory.

Post-graduation, the pool admits **external liquidity**: any address may add, remove, or collect on its
own positions like any v4 LP. On the bonding curve the guard still rejects everyone but the hook, and
protocol positions (curve, bands, full-range) are unreachable by third parties on both phases because
v4 keys positions to their owner.

Launch runs: validate → deploy token → `initialize` → `unlock` → in `unlockCallback` (`GENESIS`) mint
**curve position 0 only**, settle the token side, execute the optional dev buy. Positions 1–31 deploy
just-in-time as the simulated swap path reaches them (Decisions 15 and 17). Genesis minting cannot live
in `afterInitialize` because `initialize` does not unlock the manager and `modifyLiquidity` is
`onlyWhenUnlocked` (Decision 5).

Graduation burns the curves, splits proceeds 10 protocol / 20 LP seed / 70 creator, and seeds the single
full-range position (bounded $5,100-$150B market-cap range, ETH-limited seed) plus the **wall**: a
single-sided token-only position over the 880,000 levels above graduation that absorbs every token the
seed does not consume. Both positions are **code-locked**: no removal path exists, which `make
lock-check` enforces structurally.

### Ladder: derived geometry, bitmap state

Bands are computed, never stored: band `i+1` starts
`max(2235, 6932 - 391*i)` levels above band `i` (`levelUpper = levelLower + 447`). The schedule opens
with a 2× market-cap step and decays to the floor spacing's constant 1.2504× step (2,235 levels, of
which the 447-level band is exactly a fifth). 22 core bands reach roughly 2,900× the graduation
valuation (~$58M at the reference $2,500/ETH); up to 30 fee-funded extensions continue at the floor.

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

`afterSwap` harvests every live band whose top the swap crossed, up to `maxHarvestsPerSwap`. Each
harvest retires the band, records gross quote attribution, applies one global economics snapshot, credits
the claim-backed protocol service-fee subset, and funds the source pool's claim-backed payout pot. It
performs no plugin call, buyback, donation, redemption, or ETH transfer. Remaining live bands settle on
a later swap.

### Custody and liability classes

A completed-band burn runs inside `afterSwap`, before the crossing swapper settles input. Its positive
quote delta therefore becomes a PoolManager ERC-6909 native claim rather than raw ETH. That claim backs
two explicit liabilities: the active harvest service fee's contribution to `_protocolClaimBacked` and
the net `_payoutPot[poolId]`. A non-empty flush zeros and redeems exactly the complete pot through
`REDEEM_PAYOUT_POT`; a global protocol claim separately redeems exactly `_protocolClaimBacked` through
`REDEEM_PROTOCOL_BACKING`. Carry-only flushes redeem nothing.

Plugin carry, creator-path entitlement, direct creator revenue, and the non-claim-backed portion of global
protocol revenue are backed by raw ETH. Aggregate counters move with their component ledgers.
`_assertSolvent` checks claim backing against pot plus protocol-claim liabilities and raw ETH against all
raw-backed liabilities; no claim path may treat another class's backing as free balance. Ladder inventory
and the permanently locked full-range principal are separate token/liquidity reserves.

### Payout plans, flush, and creator paths

The append-only `PayoutPluginRegistry` has stable indices 0–255. Registered address, take, stipend, role,
and code hash are immutable; suspension is reversible. New launches may select at most eight currently
active `PAYOUT` entries whose takes total at most `WAD`. Delivery rechecks suspension and runtime code
identity. An inactive or codehash-invalid entry is never called: its current share and complete carry are
permanently redirected to creator-path entitlement.

Anyone may call `flushTo(poolId, tipTo)` — the tip recipient is always explicit, so bundlers and relays
that accept no bare ETH direct the tip to the real beneficiary — or `flushBatch(pools, tipTo)` to flush
many pools under one shared redemption unlock and one combined tip transfer; the batch is all-or-nothing,
and singles are batches of one. A new pot pays a floor-1% tip to the directed recipient, then allocates the
post-tip amount to selected entries in ascending index order. Each plugin receives plain ETH at
`onPayout(PoolId,address)` under its immutable gas stipend; only the EVM call-success bit matters and all
returndata is ignored. Failure preserves the complete attempted value as carry without blocking later
entries. Empty pot plus empty carry is a no-op, and carry-only retry neither redeems nor tips. The creator
receives the exact post-tip remainder and arithmetic dust as ledger credit rather than an arbitrary-flush
push.

`claimCreatorPath(poolId)` is distinct from `claimCreator(poolId)`. It snapshots the RevenueNFT holder,
flushes first, retains the self-flush tip for the final payment, rechecks ownership after plugin
interactions, and attempts the complete creator-path entitlement. Recipient rejection restores the whole
amount and returns an explicit failure result. `claimCreator` remains the NFT-gated direct path for
raw-backed graduation and quote-fee revenue. `claimProtocol` pays the single global ledger only to the
independently configurable protocol recipient; administrator status grants no claim right.

### Static fees and token routing

Every `PoolKey` carries the literal 1% fee for its complete lifetime. There is no dynamic-fee flag,
fee-step state, callback override, or governance action for trading fees. Permissionless `collectFees`
uses a zero-delta `modifyLiquidity` only to realize the full-range position's accrual; it never changes
that position's liquidity.

One versioned global economics snapshot routes each collection. Quote fees accrue 75% by default to the
pool's direct creator ledger and the exact remainder to global protocol revenue, under the immutable 90%
creator-share cap. Token fees may fund still-available fee-funded extension capacity using the default
100% share under the immutable 100% cap; every token not admitted to that capacity burns immediately. At
zero remaining capacity, 100% burns. Collected fees never add liquidity, and there is no LP carry.

### Governance and other cross-cutting mechanisms

- **Typed governance:** `ProtocolController` queues only plugin registration/suspension, complete economic
  tuple replacement, protocol-recipient replacement, and delay replacement. Operation identity binds the
  action, complete parameters, controller, chain, and salt. Readiness is captured using the delay active
  at scheduling, including for delay changes. The initial delay is zero and administrator transfer is
  propose/accept; operationally the administrator is the intended multisig.
- **Transient locks:** pool-scoped concern locks reject concurrent lifecycle/claim settlement. One separate
  protocol-global payout-delivery guard covers untrusted plugin calls, blocks custody, lifecycle, claims,
  governance execution, and registry mutation across every pool, and makes nested PoolManager callbacks
  suppress protocol work rather than reverting a reference plugin's swap.
- **Position salts:** `FULL_RANGE_SALT`, top-bit band salts, and low-index curve salts are disjoint and
  recomputed rather than stored.
- **Unlock dispatch:** manager interactions fail closed through typed actions: `GENESIS`, `GRADUATE`,
  `COLLECT_FEES`, `REDEEM_PAYOUT_POT`, and `REDEEM_PROTOCOL_BACKING`.
- **Plugin gas:** the payout satellite uses the published 15,000 fixed-call overhead, 100,000 per remaining
  call, 100,000 finalization reserve, 500,000 stipend cap, and exact EIP-150 margin preflight. Insufficient
  outer gas reverts the whole flush; it is not recorded as plugin failure.

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
  deploys the manager, registry, controller, NFT, `LaunchSupport`, both satellites, and the hook; completes
  the required authority/bootstrap wiring; launches a default pool; and exposes launch/signature/level
  helpers. `test/HarnessFixtures.sol` defines `HarnessLaunchpadTest`, which uses the harness artifact at the
  permission-encoded hook address. `test/fork/ForkFixtures.sol` provides the corresponding Base singleton
  fixtures; fork suites inherit those rather than the local-manager fixture.
- The hook must live at an address encoding its permission flags:
  `address(uint160((uint160(0xBEEF) << 20) | 15040))`, placed with
  `deployCodeTo("MilestoneHook.sol:MilestoneHook", ctorArgs, HOOK_ADDR)`. Deploy and configure the registry,
  controller, `LaunchSupport`, lifecycle satellite, and payout satellite before mining final hook initcode;
  then bind the controller target, complete registry authority, and set the NFT minter. Fixture/bootstrap
  helpers own this ordering—do not reproduce a partial two-contract setup in individual suites.
- `TestRouter` (`test/Fixtures.sol:36`) stands in for a third-party integrator, driving the plainest
  `unlock`/`swap`/`settle` sequence an integrator would write. `swapToLimit` is what you want for large
  buys — a plain `swap` runs the price to the extreme, because nothing provides liquidity above the far
  level until graduation. Negative `amountSpecified` is exact-input.
- `test/harness/MilestoneHookHarness.sol` exposes internals and adds test-only `UnlockAction`s
  **numbered from 200** so they cannot collide with production ones; `_dispatchUnlock` delegates anything
  below 200 to `super`.
- The fixture launches at `t = 0` and records `launchTime`. Compute every warp from that absolute origin;
  see the timestamp-optimization gotcha below.

### Gotchas that have cost real debugging time

- **`via_ir` common-subexpression-eliminates `block.timestamp`.** Two `vm.warp(block.timestamp + delta)`
  calls in the same test function collapse into one warp. Compute every warp from the fixture's absolute
  `launchTime` instead. See `test/Fixtures.sol:202`.
- **Which currency a fee lands in depends on swap direction.** A buy (`zeroForOne == true`) pays its fee
  in ETH/`currency0`; a sell pays in token/`currency1`. Collection routes those independently under one
  economics snapshot, so measure quote-ledger and token-fund/burn effects against the matching direction.
- **A zero-accrual `collectFees` emits nothing at all** — both early returns precede the `FeesCollected`
  emit. That absence is the observable form of "collection with zero accrual is a no-op".
- **Rounding destinations are explicit.** Quote-fee subtraction remainder is protocol revenue, payout-plan
  remainder and plugin-allocation dust belong to the creator path, and token-fee residue burns. Assert the
  exact integer formulas instead of applying one generic dust tolerance to every source.
- **A harvest's token-side residue is not a leak.** It goes to `carriedInventory` for the next band. Its
  quote side first becomes claim-backed service-fee and payout-pot liabilities; it is not raw ETH until an
  exact redemption action runs.
- **A price-limited buy may stop at its target level or one level above it.** When a `zeroForOne` swap
  crosses an initialized tick, v4 leaves spot at `tickNext - 1`, so `_buyToLevel(budget, L)` can end at
  level `L` or `L + 1`. Assert `assertGe(_level(), L)`, not exact equality.
- **A plugin revert is a successful flush outcome.** Its full attempted value becomes carry and later
  entries still run. Ordinary tip rejection and insufficient outer-gas preflight instead revert the whole
  flush atomically; creator self-claim rejection restores entitlement and returns `success == false`.
- **Carry-only retries do not redeem or tip.** Tests should distinguish a new-pot flush from retrying the
  existing bitmap and should prove one pot causes one exact redemption.
- **Codehash mismatch and suspension redirect, not carry.** Current share plus previous carry moves
  permanently to creator-path entitlement without calling the destination; reactivation is prospective.
- **Plugin-driven PoolManager callbacks are intentionally quiet.** While the global payout guard is held,
  callback work suppression—not a callback revert—keeps a reference buyback from recursively graduating,
  deploying, or harvesting.
- **`using StateLibrary for IPoolManager` in `test/Fixtures.sol` is file-scoped** and does not reach an
  inheriting suite (the fixture notes this at line 377). A suite that must read the manager directly —
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
