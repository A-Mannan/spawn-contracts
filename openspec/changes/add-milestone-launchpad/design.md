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

### 5. Curve minting and dev buy happen under an explicit unlock, not inside `afterInitialize`

**Decision:** The launch function performs: deploy token → `poolManager.initialize` → `poolManager.unlock` → in `unlockCallback`, mint the curve fan, settle the token side, then execute the optional dev buy. `beforeInitialize` reverts unless the initiator is the hook's own launch path; `afterInitialize` only records per-pool state.

**Why:** `DESIGN.md §4` places curve minting and the dev buy in `afterInitialize`, but `initialize` does not unlock the `PoolManager` and `modifyLiquidity` is `onlyWhenUnlocked`. Minting from inside `afterInitialize` would require the hook to call `unlock` re-entrantly from within a manager callback. Doing the work under an explicit unlock in the same transaction preserves every externally observable property the specs require — atomic launch, curves live before any third party can trade, dev buy at the initial price — without fighting the lock model.

**Alternatives considered:** `unlock` from inside `afterInitialize` — works only because `initialize` holds no lock, but relies on a subtle non-guarantee of core internals and would break if core ever locks initialization. Two-transaction launch (initialize, then seed) — leaves a window where the pool exists with no liquidity and a manipulable price; rejected outright.

### 6. Buyback executes directly inside `afterSwap`

**Decision:** The harvest's buyback share calls `poolManager.swap` directly from `afterSwap`, settles its deltas, and burns the received token — all under a transient-storage lock.

**Why:** `afterSwap` is reached from `swap`, so the manager is already unlocked; no nested `unlock` is needed. The nested swap re-enters the hook's own `beforeSwap`/`afterSwap`, so the lock must do real work: while set, band deployment and harvest detection are suppressed, which prevents double-harvest and prevents the buyback from tripping a deployment mid-settlement.

**Alternatives considered:** Queue the buyback for a later permissionless call — loses atomicity, creates a MEV-extractable pending order, and leaves the routed proceeds in limbo across blocks.

### 7. Transient storage for all settlement locks

