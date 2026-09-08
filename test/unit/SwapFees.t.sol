// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {HarnessLaunchpadTest} from "../HarnessFixtures.sol";
import {MilestoneBase} from "../../src/MilestoneBase.sol";
import {Bounds, FEE_DENOMINATOR, HarvestSplit, LaunchConfig, Phase} from "../../src/types/LaunchTypes.sol";

/// @notice Shared rig for the swap-fee suites: sizes that keep a measurement clear of the ladder, and the
/// log decoding the two fee events need.
///
/// @dev Built on the harness rather than the plain hook because the milestone-fund suite layers on top of
/// this fixture and needs `forceLadderCappedOut`. Nothing here depends on a test-only entry point; the
/// harness only swaps the deployed artifact, leaving the production wiring alone.
abstract contract FeeFixture is HarnessLaunchpadTest {
    using StateLibrary for IPoolManager;

    /// @dev 1% of the graduated full-range position's 100M token side. Large enough that its fee dominates
    /// growth dust, small enough that the price barely moves.
    uint256 internal constant MEASURED_SELL = 1_000_000 ether;

    /// @dev A *budget*, not an amount: every buy here is price-limited below the ladder, so what is
    /// actually spent is whatever it takes to walk the price back to the ceiling.
    uint256 internal constant MEASURED_BUY = 100 ether;

    /// @dev A budget for a genesis buy, spent against a level limit inside the first curve position.
    uint256 internal constant GENESIS_BUY = 10 ether;

    /// @dev An amount, not a budget: small enough that an unlimited buy against a fresh curve is an
    /// ordinary trade rather than a run up the whole ladder.
    uint256 internal constant SMALL_BUY = 0.05 ether;

    // --- Trading inside a single curve position ---

    /// @notice Start level of curve position 1 — the first level at which a second position joins the
    /// active set.
    ///
    /// @dev The curve is nested: position `i` spans `[opening + i*span/n, far]`, so every position shares
    /// the same upper edge and they stack as the level rises. Active liquidity is therefore *not* constant
    /// across a large genesis buy, which matters because `feeGrowthGlobal` accumulates `fee / L` per step:
    /// scaling the total back up by one `L` is only exact while the swap met exactly one.
    function _secondCurvePositionStart() internal view returns (int24) {
        return hook.curvePositionStart(poolId, 1);
    }

    /// @notice Buys with `ethIn` as a budget, stopping short of level `stopBelow`.
    /// @return spent The ETH the swap actually consumed before the limit bound it.
    function _buyStoppingBelow(uint256 ethIn, int24 stopBelow) internal returns (uint256 spent) {
        BalanceDelta delta = _buyToLevel(ethIn, stopBelow);
        spent = uint256(uint128(-delta.amount0()));
    }

    // --- Trading clear of the ladder ---

    /// @notice One level below the next undeployed band's lower bound: the highest level a buy can reach
    /// without waking the ladder up.
    ///
    /// @dev `_deployBandsAhead` walks the swap it is about to allow and calls `LadderLib.advance` towards
    /// the band's lower bound; `advance` clamps its target to the caller's own price limit and reports
    /// failure when the clamp binds, so the deploy loop breaks before minting anything. The real swap stops
    /// in the same place, so no band top is crossed and nothing is harvested either. This is what the
    /// parked suite's `_safeCeiling` did against the deleted `deployWindowLevels`.
    function _ceiling() internal view returns (int24) {
        return _bandLower(hook.poolState(poolId).nextBandIndex) - 1;
    }

    /// @notice Buys with `ethIn` as a budget, stopping short of the ladder.
    function _buyClearOfTheLadder(uint256 ethIn) internal returns (BalanceDelta) {
        return _buyToLevel(ethIn, _ceiling());
    }

    /// @notice Collects whatever has accrued, so the next measurement starts from a clean position.
    function _clearAccrual() internal {
        hook.collectFees(key);
    }

    // --- Fee arithmetic ---

    /// @dev What v4 charges on an exact-input swap of `amount` at `feePips`: the input available to the
    /// curve is `floor(amount * (1e6 - feePips) / 1e6)` and the fee is everything left over.
    function _feeOn(uint256 amount, uint24 feePips) internal pure returns (uint256) {
        return amount - (amount * (FEE_DENOMINATOR - feePips)) / FEE_DENOMINATOR;
    }

    /// @dev The pool's quote-side fee growth accumulator.
    function _quoteFeeGrowth() internal view returns (uint256 growth) {
        (growth,) = IPoolManager(address(manager)).getFeeGrowthGlobals(poolId);
    }

    /// @dev The token-side accumulator. Useful only pre-graduation, where a fee is provably charged but
    /// never collected: with no full-range position there is nothing for `collectFees` to realise it from.
    function _tokenFeeGrowth() internal view returns (uint256 growth) {
        (, growth) = IPoolManager(address(manager)).getFeeGrowthGlobals(poolId);
    }

    /// @dev The quote fee a swap actually paid, recovered from that accumulator rather than from the hook's
    /// books — curve-phase fees are never collected, so before graduation this is the only way to read what
    /// a trader was charged. v4 raises `feeGrowthGlobal0` by `fee * 2**128 / liquidity`, so multiplying the
    /// rise back by the liquidity the swap met returns the fee. Exact only while that liquidity is constant
    /// across the swap, which the caller arranges by keeping the trade inside one position.
    function _feeFromGrowth(uint256 growthBefore, uint128 liquidity) internal view returns (uint256) {
        return ((_quoteFeeGrowth() - growthBefore) * liquidity) >> 128;
    }

    // --- Log decoding ---

    struct Collected {
        bool seen;
        address caller;
        uint256 quoteFees;
        uint256 tokenFees;
        bool routed;
        uint256 lpQuote;
        uint256 lpToken;
        uint256 creatorQuote;
        uint256 protocolQuote;
        uint256 diverted;
        uint128 liquidityAdded;
    }

    function _collectedFromLogs(Vm.Log[] memory logs) internal pure returns (Collected memory c) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == MilestoneBase.FeesCollected.selector) {
                c.seen = true;
                c.caller = address(uint160(uint256(logs[i].topics[2])));
                (c.quoteFees, c.tokenFees) = abi.decode(logs[i].data, (uint256, uint256));
            } else if (logs[i].topics[0] == MilestoneBase.FeesRouted.selector) {
                c.routed = true;
                (c.lpQuote, c.lpToken, c.creatorQuote, c.protocolQuote, c.diverted, c.liquidityAdded) =
                    abi.decode(logs[i].data, (uint256, uint256, uint256, uint256, uint256, uint128));
            }
        }
    }

    /// @dev Collects as `caller` and returns everything the two fee events reported.
    function _collectAs(address caller) internal returns (Collected memory) {
        vm.recordLogs();
        vm.prank(caller);
        hook.collectFees(key);
        return _collectedFromLogs(vm.getRecordedLogs());
    }

    function _collectAndCapture() internal returns (Collected memory) {
        vm.recordLogs();
        hook.collectFees(key);
        return _collectedFromLogs(vm.getRecordedLogs());
    }
}

