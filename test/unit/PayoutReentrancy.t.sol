// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolId} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {MilestoneBase} from "../../src/MilestoneBase.sol";
import {PayoutTestFixture} from "../mocks/PayoutTestHook.sol";
import {
    CallbackSwapPayoutPlugin,
    ICallbackSwapRouter,
    IPayoutAttackTarget,
    ReentrantPayoutPlugin,
    SwitchablePayoutPlugin
} from "../mocks/PayoutReferenceMocks.sol";

contract PayoutReentrancyTest is PayoutTestFixture {
    // --- Scenario: Same-pool reentry is rejected ---
    function test_samePoolReentryIsRejected() public {
        ReentrantPayoutPlugin plugin = new ReentrantPayoutPlugin();
        uint8 index = _registerPayoutPlugin(address(plugin), 0.5e18);
        (PoolId id,,) = _launchWithPlan("Same", "SAME", _plan(index));
        plugin.configure(IPayoutAttackTarget(address(hook)), id, ReentrantPayoutPlugin.Attack.FLUSH, true);
        _fundPot(id, 0, 100 ether);
        hook.flushTo(id, STRANGER);
        assertFalse(plugin.nestedSucceeded());
        assertEq(plugin.totalReceived(), 44.55 ether);
        assertEq(hook.pluginCarry(id, index), 0);
    }

    // --- Scenario: Cross-pool reentry is rejected ---
    function test_crossPoolReentryIsRejected() public {
        ReentrantPayoutPlugin plugin = new ReentrantPayoutPlugin();
        uint8 index = _registerPayoutPlugin(address(plugin), 0.5e18);
        (PoolId source,,) = _launchWithPlan("Source", "SRC", _plan(index));
        (PoolId other,,) = _launchWithPlan("Other", "OTH", 0);
        plugin.configure(IPayoutAttackTarget(address(hook)), other, ReentrantPayoutPlugin.Attack.FLUSH, false);
        _fundPot(source, 0, 100 ether);
        _fundPot(other, 0, 20 ether);
        hook.flushTo(source, STRANGER);
        assertFalse(plugin.nestedSucceeded());
        assertEq(hook.pluginCarry(source, index), 44.55 ether);
        assertEq(hook.payoutPot(other), 18 ether);
    }

    // --- Scenario: Unrelated value is unreachable ---
    function test_unrelatedValueIsUnreachable() public {
        ReentrantPayoutPlugin plugin = new ReentrantPayoutPlugin();
        uint8 index = _registerPayoutPlugin(address(plugin), 0.5e18);
        (PoolId source,,) = _launchWithPlan("Guarded", "GUARD", _plan(index));
        (PoolId other,,) = _launchWithPlan("Reserve", "RES", 0);
        payoutHook.accrueDirectCreator{value: 3 ether}(other, 3 ether);
        payoutHook.accrueRawProtocol{value: 2 ether}(other, 2 ether);
        _fundPot(other, 0, 10 ether);
        plugin.configure(IPayoutAttackTarget(address(hook)), other, ReentrantPayoutPlugin.Attack.PROTOCOL_CLAIM, true);
        _fundPot(source, 0, 100 ether);
        hook.flushTo(source, STRANGER);
        assertFalse(plugin.nestedSucceeded());
        assertEq(hook.creatorClaimable(other), 3 ether);
        assertEq(hook.protocolClaimable(), 13 ether);
        assertEq(hook.payoutPot(other), 9 ether);
    }

    // --- Scenario: Nested callbacks suppress protocol work ---
    function test_nestedCallbacksSuppressProtocolWork() public {
        _graduate();
        CallbackSwapPayoutPlugin plugin = new CallbackSwapPayoutPlugin();
        uint8 index = _registerPayoutPlugin(address(plugin), 0.5e18);
        (PoolId source,,) = _launchWithPlan("Callback", "CALL", _plan(index));
        PoolKey memory targetKey = key;
        int24 beforeLevel = _level();
        uint32 beforeNextBand = hook.poolState(poolId).nextBandIndex;
        plugin.configureCallbackSwap(
            ICallbackSwapRouter(address(router)), targetKey, -int256(1 wei), _sqrtAtLevel(beforeLevel + 1)
        );
        _fundPot(source, 0, 100 ether);
        hook.flushTo(source, STRANGER);
        assertTrue(plugin.nestedSucceeded());
        assertEq(hook.poolState(poolId).nextBandIndex, beforeNextBand);
        assertEq(hook.payoutPot(source), 0);
    }

    // --- Scenario: Guard clears after the transaction ---
    function test_guardClearsAfterTheTransaction() public {
        ReentrantPayoutPlugin plugin = new ReentrantPayoutPlugin();
        uint8 index = _registerPayoutPlugin(address(plugin), 0.5e18);
        (PoolId source,,) = _launchWithPlan("Clear", "CLR", _plan(index));
        (PoolId other,,) = _launchWithPlan("Later", "LTR", 0);
        plugin.configure(IPayoutAttackTarget(address(hook)), other, ReentrantPayoutPlugin.Attack.FLUSH, true);
        _fundPot(source, 0, 100 ether);
        _fundPot(other, 0, 20 ether);
        hook.flushTo(source, STRANGER);
        assertFalse(plugin.nestedSucceeded());
        hook.flushTo(other, STRANGER);
        assertEq(hook.payoutPot(other), 0);
        assertEq(hook.creatorPathClaimable(other), 17.82 ether);
    }

    // --- Scenario (revenue-claims): Claims cannot reach ladder inventory ---
    function test_claimsCannotReachLadderInventory() public {
        _graduate();
        uint256 inventoryBefore = hook.poolState(poolId).ladderInventoryRemaining;
        payoutHook.accrueDirectCreator{value: 2 ether}(poolId, 2 ether);
        vm.prank(creator);
        hook.claimCreator(poolId);
        assertEq(hook.poolState(poolId).ladderInventoryRemaining, inventoryBefore);
    }

    // --- Scenario (revenue-claims): Claims cannot reach locked liquidity ---
    function test_claimsCannotReachLockedLiquidity() public {
        _graduate();
        uint128 liquidityBefore = hook.poolState(poolId).fullRangeLiquidity;
        payoutHook.accrueDirectCreator{value: 2 ether}(poolId, 2 ether);
        vm.prank(creator);
        hook.claimCreator(poolId);
        assertEq(hook.poolState(poolId).fullRangeLiquidity, liquidityBefore);
    }

    // --- Scenario (revenue-claims): Direct creator and protocol claims are isolated ---
    function test_directCreatorAndProtocolClaimsAreIsolated() public {
        payoutHook.accrueDirectCreator{value: 3 ether}(poolId, 3 ether);
        payoutHook.accrueRawProtocol{value: 2 ether}(poolId, 2 ether);
        vm.prank(creator);
        hook.claimCreator(poolId);
        assertEq(hook.protocolClaimable(), 2 ether);
        payoutHook.accrueDirectCreator{value: 3 ether}(poolId, 3 ether);
        vm.prank(PROTOCOL_RECIPIENT);
        hook.claimProtocol();
        assertEq(hook.creatorClaimable(poolId), 3 ether);
    }

    // --- Scenario (revenue-claims): Creator claims are isolated across pools ---
    function test_creatorClaimsAreIsolatedAcrossPools() public {
        (PoolId other,,) = _launchWithPlan("Other Claims", "OCLM", 0);
        payoutHook.accrueDirectCreator{value: 2 ether}(poolId, 2 ether);
        payoutHook.accrueDirectCreator{value: 4 ether}(other, 4 ether);
        vm.prank(creator);
        hook.claimCreator(poolId);
        assertEq(hook.creatorClaimable(other), 4 ether);
    }

    // --- Scenario (revenue-claims): Claims cannot reach pot or carry reserves ---
    function test_claimsCannotReachPotOrCarryReserves() public {
        SwitchablePayoutPlugin plugin = new SwitchablePayoutPlugin();
        uint8 index = _registerPayoutPlugin(address(plugin), 0.5e18);
        (PoolId carried,,) = _launchWithPlan("Carry Reserve", "CRSV", _plan(index));
        plugin.setShouldRevert(true);
        _fundPot(carried, 0, 100 ether);
        hook.flushTo(carried, STRANGER);
        _fundPot(poolId, 0, 20 ether);
        payoutHook.accrueDirectCreator{value: 3 ether}(poolId, 3 ether);
        uint256 carryBefore = hook.pluginCarry(carried, index);
        vm.prank(creator);
        hook.claimCreator(poolId);
        assertEq(hook.pluginCarry(carried, index), carryBefore);
        assertEq(hook.payoutPot(poolId), 18 ether);
        assertEq(hook.claimBacking(), hook.claimBackedLiabilities());
    }

    // --- Scenario (revenue-claims): Protocol claim cannot consume creator value ---
    function test_protocolClaimCannotConsumeCreatorValue() public {
        payoutHook.accrueDirectCreator{value: 3 ether}(poolId, 3 ether);
        payoutHook.accrueRawProtocol{value: 2 ether}(poolId, 2 ether);
        _fundPot(poolId, 0, 100 ether);
        hook.flushTo(poolId, STRANGER);
        uint256 creatorPath = hook.creatorPathClaimable(poolId);
        vm.prank(PROTOCOL_RECIPIENT);
        hook.claimProtocol();
        assertEq(hook.creatorClaimable(poolId), 3 ether);
        assertEq(hook.creatorPathClaimable(poolId), creatorPath);
    }

    // --- Scenario (revenue-claims): Direct revenue is claimable while a pot is unflushed ---
    function test_directRevenueIsClaimableWhileAPotIsUnflushed() public {
        _fundPot(poolId, 0, 100 ether);
        payoutHook.accrueDirectCreator{value: 3 ether}(poolId, 3 ether);
        vm.prank(creator);
        assertEq(hook.claimCreator(poolId), 3 ether);
        assertEq(hook.payoutPot(poolId), 90 ether);
    }

    // --- Scenario (revenue-claims): Flush leaves direct creator revenue unchanged ---
    function test_flushLeavesDirectCreatorRevenueUnchanged() public {
        payoutHook.accrueDirectCreator{value: 3 ether}(poolId, 3 ether);
        _fundPot(poolId, 0, 100 ether);
        hook.flushTo(poolId, STRANGER);
        assertEq(hook.creatorClaimable(poolId), 3 ether);
    }

    // --- Scenario (revenue-claims): Failed delivery leaves direct revenue unchanged ---
    function test_failedDeliveryLeavesDirectRevenueUnchanged() public {
        SwitchablePayoutPlugin plugin = new SwitchablePayoutPlugin();
        uint8 index = _registerPayoutPlugin(address(plugin), 0.5e18);
        (PoolId id,,) = _launchWithPlan("Failed Direct", "FDIR", _plan(index));
        plugin.setShouldRevert(true);
        payoutHook.accrueDirectCreator{value: 3 ether}(id, 3 ether);
        _fundPot(id, 0, 100 ether);
        hook.flushTo(id, STRANGER);
        assertEq(hook.creatorClaimable(id), 3 ether);
        vm.prank(creator);
        assertEq(hook.claimCreator(id), 3 ether);
    }
}
