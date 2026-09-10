#!/usr/bin/env python3
"""Check literal OpenSpec scenario headers and their passing test evidence.

The required inventory is the *delta* change's own scenarios. The delta is a partial
overlay -- `## ADDED` / `## MODIFIED` / `## REMOVED` blocks over an earlier change's
specs -- so the test tree legitimately still carries headers naming base scenarios that
the delta never touched. Those are *recognised* (they are not renamed drift) without
being *required*, which is the only way a partial overlay can be gated honestly.
"""

import argparse
import re
import sys
import xml.etree.ElementTree as ET
from collections import defaultdict
from pathlib import Path

SPEC_RE = re.compile(r"^#### Scenario: (.+?)\s*$")
REQUIREMENT_RE = re.compile(r"^###\s+Requirement:\s*(.+?)\s*$")
SECTION_RE = re.compile(r"^##\s+(ADDED|MODIFIED|REMOVED|RENAMED)\s+Requirements\s*$")
HEADER_RE = re.compile(r"^\s*// --- Scenario(?: \(([^)]+)\))?: (.+?) ---\s*$")
CONTRACT_RE = re.compile(r"^\s*(?:abstract\s+)?contract\s+(\w+)")
TEST_RE = re.compile(r"^\s*function\s+((?:test|invariant_)\w*)\s*\(")

DEFAULT_SPEC_DIR = "openspec/changes/add-payout-plugins/specs"
DEFAULT_BASE_SPEC_DIR = "openspec/changes/add-milestone-launchpad/specs"


def load_specs(spec_dir):
    """Return every `#### Scenario:` in a spec tree, tagged by section and requirement."""
    scenarios = []
    for path in sorted(Path(spec_dir).glob("*/spec.md")):
        capability = path.parent.name
        section = None
        requirement = None
        for line_number, line in enumerate(path.read_text().splitlines(), 1):
            section_match = SECTION_RE.match(line)
            if section_match:
                section = section_match.group(1)
                requirement = None
                continue
            requirement_match = REQUIREMENT_RE.match(line)
            if requirement_match:
                requirement = requirement_match.group(1)
                continue
            match = SPEC_RE.match(line)
            if match:
                scenarios.append(
                    {
                        "capability": capability,
                        "name": match.group(1),
                        "path": path,
                        "line": line_number,
                        "section": section,
                        "requirement": requirement,
                    }
                )
    return scenarios


def superseded_requirements(delta_specs):
    """(capability, requirement) pairs the delta restates or deletes.

    A `MODIFIED` block republishes a requirement in full, so its base scenario list is
    replaced rather than extended; a `REMOVED` block deletes it. Either way the base
    copy's scenarios stop being recognised, which is what makes a stale header visible.
    """
    return {
        (row["capability"], row["requirement"])
        for row in delta_specs
        if row["section"] in ("MODIFIED", "REMOVED") and row["requirement"]
    }


def superseded_requirement_names(spec_dir):
    """Requirement headings under `MODIFIED`/`REMOVED`, including scenario-less ones.

    A `REMOVED` block carries only prose, so it contributes no scenario rows and would
    otherwise be invisible to {superseded_requirements}.
    """
    pairs = set()
    for path in sorted(Path(spec_dir).glob("*/spec.md")):
        capability = path.parent.name
        section = None
        for line in path.read_text().splitlines():
            section_match = SECTION_RE.match(line)
            if section_match:
                section = section_match.group(1)
                continue
            requirement_match = REQUIREMENT_RE.match(line)
            if requirement_match and section in ("MODIFIED", "REMOVED"):
                pairs.add((capability, requirement_match.group(1)))
    return pairs


def carried_specs(base_spec_dir, delta_specs, delta_spec_dir):
    """Base scenarios that survive the delta untouched, and so stay recognisable."""
    base_dir = Path(base_spec_dir)
    if not base_dir.is_dir():
        return []
    superseded = superseded_requirements(delta_specs) | superseded_requirement_names(delta_spec_dir)
    required_names = {row["name"] for row in delta_specs}
    carried = []
    for row in load_specs(base_dir):
        if (row["capability"], row["requirement"]) in superseded:
            continue
        if row["name"] in required_names:
            continue
        carried.append(row)
    return carried


FUNCTION_RE = re.compile(r"^\s*function\s+(\w+)\s*\(")
CALL_RE = re.compile(r"\b(\w+)\s*\(")


def _is_entry_point(name):
    return bool(TEST_RE.match(f"    function {name}("))


def _parse_functions(lines):
    """Every function in a file, with its contract, and the names it calls.

    Fork suites annotate private *stage* helpers rather than the single entry point that
    drives them, so a header's evidence is only discoverable through the call graph.
    """
    functions = {}
    order = []
    contract = None
    current = None
    for line in lines:
        contract_match = CONTRACT_RE.match(line)
        if contract_match:
            contract = contract_match.group(1)
            current = None
        function_match = FUNCTION_RE.match(line)
        if function_match:
            current = (contract, function_match.group(1))
            functions.setdefault(current, set())
            order.append(current)
            continue
        if current is not None:
            functions[current].update(CALL_RE.findall(line))
    return functions, order


