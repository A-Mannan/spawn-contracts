---
description: "Deploying Spawn: environment variables, the migration-plan ordering, salt-mining rules, and the deployment manifest."
icon: screwdriver-wrench
---

# Deployment

## The one command

```bash
POOL_MANAGER=0x… PROTOCOL_ADMIN=0x… PROTOCOL_RECIPIENT=0x… \
BOOTSTRAP_ADMINISTRATOR=0x… \
forge script script/Deploy.s.sol --rpc-url "$BASE_RPC_URL" --broadcast
```

| Env var | Meaning |
| --- | --- |
| `POOL_MANAGER` | Uniswap v4 PoolManager on the target chain (Base mainnet: `0x498581fF718922c3f8e6A244956aF099B2652b2b`) |
| `PROTOCOL_ADMIN` | The protocol multisig that will accept final authority |
| `PROTOCOL_RECIPIENT` | Where protocol revenue is claimed |
| `BOOTSTRAP_ADMINISTRATOR` | The broadcaster key performing the deployment |
| `CREATE2_DEPLOYER` | Optional; defaults to the canonical deterministic-deployment proxy |

The template comes from `Bounds.defaultTemplate()` — the script **cannot** deploy custom economics. A deployment that used anything else would be a protocol no frontend could quote from source.

## Ordering and salt rules

`LaunchpadDeploy.deployAll` follows the design's Migration Plan: RevenueNFT → LaunchSupport → satellites → mined hook → wiring, with every planned verification executed before the wiring completes.

{% hint style="danger" %}
**Restart rule:** steps 1–2 are nonce-derived, so the mined hook salt is valid only for the satellite instance deployed in the same run. A run that fails partway must **restart from step 1** — never resume with a printed salt.
{% endhint %}

## After broadcast

1. The run writes **`deployments/<chainId>.json`** — the machine-readable manifest every frontend and indexer consumes: all deployed addresses, the hook salt, the canonical payout plan, and the template + economics snapshot. WAD-sized values are decimal strings, never JS numbers.
2. The configured **protocol multisig** completes the two-step admin handoff by calling `ProtocolController.acceptAdministrator` directly. It must not route the call through a script contract — a different `msg.sender` fails acceptance.
3. Verify pins and gates: `make pins && make release-check` (see [testing and gates](testing-and-gates.md)).

## Mining a salt standalone

`script/MineHookSalt.s.sol` mines a hook address for given permissions without deploying:

```bash
PROTOCOL_ADMIN=0x… PROTOCOL_RECIPIENT=0x… forge script script/MineHookSalt.s.sol
```

Use it to pre-compute vanity or verification addresses; the real deployment mines its own salt internally.

## ABI export

`make abis` writes the curated `abi/*.json` set (hook, support, token, NFT, registry, controller, buyback plugin, `IPayoutPlugin`, plus `StateView` and `V4Quoter`). Satellites and pure libraries are deliberately excluded — see the [architecture rule](architecture.md) on delegatecall satellites.
