---
description: "Payout plugins on Spawn: how milestone proceeds are delivered on-chain, the buyback-and-burn default, and what creators select at launch."
icon: puzzle-piece
---

# Payout plugins

Every milestone harvest funds a **payout pot**. A pot is never spent by the protocol directly — it is **flushed** to the launch's selected **payout plugins**: ordinary contracts that receive ETH and do something with it.

## The default: buyback and burn

Every deployment ships with a reference plugin at registry index 0: **buyback and burn**. It spends its share of the pot buying the launch token off the market and burning it — milestone pressure flows straight back into the token. The canonical launch selects exactly this plugin.

## Choosing a plan at launch

A launch's payout plan is **immutable** — it is part of the signed configuration. A plan is a bitset of registry indices:

- Up to **8 plugins** from the [registry](../technical/economics-and-governance.md), each currently active.
- Each plugin has a declared **take** (a share of every pot). The sum of takes cannot exceed 100%.
- **You are the remainder**: whatever the plugins don't take accrues to your [creator-path revenue](revenue-and-claims.md). Selecting nothing (plan 0) sends every pot to you.

## How a flush runs

When someone triggers `flush(poolId)` — permissionless, incentivized with a **1% tip** on each new pot:

{% stepper %}
{% step %}
The pot is redeemed from the pool's claim into raw ETH.
{% endstep %}
{% step %}
The flusher is paid the 1% tip.
{% endstep %}
{% step %}
Each selected plugin is called in ascending registry order with its share (`onPayout`).
{% endstep %}
{% step %}
Whatever the takes didn't consume is credited to the creator path.
{% endstep %}
{% endstepper %}

## Failure is safe by construction

{% hint style="success" %}
**A plugin reverting is a successful flush.** Its share is held as *carry* and retried automatically on the next flush — later plugins still get paid, and the pot can never be trapped.
{% endhint %}

A plugin that has been suspended, deactivated, or whose deployed code no longer matches its registered codehash is treated differently: its share is **permanently redirected to the creator path**. The protocol never re-trusts changed code.
