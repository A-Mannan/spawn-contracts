// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {MilestoneBase} from "../../src/MilestoneBase.sol";
import {FeeLib} from "../../src/libraries/FeeLib.sol";
import {Bounds, FeeStep} from "../../src/types/LaunchTypes.sol";
import {SwapFeesFixture} from "./SwapFees.t.sol";

/// @notice Shared shaping for tasks 10.5 and 10.6 — a two-step "trust earned" fee schedule.
///
/// @dev The buyback share is zeroed throughout. A harvest's buyback is an *unbounded* nested buy, and on a
/// ladder walked band by band it routinely carries the price several thousand levels past where the
/// triggering swap stopped — far enough to jump the next band entirely, which would make a four-milestone
/// walk a race against the overshoot rather than a test of the schedule. Nothing about the fee schedule
/// depends on the buyback; `MilestoneHarvest.t.sol` is where the buyback itself is exercised.
abstract contract FeeScheduleFixture is SwapFeesFixture {
    uint24 internal constant START_FEE = 15_000; // 1.5%, the schedule's permitted maximum
    uint24 internal constant FIRST_STEP = 10_000; // 1%
    uint24 internal constant FINAL_STEP = 5_000; // 0.5%, comfortably above the 0.25% floor

    function _configure(MilestoneBase.LaunchParams memory p) internal pure virtual override {
        p.config.harvestSplit.creatorWad = 0.6e18;
        p.config.harvestSplit.buybackWad = 0;
        p.config.harvestSplit.protocolWad = 0.1e18;
        p.config.harvestSplit.lpWad = 0.3e18;

        p.config.feeSchedule.enabled = true;
        p.config.feeSchedule.startFeeHundredthsBip = START_FEE;
        p.config.feeSchedule.stepCount = 2;
        p.config.feeSchedule.steps[0] = FeeStep({atCompletions: 1, feeHundredthsBip: FIRST_STEP});
        p.config.feeSchedule.steps[1] = FeeStep({atCompletions: 3, feeHundredthsBip: FINAL_STEP});
    }

    /// @dev The anti-snipe override the hook would return right now, flag stripped, computed against the
    /// pool's *current* stored base fee. Zero means "no override", so the pool charges the base fee.
    function _bareOverride() internal view returns (uint24) {
        return FeeLib.antiSnipeOverride(
            hook.launchConfig(poolId).antiSnipeWindowSeconds,
            uint64(launchTime),
            hook.poolState(poolId).baseFeeHundredthsBip,
            block.timestamp
        ) & LPFeeLibrary.REMOVE_OVERRIDE_MASK;
    }
}

