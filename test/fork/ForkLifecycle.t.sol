// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";

import {PoolId} from "v4-core/src/types/PoolId.sol";

import {MilestoneBase} from "../../src/MilestoneBase.sol";
import {MilestoneToken} from "../../src/MilestoneToken.sol";
import {Bounds, HarvestSplit, LaunchConfig, Phase, PoolState, WAD} from "../../src/types/LaunchTypes.sol";

import {BaseForkHarnessTest} from "./ForkFixtures.sol";

/// @notice One launch driven from signature to final claim against the Base v4 singleton (task 12.2).
///
/// The whole group is a single ordered narrative: every step consumes the pool the previous step left
/// behind, because that ordering is the thing the local unit suite cannot prove. Unit tests exercise each
/// mechanism against a manager deployed in-process; here the counterparty is the real deployment, with its
/// real fee accounting, real tick bitmap and real ERC-6909 ledger, and the question is whether the phases
/// still compose end to end.
contract ForkLifecycleTest is BaseForkHarnessTest {
    /// @dev Budget for the creator's dev buy, sized like the unit suite's: `msg.value` is a ceiling, not a
    /// spend, so it only has to be more than the buy costs — and the refund of the rest is asserted.
    uint256 private constant DEV_BUY_BUDGET = 50_000 ether;
    /// @dev 2% of supply, comfortably inside `Bounds.MAX_DEV_BUY_SHARE_WAD`.
    uint64 private constant DEV_BUY_SHARE_WAD = 0.02e18;

    /// @dev Highest band index the sweep in step 4 reaches into. Bands 0..3 complete; band 4 is left live.
    uint32 private constant SWEEP_TOP = 4;
    /// @dev Levels past a band floor to stop at: far enough in to have minted the band, short of its top.
    int24 private constant INSIDE = 100;

    uint256 private constant RUNUP_BUDGET = 1_000_000 ether;
    uint256 private constant MEASURED_SELL = 1_000_000 ether;

    /// @dev Decoded `FeesRouted`.
    struct FeeRouting {
        uint256 lpQuote;
        uint256 lpToken;
        uint256 creatorQuote;
        uint256 protocolQuote;
        uint256 diverted;
        uint128 liquidityAdded;
    }

    /// @dev Decoded `HarvestRouted`.
    struct HarvestShares {
        uint256 creatorAmount;
        uint256 buybackQuote;
        uint256 tokensBurned;
        uint256 protocolAmount;
        uint256 lpAmount;
    }

    uint256 private devBuyTokens;

    /// @dev Running totals of what each party is owed, accumulated from every step that accrues. Step 7
    /// asserts the ledgers equal these, which is what "accruals from all sources aggregate" means here:
    /// curve proceeds, milestone harvests and swap fees all land in the same quote ledger.
    uint256 private expectedCreator;
    uint256 private expectedProtocol;

    /// @notice The lifecycle, in order, against live v4.
    ///
    /// Each step asserts phase, balances and routing for its own slice and hands the pool on. A failure
    /// names the step it happened in, so the narrative stays readable from the trace alone.
    function test_theWholeLifecycleRunsAgainstLiveV4() public {
        _launchWithDevBuy();
        _fillTheCurveJustInTime();
        _graduateInPlace();
        _sweepDeploysHarvestsAndRoutes();
        _collectAndRouteSwapFees();
        _extendTheLadderFromFees();
        _creatorTakesTheProceeds();
    }

    // --- Scenario (token-launch): Dev buy requires the creator's own transaction ---
    //
    // Decision 19's two halves cannot ride one launch, so the relay case gets a pool of its own: same signed
    // shape, same dev-buy share, submitted by a stranger. Everything after this step runs on the pool the
    // creator submitted themselves, which is the only way a dev buy reaches the curve at all.
    function _relayedLaunchSkipsTheDevBuy() private {
        LaunchConfig memory config = _defaultConfig("Relayed", "RLY");
        config.devBuyShareWad = DEV_BUY_SHARE_WAD;

        uint256 requested = (config.totalSupply * DEV_BUY_SHARE_WAD) / WAD;

        vm.recordLogs();
        (PoolId relayedId,, MilestoneToken relayedToken) = _launchRelayed(config, STRANGER);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        (address relayer, uint256 tokensRequested) = _devBuySkippedFromLogs(logs);
        assertEq(relayer, STRANGER, "the relayer that forfeited the dev buy is on the record");
        assertEq(tokensRequested, requested, "for the whole share the config asked for");
        assertEq(_firstLogAt(logs, MilestoneBase.DevBuyExecuted.selector), type(uint256).max, "and no dev buy executed");

        PoolState memory state = hook.poolState(relayedId);
        assertEq(state.creator, creator, "the recovered signer is the creator, not the relayer");
        assertEq(state.devBuyTotal, 0, "nothing was bought for the creator");
        assertEq(relayedToken.balanceOf(creator), 0, "who holds none of the supply");
        assertEq(relayedToken.balanceOf(STRANGER), 0, "and neither does the relayer");

        // The share remains bonding curve inventory: genesis minted position 0 and nothing swapped against
        // it, so the curve still holds every token the ladder and the curve were allotted.
        assertEq(state.curveDeployed, 1, "the curve stands at its opening position alone");
        assertEq(relayedToken.totalSupply(), config.totalSupply, "and the whole supply is still where launch put it");
    }

    // --- Scenario (token-launch): Dev buy consumes bonding curve inventory ---
    // --- A signed config sent by the creator carries its dev buy: derived, no scenario of its own ---
    //
    // The config is signed and the signature is checked on the way in, so this is the signed-config path in
    // full; the creator relays it themselves because `_openGenesis` gates the dev buy on the sender being the
    // creator, and a dev buy is in this task's scope.
    function _launchWithDevBuy() private {
        _relayedLaunchSkipsTheDevBuy();

        LaunchConfig memory config = _defaultConfig("Lifecycle", "LIFE");
        config.devBuyShareWad = DEV_BUY_SHARE_WAD;
        config.devBuyVestingSeconds = 0;

        devBuyTokens = config.totalSupply * DEV_BUY_SHARE_WAD / WAD;
        uint256 creatorEthBefore = creator.balance;

        vm.recordLogs();
        (poolId, key, token) = _launchSignedByCreatorWithValue(config, DEV_BUY_BUDGET);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        (uint256 tokensBought, uint256 ethSpent, uint32 vesting) = _devBuyFromLogs(logs);
        assertEq(tokensBought, devBuyTokens, "dev buy bought the configured share");
        assertGt(ethSpent, 0, "the dev buy spent ETH");
        assertLt(ethSpent, DEV_BUY_BUDGET, "the dev buy came in under budget");
        assertEq(vesting, 0, "vesting was disabled");

        // `msg.value` is a budget: the unspent remainder goes straight back.
        assertEq(
            creator.balance, creatorEthBefore + DEV_BUY_BUDGET - ethSpent, "the unspent dev buy budget was refunded"
        );
        // Zero vesting releases immediately, so the creator holds the tokens rather than a schedule.
        assertEq(token.balanceOf(creator), devBuyTokens, "the creator holds the dev buy");
        assertEq(hook.releasableDevBuy(poolId), 0, "nothing is left to release");

        PoolState memory state = hook.poolState(poolId);
        assertEq(uint8(state.phase), uint8(Phase.BONDING_CURVE), "the pool opened on the bonding curve");
        assertEq(state.devBuyTotal, devBuyTokens, "the dev buy is recorded");
        assertEq(state.devBuyReleased, devBuyTokens, "and fully released");
        assertEq(nft.ownerOf(nft.tokenIdOf(poolId)), creator, "the revenue NFT went to the creator");

        // The dev buy is a swap against the curve, not a mint: no token was created for it, and the curve
        // deployed just far enough ahead of the order to fill it.
        assertEq(token.totalSupply(), config.totalSupply, "the dev buy minted nothing; it bought from the curve");
        assertGt(_deployedCurveCount(), 1, "whose path deployed positions ahead of itself");
        assertLt(_deployedCurveCount(), template.curvePositions, "but only as many as filling the order required");
    }

    // --- Scenario (bonding-curve-phase): Later curve positions deploy as price approaches ---
    // --- Scenario (bonding-curve-phase): Positions form a nested staircase ---
    //
    // The simulation that decides which positions to mint runs against v4's own swap math, so "the
    // simulation agrees with the pool" is a claim only the deployed manager can settle.
    function _fillTheCurveJustInTime() private {
        PoolState memory before = hook.poolState(poolId);
        int24 halfway = before.openingLevel + template.curveSpanLevels / 2;
        uint256 deployedBefore = _deployedCurveCount();

        vm.recordLogs();
        _buyToLevel(FORK_FLOAT, halfway);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertGe(_level(), halfway, "the buy climbed halfway up the curve span");
        assertEq(uint8(hook.poolPhase(poolId)), uint8(Phase.BONDING_CURVE), "and stayed on the curve");

        uint256 deployed = _deployedCurveCount();
        assertGt(deployed, deployedBefore, "further positions deployed as the price approached them");
        assertLe(deployed, template.curvePositions, "and never more than the template holds");

        PoolState memory state = hook.poolState(poolId);
        // Deployment is strictly ascending and just-in-time, so the deployed set is a prefix with no holes.
        assertEq(uint256(state.curveDeployed), (uint256(1) << deployed) - 1, "the deployed set is a prefix");

        (uint256 minted, uint256 tokenSettled) = _mintedCurvePositionsFromLogs(logs);
        assertEq(minted, deployed - deployedBefore, "every position the buy newly reached was minted by it");
        assertGt(tokenSettled, 0, "and each mint settled token into the pool");

        // Each position spans from its own start level to the shared far level holding an equal token amount,
        // so a later position packs the same tokens into a narrower range: liquidity rises with the index.
        // That is the staircase, read back out of the live manager's position ledger.
        for (uint256 i = 1; i < deployed; i++) {
            assertGt(_curveLiquidity(i), _curveLiquidity(i - 1), "curve liquidity thickens toward the far level");
        }
    }

    // --- Scenario (graduation): The crossing swap itself does not graduate ---
    // --- Scenario (graduation): The first swap after the crossing auto-graduates ---
    // --- Scenario (graduation): All curve positions are burned ---
    // --- Scenario (graduation): Default split is applied ---
    // --- Scenario (graduation): Full-range position is created at the graduation price ---
    // --- Scenario (graduation): Phase advances to graduated ---
    function _graduateInPlace() private {
        PoolState memory before = hook.poolState(poolId);
        uint256 curvePositions = _deployedCurveCount();

        // The crossing buy reads the level at entry, which is still short of the far level.
        _buyToLevel(FORK_FLOAT, before.farLevel);
        assertGe(_level(), before.farLevel, "the buy carried the level to the far end of the curve");
        assertEq(uint8(hook.poolPhase(poolId)), uint8(Phase.BONDING_CURVE), "the crossing swap did not graduate");

        uint256 curveCountAtCrossing = _deployedCurveCount();
        assertGt(curveCountAtCrossing, curvePositions, "the rest of the curve deployed on the way up");
        assertEq(curveCountAtCrossing, template.curvePositions, "all of it, by the time the price reached far");
        assertGt(_curveLiquidity(0), 0, "and position 0 is still live right before graduation");

        uint256 creatorBefore = hook.creatorClaimable(poolId);
        uint256 protocolBefore = hook.protocolClaimable(poolId);

        vm.recordLogs();
        _buy(1_000);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        (
            int24 graduationLevel,
            uint256 quoteProceeds,
            uint256 lpSeedQuote,
            uint256 creatorQuote,
            uint256 protocolQuote,
            uint128 fullRangeLiquidity
        ) = _graduatedFromLogs(logs);

        assertGt(quoteProceeds, 0, "the burned curves returned the ETH buyers had paid in");
        assertEq(lpSeedQuote, quoteProceeds * template.lpSeedWad / WAD, "40% seeds the full-range position");
        assertEq(creatorQuote, quoteProceeds * template.proceedsCreatorWad / WAD, "55% is the creator's");
        // Protocol is the residual, so the three shares sum to the proceeds exactly rather than to dust short.
        assertEq(protocolQuote, quoteProceeds - lpSeedQuote - creatorQuote, "5% is the protocol's, as the residual");
        assertEq(lpSeedQuote + creatorQuote + protocolQuote, quoteProceeds, "the split is exact");

        PoolState memory state = hook.poolState(poolId);
        assertEq(uint8(state.phase), uint8(Phase.GRADUATED), "phase advanced to graduated");
        assertEq(state.graduatedAt, block.timestamp, "and it is stamped");
        assertEq(state.graduationLevel, graduationLevel, "the recorded level is the level graduation read");
        assertEq(graduationLevel, _level(), "which is the live tick at call time");

        // In-place morph: the curve is gone and one full-range position stands in its place, in the same pool.
        for (uint256 i = 0; i < curveCountAtCrossing; i++) {
            assertEq(_curveLiquidity(i), 0, "every curve position was burned");
        }
        assertGt(fullRangeLiquidity, 0, "the full-range position was seeded");
        assertEq(state.fullRangeLiquidity, fullRangeLiquidity, "state agrees with the event");
        assertEq(_fullRangeLiquidity(), fullRangeLiquidity, "and so does the live manager");
        assertEq(state.fullRangeTickLower, -Bounds.FULL_RANGE_TICK_BOUND, "lower bound");
        assertEq(state.fullRangeTickUpper, Bounds.FULL_RANGE_TICK_BOUND, "upper bound");
        assertGt(_poolLiquidity(poolId), 0, "so the graduated pool has active liquidity at spot");

        // Nothing was pushed: both shares landed in the pull ledgers.
        assertEq(hook.creatorClaimable(poolId) - creatorBefore, creatorQuote, "the creator's share accrued");
        assertEq(hook.protocolClaimable(poolId) - protocolBefore, protocolQuote, "the protocol's share accrued");
        expectedCreator += creatorQuote;
        expectedProtocol += protocolQuote;

        // The ladder starts empty: bands are minted just-in-time by later buys, not at graduation.
        assertEq(_deployedBandCount(), 0, "no band exists yet");
        assertEq(state.nextBandIndex, 0, "the cursor is at the first band");
    }

    // --- Scenario (milestone-ladder): A buy crossing multiple undeployed bands deploys each before filling it ---
    // --- Scenario (milestone-ladder): Multiple bands may be live simultaneously ---
    // --- Scenario (milestone-ladder): A sweeping swap harvests every band it completes within the cap ---
    // --- Scenario (milestone-ladder): Shares are distributed per configuration ---
    // --- Scenario (milestone-ladder): Routed amounts sum to the harvest ---
    //
    // One buy does the whole ladder round trip: `beforeSwap` mints bands 0-4 ahead of the price it simulates,
    // then `afterSwap` harvests the four whose tops that price passed and routes each four ways. Band 4 is
    // still live when the transaction ends, because `_harvestAfterSwap` samples the level once before its
    // loop, so no buyback inside the loop can complete a further band in the same frame.
    function _sweepDeploysHarvestsAndRoutes() private {
        int24 target = _bandLower(SWEEP_TOP) + INSIDE;

        uint256 creatorBefore = hook.creatorClaimable(poolId);
        uint256 protocolBefore = hook.protocolClaimable(poolId);
        uint256 supplyBefore = token.totalSupply();
        uint128 fullRangeBefore = _fullRangeLiquidity();
        harness.resetSnapshots();

        vm.recordLogs();
        _buyToLevel(RUNUP_BUDGET, target);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertGe(_level(), target, "the sweep climbed into band 4");

        uint32[] memory deploys = _bandIndices(logs, MilestoneBase.BandDeployed.selector);
        assertEq(deploys.length, uint256(SWEEP_TOP) + 1, "one deploy per band the simulated path crossed");
        assertEq(_countLogs(logs, MilestoneBase.BandSkipped.selector), 0, "every floor was ahead of spot, so no skips");
        for (uint256 i = 0; i < deploys.length; i++) {
            assertEq(uint256(deploys[i]), i, "bands deploy in strictly ascending order");
            assertGt(_deployedInventoryOf(logs, deploys[i]), 0, "each band was minted holding token");
        }

        uint32[] memory harvests = _bandIndices(logs, MilestoneBase.MilestoneHarvested.selector);
        assertEq(harvests.length, SWEEP_TOP, "every band the swap completed was harvested, inside the cap");
        assertLe(harvests.length, template.maxHarvestsPerSwap, "and the cap was respected");

        // Bands 0-4 were all live at the top of `afterSwap` — the single-live-band invariant is gone.
        assertGe(harness.snapshotCount(), 1, "the sweep produced an afterSwap snapshot");
        assertEq(harness.liveBandCountAt(0), uint256(SWEEP_TOP) + 1, "five bands were live at once");
        for (uint256 i = 0; i <= SWEEP_TOP; i++) {
            assertTrue(harness.bandLiveAt(0, i), "and each by its own index");
        }

        HarvestSplit memory split = hook.poolState(poolId).harvestSplit;
        uint256 routedCreator;
        uint256 routedProtocol;
        uint256 burned;
        for (uint256 i = 0; i < harvests.length; i++) {
            uint32 index = harvests[i];
            assertEq(uint256(index), i, "harvests run in ascending order too");
            // Deployment is a `beforeSwap` act and the harvest an `afterSwap` one, so within one transaction
            // the mint always precedes the fill. Log order is the only place that ordering is observable.
            assertLt(
                _logAt(logs, MilestoneBase.BandDeployed.selector, index),
                _logAt(logs, MilestoneBase.MilestoneHarvested.selector, index),
                "the band was deployed before the swap filled it"
            );

            uint256 proceeds = _harvestProceedsOf(logs, index);
            assertGt(proceeds, 0, "the band sold its inventory into the buy");

            HarvestShares memory s = _routedOf(logs, index);
            assertEq(s.creatorAmount, proceeds * split.creatorWad / WAD, "60% to the creator");
            assertEq(s.protocolAmount, proceeds * split.protocolWad / WAD, "10% to the protocol");
            assertLe(s.buybackQuote, proceeds * split.buybackWad / WAD, "at most 20% to the buyback");
            assertGt(s.tokensBurned, 0, "which bought token back and burned it");
            // LP absorbs any buyback shortfall, so the four shares sum to the harvest exactly, not dust short.
            assertEq(
                s.creatorAmount + s.buybackQuote + s.protocolAmount + s.lpAmount,
                proceeds,
                "routed amounts sum to the harvest"
            );

            routedCreator += s.creatorAmount;
            routedProtocol += s.protocolAmount;
            burned += s.tokensBurned;
        }

        // Nothing was pushed during settlement: the ledgers moved by exactly the routed sums.
        assertEq(hook.creatorClaimable(poolId) - creatorBefore, routedCreator, "creator ledger");
        assertEq(hook.protocolClaimable(poolId) - protocolBefore, routedProtocol, "protocol ledger");
        expectedCreator += routedCreator;
        expectedProtocol += routedProtocol;
        assertEq(supplyBefore - token.totalSupply(), burned, "the bought-back token left the supply");
        // The LP share arrives as a donation, which is fee revenue to the position rather than new liquidity.
        assertEq(_fullRangeLiquidity(), fullRangeBefore, "the full-range position was not enlarged by a harvest");

        assertEq(_completedBandCount(), SWEEP_TOP, "four milestones are complete");
        assertEq(hook.poolState(poolId).completedMilestones, SWEEP_TOP, "and counted");
        assertTrue(hook.bandDeployed(poolId, SWEEP_TOP), "band 4 is deployed");
        assertFalse(hook.bandCompleted(poolId, SWEEP_TOP), "and still live, to settle on a later swap");
        assertGt(_bandLiquidity(SWEEP_TOP), 0, "its inventory is still in the live pool");
    }

    // --- Scenario (swap-fees): Quote fees split three ways on collection ---
    // --- Scenario (swap-fees): Routed amounts sum to collected fees ---
    // --- Scenario (swap-fees): The LP share compounds ---
    // --- Scenario (swap-fees): Sell-side fees fund the next band ---
    // --- Scenario (swap-fees): Any address can trigger collection ---
    //
    // Which currency a fee lands in depends on direction, so both sides are traded: a sell pays token, a buy
    // pays ETH. Both stay inside band 4, which keeps the measured window clean — `collectFees` performs no
    // swap, so no harvest can run inside it and every delta below belongs to fee routing alone.
    function _collectAndRouteSwapFees() private {
        _sellAllToLevel(_bandLower(SWEEP_TOP) - 4 * INSIDE);
        _buyToLevel(RUNUP_BUDGET, _bandLower(SWEEP_TOP) + 2 * INSIDE);
        assertFalse(hook.bandCompleted(poolId, SWEEP_TOP), "the round trip stayed short of band 4's top");

        uint256 creatorBefore = hook.creatorClaimable(poolId);
        uint256 protocolBefore = hook.protocolClaimable(poolId);
        uint256 fundBefore = hook.poolState(poolId).milestoneFundAccrued;
        uint128 fullRangeBefore = _fullRangeLiquidity();
        uint256 strangerBefore = STRANGER.balance;

        // A passer-by triggers it, and is paid nothing for doing so.
        vm.recordLogs();
        vm.prank(STRANGER);
        hook.collectFees(key);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        (uint256 quoteFees, uint256 tokenFees) = _collectedFromLogs(logs);
        assertGt(quoteFees, 0, "the buy paid its fee in ETH");
        assertGt(tokenFees, 0, "and the sell paid its fee in token");
        assertEq(STRANGER.balance, strangerBefore, "the caller was paid nothing for collecting");

        FeeRouting memory r = _feeRoutingFromLogs(logs);
        assertEq(r.creatorQuote, quoteFees * Bounds.FEE_CREATOR_SHARE_WAD / WAD, "30% of the quote side accrues");
        assertEq(r.protocolQuote, quoteFees * Bounds.FEE_PROTOCOL_SHARE_WAD / WAD, "10% to the protocol");
        // LP is the residual on the quote side, so the three shares sum to what was collected exactly.
        assertEq(r.lpQuote, quoteFees - r.creatorQuote - r.protocolQuote, "and the rest is the LP's");
        assertEq(r.lpQuote + r.creatorQuote + r.protocolQuote, quoteFees, "routed amounts sum to collected fees");

        // The token side never reaches a claimant: a fifth builds the next band, the rest compounds.
        assertEq(r.diverted, tokenFees * template.milestoneFundShareWad / WAD, "a fifth funds the next band");
        assertEq(r.lpToken, tokenFees - r.diverted, "and the remainder compounds");
        assertEq(hook.poolState(poolId).milestoneFundAccrued - fundBefore, r.diverted, "the diversion sits in the fund");

        assertGt(r.liquidityAdded, 0, "the LP share was paired at spot and minted");
        assertEq(_fullRangeLiquidity() - fullRangeBefore, r.liquidityAdded, "into the full-range position itself");

        assertEq(hook.creatorClaimable(poolId) - creatorBefore, r.creatorQuote, "creator ledger");
        assertEq(hook.protocolClaimable(poolId) - protocolBefore, r.protocolQuote, "protocol ledger");
        expectedCreator += r.creatorQuote;
        expectedProtocol += r.protocolQuote;
    }

    // --- Scenario (milestone-ladder): A new band is created beyond the core ladder ---
    //
    // Reaching index 30 organically would mean thirty harvests, and the carry from thirty completed bands
    // would fund the extension on its own — so the boundary state is manufactured, exactly as the unit suite
    // does it. The helper writes only the fields the funding decision reads; the fund it then draws on is the
    // real diversion the previous step collected.
    function _extendTheLadderFromFees() private {
        harness.forceCoreLadderExhausted(poolId);

        PoolState memory forced = hook.poolState(poolId);
        assertEq(forced.nextBandIndex, template.coreBandCount, "the cursor sits on the first extension index");
        assertEq(forced.ladderInventoryRemaining, 0, "the core allocation is spent");
        assertEq(forced.carriedInventory, 0, "and nothing is carried, so the fund is the only source left");

        uint256 fund = forced.milestoneFundAccrued;
        assertGt(fund, 0, "which the collected sell-side fees had already filled");

        uint32 first = template.coreBandCount;
        int24 target = _bandLower(first) + INSIDE;
        uint256 creatorBefore = hook.creatorClaimable(poolId);
        uint256 protocolBefore = hook.protocolClaimable(poolId);

        vm.recordLogs();
        _buyToLevel(RUNUP_BUDGET, target);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertGe(_level(), target, "the buy climbed into the first extension band");
        assertEq(_countLogs(logs, MilestoneBase.BandSkipped.selector), 0, "no level was given up on the way");
        assertTrue(hook.bandDeployed(poolId, first), "a band appeared past the end of the core ladder");
        assertGt(_bandLiquidity(first), 0, "with real liquidity in the live pool, not just a flag");

        uint256 inventory = _deployedInventoryOf(logs, first);
        assertLe(inventory, fund, "funded out of the diversion and nothing else");
        assertApproxEqRel(inventory, fund, 1e12, "essentially all of it, less mint dust");

        PoolState memory now_ = hook.poolState(poolId);
        assertEq(now_.milestoneFundAccrued, 0, "the fund was consumed");
        assertEq(now_.ladderInventoryRemaining, 0, "the core allocation stayed at zero");
        assertEq(now_.feeFundedBandsCreated, 1, "counted against the extension cap");
        assertEq(now_.nextBandIndex, uint32(first) + 1, "and the cursor moved on");

        // The same buy carried band 4's top on the way, so its harvest settled here — a band left live by an
        // earlier swap settles on a later one. Fold what it accrued into the running totals.
        assertTrue(hook.bandCompleted(poolId, SWEEP_TOP), "the band left live by the sweep settled on this swap");
        expectedCreator += hook.creatorClaimable(poolId) - creatorBefore;
        expectedProtocol += hook.protocolClaimable(poolId) - protocolBefore;
    }

    // --- Scenario (revenue-claims): Accruals from all sources aggregate ---
    // --- Scenario (revenue-claims): Current holder claims successfully ---
    // --- Scenario (revenue-claims): Designated recipient claims successfully ---
    // --- Scenario (revenue-claims): Token-denominated fees never accrue to a claimant ---
    function _creatorTakesTheProceeds() private {
        uint256 creatorOwed = hook.creatorClaimable(poolId);
        uint256 protocolOwed = hook.protocolClaimable(poolId);

        // Curve proceeds, four harvests and one fee collection, all in the same quote ledger.
        assertGt(creatorOwed, 0, "the creator is owed ETH");
        assertEq(creatorOwed, expectedCreator, "and exactly what every source accrued");
        assertEq(protocolOwed, expectedProtocol, "and so is the protocol");

        // Decision 13: proceeds collected while a swap was in flight are held as ERC-6909 claims, so paying
        // out has to redeem them first. That the claimant cannot tell the difference is the point.
        uint256 heldAsClaims = manager.balanceOf(address(hook), 0);
        assertGt(heldAsClaims, 0, "part of hook custody is a claim rather than raw ETH");

        uint256 creatorEthBefore = creator.balance;
        vm.prank(creator);
        uint256 paidCreator = hook.claimCreator(poolId);

        assertEq(paidCreator, creatorOwed, "the NFT holder took the whole balance");
        assertEq(creator.balance - creatorEthBefore, creatorOwed, "in real ETH");
        assertEq(hook.creatorClaimable(poolId), 0, "and the ledger is cleared");
        assertLt(manager.balanceOf(address(hook), 0), heldAsClaims, "which redeemed claims on the way out");

        uint256 protocolEthBefore = PROTOCOL_RECIPIENT.balance;
        vm.prank(PROTOCOL_RECIPIENT);
        uint256 paidProtocol = hook.claimProtocol(poolId);

        assertEq(paidProtocol, protocolOwed, "the designated recipient took the protocol balance");
        assertEq(PROTOCOL_RECIPIENT.balance - protocolEthBefore, protocolOwed, "in real ETH");
        assertEq(hook.protocolClaimable(poolId), 0, "and that ledger is cleared too");

        // ETH and nothing else: the token side of the fees built walls and liquidity, and there is no token
        // ledger for either party to draw on.
        assertEq(token.balanceOf(creator), devBuyTokens, "the creator's token holding is still only the dev buy");
        assertEq(token.balanceOf(PROTOCOL_RECIPIENT), 0, "and the protocol holds no token at all");

        assertEq(uint8(hook.poolPhase(poolId)), uint8(Phase.GRADUATED), "the pool trades on after the claims");
    }

    // --- Log decoders ---
    //
    // Local copies rather than shared ones: the unit suite's decoders live in fixtures rooted in a locally
    // deployed manager, which this layer cannot inherit from.

    function _devBuyFromLogs(Vm.Log[] memory logs)
        private
        pure
        returns (uint256 tokensBought, uint256 ethSpent, uint32 vestingSeconds)
    {
        uint256 at = _firstLogAt(logs, MilestoneBase.DevBuyExecuted.selector);
        require(at != type(uint256).max, "ForkLifecycle: no DevBuyExecuted log");
        (tokensBought, ethSpent, vestingSeconds) = abi.decode(logs[at].data, (uint256, uint256, uint32));
    }

    function _devBuySkippedFromLogs(Vm.Log[] memory logs)
        private
        pure
        returns (address relayer, uint256 tokensRequested)
    {
        uint256 at = _firstLogAt(logs, MilestoneBase.DevBuySkipped.selector);
        require(at != type(uint256).max, "ForkLifecycle: no DevBuySkipped log");
        relayer = address(uint160(uint256(logs[at].topics[2])));
        tokensRequested = abi.decode(logs[at].data, (uint256));
    }

    function _mintedCurvePositionsFromLogs(Vm.Log[] memory logs)
        private
        pure
        returns (uint256 minted, uint256 tokenSettled)
    {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] != MilestoneBase.CurvePositionsDeployed.selector) continue;
            (uint256 m,, uint256 t) = abi.decode(logs[i].data, (uint256, uint32, uint256));
            minted += m;
            tokenSettled += t;
        }
    }

    function _graduatedFromLogs(Vm.Log[] memory logs)
        private
        pure
        returns (int24, uint256, uint256, uint256, uint256, uint128)
    {
        uint256 at = _firstLogAt(logs, MilestoneBase.Graduated.selector);
        require(at != type(uint256).max, "ForkLifecycle: no Graduated log");
        return abi.decode(logs[at].data, (int24, uint256, uint256, uint256, uint256, uint128));
    }

    function _harvestProceedsOf(Vm.Log[] memory logs, uint32 index) private pure returns (uint256 quoteProceeds) {
        uint256 at = _logAt(logs, MilestoneBase.MilestoneHarvested.selector, index);
        require(at != type(uint256).max, "ForkLifecycle: no MilestoneHarvested log for index");
        (quoteProceeds,,) = abi.decode(logs[at].data, (uint256, uint256, uint32));
    }

    function _routedOf(Vm.Log[] memory logs, uint32 index) private pure returns (HarvestShares memory s) {
        uint256 at = _logAt(logs, MilestoneBase.HarvestRouted.selector, index);
        require(at != type(uint256).max, "ForkLifecycle: no HarvestRouted log for index");
        (s.creatorAmount, s.buybackQuote, s.tokensBurned, s.protocolAmount, s.lpAmount) =
            abi.decode(logs[at].data, (uint256, uint256, uint256, uint256, uint256));
    }

    function _collectedFromLogs(Vm.Log[] memory logs) private pure returns (uint256 quoteFees, uint256 tokenFees) {
        uint256 at = _firstLogAt(logs, MilestoneBase.FeesCollected.selector);
        require(at != type(uint256).max, "ForkLifecycle: no FeesCollected log");
        (quoteFees, tokenFees) = abi.decode(logs[at].data, (uint256, uint256));
    }

    function _feeRoutingFromLogs(Vm.Log[] memory logs) private pure returns (FeeRouting memory r) {
        uint256 at = _firstLogAt(logs, MilestoneBase.FeesRouted.selector);
        require(at != type(uint256).max, "ForkLifecycle: no FeesRouted log");
        (r.lpQuote, r.lpToken, r.creatorQuote, r.protocolQuote, r.diverted, r.liquidityAdded) =
            abi.decode(logs[at].data, (uint256, uint256, uint256, uint256, uint256, uint128));
    }

    /// @notice Position of the log for `selector` carrying band `index`, or `type(uint256).max` if absent.
    /// @dev Log order is the only place the within-transaction ordering of a deploy and its harvest shows up.
    function _logAt(Vm.Log[] memory logs, bytes32 selector, uint32 index) private pure returns (uint256) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] != selector) continue;
            if (uint32(uint256(logs[i].topics[2])) != index) continue;
            return i;
        }
        return type(uint256).max;
    }
}
