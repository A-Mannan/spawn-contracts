// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Bounds, LaunchConfig, WAD} from "../types/LaunchTypes.sol";

/// @title LaunchConfigLib
/// @notice Validates a launch configuration against every remaining protocol bound.
///
/// @dev This function is the whole of the protocol's policy enforcement. Configuration is immutable
/// after launch and there is no governance path that can widen a bound (design Decision 10), so
/// anything this accepts is permanent for that pool's lifetime and anything it rejects can never occur.
///
/// design Decision 16 shrank it dramatically, and deliberately. It used to guard band counts, spacings,
/// widths, deploy windows, supply splits, proceeds splits, fee schedules and anti-snipe windows — a
/// configuration space no buyer ever priced differently, where every knob's degenerate value was a
/// foot-gun. All of that moved into the immutable {ProtocolTemplate}, so it is now unreachable rather
/// than merely bounded. What a creator can still choose is the token, the dev buy, and how a harvest
/// is split, and that is what this validates.
///
/// Each check names the `token-launch` spec scenario it satisfies.
library LaunchConfigLib {
    error ZeroCreator();
    error ZeroTotalSupply();
    error EmptyTokenMetadata();

    error DevBuyAboveCap(uint64 shareWad);
    error DevBuyVestingTooLong(uint32 seconds_);

    error HarvestSplitMustSumToWad(uint256 sum);
    error CreatorHarvestShareAboveCap(uint64 shareWad);
    error BuybackHarvestShareBelowFloor(uint64 shareWad);
    error BuybackHarvestShareAboveCap(uint64 shareWad);
    error ProtocolHarvestShareBelowFloor(uint64 shareWad);

    /// @notice Reverts unless every protocol bound holds.
    function validate(LaunchConfig memory config) internal pure {
        // The zero address can be neither an ECDSA recovery result nor a transaction sender, so this is
        // unreachable through {MilestoneColdPaths.launch} — but the revenue NFT would mint to it and the
        // creator ledger would accrue to it, so it is worth failing on rather than assuming.
        if (config.creator == address(0)) revert ZeroCreator();
        if (config.totalSupply == 0) revert ZeroTotalSupply();
        if (bytes(config.name).length == 0 || bytes(config.symbol).length == 0) revert EmptyTokenMetadata();

        _validateDevBuy(config);
        _validateHarvestSplit(
            config.harvestSplit.creatorWad,
            config.harvestSplit.buybackWad,
            config.harvestSplit.protocolWad,
            config.harvestSplit.lpWad
        );
    }

    /// @dev Scenario: "Dev buy is capped at 10% of supply". The cap fell from 20% to 10% with
    /// Decision 17: against a thin nested book a larger dev buy sweeps expensive bins and prices the
    /// creator's own entry, so the old cap was protecting nobody.
    ///
    /// The former "strictly below the bonding curve share" check is gone with the per-launch supply
    /// split. The template's 25% curve share against a 10% dev-buy cap keeps the public raise's
    /// inventory positive by construction rather than by validation.
    function _validateDevBuy(LaunchConfig memory config) private pure {
        if (config.devBuyShareWad > Bounds.MAX_DEV_BUY_SHARE_WAD) {
            revert DevBuyAboveCap(config.devBuyShareWad);
        }
        if (config.devBuyVestingSeconds > Bounds.MAX_DEV_BUY_VESTING_SECONDS) {
            revert DevBuyVestingTooLong(config.devBuyVestingSeconds);
        }
    }

    /// @dev Scenarios: "Harvest split that does not sum to one whole is rejected", "Creator share cap
    /// is enforced", and "Valid configuration at bound edges is accepted".
    ///
    /// The buyback floor is new with Decision 18's bounds: the buyback is the mechanism by which a
    /// milestone returns value to holders rather than only to the creator, so a launch cannot opt out
    /// of it entirely. Its 40% ceiling is retained from the pre-rework bounds because the design's
    /// Risks register measures the buyback's own price push against the next band's lower bound at
    /// exactly that share.
    function _validateHarvestSplit(uint64 creatorWad, uint64 buybackWad, uint64 protocolWad, uint64 lpWad)
        private
        pure
    {
        uint256 sum = uint256(creatorWad) + buybackWad + protocolWad + lpWad;
        if (sum != WAD) revert HarvestSplitMustSumToWad(sum);

        if (creatorWad > Bounds.MAX_CREATOR_HARVEST_SHARE_WAD) revert CreatorHarvestShareAboveCap(creatorWad);
        if (buybackWad < Bounds.MIN_BUYBACK_HARVEST_SHARE_WAD) revert BuybackHarvestShareBelowFloor(buybackWad);
        if (buybackWad > Bounds.MAX_BUYBACK_HARVEST_SHARE_WAD) revert BuybackHarvestShareAboveCap(buybackWad);
        if (protocolWad < Bounds.MIN_PROTOCOL_HARVEST_SHARE_WAD) revert ProtocolHarvestShareBelowFloor(protocolWad);
    }
}
