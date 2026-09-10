// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolId} from "v4-core/src/types/PoolId.sol";
import {MilestoneBase} from "../../src/MilestoneBase.sol";
import {PoolState} from "../../src/types/LaunchTypes.sol";
import {PayoutTestFixture} from "../mocks/PayoutTestHook.sol";
import {RecordingPayoutPlugin, RejectingPayoutCaller, SwitchablePayoutPlugin} from "../mocks/PayoutReferenceMocks.sol";

contract PayoutFlushTest is PayoutTestFixture {
    event PayoutPotRedeemed(PoolId indexed poolId, uint256 amount);

    // --- Scenario (graduation): Payouts do not compound ---
    function test_payoutsDoNotCompound() public {
        RecordingPayoutPlugin plugin = new RecordingPayoutPlugin();
        uint8 index = _registerPayoutPlugin(address(plugin), 0.4e18);
        PoolId defaultPoolId = poolId;
        (poolId, key, token) = _launchWithPlan("No Compound", "NOCMP", _plan(index));
        PoolId id = poolId;
        _graduate();

        uint256 grossQuote = 100 ether;
        _fundPot(id, 0, grossQuote);
        uint256 fundedPot = hook.payoutPot(id);
        uint256 expectedTip = fundedPot / 100;
        uint256 distributable = fundedPot - expectedTip;
        uint256 expectedPlugin = distributable * 0.4e18 / 1e18;
        uint256 expectedCreator = distributable - expectedPlugin;

        PoolState memory fundedState = hook.poolState(id);
        uint128 recordedLiquidityBefore = fundedState.fullRangeLiquidity;
        uint128 realLiquidityBefore = _fullRangeLiquidity();
        uint256 defaultCreatorBefore = hook.creatorClaimable(defaultPoolId);
        uint256 graduatedCreatorBefore = hook.creatorClaimable(id);
        uint256 creatorPathBefore = hook.creatorPathClaimable(id);
        uint256 protocolBefore = hook.protocolClaimable();
        uint256 protocolBackingBefore = hook.protocolClaimBacked();
        uint256 flusherBefore = STRANGER.balance;

        vm.prank(STRANGER);
        hook.flush(id);

        assertGt(recordedLiquidityBefore, 0, "graduation recorded no liquidity");
        assertEq(realLiquidityBefore, recordedLiquidityBefore, "recorded and real liquidity differ");
        assertEq(hook.payoutPot(id), 0, "pot not completely flushed");
        assertEq(STRANGER.balance - flusherBefore, expectedTip, "incorrect tip");
        assertEq(plugin.totalReceived(), expectedPlugin, "incorrect plugin allocation");
        assertEq(hook.creatorPathClaimable(id) - creatorPathBefore, expectedCreator, "incorrect creator remainder");
        assertEq(expectedTip + plugin.totalReceived() + expectedCreator, fundedPot, "pot partition incomplete");
        assertEq(_fullRangeLiquidity(), realLiquidityBefore, "real full-range liquidity changed");
        assertEq(hook.poolState(id).fullRangeLiquidity, recordedLiquidityBefore, "recorded liquidity changed");
        assertEq(hook.creatorClaimable(defaultPoolId), defaultCreatorBefore, "unrelated pool creator ledger changed");
        assertEq(hook.creatorClaimable(id), graduatedCreatorBefore, "direct creator ledger changed");
        assertEq(hook.protocolClaimable(), protocolBefore, "protocol ledger changed");
        assertEq(hook.protocolClaimBacked(), protocolBackingBefore, "protocol backing changed");
    }

    // --- Scenario: Any address can flush one pool ---
    function test_anyAddressCanFlushOnePool() public {
        _fundPot(poolId, 0, 100 ether);
        vm.prank(STRANGER);
        hook.flush(poolId);
        assertEq(hook.payoutPot(poolId), 0);
    }

    // --- Scenario: Whole new pot is redeemed once ---
    function test_wholeNewPotIsRedeemedOnce() public {
        _fundPot(poolId, 0, 100 ether);
        vm.expectEmit(true, false, false, true, address(hook));
        emit PayoutPotRedeemed(poolId, 90 ether);
        hook.flush(poolId);
        assertEq(hook.payoutPot(poolId), 0);
        assertEq(hook.claimBacking(), 10 ether);
        hook.flush(poolId);
        assertEq(hook.claimBacking(), 10 ether);
    }

    // --- Scenario: Flusher receives one percent of the net new pot ---
    function test_flusherReceivesOnePercentOfTheNetNewPot() public {
        _fundPot(poolId, 0, 100 ether);
        uint256 beforeBalance = STRANGER.balance;
        vm.prank(STRANGER);
        hook.flush(poolId);
        assertEq(STRANGER.balance - beforeBalance, 0.9 ether);
        assertEq(hook.creatorPathClaimable(poolId), 89.1 ether);
    }

    // --- Scenario: Protocol service fee is never tipped ---
    function test_protocolServiceFeeIsNeverTipped() public {
        _fundPot(poolId, 0, 100 ether);
        vm.prank(STRANGER);
        hook.flush(poolId);
        assertEq(STRANGER.balance, 0.9 ether);
        assertEq(hook.protocolClaimable(), 10 ether);
        assertEq(hook.protocolClaimBacked(), 10 ether);
    }

    // --- Scenario: Carry is not tipped twice ---
    function test_carryIsNotTippedTwice() public {
        SwitchablePayoutPlugin plugin = new SwitchablePayoutPlugin();
        uint8 index = _registerPayoutPlugin(address(plugin), 0.5e18);
        (PoolId id,,) = _launchWithPlan("Carry Tip", "CTIP", _plan(index));
        plugin.setShouldRevert(true);
        _fundPot(id, 0, 100 ether);
        vm.prank(STRANGER);
        hook.flush(id);
        uint256 carry = hook.pluginCarry(id, index);
        uint256 flusherAfterFirst = STRANGER.balance;
        plugin.setShouldRevert(false);
        vm.prank(STRANGER);
        hook.flush(id);
        assertEq(STRANGER.balance, flusherAfterFirst);
        assertEq(plugin.lastAmount(), carry);
    }

    // --- Scenario: Carry-only flush remains available ---
    function test_carryOnlyFlushRemainsAvailable() public {
        SwitchablePayoutPlugin plugin = new SwitchablePayoutPlugin();
        uint8 index = _registerPayoutPlugin(address(plugin), 0.5e18);
        (PoolId id,,) = _launchWithPlan("Carry Only", "CARRY", _plan(index));
        plugin.setShouldRevert(true);
        _fundPot(id, 0, 100 ether);
        hook.flush(id);
        uint256 carry = hook.pluginCarry(id, index);
        assertEq(hook.payoutPot(id), 0);
        plugin.setShouldRevert(false);
        hook.flush(id);
        assertEq(plugin.totalReceived(), carry);
        assertEq(hook.pluginCarry(id, index), 0);
    }

    // --- Scenario: Empty flush is a no-op ---
    function test_emptyFlushIsANoOp() public {
        uint256 claimBacking = hook.claimBacking();
        uint256 nativeBacking = address(hook).balance;
        hook.flush(poolId);
        assertEq(hook.claimBacking(), claimBacking);
        assertEq(address(hook).balance, nativeBacking);
        assertEq(hook.totalLiabilities(), 0);
    }

    // --- Scenario: Ordinary flusher tip failure is atomic ---
    function test_ordinaryFlusherTipFailureIsAtomic() public {
        RecordingPayoutPlugin plugin = new RecordingPayoutPlugin();
        uint8 index = _registerPayoutPlugin(address(plugin), 0.5e18);
        (PoolId id,,) = _launchWithPlan("Reject Tip", "RTIP", _plan(index));
        _fundPot(id, 0, 100 ether);
        RejectingPayoutCaller caller = new RejectingPayoutCaller();
        vm.expectRevert(abi.encodeWithSelector(MilestoneBase.EthTransferFailed.selector, address(caller), 0.9 ether));
        caller.flush(address(hook), id);
        assertEq(hook.payoutPot(id), 90 ether);
        assertEq(plugin.calls(), 0);
        assertEq(hook.creatorPathClaimable(id), 0);
        assertEq(hook.claimBacking(), 100 ether);
    }

    // --- Scenario: Ordinary swaps do not flush ---
    function test_ordinarySwapsDoNotFlush() public {
        RecordingPayoutPlugin plugin = new RecordingPayoutPlugin();
        uint8 index = _registerPayoutPlugin(address(plugin), 0.5e18);
        (PoolId id,,) = _launchWithPlan("Swap", "SWAP", _plan(index));
        _fundPot(id, 0, 100 ether);
        vm.prank(BUYER);
        _buy(1 ether);
        assertEq(hook.payoutPot(id), 90 ether);
        assertEq(plugin.calls(), 0);
    }
}