def _entry_points_for(function, functions):
    """Test entry points that reach `function`, following the call graph upwards."""
    contract, name = function
    if _is_entry_point(name):
        return [function]
    reached = set()
    frontier = {name}
    seen = {name}
    while frontier:
        callee_names = frontier
        frontier = set()
        for candidate, calls in functions.items():
            if candidate[0] != contract or candidate in reached:
                continue
            if not (calls & callee_names):
                continue
            if _is_entry_point(candidate[1]):
                reached.add(candidate)
            elif candidate[1] not in seen:
                seen.add(candidate[1])
                frontier.add(candidate[1])
    return sorted(reached)


def load_headers(test_dir):
    """Collect literal scenario headers and the test entry points that execute them.

    Several headers stacked immediately above one function all describe it -- the fork
    suites use the pattern deliberately -- so a group accumulates until a function
    declaration consumes it, and the next header after that starts a fresh group.
    """
    headers = []
    for path in sorted(Path(test_dir).rglob("*.sol")):
        lines = path.read_text().splitlines()
        functions, _ = _parse_functions(lines)
        contract = None
        group = []
        for line_number, line in enumerate(lines, 1):
            contract_match = CONTRACT_RE.match(line)
            if contract_match:
                contract = contract_match.group(1)
            header = HEADER_RE.match(line)
            if header:
                entry = {
                    "capability": header.group(1),
                    "name": header.group(2),
                    "path": path,
                    "line": line_number,
                    "contract": contract,
                    "tests": [],
                }
                group.append(entry)
                headers.append(entry)
                continue
            function_match = FUNCTION_RE.match(line)
            if function_match and group:
                for owner in _entry_points_for((contract, function_match.group(1)), functions):
                    for entry in group:
                        entry["tests"].append(owner)
                group = []
    return headers


def layer_of(path, test_dir):
    """The suite layer a header lives in -- `unit`, `invariant`, `fork`, and so on."""
    try:
        relative = Path(path).resolve().relative_to(Path(test_dir).resolve())
    except ValueError:
        return str(path)
    return relative.parts[0] if len(relative.parts) > 1 else "."


def junit_results(paths):
    if not paths:
        return None
    passing = set()
    failing = set()
    for path in paths:
        root = ET.parse(path).getroot()
        for suite in root.iter("testsuite"):
            suite_class = suite.get("name", "").split(":")[-1].split(".")[-1]
            for case in suite.findall("testcase"):
                class_name = case.get("classname", "").split(":")[-1].split(".")[-1] or suite_class
                test_name = case.get("name", "").split("(", 1)[0]
                key = (class_name, test_name)
                if (
                    case.find("failure") is not None
                    or case.find("error") is not None
                    or case.find("skipped") is not None
                ):
                    failing.add(key)
                else:
                    passing.add(key)
    return passing, failing


def inspect(spec_dir, test_dir, junit=None, base_spec_dir=DEFAULT_BASE_SPEC_DIR):
    specs = load_specs(spec_dir)
    carried = carried_specs(base_spec_dir, specs, spec_dir)
    headers = load_headers(test_dir)

    by_name = defaultdict(list)
    for scenario in specs:
        by_name[scenario["name"]].append(scenario)
    duplicate_specs = {name: rows for name, rows in by_name.items() if len(rows) > 1}

    required = {row["name"]: row for row in specs}
    recognised = dict(required)
    for row in carried:
        recognised.setdefault(row["name"], row)

    claimed = defaultdict(list)
    carried_headers = []
    unknown = []
    wrong_capability = []
    empty = []
    for header in headers:
        if not header["tests"]:
            empty.append(header)
        scenario = recognised.get(header["name"])
        if scenario is None:
            unknown.append(header)
            continue
        if header["capability"] and header["capability"] != scenario["capability"]:
            wrong_capability.append((header, scenario))
        if header["name"] in required:
            claimed[header["name"]].append(header)
        else:
            carried_headers.append(header)

    missing = [required[name] for name in sorted(set(required) - set(claimed))]

    # Repetition is only redundant when the two headers cannot be probing different facets,
    # and the boundary for that is the test contract: one contract is one fixture against one
    # surface, so a second header there is a copy rather than a second angle. Across contracts
    # it is coverage -- the fork layer re-runs the specs against the live Base singleton, and a
    # validation suite and a surface suite legitimately meet the same requirement from opposite
    # sides -- so those are reported as evidence, not as defects.
    duplicates = {}
    for name, rows in claimed.items():
        per_contract = defaultdict(list)
        for row in rows:
            per_contract[(str(row["path"]), row["contract"])].append(row)
        repeated = [row for group in per_contract.values() if len(group) > 1 for row in group]
        if repeated:
            duplicates[name] = repeated

    evidence = junit_results(junit)
    nonpassing = []
    if evidence is not None:
        passing, _ = evidence
        for name, rows in claimed.items():
            tests = [test for row in rows for test in row["tests"]]
            if not any(test in passing for test in tests):
                nonpassing.append((required[name], tests))

    return {
        "specs": specs,
        "carried": carried,
        "headers": headers,
        "carried_headers": carried_headers,
        "missing": missing,
        "duplicates": duplicates,
        "duplicate_specs": duplicate_specs,
        "unknown": unknown,
        "wrong_capability": wrong_capability,
        "empty": empty,
        "nonpassing": nonpassing,
        "junit_supplied": evidence is not None,
    }


