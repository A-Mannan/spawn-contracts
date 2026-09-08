// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {LaunchpadTest} from "../Fixtures.sol";
import {MilestoneBase} from "../../src/MilestoneBase.sol";
import {FeeLib} from "../../src/libraries/FeeLib.sol";
import {Bounds, LaunchConfig} from "../../src/types/LaunchTypes.sol";

/// @notice The completion-triggered base fee step-down (task 17.5).
///
/// @dev Since Decision 20 removed the anti-snipe decay and with it the `beforeSwap` fee override, the
/// pool's stored dynamic LP fee is the whole story: there is nothing left that can shadow it for one swap,
/// so `_baseFeeOf` is both what the hook recorded and what a trader pays. That is what lets these tests
/// assert against the pool rather than against the hook's own copy — and both are checked, because a
/// divergence between them is exactly the bug `updateDynamicLPFee` exists to prevent.
///
/// The schedule under test is the default template's: 1% base, stepping to 0.5% at eight completions and
/// 0.25% at sixteen. Only the first threshold is reachable at the default 20% buyback share — see
/// `openspec/reports/verification-findings-g16-g17.md` §3, which measures why, and which also measures the
/// split that does reach the second: the buyback at its 10% floor. The threshold scenarios therefore use
/// the fixture's own pool, being about a threshold rather than about a particular one, while the floor
/// scenario relaunches at that floor, being specifically about the last step.
contract FeeStepDownTest is LaunchpadTest {
    /// @dev Levels past a band's top to aim a completing buy at: decisive, and well short of the next
    /// band's floor, which is `bandLevelSpacing - bandWidthLevels` away.
    int24 private constant PAST_TOP = 300;

    /// @dev Per-round ETH, generous enough that every round of the walk is limit-bounded rather than
    /// budget-bounded.
    uint256 private constant ROUND_BUDGET = 20_000 ether;

    /// @dev Round ceiling for the walk. §3 measured sixteen completions at round seventeen; the headroom is
    /// there so that a regression stalls the test with a message rather than spinning.
    uint256 private constant MAX_ROUNDS = 40;

    /// @dev `BaseFeeStepped` indexes only the pool, so the three interesting fields are all in `data`.
    function _steps(Vm.Log[] memory logs)
        internal
        pure
        returns (uint32[] memory at, uint24[] memory from, uint24[] memory to)
    {
        uint256 n = _countLogs(logs, MilestoneBase.BaseFeeStepped.selector);
        at = new uint32[](n);
        from = new uint24[](n);
        to = new uint24[](n);
        uint256 k;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] != MilestoneBase.BaseFeeStepped.selector) continue;
            (at[k], from[k], to[k]) = abi.decode(logs[i].data, (uint32, uint24, uint24));
            k += 1;
        }
    }

    // --- Scenario: Base fee steps down at the completion threshold ---

    /// @dev An unlimited 5,000 ETH buy deploys the cap's eight bands and completes all eight in the same
    /// transaction, so the threshold is crossed by the last harvest of one sweep. That is the sharpest
    /// available form of "from that harvest onward": the step-down log must sit *after* every harvest log,
    /// because `_applyFeeStep` runs inside the eighth harvest and not on any earlier one.
    function test_baseFeeStepsDownAtTheCompletionThreshold() public {
        _graduate();

        uint24 base = template.baseFeeHundredthsBip;
        assertEq(_baseFeeOf(poolId), base, "the pool opens at the template's base fee");
        assertEq(hook.poolState(poolId).baseFeeHundredthsBip, base, "and the hook agrees");

        vm.recordLogs();
        _buy(5_000 ether);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint32 threshold = template.feeStepOneAtCompletions;
        assertEq(hook.poolState(poolId).completedMilestones, threshold, "the sweep reached the threshold");

        (uint32[] memory at, uint24[] memory from, uint24[] memory to) = _steps(logs);
        assertEq(at.length, 1, "one step, for one threshold reached");
        assertEq(at[0], threshold, "recorded against the completion count that triggered it");
        assertEq(from[0], base, "stepping from the template's base fee");
        assertEq(to[0], template.feeStepOneFee, "to the first step's value");

        assertGt(
            _firstLogAt(logs, MilestoneBase.BaseFeeStepped.selector),
            _lastLogAt(logs, MilestoneBase.MilestoneHarvested.selector),
            "the step fired on the harvest that reached the threshold, not an earlier one"
        );

        assertEq(_baseFeeOf(poolId), template.feeStepOneFee, "the pool now charges the step's value");
        assertEq(hook.poolState(poolId).baseFeeHundredthsBip, template.feeStepOneFee, "and the hook records it");
    }

    // --- Scenario: Base fee is unchanged between thresholds ---

    /// @dev Three completions, which is not a threshold. `BaseFeeStepped` is only emitted when the value
    /// actually changes, so its absence across three harvests is the observable form of the requirement —
    /// there is no "stepped to the same value" event to distinguish from a no-op.
    function test_baseFeeIsUnchangedBetweenThresholds() public {
        _graduate();

        vm.recordLogs();
        _buyToLevel(2_000 ether, _bandUpper(2) + 50);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint32 completed = hook.poolState(poolId).completedMilestones;
        assertEq(completed, 3, "three milestones completed");
        assertLt(completed, template.feeStepOneAtCompletions, "short of the first threshold");

        assertEq(_countLogs(logs, MilestoneBase.MilestoneHarvested.selector), 3, "and each one harvested");
        assertEq(_countLogs(logs, MilestoneBase.BaseFeeStepped.selector), 0, "no step was emitted");
        assertEq(_baseFeeOf(poolId), template.baseFeeHundredthsBip, "the base fee is unchanged");
    }

    // --- Scenario: Fee never falls below the floor ---

    /// @dev Relaunches the fixture's pool with the buyback at its floor, then graduates it. Re-points
    /// `poolId`/`key`/`token` so every inherited helper follows; the CREATE2 token salt derives from the
    /// config hash, so the differing split is enough to avoid colliding with the pool `setUp` launched.
    function _relaunchAtTheBuybackFloor() private {
        LaunchConfig memory config = _defaultConfig("Floor", "FLR");
        config.harvestSplit = _split(0.6e18, uint64(Bounds.MIN_BUYBACK_HARVEST_SHARE_WAD), 0.1e18);
        (poolId, key, token) = _launchDirect(config);
        _graduate();
    }

    /// @dev One round of the walk: a single buy aimed just past the top of the lowest band whose top is
    /// still above spot. That is the regime §3 measured — one band per swap keeps each harvest's buy-back as
    /// small as the mechanism allows, and a larger buy-back is precisely what consumes band indices without
    /// completing them. The target is found from spot rather than from the cursor, because a skip advances
    /// the cursor past bands the price has already left behind. The router is topped up each round because
    /// §3's stall was on harness funds rather than on any protocol limit.
    function _round() private {
        int24 spot = _level();
        uint256 i = hook.poolState(poolId).nextBandIndex;
        uint256 ceiling = i + 16;
        while (i < ceiling && _bandUpper(i) + PAST_TOP <= spot) i += 1;
        assertLt(i, ceiling, "a band above spot within sixteen indices of the cursor");

        vm.deal(address(router), 100_000 ether);
        _buyToLevel(ROUND_BUDGET, _bandUpper(i) + PAST_TOP);
    }

    function _walkTo(uint32 targetCompletions) private {
        for (uint256 round = 0; round < MAX_ROUNDS; round++) {
            if (hook.poolState(poolId).completedMilestones >= targetCompletions) return;
            _round();
        }
        assertGe(
            hook.poolState(poolId).completedMilestones, targetCompletions, "the walk stalled short of the threshold"
        );
    }

    function _walkRounds(uint256 rounds) private {
        for (uint256 round = 0; round < rounds; round++) {
            _round();
        }
    }

    /// @dev The one test here that cannot use the fixture's own pool, for the reason §3 measures: at the
    /// default 20% buyback each harvest's buy-back runs price past the following band floors, so those bands
    /// are skipped rather than deployed and indices are consumed faster than completions accrue. Sixteen
    /// completions are reached at the 10% buyback floor.
    ///
    /// "No further reduction occurs" is asserted three ways, because no one of them says it alone: the walk
    /// to the threshold emits two steps and no third, the rounds past it emit none, and the schedule
    /// evaluated at the largest representable completion count still returns the same value — which is what
    /// makes the second step's value a floor at *any* count, not merely at the counts a unit fixture can
    /// reach. The count is asserted monotone rather than strictly rising afterwards on purpose: whether the
    /// ladder still has bands left to complete is a cap question, and this scenario is not about the cap.
    function test_feeNeverFallsBelowTheFloor() public {
        _relaunchAtTheBuybackFloor();

        uint32 threshold = template.feeStepTwoAtCompletions;
        assertEq(_baseFeeOf(poolId), template.baseFeeHundredthsBip, "the pool opens at the template's base fee");

        vm.recordLogs();
        _walkTo(threshold);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint32 completed = hook.poolState(poolId).completedMilestones;
        assertGe(completed, threshold, "the walk reached the last threshold");

        (uint32[] memory at, uint24[] memory from, uint24[] memory to) = _steps(logs);
        assertEq(at.length, 2, "the template's two steps fired, and there is no third");
        assertEq(at[0], template.feeStepOneAtCompletions, "the first at its own threshold");
        assertEq(from[0], template.baseFeeHundredthsBip, "stepping from the opening fee");
        assertEq(to[0], template.feeStepOneFee, "to the first step's value");
        assertEq(at[1], threshold, "the second at its own threshold");
        assertEq(from[1], template.feeStepOneFee, "stepping from where the first step left the fee");
        assertEq(to[1], template.feeStepTwoFee, "to the schedule's final value");

        assertEq(_baseFeeOf(poolId), template.feeStepTwoFee, "the pool charges the schedule's final value");
        assertEq(hook.poolState(poolId).baseFeeHundredthsBip, template.feeStepTwoFee, "and the hook records it");
        assertGe(template.feeStepTwoFee, 2_500, "which is at or above the 0.25% floor the requirement names");

        // Past the last threshold.
        vm.recordLogs();
        _walkRounds(3);
        Vm.Log[] memory later = vm.getRecordedLogs();

        assertGe(hook.poolState(poolId).completedMilestones, completed, "the completion count never fell");
        assertEq(_countLogs(later, MilestoneBase.BaseFeeStepped.selector), 0, "no third step fired");
        assertEq(_baseFeeOf(poolId), template.feeStepTwoFee, "and the fee did not fall further");

        assertEq(
            FeeLib.steppedBaseFee(
                template.baseFeeHundredthsBip,
                template.feeStepOneAtCompletions,
                template.feeStepOneFee,
                template.feeStepTwoAtCompletions,
                template.feeStepTwoFee,
                type(uint32).max
            ),
            template.feeStepTwoFee,
            "the schedule returns that same value at any completion count"
        );
    }

    // --- Scenario: Step-downs do not reverse ---

    /// @dev Structural rather than incidental, and the test is written to say which. The schedule is
    /// evaluated from the completion count, the count only rises, and `_applyFeeStep` returns early unless
    /// the new value is strictly lower — so there are two independent reasons a falling price cannot raise
    /// the fee. What the test can observe is the conjunction: the price retraces the whole range it just
    /// climbed, in both directions, and neither the pool's fee nor the hook's copy moves.
    function test_stepDownsDoNotReverse() public {
        _graduate();

        _buy(5_000 ether);
        uint24 stepped = template.feeStepOneFee;
        assertEq(_baseFeeOf(poolId), stepped, "the fee stepped down");
        uint32 completedAtStep = hook.poolState(poolId).completedMilestones;

        // All the way back below the first band's floor: every completed band's range is retraced
        // downward, which is the condition under which a count-free implementation would un-step.
        vm.recordLogs();
        _sellAllToLevel(_bandLower(0) - 1_000);
        // And back up through the same range again.
        _buyToLevel(2_000 ether, _bandUpper(3) + 50);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(_countLogs(logs, MilestoneBase.BaseFeeStepped.selector), 0, "no step-down was undone");
        assertEq(_baseFeeOf(poolId), stepped, "the pool still charges the stepped fee");
        assertEq(hook.poolState(poolId).baseFeeHundredthsBip, stepped, "and the hook still records it");
        assertGe(
            hook.poolState(poolId).completedMilestones,
            completedAtStep,
            "the completion count the schedule reads never fell"
        );
        assertLe(_baseFeeOf(poolId), template.baseFeeHundredthsBip, "and it never returned to the opening fee");
    }
}
