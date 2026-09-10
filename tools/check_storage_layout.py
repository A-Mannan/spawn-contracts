#!/usr/bin/env python3
"""Verify every delegatecall implementation matches MilestoneBase's storage layout."""

import argparse
import json
import os
import re
import sys

BASE = "MilestoneBase"
REQUIRED_DERIVED = ("MilestoneHook", "MilestoneColdPaths")
SOURCE_ACTIVATED_DERIVED = ("MilestonePayoutPaths",)


def artifact_path(out_dir: str, name: str) -> str:
    return os.path.join(out_dir, f"{name}.sol", f"{name}.json")


def normalize_type(type_id: str) -> str:
    """Strip user-defined-type AST ids without collapsing widths such as uint128/uint256."""
    return re.sub(r"(?<=\))\d+(?=_(?:storage|memory|calldata|ptr|ref)|\)|,|$)", "", type_id)


def read_layout(out_dir: str, name: str) -> list | None:
    path = artifact_path(out_dir, name)
    try:
        with open(path) as handle:
            artifact = json.load(handle)
    except FileNotFoundError:
        print(f"check_storage_layout: missing artifact {path}", file=sys.stderr)
        print("check_storage_layout: run `forge build` first", file=sys.stderr)
        return None

    layout = artifact.get("storageLayout")
    if layout is None:
        print(f"check_storage_layout: {path} has no storageLayout", file=sys.stderr)
        print('check_storage_layout: foundry.toml needs extra_output = ["storageLayout"]', file=sys.stderr)
        return None

    return [
        (int(entry["slot"]), int(entry["offset"]), entry["label"], normalize_type(entry["type"]))
        for entry in layout.get("storage", [])
    ]


def active_derived(src_dir: str) -> tuple[tuple[str, ...], tuple[str, ...]]:
    active = list(REQUIRED_DERIVED)
    pending = []
    for name in SOURCE_ACTIVATED_DERIVED:
        if os.path.isfile(os.path.join(src_dir, f"{name}.sol")):
            active.append(name)
        else:
            pending.append(name)
    return tuple(active), tuple(pending)


def describe(entry: tuple) -> str:
    slot, offset, label, type_id = entry
    return f"slot {slot} offset {offset}: {label} ({type_id})"


def diff(base: list, other: list, name: str) -> list[str]:
    problems = []
    for index in range(max(len(base), len(other))):
        want = base[index] if index < len(base) else None
        got = other[index] if index < len(other) else None
        if want == got:
            continue
        if want is None:
            problems.append(f"{name} declares extra state not in {BASE} - {describe(got)}")
        elif got is None:
            problems.append(f"{name} is missing {BASE}'s {describe(want)}")
        else:
            problems.append(f"{name} has {describe(got)} where {BASE} has {describe(want)}")
    return problems


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--out-dir", default="out")
    parser.add_argument("--src-dir", default="src")
    args = parser.parse_args()

    base = read_layout(args.out_dir, BASE)
    if base is None:
        return 1
    if not base:
        print(f"check_storage_layout: {BASE} declares no storage; the check would pass vacuously", file=sys.stderr)
        return 1

    derived, pending = active_derived(args.src_dir)
    problems = []
    for name in derived:
        layout = read_layout(args.out_dir, name)
        if layout is None:
            return 1
        problems.extend(diff(base, layout, name))

    if problems:
        for problem in problems:
            print(f"FAIL {problem}", file=sys.stderr)
        print(
            f"check_storage_layout: every delegatecall implementation must match {BASE}; "
            f"declare shared state in {BASE}, not in a derived contract",
            file=sys.stderr,
        )
        return 1

    suffix = ""
    if pending:
        suffix = f"; pending source not present: {', '.join(pending)}"
    print(
        f"check_storage_layout: OK, {', '.join(derived)} match {BASE} "
        f"across {len(base)} slot(s){suffix}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
