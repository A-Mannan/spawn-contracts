#!/usr/bin/env python3
"""Assertion that every externally-callable function on the delegatecall satellite is guarded.

`MilestoneColdPaths` is only ever meant to run as `MilestoneHook`, reached by DELEGATECALL. Each of its
entry points carries an `onlyDelegated` modifier that reverts a direct call. Unit tests assert that for
the entry points that exist today; this asserts the property for entry points that do not exist yet,
which is where the risk actually is. An unguarded function added later would be callable by anyone
against the satellite's own storage — the one hole the split could open.

The check reads the compiled ABI so it enumerates the real external surface rather than trusting a
hand-maintained list, then confirms each name carries the modifier in the source. State-changing
functions only: a `view`/`pure` getter reachable on the satellite reads its own empty storage and cannot
mislead anyone, so requiring the modifier there would only cost gas on the delegated path.

Requires `forge build` to have run.
"""

import json
import os
import re
import sys

CONTRACT = "MilestoneColdPaths"
SOURCE = "src/MilestoneColdPaths.sol"
MODIFIER = "onlyDelegated"

# `constructor`/`receive`/`fallback` are not callable entry points in the relevant sense: a constructor
# runs once at deployment, and the satellite declares neither of the other two.
CALLABLE_ABI_TYPES = ("function",)

# A direct call cannot change anything through these.
READ_ONLY = ("view", "pure")


def load_abi(out_dir: str) -> list:
    path = os.path.join(out_dir, f"{CONTRACT}.sol", f"{CONTRACT}.json")
    try:
        with open(path) as handle:
            return json.load(handle)["abi"]
    except FileNotFoundError:
        print(f"check_cold_path_guards: missing artifact {path}", file=sys.stderr)
        print("check_cold_path_guards: run `forge build` first", file=sys.stderr)
        return None


def guarded_functions(source: str) -> set:
    """Names of functions whose declaration — signature through opening brace — carries the modifier."""
    guarded = set()

    for match in re.finditer(r"\bfunction\s+(\w+)\s*\(", source):
        name = match.group(1)
        # The declaration runs from the name to the opening brace of the body (or `;` for an abstract
        # declaration). Modifiers can only appear in that span, and it cannot swallow the next function
        # because `{` terminates it.
        rest = source[match.end() :]
        end = rest.find("{")
        semicolon = rest.find(";")
        if semicolon != -1 and (end == -1 or semicolon < end):
            end = semicolon
        if end == -1:
            continue

        if re.search(r"\b" + re.escape(MODIFIER) + r"\b", rest[:end]):
            guarded.add(name)

    return guarded


def main() -> int:
    out_dir = sys.argv[1] if len(sys.argv) > 1 else "out"

    abi = load_abi(out_dir)
    if abi is None:
        return 1

    with open(SOURCE) as handle:
        source = handle.read()
    guarded = guarded_functions(source)

    entry_points = [
        entry
        for entry in abi
        if entry.get("type") in CALLABLE_ABI_TYPES and entry.get("stateMutability") not in READ_ONLY
    ]

    if not entry_points:
        # If the satellite ever presents no state-changing entry point the split has been restructured,
        # and a silently-passing check would be worse than a failing one.
        print(f"check_cold_path_guards: {CONTRACT} exposes no state-changing entry point", file=sys.stderr)
        print("check_cold_path_guards: the check would pass vacuously; did the split change?", file=sys.stderr)
        return 1

    unguarded = sorted({entry["name"] for entry in entry_points} - guarded)

    for name in unguarded:
        print(f"FAIL {SOURCE}: {name} is externally callable without `{MODIFIER}`", file=sys.stderr)

    if unguarded:
        print(
            f"check_cold_path_guards: {CONTRACT} runs by delegatecall only; every state-changing entry "
            f"point needs `{MODIFIER}` so a direct call cannot reach its own storage",
            file=sys.stderr,
        )
        return 1

    names = ", ".join(sorted({entry["name"] for entry in entry_points}))
    print(f"check_cold_path_guards: OK, {len(entry_points)} entry point(s) all guarded ({names})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
