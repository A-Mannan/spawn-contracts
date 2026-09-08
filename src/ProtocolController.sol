// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {EconomicConfig, PluginRole} from "./types/PayoutTypes.sol";
import {IProtocolConfigurationTarget, IPayoutPluginRegistry} from "./interfaces/IPayoutPluginRegistry.sol";

/// @title ProtocolController
/// @notice Typed, cancellable governance queue with readiness captured when an operation is scheduled.
contract ProtocolController {
    uint64 public constant MAX_HARVEST_SERVICE_FEE_WAD = 0.2e18;
    uint64 public constant MAX_QUOTE_CREATOR_SHARE_WAD = 0.9e18;
    uint64 public constant MAX_TOKEN_MILESTONE_FUND_SHARE_WAD = 0.5e18;

    uint8 public constant ACTION_REGISTER_PLUGIN = 1;
    uint8 public constant ACTION_SET_PLUGIN_SUSPENDED = 2;
    uint8 public constant ACTION_SET_ECONOMIC_CONFIG = 3;
    uint8 public constant ACTION_SET_PROTOCOL_RECIPIENT = 4;
    uint8 public constant ACTION_SET_DELAY = 5;

    IPayoutPluginRegistry public immutable registry;
    IProtocolConfigurationTarget public immutable target;

    address public administrator;
    address public pendingAdministrator;
    address public protocolRecipient;
    uint64 public governanceDelay;
    EconomicConfig private _economicConfig;

    mapping(bytes32 operationId => uint64 readyAtPlusOne) private _readyAtPlusOne;
    uint256 private _executionLock;

    event AdministratorProposed(address indexed administrator, address indexed pendingAdministrator);
    event AdministratorAccepted(address indexed previousAdministrator, address indexed administrator);
    event OperationScheduled(bytes32 indexed operationId, uint8 indexed action, bytes32 indexed salt, uint64 readyAt);
    event OperationCancelled(bytes32 indexed operationId);
    event OperationExecuted(bytes32 indexed operationId);
    event EconomicConfigUpdated(
        uint64 indexed version,
        uint64 harvestServiceFeeWad,
        uint64 quoteCreatorShareWad,
        uint64 tokenMilestoneFundShareWad
    );
    event ProtocolRecipientUpdated(address indexed previousRecipient, address indexed recipient);
    event GovernanceDelayUpdated(uint64 previousDelay, uint64 newDelay);

    error NotAdministrator();
    error NotPendingAdministrator();
    error ZeroAddress();
    error TimestampOverflow();
    error OperationAlreadyScheduled();
    error OperationNotScheduled();
    error OperationNotReady(uint64 readyAt);
    error InvalidEconomicConfig();
    error ReentrantExecution();
    error PayoutDeliveryInFlight();

    constructor(address administrator_, address protocolRecipient_, IPayoutPluginRegistry registry_, address target_) {
        if (
            administrator_ == address(0) || protocolRecipient_ == address(0) || address(registry_) == address(0)
                || target_ == address(0)
        ) revert ZeroAddress();
        administrator = administrator_;
        protocolRecipient = protocolRecipient_;
        registry = registry_;
        target = IProtocolConfigurationTarget(target_);
        _economicConfig = EconomicConfig({
            harvestServiceFeeWad: 0.1e18,
            quoteCreatorShareWad: 0.75e18,
            tokenMilestoneFundShareWad: 0.2e18,
            version: 1
        });
    }

    modifier onlyAdministrator() {
        if (msg.sender != administrator) revert NotAdministrator();
        _;
    }

    modifier nonReentrantExecution() {
        if (_executionLock != 0) revert ReentrantExecution();
        if (target.payoutDeliveryInFlight()) revert PayoutDeliveryInFlight();
        _executionLock = 1;
        _;
        _executionLock = 0;
    }

    function economicConfig() external view returns (EconomicConfig memory) {
        return _economicConfig;
    }

    function proposeAdministrator(address nextAdministrator) external onlyAdministrator nonReentrantExecution {
        if (nextAdministrator == address(0)) revert ZeroAddress();
        pendingAdministrator = nextAdministrator;
        emit AdministratorProposed(administrator, nextAdministrator);
    }

    function acceptAdministrator() external nonReentrantExecution {
        if (msg.sender != pendingAdministrator) revert NotPendingAdministrator();
        address previous = administrator;
        administrator = msg.sender;
        pendingAdministrator = address(0);
        emit AdministratorAccepted(previous, msg.sender);
    }

    function scheduleRegisterPlugin(address plugin, uint64 takeWad, uint32 gasLimit, PluginRole role, bytes32 salt)
        external
        onlyAdministrator
        nonReentrantExecution
        returns (bytes32 operationId)
    {
        operationId = hashRegisterPlugin(plugin, takeWad, gasLimit, role, salt);
        _schedule(operationId, ACTION_REGISTER_PLUGIN, salt);
    }

    function executeRegisterPlugin(address plugin, uint64 takeWad, uint32 gasLimit, PluginRole role, bytes32 salt)
        external
        nonReentrantExecution
        returns (uint8 index)
    {
        bytes32 operationId = hashRegisterPlugin(plugin, takeWad, gasLimit, role, salt);
        _consume(operationId);
        index = registry.registerPlugin(plugin, takeWad, gasLimit, role);
        emit OperationExecuted(operationId);
    }

    function hashRegisterPlugin(address plugin, uint64 takeWad, uint32 gasLimit, PluginRole role, bytes32 salt)
        public
        view
        returns (bytes32)
    {
        return _operationId(ACTION_REGISTER_PLUGIN, abi.encode(plugin, takeWad, gasLimit, role), salt);
    }

    function schedulePluginSuspension(uint8 index, bool suspended, bytes32 salt)
        external
        onlyAdministrator
        nonReentrantExecution
        returns (bytes32 operationId)
    {
        operationId = hashPluginSuspension(index, suspended, salt);
        _schedule(operationId, ACTION_SET_PLUGIN_SUSPENDED, salt);
    }

    function executePluginSuspension(uint8 index, bool suspended, bytes32 salt) external nonReentrantExecution {
        bytes32 operationId = hashPluginSuspension(index, suspended, salt);
        _consume(operationId);
        registry.setPluginSuspended(index, suspended);
        emit OperationExecuted(operationId);
    }

    function hashPluginSuspension(uint8 index, bool suspended, bytes32 salt) public view returns (bytes32) {
        return _operationId(ACTION_SET_PLUGIN_SUSPENDED, abi.encode(index, suspended), salt);
    }

    function scheduleEconomicConfig(EconomicConfig calldata config, bytes32 salt)
        external
        onlyAdministrator
        nonReentrantExecution
        returns (bytes32 operationId)
    {
        _validateEconomicConfig(config);
        if (config.version != _nextEconomicVersion()) revert InvalidEconomicConfig();
        operationId = hashEconomicConfig(config, salt);
        _schedule(operationId, ACTION_SET_ECONOMIC_CONFIG, salt);
    }

    function executeEconomicConfig(EconomicConfig calldata config, bytes32 salt) external nonReentrantExecution {
        bytes32 operationId = hashEconomicConfig(config, salt);
        _consume(operationId);
        _validateEconomicConfig(config);
        if (config.version != _nextEconomicVersion()) revert InvalidEconomicConfig();
        _economicConfig = config;
        target.setEconomicConfig(config);
        emit EconomicConfigUpdated(
            config.version, config.harvestServiceFeeWad, config.quoteCreatorShareWad, config.tokenMilestoneFundShareWad
        );
        emit OperationExecuted(operationId);
    }

    function hashEconomicConfig(EconomicConfig calldata config, bytes32 salt) public view returns (bytes32) {
        return _operationId(ACTION_SET_ECONOMIC_CONFIG, abi.encode(config), salt);
    }

    function scheduleProtocolRecipient(address recipient, bytes32 salt)
        external
        onlyAdministrator
        nonReentrantExecution
        returns (bytes32 operationId)
    {
        operationId = hashProtocolRecipient(recipient, salt);
        _schedule(operationId, ACTION_SET_PROTOCOL_RECIPIENT, salt);
    }

    function executeProtocolRecipient(address recipient, bytes32 salt) external nonReentrantExecution {
        bytes32 operationId = hashProtocolRecipient(recipient, salt);
        _consume(operationId);
        if (recipient == address(0)) revert ZeroAddress();
        address previous = protocolRecipient;
        protocolRecipient = recipient;
        target.setProtocolRecipient(recipient);
        emit ProtocolRecipientUpdated(previous, recipient);
        emit OperationExecuted(operationId);
    }

    function hashProtocolRecipient(address recipient, bytes32 salt) public view returns (bytes32) {
        return _operationId(ACTION_SET_PROTOCOL_RECIPIENT, abi.encode(recipient), salt);
    }

    function scheduleGovernanceDelay(uint64 newDelay, bytes32 salt)
        external
        onlyAdministrator
        nonReentrantExecution
        returns (bytes32 operationId)
    {
        operationId = hashGovernanceDelay(newDelay, salt);
        _schedule(operationId, ACTION_SET_DELAY, salt);
    }

    function executeGovernanceDelay(uint64 newDelay, bytes32 salt) external nonReentrantExecution {
        bytes32 operationId = hashGovernanceDelay(newDelay, salt);
        _consume(operationId);
        uint64 previous = governanceDelay;
        governanceDelay = newDelay;
        emit GovernanceDelayUpdated(previous, newDelay);
        emit OperationExecuted(operationId);
    }

    function hashGovernanceDelay(uint64 newDelay, bytes32 salt) public view returns (bytes32) {
        return _operationId(ACTION_SET_DELAY, abi.encode(newDelay), salt);
    }

    function cancel(bytes32 operationId) external onlyAdministrator nonReentrantExecution {
        if (_readyAtPlusOne[operationId] == 0) revert OperationNotScheduled();
        delete _readyAtPlusOne[operationId];
        emit OperationCancelled(operationId);
    }

    function readyAt(bytes32 operationId) public view returns (uint64) {
        uint64 encoded = _readyAtPlusOne[operationId];
        if (encoded == 0) revert OperationNotScheduled();
        return encoded - 1;
    }

    function isScheduled(bytes32 operationId) external view returns (bool) {
        return _readyAtPlusOne[operationId] != 0;
    }

    function _schedule(bytes32 operationId, uint8 action, bytes32 salt) private {
        if (_readyAtPlusOne[operationId] != 0) revert OperationAlreadyScheduled();
        uint256 timestamp = block.timestamp + governanceDelay;
        if (timestamp >= type(uint64).max) revert TimestampOverflow();
        uint64 capturedReadyAt = uint64(timestamp);
        _readyAtPlusOne[operationId] = capturedReadyAt + 1;
        emit OperationScheduled(operationId, action, salt, capturedReadyAt);
    }

    function _consume(bytes32 operationId) private {
        uint64 encoded = _readyAtPlusOne[operationId];
        if (encoded == 0) revert OperationNotScheduled();
        uint64 capturedReadyAt = encoded - 1;
        if (block.timestamp < capturedReadyAt) revert OperationNotReady(capturedReadyAt);
        delete _readyAtPlusOne[operationId];
    }

    function _nextEconomicVersion() private view returns (uint64 nextVersion) {
        uint64 currentVersion = _economicConfig.version;
        if (currentVersion == type(uint64).max) revert InvalidEconomicConfig();
        nextVersion = currentVersion + 1;
    }

    function _validateEconomicConfig(EconomicConfig calldata config) private pure {
        if (
            config.harvestServiceFeeWad > MAX_HARVEST_SERVICE_FEE_WAD
                || config.quoteCreatorShareWad > MAX_QUOTE_CREATOR_SHARE_WAD
                || config.tokenMilestoneFundShareWad > MAX_TOKEN_MILESTONE_FUND_SHARE_WAD
        ) revert InvalidEconomicConfig();
    }

    function _operationId(uint8 action, bytes memory parameters, bytes32 salt) private view returns (bytes32) {
        return keccak256(abi.encode(action, parameters, address(this), block.chainid, salt));
    }
}
