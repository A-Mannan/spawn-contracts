---
description: "Launch a token on Spawn: build your config, reserve your address, sign, and launch with an optional dev buy."
icon: rocket
---

# Launching a token

## Before you start

- You need an EOA-capable signer (the launch signature is a plain 65-byte EIP-712 signature — smart wallets must sign via an EOA-capable path).
- Decide your token's **name**, **symbol**, **total supply**, and optional **dev buy** (up to 10% of supply).
- Choose the launch's [payout plan](payout-plugins.md) — which plugins share milestone proceeds.

## The flow

{% stepper %}
{% step %}
### Build your configuration

Your launch is a fixed struct: creator (you), name, symbol, total supply, dev-buy share, payout plan, and a signing deadline. A frontend builds it for you.
{% endstep %}

{% step %}
### Validate and reserve your address

`LaunchSupport.validate(config)` checks the config and payout plan against the live registry. `LaunchSupport.predictToken(config, hook)` then tells you **the exact token address you will get** — knowable before you sign anything.

{% hint style="info" %}
The token address is derived from your config **and your address**. The same config from a different creator gets a different address — nobody can front-run your name.
{% endhint %}
{% endstep %}

{% step %}
### Sign

You sign an EIP-712 message over the whole configuration with a deadline. Every field is inside the signature — **a relayer cannot alter a single byte** of your launch, and the protocol reverts with `CreatorMismatch` if anyone tries.
{% endstep %}

{% step %}
### Launch

Send `MilestoneHook.launch(config, signature)`. Two ways:

| Mode | Who sends | ETH attached | Result |
| --- | --- | --- | --- |
| Self-send | You | Dev-buy budget | You receive exactly `totalSupply × devBuyShare` tokens; unused ETH auto-refunds |
| Relayed | Anyone | Nothing | Token launches; the dev-buy share stays on the curve for the market |

Either way, the token mints to the hook, the pool goes live at the standard 125 ETH opening valuation, and the whole fixed supply is accounted for: 25% curve, 65% milestone ladder, 10% full-range backing.
{% endstep %}
{% endstepper %}

## Dev-buy details

- The dev buy is a **fixed token amount** whose ETH cost is computed on execution — attach your budget plus headroom; exact-input semantics cap the spend and refund the difference.
- Relayed launches record a `DevBuySkipped` event; the share simply stays in curve inventory. The relayer never spends its own ETH on your behalf.

## Signature mechanics worth knowing

{% hint style="warning" %}
Your signature has a **deadline**. If it lapses, no problem: the deadline is signed but does not affect the token address, so you can re-sign with a fresh deadline and everything else stays identical — same reserved address, same config.
{% endhint %}

The EIP-712 domain is `SpawnLaunchpad`, version `"1"`, with the hook address as the verifying contract — clients should cross-check the digest against `LaunchSupport.launchDigest(config, hook)` before requesting a signature.
