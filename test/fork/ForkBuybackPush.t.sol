// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TickMath} from "v4-core/src/libraries/TickMath.sol";

import {BuybackAndBurnPlugin} from "../../src/BuybackAndBurnPlugin.sol";
import {PluginRole} from "../../src/types/PayoutTypes.sol";

import {BaseForkTest} from "./ForkFixtures.sol";

/// @notice Canonical buyback payout delivery against the live Base v4 singleton.
/// @dev Harvest only funds the isolated pot. The reference plugin receives ETH later, during an explicit
/// cold flush, and its nested live-v4 swap must burn the acquired launch tokens without re-entering ladder
/// or payout work.
contract ForkBuybackPushTest is BaseForkTest {
    uint256 private constant BUDGET = 2_000_000 ether;
    int24 private constant INSIDE = 100;
    uint32 private constant CANONICAL_BUYBACK_GAS_LIMIT = 500_000;

    BuybackAndBurnPlugin internal buyback;
    uint8 internal buybackIndex;

    function setUp() public override {
        super.setUp();

        buyback = new BuybackAndBurnPlugin(manager, address(hook), TickMath.MIN_SQRT_PRICE + 1);
        buybackIndex = _registerPlugin(
            address(buyback), CANONICAL_BUYBACK_TAKE_WAD, CANONICAL_BUYBACK_GAS_LIMIT, PluginRole.PAYOUT
        );
        (poolId, key, token) = _launchWithPlan("Fork Buyback", "FBB", _canonicalPlan(buybackIndex));
    }

    // --- Scenario (milestone-ladder): Harvest invokes no payout plugin ---
    // --- Scenario (milestone-ladder): Harvest performs no direct destination work ---
    // --- Scenario (payout-plugins): Any address can flush one pool ---
    // --- Scenario (payout-plugins): Flusher receives one percent of the net new pot ---
    // --- Scenario (payout-plugins): Plugin receives only its allocation ---
    // --- Scenario (payout-plugins): Buyback spends only delivered ETH ---
    // --- Scenario (payout-plugins): Buyback burns acquired tokens ---
    // --- Scenario (payout-plugins): Canonical economics match their declared baseline ---
    function test_canonicalBuybackRunsOnlyDuringAColdFlush() public {
        _graduate();
        _buyToLevel(BUDGET, _bandLower(0) + INSIDE);

        uint256 supplyBeforeHarvest = token.totalSupply();
        uint256 pluginEthBefore = address(buyback).balance;
        uint256 creatorPathBefore = hook.creatorPathClaimable(poolId);

        _buyToLevel(BUDGET, _bandUpper(0) + INSIDE);

        uint256 pot = hook.payoutPot(poolId);
        assertGt(pot, 0, "the harvest funded its isolated pot");
        assertEq(token.totalSupply(), supplyBeforeHarvest, "harvest itself burned no token");
        assertEq(address(buyback).balance, pluginEthBefore, "harvest delivered nothing to the plugin");
        assertEq(hook.creatorPathClaimable(poolId), creatorPathBefore, "harvest performed no creator destination work");

        uint256 tip = pot / 100;
        uint256 distributable = pot - tip;
        uint256 pluginAllocation = distributable * CANONICAL_BUYBACK_TAKE_WAD / 1e18;
        uint256 creatorRemainder = distributable - pluginAllocation;
        uint256 flusherBefore = STRANGER.balance;
        uint256 supplyBeforeFlush = token.totalSupply();

        vm.prank(STRANGER);
        hook.flush(poolId);

        assertEq(hook.payoutPot(poolId), 0, "the whole new pot was redeemed once");
        assertEq(STRANGER.balance - flusherBefore, tip, "the arbitrary flusher received one percent");
        assertEq(
            hook.creatorPathClaimable(poolId) - creatorPathBefore,
            creatorRemainder,
            "the creator received the exact arithmetic remainder"
        );
        assertEq(hook.pluginCarry(poolId, buybackIndex), 0, "the live buyback accepted its allocation");
        assertLt(token.totalSupply(), supplyBeforeFlush, "the acquired launch tokens were burned");
        assertEq(address(buyback).balance, pluginEthBefore, "the plugin retained none of its delivery");
    }
}
