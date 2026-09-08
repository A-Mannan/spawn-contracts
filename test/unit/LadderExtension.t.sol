// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {MilestoneBase} from "../../src/MilestoneBase.sol";
import {LadderLib} from "../../src/libraries/LadderLib.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Phase, PoolState, WAD} from "../../src/types/LaunchTypes.sol";
import {GraduatedFeeFixture} from "./SwapFees.t.sol";

/// @notice Unit tests for the `milestone-ladder` requirement "Fee-funded ladder extension" — what happens
/// once the core ladder's thirty bands are spent and the only inventory left is what swap fees divert.
///
/// @dev Two things about this rig are worth knowing before reading the assertions.
///
/// The first is that the extension region is *far* up. Band `coreBandCount` opens at
/// `graduationLevel + 31 * 2235` levels, which is about 1017x the graduation market cap, and the core
/// ladder below it is never minted here. So every buy is a price-limited run-up with a budget large
/// enough to be irrelevant, and the assertions read the band that appears rather than the ETH it took.
///
/// The second is that the boundary state is manufactured, by {MilestoneHookHarness.forceCoreLadderExhausted}
/// and its sibling `forceLadderCappedOut`. Walking there organically is not just slow, it is
/// self-defeating: thirty completed core bands means thirty harvests, each routing a buyback that pushes
/// price further up, so bands ahead of the cursor keep falling behind spot and *skip* — and a skipped core
/// band moves a whole per-band share into `carriedInventory`, which would fund the first extension band on
/// its own. "Extension requires accrued inventory" cannot be tested from a state where thirty bands of
/// carry are sitting there. The helpers write only the fields the funding decision reads; what a band then
/// does is the production path deciding for production reasons.
contract LadderExtensionTest is GraduatedFeeFixture {
    /// @dev A budget, not an amount. Every buy below is bounded by a level limit, so this only has to be
    /// more than the run-up costs — which is a few hundred ETH against the freshly seeded full-range
    /// position, not the millions dealt here.
    uint256 internal constant RUNUP_BUDGET = 1_000_000 ether;

    /// @dev Levels above a band's floor to stop at: inside the 447-level band, so it stays live.
    int24 internal constant INSIDE = 100;

    /// @dev Levels above a band's top to stop at, well inside the 1788-level gap to the next floor.
    int24 internal constant BEYOND = 200;

    function setUp() public virtual override {
        super.setUp();
        // The run-ups cross three orders of magnitude in price, so the router needs a float the default
        // 100k would bind.
        vm.deal(address(router), 5_000_000 ether);
    }

    // --- Rig ---

    /// @notice Places the pool exactly where the extension begins, and proves the premise the scenarios
    /// rest on: nothing but future accrual can fund another band.
    function _exhaustCoreLadder() private {
        harness.forceCoreLadderExhausted(poolId);

        PoolState memory state = hook.poolState(poolId);
        assertEq(state.nextBandIndex, template.coreBandCount, "the cursor sits on the first extension index");
        assertEq(state.ladderInventoryRemaining, 0, "the core allocation is spent");
        assertEq(state.carriedInventory, 0, "nothing is carried into the extension");
        assertEq(state.milestoneFundAccrued, 0, "and the fund is empty, so accrual is the only source left");
        assertEq(state.feeFundedBandsCreated, 0, "no extension band exists yet");
    }

    /// @notice Runs one sell through the waterfall and returns what it diverted into the milestone fund.
    /// @dev Called at the post-graduation price, where a sell of this size is the fixture's standard
    /// measured trade rather than a shock.
    function _accrue() private returns (uint256 diverted) {
        _sell(MEASURED_SELL);
        diverted = _collectAndCapture().diverted;

        assertGt(diverted, 0, "the sell's token fee diverted into the fund");
        assertEq(hook.poolState(poolId).milestoneFundAccrued, diverted, "which is where it now sits");
    }

    /// @notice The same, at an elevated price, clamped so the sell cannot fall below `floorLevel`.
    /// @dev Sized off the router's own float: a fixed token amount is a rounding error at graduation and a
    /// market-moving block a thousand times higher up.
    function _accrueAbove(int24 floorLevel) private returns (uint256 diverted) {
        _sellToLevel(token.balanceOf(address(router)) / 4, floorLevel);
        diverted = _collectAndCapture().diverted;

        assertGt(diverted, 0, "the sell's token fee diverted into the fund");
        assertGe(_level(), floorLevel, "and the sell stopped where it was told to");
    }

    /// @notice Buys up into band `index`, stopping inside it, and returns the log window.
    function _buyInto(uint256 index) private returns (Vm.Log[] memory) {
        vm.recordLogs();
        _buyToLevel(RUNUP_BUDGET, _bandLower(index) + INSIDE);
        return vm.getRecordedLogs();
    }

    // --- Scenario: Extension requires accrued inventory ---

    /// @dev The distinction this has to draw is between "the ladder could not reach the band" and "the
    /// ladder reached it and had nothing to put in it". So the buy stops *inside* band `coreBandCount`:
    /// the deploy simulation therefore did arrive at the floor, and the only thing left to stop the mint is
    /// an empty fund.
    function test_extensionRequiresAccruedInventory() public {
        _exhaustCoreLadder();
        uint256 first = template.coreBandCount;

        Vm.Log[] memory logs = _buyInto(first);

        assertEq(_countLogs(logs, MilestoneBase.BandDeployed.selector), 0, "no band was created");
        assertFalse(hook.bandDeployed(poolId, first), "and the level is still empty");
        assertGe(_level(), _bandLower(first), "though the price did reach it, so reach was never the blocker");

        // "Simply inactive" rather than "over": the swap went through untouched, and the index was not
        // consumed, so the very same band is still the one the ladder will build next.
        PoolState memory state = hook.poolState(poolId);
        assertEq(state.nextBandIndex, template.coreBandCount, "the cursor did not move past the level");
        assertEq(state.feeFundedBandsCreated, 0, "and no extension slot was spent");
        assertEq(uint8(hook.poolPhase(poolId)), uint8(Phase.GRADUATED), "the pool trades on regardless");
    }

    /// @dev The sharpest form of "simply inactive": the dry swap left the index open, so once accrual
    /// returns the ladder builds the *same* band it had failed to build, not the one above. The accrual sell
    /// is clamped back below the band's floor first, because single-sided token liquidity cannot be minted
    /// below spot — a band the price is still sitting inside could only ever be skipped, whatever the fund
    /// holds.
    function test_theLadderResumesOnceAccrualReturns() public {
        _exhaustCoreLadder();
        uint256 first = template.coreBandCount;

        _buyInto(first);
        assertEq(hook.poolState(poolId).feeFundedBandsCreated, 0, "the dry swap built nothing");
        assertEq(hook.poolState(poolId).nextBandIndex, template.coreBandCount, "and held the index open");

        uint256 diverted = _accrueAbove(_bandLower(first) - 500);

        Vm.Log[] memory logs = _buyInto(first);

        assertEq(_countLogs(logs, MilestoneBase.BandSkipped.selector), 0, "no level was given up");
        uint256 inventory = _deployedInventoryOf(logs, uint32(first));
        assertTrue(hook.bandDeployed(poolId, first), "the ladder resumed at the very index it had passed on");

        PoolState memory state = hook.poolState(poolId);
        assertEq(state.feeFundedBandsCreated, 1, "one extension band, created on the second attempt");
        assertEq(state.nextBandIndex, template.coreBandCount + 1, "and the cursor moved only now");
        assertLe(inventory, diverted, "funded out of the accrual and nothing else");
        assertApproxEqRel(inventory, diverted, 1e12, "essentially all of it, less mint dust");
    }

    // --- Scenario: A new band is created beyond the core ladder ---

    function test_aNewBandIsCreatedBeyondTheCoreLadder() public {
        _exhaustCoreLadder();
        uint256 diverted = _accrue();
        uint256 first = template.coreBandCount;

        Vm.Log[] memory logs = _buyInto(first);

        uint256 inventory = _deployedInventoryOf(logs, uint32(first));
        assertGt(inventory, 0, "a band appeared past the end of the core ladder");
        assertTrue(hook.bandDeployed(poolId, first), "recorded as deployed");
        assertGt(_bandLiquidity(first), 0, "with real liquidity in the pool, not just a flag");

        // Funded entirely by the diversion: the core allocation was spent before this began, so every token
        // in the position came out of the milestone fund.
        PoolState memory state = hook.poolState(poolId);
        assertLe(inventory, diverted, "no more than the fund held");
        assertApproxEqRel(inventory, diverted, 1e12, "and no less, less mint dust");
        assertEq(state.milestoneFundAccrued, 0, "the fund was consumed");
        assertEq(state.ladderInventoryRemaining, 0, "the core allocation stayed at zero");
        assertEq(state.feeFundedBandsCreated, 1, "counted against the extension cap");
        assertEq(state.nextBandIndex, template.coreBandCount + 1, "and the cursor moved on");
    }

    /// @dev A fee-funded band is not a different geometry, only a different funding source, so the formula
    /// that placed the core bands keeps running: one spacing step per index, same width. Asserted against
    /// what the mint actually emitted rather than against the library, so a divergence between the two
    /// would show up here.
    function test_theNewBandSitsOneSpacingStepAboveTheLast() public {
        _exhaustCoreLadder();
        _accrue();
        uint256 last = uint256(template.coreBandCount) - 1;
        uint256 first = template.coreBandCount;

        Vm.Log[] memory logs = _buyInto(first);

        (int24 lower, int24 upper) = _deployedLevelsOf(logs, uint32(first));
        assertEq(lower, _bandLower(first), "minted at the band's own floor");
        assertEq(upper, _bandUpper(first), "and its own top");
        assertEq(lower - _bandLower(last), template.bandLevelSpacing, "one spacing step above the last core band");
        assertEq(upper - lower, template.bandWidthLevels, "and the same width as every band below it");
        assertGt(lower, _bandUpper(last), "so it sits clear of the core ladder's top, gap intact");
    }

    /// @dev The point of the extension is that it produces *bands*, not a different instrument, so the
    /// harvest path must treat one exactly as it treats a core band: same completion, same four-way split,
    /// same pull-based credit.
    function test_aFeeFundedBandHarvestsAndRoutesLikeACoreBand() public {
        _exhaustCoreLadder();
        _accrue();
        uint256 first = template.coreBandCount;
        _buyInto(first);

        uint256 creatorBefore = hook.creatorClaimable(poolId);
        uint256 protocolBefore = hook.protocolClaimable(poolId);

        vm.recordLogs();
        _buyToLevel(RUNUP_BUDGET, _bandUpper(first) + BEYOND);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        (uint256 proceeds,, uint32 completed) = _harvestOf(logs, uint32(first));
        assertGt(proceeds, 0, "crossing the top completed the band and realised its quote");
        assertEq(completed, 1, "counted as a completed milestone");
        assertTrue(hook.bandCompleted(poolId, first), "and recorded as completed");
        assertEq(hook.poolState(poolId).completedMilestones, 1, "one milestone, from a fee-funded band");

        Routed memory r = _routedOf(logs, uint32(first));
        assertEq(
            r.creatorAmount + r.buybackQuote + r.protocolAmount + r.lpAmount,
            proceeds,
            "the four shares account for every wei of the proceeds"
        );
        assertEq(r.creatorAmount, (proceeds * template.defaultCreatorWad) / WAD, "creator share at its wad");
        assertEq(r.protocolAmount, (proceeds * template.defaultProtocolWad) / WAD, "protocol share at its wad");
        assertGt(r.buybackQuote, 0, "the buyback spent");
        assertGt(r.tokensBurned, 0, "and burned what it bought");

        assertEq(hook.creatorClaimable(poolId) - creatorBefore, r.creatorAmount, "credited, not pushed");
        assertEq(hook.protocolClaimable(poolId) - protocolBefore, r.protocolAmount, "likewise the protocol");
    }

    function test_theExtensionContinuesBandAfterBand() public {
        _exhaustCoreLadder();
        _accrue();
        uint256 first = template.coreBandCount;
        _buyInto(first);
        assertEq(hook.poolState(poolId).feeFundedBandsCreated, 1, "one band so far");

        // Each band needs its own accrual: a deployment zeroes the fund, and the diversion can never reach
        // the per-band cap, so nothing is left over to fund a second band for free.
        _accrueAbove(_bandLower(first));

        Vm.Log[] memory logs = _buyInto(first + 1);

        // One swap does both halves of the step: it crosses the live band's top on the way up, and mints
        // the next one at the floor above.
        assertEq(_countLogs(logs, MilestoneBase.MilestoneHarvested.selector), 1, "the band below completed");
        assertGt(_deployedInventoryOf(logs, uint32(first + 1)), 0, "and the one above was created");

        PoolState memory state = hook.poolState(poolId);
        assertEq(state.feeFundedBandsCreated, 2, "two extension bands created");
        assertEq(state.nextBandIndex, template.coreBandCount + 2, "cursor advanced band by band");
        assertEq(state.completedMilestones, 1, "with the first one harvested behind it");
        assertEq(
            _bandLower(first + 1) - _bandLower(first), template.bandLevelSpacing, "each a spacing step above the last"
        );
    }

    // --- A spent extension slot is never returned: derived, no scenario of its own ---

    /// @dev With reclaim removed (Decision 22) nothing ever credits a slot back, so the tally only counts
    /// up. {test_theExtensionContinuesBandAfterBand} shows that incidentally — it reads two after the first
    /// band has been harvested — and this states it outright: a completion is precisely the event a reclaim
    /// would have had something to give back for, and the count does not move for it.
    function test_aCompletedExtensionBandDoesNotReturnItsSlot() public {
        _exhaustCoreLadder();
        _accrue();
        uint256 first = template.coreBandCount;
        _buyInto(first);

        uint32 spent = hook.poolState(poolId).feeFundedBandsCreated;
        assertEq(spent, 1, "one slot spent on the band just built");

        // Crossing its top completes the band and realises its inventory, which is the moment under the old
        // design at which a slot could have come back.
        vm.recordLogs();
        _buyToLevel(RUNUP_BUDGET, _bandUpper(first) + BEYOND);
        assertEq(_countLogs(vm.getRecordedLogs(), MilestoneBase.MilestoneHarvested.selector), 1, "the band completed");
        assertTrue(hook.bandCompleted(poolId, first), "and is recorded as completed");

        assertEq(hook.poolState(poolId).feeFundedBandsCreated, spent, "the slot it spent stays spent");
        assertEq(hook.poolState(poolId).nextBandIndex, template.coreBandCount + 1, "while the cursor moved on");

        // Nor is there anything left to call that would give one back.
        bytes32 raw = PoolId.unwrap(poolId);
        string[3] memory sigs =
            ["reclaimBand(bytes32,uint256)", "reclaim(bytes32,uint256)", "releaseBandSlot(bytes32,uint256)"];
        for (uint256 i = 0; i < sigs.length; i++) {
            (bool ok,) = HOOK_ADDR.call(abi.encodeWithSignature(sigs[i], raw, first));
            assertFalse(ok, "no reclaim-shaped entry point exists");
        }
    }

    // --- Scenario: Extension stops at the cap ---

    /// @dev Accrual is deliberately present and untouched here. With a full fund and the price reaching the
    /// band's floor, the only difference from {test_aNewBandIsCreatedBeyondTheCoreLadder} — which builds a
    /// band from exactly this position — is the slot count, so the cap is provably what stopped it.
    ///
    /// The accrual has to happen *before* the cap is set, not after: diversion is gated on the very same
    /// {LadderLib.withinLadderCap} the deployment is, so a capped-out pool stops accruing as well as stops
    /// building ("diversion stops when the ladder is capped out"). Filling the fund first is what makes the
    /// two effects separable — this test then shows the cap blocking a band the fund could have paid for.
    function test_extensionStopsAtTheCap() public {
        _exhaustCoreLadder();
        uint256 diverted = _accrue();
        harness.forceLadderCappedOut(poolId);
        uint256 first = template.coreBandCount;

        Vm.Log[] memory logs = _buyInto(first);

        assertEq(_countLogs(logs, MilestoneBase.BandDeployed.selector), 0, "no further band is created");
        assertEq(_countLogs(logs, MilestoneBase.BandSkipped.selector), 0, "and none is stepped over either");
        assertFalse(hook.bandDeployed(poolId, first), "the level stays empty");
        assertGe(_level(), _bandLower(first), "even though the price reached it");

        PoolState memory state = hook.poolState(poolId);
        assertEq(state.feeFundedBandsCreated, template.maxFeeFundedBands, "the count is unchanged at the cap");
        assertEq(state.nextBandIndex, template.coreBandCount, "the cursor is unchanged");
        assertEq(state.milestoneFundAccrued, diverted, "and the accrual is left where it was, unspent");
        assertEq(uint8(hook.poolPhase(poolId)), uint8(Phase.GRADUATED), "trading continues, capped or not");
    }

    /// @dev The cap's arithmetic, at the edge and one past it. Sixty bands is the whole reach of the ladder:
    /// thirty core plus thirty fee-funded, which is also why the `deployedBands` bitmap's 256 slots are
    /// never a constraint.
    function test_theCapIsThirtyFeeFundedBands() public view {
        assertEq(template.maxFeeFundedBands, 30, "thirty fee-funded bands");
        uint8 core = template.coreBandCount;
        uint8 max = template.maxFeeFundedBands;

        assertTrue(LadderLib.withinLadderCap(core, core, max - 1, max), "the thirtieth extension band is allowed");
        assertFalse(LadderLib.withinLadderCap(core, core, max, max), "the thirty-first is not");
        assertTrue(LadderLib.withinLadderCap(core, core - 1, max, max), "and the cap never bars a core band");

        (,, bool lastExists) = hook.bandLevels(poolId, uint256(core) + max - 1);
        assertTrue(lastExists, "the last band the cap allows is a real level in tick space");
        assertFalse(LadderLib.withinLadderCap(core, uint256(core) + max, max, max), "one index past it is barred");
    }

    /// @dev A level the price cleared without a band being minted is not a slot spent. This is the case the
    /// cap has to get right, because the two counters move at different rates: `nextBandIndex` walks past
    /// every level, `feeFundedBandsCreated` only counts mints.
    function test_theCapCountsCreatedBandsNotSkippedLevels() public {
        _exhaustCoreLadder();
        uint256 first = template.coreBandCount;

        // With an empty fund nothing can be minted, so the price is free to run clear past two extension
        // levels without either of them being created.
        vm.recordLogs();
        _buyToLevel(RUNUP_BUDGET, _bandUpper(first + 1) + BEYOND);
        assertEq(_countLogs(vm.getRecordedLogs(), MilestoneBase.BandDeployed.selector), 0, "nothing was built");
        assertEq(hook.poolState(poolId).feeFundedBandsCreated, 0, "so no slot was spent on the way up");

        uint256 diverted = _accrueAbove(_bandLower(first + 1) + INSIDE);

        Vm.Log[] memory logs = _buyInto(first + 2);

        uint32[] memory skipped = _bandIndices(logs, MilestoneBase.BandSkipped.selector);
        assertEq(skipped.length, 2, "the two levels behind spot were stepped over");
        assertEq(skipped[0], uint32(first), "in ascending order");
        assertEq(skipped[1], uint32(first + 1), "in ascending order");

        uint256 inventory = _deployedInventoryOf(logs, uint32(first + 2));
        PoolState memory state = hook.poolState(poolId);
        assertEq(state.feeFundedBandsCreated, 1, "one band created, so one slot spent");
        assertEq(state.nextBandIndex, template.coreBandCount + 3, "while the cursor walked past three levels");
        assertLt(
            state.feeFundedBandsCreated,
            state.nextBandIndex - template.coreBandCount,
            "levels passed cost the extension nothing"
        );

        // And the skips took nothing with them: outside the core ladder there is no per-band share to carry,
        // so the whole of the fund went into the one band that was actually built.
        assertLe(inventory, diverted, "funded by the accrual alone");
        assertApproxEqRel(inventory, diverted, 1e12, "essentially all of it");
        assertLt(state.carriedInventory, _perBand(), "no per-band share was carried by either skip");
        assertLt(state.carriedInventory, diverted, "only the mint's own rounding dust");
    }

    // --- Log decoding ---

    struct Routed {
        uint256 creatorAmount;
        uint256 buybackQuote;
        uint256 tokensBurned;
        uint256 protocolAmount;
        uint256 lpAmount;
    }

    /// @notice The level bounds the {MilestoneBase.BandDeployed} log for `index` reported.
    function _deployedLevelsOf(Vm.Log[] memory logs, uint32 index) private pure returns (int24, int24) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] != MilestoneBase.BandDeployed.selector) continue;
            if (uint32(uint256(logs[i].topics[2])) != index) continue;
            (int24 lower, int24 upper,,) = abi.decode(logs[i].data, (int24, int24, uint128, uint256));
            return (lower, upper);
        }
        revert("no BandDeployed for index");
    }

    /// @notice The {MilestoneBase.MilestoneHarvested} log for `index`.
    function _harvestOf(Vm.Log[] memory logs, uint32 index) private pure returns (uint256, uint256, uint32) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] != MilestoneBase.MilestoneHarvested.selector) continue;
            if (uint32(uint256(logs[i].topics[2])) != index) continue;
            return abi.decode(logs[i].data, (uint256, uint256, uint32));
        }
        revert("no MilestoneHarvested for index");
    }

    /// @notice The {MilestoneBase.HarvestRouted} log for `index`.
    function _routedOf(Vm.Log[] memory logs, uint32 index) private pure returns (Routed memory r) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] != MilestoneBase.HarvestRouted.selector) continue;
            if (uint32(uint256(logs[i].topics[2])) != index) continue;
            (r.creatorAmount, r.buybackQuote, r.tokensBurned, r.protocolAmount, r.lpAmount) =
                abi.decode(logs[i].data, (uint256, uint256, uint256, uint256, uint256));
            return r;
        }
        revert("no HarvestRouted for index");
    }
}