/// @notice Unit tests for task 10.5 — the milestone-completion fee schedule.
contract FeeScheduleTest is FeeScheduleFixture {
    // --- Scenario (swap-fees): Milestone schedule sets the starting base fee ---

    function test_theScheduleSetsTheStartingBaseFee() public view {
        assertEq(_storedLpFee(), START_FEE, "the pool opens at the schedule's start fee, not the 1% default");
        assertEq(hook.poolState(poolId).baseFeeHundredthsBip, START_FEE, "and the hook's record agrees");
        assertEq(hook.poolState(poolId).completedMilestones, 0, "with no completions behind it");
    }

    // --- Scenario: Base fee steps down at the completion threshold ---

    function test_baseFeeStepsDownAtTheCompletionThreshold() public {
        Vm.Log[] memory logs = _completeMilestone(0);
        Stepped memory s = _steppedFromLogs(logs);

        assertTrue(s.seen, "the crossing harvest announced the step");
        assertEq(s.completedMilestones, 1, "at the first completion");
        assertEq(s.previousFee, START_FEE, "from the start fee");
        assertEq(s.newFee, FIRST_STEP, "to the first step's value");

        assertEq(_storedLpFee(), FIRST_STEP, "and the pool stores it");
        assertEq(hook.poolState(poolId).baseFeeHundredthsBip, FIRST_STEP, "as does the hook");

        // Stored is one thing; charged is the claim worth making. The window has long elapsed here, so no
        // override is returned and traders pay exactly the stepped base fee.
        assertEq(_bareOverride(), 0, "no anti-snipe override outside the window");
        assertApproxEqAbs(
            _sellAndMeasureFee(MEASURED_SELL),
            _feeOn(MEASURED_SELL, FIRST_STEP),
            1e9,
            "so a trader is charged the stepped fee"
        );
    }

    /// @dev The step is applied *at the harvest*, in the same transaction as the crossing swap — not on a
    /// later poke, and not by anyone having to call anything.
    function test_theStepIsAppliedInTheHarvestTransaction() public {
        _deployBand(0);
        (, int24 upper) = _bandLevels(0);
        assertEq(_storedLpFee(), START_FEE, "unstepped while the band is merely live");

        vm.recordLogs();
        _buyToLevel(upper + 200);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(_countLogs(logs, MilestoneBase.MilestoneHarvested.selector), 1, "the swap harvested the band");
        assertEq(_countLogs(logs, MilestoneBase.BaseFeeStepped.selector), 1, "and stepped the fee in the same call");
        assertEq(_storedLpFee(), FIRST_STEP, "which the pool already reflects");
    }

    // --- Scenario: Base fee is unchanged between thresholds ---

    function test_baseFeeIsUnchangedBetweenThresholds() public {
        _completeMilestone(0);
        assertEq(_storedLpFee(), FIRST_STEP, "stepped once");

        // The second completion is not a configured threshold, so it must move nothing — and the absence of
        // the event is the observable form of that: the emit only fires when the value actually changes.
        Vm.Log[] memory logs = _completeMilestone(1);

        assertFalse(_steppedFromLogs(logs).seen, "no step was announced");
        assertEq(_storedLpFee(), FIRST_STEP, "and the fee is exactly where it was");
        assertEq(hook.poolState(poolId).baseFeeHundredthsBip, FIRST_STEP, "in the hook's record too");
        assertEq(hook.poolState(poolId).completedMilestones, 2, "even though a milestone really did complete");
    }

    // --- Scenario: Fee never falls below the configured floor ---

    function test_feeNeverFallsBelowTheConfiguredFloor() public {
        _completeMilestone(0);
        _completeMilestone(1);
        Stepped memory s = _steppedFromLogs(_completeMilestone(2));

        assertTrue(s.seen, "the third completion reached the final step");
        assertEq(s.previousFee, FIRST_STEP, "from the first step");
        assertEq(s.newFee, FINAL_STEP, "onto the schedule's last value");
        assertEq(_storedLpFee(), FINAL_STEP, "which the pool charges");
        assertGe(FINAL_STEP, Bounds.MIN_SCHEDULE_FLOOR_FEE, "and which is at or above the protocol floor");

        // A schedule is exhausted after its last step, so further completions reduce nothing.
        Vm.Log[] memory more = _completeMilestone(3);

        assertFalse(_steppedFromLogs(more).seen, "no further reduction is even attempted");
        assertEq(_storedLpFee(), FINAL_STEP, "the schedule's final value is final");
        assertEq(hook.poolState(poolId).completedMilestones, 4, "with four milestones behind it");
        assertApproxEqAbs(
            _sellAndMeasureFee(MEASURED_SELL), _feeOn(MEASURED_SELL, FINAL_STEP), 1e9, "and traders pay 0.5%"
        );
    }

    // --- Scenario: Step-downs do not reverse ---

    function test_stepDownsDoNotReverseWhenThePriceFallsBack() public {
        _completeMilestone(0);
        assertEq(_storedLpFee(), FIRST_STEP, "stepped down");

        // All the way back down through the band that was just completed, and below graduation.
        _sellToLevel(graduationLevel - 2_000);
        assertLt(_level(), graduationLevel, "the price really did fall back");

        assertEq(_storedLpFee(), FIRST_STEP, "the fee did not climb back");
        assertEq(hook.poolState(poolId).baseFeeHundredthsBip, FIRST_STEP, "in the hook's record either");
        assertEq(hook.poolState(poolId).completedMilestones, 1, "and the completion still counts");

        // Nor does buying back up re-step it: the schedule is a function of the completion count, which is
        // forward-only, rather than of where the price happens to be.
        _buyToLevel(graduationLevel + 1_000);
        assertEq(_storedLpFee(), FIRST_STEP, "still the stepped value");
        assertEq(hook.poolState(poolId).completedMilestones, 1, "with no completion double-counted");
    }

    function test_theBaseFeeIsMonotonicAcrossTheWholeWalk() public {
        uint24 previous = _storedLpFee();

        for (uint256 i = 0; i < 4; i++) {
            _completeMilestone(i);

            uint24 current = _storedLpFee();
            assertLe(current, previous, "the base fee never rises");
            assertEq(
                current,
                FeeLib.scheduledBaseFee(hook.launchConfig(poolId).feeSchedule, uint32(i) + 1),
                "and always equals the schedule evaluated at the completion count"
            );
            previous = current;
        }

        assertEq(previous, FINAL_STEP, "ending on the schedule's final value");
    }
}

