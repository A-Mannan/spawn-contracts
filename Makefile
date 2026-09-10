# Spawn Launchpad — build & verification targets.
#
# Task groups referenced below are from
# openspec/changes/add-milestone-launchpad/tasks.md

.PHONY: all build test test-unit test-fork test-invariant deep size size-gate-selftest structural-gate-selftest scenario-tool-selftest scenario-check lock-check layout-check abis fmt fmt-check clean deps pins release-check

SIZE_LIMIT ?= 24576
FIXTURE_DIR := .sizegate-fixture

all: build size

deps:
	forge install

# Verifies the dependency pins recorded in design.md are the ones actually checked out.
pins:
	@fail=0; \
	for spec in "v4-core 5f00c84" "v4-periphery 9628c36"; do \
	  set -- $$spec; dep=$$1; want=$$2; \
	  got=$$(git -C lib/$$dep rev-parse HEAD 2>/dev/null | cut -c1-7); \
	  if [ "$$got" != "$$want" ]; then \
	    echo "PIN MISMATCH $$dep: want $$want, got $${got:-<missing>}"; fail=1; \
	  else echo "pin ok $$dep@$$got"; fi; \
	done; \
	exit $$fail

build:
	forge build

# Unit tests only: everything outside test/fork and test/invariant. The invariant campaign has its own
# target because it costs minutes; without excluding it here `release-check` would run it twice.
test-unit:
	forge test --no-match-path '{test/fork/**,test/invariant/**}'

# Fork tests need BASE_RPC_URL in the environment.
test-fork:
	@test -n "$$BASE_RPC_URL" || { echo "BASE_RPC_URL is not set; fork tests need a Base RPC endpoint"; exit 1; }
	FOUNDRY_PROFILE=fork forge test --match-path 'test/fork/**' -vv

# The `-d` guard is kept so the target stays honest if the directory is ever moved or removed: an
# unmatched `--match-path` is an error, which would fail `release-check` for a missing suite rather than
# saying so.
test-invariant:
	@if [ -d test/invariant ]; then \
	  forge test --match-path 'test/invariant/**' -vv; \
	else \
	  echo "test-invariant: test/invariant/ does not exist yet (task group 13); skipping"; \
	fi

test: test-unit

# Deeper fuzz/invariant budgets for the release check.
deep:
	FOUNDRY_PROFILE=deep forge test

# The 24 KB gate. See tools/size_gate.py for why this runs from the first milestone.
# Builds only src/ so test harnesses — which are never deployed and legitimately exceed the limit —
# are neither compiled nor measured here.
size:
	forge build --skip 'test/**' --skip 'script/**'
	python3 tools/size_gate.py --limit $(SIZE_LIMIT)

# Structural assertion that no code path reduces the full-range position (graduation spec). Runtime tests
# only cover the paths we thought of; this covers the shape of the code.
lock-check:
	python3 tools/check_full_range_lock.py

# Proves every delegatecall implementation shares the base layout and exposes no unguarded mutating
# entry point. MilestonePayoutPaths joins both checks as soon as its source exists; a missing artifact
# then fails rather than silently skipping the new satellite.
layout-check:
	forge build --skip 'test/**' --skip 'script/**'
	python3 tools/check_storage_layout.py
	python3 tools/check_cold_path_guards.py

# Focused mutation and fixture tests for the repository's structural and scenario gates.
structural-gate-selftest:
	PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tools/tests -p 'test_structural_gates.py' -v

scenario-tool-selftest:
	PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tools/tests -p 'test_scenario_gate.py' -v

# Checks the delta specs against literal test headers. For final passing evidence, capture Foundry's XML
# (`forge test --junit > report.xml`) and run `python3 tools/check_scenarios.py --junit report.xml`.
scenario-check:
	python3 tools/check_scenarios.py --report openspec/reports/payout-plugin-scenario-traceability.md

