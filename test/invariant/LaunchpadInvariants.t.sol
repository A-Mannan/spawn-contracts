// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IERC6909Claims} from "v4-core/src/interfaces/external/IERC6909Claims.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {MilestoneToken} from "../../src/MilestoneToken.sol";
import {Orientation} from "../../src/libraries/Orientation.sol";
import {Bounds, HarvestSplit, LaunchConfig, Phase, PoolState, WAD} from "../../src/types/LaunchTypes.sol";
import {LaunchpadTest} from "../Fixtures.sol";
import {LaunchpadHandler} from "./LaunchpadHandler.sol";

/// @notice The invariant layer of design Decision 11's three-layer test architecture: one randomised
/// campaign over several concurrent pools, asserting the properties that must hold after *any* sequence
/// of swaps, warps, collections, graduations, claims, and NFT transfers.
///
/// @dev One contract, not one per task group. Foundry checks every `invariant_*` in a contract against
/// the same generated sequence, so splitting tasks 13.2 / 13.3 / 13.4 across three files would run three
/// campaigns for exactly the coverage of one. The four tasks are the four sections below.
///
/// Two structural choices are worth stating, because both are consequences of
/// `fail_on_revert = false`:
///
///  1. **No assertion lives in the handler.** A reverting handler call is silently skipped by the runner,
///     so an assertion there would delete its own evidence. The handler records violations as counters;
///     everything is asserted here.
///  2. **Sequential properties are snapshotted, not recomputed.** "Deployment order strictly ascending"
///     and "per-swap caps respected" are statements about a single transaction, which no post-hoc state
///     read can express. The handler brackets every action with `vm.recordLogs()` and derives them from
///     the log, discarding the log when the action reverted.
contract LaunchpadInvariantsTest is LaunchpadTest {
    using StateLibrary for IPoolManager;

    LaunchpadHandler internal handler;

    /// @dev A second creator, so per-pool creator isolation is a statement about different parties and
    /// not just different keys into one mapping.
    uint256 internal constant CREATOR2_PK = 0xB0B5;
    address internal creator2;

    /// @dev Every address the system can move ETH to or from. No ETH enters or leaves after `setUp`, so
    /// the sum across this list is a conserved quantity — exactly, not within dust.
    address[] internal ethAccounts;
    uint256 internal ethTotalAtStart;

    PoolId internal poolId1;
    PoolId internal poolId2;
    PoolKey internal key1;
    PoolKey internal key2;

    function setUp() public override {
        // Pool 0: the fixture's default launch, still in `BONDING_CURVE`.
        super.setUp();

        creator2 = vm.addr(CREATOR2_PK);

        // Pool 1: graduated during setup, so the ladder, the fee waterfall, and both claim ledgers are
        // reachable from the campaign's very first call rather than only after the fuzzer stumbles into
        // a large enough buy.
        (poolId1, key1,) = _launchDirect(_defaultConfig("Milestone Two", "MILE2"));
        _graduatePool(poolId1, key1);

        // Pool 2: a different creator, a vesting dev buy, and a harvest split sitting on every bound edge
        // (creator 70%, buyback 10%, protocol 5%). Two distinct splits make "shares sum to one whole" a
        // claim about the configuration rather than about one hard-coded set of numbers.
        vm.deal(creator2, 100_000 ether);
        LaunchConfig memory config = Bounds.defaultConfig(creator2, "Milestone Three", "MILE3", SUPPLY);
        config.devBuyShareWad = 0.05e18;
        config.devBuyVestingSeconds = 90 days;
        config.harvestSplit =
            HarvestSplit({creatorWad: 0.7e18, buybackWad: 0.1e18, protocolWad: 0.05e18, lpWad: 0.15e18});
        vm.prank(creator2);
        (poolId2,, key2) = hook.launch{value: 90_000 ether}(config, "");

        PoolKey[] memory keys = new PoolKey[](3);
        keys[0] = key;
        keys[1] = key1;
        keys[2] = key2;

        address[] memory actors = new address[](5);
        actors[0] = creator;
        actors[1] = creator2;
        actors[2] = BUYER;
        actors[3] = STRANGER;
        actors[4] = imposter;

        // The campaign can spend up to 2_000 ether per buy across three pools for 64 calls, and every
        // buy the router cannot afford is a call the fuzzer wastes. Dealt before the conservation
        // baseline is captured, so it is part of the conserved total rather than an injection.
        vm.deal(address(router), 1_000_000 ether);

        handler =
            new LaunchpadHandler(IPoolManager(address(manager)), hook, nft, router, PROTOCOL_RECIPIENT, keys, actors);
        targetContract(address(handler));

        _recordEthAccounts();
        ethTotalAtStart = _ethTotal();
    }

    /// @dev The fixture's `_graduate()` is keyed to its own single pool; the campaign needs it per pool.
    /// Two swaps by necessity (Decision 18): the crossing buy cannot graduate inside its own `afterSwap`,
    /// so a dust buy arrives afterwards to trigger the auto-graduation in `beforeSwap`.
    function _graduatePool(PoolId id, PoolKey memory k) internal {
        int24 far = hook.poolState(id).farLevel;
        router.swapToLimit(k, true, -int256(2_000 ether), _sqrtAtLevel(far));
        router.swap(k, true, -int256(1_000));
        require(hook.poolState(id).phase == Phase.GRADUATED, "setup: pool did not graduate");
    }

    function _recordEthAccounts() private {
        ethAccounts.push(address(manager));
        ethAccounts.push(HOOK_ADDR);
        ethAccounts.push(address(router));
        ethAccounts.push(address(handler));
        ethAccounts.push(address(this));
        ethAccounts.push(address(nft));
        ethAccounts.push(address(support));
        ethAccounts.push(address(coldPaths));
        ethAccounts.push(creator);
        ethAccounts.push(creator2);
        ethAccounts.push(imposter);
        ethAccounts.push(PROTOCOL_ADMIN);
        ethAccounts.push(PROTOCOL_RECIPIENT);
        ethAccounts.push(BUYER);
        ethAccounts.push(RELAYER);
        ethAccounts.push(STRANGER);
    }

    function _ethTotal() private view returns (uint256 total) {
        for (uint256 i = 0; i < ethAccounts.length; i++) {
            total += ethAccounts[i].balance;
        }
    }

    /// @dev Hook custody of a launch token, read the way Decision 13 forces: raw balance *plus* any
    /// ERC-6909 claim. Anything the hook collects from the pool while a swap is in flight is minted as a
    /// claim rather than taken, so a claimant must not be able to tell the two apart — and neither may
    /// a conservation check.
    function _hookTokenCustody(MilestoneToken t) private view returns (uint256) {
        return
            t.balanceOf(HOOK_ADDR) + IERC6909Claims(address(manager)).balanceOf(HOOK_ADDR, uint256(uint160(address(t))));
    }

    /// @dev Native ETH is currency id 0.
    function _hookEthCustody() private view returns (uint256) {
        return HOOK_ADDR.balance + IERC6909Claims(address(manager)).balanceOf(HOOK_ADDR, 0);
    }

    function _popcount(uint256 x) private pure returns (uint256 n) {
        while (x != 0) {
            x &= x - 1;
            n += 1;
        }
    }

    // --- 13.2 Supply and value conservation ---

    /// @notice Every launched token sits with the hook, in the pool, with the router, or with the creator.
    /// @dev The four are the complete holder set by construction: supply is minted to the hook, the pool
    /// holds what backs positions and claims, the router is the only buyer, and the only outbound token
    /// transfer in the protocol is the dev-buy release to `state.creator`. Claims are not double-counted —
    /// what backs them is already in the manager's ERC20 balance.
    function invariant_everyTokenIsHeldByAKnownParty() public view {
        for (uint256 i = 0; i < handler.poolCount(); i++) {
            MilestoneToken t = handler.tokenAt(i);
            uint256 held = t.balanceOf(HOOK_ADDR) + t.balanceOf(address(manager)) + t.balanceOf(address(router))
                + t.balanceOf(handler.creatorAt(i));
            assertEq(held, t.totalSupply(), "a token escaped the known holder set");
        }
    }

    /// @notice Supply falls only by the buyback burns the harvest routing reported.
    /// @dev `MilestoneToken.burn` has exactly one call site in the protocol — the buyback leg of a
    /// harvest — and the token exposes no `burnFrom` and no post-construction mint. So the gap between
    /// minted and current supply must equal the summed `HarvestRouted.tokensBurned`, to the wei.
    function invariant_supplyFallsOnlyByRoutedBuybackBurns() public view {
        for (uint256 i = 0; i < handler.poolCount(); i++) {
            uint256 supplyNow = handler.tokenAt(i).totalSupply();
            assertLe(supplyNow, handler.initialSupplyAt(i), "supply grew after launch");
            assertEq(handler.initialSupplyAt(i) - supplyNow, handler.tokensBurned(i), "unexplained change in supply");
        }
    }

    /// @notice The hook always holds enough token to meet every token-denominated promise it has made.
    /// @dev The three ladder fields move between each other constantly — a skip shifts share into carry, a
    /// deployment drains carry and zeroes the fund — so their sum is the obligation, not any one of them.
    /// `assertGe` rather than `assertEq` because rounding dust is retained by the hook: the specs put dust
    /// on the protocol's side of the line, never against a claimant.
    function invariant_hookTokenCustodyCoversItsObligations() public view {
        for (uint256 i = 0; i < handler.poolCount(); i++) {
            PoolState memory s = hook.poolState(handler.poolIdAt(i));
            uint256 owed = s.ladderInventoryRemaining + s.carriedInventory + s.milestoneFundAccrued + s.pendingLpToken
                + (s.devBuyTotal - s.devBuyReleased);
            assertGe(_hookTokenCustody(handler.tokenAt(i)), owed, "hook cannot cover its token obligations");
        }
    }

    /// @notice The hook always holds enough ETH — raw or claimed — to pay out every pool's ledgers at once.
    /// @dev This is also where "dust is never negative from the protocol side" is asserted: the surplus of
    /// custody over obligations is the retained dust, and it may only ever be non-negative.
    function invariant_hookEthCustodyCoversClaimObligations() public view {
        uint256 owed;
        for (uint256 i = 0; i < handler.poolCount(); i++) {
            PoolId id = handler.poolIdAt(i);
            owed += hook.creatorClaimable(id) + hook.protocolClaimable(id) + hook.poolState(id).pendingLpQuote;
        }
        assertGe(_hookEthCustody(), owed, "hook cannot cover its ETH obligations");
    }

    /// @notice Every wei a harvest realised was routed to one of the four destinations.
    /// @dev Exact, not approximate: `HarvestRouted` folds any rounding shortfall into the LP leg rather
    /// than dropping it, so the four legs sum to the harvest's `quoteProceeds` with nothing left over.
    function invariant_routedAmountsSumToHarvestedAmounts() public view {
        for (uint256 i = 0; i < handler.poolCount(); i++) {
            assertEq(handler.routedQuote(i), handler.harvestedQuote(i), "harvest proceeds were not fully routed");
        }
    }

    /// @notice No sequence of actions creates or destroys ETH.
    /// @dev Nothing funds an account after `setUp`, so this is exact. It is the strongest single statement
    /// the layer makes: it covers the claim ledgers, the graduation split, the buyback swap, the dev-buy
    /// refund, and every ERC-6909 mint and burn at once, because all of them merely move this total around.
    function invariant_ethIsConserved() public view {
        assertEq(_ethTotal(), ethTotalAtStart, "ETH was created or destroyed");
    }

    // --- 13.3 Structural invariants ---

    /// @notice Every launch's harvest shares sum to one whole, whatever the campaign has done since.
    function invariant_harvestSharesSumToOneWhole() public view {
        for (uint256 i = 0; i < handler.poolCount(); i++) {
            HarvestSplit memory split = hook.poolState(handler.poolIdAt(i)).harvestSplit;
            uint256 sum = uint256(split.creatorWad) + split.buybackWad + split.protocolWad + split.lpWad;
            assertEq(sum, WAD, "harvest split no longer sums to one whole");
        }
    }

    /// @notice Bands deploy in strictly ascending order, once each, and a completed band never comes back.
    /// @dev The three counters cover ordering within a transaction; the per-pool identities cover it across
    /// the whole campaign. `popcount(deployed) + skips == nextBandIndex` is the load-bearing one: the cursor
    /// only ever advances past an index by deploying it or skipping it, so any index below the cursor that
    /// is neither would break this equality — which is what "deployment order strictly ascending" means in
    /// state rather than in a log.
    function invariant_bandDeploymentIsAscendingAndSingleUse() public view {
        assertEq(handler.violationDeployOrder(), 0, "a band deployed out of order");
        assertEq(handler.violationRedeployedCompletedBand(), 0, "a completed band was redeployed");
        assertEq(handler.violationBitmapCleared(), 0, "a deployed or completed bit was cleared");

        for (uint256 i = 0; i < handler.poolCount(); i++) {
            PoolState memory s = hook.poolState(handler.poolIdAt(i));

            assertEq(
                _popcount(s.deployedBands) + handler.bandSkipsOf(i),
                s.nextBandIndex,
                "the cursor does not account for every index below it"
            );
            assertEq(s.completedBands & ~s.deployedBands, 0, "a band completed without ever being deployed");
            assertEq(_popcount(s.completedBands), s.completedMilestones, "completion count disagrees with the bitmap");
            assertEq(
                _popcount(s.deployedBands >> template.coreBandCount),
                s.feeFundedBandsCreated,
                "fee-funded band count disagrees with the bitmap"
            );
        }
    }

    /// @notice No swap deploys or harvests more than the template permits.
    /// @dev Both caps are Decision 4's bound on settlement work per swap. A sweeping swap that crosses more
    /// bands than the cap harvests the lowest ones and leaves the rest live — the skip is the specified
    /// outcome, so the assertion is on the ceiling, not on completeness.
    function invariant_perSwapWorkCapsAreRespected() public view {
        assertLe(handler.maxDeploysInOneSwap(), template.maxDeploysPerSwap, "a swap deployed past the cap");
        assertLe(handler.maxHarvestsInOneSwap(), template.maxHarvestsPerSwap, "a swap harvested past the cap");
    }

    /// @notice Nothing ever reduces a pool's full-range liquidity.
    /// @dev The graduation position is code-locked: no removal path exists, which `make lock-check` enforces
    /// structurally at the source level. This is the same claim measured at runtime, against the position in
    /// the manager rather than against the hook's own record.
    function invariant_fullRangeLiquidityNeverDecreases() public view {
        assertEq(handler.violationFullRangeShrank(), 0, "full-range liquidity fell");
    }

    /// @notice The hook's record of its full-range position matches the position itself.
    function invariant_storedFullRangeLiquidityMatchesThePosition() public view {
        for (uint256 i = 0; i < handler.poolCount(); i++) {
            PoolState memory s = hook.poolState(handler.poolIdAt(i));
            assertEq(s.fullRangeLiquidity, handler.fullRangeLiquidityOf(i), "stored full-range liquidity drifted");

            if (s.phase == Phase.GRADUATED) {
                assertEq(s.fullRangeTickLower, -Bounds.FULL_RANGE_TICK_BOUND, "full-range lower bound moved");
                assertEq(s.fullRangeTickUpper, Bounds.FULL_RANGE_TICK_BOUND, "full-range upper bound moved");
            }
        }
    }

    /// @notice Milestone completions only ever accumulate, and the lifecycle only ever moves forwards.
    function invariant_progressNeverRegresses() public view {
        assertEq(handler.violationCompletionsRegressed(), 0, "the completion count fell");

        for (uint256 i = 0; i < handler.poolCount(); i++) {
            Phase phase = hook.poolState(handler.poolIdAt(i)).phase;
            assertTrue(phase == Phase.BONDING_CURVE || phase == Phase.GRADUATED, "a launched pool left its lifecycle");
        }
    }

    // --- 13.4 Isolation invariants ---

    // --- Scenario: Claims are isolated between creator and protocol ---

    /// @notice Paying one party's ledger never moves the other's.
    /// @dev The unit layer already covers this over synthetic harness accruals. What the campaign adds is
    /// the same claim over accruals the protocol produced itself — graduation splits, harvest routing, and
    /// the fee waterfall — with the two ledgers filling at different rates and in any order.
    function invariant_claimsAreIsolatedBetweenCreatorAndProtocol() public view {
        assertEq(handler.violationClaimTouchedOtherLedger(), 0, "a claim moved the other party's ledger");
    }

    // --- Scenario: Claims are isolated across pools ---

    /// @notice A claim against one pool leaves every other pool's ledgers untouched.
    function invariant_claimsAreIsolatedAcrossPools() public view {
        assertEq(handler.violationCrossPoolCreatorChanged(), 0, "another pool's creator balance moved");
        assertEq(handler.violationCrossPoolProtocolChanged(), 0, "another pool's protocol balance moved");
    }

    // --- Scenario: Protocol balances are isolated per pool ---

    /// @notice The protocol's balance is per pool, so claiming one leaves the others where they were.
    /// @dev Asserted separately from the creator side because the protocol recipient is a single address
    /// across every launch — the one party for whom "per pool" is a bookkeeping claim rather than an
    /// obvious consequence of different owners.
    function invariant_protocolBalancesAreIsolatedPerPool() public view {
        assertEq(handler.violationCrossPoolProtocolChanged(), 0, "another pool's protocol balance moved");
    }

    /// @notice No action on one pool disturbs another pool's state at all.
    /// @dev The whole of `PoolState` is fingerprinted, so this covers far more than the claim ledgers: a
    /// stray write to the wrong `PoolId` shows up whichever field it landed in.
    function invariant_poolStateIsIsolatedAcrossPools() public view {
        assertEq(handler.violationCrossPoolStateChanged(), 0, "an action changed another pool's state");
    }

    /// @notice Only the current revenue-NFT holder and the protocol recipient can ever be paid.
    /// @dev Recorded as a violation rather than expected as a revert: the runner silently skips a reverting
    /// handler call, so a successful unauthorised claim has to be caught by counting it, not by failing.
    function invariant_onlyTheEntitledPartyCanClaim() public view {
        assertEq(handler.violationUnauthorisedClaimSucceeded(), 0, "an unentitled address was paid");
    }

    // --- Campaign non-vacuity (task 13.1) ---

    /// @notice Every run did at least some real work.
    /// @dev Deliberately loose. The fuzzer picks uniformly among ten actions, so at depth 64 the chance a
    /// *specific* action never lands is `(9/10)^64` — about one run in 850, which over 256 runs would flake
    /// roughly a quarter of the time. Asserting per-action coverage here would therefore buy a flaky suite,
    /// so the tight coverage claim is proved deterministically by
    /// {test_handlerDrivesEveryActionToEffect} instead, and this only rules out a campaign that reverted
    /// its way through every single call.
    function afterInvariant() public view {
        assertGt(handler.totalSuccesses(), 0, "the whole run reverted");
    }

    // --- Task 13.1: non-trivial call coverage across every handler action ---

    /// @notice Every one of the handler's ten actions reaches a real effect at least once.
    ///
    /// @dev The deterministic counterpart to {afterInvariant}. `fail_on_revert = false` means a handler
    /// action that reverts on every single call is indistinguishable from one that works — the runner
    /// swallows it and the campaign still passes. So the coverage claim is proved here with hand-picked
    /// seeds rather than left to the fuzzer: each action is driven once, in an order that gives it
    /// something to do, and the assertions are on the *effect* counters, not just on the call returning.
    ///
    /// Seeds are chosen, not arbitrary. `_poolIndex` is `bound(seed, 0, 2)`, so pool seeds 0/1/2 select
    /// pools 0/1/2 directly; actor seeds index the five-actor list the same way.
    function test_handlerDrivesEveryActionToEffect() public {
        int24 spacing = template.bandLevelSpacing;
        int24 width = template.bandWidthLevels;
        int24 lower0 = hook.poolState(poolId1).graduationLevel + spacing;

        // BUY, twice on the graduated pool: the first lands mid-band-0 so the band mints (deployment is
        // simulation-driven — Decision 15 — so a buy must cross its floor), the second clears its top and
        // completes the milestone.
        handler.buy(1, 2_000 ether, _delta(poolId1, lower0 + width / 2));
        assertGt(handler.bandDeployments(), 0, "no band was ever deployed");

        handler.buy(1, 2_000 ether, _delta(poolId1, lower0 + width + 300));
        assertGt(handler.bandHarvests(), 0, "no band was ever harvested");
        assertGt(handler.harvestedQuote(1), 0, "harvest yielded nothing");
        assertGt(handler.routedQuote(1), 0, "harvest routed nothing");

        // SELL: the two buys left the router holding tokens, which is the only source a sell draws on.
        handler.sell(1, type(uint256).max, 500);
        assertGt(handler.actionSuccesses(uint256(LaunchpadHandler.Action.SELL)), 0, "no sell landed");

        // WARP: also puts pool 2's 90-day dev-buy vesting partway through, which RELEASE_DEV_BUY needs.
        handler.warp(30 days);
        assertEq(handler.secondsElapsed(), 30 days, "clock did not move");

        // COLLECT_FEES: the buys and the sell accrued fees in both currencies. A zero-accrual collection
        // succeeds silently and emits nothing, so the event-derived counter is what proves this one did
        // real work.
        handler.collectFees(1);
        assertGt(handler.feeCollections(), 0, "collection accrued nothing");

        // GRADUATE: pool 0 is still on its bonding curve. Auto-graduation (Decision 18) fires in the next
        // swap's `beforeSwap`, so the crossing buy is made outside the handler — otherwise the explicit
        // call would find the pool already graduated and revert.
        router.swapToLimit(key, true, -int256(2_000 ether), _sqrtAtLevel(hook.poolState(poolId).farLevel));
        assertEq(uint8(hook.poolState(poolId).phase), uint8(Phase.BONDING_CURVE), "graduated too early");
        handler.graduate(0);
        assertGt(handler.graduations(), 0, "nothing graduated");

        // CLAIM_CREATOR / CLAIM_PROTOCOL: both ledgers hold graduation proceeds and harvest shares by now.
        assertGt(hook.creatorClaimable(poolId1), 0, "nothing for the creator to claim");
        handler.claimCreator(1);
        assertGt(handler.creatorEthPaid(), 0, "creator was paid nothing");

        assertGt(hook.protocolClaimable(poolId1), 0, "nothing for the protocol to claim");
        handler.claimProtocol(1);
        assertGt(handler.protocolEthPaid(), 0, "protocol was paid nothing");

        // RELEASE_DEV_BUY: pool 2's dev buy is 30 of 90 days vested.
        handler.releaseDevBuy(2);
        assertGt(handler.devBuyTokensReleased(), 0, "no vested tokens released");

        // TRANSFER_NFT: pool 0's stream, from `creator` to actor 3 (`STRANGER`).
        handler.transferRevenueNft(0, 3);
        assertGt(handler.nftTransfers(), 0, "the stream did not move");
        assertEq(nft.ownerOf(nft.tokenIdOf(poolId)), STRANGER, "stream landed elsewhere");

        // UNAUTHORISED_CLAIM: actor 4 (`imposter`) holds no stream and is not the protocol recipient, so
        // both branches are attempted and both must fail.
        handler.unauthorisedClaim(0, 4);
        assertGt(handler.actionSuccesses(uint256(LaunchpadHandler.Action.UNAUTHORISED_CLAIM)), 0, "vacuous");
        assertEq(handler.violationUnauthorisedClaimSucceeded(), 0, "an unentitled address was paid");

        assertEq(handler.distinctActionsExercised(), 10, "an action never succeeded");

        // The properties the campaign asserts must hold over this hand-driven sequence too.
        invariant_everyTokenIsHeldByAKnownParty();
        invariant_harvestSharesSumToOneWhole();
        invariant_supplyFallsOnlyByRoutedBuybackBurns();
        invariant_hookTokenCustodyCoversItsObligations();
        invariant_hookEthCustodyCoversClaimObligations();
        invariant_routedAmountsSumToHarvestedAmounts();
        invariant_ethIsConserved();
        invariant_bandDeploymentIsAscendingAndSingleUse();
        invariant_perSwapWorkCapsAreRespected();
        invariant_fullRangeLiquidityNeverDecreases();
        invariant_storedFullRangeLiquidityMatchesThePosition();
        invariant_progressNeverRegresses();
        invariant_claimsAreIsolatedBetweenCreatorAndProtocol();
        invariant_claimsAreIsolatedAcrossPools();
        invariant_protocolBalancesAreIsolatedPerPool();
        invariant_poolStateIsIsolatedAcrossPools();
        invariant_onlyTheEntitledPartyCanClaim();
    }

    /// @dev The handler's buy and sell take a level *delta* from spot, so a test that wants an absolute
    /// target has to convert. Reverts rather than clamping if the target is already below spot: silently
    /// buying somewhere else would make the assertion that follows meaningless.
    function _delta(PoolId id, int24 target) private view returns (uint256) {
        int24 current = _levelOf(id);
        require(target > current, "coverage: target is at or below spot");
        return uint256(uint24(target - current));
    }
}
