#!/usr/bin/env python3
"""Verify every state-changing delegatecall-satellite entry has `onlyDelegated`."""

import argparse
import json
import os
import sys

REQUIRED_SATELLITES = ("MilestoneColdPaths",)
SOURCE_ACTIVATED_SATELLITES = ("MilestonePayoutPaths",)
MODIFIER = "onlyDelegated"
READ_ONLY = ("view", "pure")


def artifact_path(out_dir: str, name: str) -> str:
    return os.path.join(out_dir, f"{name}.sol", f"{name}.json")


def active_satellites(src_dir: str) -> tuple[tuple[str, ...], tuple[str, ...]]:
    active = list(REQUIRED_SATELLITES)
    pending = []
    for name in SOURCE_ACTIVATED_SATELLITES:
        if os.path.isfile(os.path.join(src_dir, f"{name}.sol")):
            active.append(name)
        else:
            pending.append(name)
    return tuple(active), tuple(pending)


def load_artifact(out_dir: str, contract: str) -> dict | None:
    path = artifact_path(out_dir, contract)
    try:
        with open(path) as handle:
            return json.load(handle)
    except FileNotFoundError:
        print(f"check_cold_path_guards: missing artifact {path}", file=sys.stderr)
        print("check_cold_path_guards: run `forge build` first", file=sys.stderr)
        return None


def abi_type(parameter: dict) -> str:
    value = parameter.get("type", "<unknown>")
    if not value.startswith("tuple"):
        return value
    suffix = value[len("tuple") :]
    return f"({','.join(abi_type(item) for item in parameter.get('components', []))}){suffix}"


def abi_signature(entry: dict) -> str:
    return f"{entry['name']}({','.join(abi_type(item) for item in entry.get('inputs', []))})"


def modifier_name(invocation: dict) -> str | None:
    name = invocation.get("modifierName", {})
    return name.get("name") or name.get("namePath")


def contract_definition(artifact: dict, contract: str) -> dict | None:
    ast = artifact.get("ast")
    if not ast:
        print(f"check_cold_path_guards: {contract} artifact has no AST", file=sys.stderr)
        print("check_cold_path_guards: foundry.toml needs `ast = true`", file=sys.stderr)
        return None
    for node in ast.get("nodes", []):
        if node.get("nodeType") == "ContractDefinition" and node.get("name") == contract:
            return node
    print(f"check_cold_path_guards: contract {contract} not found in its artifact AST", file=sys.stderr)
    return None


def check_contract(artifact: dict, contract: str, source: str) -> tuple[list[str], list[str]] | None:
    definition = contract_definition(artifact, contract)
    if definition is None:
        return None

    abi_entries = {
        entry.get("functionSelector"): entry
        for entry in definition.get("nodes", [])
        if entry.get("nodeType") == "FunctionDefinition"
        and entry.get("kind") == "function"
        and entry.get("visibility") in ("external", "public")
        and entry.get("implemented", True)
        and entry.get("functionSelector")
    }
    entries = [
        entry
        for entry in artifact.get("abi", [])
        if entry.get("type") == "function" and entry.get("stateMutability") not in READ_ONLY
    ]
    if not entries:
        print(f"check_cold_path_guards: {contract} exposes no state-changing entry point", file=sys.stderr)
        print("check_cold_path_guards: the check would pass vacuously; did the split change?", file=sys.stderr)
        return None

    unguarded = []
    guarded = []
    for entry in entries:
        complete_signature = abi_signature(entry)
        selector = artifact.get("methodIdentifiers", {}).get(complete_signature)
        function = abi_entries.get(selector)
        if function is None:
            unguarded.append(f"{source}: {complete_signature} (no matching source AST declaration)")
            continue
        modifiers = {modifier_name(modifier) for modifier in function.get("modifiers", [])}
        if MODIFIER in modifiers:
            guarded.append(complete_signature)
        else:
            unguarded.append(f"{source}: {complete_signature}")
    return guarded, unguarded


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--out-dir", default="out")
    parser.add_argument("--src-dir", default="src")
    args = parser.parse_args()

    satellites, pending = active_satellites(args.src_dir)
    guarded = []
    unguarded = []
    for contract in satellites:
        artifact = load_artifact(args.out_dir, contract)
        if artifact is None:
            return 1
        result = check_contract(artifact, contract, os.path.join(args.src_dir, f"{contract}.sol"))
        if result is None:
            return 1
        contract_guarded, contract_unguarded = result
        guarded.extend(f"{contract}.{item}" for item in contract_guarded)
        unguarded.extend(contract_unguarded)

    for entry in sorted(unguarded):
        print(f"FAIL {entry} is externally callable without `{MODIFIER}`", file=sys.stderr)
    if unguarded:
        print(
            "check_cold_path_guards: every state-changing satellite entry needs "
            f"`{MODIFIER}` so direct calls cannot reach satellite storage",
            file=sys.stderr,
        )
        return 1

    suffix = ""
    if pending:
        suffix = f"; pending source not present: {', '.join(pending)}"
    print(
        f"check_cold_path_guards: OK, {len(guarded)} complete-signature entry point(s) guarded "
        f"({', '.join(sorted(guarded))}){suffix}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
