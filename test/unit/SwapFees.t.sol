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
import {MilestoneToken} from "../../src/MilestoneToken.sol";
import {Bounds, FEE_DENOMINATOR, Phase, PoolState, WAD} from "../../src/types/LaunchTypes.sol";
import {EconomicConfig} from "../../src/types/PayoutTypes.sol";

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
        uint256 creatorQuote;
        uint256 protocolQuote;
        uint256 diverted;
        uint256 tokensBurned;
        uint64 economicVersion;
    }

    function _collectedFromLogs(Vm.Log[] memory logs) internal pure returns (Collected memory c) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == MilestoneBase.FeesCollected.selector) {
                c.seen = true;
                c.caller = address(uint160(uint256(logs[i].topics[2])));
                (c.quoteFees, c.tokenFees) = abi.decode(logs[i].data, (uint256, uint256));
            } else if (logs[i].topics[0] == MilestoneBase.FeesRouted.selector) {
                c.routed = true;
                (c.creatorQuote, c.protocolQuote, c.diverted, c.tokensBurned, c.economicVersion) =
                    abi.decode(logs[i].data, (uint256, uint256, uint256, uint256, uint64));
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

        // The transition's dust buy leaves a small fee in the new position. Sweep it so every measurement
        // below starts from a clean position.
        _clearAccrual();
    }

    struct PoolContext {
        PoolId id;
        PoolKey key;
        MilestoneToken token;
    }

    struct AccountingSnapshot {
        uint256 creatorQuote;
        uint256 protocolQuote;
        uint256 milestoneFund;
        uint256 tokenSupply;
        uint128 liquidity;
    }

    function _currentPool() internal view returns (PoolContext memory pool) {
        pool = PoolContext({id: poolId, key: key, token: token});
    }

    function _usePool(PoolContext memory pool) internal {
        poolId = pool.id;
        key = pool.key;
        token = pool.token;
    }

    function _launchGraduatedPool(string memory name_, string memory symbol_)
        internal
        returns (PoolContext memory pool)
    {
        (PoolId id, PoolKey memory poolKey, MilestoneToken poolToken) = _launchDirect(_defaultConfig(name_, symbol_));
        pool = PoolContext({id: id, key: poolKey, token: poolToken});
        _usePool(pool);
        _graduate();
        _clearAccrual();
    }

    function _setEconomics(uint64 quoteCreatorShareWad, uint64 tokenMilestoneFundShareWad)
        internal
        returns (EconomicConfig memory next)
    {
        EconomicConfig memory current = hook.economicConfig();
        next = EconomicConfig({
            harvestServiceFeeWad: current.harvestServiceFeeWad,
            quoteCreatorShareWad: quoteCreatorShareWad,
            tokenMilestoneFundShareWad: tokenMilestoneFundShareWad,
            version: current.version + 1
        });
        bytes32 salt = keccak256(abi.encode("swap-fee-economics", next));
        vm.prank(PROTOCOL_ADMIN);
        controller.scheduleEconomicConfig(next, salt);
        controller.executeEconomicConfig(next, salt);
        assertEq(hook.economicConfig().version, next.version, "hook activated the governed version");
        assertEq(controller.economicConfig().version, next.version, "controller records the same version");
    }

    function _snapshot() internal view returns (AccountingSnapshot memory before_) {
        before_ = AccountingSnapshot({
            creatorQuote: hook.creatorClaimable(poolId),
            protocolQuote: hook.protocolClaimable(),
            milestoneFund: hook.poolState(poolId).milestoneFundAccrued,
            tokenSupply: token.totalSupply(),
            liquidity: _fullRangeLiquidity()
        });
    }

    function _assertQuoteCollection(Collected memory c, AccountingSnapshot memory before_, EconomicConfig memory config)
        internal
        view
    {
        uint256 expectedCreator = (c.quoteFees * config.quoteCreatorShareWad) / WAD;
        assertTrue(c.seen && c.routed, "a real collection was routed");
        assertGt(c.quoteFees, 0, "quote fees were collected");
        assertEq(c.tokenFees, 0, "the measurement was quote-only");
        assertEq(c.economicVersion, config.version, "the active version was sampled");
        assertEq(c.creatorQuote, expectedCreator, "creator received the configured floor share");
        assertEq(c.protocolQuote, c.quoteFees - expectedCreator, "protocol received the exact remainder");
        assertEq(hook.creatorClaimable(poolId) - before_.creatorQuote, c.creatorQuote, "creator ledger delta is exact");
        assertEq(hook.protocolClaimable() - before_.protocolQuote, c.protocolQuote, "protocol ledger delta is exact");
        assertEq(hook.poolState(poolId).milestoneFundAccrued, before_.milestoneFund, "quote cannot fund milestones");
        assertEq(token.totalSupply(), before_.tokenSupply, "quote cannot burn launch tokens");
        assertEq(_fullRangeLiquidity(), before_.liquidity, "quote collection cannot compound liquidity");
    }

    function _assertTokenCollection(Collected memory c, AccountingSnapshot memory before_, EconomicConfig memory config)
        internal
        view
    {
        uint256 expectedDiversion = (c.tokenFees * config.tokenMilestoneFundShareWad) / WAD;
        assertTrue(c.seen && c.routed, "a real collection was routed");
        assertGt(c.tokenFees, 0, "token fees were collected");
        assertEq(c.quoteFees, 0, "the measurement was token-only");
        assertEq(c.economicVersion, config.version, "the active version was sampled");
        assertEq(c.creatorQuote, 0, "token cannot reach the creator ledger");
        assertEq(c.protocolQuote, 0, "token cannot reach the protocol ledger");
        assertEq(c.diverted, expectedDiversion, "milestone fund received the configured floor share");
        assertEq(c.tokensBurned, c.tokenFees - expectedDiversion, "the exact token remainder burned");
        assertEq(hook.creatorClaimable(poolId), before_.creatorQuote, "creator ledger is unchanged");
        assertEq(hook.protocolClaimable(), before_.protocolQuote, "protocol ledger is unchanged");
        assertEq(
            hook.poolState(poolId).milestoneFundAccrued - before_.milestoneFund,
            c.diverted,
            "milestone-fund ledger delta is exact"
        );
        assertEq(before_.tokenSupply - token.totalSupply(), c.tokensBurned, "supply fell by the exact burn");
        assertEq(_fullRangeLiquidity(), before_.liquidity, "token collection cannot compound liquidity");
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
    // --- Scenario: One percent applies from genesis forever ---

    function test_theBaseFeeAppliesFromGenesis() public {
        // Before any trade at all, the pool is already set to the template's fee and the hook agrees.
        assertEq(_baseFeeOf(poolId), template.tradingFeeHundredthsBip, "the pool opens at the template's fee");
        assertEq(key.fee, template.tradingFeeHundredthsBip, "which is the literal fee carried in the pool key");
        assertEq(template.tradingFeeHundredthsBip, Bounds.TRADING_FEE_HUNDREDTHS_BIP, "the published constant");
        assertEq(template.tradingFeeHundredthsBip, 10_000, "which is 1%");

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
        assertApproxEqRel(
            firstFee, _feeOn(firstIn, template.tradingFeeHundredthsBip), 0.0005e18, "the first swap paid 1%"
        );

        // Identical on the next swap, and the stored fee is where it started.
        growthBefore = _quoteFeeGrowth();
        uint256 secondIn = _buyStoppingBelow(GENESIS_BUY, secondStop);
        assertGt(secondIn, 0, "the second buy really traded too");
        assertEq(_poolLiquidity(poolId), liquidity, "still the same single position");

        uint256 secondFee = _feeFromGrowth(growthBefore, liquidity);
        assertApproxEqRel(
            secondFee, _feeOn(secondIn, template.tradingFeeHundredthsBip), 0.0005e18, "and so did the next"
        );
        assertEq(_baseFeeOf(poolId), template.tradingFeeHundredthsBip, "trading does not move the base fee");
    }

    // --- Scenario: Time does not affect the fee ---

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
    // --- Scenario: Any address can collect ---

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

    // --- Scenario: Net locked position is preserved ---
    // --- Scenario (graduation): Other routing preserves existing liquidity ---

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
        assertEq(_fullRangeLiquidity(), liquidityBefore, "collection leaves locked liquidity unchanged");
        assertEq(hook.poolState(poolId).fullRangeLiquidity, liquidityBefore, "and the hook's record agrees");
    }

    function test_netLiquidityNeverChangesAcrossManyCollections() public {
        uint128 opening = _fullRangeLiquidity();

        for (uint256 i = 0; i < 4; i++) {
            _sell(MEASURED_SELL);
            _buyClearOfTheLadder(MEASURED_BUY);
            hook.collectFees(key);

            assertEq(_fullRangeLiquidity(), opening, "collection never compounds the position");
        }
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
        uint256 protocolQuote = hook.protocolClaimable();
        uint256 accrued = hook.poolState(poolId).milestoneFundAccrued;
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

        assertEq(_fullRangeLiquidity(), liquidity, "the position is unchanged");
        assertEq(hook.creatorClaimable(poolId), creatorQuote, "no ledger moved");
        assertEq(hook.protocolClaimable(), protocolQuote, "no ledger moved");
        assertEq(hook.poolState(poolId).milestoneFundAccrued, accrued, "the milestone fund did not grow");
        assertEq(HOOK_ADDR.balance, hookEth, "no value left the manager a second time");
        assertEq(token.balanceOf(HOOK_ADDR), hookTokens, "in either currency");
    }

    // --- Scenario: Zero-accrual collection is a no-op ---

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

    function test_tokenFeesAreRealisedThenFundedOrBurned() public {
        uint256 hookTokensBefore = token.balanceOf(HOOK_ADDR);

        _sell(MEASURED_SELL);
        Collected memory c = _collectAndCapture();

        assertGt(c.tokenFees, 0, "the sell paid a fee");
        assertEq(c.diverted + c.tokensBurned, c.tokenFees, "funding plus burn conserved it");
        assertEq(token.balanceOf(HOOK_ADDR) - hookTokensBefore, c.diverted, "only milestone funding remains");
    }

    function test_quoteFeesAreRealisedAsNativeEth() public {
        uint256 hookEthBefore = HOOK_ADDR.balance;

        _buyClearOfTheLadder(MEASURED_BUY);
        Collected memory c = _collectAndCapture();

        assertGt(c.quoteFees, 0, "the buy paid a fee");
        assertEq(HOOK_ADDR.balance - hookEthBefore, c.quoteFees, "and all quote arrived as native ETH");
    }
}

