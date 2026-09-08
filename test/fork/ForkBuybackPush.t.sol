// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";

import {MilestoneBase} from "../../src/MilestoneBase.sol";
import {PoolState} from "../../src/types/LaunchTypes.sol";

import {BaseForkTest} from "./ForkFixtures.sol";

/// @notice The buyback price push, re-measured against the live Base v4 singleton under multi-band
/// deployment (task 12.5).
///
/// @dev The design Risks register carries this as an open quantity rather than a settled one. Its entry —
/// "The buyback moves the price, and could in principle skip the next milestone" — records a group 9
/// measurement of roughly 2,350 levels (~26%) for a default 20% buyback share of a full band's proceeds,
/// against the template's 2,235-level band spacing. Those two numbers are close enough that the push can
/// carry price into the next band's range, and the entry's resolution is that this is a *partial fill*
/// rather than a skip, because simulation-driven deployment (Decision 15) has already minted that band by
/// the time the harvest runs. It closes by naming this file's job: "The group 9 measurement is repeated as
/// a fork-test assertion under multi-band deployment."
///
/// Two things make that a fork assertion rather than a unit one. The push is a market buy against real v4
/// liquidity — the seeded full-range position and whatever live bands sit above spot — so its size is v4's
/// arithmetic, not ours, and the group 9 figure was measured against our own build of it. And the bound
/// being asserted is a *relationship* between that push and the ladder's geometry, so a push measured
/// anywhere other than against the deployed manager leaves the bound unasserted where it matters.
///
/// The measurement is possible from outside the transaction because the triggering swap is price-limited:
/// v4 stops it at the limit, the harvest and its buyback then run in `afterSwap`, and the level the
/// transaction ends at is therefore the limit plus the push. What is *not* observable from outside is a
/// per-harvest split of a multi-harvest swap, so the sweep here completes exactly one band, which is also
/// the configuration the group 9 figure describes.
///
/// The re-measurement, logged by the test itself and recorded here: **68 levels** for a 1.399 ETH buyback,
/// against the template's 2,235-level band spacing and 447-level band width — 3% of the gap to the next
/// band, and 15% of the way into it. That is far short of the ~2,350 levels group 9 saw, and the Risks
/// entry names the reason in its own first sentence: group 9 measured a buy "against the full-range
/// position", whereas under simulation-driven deployment the next band's single-sided inventory is minted
/// and sitting directly above spot, so the buyback fills against *that* instead. The bound, not the
/// number, is what is asserted below — the figure is block- and template-specific.
contract ForkBuybackPushTest is BaseForkTest {
    /// @dev Levels into a band, short of its top. The buy must end inside band 1 for band 1 to be deployed
    /// and yet uncompleted when band 0's harvest pushes into it.
    int24 internal constant INSIDE = 100;

    /// @dev A budget, not a spend: every buy here is price-limited.
    uint256 internal constant BUDGET = 2_000_000 ether;

    // --- Scenario (milestone-ladder): A deployed band cannot be jumped without filling ---
    // --- The buyback push cannot carry price past an undeployed band: derived from the design Risks ---
    //
    // One sweep, ending inside band 1. Its simulated path deploys bands 0 and 1; crossing band 0's top
    // harvests it, and the buyback share of those proceeds is spent as a market buy from a spot price that
    // is already inside band 1. So the push runs into band 1's own inventory rather than into thin
    // full-range liquidity, which is the whole of the Risks entry's resolution — and the level the
    // transaction ends at is the bound to assert.
    function test_theBuybackPushLandsInsideTheDeployedNextBandOrBelowIt() public {
        _graduate();

        int24 target = _bandLower(1) + INSIDE;

        vm.recordLogs();
        _buyToLevel(BUDGET, target);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256 buybackQuote = _buybackQuoteFromLogs(logs);
        PoolState memory state = hook.poolState(poolId);

        // The configuration the measurement is about: two bands minted by one swap's simulated path, the
        // lower of them harvested by that same swap, and the buyback actually spent.
        assertTrue(hook.bandCompleted(poolId, 0), "band 0 was harvested by the sweep that crossed its top");
        assertTrue(hook.bandDeployed(poolId, 1), "band 1 was already minted when the harvest ran");
        assertFalse(hook.bandCompleted(poolId, 1), "and was not itself completed");
        assertEq(state.completedMilestones, 1, "exactly one milestone, so one buyback to measure");
        assertGt(buybackQuote, 0, "which spent its share as a real market buy");
        assertGt(_bandLiquidity(1), 0, "band 1's position survived the push: a partial fill, not a burn");

        // The push: the swap stopped at its limit, so everything above it is the buyback's. v4 leaves a
        // `zeroForOne` swap that crosses an initialised tick exactly one tick past it, so allow a level of
        // slack on the baseline rather than pretending the limit is hit to the tick.
        int24 pushed = _level();
        assertGe(pushed + 1, target, "the buyback only ever raises the level");
        int24 push = pushed > target ? pushed - target : int24(0);

        emit log_named_int("buyback push, in levels", push);
        emit log_named_int("band level spacing", template.bandLevelSpacing);
        emit log_named_uint("buyback quote, in wei", buybackQuote);

        // The bound the Risks entry claims. Both halves are asserted, because "inside the next band" and
        // "below it" have different consequences and only the second is safe on its own.
        assertLe(pushed, _bandUpper(1), "the push landed inside band 1's range or below it");
        assertLe(
            pushed, _bandLower(state.nextBandIndex), "and never past the floor of a band that has never been deployed"
        );

        // Why that second bound is the one that matters: at or below an undeployed band's floor the band can
        // still be minted single-sided, so nothing is skipped. Above it, the next simulation would have to
        // skip it and carry its inventory forward.
        assertEq(state.nextBandIndex, 2, "band 2 is the next one up, and it is untouched");
        assertFalse(hook.bandDeployed(poolId, 2), "not deployed");
        assertEq(_bandLiquidity(2), 0, "and holding nothing");

        // And the skip really did not happen, said two ways. No band announced one; and what the pool is
        // carrying is rounding dust from the two deployments, not a band's inventory -- a skip moves a
        // whole band's share into `carriedInventory`, which is what makes the comparison to band 1's own
        // funded inventory the right scale to judge it against.
        assertEq(_bandSkippedCount(logs), 0, "no band was skipped");

        uint256 bandOneInventory = _bandInventoryFromLogs(logs, 1);
        assertGt(bandOneInventory, 0, "band 1 was funded when it was minted");
        assertLt(
            state.carriedInventory,
            bandOneInventory / 1e6,
            "and what is carried is dust beside that, not a band's worth of inventory"
        );

        // The other half of the Risks entry: a partial fill left by the buyback settles on the next external
        // crossing, because a self-swap skips the hook's own callbacks. One swap later, band 1 completes.
        _buyToLevel(BUDGET, _bandUpper(1) + INSIDE);
        assertTrue(hook.bandCompleted(poolId, 1), "the next external crossing completes band 1");
        assertEq(hook.poolState(poolId).completedMilestones, 2, "one milestone later than the buyback's push");
    }

    /// @notice How many {MilestoneBase.BandSkipped} logs `logs` holds.
    function _bandSkippedCount(Vm.Log[] memory logs) private pure returns (uint256 count) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == MilestoneBase.BandSkipped.selector) count++;
        }
    }

    /// @notice The `tokenInventory` a {MilestoneBase.BandDeployed} log reports for band `index`.
    function _bandInventoryFromLogs(Vm.Log[] memory logs, uint32 index) private pure returns (uint256) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] != MilestoneBase.BandDeployed.selector) continue;
            if (uint32(uint256(logs[i].topics[2])) != index) continue;
            (,,, uint256 inventory) = abi.decode(logs[i].data, (int24, int24, uint128, uint256));
            return inventory;
        }
        revert("ForkBuybackPush: no BandDeployed log");
    }

    /// @notice The `buybackQuote` field of the last {MilestoneBase.HarvestRouted} log in `logs`.
    function _buybackQuoteFromLogs(Vm.Log[] memory logs) private pure returns (uint256 buybackQuote) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] != MilestoneBase.HarvestRouted.selector) continue;
            (, buybackQuote,,,) = abi.decode(logs[i].data, (uint256, uint256, uint256, uint256, uint256));
        }
    }
}
