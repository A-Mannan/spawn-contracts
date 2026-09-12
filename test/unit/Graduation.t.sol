// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {MilestoneBase} from "../../src/MilestoneBase.sol";
import {Bounds, LaunchConfig, Phase, PoolState, WAD} from "../../src/types/LaunchTypes.sol";
import {EconomicConfig} from "../../src/types/PayoutTypes.sol";
import {HarnessLaunchpadTest} from "../HarnessFixtures.sol";

/// @notice Unit tests for task group 7 — the in-place graduation: what triggers it, how it splits what the
/// curve raised, and why the position it seeds can never leave.
///
/// @dev What graduation does to the *curve* — which positions burn, where their fees go — is
/// `CurveRetirement.t.sol`'s subject and is not restated here, except for the one conservation property
/// that spans both halves ("No value is stranded in retired positions"), which needs the split figures.
///
/// The harness fixture is used for a single test, "Lock survives ladder exhaustion": reaching that state
/// organically would need the price to rise by ~1.25^60, so the counters are written directly. Every other
/// test here drives the real path.
contract GraduationTest is HarnessLaunchpadTest {
    using PoolIdLibrary for PoolKey;

    /// @dev The far level is fixed at launch and never moves, so reading it once per test is safe.
    function _far() internal view returns (int24) {
        return hook.poolState(poolId).farLevel;
    }

    /// @dev The crossing buy on its own, stopping at the far level without the follow-up swap that
    /// `_graduate` uses to trigger the transition. Several tests need the pool parked in exactly this
    /// state: at the far level, still on the curve.
    function _crossToFarLevel() internal {
        _buyToLevel(2_000 ether, _far());
        require(_level() >= _far(), "could not reach the far level");
    }

    function _graduatedEvent()
        internal
        returns (uint256 proceeds, uint256 lpSeed, uint256 creatorQuote, uint256 protocolQuote)
    {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 at = _firstLogAt(logs, MilestoneBase.Graduated.selector);
        (, proceeds, lpSeed, creatorQuote, protocolQuote,,) =
            abi.decode(logs[at].data, (int24, uint256, uint256, uint256, uint256, uint128, uint128));
    }

    // --- Scenario: The crossing swap itself does not graduate ---

    /// @dev Decision 18. The crossing swap cannot graduate in its own `afterSwap`: v4 has not yet collected
    /// its input, so the manager is short by the swap in flight and the seeding would be settling against
    /// money that has not arrived. The pool therefore sits at the far level, still on the curve, until
    /// something else arrives.
    function test_theCrossingSwapItselfDoesNotGraduate() public {
        _crossToFarLevel();

        assertEq(uint8(hook.poolPhase(poolId)), uint8(Phase.BONDING_CURVE), "still on the curve");
        assertGe(_level(), _far(), "even though the far level has been reached");
        assertEq(hook.poolState(poolId).graduatedAt, 0, "nothing recorded");
        assertEq(_fullRangeLiquidity(), 0, "nothing seeded");
    }

    // --- Scenario: The first swap after the crossing auto-graduates ---

    function test_theFirstSwapAfterTheCrossingAutoGraduates() public {
        _crossToFarLevel();

        // A dust buy. Its only distinction is arriving after the crossing.
        _buy(1_000);

        assertEq(uint8(hook.poolPhase(poolId)), uint8(Phase.GRADUATED), "graduated in beforeSwap");
        assertGt(_fullRangeLiquidity(), 0, "the full-range position was seeded");
        assertEq(hook.poolState(poolId).graduatedAt, block.timestamp, "timestamp recorded");
    }

    /// @dev The second half of the scenario: the swap that triggered graduation still executes, and it
    /// executes against the graduated pool rather than being spent on the transition.
    function test_theTriggeringSwapExecutesAgainstTheGraduatedPool() public {
        _crossToFarLevel();

        uint256 before = token.balanceOf(address(router));
        _buy(1 ether);

        assertEq(uint8(hook.poolPhase(poolId)), uint8(Phase.GRADUATED), "graduated");
        assertGt(token.balanceOf(address(router)), before, "and the trade filled");
    }

    // --- Graduation gas is bounded by the template: derived, no scenario of its own ---

    /// @dev Graduation's only loop runs to `curvePositions`, an immutable template value, and touches just
    /// the positions the price actually woke. Nothing a launch chooses enters that bound, and supply is
    /// pinned protocol-wide, so two separately launched pools must graduate for the same cost.
    ///
    /// Asserted as a ratio rather than against a gas ceiling. The claim is that the cost is the template's
    /// and not the launch's; a hard number would only record today's opcode prices, and would have to be
    /// revised for reasons that have nothing to do with the property.
    function test_graduationGasIsBoundedByTheTemplate() public {
        (uint256 firstGas, uint256 firstBurns) = _graduationCost("First", "FST", SUPPLY);
        (uint256 secondGas, uint256 secondBurns) = _graduationCost("Second", "SND", SUPPLY);

        assertGt(firstBurns, 0, "curve positions really were burned");
        assertEq(secondBurns, firstBurns, "the same number either way, because the geometry is the template's");
        assertLe(firstBurns, template.curvePositions, "and never more than the loop bound");

        assertApproxEqRel(secondGas, firstGas, 0.1e18, "so graduation cost the same for every pool");
    }

    /// @dev Launches at `supply`, crosses the far level, and measures the swap that graduates it. The burn
    /// count is read before the swap: graduation consumes `curveDeployed`, so afterwards there is nothing
    /// left to count.
    function _graduationCost(string memory name_, string memory symbol_, uint256 supply)
        private
        returns (uint256 gasUsed, uint256 burns)
    {
        LaunchConfig memory config = _defaultConfig(name_, symbol_);
        config.totalSupply = supply;
        (poolId, key, token) = _launchDirect(config);
        vm.deal(address(router), 100_000 ether);

        _crossToFarLevel();
        burns = _popcount(hook.poolState(poolId).curveDeployed);

        uint256 before = gasleft();
        _buy(1_000);
        gasUsed = before - gasleft();

        assertEq(uint8(hook.poolPhase(poolId)), uint8(Phase.GRADUATED), "the measured swap is the one that graduated");
    }

    function _popcount(uint32 bits) private pure returns (uint256 n) {
        for (uint256 i = 0; i < 32; i++) {
            if (bits & (uint32(1) << uint8(i)) != 0) n += 1;
        }
    }

    // --- Scenario: Any address can trigger graduation ---

    function test_anyoneCanTriggerGraduation() public {
        _crossToFarLevel();

        vm.prank(STRANGER);
        hook.graduate(key);

        assertEq(uint8(hook.poolPhase(poolId)), uint8(Phase.GRADUATED), "a stranger graduated it");
    }

    /// @dev "On the same terms as the auto-trigger" is the part of the scenario worth pinning: the explicit
    /// call is not a second, weaker path. Two identical pools, one graduated each way, settle identically.
    function test_theExplicitCallSettlesOnTheSameTermsAsTheAutoTrigger() public {
        _crossToFarLevel();

        vm.recordLogs();
        vm.prank(STRANGER);
        hook.graduate(key);
        (uint256 proceeds, uint256 lpSeed, uint256 creatorQuote, uint256 protocolQuote) = _graduatedEvent();

        assertGt(proceeds, 0, "the curve raised something");
        assertEq(lpSeed + creatorQuote + protocolQuote, proceeds, "split exactly as the auto path does");
        assertGt(_fullRangeLiquidity(), 0, "and seeded the same position");
    }

    // --- Scenario: Graduation is rejected below the far tick ---

    function test_graduationRejectedBelowFarLevel() public {
        vm.expectRevert(abi.encodeWithSelector(MilestoneBase.FarLevelNotReached.selector, _level(), _far()));
        hook.graduate(key);

        assertEq(uint8(hook.poolPhase(poolId)), uint8(Phase.BONDING_CURVE), "still on the curve");
    }

    function test_graduationRejectedPartWayUpTheCurve() public {
        _buy(0.5 ether);
        assertLt(_level(), _far(), "not there yet");

        vm.expectRevert(abi.encodeWithSelector(MilestoneBase.FarLevelNotReached.selector, _level(), _far()));
        hook.graduate(key);
    }

    function test_graduationRejectedOnAnUnlaunchedPool() public {
        PoolKey memory foreign = key;
        foreign.tickSpacing = 60;

        vm.expectRevert();
        hook.graduate(foreign);
    }

    // --- Scenario: Tick condition is evaluated at call time ---

    /// @dev The condition is the live level, not a latch. Nothing is recorded when the level is crossed, so
    /// the identical call is rejected and then accepted with nothing changing in between but the price.
    /// Stopping one level short is what makes that visible: at `far - 1` the call reverts carrying the live
    /// level, and the only difference at the accepting call is where the price sits.
    function test_theConditionIsTheLiveLevelNotALatch() public {
        _buyToLevel(2_000 ether, _far() - 1);
        require(_level() < _far(), "overshot the far level");

        vm.expectRevert(abi.encodeWithSelector(MilestoneBase.FarLevelNotReached.selector, _level(), _far()));
        hook.graduate(key);

        _crossToFarLevel();
        hook.graduate(key);

        assertEq(uint8(hook.poolPhase(poolId)), uint8(Phase.GRADUATED), "the same call now succeeds");
    }

    /// @dev The spec's other case — a pool that reached the far level and has since fallen back, still on the
    /// curve — is not reachable, and this is what closes it off rather than an assumption. Price moves only
    /// through swaps, and the auto-graduation in `beforeSwap` (Decision 18) is direction-agnostic: it runs
    /// ahead of the trade and ahead of the `zeroForOne` branch, so the very sell that would walk the price
    /// back down graduates the pool on its way in and then executes against the graduated market. No ordering
    /// exists in which the level sits at or above far, a swap arrives, and the pool is still on the curve
    /// afterwards. See the port notes: the scenario's wording predates Decision 18.
    function test_theFallBackWindowIsUnreachableBecauseTheFallingSwapGraduatesFirst() public {
        _crossToFarLevel();
        assertEq(uint8(hook.poolPhase(poolId)), uint8(Phase.BONDING_CURVE), "the crossing swap left it on the curve");

        _sellAllToLevel(_far() - 5_000);

        assertLt(_level(), _far(), "the sell did walk the price back down");
        assertEq(uint8(hook.poolPhase(poolId)), uint8(Phase.GRADUATED), "but it graduated on its way in");
        assertGt(_fullRangeLiquidity(), 0, "against the seeded full-range position");
    }

    // --- Scenario: Graduation happens once ---

    function test_graduationHappensOnce() public {
        _graduate();

        uint128 liquidityAfterFirst = _fullRangeLiquidity();
        uint256 creatorAfterFirst = hook.creatorClaimable(poolId);

        vm.expectRevert(abi.encodeWithSelector(MilestoneBase.NotInBondingCurvePhase.selector, poolId, Phase.GRADUATED));
        hook.graduate(key);

        assertEq(_fullRangeLiquidity(), liquidityAfterFirst, "nothing re-minted");
        assertEq(hook.creatorClaimable(poolId), creatorAfterFirst, "nothing re-split");
    }

    /// @dev The auto path must be idempotent for the same reason, and it is the one that runs on every
    /// subsequent swap for the life of the pool.
    function test_laterSwapsDoNotReGraduate() public {
        _graduate();

        uint128 liquidityAfterFirst = _fullRangeLiquidity();
        uint256 creatorAfterFirst = hook.creatorClaimable(poolId);
        uint64 graduatedAt = hook.poolState(poolId).graduatedAt;

        _buy(1 ether);

        assertEq(hook.poolState(poolId).graduatedAt, graduatedAt, "the transition is not re-run");
        assertEq(_fullRangeLiquidity(), liquidityAfterFirst, "nothing re-minted");
        assertEq(hook.creatorClaimable(poolId), creatorAfterFirst, "and nothing re-split");
    }

    // --- Scenario: No value is stranded in retired positions ---

    /// @dev The conservation property that spans both halves of graduation. Pre-graduation the pool holds
    /// nothing but curve positions, so its whole quote balance is curve principal plus accrued curve fees —
    /// which makes "everything the burn released" a directly measurable quantity rather than an inference.
    /// Graduated explicitly rather than by the fixture's two-swap path, so the triggering swap's own input
    /// is not mixed into the balance being accounted for.
    function test_noValueIsStrandedInRetiredPositions() public {
        _crossToFarLevel();

        uint256 releasedByTheBurn = address(manager).balance;
        uint256 custodyBefore = HOOK_ADDR.balance;

        vm.recordLogs();
        hook.graduate(key);
        (uint256 proceeds, uint256 lpSeed, uint256 creatorQuote, uint256 protocolQuote) = _graduatedEvent();

        // Everything the curves held is what was split — nothing stayed behind in a retired position.
        assertLe(proceeds, releasedByTheBurn, "cannot split more than was released");
        assertApproxEqAbs(proceeds, releasedByTheBurn, 1e6, "and splits all but dust of it");

        // After graduation the pool backs exactly one position, so its balance is what the seed consumed.
        // Seeding settles through `modifyLiquidity`, which rounds what it charges *up*, so the pool can end
        // up holding a few wei more than the nominal seed figure the event reports. That is the rounding dust
        // the conservation requirements allow for, not an overspend, so the claim worth asserting is that the
        // pool's whole balance is the seed to within dust — an assertion a real overspend would still fail.
        uint256 seedConsumed = address(manager).balance;
        assertApproxEqAbs(seedConsumed, lpSeed, 1e6, "the pool holds the LP seed, up to rounding dust");
        assertEq(
            HOOK_ADDR.balance,
            custodyBefore + releasedByTheBurn - seedConsumed,
            "every wei released is either in custody or back in the pool"
        );
        assertGe(HOOK_ADDR.balance, creatorQuote + protocolQuote, "and custody covers what was credited");
    }

    // --- Scenario: Default split is applied ---

    function test_defaultSplitIsApplied() public {
        vm.recordLogs();
        _graduate();
        (uint256 proceeds, uint256 lpSeed, uint256 creatorQuote, uint256 protocolQuote) = _graduatedEvent();

        assertGt(proceeds, 0, "the curve raised something");
        assertApproxEqRel(lpSeed, (proceeds * template.lpSeedWad) / WAD, 0.001e18, "template LP seed share");
        assertApproxEqRel(
            creatorQuote, (proceeds * template.proceedsCreatorWad) / WAD, 0.001e18, "template creator share"
        );
        assertApproxEqRel(
            protocolQuote, (proceeds * template.proceedsProtocolWad) / WAD, 0.001e18, "template protocol share"
        );
    }

    // --- Scenario: Economic updates do not alter graduation split ---

    function test_economicUpdatesDoNotAlterGraduationSplit() public {
        EconomicConfig memory economics = EconomicConfig({
            harvestServiceFeeWad: 0.2e18,
            quoteCreatorShareWad: 0.9e18,
            tokenMilestoneFundShareWad: 0.5e18,
            version: 2
        });
        bytes32 salt = bytes32("graduation-economics");
        vm.prank(PROTOCOL_ADMIN);
        controller.scheduleEconomicConfig(economics, salt);
        controller.executeEconomicConfig(economics, salt);

        vm.recordLogs();
        _graduate();
        (uint256 proceeds, uint256 lpSeed, uint256 creatorQuote, uint256 protocolQuote) = _graduatedEvent();

        assertEq(lpSeed, (proceeds * 0.2e18) / WAD, "20% locked LP seed");
        assertEq(creatorQuote, (proceeds * 0.7e18) / WAD, "70% direct creator credit");
        assertEq(protocolQuote, proceeds - lpSeed - creatorQuote, "10% global protocol remainder");
    }

    // --- Scenario: Graduation allocations conserve proceeds ---

    function test_splitAllocationsSumToProceeds() public {
        vm.recordLogs();
        _graduate();
        (uint256 proceeds, uint256 lpSeed, uint256 creatorQuote, uint256 protocolQuote) = _graduatedEvent();

        assertEq(lpSeed + creatorQuote + protocolQuote, proceeds, "exact partition, no dust lost");
    }

    // --- Scenario: Creator proceeds are not pushed ---

    function test_creatorProceedsAreCreditedNotPushed() public {
        uint256 before = creator.balance;

        _graduate();

        assertEq(creator.balance, before, "nothing transferred during graduation");
        assertGt(hook.creatorClaimable(poolId), 0, "credited instead");
    }

    // --- Scenario: Bonding curve creator share accrues directly ---

    function test_creatorCanClaimAfterGraduation() public {
        uint256 before = creator.balance;
        _graduate();

        uint256 owed = hook.creatorClaimable(poolId);
        assertGt(owed, 0, "something accrued");

        vm.prank(creator);
        assertEq(hook.claimCreator(poolId), owed, "claimed in full");
        assertEq(creator.balance, before + owed, "paid in native ETH");
        assertEq(hook.creatorClaimable(poolId), 0, "ledger cleared");
    }

    // --- Scenario: Protocol graduation revenue accrues globally ---

    function test_protocolCanClaimAfterGraduation() public {
        uint256 beforeAccrual = hook.protocolClaimable();
        _graduate();

        uint256 owed = hook.protocolClaimable() - beforeAccrual;
        assertGt(owed, 0, "something accrued globally");

        uint256 before = PROTOCOL_RECIPIENT.balance;
        vm.prank(PROTOCOL_RECIPIENT);
        assertEq(hook.claimProtocol(), beforeAccrual + owed, "claimed the global ledger in full");
        assertEq(PROTOCOL_RECIPIENT.balance, before + beforeAccrual + owed, "paid in native ETH");
    }

    /// @dev Custody must actually hold what the ledger promises, or a claim would revert — and under
    /// Decision 13 part of it may be an ERC-6909 claim rather than raw ETH, which is exactly what a
    /// successful pull proves is redeemable.
    function test_custodyCoversTheAccruedClaims() public {
        _graduate();

        uint256 promised = hook.creatorClaimable(poolId) + hook.protocolClaimable();
        assertGt(promised, 0, "something is promised");

        uint256 creatorBefore = creator.balance;
        uint256 protocolBefore = PROTOCOL_RECIPIENT.balance;

        vm.prank(creator);
        hook.claimCreator(poolId);
        vm.prank(PROTOCOL_RECIPIENT);
        hook.claimProtocol();

        assertEq(
            (creator.balance - creatorBefore) + (PROTOCOL_RECIPIENT.balance - protocolBefore),
            promised,
            "custody covered every credited claim"
        );
    }

    // --- Scenario: Full-range position is created at the graduation price ---

    function test_fullRangePositionIsCreated() public {
        _crossToFarLevel();
        int24 priceAtCrossing = _level();

        hook.graduate(key);

        PoolState memory state = hook.poolState(poolId);
        assertGt(state.fullRangeLiquidity, 0, "liquidity recorded");
        assertEq(_fullRangeLiquidity(), state.fullRangeLiquidity, "pool agrees with recorded liquidity");

        // "At the graduation price": the level the transition recorded is the level it actually ran at, and
        // seeding did not move spot.
        assertEq(state.graduationLevel, priceAtCrossing, "seeded at the level graduation ran at");
        assertEq(_level(), priceAtCrossing, "and seeding did not move the price");
        assertGe(state.graduationLevel, _far(), "which is at or above the far level");

        // The template's bounded market-cap range — see Bounds.FULL_RANGE_TICK_LOWER/UPPER for the
        // $5,100-$150B derivation and why the bounds sit well inside TickMath's extremes.
        assertEq(state.fullRangeTickLower, Bounds.FULL_RANGE_TICK_LOWER, "spans the expensive bound");
        assertEq(state.fullRangeTickUpper, Bounds.FULL_RANGE_TICK_UPPER, "spans the cheap bound");
        assertGt(state.fullRangeTickLower, TickMath.minUsableTick(Bounds.POOL_TICK_SPACING), "inside the extreme");
        assertLt(state.fullRangeTickUpper, TickMath.maxUsableTick(Bounds.POOL_TICK_SPACING), "inside the extreme");
    }

    // --- Scenario: Graduation seeds both sides from original allocations ---

    function test_fullRangeIsFundedFromBothSides() public {
        _graduate();

        // After graduation the pool backs one full-range position, so it must hold both assets.
        assertGt(address(manager).balance, 0, "pool holds ETH");
        assertGt(token.balanceOf(address(manager)), 0, "pool holds token");
    }

    // --- Scenario: No caller can withdraw the full-range position ---

    function test_noCallerCanWithdrawTheFullRange() public {
        _graduate();

        PoolState memory state = hook.poolState(poolId);

        vm.expectRevert();
        router.removeLiquidity(key, state.fullRangeTickLower, state.fullRangeTickUpper, -1e18);

        vm.prank(creator);
        vm.expectRevert();
        router.removeLiquidity(key, state.fullRangeTickLower, state.fullRangeTickUpper, -1e18);

        vm.prank(PROTOCOL_ADMIN);
        vm.expectRevert();
        router.removeLiquidity(key, state.fullRangeTickLower, state.fullRangeTickUpper, -1e18);

        assertEq(_fullRangeLiquidity(), state.fullRangeLiquidity, "untouched");
    }

    // --- Scenario: Other routing preserves existing liquidity ---

    /// @dev Fee collection routes value without adding to or removing from the locked position.
    function test_feeCollectionPreservesNetLiquidity() public {
        _graduate();

        // Trade both ways so the position accrues fees in both currencies.
        _buy(10 ether);
        _sell(token.balanceOf(address(router)) / 2);

        uint128 before = _fullRangeLiquidity();
        assertGt(before, 0, "there is a position to preserve");

        hook.collectFees(key);

        assertEq(_fullRangeLiquidity(), before, "collection does not mutate locked liquidity");
    }

    // --- Scenario: Lock survives ladder exhaustion ---

    /// @dev The ladder-exhausted state is written directly rather than played out: reaching it organically
    /// needs sixty 1.25x market-cap steps, each fee-funded band paid for out of swap fees on the way. What
    /// the manufactured state tests is that the lock is not somehow a consequence of the ladder still having
    /// somewhere to go — see {MilestoneHookHarness.forceLadderCappedOut}.
    function test_lockSurvivesLadderExhaustion() public {
        _graduate();

        PoolState memory state = hook.poolState(poolId);
        harness.forceLadderCappedOut(poolId);

        assertEq(_fullRangeLiquidity(), state.fullRangeLiquidity, "the position is still in place");

        vm.expectRevert();
        router.removeLiquidity(key, state.fullRangeTickLower, state.fullRangeTickUpper, -1e18);

        assertEq(_fullRangeLiquidity(), state.fullRangeLiquidity, "and still cannot be removed");
    }

    // --- Scenario: Pool identity is unchanged ---

    function test_poolIdentityIsUnchanged() public {
        PoolKey memory before = key;
        address tokenBefore = hook.poolState(poolId).token;

        _graduate();

        assertEq(PoolId.unwrap(key.toId()), PoolId.unwrap(poolId), "same pool id");
        assertEq(address(key.hooks), HOOK_ADDR, "same hook");
        assertEq(address(before.hooks), address(key.hooks), "the key itself did not change");
        assertEq(hook.poolState(poolId).token, tokenBefore, "same token");
        assertEq(hook.poolState(poolId).token, address(token), "and it is the launched token");
    }

    // --- Scenario: Phase advances to graduated ---

    function test_graduationSucceedsAtFarLevel() public {
        _crossToFarLevel();

        hook.graduate(key);

        assertEq(uint8(hook.poolPhase(poolId)), uint8(Phase.GRADUATED), "graduated");
        assertGe(hook.poolState(poolId).graduationLevel, _far(), "level recorded");
        assertEq(hook.poolState(poolId).graduatedAt, block.timestamp, "timestamp recorded");
    }

    /// @dev "The milestone ladder is active": band geometry becomes addressable off the recorded graduation
    /// level, which is what the ladder deploys against from here on.
    function test_theLadderIsAddressableOnceGraduated() public {
        _graduate();

        (int24 lower, int24 upper, bool exists) = hook.bandLevels(poolId, 0);
        assertTrue(exists, "band 0 exists");
        assertEq(lower, hook.poolState(poolId).graduationLevel + template.bandFirstStepLevels, "one rung above");
        assertEq(upper - lower, template.bandWidthLevels, "of the template's width");
        assertGt(hook.poolState(poolId).ladderInventoryRemaining, 0, "with inventory to sell into it");
    }

    function test_tradingContinuesAfterGraduation() public {
        _graduate();

        // The full-range position is real liquidity, so the pool keeps working in both directions.
        uint256 tokenBefore = token.balanceOf(address(router));
        _buy(1 ether);
        assertGt(token.balanceOf(address(router)), tokenBefore, "buy filled after graduation");

        uint256 ethBefore = address(router).balance;
        _sell(token.balanceOf(address(router)) / 4);
        assertGt(address(router).balance, ethBefore, "sell filled after graduation");
    }

    // --- Scenario (token-launch): Graduated pools accept external liquidity ---
    // --- Scenario (token-launch): Protocol positions are not externally reachable ---

    /// @dev Post-graduation the pool is an ordinary market. The router adds and removes its own
    /// position; the protocol's full-range principal stays locked because no removal path exists and
    /// v4 keys positions to their owner.
    function test_externalLiquidityIsAcceptedAfterGraduation() public {
        _graduate();

        router.addLiquidity(key, -200_000, -100_000, 1e18);
        router.removeLiquidity(key, -200_000, -100_000, -1e18);
    }

    // --- Scenario: No migration entry point exists ---

    function test_noRemovalEntryPointExists() public {
        _graduate();
        bytes32 raw = PoolId.unwrap(poolId);

        string[5] memory sigs = [
            "removeFullRange(bytes32)",
            "withdrawLp(bytes32)",
            "unlockLp(bytes32)",
            "burnFullRange(bytes32)",
            "migrate(bytes32,address)"
        ];
        for (uint256 i = 0; i < sigs.length; i++) {
            (bool ok,) = HOOK_ADDR.call(abi.encodeWithSignature(sigs[i], raw));
            assertFalse(ok, "no removal or migration path");
        }
    }
}
