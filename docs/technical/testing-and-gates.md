---
description: "Spawn's verification stack: Makefile targets, Foundry profiles, and the four structural gates CI runs on every push."
icon: flask
---

# Testing and verification gates

## Daily commands

| Command | What it runs |
| --- | --- |
| `make build` | `forge build` (via_ir, Solc 0.8.26, Cancun) |
| `make test` | unit suite, excluding `test/fork/**` and `test/invariant/**` |
| `make test-invariant` | handler-driven invariant suite |
| `make test-fork` | fork suites against live Base (`FOUNDRY_PROFILE=fork`, needs `BASE_RPC_URL`) |
| `make deep` | 10k fuzz runs / 1k invariant runs |
| `make fmt` / `make fmt-check` | format or verify formatting |
| `make abis` | export curated ABIs to `abi/` |

## The four structural gates

CI runs these on every push; they are as load-bearing as the tests:

1. **Size gate** (`tools/size_gate.py`) — every deployed contract under the EIP-170 24 KB limit. Reads compiled artifacts directly; fails the build on a deliberately oversized fixture contract in its self-test.
2. **Storage layout check** (`tools/check_storage_layout.py`) — proves `MilestoneColdPaths` and `MilestonePayoutPaths` declare exactly the same storage as `MilestoneBase`. This is what makes the delegatecall satellite design safe to refactor.
3. **Cold-path guard check** (`tools/check_cold_path_guards.py`) — every state-changing satellite entry point must carry the `onlyDelegated` guard, so nothing is callable outside the hook.
4. **Scenario gate** (`tools/check_scenarios.py`) — every named spec scenario must be referenced by a test. The mapping is documented in `openspec/reports/payout-plugin-scenario-traceability.md`.

The gate self-tests (`size-gate-selftest`, `structural-gate-selftest`, `scenario-tool-selftest`) verify the tools themselves fail when they should.

## Profiles

| Profile | Purpose |
| --- | --- |
| `default` | everyday build/test |
| `fork` | Base mainnet forking via `BASE_RPC_URL` (deliberately no `eth_rpc_url` in the base profile, so forks are opt-in) |
| `deep` | 10 000 fuzz runs, 1 000 invariant runs |

## The full release gate

```bash
make release-check
# pins → fmt-check → build → size → size-gate-selftest → structural-gate-selftest
#   → scenario-tool-selftest → lock-check → layout-check → abis → test-unit → test-invariant
```

`make test-fork` runs separately with an RPC endpoint. Dependency pins are recorded in `foundry.toml` (v4-core `5f00c84`, v4-periphery `9628c36`) and verified by `make pins`.

## Where the requirements live

The normative spec deltas are `openspec/changes/*/specs/`; `openspec validate --all` must pass. When docs and code disagree, the code wins — see the [security model](security-model.md) for the invariants these tests pin.
