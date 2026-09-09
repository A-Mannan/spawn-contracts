// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolId} from "v4-core/src/types/PoolId.sol";

/// @title TransientLock
/// @notice Transaction-scoped locks in transient storage, namespaced per pool and per concern.
///
/// @dev Payout delivery is asynchronous and may invoke untrusted plugins after a pot has been redeemed.
/// The reference buyback plugin legitimately calls PoolManager, which re-enters this hook's callbacks;
/// those callbacks must suppress protocol work while the protocol-global payout guard is held. The
/// pool-scoped locks separately serialize lifecycle, settlement, collection, and claims.
///
/// Two distinct semantics, which is why this is not a single reentrancy modifier:
///
/// - {enter}/{exit} *reject* re-entry. Used by external entry points where a second concurrent invocation
///   is always a bug.
/// - {held} and {callbackWorkSuppressed} let swap callbacks *suppress* protocol work. Reverting a nested
///   callback would abort the plugin's legitimate swap; running normal work would expose lifecycle and
///   custody paths during untrusted execution.
///
/// Transient storage is the right primitive because the EVM guarantees no lock survives the transaction,
/// including on revert. It is also cheap enough for the hot swap path.
library TransientLock {
    /// @dev Namespace for every slot this library derives, so nothing collides with other transient
    /// usage in the hook or in v4 core itself.
    uint256 private constant _NAMESPACE = uint256(keccak256("milestone-launchpad.transient.lock.v1"));

    /// @notice Pool-scoped lifecycle settlement, including band retirement and exact-redemption unlocks.
    uint8 internal constant SETTLEMENT = 1;

    /// @notice The permissionless fee-collection sliver burn and re-add.
    uint8 internal constant FEE_COLLECTION = 2;

    /// @notice Creator and protocol claim paths.
    uint8 internal constant CLAIM = 3;

    /// @notice Launch-time curve minting and dev buy, performed under an explicit unlock.
    uint8 internal constant LAUNCH = 4;

    /// @dev Dedicated transaction-global slot for untrusted payout delivery. Unlike the concern locks
    /// above, this deliberately has no pool component: a plugin executing for one pool must not reach
    /// custody or lifecycle entry points for any other pool.
    bytes32 private constant _PAYOUT_DELIVERY_SLOT = keccak256("milestone-launchpad.transient.payout-delivery.v1");

    /// @notice Thrown when a pool-scoped guarded section is re-entered within the same transaction.
    error Reentrant(uint8 kind, PoolId poolId);

    /// @notice Thrown when payout delivery is entered recursively or a protected operation starts while
    /// untrusted plugin code is executing.
    error PayoutDeliveryInFlight();

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

    /// @notice Acquires the protocol-global payout-delivery guard.
    function enterPayoutDelivery() internal {
        bytes32 slot = _PAYOUT_DELIVERY_SLOT;
        uint256 current;
        assembly ("memory-safe") {
            current := tload(slot)
        }
        if (current != 0) revert PayoutDeliveryInFlight();
        assembly ("memory-safe") {
            tstore(slot, 1)
        }
    }

    /// @notice Releases the protocol-global payout-delivery guard. Idempotent like {exit}.
    function exitPayoutDelivery() internal {
        bytes32 slot = _PAYOUT_DELIVERY_SLOT;
        assembly ("memory-safe") {
            tstore(slot, 0)
        }
    }

    /// @notice Whether untrusted payout delivery is active anywhere in this protocol transaction.
    function payoutDeliveryInFlight() internal view returns (bool isHeld) {
        bytes32 slot = _PAYOUT_DELIVERY_SLOT;
        uint256 current;
        assembly ("memory-safe") {
            current := tload(slot)
        }
        isHeld = current != 0;
    }

    /// @notice Rejects a protected protocol operation while untrusted payout delivery is active.
    function requireNoPayoutDelivery() internal view {
        if (payoutDeliveryInFlight()) revert PayoutDeliveryInFlight();
    }

    /// @notice True when callback work must be suppressed.
    function callbackWorkSuppressed(PoolId poolId) internal view returns (bool) {
        return payoutDeliveryInFlight() || settlementInFlight(poolId);
    }

    /// @notice True when any settlement path is mid-flight for this pool, meaning the swap callbacks
    /// must skip ladder work.
    /// @dev Fee collection is included: its sliver burn and re-add moves liquidity, and a band deploy
    /// triggered in the middle of that would observe a half-adjusted position.
    function settlementInFlight(PoolId poolId) internal view returns (bool) {
        return held(SETTLEMENT, poolId) || held(FEE_COLLECTION, poolId);
    }
}