/// @notice Unit tests for the `swap-fees` "Fee routing waterfall" requirement.
///
/// @dev The waterfall has two destinations per currency and no third. Quote splits between the pool's
/// direct creator ledger and the single global protocol ledger; token either funds still-usable ladder
/// capacity or burns. Nothing compounds, nothing is carried for a later pairing, and no token reaches a
/// claimant — the LP share and its carry were removed with the rest of the compounding model, so what
/// these tests assert is an exact two-way partition rather than a remainder.
contract FeeWaterfallTest is GraduatedFeeFixture {
    // --- Scenario: Default quote split is 75 25 ---

    /// @dev The remainder is the protocol's *by subtraction*, not by a second percentage: 75% is computed
    /// and whatever is left over — division dust included — is the protocol's. Asserting both the floor
    /// and the exact complement is what distinguishes that from two independently rounded shares, which
    /// would leave a wei unaccounted at some inputs.
    function test_defaultQuoteSplitIs75_25() public {
        _buyClearOfTheLadder(MEASURED_BUY);
        Collected memory c = _collectAndCapture();

        assertGt(c.quoteFees, 0, "the buy paid its fee in ETH");
        assertEq(c.tokenFees, 0, "and not in token");
        assertEq(c.diverted, 0, "quote is never diverted, so the whole amount reaches the waterfall");

        uint256 expectedCreator = (c.quoteFees * Bounds.DEFAULT_QUOTE_CREATOR_SHARE_WAD) / WAD;
        assertEq(c.creatorQuote, expectedCreator, "75% to the creator");
        assertEq(c.protocolQuote, c.quoteFees - expectedCreator, "and the exact remainder to the protocol");
        assertEq(c.creatorQuote + c.protocolQuote, c.quoteFees, "which together is all of it");
    }

    function testFuzz_defaultQuoteSplitIs75_25(uint256 buyAmount) public {
        buyAmount = bound(buyAmount, 0.01 ether, 50 ether);

        _buyClearOfTheLadder(buyAmount);
        Collected memory c = _collectAndCapture();

        assertEq(
            c.creatorQuote,
            (c.quoteFees * Bounds.DEFAULT_QUOTE_CREATOR_SHARE_WAD) / WAD,
            "the creator floor holds at every size"
        );
        assertEq(c.creatorQuote + c.protocolQuote, c.quoteFees, "and the protocol takes the exact remainder");
    }

    // --- Scenario: Collection uses one configuration snapshot ---

    /// @dev One tuple is copied before any arithmetic, so both currencies in a single collection are routed
    /// by the same version. The event carries that version, which is what makes the claim checkable rather
    /// than merely intended: a routing that re-read economics between the quote and token halves could
    /// report only one of the two versions it used.
    function test_collectionUsesOneConfigurationSnapshot() public {
        _sell(MEASURED_SELL);
        _buyClearOfTheLadder(MEASURED_BUY);

        uint64 live = hook.economicConfig().version;
        Collected memory c = _collectAndCapture();

        assertTrue(c.routed, "the collection routed");
        assertGt(c.quoteFees, 0, "with a quote side");
        assertGt(c.tokenFees, 0, "and a token side, so both halves ran");
        assertEq(c.economicVersion, live, "both were routed under the version live at collection");

        // The same version governed each half's arithmetic, checkable against the tuple it names.
        EconomicConfig memory economics = hook.economicConfig();
        assertEq(
            c.creatorQuote, (c.quoteFees * economics.quoteCreatorShareWad) / WAD, "quote followed the named version"
        );
        assertEq(c.diverted + c.tokensBurned, c.tokenFees, "and the token side was partitioned under the same one");
    }

    // --- Scenario: Routed amounts conserve each currency ---

    function test_routedAmountsConserveEachCurrency() public {
        _sell(MEASURED_SELL);
        _buyClearOfTheLadder(MEASURED_BUY);
        Collected memory c = _collectAndCapture();

        assertGt(c.quoteFees, 0, "both sides accrued");
        assertGt(c.tokenFees, 0, "both sides accrued");

        assertEq(c.creatorQuote + c.protocolQuote, c.quoteFees, "the quote side is fully accounted for");
        assertEq(c.diverted + c.tokensBurned, c.tokenFees, "and the token side, diversion and burn together");
    }

    function testFuzz_routedAmountsConserveEachCurrency(uint256 sellAmount, uint256 buyAmount) public {
        sellAmount = bound(sellAmount, 1_000 ether, token.balanceOf(address(router)) / 2);
        buyAmount = bound(buyAmount, 0.01 ether, 50 ether);

        _sell(sellAmount);
        _buyClearOfTheLadder(buyAmount);
        Collected memory c = _collectAndCapture();

        assertEq(c.creatorQuote + c.protocolQuote, c.quoteFees, "quote side sums, at every size");
        assertEq(c.diverted + c.tokensBurned, c.tokenFees, "token side sums, at every size");
    }

    // --- Scenario (revenue-claims): Fee creator share accrues directly ---

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

    // --- Scenario (revenue-claims): Every protocol source accrues globally ---

    /// @dev The fee source. The protocol ledger is global rather than per-pool, so the assertion is on the
    /// single balance and the claim takes no pool argument; graduation proceeds and the harvest service fee
    /// are asserted where they happen.
    function test_feeProtocolShareAccrues() public {
        _sell(MEASURED_SELL);
        _buyClearOfTheLadder(MEASURED_BUY);

        uint256 recipientEthBefore = PROTOCOL_RECIPIENT.balance;
        uint256 claimableBefore = hook.protocolClaimable();

        Collected memory c = _collectAndCapture();

        assertGt(c.protocolQuote, 0, "there was a protocol share to credit");
        assertEq(hook.protocolClaimable() - claimableBefore, c.protocolQuote, "credited in ETH");
        assertEq(PROTOCOL_RECIPIENT.balance, recipientEthBefore, "and never pushed");

        vm.prank(PROTOCOL_RECIPIENT);
        uint256 paidEth = hook.claimProtocol();

        assertEq(paidEth, claimableBefore + c.protocolQuote, "the whole global ETH balance");
        assertEq(PROTOCOL_RECIPIENT.balance - recipientEthBefore, paidEth, "paid out for real");
    }

    // --- Scenario (revenue-claims): Token fees never accrue to a claimant ---

    /// @dev The quantified twin of the routing rule: token fees reach no claimant "on any pool". This walks
    /// two pools rather than one — this fixture's graduated pool, and a second pool still on its bonding
    /// curve, where a seller pays a token fee that no claimant can reach for a different reason: with no
    /// full-range position there is nothing to collect at all, and the fee becomes ladder inventory when
    /// graduation burns the curves.
    function test_tokenDenominatedFeesNeverAccrueToAClaimant() public {
        _assertTokenFeesReachNoClaimant("graduated pool");

        (poolId, key, token) = _launchDirect(_defaultConfig("Curvy", "CRV"));
        vm.deal(address(router), 100_000 ether);
        assertEq(uint8(hook.poolPhase(poolId)), uint8(Phase.BONDING_CURVE), "the second pool is still on its curve");

        _buy(SMALL_BUY);
        uint256 tokenGrowthBefore = _tokenFeeGrowth();
        _sell(token.balanceOf(address(router)) / 2);
        assertGt(_tokenFeeGrowth(), tokenGrowthBefore, "the sell really was charged a token fee");

        uint256 creatorOnCurve = hook.creatorClaimable(poolId);
        uint256 protocolOnCurve = hook.protocolClaimable();
        Collected memory onCurve = _collectAndCapture();

        assertFalse(onCurve.seen, "with no full-range position there is nothing to collect");
        assertEq(hook.creatorClaimable(poolId), creatorOnCurve, "so the creator's ledger cannot have moved");
        assertEq(hook.protocolClaimable(), protocolOnCurve, "nor the protocol's");
    }

    /// @dev Sells into `poolId`, collects, and holds every claimant ledger still. `label` names the pool so
    /// a failure says which one broke the property.
    function _assertTokenFeesReachNoClaimant(string memory label) private {
        uint256 creatorQuoteBefore = hook.creatorClaimable(poolId);
        uint256 protocolQuoteBefore = hook.protocolClaimable();
        uint256 potBefore = hook.payoutPot(poolId);
        uint256 creatorPathBefore = hook.creatorPathClaimable(poolId);
        uint256 creatorTokensBefore = token.balanceOf(creator);
        uint256 recipientTokensBefore = token.balanceOf(PROTOCOL_RECIPIENT);

        _sell(MEASURED_SELL);
        Collected memory c = _collectAndCapture();

        assertGt(c.tokenFees, 0, string.concat("a real token fee accrued: ", label));
        assertEq(c.quoteFees, 0, string.concat("and nothing in quote, so no ledger has business moving: ", label));

        assertEq(hook.creatorClaimable(poolId), creatorQuoteBefore, string.concat("creator ledger unmoved: ", label));
        assertEq(hook.protocolClaimable(), protocolQuoteBefore, string.concat("protocol ledger unmoved: ", label));
        assertEq(hook.payoutPot(poolId), potBefore, string.concat("the payout pot is untouched: ", label));
        assertEq(
            hook.creatorPathClaimable(poolId),
            creatorPathBefore,
            string.concat("and so is creator-path entitlement: ", label)
        );
        assertEq(
            token.balanceOf(creator), creatorTokensBefore, string.concat("no token pushed to the creator: ", label)
        );
        assertEq(
            token.balanceOf(PROTOCOL_RECIPIENT),
            recipientTokensBefore,
            string.concat("none to the protocol either: ", label)
        );

        // Funding and burning account for all of it, which is the same claim from the other side: there is
        // no third place for a token fee to have gone.
        assertEq(c.diverted + c.tokensBurned, c.tokenFees, string.concat("fund plus burn is the whole of it: ", label));
    }
}

