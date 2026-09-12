// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolId} from "v4-core/src/types/PoolId.sol";
import {MilestoneBase} from "../../src/MilestoneBase.sol";
import {Bounds} from "../../src/types/LaunchTypes.sol";
import {PluginRole} from "../../src/types/PayoutTypes.sol";
import {PayoutTestFixture} from "../mocks/PayoutTestHook.sol";
import {
    GasExhaustingPayoutPlugin,
    OrderedPayoutPlugin,
    OrderRecorder,
    RecordingPayoutPlugin,
    ReturndataPayoutPlugin,
    SwitchablePayoutPlugin
} from "../mocks/PayoutReferenceMocks.sol";

contract PayoutFailureIsolationTest is PayoutTestFixture {
    uint256 private constant DISTRIBUTABLE = 89.1 ether;

    // --- Scenario: Plugins execute deterministically ---
    function test_pluginsExecuteDeterministically() public {
        OrderRecorder recorder = new OrderRecorder();
        OrderedPayoutPlugin first = new OrderedPayoutPlugin(address(recorder), 11);
        OrderedPayoutPlugin second = new OrderedPayoutPlugin(address(recorder), 22);
        uint8 firstIndex = _registerPayoutPlugin(address(first), 0.2e18);
        uint8 secondIndex = _registerPayoutPlugin(address(second), 0.2e18);
        (PoolId id,,) = _launchWithPlan("Order", "ORD", _plan(firstIndex, secondIndex));
        _fundPot(id, 0, 100 ether);
        hook.flushTo(id, STRANGER);
        assertEq(recorder.order(0), 11);
        assertEq(recorder.order(1), 22);
    }

    // --- Scenario: Plugin receives only its allocation ---
    function test_pluginReceivesOnlyItsAllocation() public {
        RecordingPayoutPlugin first = new RecordingPayoutPlugin();
        RecordingPayoutPlugin second = new RecordingPayoutPlugin();
        uint8 a = _registerPayoutPlugin(address(first), 0.2e18);
        uint8 b = _registerPayoutPlugin(address(second), 0.3e18);
        (PoolId id,,) = _launchWithPlan("Shares", "SHR", _plan(a, b));
        _fundPot(id, 0, 100 ether);
        hook.flushTo(id, STRANGER);
        assertEq(first.totalReceived(), 17.82 ether);
        assertEq(second.totalReceived(), 26.73 ether);
        assertEq(hook.creatorPathClaimable(id), 44.55 ether);
    }

    // --- Scenario: Void callback success ignores returndata ---
    function test_voidCallbackSuccessIgnoresReturndata() public {
        ReturndataPayoutPlugin plugin = new ReturndataPayoutPlugin();
        uint8 index = _registerPayoutPlugin(address(plugin), 0.5e18);
        (PoolId id,,) = _launchWithPlan("Return", "RET", _plan(index));
        for (uint256 mode; mode < 3; ++mode) {
            plugin.setMode(ReturndataPayoutPlugin.Mode(mode));
            _fundPot(id, uint32(mode), 10 ether);
            hook.flushTo(id, STRANGER);
        }
        assertEq(plugin.calls(), 3);
        assertEq(hook.pluginCarry(id, index), 0);
    }

    // --- Scenario: EIP-150 preflight preserves finalization gas ---
    function test_eip150PreflightPreservesFinalizationGas() public {
        uint32 callGas = 150_000;
        RecordingPayoutPlugin plugin = new RecordingPayoutPlugin();
        uint8 index = _registerPlugin(address(plugin), 0.5e18, callGas, _payoutRole());
        (PoolId id,,) = _launchWithPlan("Gas", "GAS", _plan(index));
        _fundPot(id, 0, 100 ether);
        // The constants live on the payout satellite, which is where the preflight runs. The hook only
        // delegates into it, so it does not carry them itself.
        uint256 required =
            Bounds.POST_CALL_GAS + Bounds.FINALIZE_GAS + callGas + (callGas + 62) / 63 + Bounds.CALL_FIXED_GAS;
        assertEq(required, 367_381);
        hook.flushTo{gas: required + 300_000}(id, STRANGER);
        assertEq(plugin.calls(), 1);
        assertEq(hook.creatorPathClaimable(id), DISTRIBUTABLE / 2);
    }

    // --- Scenario: Insufficient preflight gas reverts the flush ---
    function test_insufficientPreflightGasRevertsTheFlush() public {
        RecordingPayoutPlugin plugin = new RecordingPayoutPlugin();
        uint8 index = _registerPayoutPlugin(address(plugin), 0.5e18);
        (PoolId id,,) = _launchWithPlan("Low Gas", "LOW", _plan(index));
        _fundPot(id, 0, 100 ether);
        vm.expectPartialRevert(MilestoneBase.InsufficientPayoutGas.selector);
        hook.flushTo{gas: 450_000}(id, STRANGER);
        assertEq(hook.payoutPot(id), 90 ether);
        assertEq(hook.pluginCarry(id, index), 0);
        assertEq(plugin.calls(), 0);
    }

    // --- Scenario: Reverting plugin does not block later plugins ---
    function test_revertingPluginDoesNotBlockLaterPlugins() public {
        SwitchablePayoutPlugin rejecting = new SwitchablePayoutPlugin();
        RecordingPayoutPlugin accepting = new RecordingPayoutPlugin();
        uint8 first = _registerPayoutPlugin(address(rejecting), 0.2e18);
        uint8 second = _registerPayoutPlugin(address(accepting), 0.3e18);
        (PoolId id,,) = _launchWithPlan("Isolate", "ISO", _plan(first, second));
        rejecting.setShouldRevert(true);
        _fundPot(id, 0, 100 ether);
        hook.flushTo(id, STRANGER);
        assertEq(hook.pluginCarry(id, first), 17.82 ether);
        assertEq(accepting.totalReceived(), 26.73 ether);
    }

    // --- Scenario: Gas-exhausting plugin is isolated ---
    function test_gasExhaustingPluginIsIsolated() public {
        GasExhaustingPayoutPlugin exhausting = new GasExhaustingPayoutPlugin();
        RecordingPayoutPlugin accepting = new RecordingPayoutPlugin();
        uint8 first = _registerPlugin(address(exhausting), 0.2e18, 30_000, _payoutRole());
        uint8 second = _registerPayoutPlugin(address(accepting), 0.3e18);
        (PoolId id,,) = _launchWithPlan("Exhaust", "EXH", _plan(first, second));
        _fundPot(id, 0, 100 ether);
        hook.flushTo(id, STRANGER);
        assertEq(hook.pluginCarry(id, first), 17.82 ether);
        assertEq(accepting.calls(), 1);
    }

    // --- Scenario: Failed carry is retried ---
    function test_failedCarryIsRetried() public {
        SwitchablePayoutPlugin plugin = new SwitchablePayoutPlugin();
        uint8 index = _registerPayoutPlugin(address(plugin), 0.5e18);
        (PoolId id,,) = _launchWithPlan("Retry", "TRY", _plan(index));
        plugin.setShouldRevert(true);
        _fundPot(id, 0, 100 ether);
        hook.flushTo(id, STRANGER);
        uint256 carry = hook.pluginCarry(id, index);
        plugin.setShouldRevert(false);
        _fundPot(id, 1, 20 ether);
        hook.flushTo(id, STRANGER);
        assertEq(plugin.lastAmount(), carry + 8.91 ether);
        assertEq(hook.pluginCarry(id, index), 0);
    }

    // --- Scenario: Successful delivery is not replayed ---
    function test_successfulDeliveryIsNotReplayed() public {
        RecordingPayoutPlugin plugin = new RecordingPayoutPlugin();
        uint8 index = _registerPayoutPlugin(address(plugin), 0.5e18);
        (PoolId id,,) = _launchWithPlan("Once", "ONCE", _plan(index));
        _fundPot(id, 0, 100 ether);
        hook.flushTo(id, STRANGER);
        uint256 delivered = plugin.totalReceived();
        hook.flushTo(id, STRANGER);
        assertEq(plugin.calls(), 1);
        assertEq(plugin.totalReceived(), delivered);
    }

    // --- Scenario: Flush accounting conserves value ---
    function test_flushAccountingConservesValue() public {
        SwitchablePayoutPlugin failed = new SwitchablePayoutPlugin();
        RecordingPayoutPlugin delivered = new RecordingPayoutPlugin();
        uint8 first = _registerPayoutPlugin(address(failed), 0.2e18);
        uint8 second = _registerPayoutPlugin(address(delivered), 0.3e18);
        (PoolId id,,) = _launchWithPlan("Conserve", "CONS", _plan(first, second));
        failed.setShouldRevert(true);
        _fundPot(id, 0, 100 ether);
        uint256 flusherBefore = STRANGER.balance;
        vm.prank(STRANGER);
        hook.flushTo(id, STRANGER);
        uint256 tip = STRANGER.balance - flusherBefore;
        assertEq(
            tip + delivered.totalReceived() + hook.creatorPathClaimable(id) + hook.pluginCarry(id, first), 90 ether
        );
    }

    // --- Scenario: Suspended value redirects to the creator ---
    function test_suspendedValueRedirectsToTheCreator() public {
        RecordingPayoutPlugin plugin = new RecordingPayoutPlugin();
        uint8 index = _registerPayoutPlugin(address(plugin), 0.5e18);
        (PoolId id,,) = _launchWithPlan("Suspend", "SUSP", _plan(index));
        _setPluginSuspended(index, true);
        _fundPot(id, 0, 100 ether);
        hook.flushTo(id, STRANGER);
        assertEq(plugin.calls(), 0);
        assertEq(hook.creatorPathClaimable(id), DISTRIBUTABLE);
    }

    // --- Scenario: Reactivation affects later allocations only ---
    function test_reactivationAffectsLaterAllocationsOnly() public {
        RecordingPayoutPlugin plugin = new RecordingPayoutPlugin();
        uint8 index = _registerPayoutPlugin(address(plugin), 0.5e18);
        (PoolId id,,) = _launchWithPlan("Reactivate", "REAC", _plan(index));
        _setPluginSuspended(index, true);
        _fundPot(id, 0, 100 ether);
        hook.flushTo(id, STRANGER);
        uint256 redirected = hook.creatorPathClaimable(id);
        _setPluginSuspended(index, false);
        _fundPot(id, 1, 20 ether);
        hook.flushTo(id, STRANGER);
        assertEq(plugin.totalReceived(), 8.91 ether);
        assertEq(hook.creatorPathClaimable(id), redirected + 8.91 ether);
    }

    // --- Scenario: Codehash mismatch permanently redirects value ---
    function test_codehashMismatchPermanentlyRedirectsValue() public {
        RecordingPayoutPlugin plugin = new RecordingPayoutPlugin();
        uint8 index = _registerPayoutPlugin(address(plugin), 0.5e18);
        (PoolId id,,) = _launchWithPlan("Codehash", "CODE", _plan(index));
        _fundPot(id, 0, 100 ether);
        vm.etch(address(plugin), hex"00");
        hook.flushTo(id, STRANGER);
        assertEq(hook.creatorPathClaimable(id), DISTRIBUTABLE);
        vm.etch(address(plugin), type(RecordingPayoutPlugin).runtimeCode);
        hook.flushTo(id, STRANGER);
        assertEq(hook.pluginCarry(id, index), 0);
        assertEq(hook.creatorPathClaimable(id), DISTRIBUTABLE);
    }

    function _payoutRole() private pure returns (PluginRole) {
        return PluginRole.PAYOUT;
    }
}
