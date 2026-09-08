# Verification findings — groups 16 and 17

Scope: task groups 16 (nested Doppler curve) and 17 (band ladder) of
`openspec/changes/add-milestone-launchpad/tasks.md`. In both groups the source was already written; the
work was verification, so most findings below are about what the tests could and could not assert, and
about two places where the code and the specs disagreed.

Status at time of writing: 16.1–16.3 complete and marked. Group 17's source carries one fix made here;
its verifying suites are **not yet written**, so 17.1–17.5 remain unmarked.

---

## 1. The straddle deadlock was reachable and bricked every buy

**Severity: high. Fixed in this session.** `src/MilestoneHook.sol`, `_deployBandsAhead`.

The `milestone-ladder` spec already forbids this, at *"An undeployed band straddling spot deploys before
the crossing buy fills it"*: **"the straddle deadlock — a band that can neither deploy nor skip — cannot
occur."** It could occur.

**Root cause.** Mintability was decided against the walk's *simulated* level, but `_deployBand` mints at
the *real* pre-swap price, which does not move during `beforeSwap`. Single-sided token liquidity requires
`currentTick >= tickUpper`, i.e. spot at or below the band's `levelLower`. The guard only skipped bands
*entirely* behind spot (`upper <= level`), so a band straddling spot (`lower < level < upper`) fell
through to `_deployBand`, asked v4 for a two-sided mint, left the `currency0` debit unsettled, and
reverted the unlock with `CurrencyNotSettled` — inside `beforeSwap`.

**Reachability**, confirmed by a scratch probe against the local `PoolManager`, entirely through
permissionless entry points:

1. A buy large enough to hit `maxDeploysPerSwap` (8) leaves band N undeployed with `nextBandIndex == N`,
   and carries spot above band N's top. `_buy(5_000 ether)` does it: 8 deployed, 8 completed, spot at
   level −43343, band 8 unminted with `nextBandIndex == 8`.
2. *Any* sell walks spot back down into band N's interior. A sell deploys nothing and harvests nothing,
   so nothing repairs the state on the way down.
3. The next buy reverts. Every buy reverts while spot sits in that 447-level window.

That is a cheap, griefable denial of service on a graduated pool: buys stay bricked until someone sells
the price back below the band's lower bound. The window is 447 of every 2235 levels — 20% of the ladder's
price range.

**Fix.** Decide mintability against spot rather than the walk, and make the escape a skip:

```solidity
if (isNew && lower < level) { _skipBand(...); next = index + 1; index += 1; continue; }
if (isLive && upper <= level) { index += 1; continue; }
```

The new-band branch is a superset of the old condition, so *"Bands below spot never deploy"* still holds;
the live-band branch preserves the old no-op for a live band the price has risen out of. `break` was the
other candidate and is wrong: it would avoid the revert but strand the ladder at that index permanently,
since `nextBandIndex` never advances and the condition stays true forever. Skip-and-carry is also what
the spec's own *"Skipped inventory re-targets the next band"* and *"Ladder continues after a skip"*
already require.

**Verification.** The reproducing probe now passes — band 8 skips, `nextBandIndex` advances to 9, its
inventory carries, the buy succeeds — and all 79 pre-existing unit tests still pass.

**Structural note.** The curve half is safe by construction, and the asymmetry is worth recording because
it explains why only the band path could desynchronise: `_deployCurveAhead` derives its starting index
from spot on every call (`CurveLib.firstPositionAbove`), so it cannot carry a stale cursor, while
`_deployBandsAhead` reads `nextBandIndex` from storage, which is exactly the state that can fall behind
spot. A regression test belongs under the existing straddle scenario name; no spec amendment is needed,
because the spec already prohibits the behaviour.

---

## 2. Decision 17 makes graduation-with-unbought-curve-inventory unreachable

**Recorded as an in-place revision note on Decision 17** (design.md), and it changes what task 16.3's
tests can assert.

