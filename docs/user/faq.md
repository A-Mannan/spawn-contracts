---
description: "Frequently asked questions about launching, trading, and earning on Spawn."
icon: circle-question
---

# FAQ

<details>

<summary>Can I provide liquidity to a Spawn pool?</summary>

No. The hook rejects every third-party deposit and withdrawal — the pool's liquidity (curve, then full-range plus ladder) is protocol-owned by design. Trading is the only pool interaction.

</details>

<details>

<summary>When exactly does graduation happen?</summary>

When the price reaches the curve top (4x the opening valuation). It is evaluated at call time: the next buy auto-graduates, or anyone can call `graduate()` deliberately. Touching the top and falling back does not graduate the pool.

</details>

<details>

<summary>What does a "milestone" actually pay?</summary>

When the price crosses a ladder band's top, that band's tokens are sold and the proceeds fund the payout pot: 10% service fee, 90% to the pot. The pot is flushed to the launch's plugins and the creator's revenue path. See [payout plugins](payout-plugins.md).

</details>

<details>

<summary>My launch shows "milestone bypassed" — is something broken?</summary>

No. If the price outruns a band before it can deploy, the band is skipped and its tokens roll into the next rung. It is a specified outcome, not a failure.

</details>

<details>

<summary>Can a relayer steal my launch or change my config?</summary>

No. The signature covers every configuration field; any edit changes the digest and the protocol reverts with `CreatorMismatch`. A relayer also cannot trigger a dev buy on your behalf — relayed launches simply skip it.

</details>

<details>

<summary>My claim reverted with a lock error. Did I lose anything?</summary>

No. A claim that races a graduation, launch, or flush is rejected by a transient lock. Retry — the balance is untouched.

</details>

<details>

<summary>Why did my claim to a creator path "fail"?</summary>

`claimCreatorPath` pays the current RevenueNFT holder's chosen recipient. If that recipient reverts the transfer, the payment reports `success == false` and the entitlement is **restored** — nothing is lost. Fix the recipient and claim again.

</details>

<details>

<summary>What happens if I sell my RevenueNFT?</summary>

The entire revenue stream — accrued-but-unclaimed and future — follows the NFT to the new holder. See [revenue and claims](revenue-and-claims.md).

</details>

<details>

<summary>Is the token supply ever inflated?</summary>

No. Supply is fixed — 1,000,000,000 tokens for every launch — and can only decrease via explicit burns (sell-side fee residue, buyback-and-burn plugin).

</details>

<details>

<summary>Is Spawn live on mainnet?</summary>

The contracts are pre-deployment; deployments exist on testnet. Always take addresses from the deployment manifest for the chain you are on, never from a webpage.
</details>
