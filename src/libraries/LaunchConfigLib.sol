// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Bounds, LaunchConfig} from "../types/LaunchTypes.sol";

/// @title LaunchConfigLib
/// @notice Validates the non-registry fields of a launch configuration against immutable bounds.
///
/// @dev Configuration is immutable after launch and governance cannot widen these bounds. Registry-aware
/// validation is deliberately performed by {LaunchSupport}: it resolves every set `payoutPlan` bit,
/// rejects missing, suspended, or non-payout entries, enforces the eight-entry cap, and sums immutable
/// takes against WAD. This library handles only the creator, metadata, supply, and dev-buy fields that do
/// not require external state.
///
/// design Decision 16 shrank this validation deliberately. Band counts, spacing, widths, supply splits,
/// graduation economics, the static trading fee, and work caps moved into the immutable
/// {ProtocolTemplate}; they are unreachable launch choices rather than merely bounded ones.
///
/// Each check names the `token-launch` spec scenario it satisfies.
library LaunchConfigLib {
    error ZeroCreator();
    error ZeroTotalSupply();
    error SupplyNotFixed(uint256 requested);
    error EmptyTokenMetadata();

    error DevBuyAboveCap(uint64 shareWad);

    /// @notice Reverts unless every non-registry launch bound holds.
    function validate(LaunchConfig memory config) internal pure {
        // The zero address can be neither an ECDSA recovery result nor a transaction sender, so this is
        // unreachable through {MilestoneColdPaths.launch} — but the revenue NFT would mint to it and the
        // creator ledger would accrue to it, so it is worth failing on rather than assuming.
        if (config.creator == address(0)) revert ZeroCreator();
        if (config.totalSupply == 0) revert ZeroTotalSupply();
        // Supply is a protocol constant, not a launch choice: the full-range and wall tick bounds are
        // derived from the graduation valuation this supply produces, so the two must move together.
        if (config.totalSupply != Bounds.FIXED_TOTAL_SUPPLY) revert SupplyNotFixed(config.totalSupply);
        if (bytes(config.name).length == 0 || bytes(config.symbol).length == 0) revert EmptyTokenMetadata();

        if (config.devBuyShareWad > Bounds.MAX_DEV_BUY_SHARE_WAD) {
            revert DevBuyAboveCap(config.devBuyShareWad);
        }
    }
}
