## Context

`DESIGN.md` at the repo root is the normative product design; see it for mechanism rationale and see `proposal.md` for motivation. This document records the implementation-level decisions that `DESIGN.md` deliberately leaves open — it marks its four-contract sketch as "an example, not a prescription" — plus several corrections where the Uniswap v4 execution model constrains what the product design assumed.

Constraints that shape everything below:

- **Repository is empty.** No `foundry.toml`, no `lib/`, no Solidity. Everything is greenfield.
- **v4 pins**: `v4-core @ 5f00c84`, `v4-periphery @ 9628c36`. Solidity `0.8.26`, `evm_version = cancun` — transient storage is load-bearing, not an optimisation.
- **`modifyLiquidity` requires an unlocked `PoolManager`; `initialize` does not unlock.** This single fact reshapes the launch flow (Decision 5).
- **Native ETH is `currency0` unconditionally**, because `address(0)` sorts below every token. The launch token is therefore always `currency1`, which fixes pool orientation but inverts the relationship between token price and tick (Decision 3).
- **Reference implementations** live at `~/Desktop/launchpad` (Doppler, flaunch, sa1t, Zora, LaunchFi, Clanker/Liquid). Read-only reference per `DESIGN.md §11`, not a dependency — patterns are ported deliberately, not imported.

## Goals / Non-Goals

**Goals:**

- One protocol core that owns the whole pool lifecycle, with the smallest external entry-point surface that the obligations allow.
- Ladder arithmetic that cannot silently invert sign, given that "token price up" means "tick down" in this pool orientation.
- Every value-moving path — graduation, harvest, fee collection, claims — guarded against reentrancy from nested pool interactions, and conserving value up to explicit rounding dust.
- A test architecture that can actually falsify the ladder: unit tests per mechanism, Base fork tests over the full lifecycle, and invariant suites on supply and routing conservation.

**Non-Goals:**

- Upgradeability, proxies, or admin pause. v1 is immutable; the only mutable protocol state is the protocol fee recipient.
- Gas micro-optimisation ahead of correctness. Bounded, predictable gas is a goal; minimal gas is not.
- Multi-chain portability. Cancun-only, Base-first.
- Any v2 item from `DESIGN.md §12`. Routing enum slots are reserved and unreachable; nothing else is stubbed.

## Decisions

### 1. Singleton hook that is also the launch entry point

**Decision:** One deployed hook contract serves every launch, holding per-pool state keyed by `PoolId`, and exposing the launch function itself. Per launch we deploy only the ERC20. A separate ERC721 handles revenue claims. Heavy arithmetic lives in internal libraries (`LaunchConfigLib`, `CurveLib`, `LadderLib`, `FeeLib`).

**Why:** Hook permission flags are identical for every launch, so the address only needs mining once — at protocol deployment, off-chain, with the salt passed to a CREATE2 deployer. A per-launch hook would need per-launch mining, which is impractical on-chain and adds a deployment step plus significant gas to every launch for no isolation the `PoolId` keying doesn't already give. Merging the factory into the hook removes an external entry point and a cross-contract trust edge; `DESIGN.md §3` explicitly invites this ("fewer external entry points, custody kept in the hook").

**Alternatives considered:** Per-launch hook cloned from an implementation (sa1t/Clanker shape) — isolation by construction, but mining per launch and 45 bands of state per clone is worse on both gas and audit surface. Separate factory calling into the hook (flaunch shape) — keeps contracts small, but adds a privileged caller the hook must trust; deferred to the contingency in Risks.

