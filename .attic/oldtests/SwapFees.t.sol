// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {Position} from "v4-core/src/libraries/Position.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {MilestoneBase} from "../../src/MilestoneBase.sol";
import {MilestoneColdPaths} from "../../src/MilestoneColdPaths.sol";
import {MilestoneToken} from "../../src/MilestoneToken.sol";
import {RevenueNFT} from "../../src/RevenueNFT.sol";
import {LaunchSupport} from "../../src/LaunchSupport.sol";
import {CurveLib} from "../../src/libraries/CurveLib.sol";
import {LadderLib} from "../../src/libraries/LadderLib.sol";
import {LaunchConfigLib} from "../../src/libraries/LaunchConfigLib.sol";
import {Orientation} from "../../src/libraries/Orientation.sol";
import {Bounds, FEE_DENOMINATOR, LaunchConfig, LiveBand, Phase, PoolState} from "../../src/types/LaunchTypes.sol";
import {MilestoneHookHarness} from "../harness/MilestoneHookHarness.sol";
import {TestRouter} from "./BondingCurve.t.sol";

/// @notice Shared fixture for task group 10 — fee collection, the routing waterfall, the milestone fund,
/// and the two fee curves.
///
/// @dev Every suite here launches, graduates, and then trades against the full-range position, which is
/// the only place swap fees can accrue once the curve is burned. Two properties of that setup do the
/// heavy lifting for the arithmetic:
///
///  - With no band live, the full-range position is the only liquidity in range and the only initialised
///    ticks are its own bounds at +/-880000. A swap that consumes its whole exact input therefore never
///    reached a target price, so it was a single `SwapMath.computeSwapStep` and the fee it paid is exactly
///    the complement of `floor(amount * (1e6 - feePips) / 1e6)`.
///  - Fee measurements are taken on the *token* side. A harvest compounds its LP share by donating
///    `currency0` (design Decision 12), so quote fee growth on the full-range position is not purely
///    swap-derived; the token side only ever grows from swaps.
///
/// The harness subclass is used throughout rather than the production hook because one scenario
/// ("Diversion stops when the ladder is capped out") needs a state no unit test can trade its way into.
/// It overrides nothing on any path exercised here.
abstract contract SwapFeesFixture is Test {
    using StateLibrary for IPoolManager;

    address internal constant HOOK_ADDR = address(uint160((uint160(0xBEEF) << 20) | 15040));
    address internal constant PROTOCOL_ADMIN = address(0xADD1);
    address internal constant PROTOCOL_RECIPIENT = address(0xFEE5);
    address internal constant CREATOR = address(0xC0FFEE);

    /// @dev An address with no role anywhere in the protocol: not the creator, not the NFT holder, not the
    /// protocol admin or recipient. Used to show collection is genuinely permissionless.
    address internal constant STRANGER = address(0x57A6E);

    uint256 internal constant SUPPLY = 1_000_000_000 ether;

    /// @dev Sell size for measured swaps: about 1% of the full-range token allocation, small enough to
    /// keep the price well inside the position and large enough that the fee it pays dwarfs mint dust.
    uint256 internal constant MEASURED_SELL = 1_000_000 ether;
    /// @dev Buy size for quote-side fee generation, likewise a small fraction of the seeded quote.
    uint256 internal constant MEASURED_BUY = 100 ether;

    PoolManager internal manager;
    MilestoneHookHarness internal hook;
    RevenueNFT internal nft;
    LaunchSupport internal support;
    TestRouter internal router;

    PoolId internal poolId;
    PoolKey internal key;
    MilestoneToken internal token;

    int24 internal graduationLevel;

    /// @dev Absolute launch timestamp. Every warp in these tests is computed from this rather than from
    /// `block.timestamp`, because under `via_ir` two `block.timestamp + delta` expressions in the same
    /// call are common-subexpression-eliminated and chained relative warps silently collapse into one.
    uint256 internal launchTime;

    // --- Per-suite shaping ---

    /// @notice Hook for a suite to reshape the launch before it happens. Default: library defaults.
    function _configure(MilestoneBase.LaunchParams memory) internal virtual {}

    /// @notice Seconds after launch at which the graduating buy runs. Suites that want to graduate while
    /// the anti-snipe window is still open override this.
    function _graduateDelay() internal view virtual returns (uint256) {
        return 61;
    }

    function setUp() public virtual {
        manager = new PoolManager(address(this));
        nft = new RevenueNFT();
        support = new LaunchSupport();

        MilestoneColdPaths coldPaths = new MilestoneColdPaths(IPoolManager(address(manager)), nft, support);

        deployCodeTo(
            "MilestoneHookHarness.sol:MilestoneHookHarness",
            abi.encode(IPoolManager(address(manager)), nft, support, coldPaths, PROTOCOL_ADMIN, PROTOCOL_RECIPIENT),
            HOOK_ADDR
        );
        hook = MilestoneHookHarness(payable(HOOK_ADDR));
        nft.setMinter(HOOK_ADDR);
        router = new TestRouter(IPoolManager(address(manager)));

        MilestoneBase.LaunchParams memory p;
        p.name = "Milestone";
        p.symbol = "MILE";
        p.config = LaunchConfigLib.defaults(SUPPLY);
        p.curves = CurveLib.defaultCurves();
        _configure(p);

        vm.prank(CREATOR);
        (PoolId id, address tokenAddr, PoolKey memory k) = hook.launch(p);
        poolId = id;
        key = k;
        token = MilestoneToken(tokenAddr);
        launchTime = block.timestamp;

        vm.deal(address(router), 500_000_000 ether);
        vm.warp(launchTime + _graduateDelay());

        // Generously sized rather than exact: the price limit is what stops the buy, and a suite that
        // graduates inside the anti-snipe window pays a large fee for the same distance.
        int24 farLevel = hook.launchConfig(poolId).farLevel;
        router.swapToLimit(key, true, -2_000_000 ether, TickMath.getSqrtPriceAtTick(Orientation.toTick(farLevel)));
        hook.graduate(key);
        require(hook.poolPhase(poolId) == Phase.GRADUATED, "did not graduate");

        graduationLevel = hook.poolState(poolId).graduationLevel;
    }

    // --- Price and position ---

    function _level() internal view returns (int24) {
        (, int24 tick,,) = IPoolManager(address(manager)).getSlot0(poolId);
        return Orientation.toLevel(tick);
    }

    /// @dev The pool's live sqrt price. Used to assert that a path moved no price at all, which is the
    /// observable form of "no swap was performed" — adding liquidity does not move a pool.
    function _sqrtPrice() internal view returns (uint160 sqrtPriceX96) {
        (sqrtPriceX96,,,) = IPoolManager(address(manager)).getSlot0(poolId);
    }

    /// @dev The fee the pool will charge absent an override, as v4 stores it.
    function _storedLpFee() internal view returns (uint24 lpFee) {
        (,,, lpFee) = IPoolManager(address(manager)).getSlot0(poolId);
    }

    function _fullRangeLiquidity() internal view returns (uint128) {
        PoolState memory state = hook.poolState(poolId);
        return IPoolManager(address(manager)).getPositionLiquidity(
            poolId,
            Position.calculatePositionKey(
                HOOK_ADDR, state.fullRangeTickLower, state.fullRangeTickUpper, hook.FULL_RANGE_SALT()
            )
        );
    }

    function _bandLevels(uint256 index) internal view returns (int24 lower, int24 upper) {
        bool exists;
        (lower, upper, exists) = LadderLib.bandLevels(hook.launchConfig(poolId), graduationLevel, index);
        require(exists, "band out of range");
    }

    /// @dev Liquidity v4 actually holds for band `index`, read from the pool rather than from hook state, so
    /// a burn is observed where it happened rather than where it was recorded.
    function _bandLiquidity(uint256 index) internal view returns (uint128) {
        (int24 lower, int24 upper) = _bandLevels(index);
        (int24 tickLower, int24 tickUpper) = Orientation.levelRangeToTicks(lower, upper);
        return IPoolManager(address(manager)).getPositionLiquidity(
            poolId, Position.calculatePositionKey(HOOK_ADDR, tickLower, tickUpper, hook.bandSalt(uint32(index)))
        );
    }

    function _perBand() internal view returns (uint256) {
        return LadderLib.perBandInventory(hook.launchConfig(poolId));
    }

    /// @dev The highest level a buy may reach without waking the ladder, derived from the *current*
    /// cursor so it stays correct as milestones complete. One level below the next band's deploy window:
    /// deployment is decided on the pre-swap price, so a swap that both starts and ends strictly below
    /// the window cannot mint anything, and the fee tests stay free of ladder side effects.
    function _safeCeiling() internal view returns (int24) {
        LaunchConfig memory config = hook.launchConfig(poolId);
        (int24 lower,) = _bandLevels(hook.poolState(poolId).bandCursor);
        return lower - config.deployWindowLevels - 1;
    }

    // --- Trading ---

    function _buyToLevel(int24 target) internal {
        router.swapToLimit(key, true, -50_000_000 ether, TickMath.getSqrtPriceAtTick(Orientation.toTick(target)));
    }

    /// @dev A quote-side buy of exactly `quoteIn`, price-limited to stay clear of the ladder.
    function _buy(uint256 quoteIn) internal returns (BalanceDelta) {
        int24 ceiling = _safeCeiling();
        require(ceiling > _level(), "no headroom below the next band");
        return router.swapToLimit(key, true, -int256(quoteIn), TickMath.getSqrtPriceAtTick(Orientation.toTick(ceiling)));
    }

    /// @dev A token-side sell of exactly `tokenIn`. The limit is far enough below spot that it never
    /// binds for the sizes used here, which is what the full-consumption assertions confirm.
    function _sell(uint256 tokenIn) internal returns (BalanceDelta) {
        return router.swapToLimit(
            key, false, -int256(tokenIn), TickMath.getSqrtPriceAtTick(Orientation.toTick(_level() - 20_000))
        );
    }

    /// @dev Walks the price back down to `target` by selling the router's whole token balance into the
    /// price limit. Sells never deploy a band, so this moves the price without waking the ladder.
    function _sellToLevel(int24 target) internal {
        uint256 balance = token.balanceOf(address(router));
        router.swapToLimit(key, false, -int256(balance), TickMath.getSqrtPriceAtTick(Orientation.toTick(target)));
    }

    /// @dev Zeroes the position's accrued fee growth so the next measurement starts from a clean slate.
    function _clearAccrual() internal {
        hook.collectFees(key);
    }

    /// @dev The token-denominated fee a sell of `tokenIn` actually paid, read back out of the position.
    function _sellAndMeasureFee(uint256 tokenIn) internal returns (uint256 tokenFees) {
        _clearAccrual();
        BalanceDelta delta = _sell(tokenIn);
        assertEq(delta.amount1(), -int256(tokenIn), "the sell consumed its whole input, so it was one step");

        uint256 quoteFees;
        (quoteFees, tokenFees) = hook.collectFees(key);
        assertEq(quoteFees, 0, "a sell pays its fee in token only");
    }

    /// @dev What v4 charges on an exact-input swap of `amount` at `feePips`: the input available to the
    /// curve is `floor(amount * (1e6 - feePips) / 1e6)` and the fee is everything left over.
    function _feeOn(uint256 amount, uint24 feePips) internal pure returns (uint256) {
        return amount - (amount * (FEE_DENOMINATOR - feePips)) / FEE_DENOMINATOR;
    }

    /// @dev Deploys band `index` and leaves the price one level below it, ready to be crossed.
    ///
    /// Deployment is decided on the *pre-swap* level, so the mint has to be triggered by a buy that starts
    /// below the window. A previous harvest's buyback is an unbounded buy and routinely leaves the price
    /// already inside the next band's window, so the price is walked back down first when it is — with a
    /// sell, which never deploys anything.
    function _deployBand(uint256 index) internal returns (LiveBand memory band) {
        LaunchConfig memory config = hook.launchConfig(poolId);
        (int24 lower,) = _bandLevels(index);
        require(hook.poolState(poolId).bandCursor <= uint32(index), "band already behind the cursor");

        int24 windowFloor = lower - config.deployWindowLevels;
        if (_level() >= windowFloor) _sellToLevel(windowFloor - 100);

        _buyToLevel(lower - config.deployWindowLevels / 2);
        require(!hook.liveBand(poolId).deployed, "deployed too early");
        _buyToLevel(lower - 1);

        band = hook.liveBand(poolId);
        require(band.deployed && band.index == uint32(index), "band did not deploy");
    }

    /// @dev Deploys band `index` and crosses its top, harvesting it. Returns the logs of the crossing
    /// swap, which is where a fee step-down would be emitted.
    function _completeMilestone(uint256 index) internal returns (Vm.Log[] memory logs) {
        _deployBand(index);
        (, int24 upper) = _bandLevels(index);

        vm.recordLogs();
        _buyToLevel(upper + 200);
        logs = vm.getRecordedLogs();

        require(hook.poolState(poolId).completedMilestones == uint32(index) + 1, "milestone did not complete");
    }

    // --- Books ---

    /// @dev Every token the hook's own books say it is holding for someone.
    function _custodiedTokens() internal view returns (uint256) {
        PoolState memory state = hook.poolState(poolId);
        return state.ladderInventoryRemaining + state.carriedInventory + state.milestoneFundAccrued
            + state.pendingLpToken + hook.creatorClaimableTokens(poolId) + hook.protocolClaimableTokens(poolId)
            + (state.devBuyTotal - state.devBuyReleased);
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
        uint256 creatorToken;
        uint256 protocolQuote;
        uint256 protocolToken;
        uint256 diverted;
        uint128 liquidityAdded;
    }

    struct Stepped {
        bool seen;
        uint32 completedMilestones;
        uint24 previousFee;
        uint24 newFee;
    }

    function _collectedFromLogs(Vm.Log[] memory logs) internal pure returns (Collected memory c) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == MilestoneBase.FeesCollected.selector) {
                c.seen = true;
                c.caller = address(uint160(uint256(logs[i].topics[2])));
                (c.quoteFees, c.tokenFees) = abi.decode(logs[i].data, (uint256, uint256));
            } else if (logs[i].topics[0] == MilestoneBase.FeesRouted.selector) {
                c.routed = true;
                (
                    c.lpQuote,
                    c.lpToken,
                    c.creatorQuote,
                    c.creatorToken,
                    c.protocolQuote,
                    c.protocolToken,
                    c.diverted,
                    c.liquidityAdded
                ) = abi.decode(logs[i].data, (uint256, uint256, uint256, uint256, uint256, uint256, uint256, uint128));
            }
        }
    }

    function _steppedFromLogs(Vm.Log[] memory logs) internal pure returns (Stepped memory s) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == MilestoneBase.BaseFeeStepped.selector) {
                s.seen = true;
                (s.completedMilestones, s.previousFee, s.newFee) = abi.decode(logs[i].data, (uint32, uint24, uint24));
            }
        }
    }

    function _countLogs(Vm.Log[] memory logs, bytes32 selector) internal pure returns (uint256 n) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == selector) n++;
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

