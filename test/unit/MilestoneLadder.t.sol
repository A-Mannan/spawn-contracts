// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {LaunchpadTest} from "../Fixtures.sol";
import {MilestoneBase} from "../../src/MilestoneBase.sol";
import {LadderLib} from "../../src/libraries/LadderLib.sol";
import {Phase, PoolState} from "../../src/types/LaunchTypes.sol";

/// @notice The ladder's deployment triggers and the promise that none of them can block a trade.
///
/// @dev What is left to the ladder's other suites: {LadderSimulationTest} owns the simulated path and the
/// per-index bitmaps, {LadderCapTest} the per-swap deploy cap, {MilestoneMultiHarvestTest} the multi-band
/// harvest, {LadderLibTest} the pure geometry. This suite takes the four scenarios that are about a swap's
/// *direction and position* rather than its path — a deployed band cannot be jumped, nothing exists before
/// the first approach, sells never mint, and a band the price has already passed never mints — plus the
/// three that say the hook is never in a trader's way.
///
/// Two mechanics shape most of what follows. A band is single-sided token liquidity in a range *above* spot
/// in level space, so it can only ever be minted ahead of the price; and a harvest burns the position
/// outright, so "the band still has liquidity" and "the band is not yet complete" are the same observation
/// read two ways.
contract MilestoneLadderTest is LaunchpadTest {
    /// @dev Comfortably past band 0's top but nowhere near the second band's floor, which sits a further
    /// 1788 levels up: a stop chosen so a crossing buy completes exactly one milestone.
    int24 internal constant PAST_TOP = 300;

    function setUp() public virtual override {
        super.setUp();
        _graduate();
    }

    function _graduationLevel() private view returns (int24) {
        return hook.poolState(poolId).graduationLevel;
    }

    function _ladderSupply() private view returns (uint256) {
        return LadderLib.ladderSupply(SUPPLY, template.ladderSupplyShareWad);
    }

    /// @dev Mints band 0 by buying to a level inside it, and returns the liquidity v4 actually holds.
    function _deployFirstBand() private returns (uint128) {
        _buyToLevel(2_000 ether, _bandLower(0) + template.bandWidthLevels / 2);
        assertTrue(hook.bandDeployed(poolId, 0), "band 0 is live");
        return _bandLiquidity(0);
    }

    // --- Scenario: No bands exist immediately after graduation ---

    function test_noBandsExistImmediatelyAfterGraduation() public view {
        PoolState memory state = hook.poolState(poolId);

        assertEq(state.deployedBands, 0, "nothing is deployed");
        assertEq(state.completedBands, 0, "nothing is complete");
        assertEq(state.nextBandIndex, 0, "the cursor sits on the first band");
        assertEq(state.carriedInventory, 0, "nothing is carried");
        assertEq(state.milestoneFundAccrued, 0, "and nothing has accrued");

        // Every band's levels are already computable; none of them holds liquidity.
        for (uint256 i = 0; i < template.coreBandCount; i++) {
            assertEq(_bandLiquidity(i), 0, "no band was pre-minted");
        }

        // The whole allocation is undrawn, and it is really in the hook's hands rather than merely counted.
        assertEq(state.ladderInventoryRemaining, _ladderSupply(), "the whole ladder share is unstaked");
        assertGe(token.balanceOf(HOOK_ADDR), _ladderSupply(), "and sits in hook custody");
    }

    /// @dev Graduation cannot land the price inside a milestone: band 0's floor is a full spacing step above
    /// the graduation level, and the crossing swap stops at that level.
    function test_graduationDoesNotInstantlyCompleteAMilestone() public view {
        assertEq(_bandLower(0), _graduationLevel() + template.bandLevelSpacing, "one full step above");
        assertLt(_level(), _bandLower(0), "so the price is below the first band");
        assertEq(hook.poolState(poolId).completedMilestones, 0, "no milestone came free with graduation");
    }

    // --- Scenario: Downward swaps do not mint ---

    function test_downwardSwapsDoNotMint() public {
        vm.recordLogs();
        _sell(token.balanceOf(address(router)) / 10);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(_countLogs(logs, MilestoneBase.BandDeployed.selector), 0, "a sell mints nothing");
        PoolState memory state = hook.poolState(poolId);
        assertEq(state.deployedBands, 0, "the bitmap is untouched");
        assertEq(state.nextBandIndex, 0, "and the cursor did not move");
        assertEq(state.ladderInventoryRemaining, _ladderSupply(), "no inventory was staked");
    }

    /// @dev The direction rule holds with the ladder already running, not just from a standing start: a sell
    /// that walks back down through a live band mints nothing on the way, however close the next floor is.
    function test_aSellBelowALiveBandStillMintsNothing() public {
        _deployFirstBand();
        uint256 deployedBefore = _deployedBandCount();

        vm.recordLogs();
        _sellToLevel(token.balanceOf(address(router)) / 4, _bandLower(0) - 200);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(_countLogs(logs, MilestoneBase.BandDeployed.selector), 0, "still nothing minted");
        assertEq(_deployedBandCount(), deployedBefore, "the deployed set is unchanged");
        assertLt(_level(), _bandLower(0), "and the price really did leave the band from below");
    }

    // --- Scenario: Bands below spot never deploy ---

    /// @dev The state this rules out is only reachable through the deploy cap: simulation-driven deployment
    /// mints every band in a buy's path, so a band ends up behind spot undeployed exactly when the path
    /// crossed more floors than one swap may mint. An unbounded buy produces that, and the assertion is
    /// that the levels left behind stay empty — a single-sided sell band below spot would hold no token at
    /// all, so minting one would stake inventory into a position that could never sell it.
    function test_bandsBelowSpotNeverDeploy() public {
        _buy(5_000 ether);

        uint256 cap = uint256(template.maxDeploysPerSwap);
        assertGt(_level(), _bandUpper(cap), "the price is past the first band the cap refused");

        vm.recordLogs();
        _buy(1 ether);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint32[] memory deployed = _bandIndices(logs, MilestoneBase.BandDeployed.selector);
        for (uint256 i = 0; i < deployed.length; i++) {
            assertGe(_bandUpper(deployed[i]), _level(), "no band was minted below spot");
        }
        assertFalse(hook.bandDeployed(poolId, cap), "the level the first swap passed stays empty");
        assertEq(_bandLiquidity(cap), 0, "with no liquidity of its own");
    }

    /// @dev Stronger, and stated as the invariant rather than as one swap's outcome: at no point does a band
    /// wholly below spot hold liquidity. A completed band holds none either — a harvest burns the position —
    /// so the two cases collapse into one check over the whole ladder.
    function test_noBandBelowSpotHoldsLiquidity() public {
        _buy(5_000 ether);
        _buy(50 ether);

        int24 level = _level();
        uint256 checked;
        for (uint256 i = 0; i < template.coreBandCount; i++) {
            if (_bandUpper(i) >= level) continue;
            assertEq(_bandLiquidity(i), 0, "a band entirely below spot holds nothing");
            checked += 1;
        }
        assertGt(checked, 0, "the walk really did leave bands behind");
    }

    // --- Scenario: A deployed band cannot be jumped without filling ---

    /// @dev "Exiting the range's top necessarily consumed its inventory" is a claim about the pool, not about
    /// the hook's bookkeeping, so it is read off the harvest: the position's token is gone, the quote it
    /// converted into is what the harvest routed, and only rounding dust came back as residue.
    function test_aDeployedBandCannotBeJumpedWithoutFilling() public {
        uint128 liquidity = _deployFirstBand();
        assertGt(liquidity, 0, "the band's inventory is real pool liquidity");

        vm.recordLogs();
        _buyToLevel(2_000 ether, _bandUpper(0) + PAST_TOP);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        (uint256 proceeds, uint256 residue) = _harvestOf(logs, 0);
        assertGt(proceeds, 0, "the inventory converted to quote on the way through");
        assertEq(_bandLiquidity(0), 0, "the position is gone");
        assertTrue(hook.bandCompleted(poolId, 0), "and the band is complete");
        assertLt(residue, _perBand() / 1_000, "what came back is dust, not unsold inventory");
    }

    /// @dev The other half of the same scenario: while the band is live its inventory is liquidity the pool
    /// will actually quote against, not a hook-side reservation. Measured as the jump in active liquidity
    /// when the price steps from below the floor to inside the range.
    function test_aLiveBandsInventoryIsLiquidityInThePath() public {
        _buyToLevel(2_000 ether, _bandLower(0) - 50);
        uint128 outside = _poolLiquidity(poolId);

        uint128 inside = _deployFirstBand();
        assertEq(_poolLiquidity(poolId), outside + inside, "the band's liquidity is active at spot");
    }

    // --- Scenario: Swaps succeed in both directions ---

    /// @dev A walk across band 0 in steps — below it, into it, through its top, and back down — every one of
    /// which is a swap the hook must not reject. A harvest routes a buyback, which is itself a buy and moves
    /// the price further up, so a later stop can already be behind us; v4 rejects a limit at a price already
    /// passed inside `Pool.swap`, before any hook is consulted, so issuing one would test core rather than
    /// the hook. The assertions afterwards show the walk was not vacuous.
    function test_swapsSucceedInBothDirections() public {
        int24 lower = _bandLower(0);
        int24[5] memory stops = [
            lower - 200,
            lower + 50,
            lower + template.bandWidthLevels / 2,
            _bandUpper(0) + PAST_TOP,
            _bandUpper(0) + PAST_TOP + 400
        ];

        for (uint256 i = 0; i < stops.length; i++) {
            if (_level() >= stops[i]) continue;
            _buyToLevel(2_000 ether, stops[i]);
        }
        assertGt(_level(), _bandUpper(0), "the walk cleared the band");
        assertEq(hook.poolState(poolId).completedMilestones, 1, "crossing it on the way completed it");

        _sellAllToLevel(_graduationLevel() + 200);
        assertLt(_level(), lower, "and the price walked back down below the band");
        assertEq(uint8(hook.poolPhase(poolId)), uint8(Phase.GRADUATED), "still graduated, in both directions");
    }

    /// @dev The empty ladder is the case worth naming separately: with no band deployed there is no harvest
    /// path to exercise, so a sell here proves the hook's swap callbacks are not gating on ladder state.
    function test_aSellIntoAnEmptyLadderSucceeds() public {
        assertEq(hook.poolState(poolId).deployedBands, 0, "no band exists");

        _sellAllToLevel(_graduationLevel() - 2_000);
        assertLt(_level(), _graduationLevel(), "the price fell back below graduation");
        assertEq(uint8(hook.poolPhase(poolId)), uint8(Phase.GRADUATED), "which does not un-graduate the pool");
    }

    // --- Scenario: In-band oscillation cannot prevent completion ---

    /// @dev Three round trips into and out of a live band. The band's conversion state churns — token out on
    /// the way up, token back on the way down — without the position being lost or completed, and the
    /// milestone lands on the first swap that ends above the top.
    function test_inBandOscillationIsPermittedButCannotPreventCompletion() public {
        uint128 liquidity = _deployFirstBand();
        int24 mid = _bandLower(0) + template.bandWidthLevels / 2;

        for (uint256 i = 0; i < 3; i++) {
            _sellToLevel(token.balanceOf(address(router)) / 8, _bandLower(0) - 100);
            assertFalse(hook.bandCompleted(poolId, 0), "oscillating never completes it");
            assertEq(_bandLiquidity(0), liquidity, "and never loses the position");

            _buyToLevel(2_000 ether, mid);
            assertTrue(hook.bandDeployed(poolId, 0), "the band is still the live one");
            assertFalse(hook.bandCompleted(poolId, 0), "still not complete");
        }
        assertEq(hook.poolState(poolId).completedMilestones, 0, "three round trips, no milestone");

        _buyToLevel(2_000 ether, _bandUpper(0) + PAST_TOP);
        assertTrue(hook.bandCompleted(poolId, 0), "the first swap ending above the top completes it");
        assertEq(hook.poolState(poolId).completedMilestones, 1, "exactly one milestone");
    }

    /// @dev Why oscillating is not free, read from the counterparty's side so no price arithmetic is needed:
    /// the price ends where it began, so a fee-free round trip would leave the pool's balances exactly as it
    /// found them. Both grow instead — the sell leg's fee is token-denominated and the buy leg's is
    /// ETH-denominated — and every wei of that came out of the trader.
    function test_eachRoundTripPaysThePoolSpreadTwice() public {
        _deployFirstBand();
        int24 start = _level();

        uint256 poolEth = address(manager).balance;
        uint256 poolToken = token.balanceOf(address(manager));

        _sellToLevel(token.balanceOf(address(router)) / 8, _bandLower(0) - 100);
        _buyToLevel(2_000 ether, start);

        assertEq(_level(), start, "the price is back where it started");
        assertGt(token.balanceOf(address(manager)), poolToken, "the sell leg left its fee in token");
        assertGt(address(manager).balance, poolEth, "and the buy leg left its fee in ETH");
    }

    // --- No size or timing gate: derived, no scenario of its own ---

    /// @dev The payout-plugin delta restated "the hook never blocks a swap in the graduated phase" without
    /// this scenario name, so the claim is now derived rather than specified — but it is still the sharpest
    /// form of that requirement, so the test stays. Both halves in one transaction sequence: a buy far
    /// larger than any band, then two more swaps in the same block with no time passing between them.
    function test_noSizeOrTimingGate() public {
        uint256 blockAt = block.number;

        _buy(5_000 ether);
        assertGt(_deployedBandCount() + _completedBandCount(), 0, "the outsized buy went through the ladder");

        _buy(1 ether);
        _sell(token.balanceOf(address(router)) / 100);
        _buy(1_000);

        assertEq(block.number, blockAt, "all of it in one block");
        assertEq(uint8(hook.poolPhase(poolId)), uint8(Phase.GRADUATED), "and none of it was rejected");
    }

    /// @dev A swap sized to nothing is still a swap the hook must not reject, at the moment a harvest has
    /// just fired — the point where settlement state is freshest and a stale guard would show.
    function test_aDustSwapImmediatelyAfterAHarvestSucceeds() public {
        _deployFirstBand();
        _buyToLevel(2_000 ether, _bandUpper(0) + PAST_TOP);
        assertEq(hook.poolState(poolId).completedMilestones, 1, "a harvest just fired");

        _buy(1_000);
        _sell(1e12);
        assertEq(uint8(hook.poolPhase(poolId)), uint8(Phase.GRADUATED), "dust in both directions is fine");
    }

    // --- Log decoding ---

    function _harvestOf(Vm.Log[] memory logs, uint32 index)
        private
        pure
        returns (uint256 quoteProceeds, uint256 tokenResidue)
    {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] != MilestoneBase.MilestoneHarvested.selector) continue;
            if (uint256(logs[i].topics[2]) != index) continue;
            (quoteProceeds, tokenResidue,) = abi.decode(logs[i].data, (uint256, uint256, uint32));
            return (quoteProceeds, tokenResidue);
        }
        revert("no MilestoneHarvested for index");
    }
}
