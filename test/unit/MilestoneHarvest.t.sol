// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {LaunchpadTest} from "../Fixtures.sol";
import {GasExhaustingPayoutPlugin, SwitchablePayoutPlugin} from "../mocks/PayoutReferenceMocks.sol";
import {MilestoneBase} from "../../src/MilestoneBase.sol";
import {Orientation} from "../../src/libraries/Orientation.sol";
import {Bounds, LaunchConfig, WAD} from "../../src/types/LaunchTypes.sol";
import {EconomicConfig} from "../../src/types/PayoutTypes.sol";

/// @notice A swapper that reverts *after* its swap has executed, so the harvest the swap triggered is
/// unwound along with it.
///
/// @dev Nothing in the protocol produces this on its own any more: a harvest's only work is burning the
/// band and moving numbers between ledgers, and every untrusted interaction was moved to the cold payout
/// path. This stands in for an integrator whose own callback fails downstream of the hook's work, which is
/// the only shape a "reverting nested interaction" can still take.
contract RevertingSwapper is IUnlockCallback {
    IPoolManager public immutable manager;

    error Deliberate();

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    receive() external payable {}

    function swapThenRevert(PoolKey memory key, int256 amountSpecified, uint160 limit) external {
        manager.unlock(abi.encode(key, amountSpecified, limit));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "not manager");
        (PoolKey memory key, int256 amountSpecified, uint160 limit) = abi.decode(data, (PoolKey, int256, uint160));

        manager.swap(
            key,
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: amountSpecified, sqrtPriceLimitX96: limit}),
            ""
        );

        // The swap succeeded and the hook harvested inside it. Failing here is what proves the harvest's
        // storage writes and its transient lock both unwind with the transaction.
        revert Deliberate();
    }
}

/// @notice A creator that cannot receive ETH, used to prove a harvest never pays one.
contract RejectingCreator {
    receive() external payable {
        revert("no ETH");
    }
}

/// @notice A payout plugin that records every call it receives.
/// @dev Registered and selected purely so the harvest tests can assert it is *never* reached; delivery
/// itself is exercised by the payout suites.
contract CountingPayoutPlugin {
    uint256 public calls;
    uint256 public received;

    function onPayout(PoolId, address) external payable {
        calls += 1;
        received += msg.value;
    }

    receive() external payable {}
}

