// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {FixedPoint96} from "v4-core/src/libraries/FixedPoint96.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

import {MilestoneBase} from "../../src/MilestoneBase.sol";
import {Orientation} from "../../src/libraries/Orientation.sol";
import {Phase, PoolState} from "../../src/types/LaunchTypes.sol";

import {TestRouter} from "../Fixtures.sol";
import {BaseForkTest} from "./ForkFixtures.sol";

/// @notice Adversarial trading against the live Base v4 singleton (task 12.4).
///
/// @dev Four attacks the design Risks register names and declines to prevent — flash-pump graduation,
/// band-boundary sandwiching, in-band oscillation and fee-collection spam. Each is *accepted* rather than
/// blocked, and each acceptance rests on a claim about cost: the attacker pays the pool's spread, the
/// protocol's state stays consistent, and nothing the attacker does moves value their way.
///
/// That is precisely the class of claim a locally deployed manager cannot settle. Every one of these
/// attacks is priced by v4's own fill arithmetic, and a unit test measures that arithmetic against the same
/// build of v4 that produced it — so an attack that is unprofitable only because our submodule and our test
/// agree looks identical to one that is unprofitable in production. Against the deployed singleton the
/// counterparty is not in on it.
///
/// The unit suite states each of these scenarios once already; this is deliberately the same claim with the
/// counterparty swapped, not a second set of claims. Where the fork adds something it is the *scale* of the
/// evidence: real tick-bitmap traversal across 32 curve positions, real fee accounting on the full-range
/// position, and an attacker who is a separate contract with its own balance, so "unprofitable" is read off
/// that balance rather than inferred.
contract ForkAdversarialTest is BaseForkTest {
    /// @dev A second router, so the attacker's trades and their ETH are distinguishable from the fixture's.
    TestRouter internal attacker;

    /// @dev Levels inside a band, short of its top: enough to be unambiguously within the range, small
    /// against the template's 447-level width.
    int24 internal constant INSIDE = 100;

    /// @dev Levels past a band's top — the crossing that completes the milestone.
    int24 internal constant PAST_TOP = 200;

    /// @dev Round trips in the oscillation loop. Three is what the unit scenario uses; the claim is about
    /// each trip in isolation, so more of them would only cost fork time.
    uint256 internal constant ROUND_TRIPS = 3;

    function setUp() public virtual override {
        super.setUp();

        attacker = new TestRouter(IPoolManager(address(manager)));
        vm.deal(address(attacker), FORK_FLOAT);
    }

    // --- Scenario (graduation): The crossing swap itself does not graduate ---
    // --- Scenario (graduation): Any address can trigger graduation ---
    //
    // The Risks register concedes the flash pump is mitigated by cost alone, so cost is what this asserts.
    // The pumper buys the entire curve in one swap, graduates the pool themselves rather than risk being
    // front-run out of it, and dumps straight back — and ends poorer by at least the ETH that graduation
    // moved out of the pool, because the split leaves only the LP seed behind to sell into.
    function test_aFlashPumpThroughGraduationLosesThePumperMoney() public {
        uint256 ethBefore = address(attacker).balance;
        int24 far = hook.poolState(poolId).farLevel;

        // Price-limited at the far level, which is the *most* favourable version of the attack: above it
        // nothing provides liquidity until graduation runs, so an unlimited buy would take the last of the
        // curve and then carry the price to the edge of tick space at no marginal cost.
        attacker.swapToLimit(key, true, -int256(FORK_FLOAT), _sqrtAtLevel(far));

        uint256 pumped = ethBefore - address(attacker).balance;
        uint256 held = token.balanceOf(address(attacker));

        assertGt(pumped, 0, "the pump spent real ETH");
        assertGt(held, 0, "and bought the curve out");
        assertGe(_level(), far, "the price reached the far level");
        assertEq(uint8(hook.poolPhase(poolId)), uint8(Phase.BONDING_CURVE), "the crossing swap did not graduate");
        assertEq(hook.poolState(poolId).graduatedAt, 0, "so nothing was recorded");
        assertEq(_fullRangeLiquidity(), 0, "and nothing was seeded");

        vm.prank(address(attacker));
        hook.graduate(key);

        assertEq(uint8(hook.poolPhase(poolId)), uint8(Phase.GRADUATED), "graduated on the pumper's own call");
        assertEq(hook.poolState(poolId).graduatedAt, block.timestamp, "and recorded it");
        assertGt(_fullRangeLiquidity(), 0, "the full-range position is seeded");

        // What the split moved out of reach: the creator and protocol shares are claim ledger entries now,
        // and no swap can reach a claim ledger.
        uint256 removed = hook.creatorClaimable(poolId) + hook.protocolClaimable(poolId);
        assertGt(removed, 0, "the creator and protocol shares left the pool");

        // Straight back out, selling everything the pump bought. A sell moves the price down in level and
        // therefore up in tick space, so its limit is the top of tick space rather than the bottom.
        attacker.swapToLimit(key, false, -int256(held), TickMath.MAX_SQRT_PRICE - 1);

        assertEq(token.balanceOf(address(attacker)), 0, "the pumper is flat in token again");
        assertLt(address(attacker).balance, ethBefore, "and out of pocket in ETH");
        assertGe(ethBefore - address(attacker).balance, removed, "by at least what graduation moved out of the pool");

        // Consistent state, not merely a losing attacker: the phase advanced once, the seeded position is
        // intact, and the curve it was funded from is gone.
        assertEq(uint8(hook.poolPhase(poolId)), uint8(Phase.GRADUATED), "the pool is still graduated");
        assertGt(_fullRangeLiquidity(), 0, "the seed survived the dump");
        assertEq(_curveLiquidity(0), 0, "and every curve position it replaced was burned");
        assertEq(_curveLiquidity(template.curvePositions - 1), 0, "at both ends of the curve");
    }

    // --- Scenario (milestone-ladder): Band-boundary trading cannot extract beyond band prices ---
    // --- Scenario (milestone-ladder): Price falling back does not un-complete a band ---
    //
    // The sandwich a band-boundary attacker would actually attempt: wake the band, sweep through its top so
    // the fills and the harvest are theirs, then sell straight back. Two claims, and the fork settles both
    // against the real book — the fills land inside the band's own price range, and the round trip costs
    // more than it returns.
    function test_sandwichingABandsHarvestCannotExtractBeyondItsPrices() public {
        _graduate();

        // Limited inside band 0, so the position the sandwich is aimed at exists when the attacker arrives.
        vm.recordLogs();
        _buyToLevel(FORK_FLOAT, _bandLower(0) + INSIDE);
        uint256 inventory = _deployedInventoryOf(vm.getRecordedLogs(), 0);

        (int24 lower, int24 upper,) = hook.bandLevels(poolId, 0);
        assertGt(_bandLiquidity(0), 0, "band 0 is live and unharvested");
        assertGt(inventory, 0, "and holds the inventory it was deployed with");

        uint256 ethBefore = address(attacker).balance;

        vm.recordLogs();
        attacker.swapToLimit(key, true, -int256(FORK_FLOAT), _sqrtAtLevel(upper + PAST_TOP));
        uint256 quote = _harvestedQuoteFromLogs(vm.getRecordedLogs());
        uint256 bought = token.balanceOf(address(attacker));

        assertGt(bought, 0, "the attacker did fill against the band");
        assertGt(quote, 0, "which harvested it on their own swap");
        assertTrue(hook.bandCompleted(poolId, 0), "and completed the milestone");

        // Level is `-tick`, so the band's *floor* token price is at its upper tick and its ceiling at its
        // lower tick. Quote per token is `1 / sqrtPrice^2`, so the floor valuation divides by the larger
        // sqrt twice. What the band realised must sit between the two, whatever the attacker did.
        (int24 tickLower, int24 tickUpper) = Orientation.levelRangeToTicks(lower, upper);
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(tickUpper);
        uint256 atFloorPrice =
            FullMath.mulDiv(FullMath.mulDiv(inventory, FixedPoint96.Q96, sqrtUpper), FixedPoint96.Q96, sqrtUpper);
        uint256 atCeilingPrice =
            FullMath.mulDiv(FullMath.mulDiv(inventory, FixedPoint96.Q96, sqrtLower), FixedPoint96.Q96, sqrtLower);

        assertLt(atFloorPrice, atCeilingPrice, "the two bounds really do bracket a range");
        assertGe(quote, atFloorPrice, "no part of the inventory was sold below the band's floor price");
        // The only thing that can carry the realised quote above the ceiling valuation is the band's own
        // accrued swap fees, which are earned rather than extracted, so a small allowance covers them.
        assertLe(quote, atCeilingPrice + atCeilingPrice / 20, "and none above its ceiling, band fees aside");

        // The other half of the sandwich. Selling back is the only exit, and there is no path to the band
        // except the pool, so the round trip pays the spread in both directions.
        attacker.swapToLimit(key, false, -int256(bought), TickMath.MAX_SQRT_PRICE - 1);

        assertEq(token.balanceOf(address(attacker)), 0, "the attacker is flat in token again");
        assertLt(address(attacker).balance, ethBefore, "and out of pocket in ETH");

        // Falling back below the range leaves the milestone where it was. Completion is a bitmap bit, not a
        // function of the current price.
        assertLt(_level(), lower, "the sell carried the price back below the band");
        assertTrue(hook.bandCompleted(poolId, 0), "the band stays complete");
        assertEq(_bandLiquidity(0), 0, "and is not re-minted");
        assertEq(hook.poolState(poolId).completedMilestones, 1, "one milestone, once");
    }

    // --- Scenario (milestone-ladder): In-band oscillation is permitted but cannot prevent completion ---
    //
    // Churn as an attack: buy up into the live band, sell back out below its floor, repeat. Every trip
    // starts and ends at the same price, so a fee-free round trip would leave the pool's two balances
    // exactly as it found them — both grow instead, which is the spread, paid twice, out of the oscillator's
    // pocket. Meanwhile the band's composition swings both ways without the position being lost, and the
    // milestone waits for a swap that ends above the top.
    function test_inBandOscillationChurnsTheBandButCannotPreventCompletion() public {
        _graduate();

        int24 floorLevel = _bandLower(0);
        int24 belowFloor = floorLevel - INSIDE;
        int24 nearTop = _bandUpper(0) - INSIDE;

        // The oscillator needs a token float first: selling back out of the band's range takes more token
        // than one leg into it returns, and a trader who is flat cannot leave the range downward at all.
        // Bought below band 0's floor, so this purchase does not itself wake the band.
        uint256 ethBefore = address(attacker).balance;
        attacker.swapToLimit(key, true, -int256(FORK_FLOAT), _sqrtAtLevel(belowFloor));
        assertEq(_deployedBandCount(), 0, "the float was bought below the band, which is still unminted");

        // Someone else wakes the band — the oscillator is attacking a position that already exists.
        _buyToLevel(FORK_FLOAT, floorLevel + INSIDE);
        uint128 liquidity = _bandLiquidity(0);
        assertGt(liquidity, 0, "band 0 is live");

        // Into the band, which is where every trip begins and ends.
        attacker.swapToLimit(key, true, -int256(FORK_FLOAT), _sqrtAtLevel(nearTop));
        assertFalse(hook.bandCompleted(poolId, 0), "stopping short of the top completes nothing");

        for (uint256 i = 0; i < ROUND_TRIPS; i++) {
            uint256 poolEth = address(manager).balance;
            uint256 poolToken = token.balanceOf(address(manager));

            // Out of the range, below its floor. Price-limited with the whole float as the budget, so v4
            // consumes exactly as much token as the move needs.
            attacker.swapToLimit(key, false, -int256(token.balanceOf(address(attacker))), _sqrtAtLevel(belowFloor));

            assertLt(_level(), floorLevel, "the trip really left the band's range");
            assertFalse(hook.bandCompleted(poolId, 0), "oscillating never completes it");
            assertTrue(hook.bandDeployed(poolId, 0), "and never loses it");
            assertEq(_bandLiquidity(0), liquidity, "with its liquidity intact");

            // And back up into it, to the same level the trip started from.
            attacker.swapToLimit(key, true, -int256(FORK_FLOAT), _sqrtAtLevel(nearTop));

            assertEq(_level(), nearTop, "the price is back where the trip started");
            assertFalse(hook.bandCompleted(poolId, 0), "a trip that ends inside the band completes nothing");
            assertEq(_bandLiquidity(0), liquidity, "and the position is still there");

            // Read from the counterparty's side, so no price arithmetic is needed: the price ended where it
            // began, so anything the pool gained is fee. The sell leg's fee is token-denominated and the buy
            // leg's is ETH-denominated, and every wei of both came out of the trader.
            assertGt(token.balanceOf(address(manager)), poolToken, "the sell leg left its fee in token");
            assertGt(address(manager).balance, poolEth, "and the buy leg left its fee in ETH");
        }

        assertEq(hook.poolState(poolId).completedMilestones, 0, "three round trips, no milestone");

        // Out entirely, so the cost of the churn is one number: the oscillator arrived with ETH and nothing
        // else, and leaves with less of it.
        attacker.swapToLimit(key, false, -int256(token.balanceOf(address(attacker))), TickMath.MAX_SQRT_PRICE - 1);
        assertEq(token.balanceOf(address(attacker)), 0, "the oscillator is flat in token");
        assertLt(address(attacker).balance, ethBefore, "and paid for every trip");

        // The first swap that ends above the top completes it, churn or no churn.
        _buyToLevel(FORK_FLOAT, _bandUpper(0) + PAST_TOP);
        assertTrue(hook.bandCompleted(poolId, 0), "the first swap ending above the top completes it");
        assertEq(hook.poolState(poolId).completedMilestones, 1, "exactly one milestone");
    }

    // --- Scenario (swap-fees): Repeated collection is harmless ---
    //
    // Griefing by calling the permissionless entry point in a loop. One call does the work; the rest find
    // nothing, say nothing, and cost a fraction of it. Worth re-running on the fork because the thing being
    // spammed is a real `modifyLiquidity(0)` fee collection against the deployed manager's own fee
    // accounting — the cheap early return is ours, but the expensive path it is being compared against is
    // v4's.
    function test_spammingFeeCollectionAccomplishesNothing() public {
        _graduate();

        // Accrue on both sides of the full-range position: a sell pays its fee in token, a buy in ETH. The
        // buy stops well short of band 0's floor so no ladder work lands in the middle of the measurement.
        _sell(token.balanceOf(address(router)) / 4);
        _buyToLevel(FORK_FLOAT / 100, _bandLower(0) - INSIDE);

        uint256 workingGasBefore = gasleft();
        (uint256 workedQuote, uint256 workedToken) = hook.collectFees(key);
        uint256 workingGas = workingGasBefore - gasleft();
        assertGt(workedQuote + workedToken, 0, "the first call had something to collect");

        uint128 liquidity = _fullRangeLiquidity();
        PoolState memory before = hook.poolState(poolId);
        uint256 creatorQuote = hook.creatorClaimable(poolId);
        uint256 protocolQuote = hook.protocolClaimable(poolId);
        uint256 hookEth = address(hook).balance;
        uint256 hookToken = token.balanceOf(address(hook));
        uint256 spammerEth = STRANGER.balance;

        for (uint256 i = 0; i < 5; i++) {
            vm.recordLogs();
            uint256 gasBefore = gasleft();
            vm.prank(STRANGER);
            (uint256 quoteFees, uint256 tokenFees) = hook.collectFees(key);
            uint256 gasUsed = gasBefore - gasleft();
            Vm.Log[] memory logs = vm.getRecordedLogs();

            // Both early returns sit above the `FeesCollected` emit, so silence is the observable form of
            // "nothing happened" — there is no zero-valued event to sift out of a log stream.
            assertEq(logs.length, 0, "nothing happened, so nothing was announced");
            assertEq(quoteFees, 0, "and nothing was collected");
            assertEq(tokenFees, 0, "in either currency");
            assertLt(gasUsed, workingGas / 4, "far cheaper than the call that did the work");
        }

        assertEq(_fullRangeLiquidity(), liquidity, "the position is unchanged in net terms");
        assertEq(hook.creatorClaimable(poolId), creatorQuote, "no ledger moved");
        assertEq(hook.protocolClaimable(poolId), protocolQuote, "on either side");
        assertEq(hook.poolState(poolId).milestoneFundAccrued, before.milestoneFundAccrued, "the fund did not grow");
        assertEq(hook.poolState(poolId).pendingLpQuote, before.pendingLpQuote, "nothing was drawn from the carry");
        assertEq(hook.poolState(poolId).pendingLpToken, before.pendingLpToken, "on either side");
        assertEq(address(hook).balance, hookEth, "no value left the manager a second time");
        assertEq(token.balanceOf(address(hook)), hookToken, "in either currency");

        // "No caller gains at the protocol's or the LP's expense", read off the caller: the spammer paid
        // five times for nothing and holds none of the pool's value.
        assertEq(STRANGER.balance, spammerEth, "the spammer received no ETH");
        assertEq(token.balanceOf(STRANGER), 0, "and no token");
    }

    // --- Log decoders ---
    //
    // Local rather than shared: the unit suite's decoders are private to fixtures rooted in a locally
    // deployed manager, which this layer cannot inherit from.

    /// @notice The `quoteProceeds` of the last {MilestoneBase.MilestoneHarvested} log in `logs`.
    function _harvestedQuoteFromLogs(Vm.Log[] memory logs) private pure returns (uint256 quote) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] != MilestoneBase.MilestoneHarvested.selector) continue;
            (quote,,) = abi.decode(logs[i].data, (uint256, uint256, uint32));
        }
    }
}