Every curve position terminates at `farLevel`, and graduation triggers at `farLevel`. So a pool that
graduates has by construction crossed all 32 start levels — deploying each — and sits at every position's
own lower bound, holding no token principal in any of them. A pool *cannot* graduate holding unbought
curve inventory.

`_burnCurves` still computes undeployed positions' nominal inventory and credits it to
`carriedInventory`. That branch is the safety net for Decision 15's "a simulation mismatch can only
under-deploy" case and cannot be provoked through any external entry point. Verified rather than assumed:
`_beforeSwap` graduates *before* dispatching to `_deployCurveAhead`; `_genesis` calls `_deployCurveAhead`
explicitly because the dev buy is a hook self-swap with callbacks skipped; a sell never deploys; and no
transient-lock path opens a gap during the bonding phase.

Consequence for the `graduation` spec's *"Token inventory and curve token fees become ladder inventory"*:
on any reachable graduation the token reaching the ladder is *entirely* curve token fees, and a pool
graduated by buys alone correctly carries zero. The tests assert that identity rather than a bound — two
drafts written against the opposite premise failed as `32 >= 32` and `0 <= 0` before the premise was
corrected.

---

## 3. The default buyback share may put the second fee step out of reach

**Unresolved. Design-level, not a code defect.** Measured, not inferred.

Each harvest's buyback is a market buy that pushes price further up, past subsequent band tops, so those
bands are below spot when the next buy arrives and are *skipped* rather than deployed. Skips consume band
indices without producing completions, and the fee schedule's thresholds (8 and 16) are counted in
**completions**.

Measured on the local `PoolManager`, one band targeted per swap to keep each buyback as small as the
mechanism allows:

| Harvest split | Completions reached | Indices consumed | Base fee |
|---|---|---|---|
| Default (20% buyback) | 7, then stalls | 8 | 10000 (no step) |
| Buyback at its 10% floor | 16 at round 17 | 24 | 2500 (both steps) |

Batched harvests are worse: 4 harvests in one swap overshot 4226 levels against a 1788-level gap and
skipped a band outright; 8 harvests overshot roughly 7700 levels, skipping four.

So at the default 20% buyback the ladder consumes indices faster than it accrues completions, and the 30
core bands can plausibly be exhausted before 16 completions. At the 10% floor both steps fire comfortably.

