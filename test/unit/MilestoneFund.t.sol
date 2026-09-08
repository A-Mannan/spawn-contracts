// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {MilestoneBase} from "../../src/MilestoneBase.sol";
import {LadderLib} from "../../src/libraries/LadderLib.sol";
import {PoolState, WAD} from "../../src/types/LaunchTypes.sol";
import {GraduatedFeeFixture} from "./SwapFees.t.sol";

/// @notice Shared rig for the two ladder-funding suites: a graduated pool plus the one manoeuvre both
/// need, which is to deploy a band and leave it alive.
abstract contract LadderFundFixture is GraduatedFeeFixture {
    /// @dev A *budget*, not an amount. Every buy in these suites is price-limited, so what it actually
    /// spends is whatever walking the price to the limit costs; 5,000 ETH carries well past the whole core
    /// ladder unlimited, so it never binds before the limit does.
    uint256 internal constant BAND_BUDGET = 5_000 ether;

    /// @notice Buys up into band `index` and returns the token inventory it was deployed with.
    ///
    /// @dev Limited *inside* the band rather than past its top, so the band is left live: a harvest in the
    /// same transaction would burn the position the assertions are about. The inventory is read from
    /// {MilestoneBase.BandDeployed} because it is the only place the figure appears — `_fundBand` reports it
    /// to nobody, and the position's liquidity is the figure after conversion, not before.
    function _deployBandAndRead(uint256 index) internal returns (uint256 inventory) {
        vm.recordLogs();
        _buyToLevel(BAND_BUDGET, _bandLower(index) + 100);
        inventory = _deployedInventoryOf(vm.getRecordedLogs(), uint32(index));
    }
}

