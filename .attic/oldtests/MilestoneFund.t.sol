// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {MilestoneBase} from "../../src/MilestoneBase.sol";
import {CurveLib} from "../../src/libraries/CurveLib.sol";
import {LadderLib} from "../../src/libraries/LadderLib.sol";
import {LaunchConfigLib} from "../../src/libraries/LaunchConfigLib.sol";
import {Bounds, LiveBand, PoolState, WAD} from "../../src/types/LaunchTypes.sol";
import {SwapFeesFixture} from "./SwapFees.t.sol";

/// @notice Unit tests for task 10.3 — diversion of token-denominated fees into the next band's inventory.
///
/// @dev The diversion is the one place the fee waterfall and the ladder meet. It runs *before* the split,
/// on the token side only, and it moves nothing: the tokens are already in hook custody by the time the
/// fund is credited, so a band grows without any swap and without touching the price.
contract MilestoneFundDiversionTest is SwapFeesFixture {
    // --- Scenario: Sell-side fees fund the next band ---

    function test_sellSideFeesFundTheNextBand() public {
        assertEq(hook.poolState(poolId).milestoneFundAccrued, 0, "nothing accrued yet");

        _sell(MEASURED_SELL);
        Collected memory c = _collectAndCapture();

        uint64 share = hook.launchConfig(poolId).milestoneFundShareWad;
        assertEq(share, Bounds.MAX_MILESTONE_FUND_SHARE_WAD, "the documented default is the 20% cap");
        assertGt(c.tokenFees, 0, "the sell paid in token");
        assertEq(c.diverted, (c.tokenFees * share) / WAD, "the configured share was diverted");
        assertEq(hook.poolState(poolId).milestoneFundAccrued, c.diverted, "and is held for the next band");

        // The remainder — and only the remainder — went through the waterfall.
        assertEq(c.creatorToken + c.protocolToken + c.lpToken, c.tokenFees - c.diverted, "the rest flowed on");
    }

    function test_accrualAccumulatesUntilABandDrawsOnIt() public {
        uint256 accrued;

        for (uint256 i = 0; i < 3; i++) {
            _sell(MEASURED_SELL);
            Collected memory c = _collectAndCapture();
            accrued += c.diverted;

            assertEq(hook.poolState(poolId).milestoneFundAccrued, accrued, "the fund only grows");
        }

        assertGt(accrued, 0, "and it really did grow");

        // Deploying the band is what spends it.
        LiveBand memory band = _deployBand(0);
        assertGt(band.tokenInventory, _perBand(), "the fund went into the band");
        assertEq(hook.poolState(poolId).milestoneFundAccrued, 0, "and the fund is empty again");
    }

    // --- Scenario: Quote-denominated fees are never diverted ---

    function test_quoteFeesAreNeverDiverted() public {
        _buy(MEASURED_BUY);
        Collected memory c = _collectAndCapture();

        assertGt(c.quoteFees, 0, "the buy paid a fee");
        assertEq(c.tokenFees, 0, "in quote only");
        assertEq(c.diverted, 0, "so nothing was diverted");
        assertEq(hook.poolState(poolId).milestoneFundAccrued, 0, "and the fund is untouched");
        assertEq(c.creatorQuote + c.protocolQuote + c.lpQuote, c.quoteFees, "the whole amount flowed through");
    }

    /// @dev A band's inventory is token offered for sale, so quote could only fund one by buying token —
    /// which "no swap performed and no price impact" rules out. A collection carrying both currencies
    /// therefore measures the diversion against the token side alone.
    function test_onlyTheTokenSideIsDivertedInAMixedCollection() public {
        _sell(MEASURED_SELL);
        _buy(MEASURED_BUY);
        Collected memory c = _collectAndCapture();

        assertGt(c.quoteFees, 0, "both sides accrued");
        assertGt(c.tokenFees, 0, "both sides accrued");
        assertEq(c.diverted, (c.tokenFees * 2) / 10, "20% of the token side");
        assertLt(c.diverted, (c.tokenFees * 2) / 10 + (c.quoteFees * 2) / 10, "and not a wei of the quote side");
        assertEq(c.lpQuote + c.creatorQuote + c.protocolQuote, c.quoteFees, "quote routed in full");
    }

    // --- Scenario: Diversion requires no swap ---

    function test_diversionPerformsNoSwapAndMovesNoPrice() public {
        _sell(MEASURED_SELL);

        uint160 priceBefore = _sqrtPrice();
        int24 levelBefore = _level();
        uint256 supplyBefore = token.totalSupply();

        vm.recordLogs();
        hook.collectFees(key);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(_countLogs(logs, IPoolManager.Swap.selector), 0, "no swap was performed");
        assertEq(_sqrtPrice(), priceBefore, "and the price did not move");
        assertEq(_level(), levelBefore, "at all");
        assertEq(token.totalSupply(), supplyBefore, "nor was anything bought and burned");
        assertGt(hook.poolState(poolId).milestoneFundAccrued, 0, "yet the fund accrued");
    }

    /// @dev Where the accrued tokens come from: the hook's own realised fee balance, not the pool.
    function test_accruedInventoryIsAlreadyInHookCustody() public {
        _sell(MEASURED_SELL);

        uint256 hookTokensBefore = token.balanceOf(HOOK_ADDR);
        Collected memory c = _collectAndCapture();

        assertEq(token.balanceOf(HOOK_ADDR) - hookTokensBefore, c.tokenFees, "the fees became a real balance");
        assertLe(hook.poolState(poolId).milestoneFundAccrued, token.balanceOf(HOOK_ADDR), "which fully backs the fund");
    }

    // --- Scenario: Diversion stops when the ladder is capped out ---

    function test_diversionStopsWhenTheLadderIsCappedOut() public {
        // Establish that diversion *was* happening, so the change below is attributable to the cap.
        _sell(MEASURED_SELL);
        _clearAccrual();
        uint256 accruedBefore = hook.poolState(poolId).milestoneFundAccrued;
        assertGt(accruedBefore, 0, "the fund was accruing before the ladder ended");

        // Every core band retired and the fee-funded extension exhausted: there is no next band to fund.
        hook.forceLadderCappedOut(poolId);

        _sell(MEASURED_SELL);
        Collected memory c = _collectAndCapture();

        assertGt(c.tokenFees, 0, "token fees still arrive");
        assertEq(c.diverted, 0, "but nothing is diverted");
        assertEq(hook.poolState(poolId).milestoneFundAccrued, accruedBefore, "so the fund does not grow");
        assertEq(
            c.creatorToken + c.protocolToken + c.lpToken,
            c.tokenFees,
            "and the whole amount flows through the waterfall instead"
        );
    }

    // --- Scenario: Diversion never exceeds the cap ---

    function test_aMilestoneFundShareAboveTheCapIsRejectedAtLaunch() public {
        MilestoneBase.LaunchParams memory p = _freshLaunchParams();
        p.config.milestoneFundShareWad = Bounds.MAX_MILESTONE_FUND_SHARE_WAD + 1;

        vm.expectRevert(
            abi.encodeWithSelector(
                LaunchConfigLib.MilestoneFundShareAboveCap.selector, Bounds.MAX_MILESTONE_FUND_SHARE_WAD + 1
            )
        );
        vm.prank(CREATOR);
        hook.launch(p);
    }

    function test_aMilestoneFundShareExactlyAtTheCapIsAccepted() public {
        MilestoneBase.LaunchParams memory p = _freshLaunchParams();
        p.config.milestoneFundShareWad = Bounds.MAX_MILESTONE_FUND_SHARE_WAD;

        vm.prank(CREATOR);
        (PoolId id,,) = hook.launch(p);

        assertEq(
            hook.launchConfig(id).milestoneFundShareWad,
            Bounds.MAX_MILESTONE_FUND_SHARE_WAD,
            "accepted exactly on the bound"
        );
    }

    /// @dev And at runtime the diverted amount never exceeds the cap's fraction of token fees, whatever
    /// the size of the collection.
    function testFuzz_divertedNeverExceedsTheCap(uint256 sellAmount) public {
        sellAmount = bound(sellAmount, 1_000 ether, 20_000_000 ether);

        _sell(sellAmount);
        Collected memory c = _collectAndCapture();

        assertLe(
            c.diverted * WAD,
            c.tokenFees * Bounds.MAX_MILESTONE_FUND_SHARE_WAD,
            "never above 20% of the token fees collected"
        );
        assertLe(c.diverted, c.tokenFees, "and obviously never more than was collected");
    }

    function _freshLaunchParams() private pure returns (MilestoneBase.LaunchParams memory p) {
        p.name = "Another";
        p.symbol = "ANOT";
        p.config = LaunchConfigLib.defaults(SUPPLY);
        p.curves = CurveLib.defaultCurves();
    }
}

