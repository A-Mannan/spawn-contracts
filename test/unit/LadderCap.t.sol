// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {LaunchpadTest} from "../Fixtures.sol";
import {MilestoneBase} from "../../src/MilestoneBase.sol";
import {LadderLib} from "../../src/libraries/LadderLib.sol";
import {PoolState} from "../../src/types/LaunchTypes.sol";

/// @notice The per-swap deploy cap and its skip-and-carry fallback (task 17.4).
///
/// @dev A note on how the cap actually behaves, because it is stronger than the requirement's wording and
/// that changes what these tests can assert. The requirement says the excess bands "SHALL be treated as
/// skipped", and spells out what that means observably: the swap succeeds, the inventory stays in hook
/// custody, and it re-targets the bands that deploy later. The implementation stops the walk at the cap
/// rather than emitting {MilestoneBase.BandSkipped} for the excess — so the excess band's core share is
/// never even drawn from `ladderInventoryRemaining`, and the band keeps its place in line. All three
/// observable clauses hold, by a wider margin than a skip would give. The actual skip fires later, when a
/// swap arrives with spot already past that band's floor, which is the second scenario below.
contract LadderCapTest is LaunchpadTest {
    /// @dev The whole ladder allocation, against which the undrawn remainder is measured.
    function _ladderSupply() internal view returns (uint256) {
        return LadderLib.ladderSupply(SUPPLY, template.ladderSupplyShareWad);
    }

    // --- Scenario: Inventory survives a capped-out swap ---

    /// @dev An unlimited 5,000 ETH buy runs the price far past the ladder's reach, so the simulated path
    /// crosses many more undeployed bands than the cap of eight. The requirement is a conjunction, and
    /// each clause gets its own assertion: the swap succeeds, the excess is not deployed, and the token
    /// that would have funded it is still in hook custody rather than lost or locked.
    function test_inventorySurvivesACappedOutSwap() public {
        _graduate();

        uint256 custodyBefore = _undeployedInventory();
        uint256 balanceBefore = token.balanceOf(HOOK_ADDR);
        assertEq(custodyBefore, _ladderSupply(), "the whole ladder allocation starts undrawn");

        vm.recordLogs();
        // No price limit: the path crosses far more band floors than the cap allows.
        _buy(5_000 ether);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256 cap = uint256(template.maxDeploysPerSwap);
        assertEq(_countLogs(logs, MilestoneBase.BandDeployed.selector), cap, "deployments stopped at the cap");
        assertGt(_level(), _bandUpper(cap), "and the path really did carry past the excess bands");

        // Clause one: it did not revert, and it did not lock the ladder.
        PoolState memory state = hook.poolState(poolId);
        assertEq(state.nextBandIndex, uint32(cap), "the cursor still points at the first undeployed band");
        assertFalse(hook.bandDeployed(poolId, cap), "which was never minted");

        // Clause two: nothing was lost. Custody moved by exactly what the log says left and came back.
        uint256 placed = _tokenDeployed(logs);
        uint256 returned = _tokenReturned(logs);
        assertEq(_undeployedInventory(), custodyBefore - placed + returned, "custody conserved");
        assertEq(token.balanceOf(HOOK_ADDR), balanceBefore - placed + returned, "and the real balance with it");

        // Clause three: the excess bands' inventory is specifically still there — undrawn, not merely
        // conserved somewhere. Each of the eight deployments drew one band's share and no more.
        assertEq(
            state.ladderInventoryRemaining,
            _ladderSupply() - cap * _perBand(),
            "only the deployed bands' shares were drawn"
        );
        assertGe(
            state.ladderInventoryRemaining,
            (uint256(template.coreBandCount) - cap) * _perBand(),
            "every band the cap denied still has its share in hook custody"
        );
    }

    // --- Scenario: Skipped inventory re-targets the next band ---

    /// @dev The skip fires on the swap *after* the capped-out one. Spot has to be past the stranded band's
    /// floor for it to be unmintable — v4 gives an all-token position only when the range is strictly below
    /// the current tick — and the band's whole reason to exist is gone once the market has priced through
    /// it, so its inventory moves to the carry and tops up the band above.
    ///
    /// Sizing: the sell lands spot in the 1,788-level gap between band 8's top and band 9's floor. Above
    /// band 8's top, so band 8 cannot mint; below band 9's floor, so band 9 still can.
    function test_skippedInventoryReTargetsTheNextBand() public {
        _graduate();

        vm.recordLogs();
        _buy(5_000 ether);
        uint256 plainInventory = _deployedInventoryOf(vm.getRecordedLogs(), 0);
        assertApproxEqAbs(plainInventory, _perBand(), 1e12, "an unassisted band gets one share");

        uint32 stranded = hook.poolState(poolId).nextBandIndex;
        _sellAllToLevel(_bandUpper(stranded) + 400);
        int24 level = _level();
        assertGt(level, _bandUpper(stranded), "spot is above the stranded band, so it cannot mint");
        assertLt(level, _bandLower(stranded + 1), "and below the next band's floor, so that one can");

        uint256 remainingBefore = hook.poolState(poolId).ladderInventoryRemaining;

        vm.recordLogs();
        // Limited inside band 9 so it mints and is left live: the assertion is about what funded it, and a
        // harvest in the same transaction would burn the evidence.
        _buyToLevel(2_000 ether, _bandLower(stranded + 1) + 100);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint32[] memory skipped = _bandIndices(logs, MilestoneBase.BandSkipped.selector);
        assertEq(skipped.length, 1, "the stranded band skipped");
        assertEq(skipped[0], stranded, "band 8");

        uint32[] memory deployed = _bandIndices(logs, MilestoneBase.BandDeployed.selector);
        assertEq(deployed.length, 1, "and the next band deployed");
        assertEq(deployed[0], stranded + 1, "band 9");

        // The skipped band's share is available to that deployment, which is visible as a band funded
        // beyond one share. The template's cap multiple of two is the ceiling, and this lands on it.
        uint256 assisted = _deployedInventoryOf(logs, stranded + 1);
        assertGt(assisted, plainInventory, "funded beyond an unassisted band's share");
        assertApproxEqAbs(
            assisted, uint256(template.bandInventoryCapMultiple) * _perBand(), 1e12, "by the skipped band's share"
        );

        // Two shares left the undrawn pool for one deployment: the skipped band's and the deployed band's.
        assertEq(
            hook.poolState(poolId).ladderInventoryRemaining,
            remainingBefore - 2 * _perBand(),
            "both bands' shares were drawn, and only one position exists"
        );
        assertGt(_bandLiquidity(stranded + 1), 0, "the inventory is live pool liquidity");
        assertEq(_bandLiquidity(stranded), 0, "and the skipped band has none");
    }

    // --- Scenario: Ladder continues after a skip ---

    function test_ladderContinuesAfterASkip() public {
        _graduate();

        _buy(5_000 ether);
        uint32 stranded = hook.poolState(poolId).nextBandIndex;
        _sellAllToLevel(_bandUpper(stranded) + 400);
        _buyToLevel(2_000 ether, _bandLower(stranded + 1) + 100);

        uint256 completedBefore = hook.poolState(poolId).completedMilestones;
        assertTrue(hook.bandDeployed(poolId, stranded + 1), "band 9 is live going in");

        vm.recordLogs();
        _buyToLevel(2_000 ether, _bandUpper(stranded + 2) + 50);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // Deploys normally: the band above the skipped one, and the one above that.
        uint32[] memory deployed = _bandIndices(logs, MilestoneBase.BandDeployed.selector);
        assertEq(deployed.length, 1, "the next band up deployed");
        assertEq(deployed[0], stranded + 2, "band 10");

        // And harvests normally: both bands the path crossed, in order.
        uint32[] memory harvested = _bandIndices(logs, MilestoneBase.MilestoneHarvested.selector);
        assertEq(harvested.length, 2, "both bands above the skip completed");
        assertEq(harvested[0], stranded + 1, "band 9 first");
        assertEq(harvested[1], stranded + 2, "then band 10");

        assertEq(
            hook.poolState(poolId).completedMilestones,
            completedBefore + 2,
            "the completion count carried on across the skip"
        );
        assertFalse(hook.bandCompleted(poolId, stranded), "the skipped band is not completed by the skip");
        assertGt(hook.poolState(poolId).nextBandIndex, stranded + 2, "and the cursor kept climbing");
    }
}
