// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {MilestoneToken} from "../../src/MilestoneToken.sol";
import {Bounds, LaunchConfig, Phase, PoolState} from "../../src/types/LaunchTypes.sol";
import {LaunchpadTest} from "../Fixtures.sol";
import {LaunchpadHandler} from "./LaunchpadHandler.sol";

/// @notice Multi-pool stateful invariants for the payout-pot and static-fee launch model.
contract LaunchpadInvariantsTest is LaunchpadTest {
    using StateLibrary for IPoolManager;

    LaunchpadHandler internal handler;

    uint256 internal constant CREATOR2_PK = 0xB0B5;
    address internal creator2;

    address[] internal ethAccounts;
    uint256 internal ethTotalAtStart;

    PoolId internal poolId1;
    PoolId internal poolId2;
    PoolKey internal key1;
    PoolKey internal key2;

    function setUp() public override {
        super.setUp();
        creator2 = vm.addr(CREATOR2_PK);

        (poolId1, key1,) = _launchDirect(_defaultConfig("Milestone Two", "MILE2"));
        _graduatePool(poolId1, key1);

        vm.deal(creator2, 100_000 ether);
        LaunchConfig memory config = Bounds.defaultConfig(creator2, "Milestone Three", "MILE3", SUPPLY);
        config.devBuyShareWad = 0.05e18;
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

        vm.deal(address(router), 1_000_000 ether);
        handler =
            new LaunchpadHandler(IPoolManager(address(manager)), hook, nft, router, PROTOCOL_RECIPIENT, keys, actors);
        targetContract(address(handler));

        _recordEthAccounts();
        ethTotalAtStart = _ethTotal();
    }

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
        ethAccounts.push(address(payoutPaths));
        ethAccounts.push(address(registry));
        ethAccounts.push(address(controller));
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

    function _popcount(uint256 x) private pure returns (uint256 n) {
        while (x != 0) {
            x &= x - 1;
            n += 1;
        }
    }

    // --- Aggregate counters roll up to the published total: derived, no scenario of its own ---

    /// @dev The scenario is about the aggregates agreeing with the per-pool ledgers they summarise, and
    /// {invariant_perPoolPotsAndCarriesMatchAggregates} is where that is asserted. This is the weaker
    /// arithmetic step above it -- that the single published total is exactly its five parts -- which no
    /// requirement names on its own but which is what a reader of `totalLiabilities()` is relying on.
    function invariant_aggregateLiabilitiesEqualComponents() public view {
        (uint256 pots, uint256 carries, uint256 paths, uint256 creators, uint256 protocol,) =
            hook.aggregateLiabilities();
        assertEq(hook.totalLiabilities(), pots + carries + paths + creators + protocol, "liability aggregate drifted");
    }

    // --- Scenario (payout-plugins): Custody classes cover their liabilities ---
    function invariant_custodyClassesCoverTheirLiabilities() public view {
        assertGe(hook.nativeBacking(), hook.totalLiabilities(), "aggregate native backing is short");
        assertGe(hook.claimBacking(), hook.claimBackedLiabilities(), "manager claims are short");
        assertGe(HOOK_ADDR.balance, hook.rawEthLiabilities(), "raw ETH is short");
    }

    // --- Scenario (payout-plugins): Aggregate liabilities equal component ledgers ---
    function invariant_perPoolPotsAndCarriesMatchAggregates() public view {
        uint256 pots;
        uint256 carries;
        uint256 paths;
        uint256 creators;
        for (uint256 i = 0; i < handler.poolCount(); i++) {
            PoolId id = handler.poolIdAt(i);
            pots += hook.payoutPot(id);
            paths += hook.creatorPathClaimable(id);
            creators += hook.creatorClaimable(id);
            uint256 bits = hook.carryBitmap(id);
            while (bits != 0) {
                uint8 index = uint8(_leastSignificantBit(bits));
                carries += hook.pluginCarry(id, index);
                bits &= bits - 1;
            }
        }
        (
            uint256 aggregatePots,
            uint256 aggregateCarries,
            uint256 aggregatePaths,
            uint256 aggregateCreators,
            uint256 aggregateProtocol,
            uint256 protocolClaimBacking
        ) = hook.aggregateLiabilities();
        assertEq(pots, aggregatePots, "pool pots do not sum to aggregate");
        assertEq(carries, aggregateCarries, "plugin carries do not sum to aggregate");
        assertEq(paths, aggregatePaths, "creator paths do not sum to aggregate");
        assertEq(creators, aggregateCreators, "direct creator ledgers do not sum to aggregate");
        // The scenario's second clause. The claim-backed figure is a subset marker on the one global
        // protocol ledger, not a ledger of its own, so it is only meaningful while it stays inside it.
        assertLe(protocolClaimBacking, aggregateProtocol, "claim-backed protocol revenue exceeds its ledger");
    }

    // --- Scenario (swap-fees): Token fees never credit a claimant or pot ---
    function invariant_supplyOnlyFallsByColdPathFeeBurns() public view {
        for (uint256 i = 0; i < handler.poolCount(); i++) {
            uint256 supplyNow = handler.tokenAt(i).totalSupply();
            assertLe(supplyNow, handler.initialSupplyAt(i), "supply grew after launch");
            assertEq(handler.initialSupplyAt(i) - supplyNow, handler.tokensBurned(i), "unexplained supply change");
        }
    }

    /// @notice All current token holders are members of the launch fixture's closed actor set.
    function invariant_everyTokenIsHeldByAKnownParty() public view {
        for (uint256 i = 0; i < handler.poolCount(); i++) {
            MilestoneToken t = handler.tokenAt(i);
            uint256 held = t.balanceOf(HOOK_ADDR) + t.balanceOf(address(manager)) + t.balanceOf(address(router))
                + t.balanceOf(handler.creatorAt(i));
            assertEq(held, t.totalSupply(), "a token escaped the known holder set");
        }
    }

    function invariant_hookTokenCustodyCoversLadderObligations() public view {
        for (uint256 i = 0; i < handler.poolCount(); i++) {
            PoolState memory s = hook.poolState(handler.poolIdAt(i));
            uint256 custody = handler.tokenAt(i).balanceOf(HOOK_ADDR) + handler.tokenAt(i).balanceOf(address(manager));
            uint256 owed = s.ladderInventoryRemaining + s.carriedInventory + s.milestoneFundAccrued;
            assertGe(custody, owed, "hook cannot cover ladder obligations");
        }
    }

    function invariant_ethIsConserved() public view {
        assertEq(_ethTotal(), ethTotalAtStart, "ETH was created or destroyed");
    }

    // --- Scenario (payout-plugins): Service fee precedes pot funding ---
    function invariant_harvestAccountingConservesGross() public view {
        for (uint256 i = 0; i < handler.poolCount(); i++) {
            assertEq(
                handler.harvestedQuote(i),
                handler.potFunded(i) + handler.serviceFees(i),
                "harvest gross did not become fee plus pot"
            );
        }
    }

    // --- Scenario (payout-plugins): Plan cannot change after launch ---
    function invariant_payoutPlansRemainStable() public view {
        assertEq(handler.violationPlanChanged(), 0, "a payout plan changed");
        for (uint256 i = 0; i < handler.poolCount(); i++) {
            assertEq(hook.payoutPlan(handler.poolIdAt(i)), handler.initialPlanAt(i), "plan was reinterpreted");
        }
    }

    // --- Scenario (swap-fees): One percent applies from genesis forever ---
    function invariant_poolFeeIsStaticOnePercent() public view {
        for (uint256 i = 0; i < handler.poolCount(); i++) {
            PoolKey memory k = handler.poolKeyAt(i);
            assertEq(uint256(k.fee), uint256(Bounds.TRADING_FEE_HUNDREDTHS_BIP), "key fee changed");
            (,,, uint24 lpFee) = IPoolManager(address(manager)).getSlot0(handler.poolIdAt(i));
            assertEq(uint256(lpFee), uint256(Bounds.TRADING_FEE_HUNDREDTHS_BIP), "live fee changed");
        }
    }

    function invariant_bandDeploymentIsAscendingAndSingleUse() public view {
        assertEq(handler.violationDeployOrder(), 0, "a band deployed out of order");
        assertEq(handler.violationRedeployedCompletedBand(), 0, "a completed band was redeployed");
        assertEq(handler.violationBitmapCleared(), 0, "a deployed or completed bit was cleared");
        for (uint256 i = 0; i < handler.poolCount(); i++) {
            PoolState memory s = hook.poolState(handler.poolIdAt(i));
            assertEq(_popcount(s.deployedBands) + handler.bandSkipsOf(i), s.nextBandIndex, "cursor accounting drifted");
            assertEq(s.completedBands & ~s.deployedBands, 0, "a band completed before deployment");
            assertEq(_popcount(s.completedBands), s.completedMilestones, "completion bitmap drifted");
            assertEq(
                _popcount(s.deployedBands >> template.coreBandCount), s.feeFundedBandsCreated, "extension count drifted"
            );
        }
    }

    function invariant_perSwapWorkCapsAreRespected() public view {
        assertLe(handler.maxDeploysInOneSwap(), template.maxDeploysPerSwap, "deploy cap exceeded");
        assertLe(handler.maxHarvestsInOneSwap(), template.maxHarvestsPerSwap, "harvest cap exceeded");
    }

    // --- Scenario (swap-fees): Net locked position is preserved ---
    function invariant_fullRangeLiquidityNeverDecreases() public view {
        assertEq(handler.violationFullRangeShrank(), 0, "full-range liquidity fell");
    }

    function invariant_storedFullRangeLiquidityMatchesThePosition() public view {
        for (uint256 i = 0; i < handler.poolCount(); i++) {
            PoolState memory s = hook.poolState(handler.poolIdAt(i));
            assertEq(s.fullRangeLiquidity, handler.fullRangeLiquidityOf(i), "stored liquidity drifted");
            if (s.phase == Phase.GRADUATED) {
                assertEq(s.fullRangeTickLower, Bounds.FULL_RANGE_TICK_LOWER, "lower bound moved");
                assertEq(s.fullRangeTickUpper, Bounds.FULL_RANGE_TICK_UPPER, "upper bound moved");
            }
        }
    }

    function invariant_progressNeverRegresses() public view {
        assertEq(handler.violationCompletionsRegressed(), 0, "completion count fell");
        for (uint256 i = 0; i < handler.poolCount(); i++) {
            Phase phase = hook.poolState(handler.poolIdAt(i)).phase;
            assertTrue(phase == Phase.BONDING_CURVE || phase == Phase.GRADUATED, "pool left lifecycle");
        }
    }

    // --- Scenario (revenue-claims): Direct creator and protocol claims are isolated ---
    function invariant_claimsAreIsolatedBetweenCreatorAndProtocol() public view {
        assertEq(handler.violationClaimTouchedOtherLedger(), 0, "a claim moved another ledger");
    }

    // --- Scenario (revenue-claims): Creator claims are isolated across pools ---
    function invariant_creatorClaimsAreIsolatedAcrossPools() public view {
        assertEq(handler.violationCrossPoolCreatorChanged(), 0, "another pool's creator balance moved");
    }

    // --- Scenario (payout-plugins): Pots are isolated across pools ---
    function invariant_poolStateIsIsolatedAcrossPools() public view {
        assertEq(handler.violationCrossPoolStateChanged(), 0, "an action changed another pool's state");
    }

    function invariant_onlyTheEntitledPartyCanClaim() public view {
        assertEq(handler.violationUnauthorisedClaimSucceeded(), 0, "an unentitled address was paid");
    }

    function afterInvariant() public view {
        assertGt(handler.totalSuccesses(), 0, "the whole run reverted");
    }

    function test_handlerDrivesPayoutActionsToEffect() public {
        int24 lower0 = hook.poolState(poolId1).graduationLevel + template.bandFirstStepLevels;
        handler.buy(1, 2_000 ether, _delta(poolId1, lower0 + template.bandWidthLevels + 300));
        assertGt(handler.bandHarvests(), 0, "no band was harvested");
        assertGt(hook.payoutPot(poolId1), 0, "harvest did not fund a pot");

        handler.flush(1);
        assertGt(handler.flushes(), 0, "pot was not redeemed");
        assertGt(hook.creatorPathClaimable(poolId1), 0, "ordinary flush did not record creator value");

        handler.claimCreatorPath(1);
        assertGt(handler.creatorPathClaims(), 0, "creator path was not claimed");

        handler.sell(1, type(uint256).max, 500);
        handler.collectFees(1);
        handler.warp(30 days);

        router.swapToLimit(key, true, -int256(2_000 ether), _sqrtAtLevel(hook.poolState(poolId).farLevel));
        handler.graduate(0);

        handler.claimCreator(1);
        handler.claimProtocol(1);
        handler.transferRevenueNft(0, 3);
        handler.unauthorisedClaim(0, 4);

        invariant_aggregateLiabilitiesEqualComponents();
        invariant_custodyClassesCoverTheirLiabilities();
        invariant_perPoolPotsAndCarriesMatchAggregates();
        invariant_supplyOnlyFallsByColdPathFeeBurns();
        invariant_harvestAccountingConservesGross();
        invariant_payoutPlansRemainStable();
        invariant_poolFeeIsStaticOnePercent();
        invariant_bandDeploymentIsAscendingAndSingleUse();
        invariant_fullRangeLiquidityNeverDecreases();
        invariant_progressNeverRegresses();
    }

    function _delta(PoolId id, int24 target) private view returns (uint256) {
        int24 current = _levelOf(id);
        require(target > current, "coverage: target is at or below spot");
        return uint256(uint24(target - current));
    }

    function _leastSignificantBit(uint256 x) private pure returns (uint256 r) {
        while (x & 1 == 0) {
            x >>= 1;
            r += 1;
        }
    }
}