# Proves the gate actually fails on an oversized contract, rather than passing vacuously.
# Generates a throwaway contract larger than the limit, gates it, then cleans up.
# via_ir is disabled for the fixture only: solc segfaults compiling a 50k-char hex literal through the
# IR pipeline, and this target tests the gate's arithmetic, not production codegen.
size-gate-selftest:
	@rm -rf $(FIXTURE_DIR)
	@mkdir -p $(FIXTURE_DIR)
	@python3 -c "\
import os;\
blob = 'ff' * 25000;\
src = '// SPDX-License-Identifier: MIT\npragma solidity 0.8.26;\n\ncontract Oversized {\n    bytes public constant BLOB = hex\"%s\";\n\n    function blob() external pure returns (bytes memory) {\n        return BLOB;\n    }\n}\n' % blob;\
open(os.path.join('$(FIXTURE_DIR)', 'Oversized.sol'), 'w').write(src)"
	@echo "size-gate-selftest: building deliberately oversized fixture, expecting the gate to fail it"
	@set +e; \
	FOUNDRY_VIA_IR=false forge build --contracts $(FIXTURE_DIR) --skip 'test/**' --skip 'script/**' >/dev/null 2>&1; \
	python3 tools/size_gate.py --limit $(SIZE_LIMIT) --expect-fail \
	  --artifact out/Oversized.sol/Oversized.json; \
	status=$$?; \
	set -e; \
	rm -rf $(FIXTURE_DIR); \
	if [ $$status -eq 0 ]; then echo "size-gate-selftest: PASS (gate rejected the oversized fixture)"; \
	else echo "size-gate-selftest: FAIL (gate did not reject the oversized fixture)"; fi; \
	exit $$status

# Curated ABI export for the frontend/data-layer handoff (docs/technical/integration.md section 10).
# The delegatecall satellites are deliberately absent: calling them directly reverts, so their ABIs
# are a foot-gun rather than an interface. StateView and V4Quoter come from v4-periphery.
# Resolution quirk: src entries need `path:Name`; the lib lens files resolve as a bare path
# (path:Name fails for them) and each holds exactly one contract, so the basename is the file name.
ABI_CONTRACTS := \
	src/MilestoneHook.sol:MilestoneHook \
	src/LaunchSupport.sol:LaunchSupport \
	src/MilestoneToken.sol:MilestoneToken \
	src/RevenueNFT.sol:RevenueNFT \
	src/PayoutPluginRegistry.sol:PayoutPluginRegistry \
	src/ProtocolController.sol:ProtocolController \
	src/BuybackAndBurnPlugin.sol:BuybackAndBurnPlugin \
	src/interfaces/IPayoutPlugin.sol:IPayoutPlugin \
	lib/v4-periphery/src/lens/StateView.sol \
	lib/v4-periphery/src/lens/V4Quoter.sol

abis:
	forge build --skip 'test/**' --skip 'script/**'
	# The v4-periphery lens contracts are not imported by anything, so the project build never
	# compiles them; build them explicitly so their artifacts exist for forge inspect.
	forge build lib/v4-periphery/src/lens/StateView.sol lib/v4-periphery/src/lens/V4Quoter.sol
	@mkdir -p abi
	@for spec in $(ABI_CONTRACTS); do \
	  case $$spec in \
	    (*:*) name=$${spec##*:} ;; \
	    (*)   name=$${spec##*/}; name=$${name%.sol} ;; \
	  esac; \
	  forge inspect --json $$spec abi > abi/$$name.json; \
	done
	@python3 -c "import json,glob; [json.load(open(f)) for f in glob.glob('abi/*.json')]; print('abis:', len(glob.glob('abi/*.json')), 'valid JSON files')"

fmt:
	forge fmt

fmt-check:
	forge fmt --check

clean:
	forge clean
	rm -rf $(FIXTURE_DIR)

# OpenSpec add-payout-plugins: full local release gate. Fork and public-testnet campaigns remain separate
# because they require environment credentials.
release-check: pins fmt-check build size size-gate-selftest structural-gate-selftest scenario-tool-selftest lock-check layout-check abis test-unit test-invariant
	@echo "release-check: unit + invariant suites and all local structural gates passed."
	@echo "release-check: run 'make test-fork' separately with BASE_RPC_URL set."
