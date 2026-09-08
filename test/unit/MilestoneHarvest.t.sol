// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {LaunchpadTest, TestRouter} from "../Fixtures.sol";
import {MilestoneBase} from "../../src/MilestoneBase.sol";
import {LaunchConfigLib} from "../../src/libraries/LaunchConfigLib.sol";
import {Orientation} from "../../src/libraries/Orientation.sol";
import {Bounds, HarvestSplit, LaunchConfig, PoolState, WAD} from "../../src/types/LaunchTypes.sol";

/// @notice A swapper that reverts *after* its swap has executed, so the harvest the swap triggered is
/// unwound along with it.
///
/// @dev Nothing in the protocol can produce this on its own — the harvest's own nested interactions are
/// the buyback swap and the LP donation, both of which are settled before the frame ends. This stands in
/// for an integrator whose own callback fails downstream of the hook's work, which is the only shape a
/// "reverting nested interaction" can actually take.
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

/// @notice A creator that cannot receive ETH, used to prove harvest proceeds are credited rather than paid.
contract RejectingCreator {
    receive() external payable {
        revert("no ETH");
    }
}

/// @notice Unit tests for the harvest: what completes a milestone, what the burn yields, where the four
/// shares go, and that the nested buyback cannot re-enter settlement.
///
/// @dev Every test graduates first — bands only exist above the graduation level. `_deployBand` then buys
/// into a band so it is minted (deployment is simulation-driven, Decision 15: a band mints when a buy's
/// simulated path crosses its floor) and spot sits inside it, which is the only state from which a further
/// buy can complete it.
contract MilestoneHarvestTest is LaunchpadTest {
    /// @dev Levels past a band's top to aim a completing buy at. Enough to clear the top decisively
    /// without running into the next band's floor, which is `bandLevelSpacing - bandWidthLevels` away.
    int24 private constant PAST_TOP = 300;

    /// @dev Generous ETH budget for a buy that is limit-bounded rather than amount-bounded.
    uint256 private constant BUDGET = 2_000 ether;

    /// @notice One harvest, reassembled from the two events that describe it.
    struct Harvest {
        bool seen;
        uint32 index;
        uint256 quoteProceeds;
        uint256 tokenResidue;
        uint32 completedMilestones;
        uint256 creatorAmount;
        uint256 buybackQuote;
        uint256 tokensBurned;
        uint256 protocolAmount;
        uint256 lpAmount;
    }

    function setUp() public virtual override {
        super.setUp();
        _graduate();
    }

    // --- Helpers ---

    /// @dev Buys into band `index` so it is deployed and spot sits mid-band. Tolerant of already being
    /// there: a preceding harvest's buyback pushes the price up, and `_buyToLevel` cannot target a level
    /// below spot.
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

            if (selector == MilestoneBase.HarvestRouted.selector && uint32(uint256(logs[i].topics[2])) == index) {
                (h.creatorAmount, h.buybackQuote, h.tokensBurned, h.protocolAmount, h.lpAmount) =
                    abi.decode(logs[i].data, (uint256, uint256, uint256, uint256, uint256));
            }
        }
    }

    /// @notice Buys to `targetLevel` while recording logs, returning them for decoding.
    function _buyAndCapture(int24 targetLevel) private returns (Vm.Log[] memory) {
        vm.recordLogs();
        _buyToLevel(BUDGET, targetLevel);
        return vm.getRecordedLogs();
    }

    /// @notice Relaunches the fixture's pool with a different creator and split, then graduates it.
    ///
    /// @dev Re-points `poolId`/`key`/`token`/`creator` so every inherited helper follows. The CREATE2 token
    /// salt derives from the config hash, so varying the creator or the split is enough to avoid a collision
    /// with the pool `setUp` already launched.
    function _relaunch(address creator_, HarvestSplit memory split) private {
        creator = creator_;
        LaunchConfig memory config = _defaultConfig("Variant", "VAR");
        config.harvestSplit = split;
        (poolId, key, token) = _launchDirect(config);
        vm.deal(address(router), 100_000 ether);
        _graduate();
    }

    // --- Scenario: Crossing the band top completes the milestone ---

    function test_crossingTheBandTopCompletesTheMilestone() public {
        _deployBand(0);
        assertTrue(hook.bandDeployed(poolId, 0), "band is deployed");
        assertFalse(hook.bandCompleted(poolId, 0), "and not yet complete");

        Vm.Log[] memory logs = _buyAndCapture(_bandUpper(0) + PAST_TOP);
        Harvest memory h = _harvestFromLogs(logs, 0);

        // Detection, burn and routing all inside the crossing swap's own transaction.
        assertTrue(h.seen, "harvested in the same transaction");
        assertTrue(hook.bandCompleted(poolId, 0), "marked complete");
        assertEq(_bandLiquidity(0), 0, "position burned");
        assertGt(h.quoteProceeds, 0, "proceeds released");
        assertGt(h.creatorAmount + h.buybackQuote + h.protocolAmount + h.lpAmount, 0, "and routed");

        PoolState memory state = hook.poolState(poolId);
        assertEq(state.completedMilestones, 1, "recorded in state");
        assertEq(h.completedMilestones, 1, "and in the event");
    }

    /// @dev Nothing about the harvest depends on who is trading: a third-party integrator's swap completes
    /// the band, and the creator is still the beneficiary.
    function test_aStrangersSwapHarvestsJustTheSame() public {
        _deployBand(0);

        TestRouter outsider = new TestRouter(IPoolManager(address(manager)));
        vm.deal(address(outsider), 100_000 ether);
        uint256 claimableBefore = hook.creatorClaimable(poolId);

        vm.recordLogs();
        vm.prank(STRANGER);
        outsider.swapToLimit(key, true, -int256(BUDGET), _sqrtAtLevel(_bandUpper(0) + PAST_TOP));
        Harvest memory h = _harvestFromLogs(vm.getRecordedLogs(), 0);

        assertTrue(h.seen, "a stranger's swap harvests");
        assertGt(h.creatorAmount, 0, "the creator share is non-zero");
        assertEq(
            hook.creatorClaimable(poolId) - claimableBefore,
            h.creatorAmount,
            "and it went to the creator, not the swapper"
        );
    }

    /// @dev The band's token inventory left the pool for the buyer, and the quote it fetched came back to
    /// the hook rather than staying stranded in the manager.
    ///
    /// Custody is a claim rather than raw ETH, because this runs inside the crossing swap's callback and the
    /// swapper has not paid yet — see design Decision 13. The claim is currency0's, so its id is 0.
    function test_harvestTakesTheQuoteIntoHookCustody() public {
        _deployBand(0);

        uint256 claimBefore = manager.balanceOf(HOOK_ADDR, 0);
        Harvest memory h = _harvestFromLogs(_buyAndCapture(_bandUpper(0) + PAST_TOP), 0);

        // Everything except the buyback spend and the donated LP share stays in the hook's custody, which
        // is what the creator and protocol ledgers are paid from.
        assertEq(
            manager.balanceOf(HOOK_ADDR, 0) - claimBefore,
            h.quoteProceeds - h.buybackQuote - h.lpAmount,
            "custody rose by exactly the credited shares"
        );
        assertEq(
            manager.balanceOf(HOOK_ADDR, 0) - claimBefore,
            h.creatorAmount + h.protocolAmount,
            "which is creator + protocol"
        );
        // And the manager really holds what the claim promises, so redemption cannot come up short.
        assertGe(address(manager).balance, manager.balanceOf(HOOK_ADDR, 0), "the claim is fully backed");
    }

    // --- Scenario: Partial fill does not complete the milestone ---

    function test_partialFillDoesNotCompleteTheMilestone() public {
        _deployBand(0);
        uint128 liquidity = _bandLiquidity(0);
        int24 lower = _bandLower(0);
        int24 upper = _bandUpper(0);

        // Further into the band: more inventory sold, the top never reached.
        Vm.Log[] memory logs = _buyAndCapture(upper - 20);

        assertEq(_countLogs(logs, MilestoneBase.MilestoneHarvested.selector), 0, "no harvest");
        assertEq(_countLogs(logs, MilestoneBase.HarvestRouted.selector), 0, "and no routing");
        assertGt(_level(), lower, "the price is inside the band");
        assertLt(_level(), upper, "but has not cleared its top");

        assertTrue(hook.bandDeployed(poolId, 0), "the band is still deployed");
        assertFalse(hook.bandCompleted(poolId, 0), "and still incomplete");
        assertEq(hook.poolState(poolId).completedMilestones, 0, "nothing completed");
        assertEq(_bandLiquidity(0), liquidity, "the position is in place, partially converted");
    }

    /// @dev The boundary itself, walked rather than asserted at one point. Completion and "the price
    /// reached the band's top" must be the same condition at every stop, which is where an off-by-one
    /// would show up in either direction.
    function test_completionTracksTheBandTopExactly() public {
        _deployBand(0);
        int24 upper = _bandUpper(0);

        bool completed;
        for (int24 target = upper - 6; target <= upper && !completed; target += 2) {
            _buyToLevel(BUDGET, target);
            completed = hook.poolState(poolId).completedMilestones == 1;

            assertEq(completed, _level() >= upper, "completion and reaching the top are one condition");
        }
        assertTrue(completed, "walking up to the top does complete it");
    }

    // --- Scenario: Band swap fees fold into the harvest ---
    // --- Scenario (swap-fees): Ladder band fees are collected at harvest ---

    function test_bandSwapFeesFoldIntoTheHarvest() public {
        _deployBand(0);
        int24 lower = _bandLower(0);
        int24 upper = _bandUpper(0);
        uint256 principal = _bandPrincipalQuote(0);

        // Churn inside the band so it earns real fees before being crossed. Each of these trades against
        // the band's own liquidity, so the fee lands on the band position rather than only on the full
        // range, and the band is never cleared. It opens with a sell because deployment is simulation-driven
        // (Decision 15) and already left spot mid-band.
        _sellAllToLevel(lower + 10);
        _buyToLevel(BUDGET, upper - 10);
        _sellAllToLevel(lower + 20);
        _buyToLevel(BUDGET, upper - 10);
        assertEq(hook.poolState(poolId).completedMilestones, 0, "still unharvested");

        Harvest memory h = _harvestFromLogs(_buyAndCapture(upper + PAST_TOP), 0);

        assertTrue(h.seen, "harvested");
        // Principal is the whole range converted to quote. Anything above it can only be accrued fees,
        // and there is no separate collection step for them: the burn returns both at once.
        assertGt(h.quoteProceeds, principal, "the harvest carries the band's fees on top of its principal");
    }

    /// @dev With no churn the harvest is principal plus only the fees of the crossing swap itself, so the
    /// same comparison still holds while being much tighter. Together with the test above this shows the
    /// fee component scales with band activity rather than being a constant.
    function test_harvestIsNeverLessThanPrincipal() public {
        _deployBand(0);
        uint256 principal = _bandPrincipalQuote(0);

        Harvest memory h = _harvestFromLogs(_buyAndCapture(_bandUpper(0) + PAST_TOP), 0);

        assertGe(h.quoteProceeds, principal, "never short of principal");
    }

    // --- Scenario: A completed band cannot be harvested again ---

    function test_aCompletedBandCannotBeHarvestedAgain() public {
        _deployBand(0);
        _buyToLevel(BUDGET, _bandUpper(0) + PAST_TOP);
        assertEq(hook.poolState(poolId).completedMilestones, 1, "band 0 complete");

        // More buying, staying below band 1's floor so no second band enters the picture. Targets are
        // computed from one base: the buyback inside the harvest has already moved spot, and each buy
        // moves it again.
        int24 start = _level();
        int24 headroom = _bandLower(1) - start;
        assertGt(headroom, 100, "room to keep buying without reaching band 1");

        vm.recordLogs();
        _buyToLevel(BUDGET, start + headroom / 3);
        _buyToLevel(BUDGET, start + (2 * headroom) / 3);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(_countLogs(logs, MilestoneBase.MilestoneHarvested.selector), 0, "no second harvest");
        assertEq(_countLogs(logs, MilestoneBase.HarvestRouted.selector), 0, "and no second routing");
        assertEq(hook.poolState(poolId).completedMilestones, 1, "still exactly one");
        assertEq(_bandLiquidity(0), 0, "the position stays burned");
    }

    // --- Scenario: Price falling back does not un-complete a band ---

    function test_priceFallingBackDoesNotUncompleteABand() public {
        _deployBand(0);
        int24 lower0 = _bandLower(0);
        int24 upper0 = _bandUpper(0);

        _buyToLevel(BUDGET, upper0 + PAST_TOP);
        uint256 creatorAfterHarvest = hook.creatorClaimable(poolId);
        assertEq(hook.poolState(poolId).completedMilestones, 1, "band 0 complete");

        // All the way back below the band, then up again to just under its old top.
        vm.recordLogs();
        _sellAllToLevel(hook.poolState(poolId).graduationLevel + 100);
        _buyToLevel(BUDGET, lower0 - 50);
        _buyToLevel(BUDGET, upper0 - 5);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(_countLogs(logs, MilestoneBase.MilestoneHarvested.selector), 0, "nothing re-harvested");
        assertEq(_countLogs(logs, MilestoneBase.BandDeployed.selector), 0, "and band 0 was not re-minted");

        PoolState memory state = hook.poolState(poolId);
        assertEq(state.completedMilestones, 1, "the count never falls");
        assertTrue(hook.bandCompleted(poolId, 0), "the band stays complete");
        assertGe(state.nextBandIndex, 1, "nor does the cursor move back");
        assertEq(_bandLiquidity(0), 0, "no position came back");
        assertEq(hook.creatorClaimable(poolId), creatorAfterHarvest, "and nothing was paid twice");
    }

    // --- Scenario: Shares are distributed per configuration ---

    function test_sharesAreDistributedPerConfiguration() public {
        _deployBand(0);

        uint256 creatorBefore = hook.creatorClaimable(poolId);
        uint256 protocolBefore = hook.protocolClaimable(poolId);
        uint256 supplyBefore = token.totalSupply();

        Harvest memory h = _harvestFromLogs(_buyAndCapture(_bandUpper(0) + PAST_TOP), 0);

        HarvestSplit memory split = hook.poolState(poolId).harvestSplit;
        assertEq(h.creatorAmount, (h.quoteProceeds * split.creatorWad) / WAD, "creator wad");
        assertEq(h.protocolAmount, (h.quoteProceeds * split.protocolWad) / WAD, "protocol wad");
        assertEq(h.buybackQuote, (h.quoteProceeds * split.buybackWad) / WAD, "buyback wad");

        // Each share reached its own destination: two ledgers credited, the buyback burned, the LP share
        // compounded into the position the pool trades against.
        assertEq(hook.creatorClaimable(poolId) - creatorBefore, h.creatorAmount, "creator ledger");
        assertEq(hook.protocolClaimable(poolId) - protocolBefore, h.protocolAmount, "protocol ledger");
        assertEq(supplyBefore - token.totalSupply(), h.tokensBurned, "buyback burned what it bought");
        assertGt(h.lpAmount, 0, "and the LP share was routed");
    }

    // --- Scenario: Routed amounts sum to the harvest ---

    function test_routedAmountsSumToTheHarvest() public {
        _deployBand(0);

        Harvest memory h = _harvestFromLogs(_buyAndCapture(_bandUpper(0) + PAST_TOP), 0);

        assertTrue(h.seen, "harvested");
        assertEq(
            h.creatorAmount + h.buybackQuote + h.protocolAmount + h.lpAmount,
            h.quoteProceeds,
            "the four shares account for every wei"
        );
        // The LP share carries the division remainder, so it is the one that can exceed its own wad — by
        // at most three wei, one per flooring division.
        HarvestSplit memory split = hook.poolState(poolId).harvestSplit;
        uint256 nominalLp = (h.quoteProceeds * split.lpWad) / WAD;
        assertGe(h.lpAmount, nominalLp, "LP is never short");
        assertLe(h.lpAmount - nominalLp, 3, "and over by dust at most");
    }

    /// @dev The LP share reaches the full-range position in the harvest itself. It arrives as fee growth
    /// rather than principal — harvest proceeds are quote-only, so there is no token side to pair — which
    /// is why the position's liquidity is unchanged while what it is owed has risen.
    function test_lpShareIsCreditedToTheFullRangePosition() public {
        _deployBand(0);
        uint128 fullRangeBefore = _fullRangeLiquidity();
        assertEq(fullRangeBefore, hook.poolState(poolId).fullRangeLiquidity, "the recorded principal agrees");

        vm.recordLogs();
        _buyToLevel(BUDGET, _bandUpper(0) + PAST_TOP);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        Harvest memory h = _harvestFromLogs(logs, 0);
        assertGt(h.lpAmount, 0, "there was an LP share to route");

        // The donation is the mechanism, and it is quote-only: there is no token side to pair it with.
        uint256 donated0;
        uint256 donated1;
        uint256 donations;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] != IPoolManager.Donate.selector) continue;
            donations++;
            (donated0, donated1) = abi.decode(logs[i].data, (uint256, uint256));
        }
        assertEq(donations, 1, "one donation, from the harvest");
        assertEq(donated0, h.lpAmount, "of exactly the LP share");
        assertEq(donated1, 0, "and nothing on the token side");

        // At donate time the full-range position is the pool's only in-range liquidity — the curves were
        // burned at graduation and the one band that could have been live was just retired — so the credit
        // is entirely its own. It arrives as fee growth rather than principal, which is why its liquidity
        // is unchanged while the pool owes it more quote than before.
        assertEq(_fullRangeLiquidity(), fullRangeBefore, "its principal is untouched, as the design says");
        assertGt(fullRangeBefore, 0, "and it is a real position, so the credit had somewhere to land");
    }

    // --- Scenario: Harvest proceeds are quote only ---

    /// @dev The band sold its whole inventory on the way up, so what the burn releases is ETH. The only
    /// token it can still hold is rounding dust, and that goes back to carried inventory to fund a later
    /// band — never to a recipient, in either currency.
    function test_harvestProceedsAreQuoteOnly() public {
        _deployBand(0);
        uint256 carriedBefore = hook.poolState(poolId).carriedInventory;
        uint256 creatorTokensBefore = token.balanceOf(creator);
        uint256 hookTokensBefore = token.balanceOf(HOOK_ADDR);

        Harvest memory h = _harvestFromLogs(_buyAndCapture(_bandUpper(0) + PAST_TOP), 0);

        assertGt(h.quoteProceeds, 0, "there were proceeds");
        assertEq(
            h.creatorAmount + h.buybackQuote + h.protocolAmount + h.lpAmount,
            h.quoteProceeds,
            "and every routed wei is quote"
        );

        // Whatever token the position still held returned to inventory, and the hook's own balance rose by
        // exactly that much: nothing else on the token side moved.
        PoolState memory state = hook.poolState(poolId);
        assertEq(state.carriedInventory - carriedBefore, h.tokenResidue, "residue carried forward");
        assertEq(token.balanceOf(HOOK_ADDR) - hookTokensBefore, h.tokenResidue, "and is backed by real custody");
        assertEq(token.balanceOf(creator), creatorTokensBefore, "no token reached the creator");
        assertEq(token.balanceOf(PROTOCOL_RECIPIENT), 0, "nor the protocol");
    }

    /// @dev The harvest never rewrites the swapper's deltas: the hook declares no `afterSwapReturnDelta`
    /// permission, so a trader's fill is identical whether or not their swap happened to trigger one. The
    /// proceeds came out of the band's own position, not out of the trader.
    function test_harvestDoesNotChangeWhatTheTraderReceives() public {
        _deployBand(0);

        uint256 routerEthBefore = address(router).balance;
        uint256 routerTokensBefore = token.balanceOf(address(router));

        vm.recordLogs();
        _buyToLevel(BUDGET, _bandUpper(0) + PAST_TOP);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertTrue(_harvestFromLogs(logs, 0).seen, "a harvest did occur");

        // Find the trader's own swap — the buyback's sender is the hook — and check the router's balances
        // moved by exactly its deltas, with nothing added or withheld.
        int128 traderAmount0;
        int128 traderAmount1;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] != IPoolManager.Swap.selector) continue;
            if (address(uint160(uint256(logs[i].topics[2]))) != address(router)) continue;
            (traderAmount0, traderAmount1,,,,) =
                abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
            break;
        }

        assertLt(traderAmount0, 0, "the trader paid quote");
        assertGt(traderAmount1, 0, "and received token");
        assertEq(routerEthBefore - address(router).balance, uint256(uint128(-traderAmount0)), "paid exactly its delta");
        assertEq(
            token.balanceOf(address(router)) - routerTokensBefore,
            uint256(uint128(traderAmount1)),
            "received exactly its delta"
        );
    }

    // --- Scenario: Buyback reduces total supply ---

    function test_buybackReducesTotalSupply() public {
        _deployBand(0);

        uint256 supplyBefore = token.totalSupply();
        uint256 hookTokensBefore = token.balanceOf(HOOK_ADDR);

        vm.recordLogs();
        _buyToLevel(BUDGET, _bandUpper(0) + PAST_TOP);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        Harvest memory h = _harvestFromLogs(logs, 0);

        assertGt(h.buybackQuote, 0, "the buyback spent its share");
        assertGt(h.tokensBurned, 0, "and bought something to burn");
        assertEq(supplyBefore - token.totalSupply(), h.tokensBurned, "supply fell by exactly what was burned");
        assertEq(
            token.balanceOf(HOOK_ADDR), hookTokensBefore + h.tokenResidue, "only the residue was kept, nothing bought"
        );

        // Two swaps in this transaction: the trader's, and the hook's buyback nested inside it.
        assertEq(_countLogs(logs, IPoolManager.Swap.selector), 2, "the buyback is a real swap");
    }

    // --- Scenario: A zero buyback share performs no swap ---
    //
    // The scenario's premise is unreachable through any launch path: `token-launch` requires the buyback
    // share to be at least 10%, which `Bounds.MIN_BUYBACK_HARVEST_SHARE_WAD` enforces, and
    // `LaunchConfigLib.t.sol:test_zeroBuybackShareIsRejected` pins that at the validator. The two
    // requirements contradict each other. `_buyBackAndBurn` does honour a zero share — it returns before
    // swapping, and says so in its own comment — but no launch can ever hand it one. Asserted below is
    // what is actually reachable: the configuration is refused end to end, and the smallest share the
    // bounds do permit routes the remaining shares normally — the half of this scenario that describes
    // observable behaviour.

    function test_aZeroBuybackShareCannotBeLaunched() public {
        LaunchConfig memory config = _defaultConfig("Zero", "ZERO");
        config.harvestSplit = _split(0.6e18, 0, 0.1e18);

        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(LaunchConfigLib.BuybackHarvestShareBelowFloor.selector, uint64(0)));
        hook.launch(config, "");
    }

    function test_theSmallestPermittedBuybackShareRoutesTheRestNormally() public {
        _relaunch(creator, _split(0.6e18, uint64(Bounds.MIN_BUYBACK_HARVEST_SHARE_WAD), 0.1e18));
        _deployBand(0);

        uint256 supplyBefore = token.totalSupply();
        vm.recordLogs();
        _buyToLevel(BUDGET, _bandUpper(0) + PAST_TOP);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        Harvest memory h = _harvestFromLogs(logs, 0);

        assertTrue(h.seen, "still harvested");
        assertEq(h.buybackQuote, (h.quoteProceeds * Bounds.MIN_BUYBACK_HARVEST_SHARE_WAD) / WAD, "the floor share");
        assertEq(supplyBefore - token.totalSupply(), h.tokensBurned, "burned what it bought");

        // The remaining shares are routed normally.
        assertEq(h.creatorAmount + h.buybackQuote + h.protocolAmount + h.lpAmount, h.quoteProceeds, "everything routed");
        assertGt(h.creatorAmount, 0, "creator share paid");
        assertGt(h.protocolAmount, 0, "protocol share paid");
        assertGt(h.lpAmount, 0, "LP share compounded");
    }

    // --- Scenario: Creator proceeds are not pushed ---

    function test_creatorProceedsAreNotPushed() public {
        RejectingCreator rejecting = new RejectingCreator();
        _relaunch(address(rejecting), _split(0.6e18, 0.2e18, 0.1e18));
        _deployBand(0);

        // A creator that reverts on receive must not be able to fail the swap that completed its
        // milestone. If any part of the harvest pushed ETH, this call would revert.
        Harvest memory h = _harvestFromLogs(_buyAndCapture(_bandUpper(0) + PAST_TOP), 0);

        assertTrue(h.seen, "the harvest went through");
        assertGt(h.creatorAmount, 0, "there was a creator share");
        assertEq(address(rejecting).balance, 0, "nothing was pushed");
        assertGe(hook.creatorClaimable(poolId), h.creatorAmount, "it is sitting in the ledger instead");
    }

    // --- Scenario (revenue-claims): Harvest creator share accrues ---

    /// @dev The credit is attributed to the harvest and is claimable by the revenue NFT holder like any
    /// other accrual.
    function test_harvestCreatorShareAccruesAndIsClaimable() public {
        _deployBand(0);

        vm.recordLogs();
        _buyToLevel(BUDGET, _bandUpper(0) + PAST_TOP);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        Harvest memory h = _harvestFromLogs(logs, 0);

        // The accrual names its source, so an indexer can attribute revenue without inferring it.
        bool sawHarvestAccrual;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] != MilestoneBase.CreatorAccrued.selector) continue;
            (uint256 amount, uint8 source) = abi.decode(logs[i].data, (uint256, uint8));
            if (source == uint8(MilestoneBase.AccrualSource.MILESTONE_HARVEST) && amount == h.creatorAmount) {
                sawHarvestAccrual = true;
            }
        }
        assertTrue(sawHarvestAccrual, "credited with the harvest as its source");

        uint256 claimable = hook.creatorClaimable(poolId);
        assertGe(claimable, h.creatorAmount, "the harvest share is claimable");

        uint256 creatorBalanceBefore = creator.balance;
        vm.prank(creator);
        uint256 paid = hook.claimCreator(poolId);

        assertEq(paid, claimable, "the holder claims the whole balance");
        assertEq(creator.balance - creatorBalanceBefore, claimable, "and receives it");
        assertEq(hook.creatorClaimable(poolId), 0, "the ledger is cleared");
    }

    /// @dev Harvest proceeds are claimable as real ETH even though the harvest never produced any — they
    /// were minted as a claim on the manager (design Decision 13), and the claim path redeems it.
    ///
    /// This is not a test that merely happens to take that path. The hook's raw ETH and its ledgers both
    /// come from the graduation split — it retains exactly what it accrued there — so after a harvest the
    /// ledgers owe strictly more real ETH than the hook holds. Draining both therefore *must* redeem, and
    /// must redeem exactly the shortfall and no more.
    function test_claimsRedeemTheHarvestClaimWhenRawEthIsShort() public {
        _deployBand(0);
        _buyToLevel(BUDGET, _bandUpper(0) + PAST_TOP);

        uint256 owed = hook.creatorClaimable(poolId) + hook.protocolClaimable(poolId);
        uint256 rawBefore = HOOK_ADDR.balance;
        uint256 claimBefore = manager.balanceOf(HOOK_ADDR, 0);
        assertGt(owed, rawBefore, "the ledgers owe more ETH than the hook holds, so redemption is forced");

        uint256 creatorBalanceBefore = creator.balance;
        vm.prank(creator);
        uint256 toCreator = hook.claimCreator(poolId);
        vm.prank(PROTOCOL_RECIPIENT);
        uint256 toProtocol = hook.claimProtocol(poolId);

        assertEq(toCreator + toProtocol, owed, "both ledgers paid in full");
        assertEq(creator.balance - creatorBalanceBefore, toCreator, "the creator holds real ETH, not a claim");
        assertEq(PROTOCOL_RECIPIENT.balance, toProtocol, "and so does the protocol");
        assertEq(claimBefore - manager.balanceOf(HOOK_ADDR, 0), owed - rawBefore, "redeemed exactly the shortfall");
        assertEq(HOOK_ADDR.balance, 0, "nothing was redeemed that was not needed, and nothing stranded");
    }

    // --- Scenario: Nested buyback swap does not re-enter settlement ---

    function test_nestedBuybackSwapDoesNotReenterSettlement() public {
        _deployBand(0);

        vm.recordLogs();
        _buyToLevel(BUDGET, _bandUpper(0) + PAST_TOP);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        Harvest memory h = _harvestFromLogs(logs, 0);

        assertGt(h.buybackQuote, 0, "the nested swap ran");
        // The buyback pushes the price further up, and it runs after the band has been retired. Without the
        // guard its own callbacks could deploy or skip bands mid-settlement, or try to harvest a second
        // time off the price it just moved.
        assertEq(_countLogs(logs, MilestoneBase.MilestoneHarvested.selector), 1, "exactly one harvest");
        assertEq(_countLogs(logs, MilestoneBase.HarvestRouted.selector), 1, "routed exactly once");
        assertEq(_countLogs(logs, MilestoneBase.BandDeployed.selector), 0, "the nested swap deployed nothing");
        assertEq(_countLogs(logs, MilestoneBase.BandSkipped.selector), 0, "and skipped nothing");
        assertEq(hook.poolState(poolId).completedMilestones, 1, "one milestone, not two");
        assertEq(_deployedBandCount() - _completedBandCount(), 0, "no band was left live by the nested swap");
    }

    // --- Scenario: Guard does not leak across transactions ---

    function test_guardDoesNotLeakAcrossTransactions() public {
        _deployBand(0);
        _buyToLevel(BUDGET, _bandUpper(0) + PAST_TOP);
        assertEq(hook.poolState(poolId).completedMilestones, 1, "first harvest done");

        // A separate transaction. If the settlement lock had survived the first harvest, every ladder and
        // harvest path would silently no-op from here on.
        _deployBand(1);
        Harvest memory h = _harvestFromLogs(_buyAndCapture(_bandUpper(1) + PAST_TOP), 1);

        assertTrue(h.seen, "the second milestone harvested too");
        assertEq(h.index, 1, "band 1 this time");
        assertEq(h.completedMilestones, 2, "two complete");
        assertEq(_completedBandCount(), 2, "and both are marked");
        assertGe(hook.poolState(poolId).nextBandIndex, 2, "the cursor kept moving");
    }

    // --- Scenario: Reverting nested interaction does not corrupt state ---

    function test_revertingNestedInteractionDoesNotCorruptState() public {
        _deployBand(0);
        int24 upper = _bandUpper(0);
        uint128 liquidity = _bandLiquidity(0);

        PoolState memory before = hook.poolState(poolId);
        uint256 creatorBefore = hook.creatorClaimable(poolId);
        uint256 supplyBefore = token.totalSupply();

        RevertingSwapper swapper = new RevertingSwapper(IPoolManager(address(manager)));
        vm.deal(address(swapper), 100_000_000 ether);

        vm.expectRevert(RevertingSwapper.Deliberate.selector);
        swapper.swapThenRevert(key, -50_000_000 ether, _sqrtAtLevel(upper + PAST_TOP));

        // Everything the harvest wrote is gone with the transaction, including the burn.
        PoolState memory afterRevert = hook.poolState(poolId);
        assertEq(afterRevert.completedMilestones, before.completedMilestones, "no milestone recorded");
        assertEq(afterRevert.nextBandIndex, before.nextBandIndex, "cursor unchanged");
        assertTrue(hook.bandDeployed(poolId, 0), "the band is still deployed");
        assertFalse(hook.bandCompleted(poolId, 0), "and still incomplete");
        assertEq(_bandLiquidity(0), liquidity, "its position is intact");
        assertEq(hook.creatorClaimable(poolId), creatorBefore, "nothing accrued");
        assertEq(token.totalSupply(), supplyBefore, "nothing burned");

        // And the lock did not survive: the same crossing now works normally.
        Harvest memory h = _harvestFromLogs(_buyAndCapture(upper + PAST_TOP), 0);
        assertTrue(h.seen, "the harvest still works after the failed attempt");
        assertEq(h.index, 0, "on the band that was preserved");
    }
}