/// @notice Task 10.5's negative case: the schedule defaults to disabled.
contract FeeScheduleDisabledTest is SwapFeesFixture {
    /// @dev Only the buyback is zeroed, for the walk-determinism reason `FeeScheduleFixture` explains. The
    /// fee schedule is left exactly as the library default leaves it, which is off.
    function _configure(MilestoneBase.LaunchParams memory p) internal pure override {
        p.config.harvestSplit.creatorWad = 0.6e18;
        p.config.harvestSplit.buybackWad = 0;
        p.config.harvestSplit.protocolWad = 0.1e18;
        p.config.harvestSplit.lpWad = 0.3e18;
    }

    // --- Scenario: Disabled schedule leaves the base fee constant ---

    function test_disabledScheduleLeavesTheBaseFeeConstant() public {
        assertFalse(hook.launchConfig(poolId).feeSchedule.enabled, "no schedule was configured");
        assertEq(_storedLpFee(), Bounds.DEFAULT_BASE_FEE, "so the pool opens at the 1% default");

        for (uint256 i = 0; i < 3; i++) {
            Vm.Log[] memory logs = _completeMilestone(i);

            assertFalse(_steppedFromLogs(logs).seen, "no step is ever announced");
            assertEq(_storedLpFee(), Bounds.DEFAULT_BASE_FEE, "and the base fee does not move");
            assertEq(hook.poolState(poolId).baseFeeHundredthsBip, Bounds.DEFAULT_BASE_FEE, "in either place");
        }

        assertEq(hook.poolState(poolId).completedMilestones, 3, "three milestones completed all the same");
        assertApproxEqAbs(
            _sellAndMeasureFee(MEASURED_SELL),
            _feeOn(MEASURED_SELL, Bounds.DEFAULT_BASE_FEE),
            1e9,
            "and traders are still charged 1%"
        );
    }
}