/// @notice Unit tests for task 10.1 — permissionless fee collection.
///
/// @dev design Decision 9 was revised during implementation: collection is a *zero-delta*
/// `modifyLiquidity` rather than the sliver burn and re-add the decision originally described.
/// `Position.update` computes fees owed from the position's existing liquidity and skips the principal
/// branch entirely when the delta is zero, so the position's liquidity, bounds and tick bitmap are never
/// touched. That turns "net liquidity is unreduced" from an outcome these tests have to check after the
/// fact into a property of the call itself — there was no sliver to put back. The tests below still check
/// it, because the requirement is about the observable position rather than about how it is realised.
contract FeeCollectionTest is SwapFeesFixture {
    // --- Scenario: Any address can trigger collection ---

    function test_anyAddressCanTriggerCollection() public {
        _sell(MEASURED_SELL);
        _buy(MEASURED_BUY);

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
        address[4] memory callers = [STRANGER, CREATOR, PROTOCOL_RECIPIENT, PROTOCOL_ADMIN];

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

    /// @dev The lopsided case, which is the common one: v4 charges the fee on the swap's input, so a
    /// stretch of one-directional trading accrues in one currency only and nothing can be paired at spot.
    /// Liquidity must be *unchanged* rather than merely restored.
    function test_netPositionIsPreservedWhenOnlyOneSideAccrued() public {
        uint128 liquidityBefore = _fullRangeLiquidity();

        _sell(MEASURED_SELL);
        (uint256 quoteFees, uint256 tokenFees) = hook.collectFees(key);

        assertEq(quoteFees, 0, "a sell pays its fee in token only");
        assertGt(tokenFees, 0, "and it did pay one");
        assertEq(_fullRangeLiquidity(), liquidityBefore, "liquidity is untouched, not reduced and rebuilt");
        assertEq(hook.poolState(poolId).fullRangeLiquidity, liquidityBefore, "and the hook's record agrees");
    }

    function test_netLiquidityNeverDecreasesAcrossManyCollections() public {
        uint128 previous = _fullRangeLiquidity();
        uint128 opening = previous;

        for (uint256 i = 0; i < 4; i++) {
            _sell(MEASURED_SELL);
            _buy(MEASURED_BUY);
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
        _buy(MEASURED_BUY);

        uint256 workingGasBefore = gasleft();
        hook.collectFees(key);
        uint256 workingGas = workingGasBefore - gasleft();

        uint128 liquidity = _fullRangeLiquidity();
        uint256 creatorQuote = hook.creatorClaimable(poolId);
        uint256 creatorToken = hook.creatorClaimableTokens(poolId);
        uint256 protocolQuote = hook.protocolClaimable(poolId);
        uint256 protocolToken = hook.protocolClaimableTokens(poolId);
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

        assertEq(_fullRangeLiquidity(), liquidity, "the position is unchanged in net terms");
        assertEq(hook.creatorClaimable(poolId), creatorQuote, "no ledger moved");
        assertEq(hook.creatorClaimableTokens(poolId), creatorToken, "no ledger moved");
        assertEq(hook.protocolClaimable(poolId), protocolQuote, "no ledger moved");
        assertEq(hook.protocolClaimableTokens(poolId), protocolToken, "no ledger moved");
        assertEq(hook.poolState(poolId).milestoneFundAccrued, accrued, "the milestone fund did not grow");
        assertEq(HOOK_ADDR.balance, hookEth, "and no value left the manager a second time");
        assertEq(token.balanceOf(HOOK_ADDR), hookTokens, "in either currency");
    }

    // --- Scenario: Collection with zero accrual is a no-op ---

    function test_collectionWithZeroAccrualIsANoOp() public {
        // Straight after graduation: the position exists and is in range, but has earned nothing yet.
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
    /// simply not collected here: they sit in the curve positions and fold into the graduation proceeds
    /// when those are burned, so this path has nothing to do until a full-range position exists.
    function test_collectionBeforeGraduationIsANoOp() public {
        MilestoneBase.LaunchParams memory p;
        p.name = "Curveling";
        p.symbol = "CURV";
        p.config = LaunchConfigLib.defaults(SUPPLY);
        p.curves = CurveLib.defaultCurves();

        vm.prank(CREATOR);
        (PoolId youngId,, PoolKey memory youngKey) = hook.launch(p);
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
        uint256 hookTokensBefore = token.balanceOf(HOOK_ADDR);

        _sell(MEASURED_SELL);
        (, uint256 tokenFees) = hook.collectFees(key);

        // With no quote side to pair against, none of the LP share could compound, so the whole token
        // amount left the manager for hook custody — where the ledgers and the milestone fund are paid from.
        assertEq(token.balanceOf(HOOK_ADDR) - hookTokensBefore, tokenFees, "collected fees became a real balance");
    }

    function test_quoteFeesAreRealisedAsNativeEth() public {
        uint256 hookEthBefore = HOOK_ADDR.balance;

        _buy(MEASURED_BUY);
        (uint256 quoteFees,) = hook.collectFees(key);

        assertGt(quoteFees, 0, "the buy paid a fee");
        assertEq(HOOK_ADDR.balance - hookEthBefore, quoteFees, "and it arrived as native ETH");
    }
}

/// @notice Unit tests for task 10.2 — the 60/30/10 routing waterfall over collected fees.
contract FeeWaterfallTest is SwapFeesFixture {
    // --- Scenario: Fees split three ways on collection ---

    function test_tokenFeesSplitThreeWays() public {
        _sell(MEASURED_SELL);
        Collected memory c = _collectAndCapture();

        assertApproxEqAbs(
            c.tokenFees, _feeOn(MEASURED_SELL, Bounds.DEFAULT_BASE_FEE), 1e9, "1% of the sell, up to growth dust"
        );
        assertEq(c.quoteFees, 0, "a sell pays in token only");

        // The milestone fund takes its share off the top; the waterfall runs over what is left.
        assertEq(c.diverted, (c.tokenFees * 2) / 10, "20% to the next band");
        uint256 waterfall = c.tokenFees - c.diverted;

        assertEq(c.creatorToken, (waterfall * 3) / 10, "30% to the creator");
        assertEq(c.protocolToken, waterfall / 10, "10% to the protocol");
        assertEq(c.lpToken, waterfall - c.creatorToken - c.protocolToken, "the LP takes the remainder");
        assertApproxEqAbs(c.lpToken, (waterfall * 6) / 10, 10, "which is 60%, plus the division dust");
    }

    function test_quoteFeesSplitThreeWays() public {
        _buy(MEASURED_BUY);
        Collected memory c = _collectAndCapture();

        assertGt(c.quoteFees, 0, "the buy paid its fee in ETH");
        assertEq(c.tokenFees, 0, "and not in token");
        assertEq(c.diverted, 0, "quote is never diverted, so the whole amount reaches the waterfall");

        assertEq(c.creatorQuote, (c.quoteFees * 3) / 10, "30% to the creator");
        assertEq(c.protocolQuote, c.quoteFees / 10, "10% to the protocol");
        assertEq(c.lpQuote, c.quoteFees - c.creatorQuote - c.protocolQuote, "the LP takes the remainder");
        assertApproxEqAbs(c.lpQuote, (c.quoteFees * 6) / 10, 10, "which is 60%, plus the division dust");
    }

    /// @dev One waterfall, not two. There is no branch on currency and no second set of proportions: the
    /// same split function runs over each side, against that side's own base.
    function test_bothCurrenciesUseTheSameProportions() public {
        _sell(MEASURED_SELL);
        _buy(MEASURED_BUY);
        Collected memory c = _collectAndCapture();

        assertGt(c.quoteFees, 0, "both sides accrued");
        assertGt(c.tokenFees, 0, "both sides accrued");

        // Diversion aside, each side is divided by identical arithmetic against its own base.
        uint256 tokenBase = c.tokenFees - c.diverted;
        assertEq(c.creatorToken, (tokenBase * 3) / 10, "30% of the token base");
        assertEq(c.creatorQuote, (c.quoteFees * 3) / 10, "30% of the quote base");
        assertEq(c.protocolToken, tokenBase / 10, "10% of the token base");
        assertEq(c.protocolQuote, c.quoteFees / 10, "10% of the quote base");
        assertEq(c.lpToken, tokenBase - c.creatorToken - c.protocolToken, "the LP takes the token remainder");
        assertEq(c.lpQuote, c.quoteFees - c.creatorQuote - c.protocolQuote, "and the quote remainder");
    }

    // --- Scenario: Routed amounts sum to collected fees ---

    function test_routedAmountsSumToCollectedFees() public {
        _sell(MEASURED_SELL);
        _buy(MEASURED_BUY);
        Collected memory c = _collectAndCapture();

        assertGt(c.quoteFees, 0, "both sides accrued");
        assertGt(c.tokenFees, 0, "both sides accrued");

        assertEq(c.lpQuote + c.creatorQuote + c.protocolQuote, c.quoteFees, "the quote side is fully accounted for");
        assertEq(
            c.lpToken + c.creatorToken + c.protocolToken + c.diverted,
            c.tokenFees,
            "and the token side, diversion included"
        );
    }

    function testFuzz_routedAmountsSumToCollectedFees(uint256 sellAmount, uint256 buyAmount) public {
        sellAmount = bound(sellAmount, 1_000 ether, 20_000_000 ether);
        buyAmount = bound(buyAmount, 0.01 ether, 50 ether);

        _sell(sellAmount);
        _buy(buyAmount);
        Collected memory c = _collectAndCapture();

        assertEq(c.lpQuote + c.creatorQuote + c.protocolQuote, c.quoteFees, "quote side sums, at every size");
        assertEq(
            c.lpToken + c.creatorToken + c.protocolToken + c.diverted, c.tokenFees, "token side sums, at every size"
        );
    }

    // --- Scenario: The LP share compounds ---

    function test_theLpShareCompoundsIntoTheFullRangePosition() public {
        _sell(MEASURED_SELL);
        _buy(MEASURED_BUY);

        uint128 liquidityBefore = _fullRangeLiquidity();
        uint256 creatorQuoteBefore = hook.creatorClaimable(poolId);
        uint256 creatorTokenBefore = hook.creatorClaimableTokens(poolId);
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
        assertEq(hook.creatorClaimableTokens(poolId) - creatorTokenBefore, c.creatorToken, "in the token ledger too");
        assertEq(hook.protocolClaimable(poolId) - protocolQuoteBefore, c.protocolQuote, "protocol likewise");
    }

    function test_theLpShareKeepsCompoundingAcrossCollections() public {
        uint128 previous = _fullRangeLiquidity();

        for (uint256 i = 0; i < 3; i++) {
            _sell(MEASURED_SELL);
            _buy(MEASURED_BUY);
            Collected memory c = _collectAndCapture();

            assertGt(c.liquidityAdded, 0, "each collection compounds");
            uint128 current = _fullRangeLiquidity();
            assertGt(current, previous, "so the position strictly grows");
            previous = current;
        }
    }

    /// @dev The full-range position takes both currencies in the ratio spot implies, and a single
    /// collection's fees are generally one-sided. What cannot be paired is carried rather than swapped for
    /// (price impact) or donated (which would be re-split and taxed again on the next collection).
    function test_theUnpairedLpShareIsCarriedRatherThanLost() public {
        assertEq(hook.poolState(poolId).pendingLpToken, 0, "nothing carried yet");

        _sell(MEASURED_SELL);
        Collected memory c = _collectAndCapture();

        assertEq(c.liquidityAdded, 0, "one-sided fees cannot be paired at spot");
        assertEq(hook.poolState(poolId).pendingLpToken, c.lpToken, "so the whole LP share waits in custody");

        // The other side arriving is what unlocks it.
        _buy(MEASURED_BUY);
        Collected memory second = _collectAndCapture();

        assertGt(second.liquidityAdded, 0, "now it pairs");
        assertLt(hook.poolState(poolId).pendingLpToken, c.lpToken, "and the carried token share was drawn down");
    }

    // --- Scenario (revenue-claims): Fee creator share accrues ---

    function test_feeCreatorShareAccrues() public {
        _sell(MEASURED_SELL);
        _buy(MEASURED_BUY);

        uint256 creatorEthBefore = CREATOR.balance;
        uint256 creatorTokensBefore = token.balanceOf(CREATOR);
        uint256 claimableBefore = hook.creatorClaimable(poolId);
        uint256 claimableTokensBefore = hook.creatorClaimableTokens(poolId);

        Collected memory c = _collectAndCapture();

        assertGt(c.creatorQuote, 0, "there was a creator share to credit");
        assertGt(c.creatorToken, 0, "in both currencies");
        assertEq(hook.creatorClaimable(poolId) - claimableBefore, c.creatorQuote, "credited in ETH");
        assertEq(hook.creatorClaimableTokens(poolId) - claimableTokensBefore, c.creatorToken, "and in token");

        // Credited, never pushed: the collection cannot be made to fail by whoever holds the NFT.
        assertEq(CREATOR.balance, creatorEthBefore, "nothing was transferred during collection");
        assertEq(token.balanceOf(CREATOR), creatorTokensBefore, "in either currency");

        // And the credit really is claimable, by the current NFT holder, in both ledgers.
        vm.prank(CREATOR);
        uint256 paidEth = hook.claimCreator(poolId);
        vm.prank(CREATOR);
        uint256 paidTokens = hook.claimCreatorTokens(poolId);

        assertEq(paidEth, claimableBefore + c.creatorQuote, "the whole ETH balance");
        assertEq(paidTokens, claimableTokensBefore + c.creatorToken, "and the whole token balance");
        assertEq(CREATOR.balance - creatorEthBefore, paidEth, "paid out for real");
        assertEq(token.balanceOf(CREATOR) - creatorTokensBefore, paidTokens, "in both currencies");
    }

    function test_feeProtocolShareAccrues() public {
        _sell(MEASURED_SELL);
        _buy(MEASURED_BUY);

        uint256 recipientEthBefore = PROTOCOL_RECIPIENT.balance;
        uint256 claimableBefore = hook.protocolClaimable(poolId);
        uint256 claimableTokensBefore = hook.protocolClaimableTokens(poolId);

        Collected memory c = _collectAndCapture();

        assertEq(hook.protocolClaimable(poolId) - claimableBefore, c.protocolQuote, "credited in ETH");
        assertEq(hook.protocolClaimableTokens(poolId) - claimableTokensBefore, c.protocolToken, "and in token");
        assertEq(PROTOCOL_RECIPIENT.balance, recipientEthBefore, "and never pushed");

        vm.prank(PROTOCOL_RECIPIENT);
        uint256 paidEth = hook.claimProtocol(poolId);
        vm.prank(PROTOCOL_RECIPIENT);
        uint256 paidTokens = hook.claimProtocolTokens(poolId);

        assertEq(paidEth, claimableBefore + c.protocolQuote, "the whole ETH balance");
        assertEq(paidTokens, claimableTokensBefore + c.protocolToken, "and the whole token balance");
    }

    /// @dev The two ledgers are never summed. A pool that traded both ways owes the creator ETH *and*
    /// token, and each has its own balance, its own claim, and its own event — so a collection that accrues
    /// in one currency leaves the other exactly where it was.
    function test_theTwoLedgersAreIndependent() public {
        _sell(MEASURED_SELL);
        Collected memory first = _collectAndCapture();

        assertGt(first.creatorToken, 0, "the sell moved the token ledger");
        assertEq(first.creatorQuote, 0, "and not the quote ledger");

        uint256 quoteBefore = hook.creatorClaimable(poolId);
        uint256 tokenBefore = hook.creatorClaimableTokens(poolId);
        assertEq(tokenBefore, first.creatorToken, "which now holds the whole token accrual");

        _buy(MEASURED_BUY);
        Collected memory second = _collectAndCapture();

        assertGt(second.creatorQuote, 0, "the buy moved the quote ledger");
        assertEq(second.creatorToken, 0, "with no token accrual in that collection at all");
        assertEq(hook.creatorClaimable(poolId) - quoteBefore, second.creatorQuote, "each ledger moves on its own");
        assertEq(hook.creatorClaimableTokens(poolId), tokenBefore, "and the other stays exactly put");
    }
}

/// @notice Task 10.2's windfall case: fees earned while the anti-snipe fee is still punitive.
///
/// @dev Graduates ten seconds into the sixty-second window, which is the only way a full-range position
/// can exist while the decay is still running — before graduation there is no position for the waterfall
/// to collect from.
contract AntiSnipeWindfallTest is SwapFeesFixture {
    function _graduateDelay() internal pure override returns (uint256) {
        return 10;
    }

    // --- Scenario: Anti-snipe windfall follows the same waterfall ---

    function test_antiSnipeWindfallFollowsTheSameWaterfall() public {
        uint32 window = hook.launchConfig(poolId).antiSnipeWindowSeconds;
        assertLt(block.timestamp - launchTime, window, "the window is still open");

        _sell(MEASURED_SELL);
        Collected memory c = _collectAndCapture();

        // A windfall by any measure: the snipe fee is nearly two orders of magnitude above the 1% base.
        assertGt(c.tokenFees, _feeOn(MEASURED_SELL, Bounds.DEFAULT_BASE_FEE) * 50, "charged at the snipe rate");

        // ... and routed with no special-case accounting whatsoever.
        _assertStandardSplit(c);
    }

    /// @dev The same split, before and after the window closes. Only the size of the take changes.
    function test_theWaterfallIsIdenticalInsideAndOutsideTheWindow() public {
        _sell(MEASURED_SELL);
        Collected memory inside = _collectAndCapture();

        vm.warp(launchTime + hook.launchConfig(poolId).antiSnipeWindowSeconds + 1);
        _sell(MEASURED_SELL);
        Collected memory outside = _collectAndCapture();

        assertGt(inside.tokenFees, outside.tokenFees * 50, "the window's take is far larger");

        // Only the size differs: both collections are divided by exactly the same arithmetic.
        _assertStandardSplit(inside);
        _assertStandardSplit(outside);
    }

    /// @dev The 20%-then-60/30/10 division of a token-side collection, asserted against its own total.
    function _assertStandardSplit(Collected memory c) private pure {
        assertGt(c.tokenFees, 0, "there was something to split");
        assertEq(c.diverted, (c.tokenFees * 2) / 10, "20% to the milestone fund");

        uint256 waterfall = c.tokenFees - c.diverted;
        assertEq(c.creatorToken, (waterfall * 3) / 10, "30% to the creator");
        assertEq(c.protocolToken, waterfall / 10, "10% to the protocol");
        assertEq(c.lpToken, waterfall - c.creatorToken - c.protocolToken, "the LP takes the remainder");
        assertEq(
            c.lpToken + c.creatorToken + c.protocolToken + c.diverted, c.tokenFees, "and every wei is accounted for"
        );
    }
}
