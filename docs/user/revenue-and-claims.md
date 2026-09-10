---
description: "How creator revenue accrues on Spawn, what the RevenueNFT represents, and how to claim or transfer it."
icon: coins
---

# Revenue and claims

## Where creator revenue comes from

Three streams accrue to a launch's creator:

| Stream | Source |
| --- | --- |
| Graduation share | 55% of curve proceeds at graduation |
| Direct fee share | 75% of post-graduation ETH-side swap fees |
| Creator-path entitlement | Whatever the payout plan's plugins do not take from milestone pots, plus payments redirected away from failed plugins |

Streams one and two are paid in raw ETH. Stream three is credited when a milestone pot is [flushed](payout-plugins.md) and the selected plugins' takes don't consume all of it.

## The RevenueNFT is the claim right

At launch the creator receives a **RevenueNFT** for the pool. The current holder of that NFT — and only the current holder — holds the right to the creator revenue stream.

{% hint style="warning" %}
**Transferring the NFT transfers the stream — including everything unclaimed.** An unclaimed balance follows the NFT to its new owner. If you sell or gift your RevenueNFT, you are selling your accrued and future revenue with it. There is no way to split them.
{% endhint %}

## Claiming

- **Direct claim** (`claimCreator`): the NFT holder claims the accrued direct revenue. Always succeeds when called by the current holder — a zero balance is a successful no-op.
- **Creator-path claim** (`claimCreatorPath`): anyone can trigger this; it pays the *current NFT holder*. It flushes the pool's pot first (keeping the keeper tip), so one call collects everything the launch owes you.
- **Zero-amount claims do not revert**, so batch tools can safely call both paths across all your pools.

{% hint style="info" %}
**Rare race:** a claim that collides with a graduation, launch, or flush in the same block reverts with a transient lock error. Nothing is lost — just retry.
{% endhint %}

## What the holder sees

| Question | Where |
| --- | --- |
| How much is owed to me directly? | `creatorClaimable(poolId)` |
| How much sits on the creator path (unflushed or pending)? | `creatorPathClaimable(poolId)` |
| Who holds the stream right? | The RevenueNFT's `ownerOf(tokenId)` — the token ID is the pool ID |

## Selling the stream

Because the NFT is a standard ERC-721, the revenue stream is tradeable like any NFT. A buyer takes over future accruals and everything unclaimed at transfer time; the seller keeps nothing behind.