**What is not proven:** that 16 is *unreachable* at the default split. The run that would have shown it
failed on test-harness funds (the router's 100k ETH), not on a protocol limit, because the default
config's larger buybacks run price up faster each round. This needs a fork-scale or invariant-scale check
before anyone concludes either way — flagging it rather than settling it. If it holds, the options are a
lower default buyback, thresholds counted in indices consumed rather than completions, or thresholds
scaled to a measured completion rate. The `swap-fees` requirement's parenthetical, "scaled to the band
count (completions 8 and 16 of the 30-band template)", is the assumption under question.

---

## 4. At most one band is live in persistent state under the default template

Relevant to the *"Multiple bands may be live simultaneously"* scenario, whose wording invites an
assertion that cannot be made on post-transaction state.

Band `i+1` sits above band `i`'s top, so reaching it requires crossing band `i`'s top, which harvests
band `i`. Live bands therefore accumulate only when the harvest cap leaves some behind, and hitting that
cap requires more than 8 bands completing in a single `afterSwap`. With `maxDeploysPerSwap` and
`maxHarvestsPerSwap` both 8, entering a swap with `k` live-and-pending bands and deploying `d ≤ 8` gives
`k + d` live, of which `min(k+d, 8)` are harvested — so the leftover is capped at 1, and `k = 2` requires
a prior swap that already left 2. Circular; unreachable.

Multiple bands *are* genuinely live simultaneously **within** a transaction. Confirmed construction: swap
A ends inside band 0 (band 0 live, incomplete); swap B deploys bands 1–8, hits the deploy cap, and
crosses tops 0–8. At the moment B's `afterSwap` begins, `deployedBands & ~completedBands` holds nine bits.
The cap harvests 0–7 and leaves band 8 live with its top already crossed; a following dust buy completes
it, taking completions to 9.

That construction is the honest test for both this scenario and *"Harvests beyond the per-swap cap settle
on the next swap"*. The per-index assertion the scenario actually calls for — "each live band's deployed
state is tracked independently by its index" — is testable on the nine-band mid-transaction set and on
the leftover.

---

## 5. Empirical geometry, for whoever writes the group 17 suites

Default template, default config, local `PoolManager`. These cost real time to derive; they are recorded
so the next suite does not re-derive them.

- Graduation level −152025. Band `i`: `lower = -149790 + 2235i`, `upper = lower + 447`. Spacing 2235,
  width 447, gap between bands 1788.
- Full-range liquidity at graduation 42450742498179135239416; ladder inventory 650000000000000000000000000;
  per-band core share ≈ 2.17e25 tokens.
- Reaching band 0's midpoint from graduation costs ≈ 59 ETH. `_buy(5_000 ether)` unlimited deploys 8,
  completes 8, and ends at level −43343 — far past the ladder, which is what makes it the capped-out
  fixture.
- `_graduate()` leaves spot exactly at the graduation level with zero bands deployed, so
  *"No bands exist immediately after graduation"* is directly assertable there. The dust buy inside
  `_graduate()` is nowhere near band 0's 59-ETH threshold.
- `_buyToLevel(x, limit)` stops at the limit, but the **post-swap** level is higher than the limit
  whenever a harvest fires, because the buyback runs after. Any test asserting a final level must either
  target a level no harvest will overshoot, or assert on the pre-harvest level.
- Reaching 16 completions needs the 10% buyback floor and ≈ 4621 ETH over 18 targeted buys (see §3).

---

## 6. Verification-practice notes carried forward from group 16

- **Genesis active liquidity is not directly measurable.** At genesis spot sits exactly on curve position
  0's boundary, where v4 counts nothing as in range. Measuring position 0's liquidity requires a small
  buy first — 0.005 ETH, chosen to stay below position 1's start ≈ 216 levels up.
- **Rounding dust is specified, and its direction is the assertion.** 32 curve burns each round against
  the hook by up to a wei; a 37-wei shortfall failed an equality. The right assertion is `assertLe` for
  direction (dust stays with the hook, never charged to a claimant) *plus* `assertApproxEqAbs(..., 200)`
  for magnitude.
- **A sharp fee measurement exists at graduation.** After the crossing buy and before the graduating
  swap, the manager's ETH balance *is* the curve's quote proceeds — auto-graduation runs in that next
  swap's `beforeSwap`, before it settles a wei. That turns a weak `assertGt` into an exact split check.
- **Sizing buys from first principles beats trial and error.** A `PriceLimitAlreadyExceeded` failure came
  from ten unlimited buys exhausting the curve and pinning price at `MIN_SQRT_PRICE+1`. The whole curve
  sweeps for only ≈ 15–20 ETH (≈ 0.000167 ETH per level near the opening), which is what the fixture
  amounts should respect.
- `sqrtPriceX96 = sqrt(P) · 2^96`. Dropping the `2^96` produced a nine-orders-of-magnitude error while
  sizing buys; caught in reasoning, never committed.
- `_poolLiquidity(PoolId)` was added to `test/Fixtures.sol` for in-range liquidity at spot.

---

## Open items

1. **§3 is unresolved** and is the one finding that may need a design amendment. It needs a check that
   does not run out of harness funds.
2. **Group 17's suites are unwritten.** The fix in §1 needs its regression test under the existing
   straddle scenario name; §4 and §5 are the constructions the rest of the scenarios need.
3. `make layout-check` was not re-run after the §1 fix. It touched no state variables and added no
   satellite entry point, so it should be unaffected — but it is cheap and the project requires it after
   changes to either.
