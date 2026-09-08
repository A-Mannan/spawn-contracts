// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolId} from "v4-core/src/types/PoolId.sol";

/// @title TransientLock
/// @notice Transaction-scoped locks in transient storage, namespaced per pool and per concern.
///
/// @dev design.md Decision 7. These paths nest by design: a harvest settles inside `afterSwap`, its
/// buyback share calls `poolManager.swap`, and that nested swap re-enters this hook's own
/// `beforeSwap`/`afterSwap`. Guards are therefore load-bearing rather than defensive boilerplate.
///
/// Two distinct semantics, which is why this is not a single reentrancy modifier:
///
/// - {enter}/{exit} *reject* re-entry. Used by external entry points — claims, fee collection,
///   graduation — where a second concurrent invocation is always a bug.
/// - {held} lets a caller *suppress* its own work. Used by the swap callbacks: while a settlement is
///   in flight, band deployment and harvest detection must quietly skip, not revert. Reverting there
///   would abort the very harvest that opened the lock (Decision 6).
///
/// Transient storage is the right primitive because the guarantee we need — "no lock survives the
/// transaction" — is provided by the EVM rather than by our own cleanup being correct on every
/// revert path. It is also cheap enough to sit on the hot swap path.
library TransientLock {
    /// @dev Namespace for every slot this library derives, so nothing collides with other transient
    /// usage in the hook or in v4 core itself.
    uint256 private constant _NAMESPACE = uint256(keccak256("milestone-launchpad.transient.lock.v1"));

    /// @notice Harvest settlement, including the nested buyback swap.
    uint8 internal constant SETTLEMENT = 1;

    /// @notice The permissionless fee-collection sliver burn and re-add.
    uint8 internal constant FEE_COLLECTION = 2;

    /// @notice Creator and protocol claim paths.
    uint8 internal constant CLAIM = 3;

    /// @notice Launch-time curve minting and dev buy, performed under an explicit unlock.
    uint8 internal constant LAUNCH = 4;

    /// @notice Thrown when a guarded section is re-entered within the same transaction.
    error Reentrant(uint8 kind, PoolId poolId);

    /// @dev Slot for a (kind, pool) pair. Per-pool rather than global: a settlement on one pool must
    /// never suppress or block activity on another.
    function _slot(uint8 kind, PoolId poolId) private pure returns (bytes32 slot) {
        slot = keccak256(abi.encode(_NAMESPACE, kind, poolId));
    }

    /// @notice Acquires a lock, reverting if it is already held.
    function enter(uint8 kind, PoolId poolId) internal {
        bytes32 slot = _slot(kind, poolId);
        uint256 current;
        assembly ("memory-safe") {
            current := tload(slot)
        }
        if (current != 0) revert Reentrant(kind, poolId);
        assembly ("memory-safe") {
            tstore(slot, 1)
        }
    }

    /// @notice Releases a lock. Idempotent; safe to call when not held.
    function exit(uint8 kind, PoolId poolId) internal {
        bytes32 slot = _slot(kind, poolId);
        assembly ("memory-safe") {
            tstore(slot, 0)
        }
    }

    /// @notice Whether a lock is currently held, for callers that suppress rather than revert.
    function held(uint8 kind, PoolId poolId) internal view returns (bool isHeld) {
        bytes32 slot = _slot(kind, poolId);
        uint256 current;
        assembly ("memory-safe") {
            current := tload(slot)
        }
        isHeld = current != 0;
    }

    /// @notice True when any settlement path is mid-flight for this pool, meaning the swap callbacks
    /// must skip ladder work.
    /// @dev Fee collection is included: its sliver burn and re-add moves liquidity, and a band deploy
    /// triggered in the middle of that would observe a half-adjusted position.
    function settlementInFlight(PoolId poolId) internal view returns (bool) {
        return held(SETTLEMENT, poolId) || held(FEE_COLLECTION, poolId);
    }
}
