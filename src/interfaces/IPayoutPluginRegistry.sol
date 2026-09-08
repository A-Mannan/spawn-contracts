// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {EconomicConfig, PluginEntry, PluginRole} from "../types/PayoutTypes.sol";

interface IPayoutPluginRegistry {
    function administrator() external view returns (address);
    function pendingAdministrator() external view returns (address);
    function entryCount() external view returns (uint16);
    function entry(uint8 index) external view returns (PluginEntry memory);
    function isSelectable(uint8 index) external view returns (bool);
    function resolveSelectable(uint8 index) external view returns (PluginEntry memory);

    function registerPlugin(address plugin, uint64 takeWad, uint32 gasLimit, PluginRole role)
        external
        returns (uint8 index);
    function setPluginSuspended(uint8 index, bool suspended) external;
    function proposeAdministrator(address nextAdministrator) external;
    function acceptAdministrator() external;
}

interface IProtocolConfigurationTarget {
    function payoutDeliveryInFlight() external view returns (bool);
    function setEconomicConfig(EconomicConfig calldata config) external;
    function setProtocolRecipient(address recipient) external;
}
