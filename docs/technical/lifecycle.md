---
description: "The Spawn pool state machine: curve phases, graduation semantics, ladder geometry, and per-swap work caps."
icon: timeline
---

# Lifecycle and the ladder

## Phase state machine

`Phase` (0-indexed): `NONE = 0`, `BONDING_CURVE = 1`, `GRADUATED = 2`. It advances one way and never reverts. Read via `poolPhase(poolId)` or `poolState(poolId)`.

## Bonding curve

- Genesis mints **curve position 0 only**; positions 1–31 deploy just-in-time as a buy's simulated path approaches them. Template: 32 positions spanning `opening → far`.
- Curve supply is **25%** of total supply; `far = opening + 13,862` levels (**~4x** the opening FDV — two 2x spans). Total supply is pinned to 1,000,000,000 (`SupplyNotFixed` otherwise) and every launch opens at the 2 ETH template FDV:
  `openingLevel = log_1.0001(openingFdvWei / totalSupplyWei)`.
- Work per swap is capped at **8 position deploys / 8 harvests**; anything left settles on later swaps.

## Graduation

- Trigger: live `level >= farLevel`, evaluated **at call time** — a pool that touched the far level and fell back has not graduated.
- Two racing, idempotent, permissionless paths: the next buy's `beforeSwap` auto-graduates, or anyone calls `graduate(key)`. The second caller reverts having changed nothing.
- Effects: all curve positions burn; quote proceeds split **20% LP seed / 70% creator / 10% protocol**. Two code-locked positions are seeded — no removal path exists, and the hook rejects every third-party liquidity operation: a **full-range** position funded by the 20% seed (ETH-limited, ~72.77M of the 650M graduation tokens), bounded to a market-cap range of ~$5,100 to ~$150B FDV, and a **wall** — a single-sided, token-only position over the 880,000 levels above graduation absorbing the remaining ~577.23M tokens at zero ETH cost.

## The milestone ladder

Protocol-owned, one-sided sell bands at ascending valuations:

```
band i+1 starts max(2235, 6932 - 391*i) levels above band i
levelUpper(i) = levelLower(i) + 447
```

- **22 core bands** hold 10% of supply (~4,545,454.5 tokens each) and reach roughly **2,900x** the graduation valuation (~$58M FDV at the $2,500/ETH reference); up to **30 fee-funded extensions** continue above at the floor spacing, funded by the token-fee stream.
- Bands deploy just-in-time ahead of a buy's path and are **harvested** — burned into the payout pot — the moment a swap crosses a band's top.
- The live set is `deployedBands & ~completedBands` and may hold several bands at once.
- A band whose lower bound is already behind spot when its turn comes is **skipped** (`BandSkipped`): its token share moves to carried inventory and the next band draws on it. Specified behavior, not an error state.

{% hint style="info" %}
The straddle deadlock — a band that could neither deploy nor skip — is proven impossible; the property is pinned by named scenarios and invariant tests (see [testing and gates](testing-and-gates.md)).
{% endhint %}

## Post-graduation fee flows

| Flow | Routing |
| --- | --- |
| Quote-side (ETH) swap fees, realized from the full-range and wall positions by `collectFees` | default 75% creator ledger / 25% protocol |
| Token-side swap fees | default 100% funds the next fee-funded band, clamped to the remaining extension capacity; anything beyond capacity burns immediately |
| Harvest of a crossed band | default 10% service fee to the claim-backed ledger / 90% funds the payout pot |

Percentages are the deployed defaults, governance-mutable within hard caps and applied **prospectively** — see [economics and governance](economics-and-governance.md).
