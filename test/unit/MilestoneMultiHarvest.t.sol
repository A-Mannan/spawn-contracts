// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {HarnessLaunchpadTest} from "../HarnessFixtures.sol";
import {MilestoneBase} from "../../src/MilestoneBase.sol";

/// @notice The bounded multi-harvest loop in `afterSwap`.
/// @dev A ninth completion in one swap requires entering with one band already live because both the
/// deployment and harvest caps are eight in the canonical template.
contract MilestoneMultiHarvestTest is HarnessLaunchpadTest {
    // --- Scenario: A sweeping swap accounts for every completed band within the cap ---

    function test_aSweepingSwapAccountsForEveryCompletedBandWithinTheCap() public {
        _graduate();

        vm.recordLogs();
        _buyToLevel(2_000 ether, _bandUpper(4) + 50);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint32[] memory harvested = _bandIndices(logs, MilestoneBase.MilestoneHarvested.selector);
        uint32[] memory funded = _bandIndices(logs, MilestoneBase.PayoutPotFunded.selector);
        assertEq(harvested.length, 5, "every crossed band was harvested");
        assertEq(funded.length, harvested.length, "each gross harvest funded its pot");
        assertLt(harvested.length, uint256(template.maxHarvestsPerSwap) + 1, "within the cap");

        for (uint256 i = 0; i < harvested.length; i++) {
            assertEq(harvested[i], uint32(i), "harvested in ascending order");
            assertEq(funded[i], uint32(i), "accounted in the same order");
            assertTrue(hook.bandCompleted(poolId, i), "marked complete");
            assertEq(_bandLiquidity(i), 0, "position burned");
        }

        assertGt(hook.payoutPot(poolId), 0, "net proceeds accumulated asynchronously");
        assertEq(hook.poolState(poolId).completedMilestones, 5, "five completions recorded");
        assertGe(_level(), _bandUpper(4), "the swap ended above the highest band");
    }

    // --- Scenario: Harvests beyond the cap remain pending ---

    function test_harvestsBeyondTheCapRemainPending() public {
        _graduate();

        _buyToLevel(2_000 ether, _bandLower(0) + 200);
        assertTrue(hook.bandDeployed(poolId, 0), "band 0 deployed");
        assertFalse(hook.bandCompleted(poolId, 0), "band 0 left incomplete");

        harness.resetSnapshots();
        vm.recordLogs();
        _buy(5_000 ether);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(_countLogs(logs, MilestoneBase.BandDeployed.selector), 8, "eight more bands deployed");
        assertEq(harness.liveBandCountAt(0), 9, "nine bands were live before harvesting");

        uint32[] memory harvested = _bandIndices(logs, MilestoneBase.MilestoneHarvested.selector);
        uint32[] memory funded = _bandIndices(logs, MilestoneBase.PayoutPotFunded.selector);
        assertEq(harvested.length, uint256(template.maxHarvestsPerSwap), "harvest cap applied");
        assertEq(funded.length, harvested.length, "every completed band was accounted");
        for (uint256 i = 0; i < harvested.length; i++) {
            assertEq(harvested[i], uint32(i), "lowest bands first");
            assertEq(funded[i], uint32(i), "same accounting order");
        }

        assertTrue(hook.bandDeployed(poolId, 8), "band 8 remains deployed");
        assertFalse(hook.bandCompleted(poolId, 8), "band 8 remains pending");
        assertGt(_bandLiquidity(8), 0, "its position remains live");
        assertGe(_level(), _bandUpper(8), "its top was crossed");
        assertEq(hook.poolState(poolId).completedMilestones, 8, "only eight completed");

        uint256 potBefore = hook.payoutPot(poolId);
        vm.recordLogs();
        _sell(1 ether);
        Vm.Log[] memory settled = vm.getRecordedLogs();

        uint32[] memory late = _bandIndices(settled, MilestoneBase.MilestoneHarvested.selector);
        uint32[] memory lateFunded = _bandIndices(settled, MilestoneBase.PayoutPotFunded.selector);
        assertEq(late.length, 1, "one pending band harvested later");
        assertEq(late[0], 8, "band 8 harvested");
        assertEq(lateFunded.length, 1, "its pot accounting ran once");
        assertEq(lateFunded[0], 8, "the same milestone was attributed");
        assertGt(hook.payoutPot(poolId), potBefore, "net pot increased only on the later swap");
        assertTrue(hook.bandCompleted(poolId, 8), "band 8 is now complete");
        assertEq(_bandLiquidity(8), 0, "its position burned");
        assertEq(hook.poolState(poolId).completedMilestones, 9, "nine completions total");
    }
}
