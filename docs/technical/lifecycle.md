---
description: "The Spawn pool state machine: curve phases, graduation semantics, ladder geometry, and per-swap work caps."
icon: timeline
---

# Lifecycle and the ladder

## Phase state machine

`Phase` (0-indexed): `NONE = 0`, `BONDING_CURVE = 1`, `GRADUATED = 2`. It advances one way and never reverts. Read via `poolPhase(poolId)` or `poolState(poolId)`.

## Bonding curve

- Genesis mints **curve position 0 only**; positions 1–31 deploy just-in-time as a buy's simulated path approaches them. Template: 32 positions spanning `opening → far`.
- Curve supply is **25%** of total supply; `far = opening + 6931` levels (**2x** the opening FDV); `opening` is derived from supply so every launch opens at the 125 ETH template FDV:
  `openingLevel = log_1.0001(openingFdvWei / totalSupplyWei)`.
- Work per swap is capped at **8 position deploys / 8 harvests**; anything left settles on later swaps.

## Graduation

- Trigger: live `level >= farLevel`, evaluated **at call time** — a pool that touched the far level and fell back has not graduated.
- Two racing, idempotent, permissionless paths: the next buy's `beforeSwap` auto-graduates, or anyone calls `graduate(key)`. The second caller reverts having changed nothing.
- Effects: all curve positions burn; quote proceeds split **40% LP seed / 55% creator / 5% protocol**; one **full-range** position is seeded. That position is code-locked — no removal path exists, and the hook rejects every third-party liquidity operation.

## The milestone ladder

Protocol-owned, one-sided sell bands at ascending valuations:

```
levelLower(i) = graduationLevel + (i+1) × 2235
levelUpper(i) = levelLower(i) + 447
```

- **30 core bands** hold 65% of supply and reach ~**800x** the graduation valuation; up to **30 fee-funded extensions** continue above, funded by the token-fee stream.
- Bands deploy just-in-time ahead of a buy's path and are **harvested** — burned into the payout pot — the moment a swap crosses a band's top.
- The live set is `deployedBands & ~completedBands` and may hold several bands at once.
- A band whose lower bound is already behind spot when its turn comes is **skipped** (`BandSkipped`): its token share moves to carried inventory and the next band draws on it. Specified behavior, not an error state.

{% hint style="info" %}
The straddle deadlock — a band that could neither deploy nor skip — is proven impossible; the property is pinned by named scenarios and invariant tests (see [testing and gates](testing-and-gates.md)).
{% endhint %}

## Post-graduation fee flows

| Flow | Routing |
| --- | --- |
| Quote-side (ETH) swap fees, realized from the full-range position by `collectFees` | default 75% creator ledger / 25% protocol |
| Token-side swap fees | default 20% funds the next fee-funded band / 80% burns; 100% burns at zero remaining extension capacity |
| Harvest of a crossed band | default 10% service fee to the claim-backed ledger / 90% funds the payout pot |

Percentages are the deployed defaults, governance-mutable within hard caps and applied **prospectively** — see [economics and governance](economics-and-governance.md).
