---
description: "Spawn's economic parameters: the immutable protocol template, the governance-mutable economics tuple, and the ProtocolController's typed operations."
icon: sliders
---

# Economics and governance

## Two layers of numbers

| Layer | Mutable? | Lives in |
| --- | --- | --- |
| **Protocol template** (`Bounds.defaultTemplate`) | No — immutable for a deployment generation | `src/types/LaunchTypes.sol`; read live via `template()` |
| **Economics tuple** (`EconomicConfig`) | Yes — timelocked, versioned, prospective | `ProtocolController`; read live via `economicConfig()` |

## The immutable template

| Constant | Value |
| --- | --- |
| `openingFdvWei` | 2e18 ETH FDV, every launch |
| Total supply | Pinned to 1,000,000,000 tokens — any other declared value reverts (`SupplyNotFixed`) |
| Curve positions / span | 32 / 13,862 levels (4x opening, two 2x spans) |
| Band spacing / width | first step 6,932 levels (2x), decaying by 391 per band to the 2,235-level (1.2504x) floor / 447 levels |
| Core bands / fee-funded bands | 22 / 30 |
| Supply split (curve / ladder / graduation LP + wall) | 25% / 10% / 65% |
| Graduation split (LP / creator / protocol) | 20% / 70% / 10% |
| Full-range range / wall | bounded ~$5,100 to ~$150B FDV / 880,000 levels above graduation |
| Trading fee | 10 000 hundredths-bip (**1%**, static) |
| Tick spacing | 1 |
| Dev-buy cap | 10% of supply |
| Per-swap work caps | 8 deploys / 8 harvests |

## The economics tuple

| Field | Default | Immutable cap |
| --- | --- | --- |
| `harvestServiceFeeWad` | 0.10e18 | 0.20e18 |
| `quoteCreatorShareWad` | 0.75e18 | 0.90e18 |
| `tokenMilestoneFundShareWad` | 1.00e18 | 1.00e18 |
| `version` | 1 | increments per replacement |

Changes are **prospectively applied**: each accrual and flush stamps the `economicVersion` it used, so history stays auditable. Indexers should treat `version` as part of every payout record.

## ProtocolController

Timelocked governance over: the economics tuple, plugin registration/suspension in the registry, the protocol recipient, and the governance delay itself. Operations are **typed** (`Operation` enum) and execute through a delay queue with scheduled/cancelled/executed events. The controller's authority is bounded by on-chain caps — the table's "immutable cap" column is enforced by `ProtocolTargetBound`, not convention.

## PayoutPluginRegistry

- Append-only; **stable indices 0–255** (`MAX_ENTRIES = 256`). Entries are never removed, only suspended.
- Registration binds a role (`PAYOUT`, `CREATOR_SYSTEM`, `UTILITY`), a take in WAD, and the plugin's **codehash** — a changed codehash invalidates the entry permanently.
- A launch plan selects at most **8 active** entries with summed takes ≤ 100% (`isSelectable(index)`); index 0 is the canonical buyback-and-burn with take `2WAD/9` ≈ 22.2%.
- Registry mutation authority is handed to the controller at deployment; the hook redirects payouts for inactive/suspended/codehash-mismatched entries to the creator path instead of calling them.