/// @notice The same rig with the pool already graduated, which is the only state in which a full-range
/// position exists for the waterfall to collect from.
abstract contract GraduatedFeeFixture is FeeFixture {
    function setUp() public virtual override {
        super.setUp();
        _graduate();

        // Decision 18 graduates inside the *next* swap's `beforeSwap`, so `_graduate()` signs off with a
        // dust buy whose fee lands in the brand-new full-range position. Sweeping it here starts every
        // measurement below from a position with nothing accrued, at the price of a few wei of quote left
        // in `pendingLpQuote` — the rounding dust the specs provide for.
        _clearAccrual();
    }
}

/// @notice Unit tests for the `swap-fees` requirement "Default swap fee" — the flat 1% the template sets,
/// and the absence of any launch-window schedule on top of it.
///
/// @dev design Decision 20 removed the anti-snipe decay and with it the `beforeSwap` fee override, so there
/// is no longer a mechanism by which the charged fee could differ from the stored one. These tests hold the
/// pool to that: they measure what a trader was actually charged, at genesis and a year later, rather than
/// only reading the stored value back.
contract DefaultSwapFeeTest is FeeFixture {
    // --- Scenario: The base fee applies from genesis ---

    function test_theBaseFeeAppliesFromGenesis() public {
        // Before any trade at all, the pool is already set to the template's fee and the hook agrees.
        assertEq(_baseFeeOf(poolId), template.baseFeeHundredthsBip, "the pool opens at the template's base fee");
        assertEq(hook.poolState(poolId).baseFeeHundredthsBip, template.baseFeeHundredthsBip, "and the hook agrees");
        assertEq(template.baseFeeHundredthsBip, 10_000, "which is 1%");

        // And that is what the very first swap is charged. Both buys stop inside curve position 0, so the
        // liquidity they met is the one the accumulator has to be scaled by.
        int24 opening = hook.poolState(poolId).openingLevel;
        int24 boundary = _secondCurvePositionStart();
        int24 firstStop = opening + (boundary - opening) / 3;
        int24 secondStop = opening + (2 * (boundary - opening)) / 3;

        uint256 growthBefore = _quoteFeeGrowth();
        uint256 firstIn = _buyStoppingBelow(GENESIS_BUY, firstStop);
        uint128 liquidity = _poolLiquidity(poolId);
        assertGt(firstIn, 0, "the buy really traded");
        assertGt(liquidity, 0, "and met real curve liquidity");
        assertEq(_deployedCurveCount(), 1, "without waking a second position, so one liquidity all through");

        uint256 firstFee = _feeFromGrowth(growthBefore, liquidity);
        assertApproxEqRel(firstFee, _feeOn(firstIn, template.baseFeeHundredthsBip), 0.0005e18, "the first swap paid 1%");

        // Identical on the next swap, and the stored fee is where it started.
        growthBefore = _quoteFeeGrowth();
        uint256 secondIn = _buyStoppingBelow(GENESIS_BUY, secondStop);
        assertGt(secondIn, 0, "the second buy really traded too");
        assertEq(_poolLiquidity(poolId), liquidity, "still the same single position");

        uint256 secondFee = _feeFromGrowth(growthBefore, liquidity);
        assertApproxEqRel(secondFee, _feeOn(secondIn, template.baseFeeHundredthsBip), 0.0005e18, "and so did the next");
        assertEq(_baseFeeOf(poolId), template.baseFeeHundredthsBip, "trading does not move the base fee");
    }

    // --- Scenario: The fee does not depend on time since launch ---

    /// @dev Two launches of the same shape open at the same level with the same geometry, so the same input
    /// must buy the same output — unless the fee between them differs. Comparing two pools rather than two
    /// swaps in one pool is what makes this exact: no price has moved in between, so any difference in
    /// output is a difference in fee and nothing else.
    function test_theFeeDoesNotDependOnTimeSinceLaunch() public {
        (PoolId lateId, PoolKey memory lateKey,) = _launchDirect(_defaultConfig("Later", "LATE"));

        BalanceDelta immediate = router.swap(key, true, -int256(SMALL_BUY));

        vm.warp(launchTime + 365 days);
        BalanceDelta muchLater = router.swap(lateKey, true, -int256(SMALL_BUY));

        assertEq(immediate.amount0(), -int256(SMALL_BUY), "the same input");
        assertEq(muchLater.amount0(), -int256(SMALL_BUY), "on both pools");
        assertEq(muchLater.amount1(), immediate.amount1(), "bought the same output a year apart");
        assertEq(_baseFeeOf(lateId), _baseFeeOf(poolId), "and the stored fee is the same too");
    }
}

