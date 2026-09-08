// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {Position} from "v4-core/src/libraries/Position.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {MilestoneBase} from "../../src/MilestoneBase.sol";
import {MilestoneHook} from "../../src/MilestoneHook.sol";
import {MilestoneColdPaths} from "../../src/MilestoneColdPaths.sol";
import {MilestoneToken} from "../../src/MilestoneToken.sol";
import {RevenueNFT} from "../../src/RevenueNFT.sol";
import {LaunchSupport} from "../../src/LaunchSupport.sol";
import {CurveLib} from "../../src/libraries/CurveLib.sol";
import {LadderLib} from "../../src/libraries/LadderLib.sol";
import {LaunchConfigLib} from "../../src/libraries/LaunchConfigLib.sol";
import {Orientation} from "../../src/libraries/Orientation.sol";
import {Bounds, LaunchConfig, LiveBand, Phase, PoolState} from "../../src/types/LaunchTypes.sol";
import {TestRouter} from "./BondingCurve.t.sol";

/// @notice Unit tests for task group 8 — the milestone ladder's cursor and just-in-time deployment.
///
/// @dev These cover the `milestone-ladder` scenarios that need a live pool rather than pure geometry:
/// deployment on approach, single-active-band bookkeeping, jumped bands, and a single sweeping swap
/// filling a band that the same swap caused to be minted. Pure geometry is covered by `LadderLib.t.sol`.
contract MilestoneLadderTest is Test {
    using StateLibrary for IPoolManager;

    address internal constant HOOK_ADDR = address(uint160((uint160(0xBEEF) << 20) | 15040));
    address internal constant PROTOCOL_ADMIN = address(0xADD1);
    address internal constant PROTOCOL_RECIPIENT = address(0xFEE5);
    address internal constant CREATOR = address(0xC0FFEE);

    uint256 internal constant SUPPLY = 1_000_000_000 ether;

    PoolManager internal manager;
    MilestoneHook internal hook;
    RevenueNFT internal nft;
    LaunchSupport internal support;
    TestRouter internal router;

    PoolId internal poolId;
    PoolKey internal key;
    MilestoneToken internal token;

    int24 internal graduationLevel;

    function setUp() public {
        manager = new PoolManager(address(this));
        nft = new RevenueNFT();
        support = new LaunchSupport();

        MilestoneColdPaths coldPaths = new MilestoneColdPaths(IPoolManager(address(manager)), nft, support);

        deployCodeTo(
            "MilestoneHook.sol:MilestoneHook",
            abi.encode(IPoolManager(address(manager)), nft, support, coldPaths, PROTOCOL_ADMIN, PROTOCOL_RECIPIENT),
            HOOK_ADDR
        );
        hook = MilestoneHook(payable(HOOK_ADDR));
        nft.setMinter(HOOK_ADDR);
        router = new TestRouter(IPoolManager(address(manager)));

        MilestoneBase.LaunchParams memory p;
        p.name = "Milestone";
        p.symbol = "MILE";
        p.config = LaunchConfigLib.defaults(SUPPLY);
        p.curves = CurveLib.defaultCurves();

        vm.prank(CREATOR);
        (PoolId id, address tokenAddr, PoolKey memory k) = hook.launch(p);
        poolId = id;
        key = k;
        token = MilestoneToken(tokenAddr);

        vm.deal(address(router), 100_000_000 ether);
        // Past the anti-snipe window, so buying through the curve and the ladder is affordable.
        vm.warp(block.timestamp + 61);

        _graduate();
        graduationLevel = hook.poolState(poolId).graduationLevel;
    }

    // --- Helpers ---

    function _level() internal view returns (int24) {
        (, int24 tick,,) = IPoolManager(address(manager)).getSlot0(poolId);
        return Orientation.toLevel(tick);
    }

    /// @dev Buys through the curve fan to the far level and graduates in place.
    function _graduate() internal {
        int24 farLevel = hook.launchConfig(poolId).farLevel;
        router.swapToLimit(key, true, -10_000 ether, TickMath.getSqrtPriceAtTick(Orientation.toTick(farLevel)));
        hook.graduate(key);
        require(hook.poolPhase(poolId) == Phase.GRADUATED, "did not graduate");
    }

    /// @dev A price-limited buy that stops exactly at `target`. Unbounded buys are useless here: they
    /// drain every position and run spot to `MIN_SQRT_PRICE`, which tells us nothing about a ladder.
    function _buyToLevel(int24 target) internal {
        router.swapToLimit(key, true, -50_000_000 ether, TickMath.getSqrtPriceAtTick(Orientation.toTick(target)));
    }

    /// @dev A sell, to walk the price back down.
    function _sellToLevel(int24 target) internal {
        uint256 balance = token.balanceOf(address(router));
        router.swapToLimit(key, false, -int256(balance), TickMath.getSqrtPriceAtTick(Orientation.toTick(target)));
    }

    function _bandLevels(uint256 index) internal view returns (int24 lower, int24 upper) {
        LaunchConfig memory config = hook.launchConfig(poolId);
        bool exists;
        (lower, upper, exists) = LadderLib.bandLevels(config, graduationLevel, index);
        require(exists, "band out of range");
    }

    /// @dev Liquidity v4 actually holds for band `index`, read from the pool rather than from our state.
    function _bandLiquidity(uint256 index) internal view returns (uint128) {
        (int24 lower, int24 upper) = _bandLevels(index);
        (int24 tickLower, int24 tickUpper) = Orientation.levelRangeToTicks(lower, upper);
        return IPoolManager(address(manager)).getPositionLiquidity(
            poolId, Position.calculatePositionKey(HOOK_ADDR, tickLower, tickUpper, hook.bandSalt(uint32(index)))
        );
    }

    function _perBand() internal view returns (uint256) {
        LaunchConfig memory config = hook.launchConfig(poolId);
        return LadderLib.perBandInventory(config);
    }

    /// @dev Moves the price into band `index`'s deploy window without deploying it, so the *next* swap
    /// is the one that mints. Deployment is triggered by the pre-swap price, which is the whole point of
    /// the just-in-time design: the mint lands before the crossing it is meant to catch.
    function _approachBand(uint256 index) internal {
        LaunchConfig memory config = hook.launchConfig(poolId);
        (int24 lower,) = _bandLevels(index);
        _buyToLevel(lower - config.deployWindowLevels / 2);
        require(!hook.liveBand(poolId).deployed, "deployed too early");
    }

    /// @dev How many times `selector` was emitted in a recorded window.
    function _countLogs(Vm.Log[] memory logs, bytes32 selector) internal pure returns (uint256 n) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == selector) n++;
        }
    }

    // --- Scenario: A band is deployed just before the price reaches it ---

    function test_bandDeploysWhenTheApproachingSwapArrives() public {
        (int24 lower, int24 upper) = _bandLevels(0);

        _approachBand(0);
        assertEq(_bandLiquidity(0), 0, "nothing minted on approach alone");

        // The next swap's pre-swap price sits in the window, so this swap mints the band first.
        _buyToLevel(lower - 1);

        LiveBand memory band = hook.liveBand(poolId);
        assertTrue(band.deployed, "band 0 is live");
        assertEq(band.index, 0, "the first band");
        assertEq(band.levelLower, lower, "lower bound is the derived one");
        assertEq(band.levelUpper, upper, "upper bound is the derived one");
        assertGt(band.liquidity, 0, "carries liquidity");
        assertEq(_bandLiquidity(0), band.liquidity, "v4 holds exactly what we recorded");
    }

    function test_bandIsFundedFromTheLadderShare() public {
        uint256 perBand = _perBand();
        uint256 hookBalanceBefore = token.balanceOf(HOOK_ADDR);
        (int24 lower,) = _bandLevels(0);

        _approachBand(0);
        _buyToLevel(lower - 1);

        LiveBand memory band = hook.liveBand(poolId);
        PoolState memory state = hook.poolState(poolId);

        // Single-sided: the position is pure token, so the hook's balance falls by exactly what it staked.
        assertEq(hookBalanceBefore - token.balanceOf(HOOK_ADDR), band.tokenInventory, "inventory left custody");
        assertApproxEqRel(band.tokenInventory, perBand, 0.0001e18, "one band's share, minus mint dust");
        assertEq(state.ladderInventoryRemaining, _perBand() * 9, "nine core bands still unfunded");
        assertLt(state.carriedInventory, perBand / 1000, "only mint dust is carried");
    }

    function test_bandDeploysStrictlyBelowSpotSoItIsSellSideOnly() public {
        (int24 lower,) = _bandLevels(0);
        _approachBand(0);
        _buyToLevel(lower - 1);

        LiveBand memory band = hook.liveBand(poolId);
        // Level is -tick, so "band above spot in price" is "band below spot in tick".
        assertGt(band.levelLower, _level(), "the band sits above the current price");
    }

    // --- Scenario: Only one band is live at a time ---

    function test_secondBandIsNotDeployedWhileTheFirstIsLive() public {
        (int24 lower0, int24 upper0) = _bandLevels(0);
        _approachBand(0);
        _buyToLevel(lower0 - 1);
        assertEq(hook.liveBand(poolId).index, 0, "band 0 live");

        // Every buy runs the deployment check. None of them may mint a second band while band 0 is
        // unharvested, however many there are and wherever inside band 0 they land.
        _buyToLevel(lower0 + 100);
        _sellToLevel(lower0 - 40);
        _buyToLevel(upper0 - 10);
        _sellToLevel(lower0 + 20);
        _buyToLevel(upper0 - 5);

        assertEq(hook.liveBand(poolId).index, 0, "still band 0; the cursor did not jump");
        assertEq(hook.poolState(poolId).completedMilestones, 0, "and it is still unharvested");
        assertEq(_bandLiquidity(1), 0, "band 1 was never minted");

        // Band 1's own window sits above band 0's top, so reaching it means crossing band 0 — which
        // harvests it. Done in a single swap, there is one deployment check for the whole move and it runs
        // while band 0 is still live, so band 1 is not minted even though the price ends up in its window.
        (int24 lower1,) = _bandLevels(1);
        LaunchConfig memory config = hook.launchConfig(poolId);
        _buyToLevel(lower1 - config.deployWindowLevels / 2);

        assertEq(hook.poolState(poolId).completedMilestones, 1, "band 0 completed on the way up");
        assertFalse(hook.liveBand(poolId).deployed, "and nothing is live behind it");
        assertEq(_bandLiquidity(1), 0, "band 1 still was not minted by that swap");
    }

    function test_repeatedSwapsInsideTheWindowDeployOnlyOnce() public {
        (int24 lower,) = _bandLevels(0);
        _approachBand(0);
        _buyToLevel(lower - 1);

        uint128 liquidityAfterFirst = _bandLiquidity(0);
        uint256 inventoryAfterFirst = hook.liveBand(poolId).tokenInventory;

        // More swaps that never leave the window. Each target differs from the last, because v4 rejects
        // a limit the price already sits at.
        _sellToLevel(lower - 60);
        _buyToLevel(lower - 5);
        _sellToLevel(lower - 50);
        _buyToLevel(lower - 2);

        assertEq(_bandLiquidity(0), liquidityAfterFirst, "liquidity unchanged");
        assertEq(hook.liveBand(poolId).tokenInventory, inventoryAfterFirst, "inventory unchanged");
        assertEq(hook.poolState(poolId).bandCursor, 0, "cursor still on the live band");
    }

    // --- Scenario: Sells never deploy bands ---

    function test_sellsDoNotDeployBands() public {
        _approachBand(0);
        // In the window, but selling: the price is moving away from the band, so there is nothing to
        // prepare for and no reason to stake inventory.
        _sellToLevel(graduationLevel + 100);

        assertFalse(hook.liveBand(poolId).deployed, "no band on a sell");
        assertEq(_bandLiquidity(0), 0, "nothing minted");
    }

    // --- Scenario: Bands below spot are not deployed ---

    function test_priceBelowTheWindowDoesNotDeploy() public {
        LaunchConfig memory config = hook.launchConfig(poolId);
        (int24 lower,) = _bandLevels(0);

        // Just under the window's floor, and buying.
        _buyToLevel(lower - config.deployWindowLevels - 50);
        _buyToLevel(lower - config.deployWindowLevels - 10);

        assertFalse(hook.liveBand(poolId).deployed, "outside the window, so no mint");
        assertEq(_bandLiquidity(0), 0, "nothing minted");
    }

    // --- Scenario: A jumped band is skipped and its inventory carried ---

    function test_jumpedBandsAreSkippedAndTheirInventoryCarried() public {
        uint256 perBand = _perBand();
        (, int24 upper2) = _bandLevels(2);

        // One swap straight from graduation clear past band 2's top. Its pre-swap level is at
        // graduation, so nothing deploys; bands 0-2 are jumped, not filled.
        _buyToLevel(upper2 + 100);
        assertEq(_bandLiquidity(0), 0, "band 0 never existed");
        assertEq(_bandLiquidity(1), 0, "band 1 never existed");
        assertEq(_bandLiquidity(2), 0, "band 2 never existed");

        uint256 hookTokensBeforeSkips = token.balanceOf(HOOK_ADDR);

        // The next swap is where the cursor catches up.
        vm.recordLogs();
        _buyToLevel(upper2 + 120);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256 skips = _countLogs(logs, MilestoneBase.BandSkipped.selector);
        assertEq(skips, 3, "bands 0, 1 and 2 were all cleared by the price");

        PoolState memory state = hook.poolState(poolId);
        assertEq(state.bandCursor, 3, "cursor advanced past every cleared band");
        assertEq(state.carriedInventory, perBand * 3, "three shares carried, none lost");
        assertEq(state.ladderInventoryRemaining, perBand * 7, "seven core bands left");
        // The tokens never left the hook: skipping moves an accounting entry, not a balance.
        assertEq(token.balanceOf(HOOK_ADDR), hookTokensBeforeSkips, "custody unchanged by skips");
    }

    /// @dev A band the price has entered but not cleared is still the next one in line.
    function test_aBandThePriceIsInsideIsNotSkipped() public {
        (int24 lower0, int24 upper0) = _bandLevels(0);

        // Land between band 0's bounds, so its top was never crossed.
        _buyToLevel(lower0 + (upper0 - lower0) / 2);
        _buyToLevel(lower0 + (upper0 - lower0) / 2 + 10);

        PoolState memory state = hook.poolState(poolId);
        assertEq(state.bandCursor, 0, "band 0 is still next");
        assertEq(state.carriedInventory, 0, "nothing carried");
    }

    function test_carriedInventoryTopsUpTheNextBandUpToTheCap() public {
        uint256 perBand = _perBand();
        (, int24 upper2) = _bandLevels(2);
        (int24 lower3,) = _bandLevels(3);
        LaunchConfig memory config = hook.launchConfig(poolId);

        // Jump bands 0-2, then approach band 3 with three shares carried.
        _buyToLevel(upper2 + 100);
        _buyToLevel(lower3 - config.deployWindowLevels / 2);
        assertEq(hook.poolState(poolId).carriedInventory, perBand * 3, "three shares waiting");

        _buyToLevel(lower3 - 1);

        LiveBand memory band = hook.liveBand(poolId);
        assertEq(band.index, 3, "band 3 is the one that deploys");
        // Available is four shares (its own plus three carried) but a band takes at most the cap, so
        // the ladder cannot be concentrated into a single position by a long jump.
        assertApproxEqRel(
            band.tokenInventory, perBand * Bounds.BAND_INVENTORY_CAP_MULTIPLE, 0.0001e18, "capped at the multiple"
        );
        assertApproxEqRel(
            hook.poolState(poolId).carriedInventory,
            perBand * (4 - Bounds.BAND_INVENTORY_CAP_MULTIPLE),
            0.0001e18,
            "the excess stays carried"
        );
    }

    function test_skippingIsBoundedPerCallAndResumes() public {
        // A jump past several bands at once. The cursor steps over every one the price has cleared, and
        // the per-call bound is what keeps that cost off whichever swap happened to be large.
        uint256 perBand = _perBand();
        (, int24 upper5) = _bandLevels(5);
        _buyToLevel(upper5 + 100);
        _buyToLevel(upper5 + 110);

        PoolState memory state = hook.poolState(poolId);
        assertEq(state.bandCursor, 6, "cleared bands 0-5");
        assertEq(state.carriedInventory, perBand * 6, "six shares carried");
        assertLe(state.bandCursor, LadderLib.MAX_SKIPS_PER_CALL, "within the per-call bound");
    }

    /// @dev The core allocation is finite: once every core band has been cleared, further skips carry
    /// nothing, and the ladder's whole share sits in carry waiting for a fee-funded band.
    function test_skippingEveryCoreBandCarriesTheWholeLadderShareAndNoMore() public {
        LaunchConfig memory config = hook.launchConfig(poolId);
        (, int24 upperLast) = _bandLevels(config.bandCount - 1);

        _buyToLevel(upperLast + 100);
        _buyToLevel(upperLast + 110);

        PoolState memory state = hook.poolState(poolId);
        assertEq(state.bandCursor, config.bandCount, "cursor is past the last core band");
        assertEq(state.ladderInventoryRemaining, 0, "the core allocation is spent");
        assertEq(state.carriedInventory, _perBand() * config.bandCount, "and is all in carry");
        assertEq(state.feeFundedBandsCreated, 0, "fee-funded bands are group 11");
    }

    // --- Scenario: A single sweeping swap fills the band it triggered ---

    /// @dev Task 8.5. Mint, fill, and harvest all inside one swap, which is the ordering the just-in-time
    /// design exists to make work: `beforeSwap` mints the band the pre-swap price is approaching, the swap
    /// itself sweeps through it, and `afterSwap` settles it on the price that swap ended at.
    function test_oneSweepingSwapMintsAndFillsTheSameBand() public {
        (, int24 upper) = _bandLevels(0);
        _approachBand(0);

        uint256 routerTokensBefore = token.balanceOf(address(router));
        uint256 hookClaimBefore = manager.balanceOf(HOOK_ADDR, 0);

        // Pre-swap level is in the window, so this swap mints band 0 and then immediately sweeps
        // through it. That ordering is what makes a single large buy cross a milestone correctly.
        vm.recordLogs();
        _buyToLevel(upper + 200);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertGt(_level(), upper, "price cleared the band's top");
        // Both halves happened in this one transaction: the band was minted and then completed.
        assertEq(_countLogs(logs, MilestoneBase.BandDeployed.selector), 1, "band 0 was minted by this swap");
        assertEq(_countLogs(logs, MilestoneBase.MilestoneHarvested.selector), 1, "and harvested by it too");

        // The band's token inventory was sold into the sweep, and the ETH it fetched left the pool for the
        // hook's custody when the position was burned — as a claim, since the sweep has not settled yet.
        assertGt(token.balanceOf(address(router)) - routerTokensBefore, 0, "buyer got tokens");
        assertGt(manager.balanceOf(HOOK_ADDR, 0), hookClaimBefore, "proceeds reached hook custody");

        PoolState memory state = hook.poolState(poolId);
        assertEq(state.completedMilestones, 1, "one milestone complete");
        assertFalse(state.liveBand.deployed, "the band was retired");
        assertEq(state.bandCursor, 1, "and the cursor moved past it");
        assertEq(_bandLiquidity(0), 0, "the position was burned, not left in place");
    }

    function test_sweepPastSeveralBandsDeploysTheFirstAndCarriesTheRest() public {
        (, int24 upper2) = _bandLevels(2);
        _approachBand(0);

        // One swap from band 0's window clear past band 2.
        _buyToLevel(upper2 + 100);

        // Band 0 was minted by this swap's own `beforeSwap`, swept, and harvested by its `afterSwap`.
        // Bands 1 and 2 never existed: the ladder only ever has one band live, so the price passed empty
        // levels. Skipping them is `beforeSwap`'s work, and this swap's already ran.
        assertEq(_bandLiquidity(0), 0, "band 0 was deployed, filled, and burned");
        assertEq(_bandLiquidity(1), 0, "band 1 was jumped");
        assertEq(_bandLiquidity(2), 0, "band 2 was jumped");
        assertEq(hook.poolState(poolId).completedMilestones, 1, "the milestone it did reach completed");
        assertEq(hook.poolState(poolId).bandCursor, 1, "cursor sits on the first band that was jumped");

        // The next swap is the one that steps over them, and their inventory becomes carry rather than
        // being lost with the levels they were meant to sell into.
        //
        // Harvesting band 0 ran a buyback, which is itself a buy, so the price sits further above band 2
        // than this swap aimed for. Which bands are behind the price therefore follows from where it
        // actually is: derive that rather than hard-code a count the buyback's size could change, and step
        // up from the current level rather than from a target already passed.
        int24 level = _level();
        uint256 jumped;
        for (uint256 i = 1; i < 10; i++) {
            (, int24 top) = _bandLevels(i);
            if (level >= top) jumped++;
        }
        assertGe(jumped, 2, "bands 1 and 2 at least are behind the price");

        // Carry is already non-zero: completing band 0 folded its rounding residue in. What the skips
        // contribute is the delta, so assert on that rather than on a total that mixes the two.
        uint256 carryBefore = hook.poolState(poolId).carriedInventory;

        vm.recordLogs();
        _buyToLevel(level + 50);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(_countLogs(logs, MilestoneBase.BandSkipped.selector), jumped, "every jumped band was skipped");
        assertEq(hook.poolState(poolId).bandCursor, 1 + jumped, "the cursor stepped over all of them");
        assertEq(
            hook.poolState(poolId).carriedInventory - carryBefore,
            _perBand() * jumped,
            "and the whole share of each became carry"
        );
    }

    // --- Scenario: The hook never blocks a swap ---

    function test_swapsSucceedAtEveryPointAcrossTheLadder() public {
        LaunchConfig memory config = hook.launchConfig(poolId);
        (int24 lower,) = _bandLevels(0);

        // A walk across the whole first band in small steps: below the window, into it, through the
        // band, and back down. Every one of these is a swap the hook must not reject.
        int24[7] memory stops = [
            lower - config.deployWindowLevels - 100,
            lower - config.deployWindowLevels,
            lower - 100,
            lower,
            lower + config.bandWidthLevels / 2,
            lower + config.bandWidthLevels + 50,
            lower + config.bandWidthLevels + 400
        ];

        for (uint256 i = 0; i < stops.length; i++) {
            // Completing band 0 runs a buyback, which is itself a buy and moves the price up further, so a
            // later stop can already be behind us by the time we get to it. v4 rejects a limit at a price
            // already passed inside `Pool.swap`, before any hook is consulted, so issuing one would test
            // core rather than the hook. Skipping is the honest walk; the assertions below show it is not
            // a vacuous one.
            if (_level() >= stops[i]) continue;
            _buyToLevel(stops[i]);
        }
        assertGt(_level(), lower + config.bandWidthLevels, "the walk really did clear the band");
        assertEq(hook.poolState(poolId).completedMilestones, 1, "crossing it on the way completed it");

        _sellToLevel(graduationLevel + 200);
        assertLt(_level(), lower, "and the price walked back down below the band");

        assertEq(uint8(hook.poolPhase(poolId)), uint8(Phase.GRADUATED), "still graduated");
    }

    // --- Scenario: No bands exist immediately after graduation ---

    function test_noBandsExistImmediatelyAfterGraduation() public view {
        PoolState memory state = hook.poolState(poolId);

        assertFalse(state.liveBand.deployed, "nothing is live");
        assertEq(state.bandCursor, 0, "the cursor starts at the first band");
        assertEq(state.carriedInventory, 0, "nothing carried");
        assertEq(state.ladderInventoryRemaining, _perBand() * 10, "the whole ladder share is still unstaked");

        // The ladder is deployed just-in-time, so graduation itself mints nothing. Every band's levels
        // are already computable, but none of them hold liquidity.
        for (uint256 i = 0; i < 10; i++) {
            assertEq(_bandLiquidity(i), 0, "no band was pre-minted");
        }
    }

    function test_graduationDoesNotInstantlyCompleteAMilestone() public view {
        (int24 lower0,) = _bandLevels(0);
        LaunchConfig memory config = hook.launchConfig(poolId);

        // The first band sits a full spacing step above graduation, not at it, so graduating never
        // lands the price inside a milestone.
        assertEq(lower0, graduationLevel + config.bandLevelSpacing, "one full step above");
        assertGt(lower0 - config.deployWindowLevels, _level(), "and above the deploy window too");
    }

    // --- Scenario: The cursor only ever advances ---

    function test_cursorNeverMovesBackward() public {
        LaunchConfig memory config = hook.launchConfig(poolId);
        (, int24 upper1) = _bandLevels(1);
        (, int24 upper3) = _bandLevels(3);

        uint32 cursor = hook.poolState(poolId).bandCursor;

        // Up past two bands, back down below graduation's first step, up again past four, down again.
        int24[6] memory stops = [
            upper1 + 50,
            upper1 + 60,
            graduationLevel + config.bandLevelSpacing / 2,
            upper3 + 50,
            upper3 + 60,
            graduationLevel + 100
        ];

        for (uint256 i = 0; i < stops.length; i++) {
            if (stops[i] > _level()) {
                _buyToLevel(stops[i]);
            } else {
                _sellToLevel(stops[i]);
            }

            uint32 next = hook.poolState(poolId).bandCursor;
            assertGe(next, cursor, "the cursor never retreats");
            cursor = next;
        }

        // A retreating price does not un-skip: the inventory those bands would have held stays carried
        // and funds the bands ahead, which is what keeps the ladder monotonic in the face of volatility.
        assertGt(cursor, 0, "the walk did advance it");
        assertGt(hook.poolState(poolId).carriedInventory, 0, "and the skipped shares are still held");
    }

    // --- Salt disjointness: bands must never collide with curves or the full range ---

    function test_bandSaltsCannotCollideWithCurveOrFullRangeSalts() public view {
        // Curve salts are `(curveIndex << 128) | positionIndex` with `curveIndex < 8`, so their highest
        // set bit is 130. The full-range salt is a keccak whose top bit happens to be clear. Band salts
        // set bit 255, which neither can reach.
        assertEq(uint256(hook.FULL_RANGE_SALT()) >> 255, 0, "full-range salt leaves the tag bit clear");

        for (uint256 c = 0; c < CurveLib.MAX_CURVES; c++) {
            assertEq(uint256(hook.curvePositionSalt(c, type(uint128).max)) >> 255, 0, "curve salts too");
        }

        assertEq(uint256(hook.bandSalt(0)) >> 255, 1, "band salts set the tag bit");
        assertTrue(hook.bandSalt(0) != hook.bandSalt(1), "and stay distinct per index");
    }
}