/// @notice Unit tests for task 10.3 — diversion of token-denominated fees into the next band's inventory.
///
/// @dev The diversion is the one place the fee waterfall and the ladder meet. It runs *before* the split,
/// on the token side only, and it moves nothing: the tokens are already in hook custody by the time the
/// fund is credited, so a band grows without any swap and without touching the price.
///
/// The share is a template immutable under design Decision 16, so there is no longer a per-launch bound to
/// probe — the parked pair of launch-validation tests went with it. What survives is the runtime property,
/// which is the one the spec states.
contract MilestoneFundDiversionTest is LadderFundFixture {
    // --- Scenario: Sell-side fees fund the next band ---

    function test_sellSideFeesFundTheNextBand() public {
        assertEq(hook.poolState(poolId).milestoneFundAccrued, 0, "nothing accrued yet");

        _sell(MEASURED_SELL);
        Collected memory c = _collectAndCapture();

        uint64 share = template.milestoneFundShareWad;
        assertEq(share, 0.2e18, "the template fixes the share at 20%");
        assertGt(c.tokenFees, 0, "the sell paid in token");
        assertEq(c.diverted, (c.tokenFees * share) / WAD, "the template's share was diverted");
        assertEq(hook.poolState(poolId).milestoneFundAccrued, c.diverted, "and is held for the next band");

        // The remainder — and only the remainder — went through the waterfall. Under design Decision 21 the
        // token side has exactly one destination left, so the whole remainder is the LP share.
        assertEq(c.lpToken, c.tokenFees - c.diverted, "the rest flowed on");
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
        assertGt(_deployBandAndRead(0), _perBand(), "the fund went into the band");
        assertEq(hook.poolState(poolId).milestoneFundAccrued, 0, "and the fund is empty again");
    }

    // --- Scenario: Quote-denominated fees are never diverted ---

    function test_quoteFeesAreNeverDiverted() public {
        _buyClearOfTheLadder(MEASURED_BUY);
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
        _buyClearOfTheLadder(MEASURED_BUY);
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

        uint160 priceBefore = _sqrtPriceOf(poolId);
        int24 levelBefore = _level();
        uint256 supplyBefore = token.totalSupply();

        vm.recordLogs();
        hook.collectFees(key);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(_countLogs(logs, IPoolManager.Swap.selector), 0, "no swap was performed");
        assertEq(_sqrtPriceOf(poolId), priceBefore, "and the price did not move");
        assertEq(_level(), levelBefore, "at all");
        assertEq(token.totalSupply(), supplyBefore, "nor was anything bought and burned");
        assertGt(hook.poolState(poolId).milestoneFundAccrued, 0, "yet the fund accrued");
    }

    /// @dev Where the accrued tokens come from: the hook's own realised fee balance, not the pool.
    function test_accruedInventoryIsAlreadyInHookCustody() public {
        _sell(MEASURED_SELL);

        uint256 hookTokensBefore = token.balanceOf(HOOK_ADDR);
        Collected memory c = _collectAndCapture();
        uint256 received = token.balanceOf(HOOK_ADDR) - hookTokensBefore;

        // Not quite the whole fee, and not because of rounding. The waterfall compounds the LP share, and
        // the few wei of quote the graduation's trailing dust buy left carried in `pendingLpQuote` can pair
        // at spot; that mint's token debit nets against the fee credit inside the same unlock, so the hook
        // takes the fee less whatever went straight back into the full-range position. A sliver of the LP
        // share doing its job, in other words — everything else arrives as a real ERC20 balance.
        assertGt(c.liquidityAdded, 0, "a sliver of the token side paired with the carried quote");
        assertLe(received, c.tokenFees, "the hook never takes more than it collected");
        assertApproxEqRel(received, c.tokenFees, 1e12, "and the rest of the fee became a real balance");

        // What the diversion actually rests on: the fund is backed by tokens the hook already holds, and the
        // compounded sliver came out of the LP share rather than out of the fund's.
        assertGe(received, c.diverted, "the diverted share in particular arrived as real tokens");
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
        harness.forceLadderCappedOut(poolId);

        _sell(MEASURED_SELL);
        Collected memory c = _collectAndCapture();

        assertGt(c.tokenFees, 0, "token fees still arrive");
        assertEq(c.diverted, 0, "but nothing is diverted");
        assertEq(hook.poolState(poolId).milestoneFundAccrued, accruedBefore, "so the fund does not grow");
        assertEq(c.lpToken, c.tokenFees, "and the whole amount flows through the waterfall instead");
    }

    // --- Scenario: Diversion never exceeds the cap ---

    /// @dev The share is a template constant now, so the reachable form of this scenario is the runtime one:
    /// whatever the size of the collection, the diverted amount never exceeds that share of the token fees.
    function testFuzz_divertedNeverExceedsTheCap(uint256 sellAmount) public {
        sellAmount = bound(sellAmount, 1_000 ether, token.balanceOf(address(router)) / 2);

        _sell(sellAmount);
        Collected memory c = _collectAndCapture();

        assertLe(
            c.diverted * WAD,
            c.tokenFees * template.milestoneFundShareWad,
            "never above 20% of the token fees collected"
        );
        assertLe(c.diverted, c.tokenFees, "and obviously never more than was collected");
    }
}

