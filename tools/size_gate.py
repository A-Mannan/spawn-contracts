#!/usr/bin/env python3
"""Contract size gate.

Fails if any contract that actually ships exceeds the EIP-170 limit. Enforced from the first milestone
on purpose: design.md Risks names "singleton hook bytecode exceeds the 24 KB limit" as the leading
structural risk, and the mitigation only works if the gate surfaces it continuously rather than at the
end. It has already earned that: MilestoneHook crossed the limit twice during Groups 4-6.

Reads compiled artifacts directly rather than parsing `forge build --sizes` output, because forge only
emits a size report when something recompiled — so on a warm cache the gate would have nothing to read.
Reading artifacts is deterministic regardless of cache state.

Usage:
    python3 tools/size_gate.py [--limit N] [--out-dir out]
    python3 tools/size_gate.py --artifact path/to/Foo.json --expect-fail

--expect-fail inverts the exit code, for the gate's own self-test.
"""

import argparse
import json
import os
import sys

EIP170_LIMIT = 24576

# The gate protects contracts that actually get deployed on-chain. Naming them explicitly means a test
# harness can never be mistaken for a production contract, and — more importantly — a production
# contract can never slip past the gate by being named like a test.
PRODUCTION_CONTRACTS = (
    "MilestoneHook",
    "MilestoneColdPaths",
    "MilestoneToken",
    "RevenueNFT",
    "LaunchSupport",
)


def runtime_size(path: str) -> int:
    with open(path) as handle:
        artifact = json.load(handle)

    obj = artifact.get("deployedBytecode", {}).get("object", "")
    if obj.startswith("0x"):
        obj = obj[2:]
    return len(obj) // 2


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--limit", type=int, default=EIP170_LIMIT)
    parser.add_argument("--out-dir", default="out")
    parser.add_argument("--artifact", action="append", default=[])
    parser.add_argument("--expect-fail", action="store_true")
    args = parser.parse_args()

    if args.artifact:
        targets = [(os.path.basename(p).removesuffix(".json"), p) for p in args.artifact]
    else:
        targets = [(name, os.path.join(args.out_dir, f"{name}.sol", f"{name}.json")) for name in PRODUCTION_CONTRACTS]

    missing = [path for _, path in targets if not os.path.isfile(path)]
    if missing:
        print(f"size_gate: artifact(s) not built: {', '.join(missing)}", file=sys.stderr)
        print("size_gate: run `forge build` first", file=sys.stderr)
        return 1

    violations = []
    for name, path in targets:
        size = runtime_size(path)
        if size > args.limit:
            violations.append((name, size, size - args.limit))
        else:
            print(f"  {name}: {size} bytes ({args.limit - size} to spare)")

    for name, size, over in violations:
        print(f"FAIL {name}: {size} bytes, {over} over the {args.limit} limit", file=sys.stderr)

    if violations:
        print(f"size_gate: {len(violations)} contract(s) over limit", file=sys.stderr)
        return 0 if args.expect_fail else 1

    print(f"size_gate: OK, {len(targets)} contract(s) within the {args.limit} byte limit")
    if args.expect_fail:
        print("size_gate: expected a violation but found none", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
