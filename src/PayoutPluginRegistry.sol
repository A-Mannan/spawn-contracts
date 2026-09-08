// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PAYOUT_WAD, PluginEntry, PluginRole} from "./types/PayoutTypes.sol";
import {IPayoutPluginRegistry} from "./interfaces/IPayoutPluginRegistry.sol";

/// @title PayoutPluginRegistry
/// @notice Bounded append-only registry whose indices and payout terms never change.
contract PayoutPluginRegistry is IPayoutPluginRegistry {
    /// @dev A stipend must leave useful gas for the plugin without making outer flush accounting unsafe.
    uint32 public constant MIN_PLUGIN_GAS_LIMIT = 25_000;
    uint32 public constant MAX_PLUGIN_GAS_LIMIT = 500_000;
    uint16 public constant MAX_ENTRIES = 256;

    address public override administrator;
    address public override pendingAdministrator;
    uint16 public override entryCount;

    mapping(uint8 index => PluginEntry value) private _entries;
    mapping(address plugin => uint16 indexPlusOne) public indexPlusOne;
    uint256 private _mutationLock;

    event PluginRegistered(
        uint8 indexed index, address indexed plugin, uint64 takeWad, uint32 gasLimit, bytes32 codeHash, PluginRole role
    );
    event PluginSuspensionSet(uint8 indexed index, bool suspended);
    event AdministratorProposed(address indexed administrator, address indexed pendingAdministrator);
    event AdministratorAccepted(address indexed previousAdministrator, address indexed administrator);

    error NotAdministrator();
    error NotPendingAdministrator();
    error RegistryFull();
    error ZeroPlugin();
    error DuplicatePlugin(address plugin, uint8 index);
    error PluginHasNoCode();
    error InvalidRole();
    error InvalidTake();
    error UnsafeGasLimit();
    error ProxyLikePlugin();
    error EntryDoesNotExist();
    error EntryNotSelectable();
    error ReentrantMutation();

    constructor(address administrator_) {
        if (administrator_ == address(0)) revert ZeroPlugin();
        administrator = administrator_;
    }

    modifier onlyAdministrator() {
        if (msg.sender != administrator) revert NotAdministrator();
        _;
    }

    modifier nonReentrantMutation() {
        if (_mutationLock != 0) revert ReentrantMutation();
        _mutationLock = 1;
        _;
        _mutationLock = 0;
    }

    function proposeAdministrator(address nextAdministrator) external override onlyAdministrator nonReentrantMutation {
        if (nextAdministrator == address(0)) revert ZeroPlugin();
        pendingAdministrator = nextAdministrator;
        emit AdministratorProposed(administrator, nextAdministrator);
    }

    function acceptAdministrator() external override nonReentrantMutation {
        if (msg.sender != pendingAdministrator) revert NotPendingAdministrator();
        address previous = administrator;
        administrator = msg.sender;
        pendingAdministrator = address(0);
        emit AdministratorAccepted(previous, msg.sender);
    }

    function entry(uint8 index) external view override returns (PluginEntry memory) {
        if (uint16(index) >= entryCount) revert EntryDoesNotExist();
        return _entries[index];
    }

    /// @notice Whether a bit may be selected by a new launch right now.
    /// @dev Runtime code identity is part of selection: destroyed or changed code is not valid.
    function isSelectable(uint8 index) public view override returns (bool) {
        if (uint16(index) >= entryCount) return false;
        PluginEntry storage stored = _entries[index];
        return _selectable(stored);
    }

    /// @notice Resolve an entry for immediate use and enforce its current code identity.
    function resolveSelectable(uint8 index) external view override returns (PluginEntry memory resolved) {
        if (uint16(index) >= entryCount) revert EntryDoesNotExist();
        PluginEntry storage stored = _entries[index];
        if (!_selectable(stored)) revert EntryNotSelectable();
        resolved = stored;
    }

    function registerPlugin(address plugin, uint64 takeWad, uint32 gasLimit, PluginRole role)
        external
        override
        onlyAdministrator
        nonReentrantMutation
        returns (uint8 index)
    {
        uint16 count = entryCount;
        if (count == MAX_ENTRIES) revert RegistryFull();
        if (plugin == address(0)) revert ZeroPlugin();
        uint16 existing = indexPlusOne[plugin];
        if (existing != 0) revert DuplicatePlugin(plugin, uint8(existing - 1));
        if (plugin.code.length == 0) revert PluginHasNoCode();
        if (role == PluginRole.INVALID) revert InvalidRole();
        if (takeWad > PAYOUT_WAD || (role != PluginRole.PAYOUT && takeWad != 0)) revert InvalidTake();
        if (gasLimit < MIN_PLUGIN_GAS_LIMIT || gasLimit > MAX_PLUGIN_GAS_LIMIT) revert UnsafeGasLimit();
        if (_isProxyLike(plugin)) revert ProxyLikePlugin();

        bytes32 codeHash = plugin.codehash;
        index = uint8(count);
        _entries[index] = PluginEntry({
            plugin: plugin,
            takeWad: takeWad,
            gasLimit: gasLimit,
            codeHash: codeHash,
            role: role,
            suspended: false
        });
        indexPlusOne[plugin] = count + 1;
        entryCount = count + 1;

        emit PluginRegistered(index, plugin, takeWad, gasLimit, codeHash, role);
    }

    function setPluginSuspended(uint8 index, bool suspended) external override onlyAdministrator nonReentrantMutation {
        if (uint16(index) >= entryCount) revert EntryDoesNotExist();
        _entries[index].suspended = suspended;
        emit PluginSuspensionSet(index, suspended);
    }

    function _selectable(PluginEntry storage stored) private view returns (bool) {
        return !stored.suspended && stored.role == PluginRole.PAYOUT && stored.plugin.codehash == stored.codeHash
            && stored.codeHash != bytes32(0);
    }

    /// @dev Reject common delegate/proxy bytecode patterns. Code-hash checks remain the runtime backstop.
    function _isProxyLike(address plugin) private view returns (bool) {
        bytes memory code = plugin.code;
        uint256 length = code.length;
        for (uint256 cursor; cursor < length;) {
            uint8 opcode = uint8(code[cursor]);
            if (opcode == 0xf2 || opcode == 0xf4) return true;
            if (opcode >= 0x60 && opcode <= 0x7f) cursor += uint256(opcode) - 0x5f;
            unchecked {
                ++cursor;
            }
        }

        // ERC-1167 minimal proxies include the implementation address after this 10-byte prefix.
        bytes10 clonePrefix = 0x363d3d373d3d3d363d73;
        if (length >= 10) {
            bytes10 prefix;
            assembly ("memory-safe") {
                prefix := mload(add(code, 0x20))
            }
            if (prefix == clonePrefix) return true;
        }

        return false;
    }
}