**Consequence:** Cross-pool state isolation becomes a correctness obligation rather than a structural guarantee. Every storage access is `poolId`-scoped, and the invariant suite asserts isolation directly (see the `revenue-claims` spec's isolation scenarios).

**Revision (task group 8).** The singleton exceeded EIP-170 during the milestone-ladder work — 25,461 bytes against the 24,576 limit, with the ladder harvest, fee waterfall, and reclaim path still unwritten. `via_ir` and a size-tuned `optimizer_runs` were already in place and between them bought only 162 bytes, so the overflow was structural, not a squeeze. The contingency in Risks was taken, but in a form that keeps this decision's central property. Rather than a *separate factory* — the flaunch shape, which adds a privileged caller the hook must trust — the launch and graduation logic moved into `MilestoneColdPaths`, a satellite reached by `DELEGATECALL`. Under delegatecall `address(this)` is still the hook, `msg.sender` is still the original caller, and positions are still hook-owned, so no trust edge is introduced: the satellite has no authority the hook does not exercise on its own behalf. The single-deployment, single-mined-address model is unchanged; a second address is deployed but never mined and never privileged. What the split does add is a storage-layout coupling — the two contracts must agree slot-for-slot — which is contained by declaring all shared state once in `MilestoneBase` and enforcing the match in CI (`make layout-check`), and a guard obligation on the satellite's entry points (`onlyDelegated`, checked by `make layout-check` too) so a direct call cannot reach its own storage. The hook's swap path, ladder, settlement and claims stay in the hook, because the ladder runs inside `beforeSwap` and an extra `DELEGATECALL` per swap is a cost every trader would pay.

### 2. Custody by direct hook balance

**Decision:** The hook holds real ERC20 and native ETH balances. No ERC-6909 claim tokens.

**Why:** The ladder needs real positions and the harvest needs real settlement; a claims primitive would be an extra accounting layer over balances we already must hold. Matches flaunch's approach and `DESIGN.md §2`.

**Consequence:** The hook needs `receive()` for native ETH and must use `settle`/`take` correctly on every path. Value conservation is asserted by invariant rather than enforced by a token standard.

### 3. Normalised level coordinate for all ladder math

**Decision:** Because the token is always `currency1`, pool price is *token per ETH* and rising token price means **falling** tick. Rather than sprinkle negations, all ladder and graduation arithmetic runs in a normalised coordinate `level = -tick`, which increases monotonically with token price. Conversion happens only at the pool boundary — reading `slot0`, and constructing `modifyLiquidity` params. A single-sided sell band is therefore a range strictly *below* the current tick, holding only `currency1`, which converts to `currency0` as the tick falls through it.

**Why:** `DESIGN.md §5` acknowledges this as "negate for token1 orientation" and leaves it there. Sign errors in tick math are the single most likely source of a silent, funds-losing bug in this protocol: a band placed on the wrong side of spot is not a revert, it is an immediately-filled position that hands inventory away at the wrong price. Confining the sign flip to two boundary helpers makes it reviewable in one place, and lets every band/curve/graduation comparison read in economic direction ("level rising toward the band").

**Alternatives considered:** Raw ticks throughout with economic naming (`bandPriceLow → tickUpper`) — no conversion layer, but every comparison operator becomes a review hazard forever. Mining the token address above WETH to force token-as-`currency1`-with-normal-orientation — impossible with native ETH, and switching to WETH costs wrapping gas on every settlement and loses v4's native-currency path.

### 4. Single active band invariant

**Decision:** At most one band position exists at any moment: the lowest level that is neither complete nor skipped. Bands are minted one at a time on approach and never pre-deployed.

**Why:** It follows from JIT deployment as `DESIGN.md §6.2` describes it (mint fires when the *pre-swap* tick enters the deploy window), and it is worth naming because it bounds worst-case settlement to one harvest per swap. Without it, a swap sweeping many levels would need an unbounded settlement loop, which is a block-gas-limit hazard and a griefing surface. With it, a sweeping swap harvests exactly one band and skips the rest benignly — inventory carries forward, no loop.

**Consequence:** Band state is a cursor plus one live-band record, not an array of live positions. Levels are computed on demand from launch config and the graduation tick; only the cursor, skip/complete bitmap, carried inventory, and the live band's `deployedAt` need storage.

**Revision (planning review, ahead of task groups 15–17).** The single-live-band invariant is superseded by simulation-driven deployment (Decision 15). Because deployment now anticipates the incoming swap's entire price path instead of reacting to a deploy window, a sweeping buy can legitimately cross several deployed bands, and the one-live-band bound would reintroduce exactly the skipping the simulation exists to eliminate. Band state becomes two `uint256` bitmaps (deployed, completed) plus a per-index `deployedAt` timestamp; the single `LiveBand` record is deleted. What Decision 4 protected — bounded settlement — survives as an explicit cap: at most `MAX_HARVESTS_PER_SWAP` (8) bands are harvested per swap, and a sweep crossing more completed bands than the cap leaves the remainder live for the next swap. Deploy order remains strictly ascending, so a level never redeploys after being passed.

### 5. Curve minting and dev buy happen under an explicit unlock, not inside `afterInitialize`

**Decision:** The launch function performs: deploy token → `poolManager.initialize` → `poolManager.unlock` → in `unlockCallback`, mint the curve fan, settle the token side, then execute the optional dev buy. `beforeInitialize` reverts unless the initiator is the hook's own launch path; `afterInitialize` only records per-pool state.

**Why:** `DESIGN.md §4` places curve minting and the dev buy in `afterInitialize`, but `initialize` does not unlock the `PoolManager` and `modifyLiquidity` is `onlyWhenUnlocked`. Minting from inside `afterInitialize` would require the hook to call `unlock` re-entrantly from within a manager callback. Doing the work under an explicit unlock in the same transaction preserves every externally observable property the specs require — atomic launch, curves live before any third party can trade, dev buy at the initial price — without fighting the lock model.

**Alternatives considered:** `unlock` from inside `afterInitialize` — works only because `initialize` holds no lock, but relies on a subtle non-guarantee of core internals and would break if core ever locks initialization. Two-transaction launch (initialize, then seed) — leaves a window where the pool exists with no liquidity and a manipulable price; rejected outright.

**Revision (planning review).** The genesis now mints only curve position 0; positions 1–31 deploy just-in-time ahead of the price per Decision 15. The explicit unlock still wraps genesis — position-0 minting, token-side settlement, and the dev buy — for the same reason as before: `initialize` does not unlock the manager, and the pool must be tradable inside the launch transaction.

### 6. Buyback executes directly inside `afterSwap`

**Decision:** The harvest's buyback share calls `poolManager.swap` directly from `afterSwap`, settles its deltas, and burns the received token — all under a transient-storage lock.

**Why:** `afterSwap` is reached from `swap`, so the manager is already unlocked; a nested `unlock` would revert, since v4 permits only one at a time. Exact-input, so the share is spent rather than a token amount targeted, and the burn reduces total supply by whatever it bought.

**Revised during task group 9 — why the lock is a defence rather than the mechanism.** This decision originally justified the lock by saying the nested swap re-enters the hook's own `beforeSwap`/`afterSwap`, so the lock had to suppress deployment and double-harvest. That is not what v4 does. `Hooks.beforeSwap` and `Hooks.afterSwap` both open with `if (msg.sender == address(self)) return`, so v4 skips *both* swap callbacks when the hook is itself the swapper: the buyback cannot re-enter the ladder or the harvest in the first place. The lock stays, and the ladder and harvest paths still check it, for two reasons. It keeps the guarantee ours rather than borrowed from a v4 implementation detail that our pinned version happens to have; and it still does real work on the paths that are *not* self-calls — fee collection and claims, which nest without the hook being the swapper. The ordering inside the harvest is the second, independent defence: the band is retired from storage and the cursor advanced *before* anything is routed, so even a re-entrant harvest would find no live band to settle.

**Alternatives considered:** Queue the buyback for a later permissionless call — loses atomicity, creates a MEV-extractable pending order, and leaves the routed proceeds in limbo across blocks.

### 7. Transient storage for all settlement locks

**Decision:** `tstore`/`tload` with namespaced slot keys (flaunch's `StoreKeys` pattern) guard band deployment, harvest settlement, fee collection, and claims. Guards are transaction-scoped and need no cleanup.

**Why:** These paths nest by design (harvest → buyback swap → hook callbacks). Persistent-storage reentrancy guards would cost a cold write plus a reset on every swap; transient storage costs are negligible and the "guard cannot leak across transactions" scenario in the ladder spec is satisfied by the EVM rather than by our cleanup code being correct.

### 8. Dynamic fee: computed in `beforeSwap`, base fee pushed at harvest

**Decision:** The anti-snipe decay is evaluated per swap and applied as a `beforeSwap` fee override. The milestone step-down mutates the stored *base* fee via `updateDynamicLPFee` at the harvest that crosses a threshold. The override wins while the anti-snipe window is open; once elapsed, the override yields to the stored base fee.

**Why:** This is exactly the precedence the `swap-fees` spec requires, and it puts each mechanism where its trigger naturally lives — the decay is a function of elapsed blocks (per-swap), the step is a function of completions (per-harvest). Block-stepped decay keeps the fee constant within a block, so it cannot be gamed by intra-block ordering.

**Alternatives considered:** Recomputing the whole schedule in `beforeSwap` including milestone steps — one code path, but re-reads completion state on every swap for a value that changes at most twice in a pool's life.

**Revision (planning review).** The anti-snipe decay and its `beforeSwap` override are removed entirely (Decision 20); this decision reduces to its second half: the stored base fee is stepped down by `updateDynamicLPFee` at harvests, with thresholds now scaled to the band count (completions 8 and 16 of the 30-band template) rather than fixed at 2 and 4. `DYNAMIC_FEE_FLAG` is retained solely for the step-down. There is no override and no precedence rule anymore.

### 9. Fee collection by sliver burn and re-add

**Decision:** v4 exposes no standalone collect, so the permissionless collection path burns a minimal sliver of the full-range position's liquidity — which forces fee accounting to settle — then re-adds it, so net liquidity is unreduced. Collected fees are then split 60/30/10, with the token-denominated portion first subject to milestone-fund diversion.

**Why:** It is the established v4 workaround and the only one that does not require an external position manager holding the position. The `graduation` spec's "fee collection preserves net liquidity" and the `swap-fees` spec's "repeated collection is harmless" scenarios are the acceptance criteria; both are testable directly.

**Consequence:** Rounding on burn/re-add can leave dust. The design accepts hook-retained dust explicitly — every conservation requirement in the specs is written as "up to rounding dust retained by the hook" — and the invariant suite asserts dust is non-negative from the protocol's side, never negative.

**Revision (task group 10).** The sliver is unnecessary: a **zero-delta** `modifyLiquidity` is v4's collect. `Position.update` computes fees owed from the position's *existing* liquidity and skips the principal branch entirely when the delta is zero, so the call realises every wei the position has earned while leaving its liquidity, its bounds and the tick bitmap untouched. That is strictly better than burning and re-adding, on all three counts this decision cared about:

- "Net liquidity is unreduced" stops being an outcome to verify after the fact and becomes a property of the call — there is no sliver to put back, so no ordering in which the position is briefly smaller and no rounding on the round trip.
- The dust this decision anticipated on burn/re-add does not arise. Dust still exists elsewhere (fee growth is tracked per unit of liquidity, so converting back to an amount floors), and the specs' "up to rounding dust" wording still holds; it is simply not this path that creates it.
- Cost is lower and, more importantly, bounded without argument: a zero-accrual call is two storage reads and a `feeGrowthInside` comparison, both of which precede the `unlock`, so "repeated collection is harmless" is a cheap early return rather than a claim about how small a sliver can be. Measured at roughly 15k gas against roughly 200k for a call that does work.

Everything after collection is unchanged: 60/30/10 over each currency, with the token side first subject to milestone-fund diversion. v4 routes a zero delta to `beforeRemoveLiquidity`, where the hook's guard admits `address(this)`, so no permission changes either.

### 10. Minimal protocol authority

**Decision:** The only privileged action in v1 is setting the protocol fee recipient. Per-pool configuration is immutable after launch. There is no pause, no parameter override, no ability to touch pool liquidity, ladder inventory, or creator balances.

**Why:** `DESIGN.md §3` forbids widening the trust surface beyond what it describes, and it describes none. Every bound is validated once at launch and then fixed, which makes the launch validator the whole of the protocol's policy enforcement — one function to audit rather than a mutable configuration space.

### 11. Test architecture

**Decision:** Three layers.

- **Unit** — per mechanism, on a locally deployed `PoolManager` via v4's test deployers. Fast, exhaustive over branch conditions, especially the launch validator's bound edges and the fee schedule's precedence table.
- **Fork** — against real v4 on a Base fork, exercising the full lifecycle: relayed signed launch → dev buy → bonding curve fills (JIT-deployed steps) → graduate → simulated multi-band deploy → multi-harvest → route → collect fees → fee-funded extension. This is where orientation and settlement bugs surface, because a local harness can share our own sign mistakes.
- **Invariant / fuzz** — a handler driving random swap sequences, time jumps, fee collections, graduations, and claims across multiple concurrent pools, asserting: total supply accounted for across custody, deployed positions, and burns; routed amounts sum to harvested amounts within dust; the four harvest shares sum to one whole; no code path reduces full-range liquidity; per-pool and per-party claim isolation. *(Revised in planning review: bitmap state replaces the single live band, and the reclaim driver is removed with Decision 22.)*

**Why:** The ladder's failure modes are sequential and stateful — a jumped band followed by a fee-funded extension is not something a unit test enumerates. Invariants are the only layer that explores those orderings.

### 12. Harvest LP share reaches the full-range position by `donate`

*Added during task group 9; the mechanism was undecided when the harvest routing was specified.*

**Decision:** The harvest's LP share is delivered with `poolManager.donate(key, amount, 0, "")` and paid from the hook's quote claim in the same call (see Decision 13). It is credited as quote-side fee growth on the pool's in-range liquidity, not added as position principal. The share is also computed as the *remainder* of the harvest rather than from its own wad, so integer-division dust and any part of the buyback share its swap could not spend compound with it instead of being stranded.

**Why:** Harvest proceeds are quote-only by construction — a completed band has sold its entire token inventory — while the full-range position straddles spot and so requires both currencies for a principal add. Every way of sourcing the token side is ruled out by something already decided. Swapping for it is forbidden by the `milestone-ladder` scenario "A zero buyback share performs no swap", which requires that routing anything other than the buyback perform no swap at all. Pairing it against ladder token inventory would spend inventory earmarked for future bands, breaking the ladder's custody accounting. Deferring it to a later collect-and-add call would break the atomicity that Decision 6 exists to preserve. `donate` needs no counterparty currency, is atomic, and creates no claimable balance to be swept later.

The donation lands entirely on the intended position: at the moment it is called the curves have been burned at graduation, the only band that could have been live was retired earlier in this same call, and a retired band sits below spot regardless — so the full-range position is the pool's only in-range liquidity. The value is then folded into that position's liquidity by the fee-collection path (Decision 9), which is the one place the protocol holds both currencies at once.

**Consequence — the LP share is re-split by the fee waterfall.** Donated quote is indistinguishable from swap fees in `feeGrowthGlobal0X128`, so when the Decision 9 collection path next runs, the donated amount is split 60/30/10 along with genuine fees rather than staying wholly with the LP. At the default 10% `lpWad` this shifts roughly 4% of a harvest's value from the LP share to the creator and protocol shares. This is accepted rather than corrected: it moves value between protocol-side recipients only, never away from the pool or a user, and correcting it would mean tracking a donated-principal balance separately through the collection path — new state and a second accounting rule, to reallocate low single-digit percentages between the same three parties. The `milestone-ladder` spec's requirement is that the LP share is "added to the full-range position", which is satisfied; the stronger "increases the full-range position's liquidity" wording belongs to the `swap-fees` fee-collection spec, where both currencies genuinely are available.

**Alternatives considered:** A zap-swap of the LP share into both currencies before adding principal — rejected by the zero-buyback scenario above. A deferred LP buffer collected on the next fee collection — rejected as it breaks harvest atomicity and creates a balance with no owner in the meantime.

### 13. Value harvested inside a swap is held as an ERC-6909 claim, not as real ETH

*Added during task group 9, in response to a test failure that turned out to be structural rather than incidental.*

**Decision:** Anything the protocol collects from the pool while a swap is in flight is converted to an ERC-6909 claim with `poolManager.mint(address(this), currency.toId(), amount)` rather than withdrawn with `take`. Debits raised in the same frame — the buyback's input, the LP donation — are paid by burning that claim rather than by settling real currency. Claims are redeemed for real ETH lazily, by `_ensureEth`, which opens its own `unlock` (`UnlockAction.REDEEM_QUOTE`) and redeems only the shortfall. The two pull-payment entry points, `claimCreator` and `claimProtocol`, call it before paying.

**Why:** `take` moves real currency, so it can only ever withdraw what the manager physically holds — and inside `afterSwap` the manager is short by exactly the amount of the swap that is executing. v4 collects a swapper's input *after* `swap` returns, from the swapper's own callback; a hook running mid-swap sees the pool's accounting updated but the currency not yet delivered.

For this protocol that is not an edge case but the normal path. A band completes precisely when a buy has consumed its entire token inventory, so the quote the band just earned *is* the in-flight swap's unsettled input. The larger the buy, the larger both numbers, and the shortfall never closes. `take` would revert on the buys that matter most — the ones that sweep a band in one transaction — which the `milestone-ladder` scenarios require to succeed. Confirmed empirically: the harvest tests that stepped up to a band top in small increments passed, because each step settled before the next; every test that crossed the top in one swap failed with `OutOfFunds` on a `take` of the exact harvest amount.

The one reading under which `take` would appear to work is worse than the failure. The manager is a singleton holding every pool's currency, so a `take` beyond our own pool's reserves could be satisfied out of *unrelated pools'* float. It would net to zero by the end of the unlock and `CurrencyNotSettled` would never fire, so nothing would flag it — but it makes our swaps succeed or revert depending on how much unrelated liquidity happens to be in the manager at that block. A launch's liveness must not depend on that.

Claims are v4's own answer to this, and the right one: minting one is pure accounting that moves nothing, so it is always available, and the claim is fully backed the instant the enclosing unlock completes and the swapper settles. Value stays in the singleton until someone actually needs it as ETH, which also makes the buyback and the donation cheaper — neither round-trips currency out of the manager and back in.

**Consequence — "hook custody" means two things, and claimants must not have to tell them apart.** Accrued balances are now backed by raw ETH when the value arrived from a graduation and by a claim when it arrived from a harvest, and a single accrued balance can be part of each. `_ensureEth` is what makes that invisible: it tops up from claims only when the raw balance is short, so one claim funds many partial claims and a redemption never happens when it is not needed. The claim ledger itself is unchanged — accrual is still bookkeeping only, and nothing is pushed to a creator or the protocol during settlement.

**Alternatives considered:** Deferring the harvest to the *next* swap's `beforeSwap`, by which time the previous swapper has settled — rejected because it breaks "crossing the band top completes the milestone": the band would sit retired-but-unrecorded, and `completedMilestones` would lag reality until an unrelated trader arrived. Charging the harvest to the trader through `afterSwap`'s return delta — rejected because it changes what the trader receives, which the same spec forbids. Taking real ETH when the manager's balance happens to allow it and minting a claim otherwise — rejected as strictly worse than either: it splits custody across two backings nondeterministically, so the same harvest behaves differently block to block, for no gain over always minting.

### 14. A reclaimed band's realised quote goes through the harvest split; its token goes to the carry

*Added during task group 11. The `milestone-ladder` reclaim requirement and `DESIGN.md §6.4` both specify what happens to a stale band's **inventory** and neither mentions the quote a partly-filled band has realised. This decision fills that gap rather than leaving it to the implementation.*

**Decision:** Reclaim burns the stale position and splits what comes back by currency. The **token** joins `carriedInventory` untouched, which is the specified behaviour — "inventory returns to hook custody, re-targeted at the next band in line", and reclaim "SHALL NOT burn, reprice, or redirect the inventory". The **quote** goes through the launch's configured `harvestSplit`, by the same `_routeHarvest` a completed band uses: creator and protocol credited, buyback bought and burned, LP share donated. What reclaim does *not* do is count a completion: `completedMilestones` is untouched and no fee step is applied. `BandReclaimed` is emitted rather than `MilestoneHarvested`, so the two cases are distinguishable in logs even though both are followed by `HarvestRouted`.

**Why the quote is routed at all:** leaving it in custody would strand it. There is no unrouted-proceeds ledger and no sweep function in v1, so quote sitting outside both claim ledgers and outside the pool would be permanently unreachable — worse than the rounding dust the specs deliberately tolerate, because it is unbounded rather than dust-sized.

**Why the harvest split specifically:** the `swap-fees` spec already sends band fees there — "those fees are collected with the band and folded into the harvest rather than routed through this waterfall" — and a reclaimed band's quote is overwhelmingly those same `currency0` fees. A band that fully retraced below its own range holds no quote *principal* at all, because a band is an ordinary concentrated position and a falling price converts its ETH back into token; principal survives a reclaim only when the price is parked inside the band's narrow range at that moment. So this is not a new destination for a new kind of value; it is the destination the specs already chose, reached by the other of the two paths that can end a band's life.

**Why no completion is counted:** completion gates exactly two things — the milestone count and the fee schedule — and a reclaimed band reached neither. Counting one would step the base fee down for a milestone the market never hit, and `swap-fees`' "step-downs do not reverse" would then lock in a reduction earned by abandonment.

**Consequence — the routing helpers stay in `MilestoneBase`.** *(Superseded detail: this consequence existed so reclaim, on the satellite side of the delegatecall boundary, could share the harvest's routing. With reclaim removed by Decision 22, the harvest is the only caller; the helpers' location remains unchanged, chosen for bytecode reasons alone.)* The harvest runs in the hook's `afterSwap`; `_routeHarvest`, `_buyBackAndBurn` and `_compoundLpShare` are declared in the shared parent. The hook's bytecode is unchanged — it is the same code, declared one level up — and the satellite grows, which is the direction the EIP-170 risk wants. The harvest holds the quote as a claim (Decision 13), so routing pays the buyback and the donation by burning that claim.

**Consequence — a reclaimed fee-funded band returns its extension slot.** `feeFundedBandsCreated` counts bands that *exist*. Reclaim does not advance the cursor, so a redeploy is the same ladder level; decrementing on reclaim keeps the count a tally of distinct levels reached rather than of mint events, and removes a griefing shape in which repeated reclaim-and-redeploy of one level could exhaust the 30-band cap without the ladder ever advancing.

**Consequence — a redeploy draws a fresh core share.** `_fundBand` draws `perBandInventory` from `ladderInventoryRemaining` whenever a core index deploys, so a reclaimed-and-redeployed index draws twice. This is bounded and accepted: `ladderInventoryRemaining` only ever falls, so the ladder's aggregate allocation is unchanged and no inventory is created; the per-band cap of `2x` stops the pair concentrating; and the effect is only to shift allocation slightly earlier in the ladder, leaving later bands correspondingly smaller.

**Revision (planning review).** Reclaim is removed entirely — see Decision 22. This decision's quote-routing machinery is deleted with it. Its underlying principle — no value sits unrouted in hook custody — carries into Decision 21's token-fee rerouting.

### 15. Deployment is simulation-driven (curve steps and bands)

*Added during planning review; replaces the deploy-window trigger and makes Decision 4's single live band obsolete.*

**Decision:** In `beforeSwap`, on buys only, the hook walks the incoming swap with v4's own swap math (`TickMath`/`SwapMath` over the pool's liquidity profile) and deploys every undeployed curve position (bonding phase) or band (graduated phase) that the walk crosses, before the swap executes. Band deployments are capped at `MAX_DEPLOYS_PER_SWAP` (8); curve deployments are bounded by the template's 32 positions. Skip-and-carry survives only as the cap's fallback. The deploy-window trigger and `_skipPassedBands` as a primary mechanism are deleted.

**Why:** The deploy window had a genuine hole: an undeployed band whose range straddles spot can neither deploy (the window is strictly below the band) nor be skipped (skipping requires the upper bound below spot) — it deadlocks until price falls back. And a sweep crossing undeployed space sells nothing there. The hook is uniquely able to simulate exactly: post-graduation the entire liquidity profile is protocol-owned and deterministic (one code-locked full-range position plus hook-minted positions), and `amountSpecified`, `zeroForOne`, and `sqrtPriceLimitX96` are inputs to `beforeSwap`. No manager internals are extsloaded; between walls there are no tick boundaries at all, so the walk is O(bands crossed). The swap then executes against the freshly deployed liquidity — and a deployed band cannot be jumped without filling it, which is completion by definition.

**Consequence:** A simulation or rounding mismatch can only *under*-deploy; the shortfall degrades to the specified skip-and-carry and never over-sells. Decision 4's boundedness becomes the harvest cap. Whales pay the deploy gas for the positions they consume.

**Alternatives considered:** Deploy-window trigger (status quo — carries the straddle deadlock and sweep skips); one-ahead deployment, minting band *i+1* during *i*'s harvest (cheap approximation, still skips deep sweeps); eager fan at graduation (pays genesis gas for smoothness nothing needs at t=0, and breaks fee-top-up timing); a fully virtual bonding curve with the pool born at graduation (the pump.fun shape — rejected: bonding trades leave v4 composability, and the real pool's price cannot move from init to the graduation level without a self-trade priming sequence).

