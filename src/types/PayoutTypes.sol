// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// Fixed-point denominator for payout and economic shares.
uint256 constant PAYOUT_WAD = 1e18;

/// @notice The complete global economic tuple consumed by harvest and fee routing.
/// @dev Governance replaces this tuple atomically and increments `version`.
struct EconomicConfig {
    uint64 harvestServiceFeeWad;
    uint64 quoteCreatorShareWad;
    uint64 tokenMilestoneFundShareWad;
    uint64 version;
}

/// @notice Registry classification. Only `PAYOUT` entries may be selected by a launch plan.
enum PluginRole {
    INVALID,
    PAYOUT,
    CREATOR_SYSTEM,
    UTILITY
}

/// @notice Stable append-only registry record. Only `suspended` may change after registration.
struct PluginEntry {
    address plugin;
    uint64 takeWad;
    uint32 gasLimit;
    bytes32 codeHash;
    PluginRole role;
    bool suspended;
}
