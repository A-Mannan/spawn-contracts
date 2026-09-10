#!/usr/bin/env python3
"""AST-level allowlist for mutations of the permanently locked full-range position."""

import argparse
import json
import os
import sys

REQUIRED_CONTRACTS = ("MilestoneBase", "MilestoneHook", "MilestoneColdPaths")
SOURCE_ACTIVATED_CONTRACTS = ("MilestonePayoutPaths",)
FULL_RANGE_SALT = "FULL_RANGE_SALT"
KNOWN_NON_FULL_SALTS = ("bandSalt", "curvePositionSalt")
POSITIVE_ALLOWLIST = {
    ("MilestoneColdPaths", "_seedFullRange(PoolKey,PoolId,uint256,uint256,uint256)"),
}


def artifact_path(out_dir: str, name: str) -> str:
    return os.path.join(out_dir, f"{name}.sol", f"{name}.json")


def walk(node):
    if isinstance(node, dict):
        yield node
        for value in node.values():
            yield from walk(value)
    elif isinstance(node, list):
        for value in node:
            yield from walk(value)


def canonical_type(parameter: dict) -> str:
    value = parameter.get("typeDescriptions", {}).get("typeString", "<unknown>")
    for prefix in ("struct ", "enum ", "contract "):
        if value.startswith(prefix):
            return value[len(prefix) :].split()[0]
    return value.replace(" storage pointer", "").replace(" storage ref", "")


def signature(function: dict) -> str:
    parameters = function.get("parameters", {}).get("parameters", [])
    return f"{function.get('name', '<anonymous>')}({','.join(canonical_type(item) for item in parameters)})"


def declaration_values(function: dict) -> dict[int, dict]:
    values = {}
    for node in walk(function.get("body", {})):
        if node.get("nodeType") != "VariableDeclarationStatement":
            continue
        declarations = [item for item in node.get("declarations", []) if item]
        initial = node.get("initialValue")
        if len(declarations) == 1 and initial is not None:
            values[declarations[0]["id"]] = initial
    return values


def resolve_local(expression: dict, values: dict[int, dict], seen=None) -> dict:
    if seen is None:
        seen = set()
    while expression.get("nodeType") == "Identifier":
        declaration = expression.get("referencedDeclaration")
        if declaration not in values or declaration in seen:
            break
        seen.add(declaration)
        expression = values[declaration]
    return expression


def callee_name(call: dict) -> str | None:
    expression = call.get("expression", {})
    if expression.get("nodeType") == "Identifier":
        return expression.get("name")
    if expression.get("nodeType") == "MemberAccess":
        return expression.get("memberName")
    return None


def salt_kind(expression: dict, values: dict[int, dict]) -> str:
    expression = resolve_local(expression, values)
    if expression.get("nodeType") == "Identifier" and expression.get("name") == FULL_RANGE_SALT:
        return "full"
    if expression.get("nodeType") == "FunctionCall" and callee_name(expression) in KNOWN_NON_FULL_SALTS:
        return "other"
    return "unknown"


def delta_kind(expression: dict, values: dict[int, dict]) -> str:
    expression = resolve_local(expression, values)
    node_type = expression.get("nodeType")
    if node_type == "Literal" and expression.get("kind") == "number":
        value = int(expression.get("value", "0"), 0)
        return "zero" if value == 0 else "positive"
    if node_type == "UnaryOperation" and expression.get("operator") == "-":
        return "negative"
    if node_type == "FunctionCall" and expression.get("kind") == "typeConversion":
        inner = expression.get("arguments", [])
        if len(inner) != 1:
            return "unknown"
        inner_kind = delta_kind(inner[0], values)
        if inner_kind != "unknown":
            return inner_kind
        inner_type = inner[0].get("typeDescriptions", {}).get("typeString", "")
        if inner_type.startswith("uint"):
            return "positive"
    type_string = expression.get("typeDescriptions", {}).get("typeString", "")
    if type_string.startswith("uint"):
        return "positive"
    return "unknown"


def modify_params(call: dict, values: dict[int, dict]) -> tuple[dict, dict] | None:
    arguments = call.get("arguments", [])
    if len(arguments) < 2:
        return None
    params = resolve_local(arguments[1], values)
    if params.get("nodeType") != "FunctionCall" or params.get("kind") != "structConstructorCall":
        return None
    names = params.get("names", [])
    arguments = params.get("arguments", [])
    if not names or len(names) != len(arguments):
        return None
    fields = dict(zip(names, arguments))
    if "liquidityDelta" not in fields or "salt" not in fields:
        return None
    return fields["liquidityDelta"], fields["salt"]