/// @notice Literal evidence for governed, global, prospective fee routing and the absence of compounding.
contract GovernedFeeRoutingTest is GraduatedFeeFixture {
    function _collectQuote(EconomicConfig memory config) private returns (Collected memory c) {
        _buyClearOfTheLadder(MEASURED_BUY);
        AccountingSnapshot memory before_ = _snapshot();
        c = _collectAndCapture();
        _assertQuoteCollection(c, before_, config);
    }

    function _collectToken(EconomicConfig memory config) private returns (Collected memory c) {
        _sell(MEASURED_SELL);
        AccountingSnapshot memory before_ = _snapshot();
        c = _collectAndCapture();
        _assertTokenCollection(c, before_, config);
    }

    // --- Scenario: Active quote distribution applies globally ---

    function test_activeQuoteDistributionAppliesGlobally() public {
        PoolContext memory first = _currentPool();
        PoolContext memory second = _launchGraduatedPool("Second Quote", "SQUOTE");
        EconomicConfig memory config = _setEconomics(0.6e18, Bounds.DEFAULT_TOKEN_MILESTONE_FUND_SHARE_WAD);

        _usePool(first);
        Collected memory firstCollection = _collectQuote(config);
        _usePool(second);
        Collected memory secondCollection = _collectQuote(config);

        assertEq(firstCollection.economicVersion, config.version, "first pool used the global version");
        assertEq(secondCollection.economicVersion, config.version, "second pool used the global version");
    }

    // --- Scenario: Active token distribution applies globally ---

    function test_activeTokenDistributionAppliesGlobally() public {
        PoolContext memory first = _currentPool();
        PoolContext memory second = _launchGraduatedPool("Second Token", "STOKEN");
        EconomicConfig memory config = _setEconomics(Bounds.DEFAULT_QUOTE_CREATOR_SHARE_WAD, 0.35e18);

        _usePool(first);
        Collected memory firstCollection = _collectToken(config);
        _usePool(second);
        Collected memory secondCollection = _collectToken(config);

        assertEq(firstCollection.economicVersion, config.version, "first pool used the global version");
        assertEq(secondCollection.economicVersion, config.version, "second pool used the global version");
    }

    // --- Scenario: Collector cannot redirect value ---

    function test_collectorCannotRedirectValue() public {
        EconomicConfig memory config = _setEconomics(0.6e18, 0.35e18);
        _sell(MEASURED_SELL);
        _buyClearOfTheLadder(MEASURED_BUY);
        AccountingSnapshot memory before_ = _snapshot();
        uint256 callerEth = STRANGER.balance;
        uint256 callerToken = token.balanceOf(STRANGER);

        Collected memory c = _collectAs(STRANGER);
        uint256 expectedCreator = (c.quoteFees * config.quoteCreatorShareWad) / WAD;
        uint256 expectedDiversion = (c.tokenFees * config.tokenMilestoneFundShareWad) / WAD;

        assertEq(c.caller, STRANGER, "the third party really triggered collection");
        assertEq(c.economicVersion, config.version, "routing used the active version");
        assertEq(c.creatorQuote, expectedCreator, "only the creator destination received its share");
        assertEq(c.protocolQuote, c.quoteFees - expectedCreator, "only the protocol received the remainder");
        assertEq(c.diverted, expectedDiversion, "only the milestone fund retained its token share");
        assertEq(c.tokensBurned, c.tokenFees - expectedDiversion, "all remaining token burned");
        assertEq(hook.creatorClaimable(poolId) - before_.creatorQuote, c.creatorQuote, "creator ledger delta is exact");
        assertEq(hook.protocolClaimable() - before_.protocolQuote, c.protocolQuote, "protocol ledger delta is exact");
        assertEq(
            hook.poolState(poolId).milestoneFundAccrued - before_.milestoneFund,
            c.diverted,
            "milestone-fund delta is exact"
        );
        assertEq(STRANGER.balance, callerEth, "collector received no ETH");
        assertEq(token.balanceOf(STRANGER), callerToken, "collector received no token");
        assertEq(_fullRangeLiquidity(), before_.liquidity, "collector cannot redirect value into liquidity");
    }

    // --- Scenario: Prior accrual is not repartitioned ---

    function test_priorAccrualIsNotRepartitioned() public {
        EconomicConfig memory oldConfig = hook.economicConfig();
        Collected memory oldCollection = _collectQuote(oldConfig);
        uint256 creatorRecorded = hook.creatorClaimable(poolId);
        uint256 protocolRecorded = hook.protocolClaimable();

        EconomicConfig memory next = _setEconomics(0.55e18, 0.4e18);

        assertEq(oldCollection.economicVersion, oldConfig.version, "accrual records its original version");
        assertEq(hook.creatorClaimable(poolId), creatorRecorded, "recorded creator quantity is unchanged");
        assertEq(hook.protocolClaimable(), protocolRecorded, "recorded protocol quantity is unchanged");
        assertEq(hook.economicConfig().version, next.version, "only prospective policy changed");
    }

    // --- Scenario: Uncollected fees use collection-time configuration ---

    function test_uncollectedFeesUseCollectionTimeConfiguration() public {
        _buyClearOfTheLadder(MEASURED_BUY);
        EconomicConfig memory config = _setEconomics(0.55e18, 0.4e18);
        AccountingSnapshot memory before_ = _snapshot();

        Collected memory c = _collectAndCapture();

        _assertQuoteCollection(c, before_, config);
    }

    // --- Scenario: Valid update affects every pool prospectively ---

    function test_validUpdateAffectsEveryPoolProspectively() public {
        PoolContext memory first = _currentPool();
        Collected memory firstPrior = _collectQuote(hook.economicConfig());
        uint256 firstRecorded = hook.creatorClaimable(first.id);
        PoolContext memory second = _launchGraduatedPool("Prospective", "PROSP");
        Collected memory secondPrior = _collectQuote(hook.economicConfig());
        uint256 secondRecorded = hook.creatorClaimable(second.id);

        EconomicConfig memory next = _setEconomics(0.55e18, 0.4e18);
        assertEq(hook.creatorClaimable(first.id), firstRecorded, "first pool's prior quantity stayed fixed");
        assertEq(hook.creatorClaimable(second.id), secondRecorded, "second pool's prior quantity stayed fixed");

        _usePool(first);
        Collected memory firstAfter = _collectToken(next);
        _usePool(second);
        Collected memory secondAfter = _collectToken(next);

        assertEq(firstPrior.economicVersion + 1, firstAfter.economicVersion, "first pool advanced prospectively");
        assertEq(secondPrior.economicVersion + 1, secondAfter.economicVersion, "second pool advanced prospectively");
    }

    // --- Scenario (graduation): Quote fees do not compound ---

    function test_quoteFeesDoNotCompound() public {
        EconomicConfig memory config = hook.economicConfig();
        AccountingSnapshot memory before_ = _snapshot();
        _buyClearOfTheLadder(MEASURED_BUY);

        Collected memory c = _collectAndCapture();

        _assertQuoteCollection(c, before_, config);
        assertEq(c.diverted, 0, "quote produced no token-side carry");
        assertEq(c.tokensBurned, 0, "quote produced no token-side burn");
    }

    // --- Scenario (graduation): Token fees do not compound ---

    function test_tokenFeesDoNotCompound() public {
        EconomicConfig memory config = hook.economicConfig();
        AccountingSnapshot memory before_ = _snapshot();
        uint256 payoutBefore = hook.payoutPot(poolId);
        uint256 creatorPathBefore = hook.creatorPathClaimable(poolId);
        _sell(MEASURED_SELL);

        Collected memory c = _collectAndCapture();

        _assertTokenCollection(c, before_, config);
        assertEq(hook.payoutPot(poolId), payoutBefore, "token fees created no payout entitlement");
        assertEq(hook.creatorPathClaimable(poolId), creatorPathBefore, "token fees created no creator-path carry");
    }

    // --- Scenario: No LP fee carry exists ---

    function test_noLpFeeCarryExists() public {
        EconomicConfig memory config = hook.economicConfig();
        uint128 lockedLiquidity = _fullRangeLiquidity();

        Collected memory quoteCollection = _collectQuote(config);
        Collected memory tokenCollection = _collectToken(config);
        vm.recordLogs();
        (uint256 latentQuote, uint256 latentToken) = hook.collectFees(key);
        Vm.Log[] memory emptyLogs = vm.getRecordedLogs();

        assertGt(quoteCollection.quoteFees, 0, "the quote-only collection was real");
        assertGt(tokenCollection.tokenFees, 0, "the token-only collection was real");
        assertEq(_fullRangeLiquidity(), lockedLiquidity, "neither side was carried into LP liquidity");
        assertEq(latentQuote, 0, "no quote fee remained for later pairing");
        assertEq(latentToken, 0, "no token fee remained for later pairing");
        assertEq(emptyLogs.length, 0, "zero-accrual collection found no hidden LP carry");
    }
}