/// @notice Unit tests for the milestone harvest under the asynchronous payout model.
///
/// @dev A harvest is now deliberately small: it retires the completed band, records the gross quote it
/// released, credits the active service fee to the single global protocol ledger, and funds the source
/// pool's payout pot with the exact remainder. It pays nobody. Everything that used to happen inline —
/// the buyback swap, the LP donation, the four-way split — was removed, so most of what these tests assert
/// is an *absence* observable from the swap's own logs and balances.
///
/// Every test graduates first, because bands only exist above the graduation level. `_deployBand` then
/// buys into a band so it is minted (deployment is simulation-driven: a band mints when a buy's simulated
/// path crosses its floor) and spot sits inside it, which is the only state from which a further buy can
/// complete it.
contract MilestoneHarvestTest is LaunchpadTest {
    /// @dev Levels past a band's top to aim a completing buy at. Enough to clear the top decisively
    /// without running into the next band's floor, which is `bandLevelSpacing - bandWidthLevels` away.
    int24 private constant PAST_TOP = 300;

    /// @dev Generous ETH budget for a buy that is limit-bounded rather than amount-bounded.
    uint256 private constant BUDGET = 2_000 ether;

    /// @notice One harvest, reassembled from the two events that describe it.
    struct Harvest {
        bool seen;
        bool funded;
        uint32 index;
        uint256 quoteProceeds;
        uint256 tokenResidue;
        uint32 completedMilestones;
        uint256 grossQuote;
        uint256 serviceFee;
        uint256 netQuote;
        uint64 economicVersion;
    }

    function setUp() public virtual override {
        super.setUp();
        _graduate();
    }

    // --- Helpers ---

    /// @dev Buys into band `index` so it is deployed and spot sits mid-band. Tolerant of already being
    /// there: `_buyToLevel` cannot target a level below spot.
    function _deployBand(uint256 index) private {
        int24 mid = _bandLower(index) + template.bandWidthLevels / 2;
        if (_level() < mid) _buyToLevel(BUDGET, mid);
    }

    /// @notice The quote a band's position yields once every token in it has been sold.
    ///
    /// @dev Independent of where spot is: liquidity does not change as price traverses a range, only the
    /// composition does, so the fully-converted amount0 can be read at any point before the burn. Must be
    /// read *before* the harvest, which zeroes the liquidity.
    function _bandPrincipalQuote(uint256 index) private view returns (uint256) {
        uint128 liquidity = _bandLiquidity(index);
        int24 tickLower = Orientation.toTick(_bandUpper(index));
        int24 tickUpper = Orientation.toTick(_bandLower(index));
        return SqrtPriceMath.getAmount0Delta(
            TickMath.getSqrtPriceAtTick(tickLower), TickMath.getSqrtPriceAtTick(tickUpper), liquidity, false
        );
    }

    /// @notice Pulls the harvest of band `index` out of a recorded log stream.
    function _harvestFromLogs(Vm.Log[] memory logs, uint32 index) private pure returns (Harvest memory h) {
        for (uint256 i = 0; i < logs.length; i++) {
            bytes32 selector = logs[i].topics[0];

            if (selector == MilestoneBase.MilestoneHarvested.selector && uint32(uint256(logs[i].topics[2])) == index) {
                h.seen = true;
                h.index = index;
                (h.quoteProceeds, h.tokenResidue, h.completedMilestones) =
                    abi.decode(logs[i].data, (uint256, uint256, uint32));
            }

            if (selector == MilestoneBase.PayoutPotFunded.selector && uint32(uint256(logs[i].topics[2])) == index) {
                h.funded = true;
                (h.grossQuote, h.serviceFee, h.netQuote, h.economicVersion) =
                    abi.decode(logs[i].data, (uint256, uint256, uint256, uint64));
            }
        }
    }

    /// @notice Buys to `targetLevel` while recording logs, returning them for decoding.
    function _buyAndCapture(int24 targetLevel) private returns (Vm.Log[] memory) {
        vm.recordLogs();
        _buyToLevel(BUDGET, targetLevel);
        return vm.getRecordedLogs();
    }

    /// @dev Deploys band 0 and then completes it, returning everything the harvest reported.
    function _completeBandZero() private returns (Harvest memory) {
        _deployBand(0);
        Vm.Log[] memory logs = _buyAndCapture(_bandUpper(0) + PAST_TOP);
        return _harvestFromLogs(logs, 0);
    }

    /// @dev Replaces the global economic tuple through the typed controller. The fixture's delay is zero,
    /// so scheduling and executing in one call is the ordinary governance path rather than a shortcut.
    function _setServiceFee(uint64 serviceFeeWad) private returns (uint64 version) {
        EconomicConfig memory current = hook.economicConfig();
        version = current.version + 1;
        EconomicConfig memory next = EconomicConfig({
            harvestServiceFeeWad: serviceFeeWad,
            quoteCreatorShareWad: current.quoteCreatorShareWad,
            tokenMilestoneFundShareWad: current.tokenMilestoneFundShareWad,
            version: version
        });

        bytes32 salt = keccak256(abi.encode("harvest-service-fee", serviceFeeWad, version));
        vm.prank(PROTOCOL_ADMIN);
        controller.scheduleEconomicConfig(next, salt);
        controller.executeEconomicConfig(next, salt);
    }

    // --- Scenario: Crossing the band top completes and accounts for the milestone ---

    function test_crossingTheBandTopCompletesAndAccountsForTheMilestone() public {
        _deployBand(0);
        assertTrue(hook.bandDeployed(poolId, 0), "the band was minted");
        assertFalse(hook.bandCompleted(poolId, 0), "and is not complete while spot sits inside it");

        uint256 liquidityBefore = _bandLiquidity(0);
        assertGt(liquidityBefore, 0, "the position holds inventory");

        Vm.Log[] memory logs = _buyAndCapture(_bandUpper(0) + PAST_TOP);
        Harvest memory h = _harvestFromLogs(logs, 0);

        assertGe(_level(), _bandUpper(0), "the swap ended at or above the band's top");
        assertTrue(h.seen, "the milestone was harvested in the crossing transaction");
        assertTrue(hook.bandCompleted(poolId, 0), "the band is marked complete");
        assertEq(_bandLiquidity(0), 0, "and its position was burned");

        // Accounting finished inside the same transaction: the pot and the protocol ledger both moved.
        assertTrue(h.funded, "pot accounting ran atomically with the completion");
        assertGt(h.quoteProceeds, 0, "the burn released quote");
        assertEq(h.grossQuote, h.quoteProceeds, "recorded gross is what the burn released");
        assertEq(hook.payoutPot(poolId), h.netQuote, "the pot holds the exact net remainder");
        assertEq(h.completedMilestones, 1, "one milestone is complete");
    }

    // --- Scenario: Partial fill does not complete the milestone ---

    function test_partialFillDoesNotCompleteTheMilestone() public {
        _deployBand(0);

        uint128 liquidityBefore = _bandLiquidity(0);
        uint256 potBefore = hook.payoutPot(poolId);

        // Stop strictly inside the band: some inventory sold, none of the top crossed.
        int24 target = _bandLower(0) + template.bandWidthLevels / 2 + 50;
        vm.recordLogs();
        _buyToLevel(BUDGET, target);
        Harvest memory h = _harvestFromLogs(vm.getRecordedLogs(), 0);

        assertLt(_level(), _bandUpper(0), "the swap ended below the band's top");
        assertFalse(h.seen, "so nothing was harvested");
        assertFalse(hook.bandCompleted(poolId, 0), "the band is still live");
        assertGt(_bandLiquidity(0), 0, "with its position intact");
        assertLe(_bandLiquidity(0), liquidityBefore, "partially filled at most");
        assertEq(hook.payoutPot(poolId), potBefore, "and no pot accounting occurred");
    }

    // --- Scenario: Band swap fees fold into the gross harvest ---
    // --- Scenario (swap-fees): Ladder fees remain part of harvest ---

    /// @dev The burn's positive delta carries principal and accrued position fees together, so there is no
    /// separate fee path to account for: the gross the pot is funded from is strictly larger than the
    /// position's principal alone. Reading the principal before the burn is what makes that checkable.
    function test_bandSwapFeesFoldIntoTheGrossHarvest() public {
        _deployBand(0);

        uint256 principal = _bandPrincipalQuote(0);
        assertGt(principal, 0, "the position has a convertible principal");

        Vm.Log[] memory logs = _buyAndCapture(_bandUpper(0) + PAST_TOP);
        Harvest memory h = _harvestFromLogs(logs, 0);

        assertTrue(h.seen, "the band completed");
        assertGt(h.quoteProceeds, principal, "gross exceeds bare principal, so the band's own fees are in it");
        assertEq(h.grossQuote, h.quoteProceeds, "and the pot is funded from that same gross");
    }

    // --- Scenario: A completed band cannot be accounted again ---

    function test_aCompletedBandCannotBeAccountedAgain() public {
        Harvest memory first = _completeBandZero();
        assertTrue(first.seen, "band 0 completed once");

        uint256 potAfterFirst = hook.payoutPot(poolId);
        uint256 protocolAfterFirst = hook.protocolClaimable();

        // Walk spot back down through the retired band and up across its top again.
        _sellAllToLevel(_bandLower(0) - 100);
        assertLt(_level(), _bandLower(0), "spot fell back below the retired band");

        vm.recordLogs();
        _buyToLevel(BUDGET, _bandUpper(0) + PAST_TOP);
        Harvest memory second = _harvestFromLogs(vm.getRecordedLogs(), 0);

        assertFalse(second.seen, "crossing it a second time harvests nothing");
        assertTrue(hook.bandCompleted(poolId, 0), "the completion bit is never cleared");
        assertEq(hook.payoutPot(poolId), potAfterFirst, "so the pot cannot be credited twice");
        assertEq(hook.protocolClaimable(), protocolAfterFirst, "nor the protocol ledger");
    }

    // --- Scenario: Gross harvest is attributed before deductions ---

    /// @dev Two events, in order: the harvest records pool, index and gross; the funding then records the
    /// deduction against that same index. An indexer can therefore attribute the gross without waiting for
    /// any later payout settlement, which is the point of splitting them.
    function test_grossHarvestIsAttributedBeforeDeductions() public {
        _deployBand(0);
        Vm.Log[] memory logs = _buyAndCapture(_bandUpper(0) + PAST_TOP);

        uint256 harvestedAt = type(uint256).max;
        uint256 fundedAt = type(uint256).max;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == MilestoneBase.MilestoneHarvested.selector) harvestedAt = i;
            if (logs[i].topics[0] == MilestoneBase.PayoutPotFunded.selector) fundedAt = i;
        }

        assertLt(harvestedAt, logs.length, "the harvest was recorded");
        assertLt(fundedAt, logs.length, "and so was the funding");
        assertLt(harvestedAt, fundedAt, "gross attribution precedes the deduction it is reduced by");

        Harvest memory h = _harvestFromLogs(logs, 0);
        assertEq(
            uint256(uint160(uint256(logs[harvestedAt].topics[1]))),
            uint256(uint160(uint256(PoolId.unwrap(poolId)))),
            "pool is indexed"
        );
        assertEq(h.index, 0, "index is indexed");
        assertGt(h.grossQuote, 0, "and the gross is non-zero before any deduction");
    }

    // --- Scenario: Active service fee is applied ---

    /// @dev One snapshot governs the deduction, and the event names the version it used. Harvesting under
    /// the default and then again after a governed update proves the snapshot is read per harvest rather
    /// than fixed at launch.
    function test_activeServiceFeeIsApplied() public {
        Harvest memory first = _completeBandZero();
        assertTrue(first.funded, "the first milestone funded a pot");
        assertEq(first.economicVersion, 1, "under the published initial version");
        assertEq(
            first.serviceFee,
            (first.grossQuote * Bounds.DEFAULT_HARVEST_SERVICE_FEE_WAD) / WAD,
            "the default 10% service fee applied"
        );

        uint64 raised = Bounds.MAX_HARVEST_SERVICE_FEE_WAD;
        uint64 version = _setServiceFee(raised);

        _deployBand(1);
        Vm.Log[] memory logs = _buyAndCapture(_bandUpper(1) + PAST_TOP);
        Harvest memory second = _harvestFromLogs(logs, 1);

        assertTrue(second.funded, "the second milestone funded a pot");
        assertEq(second.economicVersion, version, "under the newly executed version");
        assertEq(second.serviceFee, (second.grossQuote * raised) / WAD, "at the newly active percentage");
        assertEq(second.netQuote, second.grossQuote - second.serviceFee, "with the exact remainder to the pot");
    }

    // --- Scenario: Net harvest funds only its source pool ---

    function test_netHarvestFundsOnlyItsSourcePool() public {
        // A second graduated pool, untouched by the first pool's harvest.
        PoolId sourcePool = poolId;
        (PoolId otherPool,,) = _launchDirect(_defaultConfig("Other", "OTH"));
        uint256 otherPotBefore = hook.payoutPot(otherPool);

        poolId = sourcePool;
        Harvest memory h = _completeBandZero();

        assertTrue(h.funded, "the source pool's milestone funded a pot");
        assertEq(hook.payoutPot(sourcePool), h.netQuote, "the exact remainder reached the source pool");
        assertEq(hook.payoutPot(otherPool), otherPotBefore, "and no other pool's pot moved");
    }

    // --- Scenario: Harvest proceeds are quote only ---

    function test_harvestProceedsAreQuoteOnly() public {
        _deployBand(0);
        uint256 carriedBefore = hook.poolState(poolId).carriedInventory;

        Vm.Log[] memory logs = _buyAndCapture(_bandUpper(0) + PAST_TOP);
        Harvest memory h = _harvestFromLogs(logs, 0);

        assertTrue(h.seen, "the band completed");
        assertGt(h.grossQuote, 0, "the routed proceeds are quote");
        assertEq(hook.payoutPot(poolId), h.netQuote, "and the pot is denominated in that quote");

        // Whatever token the position still held is inventory, not proceeds: it returns to the carry that
        // funds the next band rather than to any ledger.
        assertEq(
            hook.poolState(poolId).carriedInventory - carriedBefore,
            h.tokenResidue,
            "token residue returned to carried inventory"
        );
    }

    // --- Scenario: Harvest accounting conserves the gross amount ---

    function test_harvestAccountingConservesTheGrossAmount() public {
        uint256 protocolBefore = hook.protocolClaimable();
        uint256 backedBefore = hook.protocolClaimBacked();

        Harvest memory h = _completeBandZero();

        assertTrue(h.funded, "the milestone funded a pot");
        assertEq(h.serviceFee + h.netQuote, h.grossQuote, "fee plus net is exactly the gross");
        assertEq(hook.protocolClaimable() - protocolBefore, h.serviceFee, "the fee reached the global ledger");
        assertEq(hook.protocolClaimBacked() - backedBefore, h.serviceFee, "as a claim-backed subset of it");
        assertEq(hook.payoutPot(poolId), h.netQuote, "and the net reached the pot");

        // Both liabilities are claim-backed until an explicit redemption runs, so the manager still holds
        // the whole gross on the hook's behalf.
        assertGe(hook.claimBacking(), hook.claimBackedLiabilities(), "claims cover both new liabilities");
    }

    function testFuzz_harvestAccountingConservesTheGrossAmount(uint64 serviceFeeWad) public {
        serviceFeeWad = uint64(bound(serviceFeeWad, 0, Bounds.MAX_HARVEST_SERVICE_FEE_WAD));
        _setServiceFee(serviceFeeWad);

        Harvest memory h = _completeBandZero();

        assertTrue(h.funded, "the milestone funded a pot at every legal fee");
        assertEq(h.serviceFee, (h.grossQuote * serviceFeeWad) / WAD, "the fee is the configured floor");
        assertEq(h.serviceFee + h.netQuote, h.grossQuote, "and conservation holds exactly");
    }

    // --- Scenario: Harvest leaves direct creator revenue unchanged ---

    /// @dev Relaunched under a creator that reverts on receive, so "unchanged" is proved against the one
    /// recipient a push would visibly fail on rather than merely not having been credited.
    function test_harvestLeavesDirectCreatorRevenueUnchanged() public {
        address rejecting = address(new RejectingCreator());
        creator = rejecting;
        LaunchConfig memory config = _defaultConfig("Rejecting", "RJC");
        (poolId, key, token) = _launchDirect(config);
        vm.deal(address(router), 200_000 ether);
        _graduate();

        uint256 directBefore = hook.creatorClaimable(poolId);
        uint256 pathBefore = hook.creatorPathClaimable(poolId);

        Harvest memory h = _completeBandZero();

        assertTrue(h.funded, "the milestone was harvested and funded");
        assertEq(hook.creatorClaimable(poolId), directBefore, "the direct creator ledger did not move");
        assertEq(hook.creatorPathClaimable(poolId), pathBefore, "nor creator-path entitlement, which a flush owns");
        assertEq(rejecting.balance, 0, "and nothing was pushed to a creator that would have reverted");
    }

    // --- Scenario: Harvest performs no direct destination work ---
    // --- Scenario: Harvest invokes no payout plugin ---
    // --- Scenario: Ordinary swaps never flush ---

    /// @dev The three absences share one setup, because they are the same claim observed three ways: a
    /// plan is selected and its plugin registered, then an ordinary router buy crosses a band. The harvest
    /// runs — and nothing else does.
    function test_harvestPerformsNoDirectDestinationWork() public {
        CountingPayoutPlugin plugin = new CountingPayoutPlugin();
        uint8 index = _registerPayoutPlugin(address(plugin), 0.5e18);

        (poolId, key, token) = _launchWithPlan("Planned", "PLN", _plan(index));
        vm.deal(address(router), 200_000 ether);
        _graduate();

        uint128 fullRangeBefore = _fullRangeLiquidity();
        uint256 hookEthBefore = HOOK_ADDR.balance;
        uint256 supplyBefore = token.totalSupply();

        _deployBand(0);
        Vm.Log[] memory logs = _buyAndCapture(_bandUpper(0) + PAST_TOP);
        Harvest memory h = _harvestFromLogs(logs, 0);

        assertTrue(h.seen, "the band really was harvested, so the absences below are meaningful");

        // No plugin was reached, and no pot was redeemed on the swap path.
        assertEq(plugin.calls(), 0, "no payout plugin was invoked");
        assertEq(plugin.received(), 0, "and none received value");
        assertEq(_countLogs(logs, MilestoneBase.PayoutPotRedeemed.selector), 0, "no pot was redeemed");
        assertEq(_countLogs(logs, MilestoneBase.PayoutTipPaid.selector), 0, "and no tip was paid");
        assertEq(hook.payoutPot(poolId), h.netQuote, "the whole net remainder is still waiting in the pot");

        // No buyback, no donation, no liquidity operation.
        assertEq(_countLogs(logs, IPoolManager.Swap.selector), 1, "only the trader's own swap occurred");
        assertEq(_countLogs(logs, IPoolManager.Donate.selector), 0, "nothing was donated");
        assertEq(_fullRangeLiquidity(), fullRangeBefore, "the locked position is untouched");
        assertEq(token.totalSupply(), supplyBefore, "and no token was bought back and burned");

        // No ETH left the hook: harvest proceeds are claim-backed until an explicit redemption runs.
        assertEq(HOOK_ADDR.balance, hookEthBefore, "no ETH was transferred by the harvest");
    }

    // --- Scenario: Plugin availability cannot block a swap ---

    function test_pluginAvailabilityCannotBlockASwap() public {
        SwitchablePayoutPlugin reverting = new SwitchablePayoutPlugin();
        CountingPayoutPlugin suspended = new CountingPayoutPlugin();
        GasExhaustingPayoutPlugin exhausting = new GasExhaustingPayoutPlugin();
        uint8 revertingIndex = _registerPayoutPlugin(address(reverting), 0.2e18);
        uint8 suspendedIndex = _registerPayoutPlugin(address(suspended), 0.3e18);
        uint8 exhaustingIndex = _registerPayoutPlugin(address(exhausting), 0.4e18);
        uint256 plan = _plan(revertingIndex, suspendedIndex) | _plan(exhaustingIndex);

        (poolId, key, token) = _launchWithPlan("Unavailable", "NAV", plan);
        vm.deal(address(router), 200_000 ether);
        _graduate();
        _deployBand(0);

        // Availability changes after launch cannot alter its immutable selection. The third plugin is
        // intrinsically gas-exhausting under its registered stipend.
        reverting.setShouldRevert(true);
        _setPluginSuspended(suspendedIndex, true);
        assertEq(hook.payoutPlan(poolId), plan, "all unavailable destinations remain selected");

        Vm.Log[] memory logs = _buyAndCapture(_bandUpper(0) + PAST_TOP);
        Harvest memory h = _harvestFromLogs(logs, 0);

        assertTrue(h.seen, "the ordinary swap crossed and harvested the deployed band");
        assertTrue(h.funded, "bounded harvest accounting still completed");
        assertTrue(hook.bandCompleted(poolId, 0), "the crossed band was retired");
        assertEq(hook.payoutPot(poolId), h.netQuote, "the complete net harvest remains in the pot");
        assertGt(h.netQuote, 0, "the availability check exercised real pot funding");
        assertEq(_countLogs(logs, IPoolManager.Swap.selector), 1, "only the ordinary router swap executed");
        assertEq(_countLogs(logs, MilestoneBase.PayoutPotRedeemed.selector), 0, "the swap did not flush the pot");

        assertEq(_countLogs(logs, MilestoneBase.PluginPayoutDelivered.selector), 0, "no plugin delivery ran");
        assertEq(_countLogs(logs, MilestoneBase.PluginPayoutCarried.selector), 0, "no failed call created carry");
        assertEq(_countLogs(logs, MilestoneBase.PluginPayoutRedirected.selector), 0, "no suspension redirect ran");
        assertEq(reverting.calls(), 0, "the reverting plugin was not called");
        assertEq(suspended.calls(), 0, "the suspended plugin was not called");
        assertEq(address(exhausting).balance, 0, "the gas-exhausting plugin received nothing");
        assertEq(hook.pluginCarry(poolId, revertingIndex), 0, "the reverting destination has no carry");
        assertEq(hook.pluginCarry(poolId, suspendedIndex), 0, "the suspended destination has no carry");
        assertEq(hook.pluginCarry(poolId, exhaustingIndex), 0, "the exhausting destination has no carry");
        assertEq(hook.carryBitmap(poolId), 0, "no carry bookkeeping ran");
        assertEq(hook.creatorPathClaimable(poolId), 0, "no creator-path redirect or remainder ran");
    }

    // --- Settlement is reentrancy-guarded: derived, no scenario of its own ---

    /// @dev A nested interaction that fails downstream of the harvest unwinds every storage write the
    /// harvest made, transient lock included — so the band is live again and a later swap can complete it
    /// normally. The lock not persisting is what the second harvest proves.
    function test_aRevertingNestedInteractionLeavesNoResidue() public {
        _deployBand(0);
        uint256 potBefore = hook.payoutPot(poolId);

        RevertingSwapper swapper = new RevertingSwapper(IPoolManager(address(manager)));
        vm.deal(address(swapper), BUDGET);
        uint160 limit = _sqrtAtLevel(_bandUpper(0) + PAST_TOP);

        vm.expectRevert(RevertingSwapper.Deliberate.selector);
        swapper.swapThenRevert(key, -int256(BUDGET), limit);

        assertFalse(hook.bandCompleted(poolId, 0), "the completion was rolled back");
        assertGt(_bandLiquidity(0), 0, "the position is intact");
        assertEq(hook.payoutPot(poolId), potBefore, "and the pot accounting unwound with it");

        // The transient lock did not survive the reverted frame.
        Harvest memory h = _completeBandZero();
        assertTrue(h.funded, "a later swap harvests the same band normally");
    }
}