def is_modify_liquidity(call: dict) -> bool:
    expression = call.get("expression", {})
    if call.get("nodeType") != "FunctionCall" or expression.get("nodeType") != "MemberAccess":
        return False
    if expression.get("memberName") != "modifyLiquidity":
        return False
    receiver_type = expression.get("expression", {}).get("typeDescriptions", {}).get("typeString", "")
    return receiver_type == "contract IPoolManager"


def line_number(source: bytes, source_range: str) -> int:
    start = int(source_range.split(":", 1)[0])
    return source[:start].count(b"\n") + 1


def check_contract(out_dir: str, src_dir: str, contract: str):
    artifact_name = artifact_path(out_dir, contract)
    source_name = os.path.join(src_dir, f"{contract}.sol")
    try:
        with open(artifact_name) as handle:
            artifact = json.load(handle)
        with open(source_name, "rb") as handle:
            source = handle.read()
    except FileNotFoundError as error:
        print(f"check_full_range_lock: missing required file {error.filename}", file=sys.stderr)
        return None

    ast = artifact.get("ast")
    if not ast:
        print(f"check_full_range_lock: {artifact_name} has no AST", file=sys.stderr)
        return None
    definition = next(
        (
            node
            for node in ast.get("nodes", [])
            if node.get("nodeType") == "ContractDefinition" and node.get("name") == contract
        ),
        None,
    )
    if definition is None:
        print(f"check_full_range_lock: {contract} not found in its artifact AST", file=sys.stderr)
        return None

    sites = []
    for function in definition.get("nodes", []):
        if function.get("nodeType") != "FunctionDefinition" or not function.get("body"):
            continue
        values = declaration_values(function)
        for call in walk(function["body"]):
            if not is_modify_liquidity(call):
                continue
            location = f"{source_name}:{line_number(source, call['src'])}"
            params = modify_params(call, values)
            if params is None:
                sites.append((location, signature(function), "unknown-salt", "unknown"))
                continue
            delta, salt = params
            sites.append((location, signature(function), salt_kind(salt, values), delta_kind(delta, values)))
    return sites


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--out-dir", default="out")
    parser.add_argument("--src-dir", default="src")
    args = parser.parse_args()

    contracts = list(REQUIRED_CONTRACTS)
    pending = []
    for contract in SOURCE_ACTIVATED_CONTRACTS:
        if os.path.isfile(os.path.join(args.src_dir, f"{contract}.sol")):
            contracts.append(contract)
        else:
            pending.append(contract)

    all_sites = []
    for contract in contracts:
        sites = check_contract(args.out_dir, args.src_dir, contract)
        if sites is None:
            return 1
        all_sites.extend((contract, *site) for site in sites)
    if not all_sites:
        print("check_full_range_lock: no modifyLiquidity sites found; check would pass vacuously", file=sys.stderr)
        return 1

    violations = []
    positive_sites = []
    zero_sites = []
    for contract, location, function, salt, delta in all_sites:
        if salt == "other":
            continue
        if salt != "full":
            violations.append(f"{location}: cannot prove modifyLiquidity salt is not {FULL_RANGE_SALT}")
            continue
        if delta == "zero":
            zero_sites.append(location)
        elif delta == "positive":
            positive_sites.append((contract, function, location))
            if (contract, function) not in POSITIVE_ALLOWLIST:
                violations.append(f"{location}: positive {FULL_RANGE_SALT} mutation outside graduation seed")
        elif delta == "negative":
            violations.append(f"{location}: negative {FULL_RANGE_SALT} mutation is forbidden")
        else:
            violations.append(f"{location}: cannot prove {FULL_RANGE_SALT} liquidityDelta sign")

    allowed_found = {(contract, function) for contract, function, _ in positive_sites}
    missing = POSITIVE_ALLOWLIST - allowed_found
    extras = len(positive_sites) - len(allowed_found)
    for contract, function in sorted(missing):
        violations.append(f"missing graduation seed allowlist site {contract}.{function}")
    if extras:
        violations.append("graduation seed appears more than once; exactly one positive full-range mutation is allowed")
    if not zero_sites:
        violations.append("missing zero-delta full-range fee collection site")

    for violation in violations:
        print(f"FAIL {violation}", file=sys.stderr)
    if violations:
        print(
            "check_full_range_lock: only zero-delta collection and the single graduation seed may use "
            f"{FULL_RANGE_SALT}",
            file=sys.stderr,
        )
        return 1

    suffix = ""
    if pending:
        suffix = f"; pending source not present: {', '.join(pending)}"
    print(
        f"check_full_range_lock: OK, {len(all_sites)} modifyLiquidity site(s), "
        f"{len(zero_sites)} zero-delta collection site(s), one graduation seed, no other full-range mutation{suffix}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
