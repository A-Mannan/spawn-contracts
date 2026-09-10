---
description: "Spawn's security model: authority boundaries, custody classes, the invariants the suite pins, and what governance can never change."
icon: shield-halved
---

# Security model

## Authority boundaries

| Role | Scope | Lifetime |
| --- | --- | --- |
| Deployer | Wires the minter on the RevenueNFT | One-shot; retains no ongoing authority |
| `ProtocolController` (admin) | Economics tuple within caps, plugin registry, protocol recipient, delay | Timelocked, typed operations only |
| Hook | All per-pool state, the only NFT minter, the only LP in its pools | Permanent |
| Governance delay | Time between scheduling and executing a controller operation | Governance-mutable within bounds |

## Custody classes

The hook distinguishes exactly two kinds of held value, and every claim path redeems only what it is entitled to:

- **Raw ETH** — graduation split, quote-fee share, creator-path entitlement, protocol remainder.
- **PoolManager ERC-6909 claims** — payout pots and the claim-backed service-fee ledger, redeemed into raw ETH only inside a flush.

Claims cover pots plus the claim-backed protocol ledger; raw ETH covers carry, creator-path, direct, and protocol remainder. A solvency assertion (`_assertSolvent`) backs every claim: the ledgers cannot promise more ETH than the hook holds.

## Invariants the suite pins

- **No drain of unaccrued value** — claims are bounded by accrual; the claim paths recheck ownership mid-flight and restore entitlement on recipient failure.
- **No third-party liquidity** — the hook rejects every external add/remove; the full-range position is code-locked.
- **No straddle deadlock** — a ladder band can always either deploy or skip; the property is proven, not assumed.
- **Payout delivery cannot be trapped** — plugin reverts become carry and retry; suspended/changed-code entries are permanently redirected to the creator path; the pre-mutation in-flight guard prevents double delivery under reentrancy.
- **Every action reaches effect** — the invariant handler drives every unlock action to observable state change.
- **Bounded work per swap** — deploys and harvests are capped (8/8), so no swap can be gas-griefed into failure by ladder width.

## Reentrancy posture

Settlement uses transient (EIP-1153) locks around launch, graduation, and flush; claims racing those operations revert and can be retried losslessly. While a plugin is being paid, PoolManager callback work is suppressed rather than reverted — a plugin's own pool interactions cannot recursively trigger graduation, deployment, or harvesting.

## What governance can never change

- The **caps** on every economic parameter (e.g. harvest service fee never exceeds 20%, creator quote share never exceeds 90%) are enforced by `ProtocolTargetBound`, not by convention.
- The **template** (openings, band geometry, supply split, 1% fee) is immutable per deployment generation.
- The **registry is append-only**: entries are never removed, indices never reused, and changed code is never trusted again.

## Known deployment-policy boundaries

One guarantee holds by deployment wiring rather than by code: the registry's mutation authority is irrevocably handed to the controller at deploy time. The deployment script checks it; treat deviations as a broken deployment.
