#!/usr/bin/env python3
"""Assertion that the two halves of the hook share one storage layout, slot for slot.

`MilestoneColdPaths` runs by DELEGATECALL from `MilestoneHook`, so it reads and writes the *hook's*
storage while resolving slots from its own compiled layout. If the two disagree by even one slot, a
launch writes a pool's phase over a claim balance and the corruption is silent — no revert, no event,
nothing a runtime test would notice unless it happened to assert on the specific pair of variables that
collided.

Both layouts are compared against `MilestoneBase`, the abstract contract that declares all of the shared
state, rather than against each other. Comparing to the base is the stronger check: two contracts can
agree with each other while both having drifted from the shared declaration, which happens the moment
someone adds the same variable to both halves instead of to the base. Comparing to the base rejects that,
and it is what makes the base's own claim — "the only way to break it is to declare a state variable in
one of the two derived contracts" — actually enforced rather than merely asserted in a comment.

Requires `extra_output = ["storageLayout"]` in foundry.toml, which is already set.
"""

import json
import os
import re
import sys

BASE = "MilestoneBase"
DERIVED = ("MilestoneHook", "MilestoneColdPaths")


def artifact_path(out_dir: str, name: str) -> str:
    return os.path.join(out_dir, f"{name}.sol", f"{name}.json")


def normalize_type(type_id: str) -> str:
    """Strips solc's AST node ids from a type identifier.

    A type identifier looks like `t_struct(PoolState)61355_storage`. The trailing number is an AST node
    id, which is assigned per compilation unit and shifts whenever an unrelated file above it in the
    dependency order gains or loses a declaration. The struct's *name* survives normalization, so a
    genuine type change is still caught while incidental id churn is not reported as a layout break.
    """
    return re.sub(r"\d+", "", type_id)


def read_layout(out_dir: str, name: str) -> list:
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


def describe(entry: tuple) -> str:
    slot, offset, label, type_id = entry
    return f"slot {slot} offset {offset}: {label} ({type_id})"


def diff(base: list, other: list, name: str) -> list:
    """Reports every position where `other` departs from `base`."""
    problems = []

    for index in range(max(len(base), len(other))):
        want = base[index] if index < len(base) else None
        got = other[index] if index < len(other) else None

        if want == got:
            continue
        if want is None:
            problems.append(f"{name} declares extra state not in {BASE} — {describe(got)}")
        elif got is None:
            problems.append(f"{name} is missing {BASE}'s {describe(want)}")
        else:
            problems.append(f"{name} has {describe(got)} where {BASE} has {describe(want)}")

    return problems


def main() -> int:
    out_dir = sys.argv[1] if len(sys.argv) > 1 else "out"

    base = read_layout(out_dir, BASE)
    if base is None:
        return 1
    if not base:
        # An empty base layout would make every comparison below trivially pass.
        print(f"check_storage_layout: {BASE} declares no storage; the check would pass vacuously", file=sys.stderr)
        return 1

    problems = []
    for name in DERIVED:
        layout = read_layout(out_dir, name)
        if layout is None:
            return 1
        problems.extend(diff(base, layout, name))

    if problems:
        for problem in problems:
            print(f"FAIL {problem}", file=sys.stderr)
        print(
            "check_storage_layout: the delegatecall halves must share one layout; "
            f"declare shared state in {BASE}, not in a derived contract",
            file=sys.stderr,
        )
        return 1

    print(
        f"check_storage_layout: OK, {' and '.join(DERIVED)} both match {BASE} "
        f"across {len(base)} slot(s)"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
