// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {EconomicConfig, PluginRole} from "../../src/types/PayoutTypes.sol";
import {IProtocolConfigurationTarget} from "../../src/interfaces/IPayoutPluginRegistry.sol";
import {PayoutPluginRegistry} from "../../src/PayoutPluginRegistry.sol";
import {ProtocolController} from "../../src/ProtocolController.sol";

contract GovernanceTargetMock is IProtocolConfigurationTarget {
    EconomicConfig private _config;
    address public protocolRecipient;
    uint256 public economicConfigCalls;
    uint256 public recipientCalls;
    bool public payoutDeliveryInFlight;

    function setPayoutDeliveryInFlight(bool active) external {
        payoutDeliveryInFlight = active;
    }

    function setEconomicConfig(EconomicConfig calldata config) external {
        _config = config;
        ++economicConfigCalls;
    }

    function setProtocolRecipient(address recipient) external {
        protocolRecipient = recipient;
        ++recipientCalls;
    }

    function economicConfig() external view returns (EconomicConfig memory) {
        return _config;
    }
}

contract GovernancePlugin {
    receive() external payable {}
}

contract EconomicGovernanceTest is Test {
    address internal constant ADMINISTRATOR = address(0xA11CE);
    address internal constant RECIPIENT = address(0xFEE);
    address internal constant NEXT_ADMINISTRATOR = address(0xBEEF);
    address internal constant STRANGER = address(0xB0B);
    address internal constant NEXT_RECIPIENT = address(0xCAFE);
    uint32 internal constant GAS_LIMIT = 100_000;

    GovernanceTargetMock internal target;
    PayoutPluginRegistry internal registry;
    ProtocolController internal controller;

    function setUp() public {
        target = new GovernanceTargetMock();
        registry = new PayoutPluginRegistry(address(this));
        controller = new ProtocolController(ADMINISTRATOR, RECIPIENT, registry, address(target));
        registry.proposeAdministrator(address(controller));
        vm.prank(address(controller));
        registry.acceptAdministrator();
        assertEq(registry.administrator(), address(controller), "registry authority is controller");
    }

    // --- Scenario: Administrator and recipient are independent ---

    function test_administratorAndRecipientAreIndependent() public {
        assertEq(controller.administrator(), ADMINISTRATOR);
        assertEq(controller.protocolRecipient(), RECIPIENT);
        assertTrue(ADMINISTRATOR != RECIPIENT);

        vm.prank(RECIPIENT);
        vm.expectRevert(ProtocolController.NotAdministrator.selector);
        controller.scheduleProtocolRecipient(NEXT_RECIPIENT, bytes32("recipient"));

        vm.prank(ADMINISTRATOR);
        controller.scheduleProtocolRecipient(NEXT_RECIPIENT, bytes32("recipient"));
    }

    // --- Scenario: Administrator transfer requires acceptance ---

    function test_administratorTransferRequiresAcceptance() public {
        vm.prank(ADMINISTRATOR);
        controller.proposeAdministrator(NEXT_ADMINISTRATOR);

        assertEq(controller.administrator(), ADMINISTRATOR, "proposal does not transfer authority");
        assertEq(controller.pendingAdministrator(), NEXT_ADMINISTRATOR);

        vm.prank(NEXT_ADMINISTRATOR);
        controller.acceptAdministrator();
        assertEq(controller.administrator(), NEXT_ADMINISTRATOR);
        assertEq(controller.pendingAdministrator(), address(0));

        vm.prank(ADMINISTRATOR);
        vm.expectRevert(ProtocolController.NotAdministrator.selector);
        controller.scheduleGovernanceDelay(1, bytes32("old-admin"));
    }

    // --- Scenario: Unauthorized acceptance is rejected ---

    function test_unauthorizedAcceptanceIsRejected() public {
        vm.prank(ADMINISTRATOR);
        controller.proposeAdministrator(NEXT_ADMINISTRATOR);

        vm.prank(STRANGER);
        vm.expectRevert(ProtocolController.NotPendingAdministrator.selector);
        controller.acceptAdministrator();
        assertEq(controller.administrator(), ADMINISTRATOR);
    }

    // --- Scenario: Zero-delay update can execute immediately ---

    function test_zeroDelayUpdateCanExecuteImmediately() public {
        bytes32 salt = bytes32("zero-delay");
        vm.prank(ADMINISTRATOR);
        bytes32 operationId = controller.scheduleProtocolRecipient(NEXT_RECIPIENT, salt);

        assertEq(controller.readyAt(operationId), block.timestamp);
        vm.prank(STRANGER);
        controller.executeProtocolRecipient(NEXT_RECIPIENT, salt);
        assertEq(controller.protocolRecipient(), NEXT_RECIPIENT);
        assertEq(target.protocolRecipient(), NEXT_RECIPIENT);
    }

    // --- Scenario: Positive delay is enforced ---

    function test_positiveDelayIsEnforced() public {
        _setDelay(2 days);
        bytes32 salt = bytes32("positive-delay");
        vm.prank(ADMINISTRATOR);
        bytes32 operationId = controller.scheduleProtocolRecipient(NEXT_RECIPIENT, salt);
        uint64 ready = controller.readyAt(operationId);

        vm.expectRevert(abi.encodeWithSelector(ProtocolController.OperationNotReady.selector, ready));
        controller.executeProtocolRecipient(NEXT_RECIPIENT, salt);
        vm.warp(ready);
        vm.prank(STRANGER);
        controller.executeProtocolRecipient(NEXT_RECIPIENT, salt);
    }

    // --- Scenario: Delay update uses the old delay ---

    function test_delayUpdateUsesTheOldDelay() public {
        _setDelay(1 days);
        bytes32 salt = bytes32("delay-update");
        vm.prank(ADMINISTRATOR);
        bytes32 operationId = controller.scheduleGovernanceDelay(3 days, salt);
        uint64 ready = controller.readyAt(operationId);

        vm.expectRevert(abi.encodeWithSelector(ProtocolController.OperationNotReady.selector, ready));
        controller.executeGovernanceDelay(3 days, salt);
        vm.warp(ready);
        controller.executeGovernanceDelay(3 days, salt);
        assertEq(controller.governanceDelay(), 3 days);
    }

    // --- Scenario: Queued readiness does not change retroactively ---

    function test_queuedReadinessDoesNotChangeRetroactively() public {
        _setDelay(2 days);
        bytes32 recipientSalt = bytes32("captured");
        vm.prank(ADMINISTRATOR);
        bytes32 recipientOperation = controller.scheduleProtocolRecipient(NEXT_RECIPIENT, recipientSalt);
        uint64 captured = controller.readyAt(recipientOperation);

        bytes32 delaySalt = bytes32("shorter");
        vm.prank(ADMINISTRATOR);
        bytes32 delayOperation = controller.scheduleGovernanceDelay(0, delaySalt);
        vm.warp(controller.readyAt(delayOperation));
        controller.executeGovernanceDelay(0, delaySalt);

        assertEq(controller.readyAt(recipientOperation), captured);
        controller.executeProtocolRecipient(NEXT_RECIPIENT, recipientSalt);
    }

    // --- Scenario: Scheduled operation can be cancelled ---

    function test_scheduledOperationCanBeCancelled() public {
        bytes32 salt = bytes32("cancelled");
        vm.prank(ADMINISTRATOR);
        bytes32 operationId = controller.scheduleProtocolRecipient(NEXT_RECIPIENT, salt);

        vm.prank(STRANGER);
        vm.expectRevert(ProtocolController.NotAdministrator.selector);
        controller.cancel(operationId);
        vm.prank(ADMINISTRATOR);
        controller.cancel(operationId);

        vm.expectRevert(ProtocolController.OperationNotScheduled.selector);
        controller.executeProtocolRecipient(NEXT_RECIPIENT, salt);
    }

    // --- Scenario: Operation identity binds complete parameters ---

    function test_operationIdentityBindsCompleteParameters() public {
        bytes32 salt = bytes32("identity");
        vm.prank(ADMINISTRATOR);
        bytes32 operationId = controller.scheduleProtocolRecipient(NEXT_RECIPIENT, salt);

        vm.expectRevert(ProtocolController.OperationNotScheduled.selector);
        controller.executeProtocolRecipient(address(0xDEAD), salt);
        vm.expectRevert(ProtocolController.OperationNotScheduled.selector);
        controller.executeProtocolRecipient(NEXT_RECIPIENT, bytes32("other-salt"));

        bytes32 differentAction = controller.hashGovernanceDelay(uint64(uint160(NEXT_RECIPIENT)), salt);
        assertTrue(operationId != differentAction, "action type is bound");
        controller.executeProtocolRecipient(NEXT_RECIPIENT, salt);
    }

    // --- Scenario (swap-fees): Default global configuration is published ---

    function test_defaultGlobalConfigurationIsPublished() public view {
        EconomicConfig memory config = controller.economicConfig();
        assertEq(config.harvestServiceFeeWad, 0.1e18);
        assertEq(config.quoteCreatorShareWad, 0.75e18);
        assertEq(config.tokenMilestoneFundShareWad, 0.2e18);
        assertEq(config.version, 1);
        assertEq(controller.governanceDelay(), 0);
    }

    // --- Scenario (swap-fees): Service-fee cap is enforced ---

    function test_serviceFeeCapIsEnforced() public {
        EconomicConfig memory config = _config(0.2e18 + 1, 0.75e18, 0.2e18, 2);
        vm.prank(ADMINISTRATOR);
        vm.expectRevert(ProtocolController.InvalidEconomicConfig.selector);
        controller.scheduleEconomicConfig(config, bytes32("service-cap"));
    }

    // --- Scenario (swap-fees): Quote creator cap is enforced ---

    function test_quoteCreatorCapIsEnforced() public {
        EconomicConfig memory config = _config(0.1e18, 0.9e18 + 1, 0.2e18, 2);
        vm.prank(ADMINISTRATOR);
        vm.expectRevert(ProtocolController.InvalidEconomicConfig.selector);
        controller.scheduleEconomicConfig(config, bytes32("creator-cap"));
    }

    // --- Scenario (swap-fees): Token-fund cap is enforced ---

    function test_tokenFundCapIsEnforced() public {
        EconomicConfig memory config = _config(0.1e18, 0.75e18, 0.5e18 + 1, 2);
        vm.prank(ADMINISTRATOR);
        vm.expectRevert(ProtocolController.InvalidEconomicConfig.selector);
        controller.scheduleEconomicConfig(config, bytes32("token-cap"));
    }

    // --- Scenario (swap-fees): Exact cap values are accepted ---

    function test_exactCapValuesAreAccepted() public {
        EconomicConfig memory config = _config(0.2e18, 0.9e18, 0.5e18, 2);
        bytes32 salt = bytes32("exact-caps");
        vm.prank(ADMINISTRATOR);
        controller.scheduleEconomicConfig(config, salt);
        vm.prank(STRANGER);
        controller.executeEconomicConfig(config, salt);

        EconomicConfig memory actual = controller.economicConfig();
        assertEq(actual.harvestServiceFeeWad, config.harvestServiceFeeWad);
        assertEq(actual.quoteCreatorShareWad, config.quoteCreatorShareWad);
        assertEq(actual.tokenMilestoneFundShareWad, config.tokenMilestoneFundShareWad);
        assertEq(actual.version, 2, "controller chooses monotonic version");
        assertEq(target.economicConfigCalls(), 1);
        assertEq(keccak256(abi.encode(target.economicConfig())), keccak256(abi.encode(actual)));
    }

    // --- Typed registry operations: derived, no scenario of its own ---

    function test_typedRegistryOperationsArePermissionlessAfterScheduling() public {
        GovernancePlugin plugin = new GovernancePlugin();
        bytes32 registerSalt = bytes32("register");
        vm.prank(ADMINISTRATOR);
        controller.scheduleRegisterPlugin(address(plugin), 0.2e18, GAS_LIMIT, PluginRole.PAYOUT, registerSalt);
        vm.prank(STRANGER);
        uint8 index =
            controller.executeRegisterPlugin(address(plugin), 0.2e18, GAS_LIMIT, PluginRole.PAYOUT, registerSalt);
        assertEq(index, 0);
        assertTrue(registry.isSelectable(index));

        bytes32 suspendSalt = bytes32("suspend");
        vm.prank(ADMINISTRATOR);
        controller.schedulePluginSuspension(index, true, suspendSalt);
        vm.prank(STRANGER);
        controller.executePluginSuspension(index, true, suspendSalt);
        assertFalse(registry.isSelectable(index));
    }

    // --- Global payout guard blocks governance: derived, no scenario of its own ---

    function test_globalPayoutGuardBlocksSchedulingAndExecution() public {
        bytes32 salt = bytes32("guarded");
        target.setPayoutDeliveryInFlight(true);
        vm.prank(ADMINISTRATOR);
        vm.expectRevert(ProtocolController.PayoutDeliveryInFlight.selector);
        controller.scheduleProtocolRecipient(NEXT_RECIPIENT, salt);

        target.setPayoutDeliveryInFlight(false);
        vm.prank(ADMINISTRATOR);
        controller.scheduleProtocolRecipient(NEXT_RECIPIENT, salt);
        target.setPayoutDeliveryInFlight(true);
        vm.expectRevert(ProtocolController.PayoutDeliveryInFlight.selector);
        controller.executeProtocolRecipient(NEXT_RECIPIENT, salt);
        assertTrue(controller.isScheduled(controller.hashProtocolRecipient(NEXT_RECIPIENT, salt)));
    }

    // --- Typed queue safety: derived, no scenario of its own ---

    function test_queueRejectsUnauthorizedDuplicateReplayAndZeroValues() public {
        bytes32 salt = bytes32("queue-safety");
        vm.prank(STRANGER);
        vm.expectRevert(ProtocolController.NotAdministrator.selector);
        controller.scheduleGovernanceDelay(1, salt);

        vm.prank(ADMINISTRATOR);
        bytes32 operationId = controller.scheduleGovernanceDelay(1, salt);
        vm.prank(ADMINISTRATOR);
        vm.expectRevert(ProtocolController.OperationAlreadyScheduled.selector);
        controller.scheduleGovernanceDelay(1, salt);
        controller.executeGovernanceDelay(1, salt);
        assertFalse(controller.isScheduled(operationId));
        vm.expectRevert(ProtocolController.OperationNotScheduled.selector);
        controller.executeGovernanceDelay(1, salt);
        vm.warp(block.timestamp + 1);

        vm.prank(ADMINISTRATOR);
        vm.expectRevert(ProtocolController.ZeroAddress.selector);
        controller.proposeAdministrator(address(0));

        bytes32 recipientSalt = bytes32("zero-recipient");
        vm.prank(ADMINISTRATOR);
        bytes32 zeroRecipientOperation = controller.scheduleProtocolRecipient(address(0), recipientSalt);
        vm.warp(controller.readyAt(zeroRecipientOperation));
        vm.expectRevert(ProtocolController.ZeroAddress.selector);
        controller.executeProtocolRecipient(address(0), recipientSalt);
        assertTrue(controller.isScheduled(zeroRecipientOperation));
    }

    function _setDelay(uint64 newDelay) private {
        bytes32 salt = keccak256(abi.encode("set-delay", newDelay, block.timestamp));
        vm.prank(ADMINISTRATOR);
        controller.scheduleGovernanceDelay(newDelay, salt);
        controller.executeGovernanceDelay(newDelay, salt);
    }

    function _config(uint64 serviceFee, uint64 creatorShare, uint64 tokenFund, uint64 version)
        private
        pure
        returns (EconomicConfig memory)
    {
        return EconomicConfig({
            harvestServiceFeeWad: serviceFee,
            quoteCreatorShareWad: creatorShare,
            tokenMilestoneFundShareWad: tokenFund,
            version: version
        });
    }
}