### 16. A fixed protocol template with an anchored opening FDV

*Added during planning review.*

**Decision:** Every launch-shaped parameter moves into a `ProtocolTemplate` struct set once as a hook constructor argument — immutable, identical for every launch: curve shape (32 nested positions, 2× span), ladder geometry (2,235-level spacing = 1.25×, 30 core + 30 fee-funded bands, 447-level walls ≈ 4.5% of price), supply split 25/65/10 (curve/ladder/full-range), milestone-fund share 20% (per-band cap 2×), base fee 1%, fee schedule, and `OPENING_FDV_ETH` (125 ETH). The opening price is no longer a constant: the launch derives the start level from the supply so **every launch opens at the same FDV**. Per-launch configuration shrinks to token metadata/supply, the optional dev buy (≤10% of supply, vesting ≤12 months), and the harvest split within bounds (creator ≤70%, buyback ≥10%, protocol ≥5%).

**Why:** The launch validator was the whole trust surface (Decision 10) and had grown to guard configurations no buyer ever priced differently — geometry knobs whose degenerate values are pure foot-guns. One audited template is the Virtuals posture: uniform terms, comparable launches, publishable economics. Anchoring FDV closes a real hole: a fixed opening *price* let a 100B-supply token open at a $400M FDV. The anchor is denominated in ETH because there is no on-chain ETH/USD oracle and none is wanted (the pump.fun graduation bar is likewise SOL-denominated).

