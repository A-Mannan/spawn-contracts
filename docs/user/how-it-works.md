---
description: "The lifecycle of every Spawn launch: bonding curve, milestone ladder, graduation, and where the money goes."
icon: diagram-project
---

# How it works

Every Spawn token lives in one pool that moves through three one-way phases.

```mermaid
stateDiagram-v2
    [*] --> BondingCurve: launch
    BondingCurve --> Graduated: price reaches the curve top
    Graduated --> Graduated: milestones pay out as price climbs
```

## Phase 1 — Bonding curve

A launch mints the whole fixed supply — **1,000,000,000 tokens**, pinned protocol-wide — to the hook and seeds a **bonding curve**: 32 liquidity positions spread over a price span that ends at **4x the opening valuation**. Every launch opens at the same valuation (2 ETH fully-diluted, ~$5,000 at the $2,500/ETH reference), so day-one pricing is fair and identical for everyone.

- Buying moves the price up the curve. Liquidity for later positions is deployed **just-in-time** as the price approaches them.
- There is no token in the pool above the curve top — the curve *is* the raise.
- The creator can buy a slice of supply at launch (the **dev buy**, capped at 10%) — everyone else buys on the same curve at the same price.

## Phase 2 — The milestone ladder (the differentiator)

When the price reaches the curve top, the pool **graduates** automatically:

- Curve liquidity is burned and replaced by two code-locked positions — neither can ever be removed: a **full-range position** funded by 20% of curve proceeds and bounded to a market-cap range of roughly $5,100 to $150B FDV, plus a **wall** — a single-sided token-only position spanning the 880,000 levels above graduation that absorbs every token the seed does not.
- Curve proceeds split **20% liquidity / 70% creator / 10% protocol**.
- 10% of supply is loaded into a **ladder of 22 one-sided sell bands** at ascending valuations. The first rung sits **2x** the graduation valuation and the spacing decays to **1.2504x** per rung, topping out around **2,900x** graduation. As price keeps climbing, each band is sold *into* the pump and its proceeds fund the pool's payout pot.

{% hint style="success" %}
This is what makes Spawn different: price increases after graduation **retire real liquidity** and pay people — the creator, on-chain plugins (like buyback-and-burn), and the protocol — instead of just making a chart go up.
{% endhint %}

After the core ladder, up to 30 extra rungs are funded by the token-side fee stream, so the ladder keeps paying as long as the token keeps climbing.

## Phase 3 — Graduated, permanently

Graduation is one-way. From then on:

- Trading continues on the graduated pool with full-range liquidity under it and the wall above it — deep buy-side liquidity with a hard price floor at a ~$5,100 FDV.
- Every milestone crossing funds the payout pot, which is flushed to the launch's selected [payout plugins](payout-plugins.md) and the creator's revenue stream.
- The creator's revenue lives in a [claimable stream represented by an NFT](revenue-and-claims.md).

## Where value flows

| Source | Split |
| --- | --- |
| Graduation (curve proceeds) | 20% LP seed · 70% creator · 10% protocol |
| Trading fees (ETH side) | 75% creator · 25% protocol |
| Trading fees (token side) | 100% next-rung funding · 0% burn (burns once extension capacity is used up) |
| Milestone harvests | 10% service fee · 90% payout pot |

{% hint style="info" %}
These are the shipped defaults. Governance can move the last three rows within hard caps — never past them, and changes apply only to future milestones. The exact numbers live in the [economics reference](../technical/economics-and-governance.md).
{% endhint %}
