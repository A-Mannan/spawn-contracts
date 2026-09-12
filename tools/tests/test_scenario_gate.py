#!/usr/bin/env python3

import importlib.util
import io
import tempfile
import textwrap
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

TOOLS = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("check_scenarios", TOOLS / "check_scenarios.py")
SCENARIOS = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(SCENARIOS)


class ScenarioGateTests(unittest.TestCase):
    def fixture(self, specs, tests, junit=None, base_specs=None):
        directory = tempfile.TemporaryDirectory()
        root = Path(directory.name)
        spec_dir = root / "specs" / "capability"
        base_spec_dir = root / "base-specs" / "capability"
        test_dir = root / "test"
        spec_dir.mkdir(parents=True)
        base_spec_dir.mkdir(parents=True)
        test_dir.mkdir()
        (spec_dir / "spec.md").write_text(specs)
        if base_specs is not None:
            (base_spec_dir / "spec.md").write_text(base_specs)
        if isinstance(tests, dict):
            for name, source in tests.items():
                (test_dir / name).write_text(source)
        else:
            (test_dir / "Suite.t.sol").write_text(tests)
        junit_path = None
        if junit is not None:
            junit_path = root / "report.xml"
            junit_path.write_text(junit)
        return directory, spec_dir.parent, base_spec_dir.parent, test_dir, junit_path

    def test_inventory_is_derived_and_complete(self):
        hold, specs, base_specs, tests, _ = self.fixture(
            "#### Scenario: First\n#### Scenario: Second\n",
            textwrap.dedent(
                """
                contract Suite {
                    // --- Scenario: First ---
                    function test_first() public {}
                    // --- Scenario: Second ---
                    function test_second() public {}
                }
                """
            ),
        )
        self.addCleanup(hold.cleanup)
        result = SCENARIOS.inspect(specs, tests, base_spec_dir=base_specs)
        self.assertEqual(len(result["specs"]), 2)
        self.assertFalse(result["missing"])
        self.assertFalse(result["unknown"])

    def test_missing_unknown_duplicate_and_header_without_test_fail(self):
        hold, specs, base_specs, tests, _ = self.fixture(
            "#### Scenario: First\n#### Scenario: Missing\n",
            textwrap.dedent(
                """
                contract Suite {
                    // --- Scenario: First ---
                    function test_first() public {}
                    // --- Scenario: First ---
                    function test_duplicate() public {}
                    // --- Scenario: Renamed ---
                }
                """
            ),
        )
        self.addCleanup(hold.cleanup)
        result = SCENARIOS.inspect(specs, tests, base_spec_dir=base_specs)
        self.assertEqual([row["name"] for row in result["missing"]], ["Missing"])
        self.assertIn("First", result["duplicates"])
        self.assertEqual(result["unknown"][0]["name"], "Renamed")
        self.assertEqual(result["empty"][0]["name"], "Renamed")

    def test_junit_requires_passing_evidence(self):
        hold, specs, base_specs, tests, junit = self.fixture(
            "#### Scenario: Passes\n#### Scenario: Fails\n",
            textwrap.dedent(
                """
                contract Suite {
                    // --- Scenario: Passes ---
                    function test_passes() public {}
                    // --- Scenario: Fails ---
                    function test_fails() public {}
                }
                """
            ),
            textwrap.dedent(
                """
                <testsuites><testsuite>
                  <testcase classname="Suite" name="test_passes()"/>
                  <testcase classname="Suite" name="test_fails()"><failure/></testcase>
                </testsuite></testsuites>
                """
            ),
        )
        self.addCleanup(hold.cleanup)
        result = SCENARIOS.inspect(specs, tests, [junit], base_spec_dir=base_specs)
        self.assertEqual([row[0]["name"] for row in result["nonpassing"]], ["Fails"])

        output = io.StringIO()
        with redirect_stdout(output):
            self.assertEqual(SCENARIOS.report(result), 1)
        self.assertIn("literal coverage: 2/2", output.getvalue())
        self.assertIn("passing evidence: 1/2", output.getvalue())

    def test_foundry_junit_infers_contract_from_suite_name(self):
        hold, specs, base_specs, tests, junit = self.fixture(
            "#### Scenario: Foundry shape\n",
            textwrap.dedent(
                """
                contract FoundrySuite {
                    // --- Scenario: Foundry shape ---
                    function test_foundryShape() public {}
                }
                """
            ),
            textwrap.dedent(
                """
                <testsuites><testsuite name="test/unit/Foundry.t.sol:FoundrySuite">
                  <testcase name="test_foundryShape()"/>
                </testsuite></testsuites>
                """
            ),
        )
        self.addCleanup(hold.cleanup)
        result = SCENARIOS.inspect(specs, tests, [junit], base_spec_dir=base_specs)
        self.assertFalse(result["nonpassing"])

    def test_missing_scenario_is_not_counted_as_passing_evidence(self):
        hold, specs, base_specs, tests, junit = self.fixture(
            "#### Scenario: Claimed\n#### Scenario: Missing\n",
            textwrap.dedent(
                """
                contract Suite {
                    // --- Scenario: Claimed ---
                    function test_claimed() public {}
                }
                """
            ),
            '<testsuites><testsuite><testcase classname="Suite" name="test_claimed()"/>'
            '</testsuite></testsuites>',
        )
        self.addCleanup(hold.cleanup)
        result = SCENARIOS.inspect(specs, tests, [junit], base_spec_dir=base_specs)
        output = io.StringIO()
        with redirect_stdout(output):
            self.assertEqual(SCENARIOS.report(result), 1)
        self.assertIn("literal coverage: 1/2", output.getvalue())
        self.assertIn("passing evidence: 1/2", output.getvalue())

    def test_unchanged_base_scenario_is_recognised_but_not_required(self):
        hold, specs, base_specs, tests, _ = self.fixture(
            "## ADDED Requirements\n### Requirement: New behavior\n#### Scenario: New\n",
            textwrap.dedent(
                """
                contract Suite {
                    // --- Scenario: New ---
                    function test_new() public {}
                    // --- Scenario: Carried ---
                    function test_carried() public {}
                }
                """
            ),
            base_specs="### Requirement: Existing behavior\n#### Scenario: Carried\n",
        )
        self.addCleanup(hold.cleanup)
        result = SCENARIOS.inspect(specs, tests, base_spec_dir=base_specs)
        self.assertFalse(result["missing"])
        self.assertFalse(result["unknown"])
        self.assertEqual([row["name"] for row in result["carried_headers"]], ["Carried"])

    def test_private_helper_header_is_attributed_to_calling_test(self):
        hold, specs, base_specs, tests, junit = self.fixture(
            "#### Scenario: Through helper\n",
            textwrap.dedent(
                """
                contract Suite {
                    // --- Scenario: Through helper ---
                    function _stage() private {}

                    function _middle() private {
                        _stage();
                    }

                    function test_entry() public {
                        _middle();
                    }

                    function test_unrelated() public {}
                }
                """
            ),
            textwrap.dedent(
                """
                <testsuites><testsuite>
                  <testcase classname="Suite" name="test_entry()"/>
                </testsuite></testsuites>
                """
            ),
        )
        self.addCleanup(hold.cleanup)
        result = SCENARIOS.inspect(specs, tests, [junit], base_spec_dir=base_specs)
        self.assertEqual(result["headers"][0]["tests"], [("Suite", "test_entry")])
        self.assertFalse(result["empty"])
        self.assertFalse(result["nonpassing"])

        junit.write_text(
            '<testsuites><testsuite><testcase classname="Suite" name="test_unrelated()"/>'
            '</testsuite></testsuites>'
        )
        unrelated = SCENARIOS.inspect(specs, tests, [junit], base_spec_dir=base_specs)
        self.assertEqual([row[0]["name"] for row in unrelated["nonpassing"]], ["Through helper"])
        self.assertEqual(unrelated["nonpassing"][0][1], [("Suite", "test_entry")])

    def test_duplicate_detection_is_scoped_to_file_and_contract(self):
        hold, specs, base_specs, tests, _ = self.fixture(
            "#### Scenario: Shared\n#### Scenario: Repeated\n",
            {
                "First.t.sol": textwrap.dedent(
                    """
                    contract First {
                        // --- Scenario: Shared ---
                        function test_sharedFirst() public {}
                        // --- Scenario: Repeated ---
                        function test_repeatedFirst() public {}
                        // --- Scenario: Repeated ---
                        function test_repeatedAgain() public {}
                    }
                    """
                ),
                "Second.t.sol": textwrap.dedent(
                    """
                    contract Second {
                        // --- Scenario: Shared ---
                        function test_sharedSecond() public {}
                    }
                    """
                ),
            },
        )
        self.addCleanup(hold.cleanup)
        result = SCENARIOS.inspect(specs, tests, base_spec_dir=base_specs)
        self.assertNotIn("Shared", result["duplicates"])
        self.assertEqual(len(result["duplicates"]["Repeated"]), 2)
        self.assertEqual({row["contract"] for row in result["duplicates"]["Repeated"]}, {"First"})

        strict_stdout = io.StringIO()
        strict_stderr = io.StringIO()
        with redirect_stdout(strict_stdout), redirect_stderr(strict_stderr):
            self.assertEqual(SCENARIOS.report(result), 1)
        duplicate_line = next(line for line in strict_stderr.getvalue().splitlines() if line.startswith("DUPLICATE-ONLY"))
        self.assertRegex(
            duplicate_line,
            r"^DUPLICATE-ONLY Repeated: .*/First\.t\.sol:\d+, .*/First\.t\.sol:\d+$",
        )

        permissive_stdout = io.StringIO()
        permissive_stderr = io.StringIO()
        with redirect_stdout(permissive_stdout), redirect_stderr(permissive_stderr):
            self.assertEqual(SCENARIOS.report(result, strict_duplicates=False), 0)
        self.assertEqual(permissive_stderr.getvalue(), strict_stderr.getvalue())

    def test_repository_inventory_is_225_unique_scenarios(self):
        root = TOOLS.parent
        scenarios = SCENARIOS.load_specs(root / "openspec/changes/add-payout-plugins/specs")
        self.assertEqual(len(scenarios), 225)
        self.assertEqual(len({row["name"] for row in scenarios}), 225)


if __name__ == "__main__":
    unittest.main()
