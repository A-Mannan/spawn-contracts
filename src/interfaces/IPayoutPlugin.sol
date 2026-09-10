// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolId} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

/// @notice Destination interface used by the payout satellite.
/// @dev A plugin receives no routing calldata: the authenticated hook supplies only the source pool,
/// source launch token, and the ETH allocation fixed by the pool's immutable payout plan.
interface IPayoutPlugin {
    function onPayout(PoolId poolId, address token) external payable;
}

/// @notice Minimal source-pool lookup expected from the launch hook by reference plugins.
/// @dev Keeping this view separate from the hook implementation prevents plugins from depending on
/// mutable hook storage structs or implementation-only getters.
interface IPayoutPoolLookup {
    function payoutPool(PoolId poolId) external view returns (PoolKey memory key, address token);
}