/// @notice Unit tests for task 10.1 — permissionless fee collection.
///
/// @dev design Decision 9 was revised during implementation: collection is a *zero-delta* `modifyLiquidity`
/// rather than the sliver burn and re-add the decision originally described. `Position.update` computes fees
/// owed from the position's existing liquidity and skips the principal branch entirely when the delta is
/// zero, so the position's liquidity, bounds and tick bitmap are never touched. That turns "net liquidity is
/// unreduced" from an outcome these tests have to check after the fact into a property of the call itself —
/// there was no sliver to put back. The tests below still check it, because the requirement is about the
/// observable position rather than about how it is realised.
contract FeeCollectionTest is GraduatedFeeFixture {
    // --- Scenario: Any address can trigger collection ---

    function test_anyAddressCanTriggerCollection() public {
        _sell(MEASURED_SELL);
        _buyClearOfTheLadder(MEASURED_BUY);

        uint256 strangerEthBefore = STRANGER.balance;
        Collected memory c = _collectAs(STRANGER);

        assertTrue(c.seen, "an address with no role in the protocol collected");
        assertEq(c.caller, STRANGER, "and the log records who asked");
        assertGt(c.quoteFees, 0, "quote fees were realised");
        assertGt(c.tokenFees, 0, "token fees were realised");
        assertTrue(c.routed, "and routed");

        // Permissionless is not the same as paid: the caller is not a party to the waterfall, so there is
        // nothing for a bot to extract by racing to be the one who triggers it.
        assertEq(STRANGER.balance, strangerEthBefore, "the caller earns nothing");
        assertEq(token.balanceOf(STRANGER), 0, "in either currency");
    }

    function test_collectionIsGatedOnNoRoleAtAll() public {
        address[4] memory callers = [STRANGER, creator, PROTOCOL_RECIPIENT, PROTOCOL_ADMIN];

        for (uint256 i = 0; i < callers.length; i++) {
            _sell(MEASURED_SELL);
            Collected memory c = _collectAs(callers[i]);

            assertTrue(c.seen, "every caller can collect");
            assertEq(c.caller, callers[i], "and each is recorded as the one who did");
            assertGt(c.tokenFees, 0, "with real work done each time");
        }
    }

    // --- Scenario: Net position is preserved ---
    // --- Scenario (graduation): Fee collection preserves net liquidity ---

    /// @dev The lopsided case, which is the common one: v4 charges the fee on the swap's input, so a stretch
    /// of one-directional trading accrues in one currency only and there is next to nothing to pair at spot.
    /// The requirement is "at least", and the mechanism delivers rather more — the position is never taken
    /// apart, so what little it moves is a carried remainder finally pairing, never a shortfall from a burn.
    function test_netPositionIsPreservedWhenOnlyOneSideAccrued() public {
        uint128 liquidityBefore = _fullRangeLiquidity();

        _sell(MEASURED_SELL);
        (uint256 quoteFees, uint256 tokenFees) = hook.collectFees(key);

        assertEq(quoteFees, 0, "a sell pays its fee in token only");
        assertGt(tokenFees, 0, "and it did pay one");
        assertGe(_fullRangeLiquidity(), liquidityBefore, "liquidity is never reduced");
        assertApproxEqRel(_fullRangeLiquidity(), liquidityBefore, 1e12, "not reduced and rebuilt, either");
        assertEq(hook.poolState(poolId).fullRangeLiquidity, _fullRangeLiquidity(), "and the hook's record agrees");
    }

    function test_netLiquidityNeverDecreasesAcrossManyCollections() public {
        uint128 previous = _fullRangeLiquidity();
        uint128 opening = previous;

        for (uint256 i = 0; i < 4; i++) {
            _sell(MEASURED_SELL);
            _buyClearOfTheLadder(MEASURED_BUY);
            hook.collectFees(key);

            uint128 current = _fullRangeLiquidity();
            assertGe(current, previous, "collection never reduces the position");
            previous = current;
        }

        // Not a vacuous pass: with both currencies arriving, the LP share really did compound.
        assertGt(previous, opening, "and over a two-sided market it grows");
    }

    // --- Scenario: Repeated collection is harmless ---

    function test_repeatedCollectionIsHarmless() public {
        _sell(MEASURED_SELL);
        _buyClearOfTheLadder(MEASURED_BUY);

        uint256 workingGasBefore = gasleft();
        hook.collectFees(key);
        uint256 workingGas = workingGasBefore - gasleft();

        uint128 liquidity = _fullRangeLiquidity();
        uint256 creatorQuote = hook.creatorClaimable(poolId);
        uint256 protocolQuote = hook.protocolClaimable(poolId);
        uint256 accrued = hook.poolState(poolId).milestoneFundAccrued;
        uint256 carriedQuote = hook.poolState(poolId).pendingLpQuote;
        uint256 carriedToken = hook.poolState(poolId).pendingLpToken;
        uint256 hookEth = HOOK_ADDR.balance;
        uint256 hookTokens = token.balanceOf(HOOK_ADDR);

        for (uint256 i = 0; i < 3; i++) {
            vm.recordLogs();
            uint256 gasBefore = gasleft();
            (uint256 quoteFees, uint256 tokenFees) = hook.collectFees(key);
            uint256 gasUsed = gasBefore - gasleft();
            Vm.Log[] memory logs = vm.getRecordedLogs();

            // Both early returns sit above the `FeesCollected` emit, so silence is the observable form of
            // "nothing happened" — there is no zero-valued event to sift out of a log stream.
            assertEq(logs.length, 0, "nothing happened, so nothing was announced");
            assertEq(quoteFees, 0, "and nothing was collected");
            assertEq(tokenFees, 0, "in either currency");
            assertLt(gasUsed, workingGas / 4, "far cheaper than the call that did the work");
            assertLt(gasUsed, 60_000, "and bounded outright, so spamming it grieves nobody");
        }

        assertEq(_fullRangeLiquidity(), liquidity, "the position is unchanged in net terms");
        assertEq(hook.creatorClaimable(poolId), creatorQuote, "no ledger moved");
        assertEq(hook.protocolClaimable(poolId), protocolQuote, "no ledger moved");
        assertEq(hook.poolState(poolId).milestoneFundAccrued, accrued, "the milestone fund did not grow");
        assertEq(hook.poolState(poolId).pendingLpQuote, carriedQuote, "and nothing was drawn from the carry");
        assertEq(hook.poolState(poolId).pendingLpToken, carriedToken, "on either side");
        assertEq(HOOK_ADDR.balance, hookEth, "no value left the manager a second time");
        assertEq(token.balanceOf(HOOK_ADDR), hookTokens, "in either currency");
    }

    // --- Scenario: Collection with zero accrual is a no-op ---

    function test_collectionWithZeroAccrualIsANoOp() public {
        // The fixture swept graduation's trailing dust, so the position exists and is in range but has
        // nothing outstanding.
        uint128 liquidity = _fullRangeLiquidity();
        assertGt(liquidity, 0, "the position is really there");

        vm.recordLogs();
        (uint256 quoteFees, uint256 tokenFees) = hook.collectFees(key);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(logs.length, 0, "no events at all");
        assertEq(quoteFees, 0, "nothing to collect");
        assertEq(tokenFees, 0, "nothing to collect");
        assertEq(_fullRangeLiquidity(), liquidity, "and the position is untouched");
    }

    /// @dev The pre-graduation answer to the same requirement. Curve-phase fees are not lost, they are
    /// simply not collected here: they sit in the curve positions and fold into the graduation proceeds when
    /// those are burned, so this path has nothing to do until a full-range position exists.
    function test_collectionBeforeGraduationIsANoOp() public {
        (PoolId youngId, PoolKey memory youngKey,) = _launchDirect(_defaultConfig("Curveling", "CURV"));
        assertEq(uint8(hook.poolPhase(youngId)), uint8(Phase.BONDING_CURVE), "still on its curve");

        // Trade against its curve so fees really are accruing somewhere in the pool.
        router.swap(youngKey, true, -1 ether);

        vm.recordLogs();
        (uint256 quoteFees, uint256 tokenFees) = hook.collectFees(youngKey);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(logs.length, 0, "no events");
        assertEq(quoteFees, 0, "nothing collected");
        assertEq(tokenFees, 0, "nothing collected");
        assertEq(hook.poolState(youngId).fullRangeLiquidity, 0, "because there is no position to collect from");
    }

    // --- Collection realises value out of the singleton, not merely on paper ---

    function test_tokenFeesAreRealisedIntoHookCustody() public {
        uint256 carriedBefore = hook.poolState(poolId).pendingLpToken;
        uint256 hookTokensBefore = token.balanceOf(HOOK_ADDR);

        _sell(MEASURED_SELL);
        Collected memory c = _collectAndCapture();

        // Whatever the pairing consumed went back into the pool as liquidity; the rest left the manager for
        // hook custody, which is where the ledgers and the milestone fund are paid from.
        uint256 paired = (carriedBefore + c.lpToken) - hook.poolState(poolId).pendingLpToken;
        assertGt(c.tokenFees, 0, "the sell paid a fee");
        assertEq(token.balanceOf(HOOK_ADDR) - hookTokensBefore, c.tokenFees - paired, "the rest became a real balance");
    }

    function test_quoteFeesAreRealisedAsNativeEth() public {
        uint256 carriedBefore = hook.poolState(poolId).pendingLpQuote;
        uint256 hookEthBefore = HOOK_ADDR.balance;

        _buyClearOfTheLadder(MEASURED_BUY);
        Collected memory c = _collectAndCapture();

        uint256 paired = (carriedBefore + c.lpQuote) - hook.poolState(poolId).pendingLpQuote;
        assertGt(c.quoteFees, 0, "the buy paid a fee");
        assertEq(HOOK_ADDR.balance - hookEthBefore, c.quoteFees - paired, "and it arrived as native ETH");
    }
}