/// @notice Unit tests for task 10.6 — precedence between the anti-snipe decay and the milestone schedule.
///
/// @dev Graduates ten seconds into a sixty-second window, so the whole of the first milestone happens while
/// the decay is still running. That is the only configuration in which the two mechanisms are simultaneously
/// live, and it is where their precedence stops being an argument about code and becomes an observation.
contract FeeSchedulePrecedenceTest is FeeScheduleFixture {
    function _graduateDelay() internal pure override returns (uint256) {
        return 10;
    }

    function _configure(MilestoneBase.LaunchParams memory p) internal pure override {
        super._configure(p);

        // A single step, reached by the very first completion, so the step lands inside the window.
        p.config.feeSchedule.stepCount = 1;
        p.config.feeSchedule.steps[0] = FeeStep({atCompletions: 1, feeHundredthsBip: FINAL_STEP});
        p.config.feeSchedule.steps[1] = FeeStep({atCompletions: 0, feeHundredthsBip: 0});
    }

    // --- Scenario: Anti-snipe overrides during its window ---

    function test_antiSnipeOverridesDuringItsWindow() public {
        uint32 window = hook.launchConfig(poolId).antiSnipeWindowSeconds;
        assertLt(block.timestamp - launchTime, window, "the window is open before the milestone");

        Stepped memory s = _steppedFromLogs(_completeMilestone(0));

        assertTrue(s.seen, "the milestone stepped the base fee");
        assertEq(s.newFee, FINAL_STEP, "down to the schedule's step");
        assertEq(_storedLpFee(), FINAL_STEP, "and the pool stores the stepped value");
        assertLt(block.timestamp - launchTime, window, "all of which happened inside the window");

        // The stored base fee is 0.5% now. What a trader actually pays is still the decay — two orders of
        // magnitude higher — because the override wins for as long as the window is open.
        uint24 expected = _bareOverride();
        assertGt(expected, FINAL_STEP * 50, "the decay is nowhere near the stepped base fee");
        assertApproxEqAbs(
            _sellAndMeasureFee(MEASURED_SELL),
            _feeOn(MEASURED_SELL, expected),
            1e9,
            "and the swap was charged the decayed rate, not the stepped one"
        );
    }

    // --- Scenario: Stepped base fee applies after the window ---

    function test_steppedBaseFeeAppliesAfterTheWindow() public {
        _completeMilestone(0);
        assertEq(_storedLpFee(), FINAL_STEP, "stepped while the window was still open");

        vm.warp(launchTime + hook.launchConfig(poolId).antiSnipeWindowSeconds + 1);
        assertEq(_bareOverride(), 0, "no override survives the window");

        assertApproxEqAbs(
            _sellAndMeasureFee(MEASURED_SELL),
            _feeOn(MEASURED_SELL, FINAL_STEP),
            1e9,
            "so the stepped base fee becomes what traders pay"
        );
    }

    // --- Scenario: Anti-snipe decays toward the current base fee ---

    function test_antiSnipeDecaysTowardTheCurrentBaseFee() public {
        _completeMilestone(0);
        uint32 window = hook.launchConfig(poolId).antiSnipeWindowSeconds;

        // One second before the window closes, the decay has almost arrived — and where it arrives is the
        // *stepped* base fee, not the schedule's start fee and not a hardcoded 1%.
        vm.warp(launchTime + window - 1);
        uint24 nearEnd = _bareOverride();
        uint24 decayStep = Bounds.ANTI_SNIPE_START_FEE / uint24(window);

        assertGt(nearEnd, FINAL_STEP, "still marginally above the target");
        assertLt(nearEnd, FINAL_STEP + 2 * decayStep, "but within a couple of decay steps of it");

        // The comparison that makes it "the *current* base fee": had the step not been applied, the same
        // instant would still be decaying toward the higher start fee.
        uint24 hadItNotStepped = FeeLib.antiSnipeOverride(window, uint64(launchTime), START_FEE, block.timestamp)
            & LPFeeLibrary.REMOVE_OVERRIDE_MASK;
        assertLt(nearEnd, hadItNotStepped, "the step moved the decay's target down with it");

        vm.warp(launchTime + window);
        assertEq(_bareOverride(), 0, "at the boundary the stored base fee takes over");
        assertEq(_storedLpFee(), FINAL_STEP, "which is the value the step left behind");
    }

    /// @dev The charged fee across the whole window, sampled: monotonically falling, always at or above the
    /// stepped base fee, and converging on it rather than on where it started.
    function test_theChargedFeeConvergesOnTheSteppedBaseFee() public {
        _completeMilestone(0);
        uint32 window = hook.launchConfig(poolId).antiSnipeWindowSeconds;
        uint24 previous = Bounds.ANTI_SNIPE_START_FEE + 1;

        for (uint32 elapsed = 10; elapsed < window; elapsed += 10) {
            vm.warp(launchTime + elapsed);
            uint24 charged = _bareOverride();

            assertLt(charged, previous, "the charged fee falls with elapsed time");
            assertGe(charged, FINAL_STEP, "and never below the stepped base fee");
            previous = charged;
        }

        vm.warp(launchTime + window);
        assertEq(_bareOverride(), 0, "then hands over to the base fee entirely");
    }
}