/// @notice Unit tests for task 10.4 — how a band's inventory is sized at deployment.
///
/// @dev Configured with a deliberately tiny ladder share, so that fee-derived accrual is a large multiple
/// of one band rather than a rounding error against it. Nothing about the mechanism changes with the
/// share; what changes is whether the cap and the overflow are reachable inside a unit test at all. At the
/// documented default — 65% of a billion tokens over ten bands — a band is 65,000,000 tokens while a
/// 1% fee on the largest sell the pool can absorb diverts a few hundred thousand, so the cap is thousands
/// of collections away. Here a band is 100,000 tokens and one large sell overshoots it.
contract BandInventorySizingTest is SwapFeesFixture {
    function _configure(MilestoneBase.LaunchParams memory p) internal pure override {
        // 0.03% of supply across three bands: 100,000 tokens each. The rest of the supply moves to the
        // curve, so the pool still graduates normally and the router still ends up holding most of it.
        p.config.curveSupplyShareWad = 0.8997e18;
        p.config.ladderSupplyShareWad = 0.0003e18;
        p.config.fullRangeSupplyShareWad = 0.1e18;
        p.config.bandCount = 3;
    }

    function test_theFixtureLeavesAccrualRoomToMatter() public view {
        assertEq(_perBand(), 100_000 ether, "one band is 100,000 tokens");
        assertEq(hook.launchConfig(poolId).bandCount, 3, "across three of them");
        assertEq(hook.poolState(poolId).ladderInventoryRemaining, 300_000 ether, "with the whole share unstaked");
    }

    // --- Scenario: Accrued milestone-fund tokens enlarge the band ---

    function test_accruedMilestoneFundTokensEnlargeTheBand() public {
        _sell(1_000_000 ether);
        Collected memory c = _collectAndCapture();

        uint256 accrued = hook.poolState(poolId).milestoneFundAccrued;
        uint256 perBand = _perBand();

        assertEq(accrued, c.diverted, "the fund holds what was diverted");
        assertGt(accrued, 0, "and it is not trivial");
        assertLt(perBand + accrued, perBand * Bounds.BAND_INVENTORY_CAP_MULTIPLE, "still below the cap");

        LiveBand memory band = _deployBand(0);
        PoolState memory state = hook.poolState(poolId);

        assertGt(band.tokenInventory, perBand, "the band is larger than its configured share alone");
        // Exact rather than approximate: the configured share plus the accrual, less only the dust the
        // liquidity conversion floors away — and that dust is carried forward, not lost.
        assertEq(band.tokenInventory + state.carriedInventory, perBand + accrued, "share plus accrual, to the wei");
        assertEq(state.milestoneFundAccrued, 0, "the fund was consumed by the deployment");
        assertEq(state.ladderInventoryRemaining, perBand * 2, "and the band's own share came out of the ladder");
    }

    // --- Scenario: Inventory is capped at twice the configured share ---
    // --- Scenario: Overflow carries to the next band ---

    function test_inventoryIsCappedAtTwiceTheConfiguredShare() public {
        _sell(100_000_000 ether);
        _clearAccrual();

        uint256 accrued = hook.poolState(poolId).milestoneFundAccrued;
        uint256 perBand = _perBand();
        uint256 cap = perBand * Bounds.BAND_INVENTORY_CAP_MULTIPLE;

        assertGt(perBand + accrued, cap, "more is available than a single band may take");

        LiveBand memory band = _deployBand(0);
        PoolState memory state = hook.poolState(poolId);

        assertLe(band.tokenInventory, cap, "never above the cap");
        assertApproxEqAbs(band.tokenInventory, cap, 1e9, "and deployed at exactly it, less mint dust");
        // Capped, not truncated: what the cap held back is carried, and the two still sum to what was
        // available. A run of accrual cannot concentrate the ladder into one position, nor lose the excess.
        assertEq(band.tokenInventory + state.carriedInventory, perBand + accrued, "nothing was discarded");
        assertApproxEqAbs(state.carriedInventory, perBand + accrued - cap, 1e9, "the excess became carry");
        assertGt(state.carriedInventory, 0, "and there really was an excess");
    }

    function test_theCarriedOverflowFundsTheNextBand() public {
        _sell(100_000_000 ether);
        _clearAccrual();

        _deployBand(0);
        assertGt(hook.poolState(poolId).carriedInventory, 0, "band 0 was capped and left something behind");

        // Cross band 0's top so the cursor moves on.
        (, int24 upper0) = _bandLevels(0);
        _buyToLevel(upper0 + 200);
        assertEq(hook.poolState(poolId).completedMilestones, 1, "band 0 completed");

        uint256 carried = hook.poolState(poolId).carriedInventory;
        assertGt(carried, 0, "and the overflow survived the harvest");

        LiveBand memory band1 = _deployBand(1);

        assertGt(band1.tokenInventory, _perBand(), "band 1 is topped up by the carry");
        assertEq(
            band1.tokenInventory + hook.poolState(poolId).carriedInventory,
            _perBand() + carried,
            "and the carry was spent on it rather than sitting idle"
        );
    }

    // --- Scenario: No inventory is created from nothing ---

    function test_noInventoryIsCreatedFromNothing() public {
        _sell(1_000_000 ether);
        _clearAccrual();

        uint256 heldBefore = token.balanceOf(HOOK_ADDR);
        uint256 booksBefore = _custodiedTokens();
        assertGe(heldBefore, booksBefore, "the hook holds at least everything its books promise");

        LiveBand memory band = _deployBand(0);

        assertEq(heldBefore - token.balanceOf(HOOK_ADDR), band.tokenInventory, "the band was funded out of custody");
        assertEq(booksBefore - _custodiedTokens(), band.tokenInventory, "and the books moved by the same amount");
        assertGe(token.balanceOf(HOOK_ADDR), _custodiedTokens(), "still fully backed afterwards");
    }

    /// @dev The ladder's ceiling across a whole walk: everything it can ever stake is its configured share
    /// plus what fees actually diverted into it, and never a wei more.
    function test_theLadderNeverStakesMoreThanItWasGiven() public {
        uint256 ladderSupply = LadderLib.ladderSupply(hook.launchConfig(poolId));
        uint256 divertedTotal;

        for (uint256 i = 0; i < 3; i++) {
            _sell(1_000_000 ether);
            Collected memory c = _collectAndCapture();
            divertedTotal += c.diverted;

            LiveBand memory band = _deployBand(i);
            PoolState memory state = hook.poolState(poolId);

            assertLe(
                band.tokenInventory + state.carriedInventory + state.ladderInventoryRemaining
                    + state.milestoneFundAccrued,
                ladderSupply + divertedTotal,
                "the ladder holds its share plus what fees gave it, and nothing invented"
            );
            assertGe(token.balanceOf(HOOK_ADDR), _custodiedTokens(), "and custody still backs the books");

            (, int24 upper) = _bandLevels(i);
            _buyToLevel(upper + 200);
            assertEq(hook.poolState(poolId).completedMilestones, uint32(i) + 1, "each band completed in turn");
        }

        assertGt(divertedTotal, 0, "with real accrual along the way");
    }
}
