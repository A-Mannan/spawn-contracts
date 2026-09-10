// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {MilestoneBase} from "../../src/MilestoneBase.sol";
import {LadderLib} from "../../src/libraries/LadderLib.sol";
import {Bounds, LaunchConfig, LiveBand, PoolState} from "../../src/types/LaunchTypes.sol";
import {SwapFeesFixture} from "./SwapFees.t.sol";

/// @notice Unit tests for task 11.1 — the fee-funded ladder extension.
///
/// @dev Bands past `bandCount` are not a separate mechanism. `LadderLib.bandLevels` keeps counting with the
/// same formula, so a fee-funded band's geometry is one spacing step above the last one for free; the only
/// two differences are that it has no core supply allocation, so it exists only if inventory has accrued,
/// and that it is counted against a protocol cap of {Bounds.MAX_FEE_FUNDED_BANDS}.
///
/// The fixture uses a deliberately tiny ladder share for the reason `BandInventorySizingTest` explains: it
/// is what makes a band's whole inventory reachable from swap fees inside a unit test. It also makes the
/// core ladder cheap to walk to exhaustion, which is the precondition every scenario here needs. The
/// buyback is zeroed so the harvest of one band does not carry the price past the next.
contract LadderExtensionTest is SwapFeesFixture {
    function _configure(MilestoneBase.LaunchParams memory p) internal pure override {
        p.config.curveSupplyShareWad = 0.8997e18;
        p.config.ladderSupplyShareWad = 0.0003e18;
        p.config.fullRangeSupplyShareWad = 0.1e18;
        p.config.bandCount = 3;

        p.config.harvestSplit.creatorWad = 0.6e18;
        p.config.harvestSplit.buybackWad = 0;
        p.config.harvestSplit.protocolWad = 0.1e18;
        p.config.harvestSplit.lpWad = 0.3e18;
    }

    /// @dev Walks the core ladder to exhaustion by completing every core band in turn. Leaves the cursor on
    /// the first fee-funded index with the core allocation spent and nothing but rounding dust carried.
    function _exhaustCoreLadder() private {
        uint8 bandCount = hook.launchConfig(poolId).bandCount;

        for (uint256 i = 0; i < bandCount; i++) {
            _completeMilestone(i);
        }

        PoolState memory state = hook.poolState(poolId);
        require(state.bandCursor == bandCount, "cursor is not on the first fee-funded index");
        require(state.ladderInventoryRemaining == 0, "core allocation is not spent");
        require(state.milestoneFundAccrued == 0, "no fees were collected, so nothing should have accrued");
    }

    /// @dev Approaches band `index` from below without requiring that anything deploy, so a test can assert
    /// that nothing did. `_deployBand` insists on a successful mint; this is its permissive twin.
    function _approachWithoutRequiring(uint256 index) private {
        LaunchConfig memory config = hook.launchConfig(poolId);
        (int24 lower,) = _bandLevels(index);

        int24 windowFloor = lower - config.deployWindowLevels;
        if (_level() >= windowFloor) _sellToLevel(windowFloor - 100);

        _buyToLevel(lower - config.deployWindowLevels / 2);
        _buyToLevel(lower - 1);
    }

    // --- Scenario: Extension requires accrued inventory ---

    function test_extensionRequiresAccruedInventory() public {
        _exhaustCoreLadder();

        uint256 carried = hook.poolState(poolId).carriedInventory;
        assertLt(carried, _perBand() / 1e12, "nothing but mint dust is carried out of a completed core ladder");

        uint256 hookTokensBefore = token.balanceOf(HOOK_ADDR);
        _approachWithoutRequiring(uint256(hook.launchConfig(poolId).bandCount));

        // The ladder is inactive, not broken: the swaps went through, no band appeared, and the dust that
        // was carried is still carried rather than staked or lost.
        PoolState memory state = hook.poolState(poolId);
        assertFalse(state.liveBand.deployed, "no band was created without inventory to fund it");
        assertEq(state.feeFundedBandsCreated, 0, "and none was counted against the extension cap");
        assertEq(state.carriedInventory, carried, "the dust was returned to the carry, not staked");
        assertEq(token.balanceOf(HOOK_ADDR), hookTokensBefore, "and no token left custody");
    }

    /// @dev And it resumes the moment accrual does — the ladder is dormant, not closed.
    function test_theLadderResumesOnceAccrualReturns() public {
        _exhaustCoreLadder();
        _approachWithoutRequiring(3);
        assertFalse(hook.liveBand(poolId).deployed, "dormant");

        _sell(MEASURED_SELL);
        _clearAccrual();
        assertGt(hook.poolState(poolId).milestoneFundAccrued, 0, "fees have now accrued");

        LiveBand memory band = _deployBand(3);
        assertTrue(band.deployed, "and the ladder woke up");
        assertEq(band.index, 3, "on the first fee-funded index");
    }

    // --- Scenario: A new band is created beyond the core ladder ---

    function test_aNewBandIsCreatedBeyondTheCoreLadder() public {
        _exhaustCoreLadder();

        _sell(MEASURED_SELL);
        Collected memory c = _collectAndCapture();
        uint256 accrued = hook.poolState(poolId).milestoneFundAccrued;
        uint256 carried = hook.poolState(poolId).carriedInventory;
        assertEq(accrued, c.diverted, "the fund holds what the collection diverted");

        LiveBand memory band = _deployBand(3);
        PoolState memory state = hook.poolState(poolId);

        assertEq(band.index, 3, "the index continues past the core band count");
        assertGe(band.index, hook.launchConfig(poolId).bandCount, "so it is a fee-funded band");
        assertEq(state.feeFundedBandsCreated, 1, "counted against the extension cap");
        assertGt(band.liquidity, 0, "and it is real liquidity");

        // Funded entirely by fees: it has no core allocation to draw on, and the ladder's own share is
        // already spent.
        assertEq(state.ladderInventoryRemaining, 0, "no core allocation was left to use");
        assertEq(band.tokenInventory + state.carriedInventory, accrued + carried, "so the fees paid for it");
        assertEq(state.milestoneFundAccrued, 0, "and the fund was spent on it");
    }

    /// @dev "One spacing step above the last band" is not special-cased anywhere: it falls out of the same
    /// `graduationLevel + (i + 1) * spacing` formula the core bands use, so any observer can compute it.
    function test_theNewBandSitsOneSpacingStepAboveTheLast() public view {
        LaunchConfig memory config = hook.launchConfig(poolId);
        (int24 lastCoreLower, int24 lastCoreUpper) = _bandLevels(uint256(config.bandCount) - 1);
        (int24 firstExtLower, int24 firstExtUpper) = _bandLevels(uint256(config.bandCount));

        assertEq(firstExtLower - lastCoreLower, config.bandLevelSpacing, "one uniform step above the last core band");
        assertEq(firstExtUpper - firstExtLower, config.bandWidthLevels, "with the same width as every other band");
        assertEq(lastCoreUpper - lastCoreLower, config.bandWidthLevels, "which is the core bands' width");
        assertGt(firstExtLower, lastCoreUpper, "and no overlap with the band below it");
    }

    function test_aFeeFundedBandHarvestsAndRoutesLikeACoreBand() public {
        _exhaustCoreLadder();
        _sell(MEASURED_SELL);
        _clearAccrual();

        _deployBand(3);
        (, int24 upper3) = _bandLevels(3);

        uint256 creatorBefore = hook.creatorClaimable(poolId);
        uint256 protocolBefore = hook.protocolClaimable(poolId);
        uint32 completedBefore = hook.poolState(poolId).completedMilestones;

        vm.recordLogs();
        _buyToLevel(upper3 + 200);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(_countLogs(logs, MilestoneBase.MilestoneHarvested.selector), 1, "it harvested like any band");
        assertEq(_countLogs(logs, MilestoneBase.HarvestRouted.selector), 1, "and routed like any band");

        PoolState memory state = hook.poolState(poolId);
        assertEq(state.completedMilestones, completedBefore + 1, "and counted as a completed milestone");
        assertEq(state.bandCursor, 4, "with the cursor moving on to the next fee-funded index");
        assertFalse(state.liveBand.deployed, "the position was retired");
        assertGt(hook.creatorClaimable(poolId), creatorBefore, "the creator was credited");
        assertGt(hook.protocolClaimable(poolId), protocolBefore, "and so was the protocol");
    }

    /// @dev A second fee-funded band, to show the extension continues rather than stopping at one.
    function test_theExtensionContinuesBandAfterBand() public {
        _exhaustCoreLadder();

        for (uint256 index = 3; index <= 4; index++) {
            _sell(MEASURED_SELL);
            _clearAccrual();

            LiveBand memory band = _deployBand(index);
            assertEq(band.index, uint32(index), "the next fee-funded index deployed");
            assertEq(
                hook.poolState(poolId).feeFundedBandsCreated,
                uint32(index) - hook.launchConfig(poolId).bandCount + 1,
                "each one counted once against the cap"
            );

            (, int24 upper) = _bandLevels(index);
            _buyToLevel(upper + 200);
            assertEq(hook.poolState(poolId).bandCursor, uint32(index) + 1, "and completed in turn");
        }
    }

    // --- Scenario: Extension stops at the cap ---

    function test_extensionStopsAtTheCap() public {
        // Accrue *first*: once the ladder is capped out, diversion stops, so the fund could not be filled
        // afterwards. This way the inventory is unambiguously available and the cap is the only thing
        // standing in the way.
        _sell(MEASURED_SELL);
        _clearAccrual();
        uint256 accrued = hook.poolState(poolId).milestoneFundAccrued;
        assertGt(accrued, 0, "there is inventory to fund a band with");

        hook.forceLadderCappedOut(poolId);
        assertEq(hook.poolState(poolId).feeFundedBandsCreated, Bounds.MAX_FEE_FUNDED_BANDS, "the cap is reached");

        _approachWithoutRequiring(uint256(hook.launchConfig(poolId).bandCount));

        PoolState memory state = hook.poolState(poolId);
        assertFalse(state.liveBand.deployed, "no further band is created, however much has accrued");
        assertEq(state.feeFundedBandsCreated, Bounds.MAX_FEE_FUNDED_BANDS, "and the count does not pass the cap");
        assertEq(state.milestoneFundAccrued, accrued, "the accrued inventory is simply left in custody");
    }

    function test_theCapIsThirtyFeeFundedBands() public view {
        uint8 bandCount = hook.launchConfig(poolId).bandCount;

        assertEq(uint256(Bounds.MAX_FEE_FUNDED_BANDS), 30, "the protocol maximum the spec names");
        assertTrue(
            LadderLib.withinLadderCap(bandCount, bandCount, Bounds.MAX_FEE_FUNDED_BANDS - 1), "one slot still open"
        );
        assertFalse(LadderLib.withinLadderCap(bandCount, bandCount, Bounds.MAX_FEE_FUNDED_BANDS), "and none at the cap");

        // Core bands are always addressable: the cap counts only the extension.
        for (uint256 i = 0; i < bandCount; i++) {
            assertTrue(LadderLib.withinLadderCap(bandCount, i, Bounds.MAX_FEE_FUNDED_BANDS), "core band unaffected");
        }
    }

    /// @dev The count is of bands actually *created*, not of indices passed. A level the price jumped was
    /// never created and so must not consume one of the thirty slots.
    function test_theCapCountsCreatedBandsNotSkippedLevels() public {
        _exhaustCoreLadder();
        _sell(MEASURED_SELL);
        _clearAccrual();

        // Jump straight past two fee-funded levels without either being deployed.
        (, int24 upper4) = _bandLevels(4);
        _buyToLevel(upper4 + 100);
        _buyToLevel(upper4 + 110);

        PoolState memory state = hook.poolState(poolId);
        assertGe(state.bandCursor, 5, "the cursor stepped over the levels the price cleared");
        assertEq(state.feeFundedBandsCreated, 0, "but none of them was created, so no slot was consumed");
    }
}