def location(row):
    return f"{row['path']}:{row['line']}"


def report(result, strict_duplicates=True):
    specs = result["specs"]
    print(f"scenario inventory: {len(specs)} required scenario(s)")
    print(f"literal coverage: {len(specs) - len(result['missing'])}/{len(specs)}")
    print(f"literal headers scanned: {len(result['headers'])}")
    print(f"carried base scenarios recognised: {len(result['carried_headers'])} header(s)")
    for scenario in result["missing"]:
        print(f"MISSING {scenario['capability']}: {scenario['name']}", file=sys.stderr)
    for name, rows in result["duplicates"].items():
        sites = ", ".join(location(row) for row in rows)
        print(f"DUPLICATE-ONLY {name}: {sites}", file=sys.stderr)
    for header in result["unknown"]:
        print(f"RENAMED-OR-UNKNOWN {location(header)}: {header['name']}", file=sys.stderr)
    for header, scenario in result["wrong_capability"]:
        print(
            f"WRONG-CAPABILITY {location(header)}: {header['name']} belongs to {scenario['capability']}",
            file=sys.stderr,
        )
    for header in result["empty"]:
        print(f"NO-TEST {location(header)}: {header['name']}", file=sys.stderr)
    for scenario, tests in result["nonpassing"]:
        rendered = ", ".join(f"{contract}.{test}" for contract, test in tests)
        print(f"NON-PASSING {scenario['capability']}: {scenario['name']} ({rendered})", file=sys.stderr)
    if not result["junit_supplied"]:
        print("passing evidence: not checked (supply --junit from the current test run)")
    else:
        passed = len(specs) - len(result["missing"]) - len(result["nonpassing"])
        print(f"passing evidence: {passed}/{len(specs)}")

    failures = (
        result["missing"]
        or result["duplicate_specs"]
        or result["unknown"]
        or result["wrong_capability"]
        or result["empty"]
        or result["nonpassing"]
        or (strict_duplicates and result["duplicates"])
    )
    return 1 if failures else 0


def write_markdown(path, result):
    missing = {row["name"] for row in result["missing"]}
    duplicated = set(result["duplicates"])
    nonpassing = {row[0]["name"] for row in result["nonpassing"]}
    empty = {row["name"] for row in result["empty"]}
    claimed = defaultdict(list)
    for header in result["headers"]:
        claimed[header["name"]].append(header)

    lines = [
        "# Payout-plugin scenario traceability",
        "",
        f"Inventory: **{len(result['specs'])}** scenarios, derived from the delta specs.",
        "",
        f"Base scenarios carried through untouched and still referenced by tests: "
        f"**{len(result['carried_headers'])}** header(s).",
        "",
        "| Capability | Scenario | Status | Test evidence |",
        "| --- | --- | --- | --- |",
    ]
    for scenario in result["specs"]:
        name = scenario["name"]
        headers = claimed.get(name, [])
        tests = [
            f"`{header['path']}:{header['line']}` "
            + ", ".join(f"`{contract}.{test}`" for contract, test in header["tests"])
            for header in headers
        ]
        if name in missing:
            status = "missing"
        elif name in duplicated:
            status = "duplicate-only"
        elif name in empty:
            status = "no test function"
        elif name in nonpassing:
            status = "non-passing"
        elif result["junit_supplied"]:
            status = "passing"
        else:
            status = "literal header; run unverified"
        lines.append(f"| {scenario['capability']} | {name} | {status} | {'<br>'.join(tests) or '-'} |")
    Path(path).write_text("\n".join(lines) + "\n")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--spec-dir", default=DEFAULT_SPEC_DIR)
    parser.add_argument("--base-spec-dir", default=DEFAULT_BASE_SPEC_DIR)
    parser.add_argument("--test-dir", default="test")
    parser.add_argument("--junit", type=Path, action="append", help="JUnit report; repeat for each test layer")
    parser.add_argument("--report", type=Path)
    parser.add_argument("--allow-duplicates", action="store_true")
    args = parser.parse_args()
    result = inspect(args.spec_dir, args.test_dir, args.junit, base_spec_dir=args.base_spec_dir)
    if args.report:
        write_markdown(args.report, result)
    return report(result, strict_duplicates=not args.allow_duplicates)


if __name__ == "__main__":
    raise SystemExit(main())
