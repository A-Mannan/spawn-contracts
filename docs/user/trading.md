---
description: "Trading on Spawn: buying into the curve, the 1% fee, graduation, price limits, and how quotes work."
icon: arrow-trend-up
---

# Trading

## The pool

Every launch is exactly one Uniswap v4 pool: **ETH vs the token**, with a static **1% fee** and 1-tick spacing. Buys pay the fee in ETH; sells pay it in token.

## Buying

- Buys move the price **up** the bonding curve before graduation and against full-range liquidity after.
- There is no liquidity above the curve top until graduation, so an unbounded buy sweeps the curve and parks the price at the top. Frontends show **"graduation on next trade"** and route that trade through a deliberate, quoted graduation first.
- Bounded buys into the curve may land at their target level or one rung above it — treat targets as minimums, not exacts.

## Selling

- After graduation, the protocol's own ladder is a standing **sell-side bid**: as the price climbs into each milestone band, the protocol sells that band's tokens into your pump and retires the proceeds into payouts.
- A band whose moment has passed before it could deploy is **skipped** — its tokens roll into the next rung. That is normal protocol behavior ("milestone bypassed"), not an error.

## Fees — where they go

The 1% fee is not a tip to LPs. Post-graduation it funds the protocol's economics: the ETH side mostly goes to the creator's revenue stream, the token side funds future ladder rungs and burns. See [how it works](how-it-works.md) for the exact splits.

## Flush timing

`flush(poolId)` is a standalone permissionless call: anyone can deliver a pool's payout pot, and the immediate caller earns the 1% tip. When your trade completes a milestone, the pot funds but is not delivered until someone flushes - usually a keeper. The NFT holder does not need to race anyone: `claimCreatorPath(poolId)` flushes first and pays out the complete entitlement, tip included, in one call.

{% hint style="warning" %}
**You cannot provide liquidity.** The hook rejects every third-party deposit or withdrawal — the pool's liquidity is protocol-owned by design. If a UI offers you to "LP" a Spawn pool, it is not Spawn.
{% endhint %}

## Quotes

Quote through `V4Quoter` or the v4 SDK against the pool — the quote runs the hook's real logic, so just-in-time curve and band deployments are already priced in. Two caveats: gas estimates from a quote understate real swaps (deployments cost gas), and quotes are single-swap — re-quote on submission errors rather than padding slippage.