**Decision:** `tstore`/`tload` with namespaced slot keys (flaunch's `StoreKeys` pattern) guard band deployment, harvest settlement, fee collection, and claims. Guards are transaction-scoped and need no cleanup.

**Why:** These paths nest by design (harvest → buyback swap → hook callbacks). Persistent-storage reentrancy guards would cost a cold write plus a reset on every swap; transient storage costs are negligible and the "guard cannot leak across transactions" scenario in the ladder spec is satisfied by the EVM rather than by our cleanup code being correct.

### 8. Dynamic fee: computed in `beforeSwap`, base fee pushed at harvest

**Decision:** The anti-snipe decay is evaluated per swap and applied as a `beforeSwap` fee override. The milestone step-down mutates the stored *base* fee via `updateDynamicLPFee` at the harvest that crosses a threshold. The override wins while the anti-snipe window is open; once elapsed, the override yields to the stored base fee.

**Why:** This is exactly the precedence the `swap-fees` spec requires, and it puts each mechanism where its trigger naturally lives — the decay is a function of elapsed blocks (per-swap), the step is a function of completions (per-harvest). Block-stepped decay keeps the fee constant within a block, so it cannot be gamed by intra-block ordering.

**Alternatives considered:** Recomputing the whole schedule in `beforeSwap` including milestone steps — one code path, but re-reads completion state on every swap for a value that changes at most twice in a pool's life.

### 9. Fee collection by sliver burn and re-add

**Decision:** v4 exposes no standalone collect, so the permissionless collection path burns a minimal sliver of the full-range position's liquidity — which forces fee accounting to settle — then re-adds it, so net liquidity is unreduced. Collected fees are then split 60/30/10, with the token-denominated portion first subject to milestone-fund diversion.

**Why:** It is the established v4 workaround and the only one that does not require an external position manager holding the position. The `graduation` spec's "fee collection preserves net liquidity" and the `swap-fees` spec's "repeated collection is harmless" scenarios are the acceptance criteria; both are testable directly.

**Consequence:** Rounding on burn/re-add can leave dust. The design accepts hook-retained dust explicitly — every conservation requirement in the specs is written as "up to rounding dust retained by the hook" — and the invariant suite asserts dust is non-negative from the protocol's side, never negative.

### 10. Minimal protocol authority

**Decision:** The only privileged action in v1 is setting the protocol fee recipient. Per-pool configuration is immutable after launch. There is no pause, no parameter override, no ability to touch pool liquidity, ladder inventory, or creator balances.

**Why:** `DESIGN.md §3` forbids widening the trust surface beyond what it describes, and it describes none. Every bound is validated once at launch and then fixed, which makes the launch validator the whole of the protocol's policy enforcement — one function to audit rather than a mutable configuration space.

### 11. Test architecture

**Decision:** Three layers.

- **Unit** — per mechanism, on a locally deployed `PoolManager` via v4's test deployers. Fast, exhaustive over branch conditions, especially the launch validator's bound edges and the fee schedule's precedence table.
- **Fork** — against real v4 on a Base fork, exercising the full lifecycle: launch → dev buy → bonding curve fills → graduate → JIT deploy → harvest → route → reclaim → fee-funded extension. This is where orientation and settlement bugs surface, because a local harness can share our own sign mistakes.
- **Invariant / fuzz** — a handler driving random swap sequences, time jumps, collections, reclaims, and claims, asserting: total supply accounted for across custody, live band, positions, and burns; routed amounts sum to harvested amounts within dust; the four harvest shares sum to one whole; no code path reduces full-range liquidity; at most one live band; per-pool and per-party claim isolation.

**Why:** The ladder's failure modes are sequential and stateful — a jumped band followed by a reclaim followed by a fee-funded extension is not something a unit test enumerates. Invariants are the only layer that explores those orderings.

## Risks / Trade-offs

- **Singleton hook bytecode exceeds the 24 KB limit** → Arithmetic lives in libraries from the start rather than being extracted later under pressure. If the limit is still hit, the documented contingency is to split the launch entry into a thin external launcher whose only privilege is calling the hook's initialize path — reverting to the flaunch shape at the cost of one trust edge. Contract size is checked in CI from the first milestone so this surfaces early, not at the end.
- **Singleton means one bug affects every pool** → Accepted in exchange for the smaller audit surface. Mitigated by `poolId`-scoped storage with isolation asserted as an invariant, not assumed.
- **Sign inversion in ladder math** → Normalised `level` coordinate (Decision 3), conversion confined to two boundary helpers, and fork tests against real v4 where a wrong-sided band would visibly fill instantly.
- **Sweeping swap skips several milestones** → By design (`DESIGN.md §10`); inventory is never lost, it re-targets. The single-active-band invariant makes this the *only* possible outcome rather than an edge case, which is why it is bounded rather than merely tolerated.
- **Flash-pump graduation** → Cost-based mitigation only, as `DESIGN.md §10` accepts: the attacker pays the full curve spread and the proceeds stay in the pool. The tick is verified at call time so a reverted pump cannot leave a graduation flag set.
- **Nested settlement swap reverting mid-harvest** → The whole transaction reverts. No partial-harvest state is representable, because completion marking and routing occur in the same call frame.
- **Fee-collection griefing** → Bounded per-call cost and net-unchanged position; a spammer pays gas to accomplish nothing. Asserted directly by the "repeated collection is harmless" scenario.
- **Dust accumulation in hook custody** → Accepted and made explicit in every conservation requirement. Dust accrues to the protocol side, never to a user's detriment; there is no sweep function in v1.
- **In-band oscillation churn** → Not preventable without swap gating, which the design rejects. Every cycle pays the spread twice and harvest-at-crossing is atomic, so churn delays nothing it can profit from.
- **NFT claim semantics on transfer** → Unclaimed balance follows the NFT (flaunch pattern), so a seller who forgets to claim loses the balance to the buyer. Documented and accepted per `DESIGN.md §10`; the specs state it as a requirement rather than leaving it emergent.

## Migration Plan

Nothing exists to migrate; this is a first deployment.

1. Deploy the revenue NFT contract.
2. Mine the hook salt off-chain for the required permission flags, then deploy the hook via a CREATE2 deployer with that salt. Verify the deployed address encodes exactly the expected flags before proceeding.
3. Wire the NFT's authorised minter to the hook, and set the protocol fee recipient.
4. Verify all contracts on the block explorer and publish the launch-parameter bounds.

**Rollback:** There is no upgrade or pause path by design, so rollback is not a runtime operation — it is deploying a corrected protocol and ceasing to launch on the old one. Pools already launched on a deployed hook keep running under it permanently, including their locked full-range LP. This makes pre-deployment verification the whole of the safety margin: testnet deployment with a complete lifecycle rehearsal precedes mainnet, and the mined address's flags are asserted on-chain before the NFT is wired.

## Open Questions

- Sliver size for the fee-collection burn/re-add — needs empirical tuning against real accrual on a fork; affects gas and dust only, not behaviour or task breakdown.
- Whether the launch token adds Permit2 support (`DESIGN.md §3` marks it optional) — additive to the token contract, decidable when the token is written.
- Whether the protocol fee recipient is an EOA or a multisig at deployment — operational, resolved at the deployment step.
