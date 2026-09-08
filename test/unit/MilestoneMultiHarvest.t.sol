// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {HarnessLaunchpadTest} from "../HarnessFixtures.sol";
import {MilestoneBase} from "../../src/MilestoneBase.sol";

/// @notice The bounded multi-harvest loop in `afterSwap` (task 17.3).
///
/// @dev Both scenarios turn on the same two numbers: `maxDeploysPerSwap` and `maxHarvestsPerSwap`, both 8
/// in the default template. Within the cap is easy to construct — a limited buy deploys and completes as
/// many bands as its limit allows. *Beyond* the cap is not, and the reason is worth stating: band `i+1`
/// sits above band `i`'s top, so a swap cannot reach the ninth band without crossing the eighth's top, and
/// the deploy cap stops it at eight new bands in the first place. Nine tops in one swap therefore requires
/// entering the swap with a band already live — which is what the second test builds.
contract MilestoneMultiHarvestTest is HarnessLaunchpadTest {
    // --- Scenario: A sweeping swap harvests every band it completes within the cap ---

    /// @dev Five bands, comfortably inside the cap of eight, all in one transaction. The assertion is on
    /// the log rather than on the bitmap: "completed and routed within that transaction, in ascending
    /// order" is a statement about a sequence, and the post-swap bitmap has forgotten the order.
    function test_aSweepingSwapHarvestsEveryBandItCompletesWithinTheCap() public {
        _graduate();

        vm.recordLogs();
        _buyToLevel(2_000 ether, _bandUpper(4) + 50);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint32[] memory harvested = _bandIndices(logs, MilestoneBase.MilestoneHarvested.selector);
        assertEq(harvested.length, 5, "every band the sweep completed was harvested");
        assertLt(harvested.length, uint256(template.maxHarvestsPerSwap) + 1, "and it stayed within the cap");

        uint32[] memory routed = _bandIndices(logs, MilestoneBase.HarvestRouted.selector);
        assertEq(routed.length, harvested.length, "each harvest routed its proceeds");

        for (uint256 i = 0; i < harvested.length; i++) {
            assertEq(harvested[i], uint32(i), "in ascending order");
            assertEq(routed[i], uint32(i), "routed in the same order");
            assertTrue(hook.bandCompleted(poolId, i), "and marked complete");
            assertEq(_bandLiquidity(i), 0, "its position burned");
        }

        assertEq(hook.poolState(poolId).completedMilestones, 5, "five completions recorded");
        assertGe(_level(), _bandUpper(4), "the swap really did end above the highest of them");
    }

    // --- Scenario: Harvests beyond the per-swap cap settle on the next swap ---

    /// @dev The construction. Swap A stops inside band 0, leaving it deployed and incomplete. Swap B then
    /// enters with one band already live, deploys eight more — exactly the deploy cap — and runs the price
    /// past all nine tops. Nine bands complete; the harvest cap routes the lowest eight and leaves band 8
    /// live with its top already crossed. A later swap picks it up.
    ///
    /// The mid-transaction count comes from the harness: nine bands are live only between B's deployments
    /// and B's harvests, and nothing external can observe that window.
    function test_harvestsBeyondThePerSwapCapSettleOnTheNextSwap() public {
        _graduate();

        _buyToLevel(2_000 ether, _bandLower(0) + 200);
        assertTrue(hook.bandDeployed(poolId, 0), "band 0 deployed by the first swap");
        assertFalse(hook.bandCompleted(poolId, 0), "and left incomplete inside its range");

        harness.resetSnapshots();
        vm.recordLogs();
        _buy(5_000 ether);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(_countLogs(logs, MilestoneBase.BandDeployed.selector), 8, "the deploy cap allowed eight more");
        assertEq(harness.liveBandCountAt(0), 9, "so nine bands were live when afterSwap began");

        uint32[] memory harvested = _bandIndices(logs, MilestoneBase.MilestoneHarvested.selector);
        assertEq(harvested.length, uint256(template.maxHarvestsPerSwap), "the cap routed exactly eight");
        for (uint256 i = 0; i < harvested.length; i++) {
            assertEq(harvested[i], uint32(i), "the lowest bands, in ascending order");
        }

        // The remainder: live, its top crossed, its proceeds not yet routed.
        assertTrue(hook.bandDeployed(poolId, 8), "band 8 remains deployed");
        assertFalse(hook.bandCompleted(poolId, 8), "and uncompleted");
        assertGt(_bandLiquidity(8), 0, "its position still exists");
        assertGe(_level(), _bandUpper(8), "even though the price is already above its top");
        assertEq(hook.poolState(poolId).completedMilestones, 8, "eight completions so far");

        // "The next swap that ends above them routes them". A sell, because it isolates the requirement:
        // a sell never deploys or skips, so the only ladder event it can possibly emit is the settlement
        // this scenario is about. It ends far above band 8's top — one token barely moves a price this
        // high — which is the condition the harvest loop actually tests.
        vm.recordLogs();
        _sell(1 ether);
        Vm.Log[] memory settled = vm.getRecordedLogs();

        assertGe(_level(), _bandUpper(8), "the following swap also ended above band 8");
        uint32[] memory late = _bandIndices(settled, MilestoneBase.MilestoneHarvested.selector);
        assertEq(late.length, 1, "exactly the band the cap left behind");
        assertEq(late[0], 8, "band 8");
        assertEq(_countLogs(settled, MilestoneBase.HarvestRouted.selector), 1, "and its proceeds were routed");

        assertTrue(hook.bandCompleted(poolId, 8), "band 8 is now complete");
        assertEq(_bandLiquidity(8), 0, "its position burned");
        assertEq(hook.poolState(poolId).completedMilestones, 9, "nine completions, one per band crossed");
    }
}
