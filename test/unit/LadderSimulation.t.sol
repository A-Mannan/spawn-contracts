// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {HarnessLaunchpadTest} from "../HarnessFixtures.sol";
import {MilestoneBase} from "../../src/MilestoneBase.sol";
import {PoolState} from "../../src/types/LaunchTypes.sol";

/// @notice Simulation-driven band deployment and the per-index bitmaps (tasks 17.1 and 17.2).
///
/// @dev Every requirement here is about what happens *inside* one transaction — the order deployments
/// land in relative to the fill, how many bands are live at once, which indices the walk touches. None of
/// that survives to post-transaction state, so the assertions run against the recorded log and against
/// {MilestoneHookHarness}'s `afterSwap` snapshots rather than against getters.
///
/// The geometry these tests are sized against, all derived from the default template: graduation level
/// −152025, band `i` spanning `[-149790 + 2235i, -149343 + 2235i]`, so spacing 2235, width 447, and a
/// 1788-level gap between one band's top and the next one's bottom. Reaching band 0 from graduation costs
/// roughly 59 ETH against the seeded full-range liquidity.
contract LadderSimulationTest is HarnessLaunchpadTest {
    /// @dev Level spacing and width, restated as constants so a test can name a band boundary without
    /// re-deriving it. Asserted against the hook's own geometry in {test_geometryPremise}.
    int24 internal constant GRADUATION_LEVEL = -152025;
    int24 internal constant BAND_SPACING = 2235;
    int24 internal constant BAND_WIDTH = 447;

    /// @dev Not a scenario: a guard on the constants above, so a template change fails here with a clear
    /// message rather than as a mystifying mis-sized buy three tests down.
    function test_geometryPremise() public {
        _graduate();

        assertEq(hook.poolState(poolId).graduationLevel, GRADUATION_LEVEL, "graduation level");
        for (uint256 i = 0; i < 10; i++) {
            (int24 lower, int24 upper, bool exists) = hook.bandLevels(poolId, i);
            assertTrue(exists, "band exists");
            assertEq(lower, GRADUATION_LEVEL + int24(int256(i + 1)) * BAND_SPACING, "band lower");
            assertEq(upper, lower + BAND_WIDTH, "band upper");
        }
    }

    // --- Scenario: A buy crossing multiple undeployed bands deploys each before filling it ---

    /// @dev "Before filling it" is observable because the two happen in different places: deployment runs
    /// in `beforeSwap`, the fill inside `swap` itself. So every {MilestoneBase.BandDeployed} must precede
    /// the manager's own `Swap` event, which is the only log the fill emits. Asserting merely that both
    /// happened would pass on an implementation that minted afterwards and sold nothing.
    function test_aBuyCrossingMultipleUndeployedBandsDeploysEachBeforeFillingIt() public {
        _graduate();

        vm.recordLogs();
        // Limited just above band 2's top, so the walk reaches exactly three bands and the swap ends
        // above all three of their tops.
        _buyToLevel(2_000 ether, _bandUpper(2) + 50);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint32[] memory deployed = _bandIndices(logs, MilestoneBase.BandDeployed.selector);
        assertEq(deployed.length, 3, "three bands crossed, three deployments");
        for (uint256 i = 0; i < deployed.length; i++) {
            assertEq(deployed[i], uint32(i), "deployed in the order the path crosses them");
        }

        assertLt(
            _lastLogAt(logs, MilestoneBase.BandDeployed.selector),
            _firstLogAt(logs, IPoolManager.Swap.selector),
            "every band was minted before the swap that fills it"
        );

        // And the fill really happened: each band's inventory was consumed and harvested in the same
        // transaction, which is what makes the deployments load-bearing rather than decorative.
        uint32[] memory harvested = _bandIndices(logs, MilestoneBase.MilestoneHarvested.selector);
        assertEq(harvested.length, 3, "the swap filled all three");
        for (uint256 i = 0; i < harvested.length; i++) {
            assertEq(harvested[i], uint32(i), "filled in ascending order");
            assertEq(_bandLiquidity(i), 0, "position burned by its harvest");
        }
    }

    // --- Scenario: An undeployed band straddling spot deploys before the crossing buy fills it ---

    /// @dev The first clause of the requirement: a band whose range the path is about to enter mints
    /// first. Distinct from the test above in what it pins — here the swap stops *inside* band 0 rather
    /// than above it, so the band is minted and left live, and no harvest can be mistaken for the proof.
    function test_anUndeployedBandStraddlingSpotDeploysBeforeTheCrossingBuyFillsIt() public {
        _graduate();

        vm.recordLogs();
        _buyToLevel(2_000 ether, _bandLower(0) + BAND_WIDTH / 2);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(_countLogs(logs, MilestoneBase.BandDeployed.selector), 1, "band 0 minted");
        assertLt(
            _firstLogAt(logs, MilestoneBase.BandDeployed.selector),
            _firstLogAt(logs, IPoolManager.Swap.selector),
            "minted before the price entered its range"
        );

        int24 level = _level();
        assertGt(level, _bandLower(0), "the swap ended inside band 0's range");
        assertLt(level, _bandUpper(0), "and below its top, so the band is only partly filled");
        assertTrue(hook.bandDeployed(poolId, 0), "band 0 deployed");
        assertFalse(hook.bandCompleted(poolId, 0), "and not completed");
        assertGt(_bandLiquidity(0), 0, "its inventory is real, live pool liquidity");
    }

    /// @dev The second clause: "the straddle deadlock — a band that can neither deploy nor skip — cannot
    /// occur". A regression test for a reachable denial of service.
    ///
    /// The deadlock arose because mintability was decided against the *simulated* level while
    /// {_deployBand} mints at the real, unmoved pre-swap price. Single-sided token liquidity needs
    /// `currentTick >= tickUpper`, i.e. spot at or below the band's `levelLower`; the guard only skipped
    /// bands entirely behind spot, so a band straddling spot fell through to a two-sided mint, left the
    /// `currency0` debit unsettled, and reverted the unlock with `CurrencyNotSettled` — inside
    /// `beforeSwap`, so *every* buy reverted while spot sat in that window.
    ///
    /// Reachable through permissionless entry points only, which is the whole point: a buy big enough to
    /// hit the deploy cap leaves band N undeployed with the cursor still at N and carries spot above N's
    /// top; any sell then walks spot back down into N's interior, deploying and harvesting nothing on the
    /// way; the next buy was bricked. The window was 447 of every 2235 levels.
    function test_theStraddleDeadlockCannotOccur() public {
        _graduate();

        // Cap out: eight deploys, all eight harvested, spot left far above the ladder's reach.
        _buy(5_000 ether);
        uint32 stranded = hook.poolState(poolId).nextBandIndex;
        assertEq(stranded, 8, "the deploy cap stopped the walk at band 8");
        assertFalse(hook.bandDeployed(poolId, stranded), "band 8 was never minted");
        assertGt(_level(), _bandUpper(stranded), "and spot is above its top");

        // Any sell walks spot back down. Land it strictly inside band 8's range — the straddle.
        _sellAllToLevel(_bandLower(stranded) + BAND_WIDTH / 2);
        int24 level = _level();
        assertGt(level, _bandLower(stranded), "spot sits inside the undeployed band");
        assertLt(level, _bandUpper(stranded), "strictly inside: it can neither mint nor be behind spot");
        assertEq(hook.poolState(poolId).nextBandIndex, stranded, "and the cursor still points at it");

        // The buy that used to revert with `CurrencyNotSettled`.
        vm.recordLogs();
        _buy(1 ether);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint32[] memory skipped = _bandIndices(logs, MilestoneBase.BandSkipped.selector);
        assertEq(skipped.length, 1, "the straddling band took the skip escape");
        assertEq(skipped[0], stranded, "and it was band 8 that skipped");
        assertGt(hook.poolState(poolId).nextBandIndex, stranded, "the cursor advanced, so the ladder is not stuck");

        // The other candidate fix was `break`, which also avoids the revert. It is wrong, and this is the
        // assertion that separates the two: with `break` the cursor never advances, the condition stays
        // true forever, and the ladder is stranded at this index for the life of the pool.
        _buy(1 ether);
        assertGt(hook.poolState(poolId).nextBandIndex, stranded, "still not stuck on a second attempt");
    }

    // --- Scenario: A simulation mismatch can only under-deploy ---

    /// @dev Two properties together are the requirement. First, nothing is created or lost: the ladder's
    /// three custody fields move between each other constantly — a skip shifts core share into carry, a
    /// harvest returns residue to carry, a deployment drains both — so only their sum conserves, against
    /// exactly the token the log says left and came back.
    ///
    /// Second, "no inventory is ever sold that the simulation did not place": every band holding live pool
    /// liquidity announced itself with a {MilestoneBase.BandDeployed}. A divergence can leave a band
    /// unminted; it can never leave one minted unannounced.
    function test_aSimulationMismatchCanOnlyUnderDeploy() public {
        _graduate();

        uint256 custodyBefore = _undeployedInventory();
        uint256 balanceBefore = token.balanceOf(HOOK_ADDR);

        vm.recordLogs();
        _buy(5_000 ether);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256 placed = _tokenDeployed(logs);
        uint256 returned = _tokenReturned(logs);
        assertGt(placed, 0, "the sweep placed inventory");

        assertEq(
            _undeployedInventory(),
            custodyBefore - placed + returned,
            "ladder custody moved by exactly what the log placed and got back"
        );

        // The hook's real token balance tracks the same quantity: the buyback takes tokens and burns
        // them in the same frame (net zero on the balance, supply falls), and the LP share is donated in
        // quote only, so neither routing leg touches this identity.
        assertEq(token.balanceOf(HOOK_ADDR), balanceBefore - placed + returned, "and real custody agrees with it");

        uint256 announced = _countLogs(logs, MilestoneBase.BandDeployed.selector);
        assertEq(announced, 8, "the deploy cap bounded the sweep at eight");
        for (uint256 i = 0; i < uint256(template.coreBandCount); i++) {
            if (_bandLiquidity(i) == 0) continue;
            assertTrue(hook.bandDeployed(poolId, i), "no band holds liquidity it never announced");
        }
    }

    // --- Scenario: Multiple bands may be live simultaneously ---

    /// @dev The construction, and why it needs the harness. Band `i+1` sits above band `i`'s top, so
    /// reaching it means crossing band `i`'s top, which harvests band `i`. Live bands therefore pile up
    /// only between `beforeSwap`'s deployments and `afterSwap`'s harvests, and with both caps at 8 the
    /// leftover that survives a transaction is at most one. Asserting on post-transaction state would
    /// silently weaken this requirement into something the single-band case already satisfies.
    ///
    /// So: swap A ends inside band 0, leaving it live and incomplete. Swap B enters with that one live
    /// band, deploys eight more, and crosses all nine tops. At the top of B's `afterSwap` — before the
    /// harvest loop drains it — `deployedBands & ~completedBands` holds nine bits.
    function test_multipleBandsMayBeLiveSimultaneously() public {
        _graduate();

        _buyToLevel(2_000 ether, _bandLower(0) + BAND_WIDTH / 2);
        assertTrue(hook.bandDeployed(poolId, 0) && !hook.bandCompleted(poolId, 0), "band 0 live");

        harness.resetSnapshots();
        _buy(5_000 ether);

        assertEq(harness.snapshotCount(), 1, "one afterSwap to inspect");
        assertEq(harness.liveBandCountAt(0), 9, "nine bands live at once mid-transaction");

        // Per index, not merely nine of them: the requirement is that each live band's deployed state is
        // tracked independently by its index, and a population count alone would pass on a bitmap with
        // the right cardinality and the wrong bits.
        for (uint256 i = 0; i < 9; i++) {
            assertTrue(harness.bandLiveAt(0, i), "band tracked live at its own index");
        }
        assertFalse(harness.bandLiveAt(0, 9), "and band 9, never deployed, is not");
    }

    // --- Scenario: Completed bands never redeploy ---

    function test_completedBandsNeverRedeploy() public {
        _graduate();

        _buyToLevel(2_000 ether, _bandUpper(0) + 50);
        assertTrue(hook.bandCompleted(poolId, 0), "band 0 completed");
        assertEq(_bandLiquidity(0), 0, "and its position is burned");

        // Fall back below band 0's floor, then climb through its whole range again.
        _sellAllToLevel(_bandLower(0) - 500);
        assertLt(_level(), _bandLower(0), "spot is below the completed band");

        vm.recordLogs();
        _buyToLevel(2_000 ether, _bandUpper(0) + 50);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint32[] memory deployed = _bandIndices(logs, MilestoneBase.BandDeployed.selector);
        for (uint256 i = 0; i < deployed.length; i++) {
            assertTrue(deployed[i] > 0, "no position minted for the completed level");
        }
        assertEq(_bandLiquidity(0), 0, "band 0 holds no liquidity");
        assertTrue(hook.bandCompleted(poolId, 0), "the band stays complete");
        assertEq(_countLogs(logs, MilestoneBase.MilestoneHarvested.selector), 0, "and is not harvested twice");
    }

    // --- Scenario: Deployment order is strictly ascending ---

    /// @dev Across a whole sequence of swaps in both directions, not just within one. Falling price is
    /// what makes this non-trivial: a sell walks spot back down over indices the ladder has already
    /// passed, and the ascending guarantee is the reason none of them mints again.
    function test_deploymentOrderIsStrictlyAscending() public {
        _graduate();

        vm.recordLogs();
        _buyToLevel(2_000 ether, _bandUpper(1) + 50);
        _sellAllToLevel(_bandLower(0) - 500);
        _buyToLevel(2_000 ether, _bandUpper(3) + 50);
        _sellAllToLevel(_bandLower(2) - 500);
        _buyToLevel(2_000 ether, _bandUpper(5) + 50);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint32[] memory deployed = _bandIndices(logs, MilestoneBase.BandDeployed.selector);
        assertGt(deployed.length, 2, "the sequence deployed several bands");
        for (uint256 i = 1; i < deployed.length; i++) {
            assertGt(deployed[i], deployed[i - 1], "no band below an already-deployed index is deployed");
        }

        // The cursor is the structural form of the same property: it is a high-water mark, so nothing
        // below it can mint whatever the price does afterwards.
        PoolState memory state = hook.poolState(poolId);
        assertGt(state.nextBandIndex, deployed[deployed.length - 1], "the cursor is past every deployment");
    }
}