/// @notice Unit tests for tasks 10.2 and 10.3 — the fee waterfall and its LP compounding.
contract FeeWaterfallTest is GraduatedFeeFixture {
    // --- Scenario: Quote fees split three ways on collection ---

    function test_quoteFeesSplitThreeWays() public {
        _buyClearOfTheLadder(MEASURED_BUY);
        Collected memory c = _collectAndCapture();

        assertGt(c.quoteFees, 0, "the buy paid its fee in ETH");
        assertEq(c.tokenFees, 0, "and not in token");
        assertEq(c.diverted, 0, "quote is never diverted, so the whole amount reaches the waterfall");

        assertEq(c.creatorQuote, (c.quoteFees * 3) / 10, "30% to the creator");
        assertEq(c.protocolQuote, c.quoteFees / 10, "10% to the protocol");
        assertEq(c.lpQuote, c.quoteFees - c.creatorQuote - c.protocolQuote, "the LP takes the remainder");
        assertApproxEqAbs(c.lpQuote, (c.quoteFees * 6) / 10, 10, "which is 60%, plus the division dust");
    }

    // --- Scenario: Token fees are never credited to a recipient ---

    /// @dev design Decision 21. Token fees paid to a creator or the protocol would be income realisable
    /// only by selling into the pool's own holders, so the whole token side goes to pool-facing
    /// destinations: the milestone fund's next-band inventory, and full-range compounding.
    function test_tokenFeesAreNeverCreditedToARecipient() public {
        uint256 creatorBefore = hook.creatorClaimable(poolId);
        uint256 protocolBefore = hook.protocolClaimable(poolId);
        uint256 creatorTokensBefore = token.balanceOf(creator);
        uint256 recipientTokensBefore = token.balanceOf(PROTOCOL_RECIPIENT);

        _sell(MEASURED_SELL);
        Collected memory c = _collectAndCapture();

        assertGt(c.tokenFees, 0, "the sell paid a real fee in token");
        assertEq(c.quoteFees, 0, "and nothing in quote, so no ledger has any business moving");

        assertEq(hook.creatorClaimable(poolId), creatorBefore, "the creator's ledger did not move");
        assertEq(hook.protocolClaimable(poolId), protocolBefore, "nor the protocol's");
        assertEq(token.balanceOf(creator), creatorTokensBefore, "and no token was pushed to either");
        assertEq(token.balanceOf(PROTOCOL_RECIPIENT), recipientTokensBefore, "and no token was pushed to either");

        // Every wei of it went to the fund or to the pool: those are the only two destinations there are.
        assertEq(c.diverted + c.lpToken, c.tokenFees, "the token side is fully accounted for by the two");
        assertEq(c.diverted, (c.tokenFees * 2) / 10, "20% to the next band's inventory");
        assertEq(c.lpToken, c.tokenFees - c.diverted, "and the remainder compounds");

        // There is no token claim entry point to reach it with, either.
        (bool ok,) = HOOK_ADDR.call(abi.encodeWithSignature("claimCreatorTokens(bytes32)", PoolId.unwrap(poolId)));
        assertFalse(ok, "no token claim exists for the creator");
        (ok,) = HOOK_ADDR.call(abi.encodeWithSignature("claimProtocolTokens(bytes32)", PoolId.unwrap(poolId)));
        assertFalse(ok, "nor for the protocol");
    }

    // --- Scenario: Routed amounts sum to collected fees ---

    function test_routedAmountsSumToCollectedFees() public {
        _sell(MEASURED_SELL);
        _buyClearOfTheLadder(MEASURED_BUY);
        Collected memory c = _collectAndCapture();

        assertGt(c.quoteFees, 0, "both sides accrued");
        assertGt(c.tokenFees, 0, "both sides accrued");

        assertEq(c.lpQuote + c.creatorQuote + c.protocolQuote, c.quoteFees, "the quote side is fully accounted for");
        assertEq(c.lpToken + c.diverted, c.tokenFees, "and the token side, diversion included");
    }

    function testFuzz_routedAmountsSumToCollectedFees(uint256 sellAmount, uint256 buyAmount) public {
        sellAmount = bound(sellAmount, 1_000 ether, token.balanceOf(address(router)) / 2);
        buyAmount = bound(buyAmount, 0.01 ether, 50 ether);

        _sell(sellAmount);
        _buyClearOfTheLadder(buyAmount);
        Collected memory c = _collectAndCapture();

        assertEq(c.lpQuote + c.creatorQuote + c.protocolQuote, c.quoteFees, "quote side sums, at every size");
        assertEq(c.lpToken + c.diverted, c.tokenFees, "token side sums, at every size");
    }

    // --- Scenario: The LP share compounds ---

    function test_theLpShareCompoundsIntoTheFullRangePosition() public {
        _sell(MEASURED_SELL);
        _buyClearOfTheLadder(MEASURED_BUY);

        uint128 liquidityBefore = _fullRangeLiquidity();
        uint256 creatorQuoteBefore = hook.creatorClaimable(poolId);
        uint256 protocolQuoteBefore = hook.protocolClaimable(poolId);

        Collected memory c = _collectAndCapture();

        assertGt(c.liquidityAdded, 0, "the pairing minted liquidity");
        assertEq(_fullRangeLiquidity() - liquidityBefore, c.liquidityAdded, "v4 holds exactly what was reported");
        assertEq(
            hook.poolState(poolId).fullRangeLiquidity - liquidityBefore,
            c.liquidityAdded,
            "and the hook's own record agrees"
        );

        // Compounding means "became liquidity", not "was credited somewhere". The ledgers moved by exactly
        // their own shares and not by a wei of the LP's.
        assertEq(hook.creatorClaimable(poolId) - creatorQuoteBefore, c.creatorQuote, "creator got the creator share");
        assertEq(hook.protocolClaimable(poolId) - protocolQuoteBefore, c.protocolQuote, "protocol likewise");
    }

    function test_theLpShareKeepsCompoundingAcrossCollections() public {
        uint128 previous = _fullRangeLiquidity();

        for (uint256 i = 0; i < 3; i++) {
            _sell(MEASURED_SELL);
            _buyClearOfTheLadder(MEASURED_BUY);
            Collected memory c = _collectAndCapture();

            assertGt(c.liquidityAdded, 0, "each collection compounds");
            uint128 current = _fullRangeLiquidity();
            assertGt(current, previous, "so the position strictly grows");
            previous = current;
        }
    }

    // --- Scenario: An unpairable LP token remainder carries forward ---

    /// @dev The full-range position takes both currencies in the ratio spot implies, and a single
    /// collection's fees are generally one-sided. What cannot be paired is carried rather than swapped for
    /// (price impact) or donated (which would be re-split and taxed again on the next collection).
    function test_theUnpairedLpShareIsCarriedRatherThanLost() public {
        uint256 carriedBefore = hook.poolState(poolId).pendingLpToken;

        _sell(MEASURED_SELL);
        Collected memory c = _collectAndCapture();

        assertGt(c.lpToken, 0, "there was an LP token share to place");
        assertApproxEqRel(
            hook.poolState(poolId).pendingLpToken - carriedBefore,
            c.lpToken,
            1e12,
            "so essentially the whole LP share waits in custody"
        );
        uint256 carriedAfterSell = hook.poolState(poolId).pendingLpToken;

        // The other side arriving is what unlocks it.
        _buyClearOfTheLadder(MEASURED_BUY);
        Collected memory second = _collectAndCapture();

        assertGt(second.liquidityAdded, 0, "now it pairs");
        assertLt(hook.poolState(poolId).pendingLpToken, carriedAfterSell, "and the carried token share was drawn down");
    }

    // --- Scenario (revenue-claims): Fee creator share accrues ---

    function test_feeCreatorShareAccrues() public {
        _sell(MEASURED_SELL);
        _buyClearOfTheLadder(MEASURED_BUY);

        uint256 creatorEthBefore = creator.balance;
        uint256 claimableBefore = hook.creatorClaimable(poolId);

        Collected memory c = _collectAndCapture();

        assertGt(c.creatorQuote, 0, "there was a creator share to credit");
        assertEq(hook.creatorClaimable(poolId) - claimableBefore, c.creatorQuote, "credited in ETH");

        // Credited, never pushed: the collection cannot be made to fail by whoever holds the NFT.
        assertEq(creator.balance, creatorEthBefore, "nothing was transferred during collection");

        // And the credit really is claimable, by the current NFT holder.
        vm.prank(creator);
        uint256 paidEth = hook.claimCreator(poolId);

        assertEq(paidEth, claimableBefore + c.creatorQuote, "the whole ETH balance");
        assertEq(creator.balance - creatorEthBefore, paidEth, "paid out for real");
    }

    // --- Scenario (revenue-claims): Protocol shares accrue from every source ---

    /// @dev The fee source. The other two are asserted where they happen: graduation proceeds in
    /// {GraduationTest.test_protocolCanClaimAfterGraduation}, the harvest share in
    /// {MilestoneHarvestTest.test_sharesAreDistributedPerConfiguration}.
    function test_feeProtocolShareAccrues() public {
        _sell(MEASURED_SELL);
        _buyClearOfTheLadder(MEASURED_BUY);

        uint256 recipientEthBefore = PROTOCOL_RECIPIENT.balance;
        uint256 claimableBefore = hook.protocolClaimable(poolId);

        Collected memory c = _collectAndCapture();

        assertGt(c.protocolQuote, 0, "there was a protocol share to credit");
        assertEq(hook.protocolClaimable(poolId) - claimableBefore, c.protocolQuote, "credited in ETH");
        assertEq(PROTOCOL_RECIPIENT.balance, recipientEthBefore, "and never pushed");

        vm.prank(PROTOCOL_RECIPIENT);
        uint256 paidEth = hook.claimProtocol(poolId);

        assertEq(paidEth, claimableBefore + c.protocolQuote, "the whole ETH balance");
        assertEq(PROTOCOL_RECIPIENT.balance - recipientEthBefore, paidEth, "paid out for real");
    }

    // --- Scenario (revenue-claims): Token-denominated fees never accrue to a claimant ---

    /// @dev The twin of {test_tokenFeesAreNeverCreditedToARecipient}, which holds this fixture's own pool to
    /// the `swap-fees` routing rule. What `revenue-claims` adds is a quantifier — the ledgers stay put when
    /// token fees are collected "on any pool" — so this walks pools rather than a pool.
    ///
    /// Fee routing is fixed by the immutable template while the harvest split is per-launch (Decision 16),
    /// which makes the launch most able to leak token value to a creator the one whose creator share sits at
    /// its 70% cap: if any configured share reached the token side, that is where it would show. Checked
    /// here alongside the default split, and alongside a pool still on its bonding curve, where a seller
    /// pays a token fee that no claimant can reach for a different reason — it is never collected at all.
    function test_tokenDenominatedFeesNeverAccrueToAClaimant() public {
        _assertTokenFeesReachNoClaimant("default split");

        _relaunchGraduated(
            _split(
                Bounds.MAX_CREATOR_HARVEST_SHARE_WAD,
                Bounds.MIN_BUYBACK_HARVEST_SHARE_WAD,
                Bounds.MIN_PROTOCOL_HARVEST_SHARE_WAD
            )
        );
        _assertTokenFeesReachNoClaimant("creator share at its cap");

        // A pool still on its bonding curve. `fullRangeLiquidity` is zero until graduation seeds the
        // position, so collection is a no-op there: the token fee stays in the curve and becomes ladder
        // inventory when graduation burns it (`graduation` "Token inventory and curve token fees become
        // ladder inventory"). Either way it does not pass through a claimable balance.
        (poolId, key, token) = _launchDirect(_defaultConfig("Curvy", "CRV"));
        vm.deal(address(router), 100_000 ether);
        assertEq(uint8(hook.poolPhase(poolId)), uint8(Phase.BONDING_CURVE), "the third pool is still on its curve");

        _buy(SMALL_BUY);
        uint256 tokenGrowthBefore = _tokenFeeGrowth();
        _sell(token.balanceOf(address(router)) / 2);
        assertGt(_tokenFeeGrowth(), tokenGrowthBefore, "the sell really was charged a token fee");

        uint256 creatorOnCurve = hook.creatorClaimable(poolId);
        uint256 protocolOnCurve = hook.protocolClaimable(poolId);
        Collected memory onCurve = _collectAndCapture();

        assertFalse(onCurve.seen, "with no full-range position there is nothing to collect");
        assertEq(hook.creatorClaimable(poolId), creatorOnCurve, "so the creator's ledger cannot have moved");
        assertEq(hook.protocolClaimable(poolId), protocolOnCurve, "nor the protocol's");
    }

    /// @dev Sells into `poolId`, collects, and holds both ledgers still. `label` names the pool so a failure
    /// says which one broke the property.
    function _assertTokenFeesReachNoClaimant(string memory label) private {
        uint256 creatorQuoteBefore = hook.creatorClaimable(poolId);
        uint256 protocolQuoteBefore = hook.protocolClaimable(poolId);
        uint256 creatorTokensBefore = token.balanceOf(creator);
        uint256 recipientTokensBefore = token.balanceOf(PROTOCOL_RECIPIENT);

        _sell(MEASURED_SELL);
        Collected memory c = _collectAndCapture();

        assertGt(c.tokenFees, 0, string.concat("a real token fee accrued: ", label));
        assertEq(c.quoteFees, 0, string.concat("and nothing in quote, so no ledger has business moving: ", label));

        assertEq(hook.creatorClaimable(poolId), creatorQuoteBefore, string.concat("creator ledger unmoved: ", label));
        assertEq(hook.protocolClaimable(poolId), protocolQuoteBefore, string.concat("protocol ledger unmoved: ", label));
        assertEq(
            token.balanceOf(creator), creatorTokensBefore, string.concat("no token pushed to the creator: ", label)
        );
        assertEq(
            token.balanceOf(PROTOCOL_RECIPIENT),
            recipientTokensBefore,
            string.concat("none to the protocol either: ", label)
        );

        // The two pool-facing destinations account for all of it, which is the same claim from the other
        // side: there is no third place for a token fee to have gone.
        assertEq(c.diverted + c.lpToken, c.tokenFees, string.concat("fund plus pool is the whole of it: ", label));
    }

    /// @dev Relaunches under `split` and graduates, sweeping the graduation dust so the next measurement
    /// starts clean — the same two steps {GraduatedFeeFixture} takes.
    function _relaunchGraduated(HarvestSplit memory split) private {
        LaunchConfig memory config = _defaultConfig("Variant", "VAR");
        config.harvestSplit = split;
        (poolId, key, token) = _launchDirect(config);
        vm.deal(address(router), 100_000 ether);
        _graduate();
        _clearAccrual();
    }
}