/// @notice Unit tests for task 10.4 — how a band's inventory is sized at deployment.
///
/// @dev The parked version of this suite launched with a deliberately tiny ladder share, so that fee-derived
/// accrual was a large multiple of one band rather than a rounding error against it. Design Decision 16
/// moved those shares into the immutable template, so that lever is gone: at the shipped template a band is
/// 21,666,666 tokens while a 1% fee on the largest sell the pool can absorb diverts a few hundred thousand,
/// which puts the cap thousands of collections away.
///
/// The cap is still reachable, just from the other funding source. A band's inventory is its own share plus
/// *carried* inventory plus the accrued fund, and a skipped band carries a whole share — so two bands
/// stranded above spot put three shares in front of the band that deploys next, and the cap bites. That is
/// the driver these tests use, and it exercises exactly the same {LadderLib.sizeInventory} branch the
/// parked accrual-driven version did. The accrual path keeps the first test, where its scale is enough to
/// show up.
contract BandInventorySizingTest is LadderFundFixture {
    /// @notice The whole ladder allocation, the pool every band's share is drawn from.
    function _ladderSupply() internal view returns (uint256) {
        return LadderLib.ladderSupply(SUPPLY, template.ladderSupplyShareWad);
    }

    // --- Scenario: Accrued milestone-fund tokens enlarge the band ---

    function test_accruedMilestoneFundTokensEnlargeTheBand() public {
        _sell(MEASURED_SELL);
        Collected memory c = _collectAndCapture();

        uint256 accrued = hook.poolState(poolId).milestoneFundAccrued;
        uint256 perBand = _perBand();

        assertEq(accrued, c.diverted, "the fund holds what was diverted");
        assertGt(accrued, 0, "and it is not trivial");
        assertLt(perBand + accrued, perBand * template.bandInventoryCapMultiple, "still below the cap");
        // A pure-buy graduation carries nothing, so the fund is the only thing topping this band up and the
        // arithmetic below is unambiguous.
        assertEq(hook.poolState(poolId).carriedInventory, 0, "with no carry in play");

        uint256 inventory = _deployBandAndRead(0);
        PoolState memory state = hook.poolState(poolId);

        assertGt(inventory, perBand, "the band is larger than its configured share alone");
        // Exact rather than approximate: the configured share plus the accrual, less only the dust the
        // liquidity conversion floors away — and that dust is carried forward, not lost.
        assertEq(inventory + state.carriedInventory, perBand + accrued, "share plus accrual, to the wei");
        assertEq(state.milestoneFundAccrued, 0, "the fund was consumed by the deployment");
        assertEq(
            state.ladderInventoryRemaining, _ladderSupply() - perBand, "and the band's own share came out of the ladder"
        );
    }

    // --- Scenario: Inventory is capped at twice the configured share ---
    // --- Scenario: Overflow carries to the next band ---

    /// @dev Strands two bands above spot and then deploys the one above them, so three shares are available
    /// where the cap allows two.
    ///
    /// Getting two bands stranded takes the same two steps as one: an unlimited buy runs past the per-swap
    /// deploy cap leaving a run of undeployed bands behind it, and a sell then parks spot in the gap above
    /// the second of them. Both are below spot and undeployed, so both skip on the next buy up; the third is
    /// above spot, so it is the one that mints.
    function test_inventoryIsCappedAtTwiceTheConfiguredShare() public {
        uint32 stranded = _strandTwoBands();
        uint256 perBand = _perBand();
        uint256 cap = uint256(template.bandInventoryCapMultiple) * perBand;

        uint256 carriedBefore = hook.poolState(poolId).carriedInventory;
        uint256 remainingBefore = hook.poolState(poolId).ladderInventoryRemaining;

        vm.recordLogs();
        _buyToLevel(2_000 ether, _bandLower(stranded + 2) + 100);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint32[] memory skipped = _bandIndices(logs, MilestoneBase.BandSkipped.selector);
        assertEq(skipped.length, 2, "two bands stranded, two skipped");
        assertEq(skipped[0], stranded, "in order");
        assertEq(skipped[1], stranded + 1, "in order");

        // Two skipped shares plus the deploying band's own: three where two are allowed.
        uint256 available = 3 * perBand + carriedBefore;
        assertGt(available, cap, "more is available than a single band may take");

        uint256 inventory = _deployedInventoryOf(logs, stranded + 2);
        PoolState memory state = hook.poolState(poolId);

        assertLe(inventory, cap, "never above the cap");
        assertApproxEqAbs(inventory, cap, 1e12, "and deployed at exactly it, less mint dust");
        // Capped, not truncated: what the cap held back is carried, and the two still sum to what was
        // available. A run of skips cannot concentrate the ladder into one position, nor lose the excess.
        assertEq(inventory + state.carriedInventory, available, "nothing was discarded");
        assertApproxEqAbs(state.carriedInventory, available - cap, 1e12, "the excess became carry");
        assertGt(state.carriedInventory, 0, "and there really was an excess");
        assertEq(
            state.ladderInventoryRemaining,
            remainingBefore - 3 * perBand,
            "three shares left the undrawn pool for one position"
        );
    }

    function test_theCarriedOverflowFundsTheNextBand() public {
        uint32 stranded = _strandTwoBands();
        _buyToLevel(2_000 ether, _bandLower(stranded + 2) + 100);

        uint256 carried = hook.poolState(poolId).carriedInventory;
        assertGt(carried, 0, "the capped band left something behind");

        // Cross the capped band's top so the cursor moves on, and deploy the band above it in the same
        // swap. The deploy runs in `beforeSwap` and the harvest in `afterSwap`, so what funds this band is
        // the carry as it stood, before the crossing adds anything of its own.
        uint256 completedBefore = hook.poolState(poolId).completedMilestones;

        vm.recordLogs();
        _buyToLevel(2_000 ether, _bandLower(stranded + 3) + 100);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(
            hook.poolState(poolId).completedMilestones, completedBefore + 1, "the capped band completed on the way"
        );

        uint256 inventory = _deployedInventoryOf(logs, stranded + 3);
        assertGt(inventory, _perBand(), "the next band is topped up by the carry");
        assertEq(
            inventory + hook.poolState(poolId).carriedInventory,
            _perBand() + carried,
            "and the carry was spent on it rather than sitting idle"
        );
    }

    // --- Scenario: No inventory is created from nothing ---

    function test_noInventoryIsCreatedFromNothing() public {
        _sell(MEASURED_SELL);
        _clearAccrual();

        uint256 heldBefore = token.balanceOf(HOOK_ADDR);
        uint256 booksBefore = _undeployedInventory();
        assertGe(heldBefore, booksBefore, "the hook holds at least everything its books promise");

        uint256 inventory = _deployBandAndRead(0);

        assertEq(heldBefore - token.balanceOf(HOOK_ADDR), inventory, "the band was funded out of custody");
        assertEq(booksBefore - _undeployedInventory(), inventory, "and the books moved by the same amount");
        assertGe(token.balanceOf(HOOK_ADDR), _undeployedInventory(), "still fully backed afterwards");
    }

    /// @dev The ladder's ceiling across a whole walk: everything it can ever stake is its configured share
    /// plus what fees actually diverted into it, and never a wei more.
    function test_theLadderNeverStakesMoreThanItWasGiven() public {
        uint256 divertedTotal;

        for (uint256 i = 0; i < 3; i++) {
            _sell(MEASURED_SELL);
            Collected memory c = _collectAndCapture();
            divertedTotal += c.diverted;

            uint256 inventory = _deployBandAndRead(i);

            assertLe(
                inventory + _undeployedInventory(),
                _ladderSupply() + divertedTotal,
                "the ladder holds its share plus what fees gave it, and nothing invented"
            );
            assertGe(token.balanceOf(HOOK_ADDR), _undeployedInventory(), "and custody still backs the books");

            _buyToLevel(BAND_BUDGET, _bandUpper(i) + 200);
            assertEq(hook.poolState(poolId).completedMilestones, uint32(i) + 1, "each band completed in turn");
        }

        assertGt(divertedTotal, 0, "with real accrual along the way");
    }

    /// @notice Leaves bands `n` and `n + 1` undeployed with spot parked above both, and returns `n`.
    function _strandTwoBands() private returns (uint32 stranded) {
        // No price limit: the path crosses far more band floors than the per-swap deploy cap allows, so the
        // bands above the cap are left undeployed with the price already past them.
        _buy(5_000 ether);
        stranded = hook.poolState(poolId).nextBandIndex;

        // Park spot in the gap between the second stranded band's top and the third band's floor: above both
        // stranded bands, so neither can mint, and below the next one, so that one still can.
        _sellAllToLevel(_bandUpper(stranded + 1) + 400);

        assertFalse(hook.bandDeployed(poolId, stranded), "the first stranded band was never minted");
        assertFalse(hook.bandDeployed(poolId, stranded + 1), "nor the second");
        assertGt(_level(), _bandUpper(stranded + 1), "spot is above both, so neither can mint");
        assertLt(_level(), _bandLower(stranded + 2), "and below the next band's floor, so that one can");
    }
}
