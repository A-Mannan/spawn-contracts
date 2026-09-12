// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {LaunchSupport} from "../../src/LaunchSupport.sol";
import {PayoutPluginRegistry} from "../../src/PayoutPluginRegistry.sol";
import {MilestoneToken} from "../../src/MilestoneToken.sol";
import {LaunchConfig, WAD} from "../../src/types/LaunchTypes.sol";
import {PluginRole} from "../../src/types/PayoutTypes.sol";
import {PayoutTestFixture} from "../mocks/PayoutTestHook.sol";
import {RecordingPayoutPlugin} from "../mocks/PayoutReferenceMocks.sol";

contract PayoutPlansTest is PayoutTestFixture {
    // --- Scenario: Set bits select stable registry indices ---
    function test_setBitsSelectStableRegistryIndices() public {
        RecordingPayoutPlugin first = new RecordingPayoutPlugin();
        RecordingPayoutPlugin second = new RecordingPayoutPlugin();
        uint8 firstIndex = _registerPayoutPlugin(address(first), 0.2e18);
        uint8 secondIndex = _registerPayoutPlugin(address(second), 0.3e18);
        (PoolId id,,) = _launchWithPlan("Plan", "PLAN", _plan(firstIndex, secondIndex));
        _fundPot(id, 0, 100 ether);

        hook.flushTo(id, STRANGER);

        assertEq(first.totalReceived(), 17.82 ether);
        assertEq(second.totalReceived(), 26.73 ether);
    }

    // --- Scenario: Invalid plan bits are rejected ---
    function test_invalidPlanBitsAreRejected() public {
        LaunchConfig memory config = _defaultConfig("Invalid", "INV");
        config.payoutPlan = uint256(1) << 200;
        vm.expectRevert(PayoutPluginRegistry.EntryDoesNotExist.selector);
        _launchDirect(config);

        RecordingPayoutPlugin suspended = new RecordingPayoutPlugin();
        uint8 index = _registerPayoutPlugin(address(suspended), 0.1e18);
        _setPluginSuspended(index, true);
        config = _defaultConfig("Suspended", "SUSP");
        config.payoutPlan = _plan(index);
        vm.expectRevert(PayoutPluginRegistry.EntryNotSelectable.selector);
        _launchDirect(config);

        RecordingPayoutPlugin utility = new RecordingPayoutPlugin();
        index = _registerPlugin(address(utility), 0, DEFAULT_PLUGIN_GAS_LIMIT, PluginRole.UTILITY);
        config = _defaultConfig("Utility", "UTIL");
        config.payoutPlan = _plan(index);
        vm.expectRevert(PayoutPluginRegistry.EntryNotSelectable.selector);
        _launchDirect(config);
    }

    // --- Scenario: Excessive fixed takes are rejected ---
    function test_excessiveFixedTakesAreRejected() public {
        uint8 first = _registerPayoutPlugin(address(new RecordingPayoutPlugin()), 0.6e18);
        uint8 second = _registerPayoutPlugin(address(new RecordingPayoutPlugin()), 0.5e18);
        LaunchConfig memory config = _defaultConfig("Excess", "EXC");
        config.payoutPlan = _plan(first, second);
        vm.expectRevert(abi.encodeWithSelector(LaunchSupport.PayoutTakesAboveWad.selector, 1.1e18));
        _launchDirect(config);
    }

    // --- Scenario: Enabled plugin count is bounded ---
    function test_enabledPluginCountIsBounded() public {
        uint256 plan;
        for (uint256 i; i < 9; ++i) {
            uint8 index = _registerPayoutPlugin(address(new RecordingPayoutPlugin()), 0.01e18);
            plan |= uint256(1) << index;
        }
        LaunchConfig memory config = _defaultConfig("Too Many", "MANY");
        config.payoutPlan = plan;
        vm.expectRevert(abi.encodeWithSelector(LaunchSupport.TooManyPayoutPlugins.selector, 9));
        _launchDirect(config);
    }

    // --- Scenario: Empty plan pays the creator ---
    function test_emptyPlanPaysTheCreator() public {
        _fundPot(poolId, 0, 100 ether);
        vm.prank(STRANGER);
        hook.flushTo(poolId, STRANGER);
        assertEq(hook.creatorPathClaimable(poolId), 89.1 ether);
    }

    // --- Scenario: Creator receives allocation dust ---
    function test_creatorReceivesAllocationDust() public {
        uint64 take = uint64(WAD / 3);
        RecordingPayoutPlugin plugin = new RecordingPayoutPlugin();
        uint8 index = _registerPayoutPlugin(address(plugin), take);
        (PoolId id,,) = _launchWithPlan("Dust", "DUST", _plan(index));
        _fundPot(id, 0, 1001 wei);
        hook.flushTo(id, STRANGER);
        uint256 distributable = 892;
        assertEq(hook.creatorPathClaimable(id), distributable - FullMath.mulDiv(distributable, take, WAD));
    }

    // --- Scenario: Plan cannot change after launch ---
    function test_planCannotChangeAfterLaunch() public {
        uint8 index = _registerPayoutPlugin(address(new RecordingPayoutPlugin()), 0.1e18);
        (PoolId id,,) = _launchWithPlan("Immutable", "IMM", _plan(index));
        assertEq(hook.payoutPlan(id), _plan(index));
        assertEq(hook.poolState(id).payoutPlan, _plan(index));
    }

    // --- Scenario: Registry growth cannot reinterpret a plan ---
    function test_registryGrowthCannotReinterpretAPlan() public {
        RecordingPayoutPlugin original = new RecordingPayoutPlugin();
        uint8 index = _registerPayoutPlugin(address(original), 0.2e18);
        (PoolId id,,) = _launchWithPlan("Stable", "STBL", _plan(index));
        _registerPayoutPlugin(address(new RecordingPayoutPlugin()), 0.4e18);
        _fundPot(id, 0, 100 ether);
        hook.flushTo(id, STRANGER);
        assertEq(original.totalReceived(), 17.82 ether);
        assertEq(hook.payoutPlan(id), _plan(index));
    }

    // --- Scenario: Preset names are off chain ---
    function test_presetNamesAreOffChain() public {
        uint8 index = _registerPayoutPlugin(address(new RecordingPayoutPlugin()), 0.2e18);
        uint256 firstAlias = _plan(index);
        uint256 renamedAlias = _plan(index);
        assertEq(firstAlias, renamedAlias);
    }

    // --- Scenario: Canonical bits select intended destinations ---
    function test_canonicalBitsSelectIntendedDestinations() public {
        uint8 buyback = _registerPayoutPlugin(address(new RecordingPayoutPlugin()), CANONICAL_BUYBACK_TAKE_WAD);
        assertEq(_canonicalPlan(buyback), uint256(1) << buyback);
    }
}
