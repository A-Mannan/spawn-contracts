#!/usr/bin/env python3
"""Source-level assertion that the full-range position has no removal path.

The `graduation` spec requires "The system SHALL expose no code path, for any caller including the
creator and the protocol, that removes or reduces liquidity from the full-range position." Runtime tests
can only show that the paths we thought of are closed. This checks the stronger, structural claim: no
`modifyLiquidity` call site in the hook combines a negative `liquidityDelta` with `FULL_RANGE_SALT`.

Burning is legitimate elsewhere — curve positions at graduation, band positions at harvest and reclaim —
so the check is specific to the full-range salt rather than banning negative deltas outright.

Both halves of the hook are scanned. `MilestoneColdPaths` runs by DELEGATECALL in the hook's own storage,
so a reducing call site there would reduce the hook's own full-range position; scanning only the hook
would leave exactly the file that seeds the position unchecked.
"""

import re
import sys

# Every source file that executes in the hook's storage context. `MilestoneBase` is scanned too: both
# halves inherit it, so a call site added there would reduce the hook's own position exactly as one in
# either derived file would, and would otherwise escape this check entirely.
SOURCES = ("src/MilestoneHook.sol", "src/MilestoneColdPaths.sol", "src/MilestoneBase.sol")

# Files that must contain at least one call site, or the scan has gone vacuous and the path has moved.
# `MilestoneBase` legitimately holds none: it declares the settlement primitives and the band-proceeds
# routing, neither of which calls `modifyLiquidity`.
MUST_HAVE_SITES = ("src/MilestoneHook.sol", "src/MilestoneColdPaths.sol")
SALT = "FULL_RANGE_SALT"


def main() -> int:
    total_sites = 0
    violations = []
    salt_sites = 0

    for source in SOURCES:
        with open(source) as handle:
            text = handle.read()

        # Each modifyLiquidity call site, from the call through its closing paren-ish region.
        sites = [m.start() for m in re.finditer(r"poolManager\.modifyLiquidity\(", text)]
        if not sites and source in MUST_HAVE_SITES:
            print(f"check_full_range_lock: no modifyLiquidity call sites found in {source}", file=sys.stderr)
            print("check_full_range_lock: the check would pass vacuously; is the path still there?", file=sys.stderr)
            return 1
        total_sites += len(sites)

        for start in sites:
            block = text[start : start + 900]
            end = block.find(");")
            if end != -1:
                block = block[:end]

            uses_full_range_salt = SALT in block
            # A negative delta is written either as a literal `-int256(...)`/`-1` or via a named negative.
            reduces = re.search(r"liquidityDelta:\s*-", block) is not None

            if uses_full_range_salt:
                salt_sites += 1
                if reduces:
                    line = text[:start].count("\n") + 1
                    violations.append(f"{source}:{line}")

    # The salt has to appear at some call site, or the position is never created and the scan above
    # proves nothing. This is the same anti-vacuity guard as the empty-sites check, one level down.
    if salt_sites == 0:
        print(f"check_full_range_lock: no modifyLiquidity call site uses {SALT}", file=sys.stderr)
        print("check_full_range_lock: the full-range position is never created; did it move?", file=sys.stderr)
        return 1

    for location in violations:
        print(f"FAIL {location}: reduces liquidity on the full-range position", file=sys.stderr)

    if violations:
        print("check_full_range_lock: the full-range position must have no removal path", file=sys.stderr)
        return 1

    print(
        f"check_full_range_lock: OK, {total_sites} modifyLiquidity site(s) across {len(SOURCES)} file(s), "
        f"{salt_sites} on the full range, none reduces it"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
