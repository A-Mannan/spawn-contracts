---
description: "Every number in a Spawn launch: opening and graduation valuations, ETH needed to graduate, and all 22 milestone payout levels with their ETH and USD values."
icon: diagram-table
---

# Milestones and payouts — the numbers

All figures use the protocol template (1,000,000,000-token fixed supply) and the **$2,500/ETH** reference price. ETH figures are exact; USD figures scale linearly with the ETH price.

## Launch and graduation

| Metric | Value |
| --- | --- |
| Opening valuation (FDV) | 2 ETH ≈ **$5,000** |
| Graduation valuation (FDV) | 8 ETH ≈ **$19,997** (4x opening) |
| ETH needed to graduate (full curve sweep) | ≈ **1.43 ETH** (≈ $3,570) |
| Tokens trading on the curve | 250M (25% of supply) |

The valuation doubles twice from open to graduation. The 1.43 ETH is what the curve raises because only a quarter of the supply trades there — the curve is the raise, there is no other sell-side liquidity during this phase.

{% hint style="info" %}
A creator's dev buy (up to 10% of supply) rides the same curve at the same prices, so part of the raised ETH can be the creator's own contribution.
{% endhint %}

### Where the graduation raise goes

| Recipient | Share | ETH | USD |
| --- | --- | --- | --- |
| Liquidity seed (code-locked forever) | 20% | ≈ 0.285 ETH | ≈ $713 |
| Creator | 70% | ≈ 0.999 ETH | ≈ $2,497 |
| Protocol | 10% | ≈ 0.143 ETH | ≈ $357 |

## The milestone ladder

After graduation, **10% of supply (100M tokens)** is loaded into 22 sell bands — ≈ 4.55M tokens each — at ascending valuations. The first rung sits **2x** the graduation valuation, rung spacing shrinks early on, and from rung 12 onward every rung is a steady **1.25x** above the last. The ladder tops out near **2,900x** graduation.

Each band is a one-sided sell position: as the price climbs through it, the band's tokens are sold into the pump and the proceeds fund the pool's payout pot. A milestone is completed when price crosses the band's **top**.

### All 22 milestones

Each band holds ≈ 4,545,454.5 tokens. "Value at completion" is the fully-diluted valuation when price crosses that band's top.

| Milestone | Market cap at completion | × Graduation | Harvest (ETH) | Payout pot (ETH) |
| --- | --- | --- | --- | --- |
| 1 | $41,823 | 2.1x | 0.074 | 0.067 |
| 2 | $80,441 | 4.0x | 0.143 | 0.129 |
| 3 | $148,783 | 7.4x | 0.265 | 0.238 |
| 4 | $264,637 | 13.2x | 0.471 | 0.424 |
| 5 | $452,656 | 22.6x | 0.805 | 0.724 |
| 6 | $744,571 | 37.2x | 1.324 | 1.192 |
| 7 | $1.18M | 58.9x | 2.094 | 1.885 |
| 8 | $1.79M | 89.6x | 3.186 | 2.867 |
| 9 | $2.62M | 131x | 4.660 | 4.194 |
| 10 | $3.69M | 184x | 6.555 | 5.900 |
| 11 | $4.99M | 249x | 8.868 | 7.981 |
| 12 | $6.49M | 324x | 11.54 | 10.38 |
| 13 | $8.12M | 406x | 14.43 | 12.99 |
| 14 | $10.15M | 508x | 18.05 | 16.24 |
| 15 | $12.69M | 635x | 22.57 | 20.31 |
| 16 | $15.87M | 794x | 28.22 | 25.40 |
| 17 | $19.85M | 992x | 35.29 | 31.76 |
| 18 | $24.82M | 1,241x | 44.12 | 39.71 |
| 19 | $31.03M | 1,552x | 55.17 | 49.65 |
| 20 | $38.80M | 1,940x | 68.99 | 62.09 |
| 21 | $48.52M | 2,426x | 86.27 | 77.64 |
| 22 | $60.67M | 3,034x | 107.87 | 97.08 |

Market-cap values are in ETH terms ≈ 16.7 / 32.2 / 59.5 / 105.9 ... up to 24,268 ETH at milestone 22.

### Full-ladder totals

| Metric | ETH | USD |
| --- | --- | --- |
| Total harvested across all 22 milestones | **520.95 ETH** | ≈ $1.30M |
| Protocol service fee (10% of each harvest) | 52.10 ETH | ≈ $130K |
| Total payout pots (90%) | **468.86 ETH** | ≈ $1.17M |

When a pot is flushed, a 1% tip goes to whoever triggers it, then the remainder is distributed to the launch's selected payout plugins and the creator:

| Recipient | Share of distributable | ETH (full ladder) |
| --- | --- | --- |
| Payout plugins (e.g. buyback-and-burn) | per launch plan | — |
| Buyback-and-burn at the canonical plan (2/9) | ≈ 22.2% | ≈ 103.15 ETH |
| Creator | remainder (7/9 at canonical) | ≈ 361.02 ETH |

{% hint style="success" %}
The ladder converts price appreciation into real payouts: a token that runs the full ladder turns 10% of its supply into roughly **$1.17M distributed** — without anyone selling into thin air. Every harvest is price *crossing* a milestone, so payouts are earned by demand, not by time.
{% endhint %}

## Beyond the 22nd milestone

Up to **30 additional rungs** extend the ladder above milestone 22, funded by the token-side trading-fee stream (100% of token fees go to next-rung funding until capacity is used up, then they burn). They continue at the steady 1.25x spacing, so the ladder keeps paying as long as the token keeps climbing — the core 22 need only price, not fees.

## Value flow summary

| Source | Split |
| --- | --- |
| Graduation raise | 20% locked liquidity · 70% creator · 10% protocol |
| Trading fees (ETH side) | 75% creator · 25% protocol |
| Trading fees (token side) | 100% next-rung funding until capacity is full, then burn |
| Milestone harvest | 10% protocol service fee · 90% payout pot |

{% hint style="info" %}
The percentages are protocol defaults set at launch; the harvest split and fee routing can move within hard caps, and every change applies only to future milestones. For the full mechanics see [How it works](how-it-works.md) and the [economics reference](../technical/economics-and-governance.md).
{% endhint %}
