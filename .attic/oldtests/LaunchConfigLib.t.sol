// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchConfigLib} from "../../src/libraries/LaunchConfigLib.sol";
import {Bounds, LaunchConfig, WAD} from "../../src/types/LaunchTypes.sol";

/// @dev External wrapper: `validate` is internal, so it inlines into the caller's frame and
/// `vm.expectRevert` would not see a deeper revert.
contract ValidatorHarness {
    function validate(LaunchConfig memory config) external pure {
        LaunchConfigLib.validate(config);
    }
}

/// @notice Unit tests for task 4.1. Every bound is probed twice: exactly on the boundary (must pass)
/// and one step outside it (must revert with that bound's own error).
///
/// The pairing matters more than either half alone. A validator that rejects everything would satisfy
/// the rejection cases; one that accepts everything would satisfy the acceptance cases. Only the pair
/// pins the boundary to the exact value the spec names.
contract LaunchConfigLibTest is Test {
    ValidatorHarness internal harness;

    uint256 internal constant SUPPLY = 1_000_000_000 ether;

    function setUp() public {
        harness = new ValidatorHarness();
    }

    function _base() internal pure returns (LaunchConfig memory) {
        return LaunchConfigLib.defaults(SUPPLY);
    }

    // --- The documented defaults are themselves valid ---

    function test_defaultsAreValid() public view {
        harness.validate(_base());
    }

    function test_defaultsMatchTheDocumentedTable() public pure {
        LaunchConfig memory c = _base();

        assertEq(c.curveSupplyShareWad, 0.25e18, "25% curve");
        assertEq(c.ladderSupplyShareWad, 0.65e18, "65% ladder");
        assertEq(c.fullRangeSupplyShareWad, 0.1e18, "10% full range");
        assertEq(c.bandCount, 10, "10 bands");
        assertEq(c.bandLevelSpacing, 6931, "2x market-cap step");
        assertEq(c.antiSnipeWindowSeconds, 60, "60s anti-snipe");
        assertEq(c.reclaimPeriodSeconds, 30 days, "30-day reclaim");
        assertEq(c.devBuyShareWad, 0, "dev buy off by default");
        assertFalse(c.feeSchedule.enabled, "fee schedule off by default");
    }

    // --- Supply ---

    function test_zeroSupplyRejected() public {
        LaunchConfig memory c = _base();
        c.totalSupply = 0;

        vm.expectRevert(LaunchConfigLib.ZeroTotalSupply.selector);
        harness.validate(c);
    }

    function test_supplySharesMustSumToWad() public {
        LaunchConfig memory c = _base();
        c.fullRangeSupplyShareWad = 0.11e18; // sums to 1.01e18

        vm.expectRevert(abi.encodeWithSelector(LaunchConfigLib.SupplySharesMustSumToWad.selector, uint256(1.01e18)));
        harness.validate(c);
    }

    function test_supplySharesUnderWadRejected() public {
        LaunchConfig memory c = _base();
        c.curveSupplyShareWad = 0.24e18; // sums to 0.99e18

        vm.expectRevert(abi.encodeWithSelector(LaunchConfigLib.SupplySharesMustSumToWad.selector, uint256(0.99e18)));
        harness.validate(c);
    }

    // --- Scenario: Out-of-range band count is rejected ---

    function test_bandCountAtBoundsAccepted() public view {
        LaunchConfig memory c = _base();

        c.bandCount = Bounds.MIN_BAND_COUNT; // 3
        // 65% over 3 bands would exceed the 15% per-band cap, so scale the ladder to suit.
        c.ladderSupplyShareWad = 0.45e18;
        c.curveSupplyShareWad = 0.45e18;
        c.fullRangeSupplyShareWad = 0.1e18;
        harness.validate(c);

        c = _base();
        c.bandCount = Bounds.MAX_BAND_COUNT; // 15
        harness.validate(c);
    }

    function test_bandCountBelowMinRejected() public {
        LaunchConfig memory c = _base();
        c.bandCount = Bounds.MIN_BAND_COUNT - 1; // 2

        vm.expectRevert(abi.encodeWithSelector(LaunchConfigLib.BandCountOutOfRange.selector, uint8(2)));
        harness.validate(c);
    }

    function test_bandCountAboveMaxRejected() public {
        LaunchConfig memory c = _base();
        c.bandCount = Bounds.MAX_BAND_COUNT + 1; // 16

        vm.expectRevert(abi.encodeWithSelector(LaunchConfigLib.BandCountOutOfRange.selector, uint8(16)));
        harness.validate(c);
    }

    // --- Scenario: Band spacing below the floor is rejected ---

    function test_bandSpacingAtFloorAccepted() public view {
        LaunchConfig memory c = _base();
        c.bandLevelSpacing = Bounds.MIN_BAND_LEVEL_SPACING; // 4055, a 1.5x step
        c.bandWidthLevels = 300;
        c.deployWindowLevels = 120;

        harness.validate(c);
    }

    function test_bandSpacingBelowFloorRejected() public {
        LaunchConfig memory c = _base();
        c.bandLevelSpacing = Bounds.MIN_BAND_LEVEL_SPACING - 1;
        c.bandWidthLevels = 300;
        c.deployWindowLevels = 120;

        vm.expectRevert(abi.encodeWithSelector(LaunchConfigLib.BandSpacingBelowFloor.selector, int24(4054)));
        harness.validate(c);
    }

    /// @dev The floor is a 1.5x market-cap step: ln(1.5)/ln(1.0001).
    function test_spacingFloorCorrespondsToA1Point5xStep() public pure {
        // 1.0001^4055 ~= 1.5. Check the exponent is right to within a tick.
        assertEq(Bounds.MIN_BAND_LEVEL_SPACING, 4055, "1.5x step");
        assertEq(Bounds.DEFAULT_BAND_LEVEL_SPACING, 6931, "2x step");
    }

    // --- Band width and deploy window must fit inside the gap ---

    function test_bandWidthAtGapRejected() public {
        LaunchConfig memory c = _base();
        c.bandWidthLevels = c.bandLevelSpacing; // touching neighbours

        vm.expectRevert(abi.encodeWithSelector(LaunchConfigLib.BandWidthInvalid.selector, int24(6931), int24(6931)));
        harness.validate(c);
    }

    function test_zeroBandWidthRejected() public {
        LaunchConfig memory c = _base();
        c.bandWidthLevels = 0;

        vm.expectRevert(abi.encodeWithSelector(LaunchConfigLib.BandWidthInvalid.selector, int24(0), int24(6931)));
        harness.validate(c);
    }

    function test_bandWidthJustInsideGapAccepted() public view {
        LaunchConfig memory c = _base();
        c.bandWidthLevels = c.bandLevelSpacing - 1;
        c.deployWindowLevels = 1;

        harness.validate(c);
    }

    function test_deployWindowOverflowingGapRejected() public {
        LaunchConfig memory c = _base();
        c.bandWidthLevels = 520;
        c.deployWindowLevels = c.bandLevelSpacing - 520 + 1; // one past the gap below the band

        vm.expectRevert(abi.encodeWithSelector(LaunchConfigLib.DeployWindowInvalid.selector, int24(6412), int24(6931)));
        harness.validate(c);
    }

    function test_deployWindowExactlyFillingGapAccepted() public view {
        LaunchConfig memory c = _base();
        c.bandWidthLevels = 520;
        c.deployWindowLevels = c.bandLevelSpacing - 520;

        harness.validate(c);
    }

    function test_zeroDeployWindowRejected() public {
        LaunchConfig memory c = _base();
        c.deployWindowLevels = 0;

        vm.expectRevert(abi.encodeWithSelector(LaunchConfigLib.DeployWindowInvalid.selector, int24(0), int24(6931)));
        harness.validate(c);
    }

    // --- Scenario: Oversized ladder supply is rejected ---

    function test_ladderShareAtCapAccepted() public view {
        LaunchConfig memory c = _base();
        c.ladderSupplyShareWad = Bounds.MAX_LADDER_SUPPLY_SHARE_WAD; // 65%

        harness.validate(c);
    }

    function test_ladderShareAboveCapRejected() public {
        LaunchConfig memory c = _base();
        c.ladderSupplyShareWad = Bounds.MAX_LADDER_SUPPLY_SHARE_WAD + 1;
        c.curveSupplyShareWad = 0.25e18 - 1; // keep the sum at WAD so this bound is the one that trips

        vm.expectRevert(
            abi.encodeWithSelector(
                LaunchConfigLib.LadderShareAboveCap.selector, uint64(Bounds.MAX_LADDER_SUPPLY_SHARE_WAD + 1)
            )
        );
        harness.validate(c);
    }

    /// @dev The per-band cap binds independently: 60% over 4 bands is 15% each, which is exactly at the
    /// cap, while 61% over 4 bands is over it even though the aggregate is under 65%.
    function test_perBandShareAtCapAccepted() public view {
        LaunchConfig memory c = _base();
        c.bandCount = 4;
        c.ladderSupplyShareWad = 0.6e18; // 15% per band
        c.curveSupplyShareWad = 0.3e18;
        c.fullRangeSupplyShareWad = 0.1e18;

        harness.validate(c);
    }

    function test_perBandShareAboveCapRejected() public {
        LaunchConfig memory c = _base();
        c.bandCount = 4;
        c.ladderSupplyShareWad = 0.64e18; // 16% per band, aggregate still under 65%
        c.curveSupplyShareWad = 0.26e18;
        c.fullRangeSupplyShareWad = 0.1e18;

        vm.expectRevert(abi.encodeWithSelector(LaunchConfigLib.PerBandShareAboveCap.selector, uint256(0.16e18)));
        harness.validate(c);
    }

    // --- Scenario: Dev buy is capped below the bonding curve share ---

    function test_devBuyAtCapAcceptedWhenCurveShareIsLarger() public view {
        LaunchConfig memory c = _base();
        c.devBuyShareWad = Bounds.MAX_DEV_BUY_SHARE_WAD; // 20%, curve share is 25%

        harness.validate(c);
    }

    function test_devBuyAboveCapRejected() public {
        LaunchConfig memory c = _base();
        c.devBuyShareWad = Bounds.MAX_DEV_BUY_SHARE_WAD + 1;

        vm.expectRevert(
            abi.encodeWithSelector(LaunchConfigLib.DevBuyAboveCap.selector, uint64(Bounds.MAX_DEV_BUY_SHARE_WAD + 1))
        );
        harness.validate(c);
    }

    /// @dev Equality is rejected, not just excess: the public raise must retain something.
    function test_devBuyEqualToCurveShareRejected() public {
        LaunchConfig memory c = _base();
        c.curveSupplyShareWad = 0.15e18;
        c.ladderSupplyShareWad = 0.65e18;
        c.fullRangeSupplyShareWad = 0.2e18;
        c.devBuyShareWad = 0.15e18; // exactly the curve share

        vm.expectRevert(
            abi.encodeWithSelector(LaunchConfigLib.DevBuyNotBelowCurveShare.selector, uint64(0.15e18), uint64(0.15e18))
        );
        harness.validate(c);
    }

    function test_devBuyJustBelowCurveShareAccepted() public view {
        LaunchConfig memory c = _base();
        c.curveSupplyShareWad = 0.15e18;
        c.ladderSupplyShareWad = 0.65e18;
        c.fullRangeSupplyShareWad = 0.2e18;
        c.devBuyShareWad = 0.15e18 - 1;

        harness.validate(c);
    }

    function test_devBuyVestingAtMaxAccepted() public view {
        LaunchConfig memory c = _base();
        c.devBuyShareWad = 0.1e18;
        c.devBuyVestingSeconds = Bounds.MAX_DEV_BUY_VESTING_SECONDS; // 12 months

        harness.validate(c);
    }

    function test_devBuyVestingAboveMaxRejected() public {
        LaunchConfig memory c = _base();
        c.devBuyShareWad = 0.1e18;
        c.devBuyVestingSeconds = Bounds.MAX_DEV_BUY_VESTING_SECONDS + 1;

        vm.expectRevert(
            abi.encodeWithSelector(
                LaunchConfigLib.DevBuyVestingTooLong.selector, uint32(Bounds.MAX_DEV_BUY_VESTING_SECONDS + 1)
            )
        );
        harness.validate(c);
    }

    // --- Scenario: Harvest split that does not sum to one whole is rejected ---

    function test_harvestSplitNotSummingToWadRejected() public {
        LaunchConfig memory c = _base();
        c.harvestSplit.lpWad = 0.11e18; // sums to 1.01e18

        vm.expectRevert(abi.encodeWithSelector(LaunchConfigLib.HarvestSplitMustSumToWad.selector, uint256(1.01e18)));
        harness.validate(c);
    }

    // --- Scenario: Harvest split violating component bounds is rejected ---

    function test_protocolHarvestShareAtFloorAccepted() public view {
        LaunchConfig memory c = _base();
        c.harvestSplit.protocolWad = Bounds.MIN_PROTOCOL_HARVEST_SHARE_WAD; // 5%
        c.harvestSplit.creatorWad = 0.65e18; // keep the sum at WAD

        harness.validate(c);
    }

    function test_protocolHarvestShareBelowFloorRejected() public {
        LaunchConfig memory c = _base();
        c.harvestSplit.protocolWad = Bounds.MIN_PROTOCOL_HARVEST_SHARE_WAD - 1;
        // Give the shortfall to the creator so the sum stays at WAD and this bound is the one that trips.
        c.harvestSplit.creatorWad = 0.65e18 + 1;

        vm.expectRevert(
            abi.encodeWithSelector(
                LaunchConfigLib.ProtocolHarvestShareBelowFloor.selector,
                uint64(Bounds.MIN_PROTOCOL_HARVEST_SHARE_WAD - 1)
            )
        );
        harness.validate(c);
    }

    function test_buybackShareAtCapAccepted() public view {
        LaunchConfig memory c = _base();
        c.harvestSplit.buybackWad = Bounds.MAX_BUYBACK_HARVEST_SHARE_WAD; // 40%
        c.harvestSplit.creatorWad = 0.4e18; // 40 + 40 + 10 + 10 = 100

        harness.validate(c);
    }

    function test_buybackShareAboveCapRejected() public {
        LaunchConfig memory c = _base();
        c.harvestSplit.buybackWad = Bounds.MAX_BUYBACK_HARVEST_SHARE_WAD + 1;
        c.harvestSplit.creatorWad = 0.4e18 - 1;

        vm.expectRevert(
            abi.encodeWithSelector(
                LaunchConfigLib.BuybackHarvestShareAboveCap.selector, uint64(Bounds.MAX_BUYBACK_HARVEST_SHARE_WAD + 1)
            )
        );
        harness.validate(c);
    }

    // --- Scenario: LP-seed share below the floor is rejected ---

    function test_lpSeedShareAtFloorAccepted() public view {
        LaunchConfig memory c = _base();
        c.proceedsSplit.lpSeedWad = Bounds.MIN_LP_SEED_SHARE_WAD; // 20%
        c.proceedsSplit.creatorWad = 0.75e18;
        c.proceedsSplit.protocolWad = 0.05e18;

        harness.validate(c);
    }

    function test_lpSeedShareBelowFloorRejected() public {
        LaunchConfig memory c = _base();
        c.proceedsSplit.lpSeedWad = Bounds.MIN_LP_SEED_SHARE_WAD - 1;
        c.proceedsSplit.creatorWad = 0.75e18 + 1;
        c.proceedsSplit.protocolWad = 0.05e18;

        vm.expectRevert(
            abi.encodeWithSelector(
                LaunchConfigLib.LpSeedShareBelowFloor.selector, uint64(Bounds.MIN_LP_SEED_SHARE_WAD - 1)
            )
        );
        harness.validate(c);
    }

    function test_proceedsSplitNotSummingToWadRejected() public {
        LaunchConfig memory c = _base();
        c.proceedsSplit.protocolWad = 0.06e18; // sums to 1.01e18

        vm.expectRevert(abi.encodeWithSelector(LaunchConfigLib.ProceedsSplitMustSumToWad.selector, uint256(1.01e18)));
        harness.validate(c);
    }

    // --- Scenario: Diversion never exceeds the cap ---

    function test_milestoneFundShareAtCapAccepted() public view {
        LaunchConfig memory c = _base();
        c.milestoneFundShareWad = Bounds.MAX_MILESTONE_FUND_SHARE_WAD; // 20%

        harness.validate(c);
    }

    function test_milestoneFundShareAboveCapRejected() public {
        LaunchConfig memory c = _base();
        c.milestoneFundShareWad = Bounds.MAX_MILESTONE_FUND_SHARE_WAD + 1;

        vm.expectRevert(
            abi.encodeWithSelector(
                LaunchConfigLib.MilestoneFundShareAboveCap.selector, uint64(Bounds.MAX_MILESTONE_FUND_SHARE_WAD + 1)
            )
        );
        harness.validate(c);
    }

    // --- Scenario: Invalid anti-snipe window is rejected ---

    function test_allFourPermittedWindowsAccepted() public view {
        uint32[4] memory windows = [uint32(0), 60, 600, 5880];

        for (uint256 i = 0; i < windows.length; i++) {
            LaunchConfig memory c = _base();
            c.antiSnipeWindowSeconds = windows[i];
            harness.validate(c);
        }
    }

    function test_arbitraryAntiSnipeWindowRejected() public {
        uint32[5] memory bad = [uint32(1), 59, 61, 300, 5881];

        for (uint256 i = 0; i < bad.length; i++) {
            LaunchConfig memory c = _base();
            c.antiSnipeWindowSeconds = bad[i];

            vm.expectRevert(abi.encodeWithSelector(LaunchConfigLib.AntiSnipeWindowNotPermitted.selector, bad[i]));
            harness.validate(c);
        }
    }

    // --- Scenario: Milestone fee schedule outside bounds is rejected ---

    function _scheduleConfig(uint24 startFee, uint8 stepCount, uint24 fee0, uint8 at0, uint24 fee1, uint8 at1)
        internal
        pure
        returns (LaunchConfig memory c)
    {
        c = _base();
        c.feeSchedule.enabled = true;
        c.feeSchedule.startFeeHundredthsBip = startFee;
        c.feeSchedule.stepCount = stepCount;
        c.feeSchedule.steps[0].feeHundredthsBip = fee0;
        c.feeSchedule.steps[0].atCompletions = at0;
        c.feeSchedule.steps[1].feeHundredthsBip = fee1;
        c.feeSchedule.steps[1].atCompletions = at1;
    }

    /// @dev The documented example: 1.5% -> 1.0% -> 0.5% at completions 2 and 4.
    function test_documentedScheduleAccepted() public view {
        harness.validate(_scheduleConfig(15_000, 2, 10_000, 2, 5_000, 4));
    }

    function test_scheduleStartFeeAtCapAccepted() public view {
        harness.validate(_scheduleConfig(Bounds.MAX_SCHEDULE_START_FEE, 1, 10_000, 2, 0, 0));
    }

    function test_scheduleStartFeeAboveCapRejected() public {
        LaunchConfig memory c = _scheduleConfig(Bounds.MAX_SCHEDULE_START_FEE + 1, 1, 10_000, 2, 0, 0);

        vm.expectRevert(
            abi.encodeWithSelector(
                LaunchConfigLib.ScheduleStartFeeAboveCap.selector, uint24(Bounds.MAX_SCHEDULE_START_FEE + 1)
            )
        );
        harness.validate(c);
    }

    function test_scheduleFeeAtFloorAccepted() public view {
        harness.validate(_scheduleConfig(15_000, 1, Bounds.MIN_SCHEDULE_FLOOR_FEE, 2, 0, 0));
    }

    function test_scheduleFeeBelowFloorRejected() public {
        LaunchConfig memory c = _scheduleConfig(15_000, 1, Bounds.MIN_SCHEDULE_FLOOR_FEE - 1, 2, 0, 0);

        vm.expectRevert(
            abi.encodeWithSelector(
                LaunchConfigLib.ScheduleFeeBelowFloor.selector, uint24(Bounds.MIN_SCHEDULE_FLOOR_FEE - 1)
            )
        );
        harness.validate(c);
    }

    function test_scheduleWithTwoStepsAccepted() public view {
        harness.validate(_scheduleConfig(15_000, Bounds.MAX_FEE_STEPS, 10_000, 2, 5_000, 4));
    }

    function test_scheduleWithThreeStepsRejected() public {
        LaunchConfig memory c = _scheduleConfig(15_000, Bounds.MAX_FEE_STEPS + 1, 10_000, 2, 5_000, 4);

        vm.expectRevert(
            abi.encodeWithSelector(LaunchConfigLib.ScheduleTooManySteps.selector, uint8(Bounds.MAX_FEE_STEPS + 1))
        );
        harness.validate(c);
    }

    function test_enabledScheduleWithNoStepsRejected() public {
        LaunchConfig memory c = _scheduleConfig(15_000, 0, 0, 0, 0, 0);

        vm.expectRevert(LaunchConfigLib.ScheduleNeedsAtLeastOneStep.selector);
        harness.validate(c);
    }

    /// @dev A "step-down" schedule that steps up is incoherent, and would make the spec's
    /// "Step-downs do not reverse" unsatisfiable.
    function test_nonDecreasingScheduleRejected() public {
        LaunchConfig memory c = _scheduleConfig(10_000, 2, 5_000, 2, 7_500, 4);

        vm.expectRevert(
            abi.encodeWithSelector(
                LaunchConfigLib.ScheduleNotMonotonicallyDecreasing.selector, uint24(5_000), uint24(7_500)
            )
        );
        harness.validate(c);
    }

    function test_scheduleStepEqualToPreviousRejected() public {
        LaunchConfig memory c = _scheduleConfig(10_000, 1, 10_000, 2, 0, 0);

        vm.expectRevert(
            abi.encodeWithSelector(
                LaunchConfigLib.ScheduleNotMonotonicallyDecreasing.selector, uint24(10_000), uint24(10_000)
            )
        );
        harness.validate(c);
    }

    function test_nonAscendingThresholdsRejected() public {
        LaunchConfig memory c = _scheduleConfig(15_000, 2, 10_000, 4, 5_000, 4);

        vm.expectRevert(
            abi.encodeWithSelector(LaunchConfigLib.ScheduleThresholdsNotAscending.selector, uint8(4), uint8(4))
        );
        harness.validate(c);
    }

    function test_zeroThresholdRejected() public {
        LaunchConfig memory c = _scheduleConfig(15_000, 1, 10_000, 0, 0, 0);

        vm.expectRevert(
            abi.encodeWithSelector(LaunchConfigLib.ScheduleThresholdsNotAscending.selector, uint8(0), uint8(0))
        );
        harness.validate(c);
    }

    /// @dev A disabled schedule is not validated at all, so nonsense fields in it are harmless.
    function test_disabledScheduleIgnoresItsFields() public view {
        LaunchConfig memory c = _base();
        c.feeSchedule.enabled = false;
        c.feeSchedule.startFeeHundredthsBip = 999_999;
        c.feeSchedule.stepCount = 200;

        harness.validate(c);
    }

    // --- Maintenance ---

    function test_zeroReclaimPeriodRejected() public {
        LaunchConfig memory c = _base();
        c.reclaimPeriodSeconds = 0;

        vm.expectRevert(LaunchConfigLib.ZeroReclaimPeriod.selector);
        harness.validate(c);
    }

    function test_oneSecondReclaimPeriodAccepted() public view {
        LaunchConfig memory c = _base();
        c.reclaimPeriodSeconds = 1;

        harness.validate(c);
    }

    // --- Scenario: Valid configuration at bound edges is accepted ---

    /// @dev Every bound simultaneously at its permitted extreme.
    function test_configurationSittingOnEveryBoundAccepted() public view {
        LaunchConfig memory c = _base();

        c.bandCount = Bounds.MIN_BAND_COUNT; // 3
        c.bandLevelSpacing = Bounds.MIN_BAND_LEVEL_SPACING; // 1.5x step
        c.bandWidthLevels = 1;
        c.deployWindowLevels = 1;

        // 45% over 3 bands is 15% each: exactly the per-band cap.
        c.ladderSupplyShareWad = 0.45e18;
        c.curveSupplyShareWad = 0.45e18;
        c.fullRangeSupplyShareWad = 0.1e18;

        c.devBuyShareWad = Bounds.MAX_DEV_BUY_SHARE_WAD; // 20%, below the 45% curve share
        c.devBuyVestingSeconds = Bounds.MAX_DEV_BUY_VESTING_SECONDS;

        c.harvestSplit.buybackWad = Bounds.MAX_BUYBACK_HARVEST_SHARE_WAD; // 40%
        c.harvestSplit.protocolWad = Bounds.MIN_PROTOCOL_HARVEST_SHARE_WAD; // 5%
        c.harvestSplit.creatorWad = 0.45e18;
        c.harvestSplit.lpWad = 0.1e18;

        c.proceedsSplit.lpSeedWad = Bounds.MIN_LP_SEED_SHARE_WAD; // 20%
        c.proceedsSplit.creatorWad = 0.75e18;
        c.proceedsSplit.protocolWad = 0.05e18;

        c.milestoneFundShareWad = Bounds.MAX_MILESTONE_FUND_SHARE_WAD; // 20%
        c.antiSnipeWindowSeconds = 5880; // longest permitted window
        c.reclaimPeriodSeconds = 1;

        c.feeSchedule.enabled = true;
        c.feeSchedule.startFeeHundredthsBip = Bounds.MAX_SCHEDULE_START_FEE;
        c.feeSchedule.stepCount = Bounds.MAX_FEE_STEPS;
        c.feeSchedule.steps[0].feeHundredthsBip = 10_000;
        c.feeSchedule.steps[0].atCompletions = 1;
        c.feeSchedule.steps[1].feeHundredthsBip = Bounds.MIN_SCHEDULE_FLOOR_FEE;
        c.feeSchedule.steps[1].atCompletions = 2;

        harness.validate(c);
    }

    // --- Fuzzing: the validator never accepts an out-of-bound share ---

    function testFuzz_ladderShareAboveCapAlwaysRejected(uint64 shareWad) public {
        // Upper bound leaves room for the 10% full-range share, so the compensating curve share below
        // stays non-negative and the ladder cap is what trips.
        shareWad = uint64(bound(shareWad, Bounds.MAX_LADDER_SUPPLY_SHARE_WAD + 1, 0.9e18));

        LaunchConfig memory c = _base();
        c.ladderSupplyShareWad = shareWad;
        c.curveSupplyShareWad = uint64(WAD) - shareWad - c.fullRangeSupplyShareWad;

        vm.expectRevert(abi.encodeWithSelector(LaunchConfigLib.LadderShareAboveCap.selector, shareWad));
        harness.validate(c);
    }

    function testFuzz_harvestSplitOffByAnyAmountRejected(uint64 delta) public {
        delta = uint64(bound(delta, 1, 0.05e18));

        LaunchConfig memory c = _base();
        c.harvestSplit.lpWad = 0.1e18 + delta;

        vm.expectRevert(abi.encodeWithSelector(LaunchConfigLib.HarvestSplitMustSumToWad.selector, uint256(WAD) + delta));
        harness.validate(c);
    }

    function testFuzz_onlyEnumeratedAntiSnipeWindowsAccepted(uint32 window) public {
        vm.assume(window != 0 && window != 60 && window != 600 && window != 5880);

        LaunchConfig memory c = _base();
        c.antiSnipeWindowSeconds = window;

        vm.expectRevert(abi.encodeWithSelector(LaunchConfigLib.AntiSnipeWindowNotPermitted.selector, window));
        harness.validate(c);
    }
}
