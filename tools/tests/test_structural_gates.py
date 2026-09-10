#!/usr/bin/env python3

import copy
import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

TOOLS = Path(__file__).resolve().parents[1]


def load_tool(name: str):
    spec = importlib.util.spec_from_file_location(name, TOOLS / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


GUARDS = load_tool("check_cold_path_guards")
LAYOUT = load_tool("check_storage_layout")


class GuardCheckerTests(unittest.TestCase):
    def artifact(self, functions, abi=None, methods=None):
        return {
            "ast": {
                "nodes": [
                    {
                        "nodeType": "ContractDefinition",
                        "name": "MilestonePayoutPaths",
                        "nodes": functions,
                    }
                ]
            },
            "abi": abi or [],
            "methodIdentifiers": methods or {},
        }

    def function(self, name, selector, guarded=True):
        return {
            "nodeType": "FunctionDefinition",
            "name": name,
            "kind": "function",
            "visibility": "external",
            "stateMutability": "nonpayable",
            "implemented": True,
            "functionSelector": selector,
            "modifiers": ([{"modifierName": {"name": "onlyDelegated"}}] if guarded else []),
        }

    def test_overload_is_checked_by_complete_signature(self):
        guarded = self.function("flush", "11111111", guarded=True)
        unguarded = self.function("flush", "22222222", guarded=False)
        abi = [
            {"type": "function", "name": "flush", "stateMutability": "nonpayable", "inputs": [{"type": "bytes32"}]},
            {"type": "function", "name": "flush", "stateMutability": "nonpayable", "inputs": [{"type": "address"}]},
        ]
        methods = {"flush(bytes32)": "11111111", "flush(address)": "22222222"}
        result = GUARDS.check_contract(
            self.artifact([guarded, unguarded], abi, methods),
            "MilestonePayoutPaths",
            "src/MilestonePayoutPaths.sol",
        )
        self.assertEqual(result[0], ["flush(bytes32)"])
        self.assertEqual(result[1], ["src/MilestonePayoutPaths.sol: flush(address)"])


class StorageLayoutTests(unittest.TestCase):
    def test_type_width_is_not_normalized_away(self):
        base = [(0, 0, "amount", LAYOUT.normalize_type("t_uint128"))]
        derived = [(0, 0, "amount", LAYOUT.normalize_type("t_uint256"))]
        self.assertTrue(LAYOUT.diff(base, derived, "MilestonePayoutPaths"))

    def test_user_defined_ast_ids_are_normalized(self):
        self.assertEqual(
            LAYOUT.normalize_type("t_struct(PoolState)123_storage"),
            LAYOUT.normalize_type("t_struct(PoolState)456_storage"),
        )


class SizeGateTests(unittest.TestCase):
    def test_missing_payout_artifact_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            completed = subprocess.run(
                [sys.executable, str(TOOLS / "size_gate.py"), "--out-dir", directory],
                capture_output=True,
                text=True,
                check=False,
            )
        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("MilestonePayoutPaths.json", completed.stderr)


class FullRangeLockTests(unittest.TestCase):
    def fixture(self):
        with open(TOOLS.parent / "out/MilestoneColdPaths.sol/MilestoneColdPaths.json") as handle:
            return json.load(handle)

    def seed_function(self, artifact):
        contract = next(node for node in artifact["ast"]["nodes"] if node.get("name") == "MilestoneColdPaths")
        return next(node for node in contract["nodes"] if node.get("name") == "_seedFullRange")

    def calls(self, function):
        return [node for node in load_tool("check_full_range_lock").walk(function["body"]) if node.get("nodeType") == "FunctionCall"]

    def params(self, function):
        lock = load_tool("check_full_range_lock")
        values = lock.declaration_values(function)
        call = next(node for node in lock.walk(function["body"]) if lock.is_modify_liquidity(node))
        return lock, values, lock.modify_params(call, values)

    def test_compounding_fixture_fails_gate(self):
        with tempfile.TemporaryDirectory() as directory:
            out_dir = Path(directory)
            for contract in (
                "MilestoneBase",
                "MilestoneHook",
                "MilestoneColdPaths",
                "MilestonePayoutPaths",
            ):
                source = TOOLS.parent / f"out/{contract}.sol/{contract}.json"
                target = out_dir / f"{contract}.sol/{contract}.json"
                target.parent.mkdir()
                target.write_bytes(source.read_bytes())

            artifact_path = out_dir / "MilestoneColdPaths.sol/MilestoneColdPaths.json"
            artifact = json.loads(artifact_path.read_text())
            compound = copy.deepcopy(self.seed_function(artifact))
            compound["name"] = "_compoundFullRange"
            contract = next(node for node in artifact["ast"]["nodes"] if node.get("name") == "MilestoneColdPaths")
            contract["nodes"].append(compound)
            artifact_path.write_text(json.dumps(artifact))

            completed = subprocess.run(
                [
                    sys.executable,
                    str(TOOLS / "check_full_range_lock.py"),
                    "--out-dir",
                    str(out_dir),
                    "--src-dir",
                    str(TOOLS.parent / "src"),
                ],
                capture_output=True,
                text=True,
                check=False,
            )
        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("positive FULL_RANGE_SALT mutation outside graduation seed", completed.stderr)

    def test_graduation_seed_is_positive(self):
        function = self.seed_function(self.fixture())
        lock, values, params = self.params(function)
        self.assertEqual(lock.salt_kind(params[1], values), "full")
        self.assertEqual(lock.delta_kind(params[0], values), "positive")

    def test_negative_full_range_delta_is_detected(self):
        function = self.seed_function(copy.deepcopy(self.fixture()))
        lock, _, params = self.params(function)
        positive = params[0]
        negative = {
            "nodeType": "UnaryOperation",
            "operator": "-",
            "subExpression": copy.deepcopy(positive),
            "typeDescriptions": {"typeString": "int256"},
        }
        params_call = next(
            node
            for node in lock.walk(function["body"])
            if node.get("kind") == "structConstructorCall"
            and "liquidityDelta" in node.get("names", [])
            and "salt" in node.get("names", [])
        )
        index = params_call["names"].index("liquidityDelta")
        params_call["arguments"][index] = negative
        lock, values, params = self.params(function)
        self.assertEqual(lock.delta_kind(params[0], values), "negative")


if __name__ == "__main__":
    unittest.main()