**Consequence:** `Curve[]` per-launch config, `_curves` storage, and the geometry validators are deleted — which also makes structurally impossible the 512-position graduation-gas DoS the old validator permitted (8 curves × 64 positions ≈ 45M gas to burn at graduation, beyond the block limit). Bytecode freed funds the simulation code. Splits are constants; changing any number means redeploying the protocol, consistent with v1 immutability.

**Alternatives considered:** Bounded per-launch configurability (status quo — over-exposed surface, every knob a foot-gun); a fully fixed template including the harvest split (drops the creator's economic choice, the stated differentiator); fixed opening *price* rather than fixed FDV (leaves opening valuation floating 100× across supplies).

### 17. The bonding curve is nested, attributed to Doppler, and JIT-minted

*Added during planning review; supersedes the contiguous equal-slice fan.*

**Decision:** The bonding curve is 32 nested single-sided token positions spanning `[startLevel + i·span/32, farLevel]`, each holding an equal share of curve supply — the Doppler Multicurve algorithm (Adams, Czernik, Kulkarni, Kunz, April 2025, eqs. 3.1–3.2), reimplemented inside `CurveLib` with this protocol's level-space orientation and salt families. The vendored implementation is BUSL-1.1 licensed: the algorithm is ported, the code is not. Only position 0 is minted at genesis; positions 1–31 deploy just before price reaches their start (Decision 15). A dev buy is capped at 10% of supply.

**Why:** Nested equal-token positions staircase liquidity upward, concentrating it near `farLevel` — cheap supply is scarcer at genesis (structural anti-sniping), average execution is higher, and the graduation sweep meets a deep wall. The paper proves the static single-position alternative front-loads the cheapest tokens to snipers. Against the flat contiguous fan, the nested shape is strictly stronger on the paper's own metrics at the same position count. JIT minting makes launch gas independent of position count (one mint at genesis) and lets a genesis dev buy pay deploy gas only for the positions it consumes. The 10% dev-buy cap: against a thin early book, larger dev buys sweep expensive bins and price the creator's own entry.

**Consequence:** Launch gas is ~1M (token + initialize + position 0); graduation burns at most 32 positions (~2M, bounded). The `CurveLib` docstring's "ports Doppler's multicurve" overclaim is corrected to algorithm attribution.

*Revision (task 16.3 verification): the nested shape makes "graduation with unbought curve inventory" unreachable, not merely rare.* Every position terminates at `farLevel` and graduation triggers at `farLevel`, so a pool that graduates has by construction crossed all 32 start levels — deploying each — and sits at every position's own lower bound, holding no token principal in any of them. `_burnCurves` still computes undeployed positions' nominal inventory and credits it to `carriedInventory`; that branch is the safety net for Decision 15's "a simulation mismatch can only under-deploy" case and cannot be provoked through any external entry point. The practical consequence is for the `graduation` spec's "Token inventory and curve token fees become ladder inventory": on any reachable graduation the token reaching the ladder is *entirely* curve token fees, and a pool graduated by buys alone correctly carries zero. Tests assert that identity rather than a bound.

**Alternatives considered:** The flat contiguous fan (uniform tokens per bucket — weaker on anti-snipe and average execution at identical cost); the eager fan (32 mints at genesis for smoothness nothing needs at t=0); a single position per curve (the paper's proven worst shape).

### 18. Graduation auto-triggers in the next swap's `beforeSwap`

*Added during planning review.*

**Decision:** When the first swap after the far level is crossed arrives, its `beforeSwap` graduates the pool — burn curves, split proceeds 40/55/5, seed the full-range position — before executing. The crossing swap itself cannot graduate: Decision 13's shortfall applies, since its curve proceeds are unsettled mid-swap and the LP seed needs settled ETH. Permissionless `graduate()` remains and races the auto-trigger; both verify the level at call time and both are idempotent against the phase check.

**Why:** The limbo above `farLevel` — price beyond the curve's end, no liquidity above, nobody having called `graduate()` — is closed atomically by the first trader who wants that market. Above `farLevel` nobody *can* trade until graduation runs, so the payer is self-selecting. The gas is bounded by the template (~32 burns, ~2M) and one-time.

**Consequence:** Graduation no longer depends on a keeper or an altruist. `beforeSwap` gains a phase transition, guarded by the settlement lock; the triggering swap executes against post-graduation liquidity. No bounty: a caller earns nothing, there is nothing to steer, and any dust swap self-heals the limbo.

**Alternatives considered:** `afterSwap` auto-graduation inside the crossing swap (blocked by Decision 13 — the LP seed needs settled ETH and a nested `unlock` is impossible); `graduate()` alone (the limbo persists until someone altruistically pays ~2M gas).

### 19. Launch by signed config with permissionless relay

*Added during planning review.*

**Decision:** The creator signs the `LaunchConfig` off-chain (EIP-712 over the config hash plus a deadline). Anyone may relay `launch(config, signature)`. The creator is the recovered signer, not `msg.sender` — the RevenueNFT, vesting, and dev-buy authorization all key off the recovered address. The token deploys via CREATE2 with a config-hash salt, so its address is knowable before launch and a replayed signature fails on the existing deployment. The dev buy executes only when the relayer is the creator; on a relayed launch the dev-buy share remains curve inventory.

**Why:** The pump.fun posture — creation costs the creator nothing, and deployment timing is whoever wants the market first. The signature covers the entire config, so a relayer cannot alter a single economic parameter. Anti-snipe removal (Decision 20) is what makes this model safe: the wall that used to re-arm at genesis is gone, so deployment timing is economically inert, and the structural protections (thin nested book, whale-paid deploy gas, creator dev buy) do the anti-snipe work.

**Consequence:** The launch entry gains signature verification; `token-launch` gains the relay/replay/deadline scenario suite. No on-chain relayer tip in v1 — front-ends relay published configs, exactly as pump.fun's interface pays its users' gas.

**Alternatives considered:** Creator-must-deploy (a ~1M-gas creator tx for cents on Base — workable but no zero-cost story); fee-exempt first buyer (a snipe lottery over every published config — rejected); on-chain registration with tips (new state and surface to save cents).

**Revision (planning review, salt binding).** The CREATE2 salt is `keccak256(configHash, recoveredSigner)` — not the config hash alone — and the signed deadline is excluded from it. Two properties motivate the binding. First, a config-hash-only salt would let anyone occupy the advertised address: a griefer signs the *published* configuration with their own key and relays first, deploying the token at the very address every token page displays, with the griefer as creator. Binding the recovered signer drops any such clone at a different address — an identical configuration signed by a different key is a separate token attributed to that signer, and the advertised address stays reserved for the creator. Second, excluding the deadline keeps the address stable across re-signing: a configuration whose signature lapsed can be re-signed with a fresh deadline and still lands at the address the token page has shown since creation. Replay protection is unchanged — same configuration, same signer, same salt, deployment collision — and the address remains derivable by anyone holding the published configuration and signature: recover the signer, hash the pair, apply the CREATE2 formula.

**Revision (v1 scope: wallet creators, custodial launch deferred).** v1 serves creators with wallets; custodial signing for web2 (no-wallet) creators is deferred, not designed out. When it arrives it lands as per-creator keys whose signatures are relayed like any creator's — the chain cannot tell who held the key that produced a signature, so the recovered-signer surface accommodates custodial signing with no on-chain change. A backend-attestation alternative — one whitelisted server key authorizing launches with the creator as a signed field — was considered and rejected: it re-introduces the privileged approval the relay requirement forbids ("without allowlisting, approval, or privileged roles"), adds mutable protocol state and an admin surface the singleton otherwise avoids, and its only purpose — authorizing keyless creators — disappears under per-creator keys, which would make the whitelist redundant machinery. The launch accordingly keeps two entries for wallet creators: the creator's own transaction, where identity is the sender and no signature is required, and signed relay, where identity is the recovered signer; the dev buy rides only the creator's own transaction. Both entries feed the same salt formula — `keccak256(configHash, creator)` — so a creator who publishes a signed configuration and later self-launches deploys to the advertised address either way, and a griefer self-launching the published configuration lands at a different address exactly as a foreign signature does.

### 20. The anti-snipe decay is removed; the fee is static with milestone step-downs

*Added during planning review; supersedes the 99%→1% launch window.*

**Decision:** The 99%→1% launch-window decay, its `beforeSwap` override, the four window presets, and their precedence rules are deleted. The pool fee is the stored base fee (1%), stepped down permanently by milestone completions via `updateDynamicLPFee` (Decision 8, revised). `DYNAMIC_FEE_FLAG` is retained solely for the step-down.

**Why:** With the nested JIT curve (Decision 17), the cheap supply a decay wall protected is structurally scarce — the curve shape is the paper's own anti-snipe mitigation, and this protocol's version is stronger (JIT thin books, whales paying deploy gas, creator dev buy front-running snipers). The decay machinery was the hook's most test-fragile component (block-stepped warps, override precedence) and it conflicts with the lazy launch model: a wall that re-arms at genesis makes deployment timing matter again, defeating Decision 19's "timing is inert" property. Sniping at open is accepted, as pump.fun accepts it.

**Consequence:** Every swap pays the flat (stepped-down) fee from genesis. The fee suite loses its warp-dependent tests; `token-launch` loses the window knob. The fee can only decrease, at most twice, ever.

**Alternatives considered:** Keep as a per-launch option defaulting to 0s (preserves the choice but the guarded hot path stays); keep with a fee-exempt trigger buyer (a snipe lottery — rejected).

### 21. Creator and protocol are paid in ETH only

*Added during planning review; supersedes the four-ledger claim accounting.*

**Decision:** All token-denominated value entering the hook is routed to pool-facing destinations: 20% of collected token fees divert to the milestone fund (unchanged), the remaining 80% compounds into the full-range position, paired with the ETH LP share (any pairing imbalance carries in `pendingLpToken`). Creator and protocol accrue **ETH only** — from graduation proceeds, harvests, and ETH-denominated fees. The `_creatorClaimableTokens` and `_protocolClaimableTokens` ledgers, their claim entry points, and their events are deleted.

**Why:** Token fees paid to creator or protocol were income those parties could only realize by selling against their own holders — the protocol has no use for token balances it will never act on. Sell fees cluster in drawdowns; routing them to future walls and pool depth is the maximally counter-cyclical destination. Four ledgers collapse to two, two claim paths and their events vanish — real EIP-170 headroom and a one-sentence accounting: *creators earn ETH; token fees build walls and liquidity.*

**Consequence:** `revenue-claims` loses its token-ledger scenarios; the fee waterfall's token side becomes fund-then-LP; the conservation invariants lose their token-claim legs.

**Alternatives considered:** Keep four ledgers (symmetry without purpose); auto-burn all token fees (discards the LP pairing that compounds depth).

### 22. Reclaim is removed; abandoned bands are permanent standing orders

*Added during planning review; supersedes Decision 14.*

**Decision:** The 30-day permissionless reclaim — its entry point, the `BandReclaimed` event, and Decision 14's quote-routing machinery — is deleted. A deployed band the market never completes remains a standing limit order: if the market returns, it fills at its level; if the token dies, the band holds its inventory and in-range fee accrual indefinitely.

**Why:** The multi-band design removed reclaim's original purpose (unblocking a stuck ladder — nothing blocks anymore). The remaining argument, value recovery, collapsed under arithmetic: with spot below the band's lower bound the position is entirely token (an AMM round trip — the partial fill's ETH converts back when price falls), so the only stranded value is the band's in-range fee accrual, dust per pool. Against that dust: a cold-path entry point, an event, a state machine, and a near-completion griefing shape. The stranding is accepted and recorded in Risks — conditional on permanent death, since a returning market completes the band and folds the fees into the normal harvest.

**Consequence:** `milestone-ladder` loses the reclaim requirement and its scenarios; fee-funded slots are consumed permanently (the decrement bookkeeping dies with the double-draw quirk); the invariant suite drops its reclaim legs.

**Alternatives considered:** Keep reclaim guarded to spot-below-lower (recovers fee dust only — dust versus permanent surface); re-target reclaimed tokens at higher bands (economically incoherent — offering inventory above a level the market just declined to reach).

## Risks / Trade-offs

- **Singleton hook bytecode exceeds the 24 KB limit** → **Realised in task group 8, and resolved.** Arithmetic lived in libraries from the start, `via_ir` was on, and `optimizer_runs` was size-tuned; the hook still reached 25,461 bytes against the 24,576 limit with three task groups of hook code still to write. The contingency was taken in a modified form: instead of a thin external *launcher* (one trust edge), the launch and graduation paths moved into a `DELEGATECALL` satellite, `MilestoneColdPaths`, which introduces no trust edge because it executes as the hook. See Decision 1's revision note. Post-split: hook 12,713 bytes, satellite 16,278 — both with 8 KB or more of headroom for groups 9–11. Contract size was checked in CI from the first milestone, which is why this surfaced with room to respond rather than at the end.
- **Delegatecall storage-layout drift between the hook and its satellite** → New risk introduced by the split above, and the reason the split is the *only* structural coupling worth guarding. Both contracts resolve storage slots from their own compiled layout while writing the hook's storage, so a divergence would write a pool's phase over a claim balance with no revert and no event — silent corruption that a runtime test would only catch by happening to assert on the colliding pair. Contained three ways: every shared state variable is declared exactly once in `MilestoneBase` and never in either derived contract; `make layout-check` compares both compiled layouts against `MilestoneBase` in CI, so a variable added to either half fails the build; and the same target checks that every satellite entry point carries `onlyDelegated`, so a direct call cannot reach the satellite's own storage. The layout check is self-tested against an injected extra slot and a reordering.
- **Singleton means one bug affects every pool** → Accepted in exchange for the smaller audit surface. Mitigated by `poolId`-scoped storage with isolation asserted as an invariant, not assumed.
- **Sign inversion in ladder math** → Normalised `level` coordinate (Decision 3), conversion confined to two boundary helpers, and fork tests against real v4 where a wrong-sided band would visibly fill instantly.
- **Sweeping swap skips several milestones** → By design (`DESIGN.md §10`); inventory is never lost, it re-targets. The single-active-band invariant makes this the *only* possible outcome rather than an edge case, which is why it is bounded rather than merely tolerated.
- **Flash-pump graduation** → Cost-based mitigation only, as `DESIGN.md §10` accepts: the attacker pays the full curve spread and the proceeds stay in the pool. The tick is verified at call time so a reverted pump cannot leave a graduation flag set.
- **Nested settlement swap reverting mid-harvest** → The whole transaction reverts. No partial-harvest state is representable, because completion marking and routing occur in the same call frame.
- **Fee-collection griefing** → Bounded per-call cost and net-unchanged position; a spammer pays gas to accomplish nothing. Asserted directly by the "repeated collection is harmless" scenario.
- **Dust accumulation in hook custody** → Accepted and made explicit in every conservation requirement. Dust accrues to the protocol side, never to a user's detriment; there is no sweep function in v1.
- **In-band oscillation churn** → Not preventable without swap gating, which the design rejects. Every cycle pays the spread twice and harvest-at-crossing is atomic, so churn delays nothing it can profit from.
- **NFT claim semantics on transfer** → Unclaimed balance follows the NFT (flaunch pattern), so a seller who forgets to claim loses the balance to the buyer. Documented and accepted per `DESIGN.md §10`; the specs state it as a requirement rather than leaving it emergent.
- **The buyback moves the price, and could in principle skip the next milestone** → Bounded by construction, and measured. The buyback is a market buy of the buyback share against the full-range position, so it raises the level after every harvest — in the group 9 tests, by roughly 2,350 levels (~26%) for a default 20% share of a full band's proceeds. The next band's lower bound sits 2,235 levels above the band just completed, so a buyback at the default share can now carry price into the next band's range — but under simulation-driven deployment that band is already deployed, so a partial fill is the outcome, not a skip. A partial fill left by a self-swap settles on the next external crossing (self-swaps skip the hook's own callbacks), which is benign: the milestone completes on genuine external demand, one swap later than the buyback's own push. The group 9 measurement is repeated as a fork-test assertion under multi-band deployment, and `buybackWad` stays capped at 40%.
- **A multi-harvest swap exceeds reasonable gas** → Capped. `MAX_HARVESTS_PER_SWAP` (8) bounds settlement at roughly 8 × (burn + nested buyback + donate) ≈ 1.2M gas; a sweep crossing more completed bands than the cap leaves the remainder live and settles it on the next swap. Curve-side burns at graduation are bounded by the template's 32 positions.
- **The simulation deploys a band the swap does not actually fill** → Structurally one-sided. A level/profile or rounding mismatch can only *under*-deploy (the simulation never sells inventory), and an under-deployed band degrades to the specified skip-and-carry: inventory carries forward, no value lost, no revert. Boundary fuzz tests compare simulated outcomes against real v4 execution at band edges.
- **A sweeping buy jumps undeployed bands when the deploy cap is hit** → By design and benign. The cap is 8 bands ≈ a 6× market-cap single swap at the 1.25× template spacing — beyond any plausible organic trade; overflow carries inventory forward exactly as the legacy skip path did, now a fallback rather than the primary mechanism.
- **Graduation gas lands on an uninvolved trader** → Bounded and self-selecting. The auto-trigger costs ~2M gas (32 burns) once per pool, falls on the first trader who wants a market that cannot exist above `farLevel` until graduation runs, and permissionless `graduate()` lets a prepared caller race it. Accepted without a bounty: there is nothing for a caller to steer.
- **Sniping at open** → Accepted, structurally mitigated. With the anti-snipe decay removed (Decision 20), open-price sniping is possible by design, as pump.fun accepts. Mitigation is structural: the nested JIT book has no cheap supply pile (position 0 holds ~1/32 of curve inventory across the full 2× span), deploys cost the deploying whale gas, and the creator's dev buy can front-run snipers from genesis.
- **Signature replay or stale-config deployment** → Handled by construction. EIP-712 over the config hash with a deadline; CREATE2 salt derived from the config hash *and* the recovered signer (Decision 19, revision), so a replayed signature fails on the already-deployed token and a different signer cannot occupy the advertised address; the signature covers every economic parameter, so a relayer cannot alter any of them.
- **Fee accrual stranded in abandoned bands** → Accepted (Decision 22). A band the market never completes holds its in-range fee accrual indefinitely; if the market returns, the band completes and the fees fold into the normal harvest. Stranding is conditional on permanent death and is fee dust per pool, not principal — an AMM round trip returns the converted quote when price falls back through the band.

## Migration Plan

Nothing exists to migrate; this is a first deployment.

1. Deploy the revenue NFT contract and the `LaunchSupport` helper.
2. Deploy `MilestoneColdPaths`, the delegatecall satellite (Decision 1's revision note), constructed with the same pool manager, revenue NFT and launch support the hook will get. It must exist before the hook: the hook's constructor rejects a satellite address with no code, since a `DELEGATECALL` to a codeless address succeeds silently and would turn every launch into a no-op.
3. Mine the hook salt off-chain for the required permission flags, then deploy the hook via a CREATE2 deployer with that salt. The satellite's address is a constructor argument and therefore part of the initcode the salt is mined against, so mining must follow step 2 and the mined salt is only valid for that exact satellite address and argument set. Verify the deployed address encodes exactly the expected flags before proceeding.
4. Verify the hook and the satellite were constructed with identical pool manager, revenue NFT and launch support addresses, and that the hook's `coldPaths` points at the deployed satellite. A mismatch does not revert at deployment but makes the two halves disagree about their own immutables at runtime.
5. Wire the NFT's authorised minter to the hook, and set the protocol fee recipient.
6. Verify all contracts on the block explorer and publish the launch-parameter bounds.

**Rollback:** There is no upgrade or pause path by design, so rollback is not a runtime operation — it is deploying a corrected protocol and ceasing to launch on the old one. The satellite is no exception: `coldPaths` is immutable on the hook, so replacing the launch logic means deploying a new hook at a newly mined address, exactly as changing any other logic would. Pools already launched on a deployed hook keep running under it permanently, including their locked full-range LP. This makes pre-deployment verification the whole of the safety margin: testnet deployment with a complete lifecycle rehearsal precedes mainnet, and the mined address's flags are asserted on-chain before the NFT is wired.

## Open Questions

- Sliver size for the fee-collection burn/re-add — needs empirical tuning against real accrual on a fork; affects gas and dust only, not behaviour or task breakdown.
- Whether the launch token adds Permit2 support (`DESIGN.md §3` marks it optional) — additive to the token contract, decidable when the token is written.
- Whether the protocol fee recipient is an EOA or a multisig at deployment — operational, resolved at the deployment step.
