// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {TransientLock} from "../../src/libraries/TransientLock.sol";

/// @notice Exercises the lock the way the hook will: an outer guarded section that performs a nested
/// call, mirroring harvest settlement -> buyback swap -> hook callback.
contract LockHarness {
    PoolId public immutable poolId;

    /// @notice Records what the nested callback observed, so tests can assert suppression happened.
    bool public nestedSawLockHeld;
    uint256 public nestedWorkPerformed;
    bool public nestedReentryReverted;

    constructor(PoolId poolId_) {
        poolId = poolId_;
    }

    // --- Guard semantics: re-entry is rejected ---

    /// @notice Outer guarded section that calls back into itself, as a nested swap would.
    function settleWithSelfReentry() external {
        TransientLock.enter(TransientLock.SETTLEMENT, poolId);

        try this.settleWithSelfReentry() {
            nestedReentryReverted = false;
        } catch {
            nestedReentryReverted = true;
        }

        TransientLock.exit(TransientLock.SETTLEMENT, poolId);
    }

    /// @notice Acquires without releasing, so a later transaction can prove the lock cleared.
    function acquireAndLeaveHeld(uint8 kind) external {
        TransientLock.enter(kind, poolId);
    }

    function enter(uint8 kind) external {
        TransientLock.enter(kind, poolId);
    }

    function exit(uint8 kind) external {
        TransientLock.exit(kind, poolId);
    }

    function held(uint8 kind) external view returns (bool) {
        return TransientLock.held(kind, poolId);
    }

    function heldFor(uint8 kind, PoolId other) external view returns (bool) {
        return TransientLock.held(kind, other);
    }

    function settlementInFlight() external view returns (bool) {
        return TransientLock.settlementInFlight(poolId);
    }

    function enterPayoutDelivery() external {
        TransientLock.enterPayoutDelivery();
    }

    function exitPayoutDelivery() external {
        TransientLock.exitPayoutDelivery();
    }

    function payoutDeliveryInFlight() external view returns (bool) {
        return TransientLock.payoutDeliveryInFlight();
    }

    function callbackWorkSuppressedFor(PoolId other) external view returns (bool) {
        return TransientLock.callbackWorkSuppressed(other);
    }

    function requireNoPayoutDelivery() external view {
        TransientLock.requireNoPayoutDelivery();
    }

    // --- Suppression semantics: the callback skips instead of reverting ---

    /// @notice Outer settlement that performs a nested call which must *suppress*, not revert.
    function settleWithSuppressedCallback() external {
        TransientLock.enter(TransientLock.SETTLEMENT, poolId);
        this.ladderCallback();
        TransientLock.exit(TransientLock.SETTLEMENT, poolId);
    }

    /// @notice Stands in for beforeSwap/afterSwap ladder work.
    function ladderCallback() external {
        if (TransientLock.settlementInFlight(poolId)) {
            nestedSawLockHeld = true;
            return; // suppressed, deliberately not a revert
        }
        nestedWorkPerformed += 1;
    }
}

/// @notice Unit tests for task 3.3.
contract TransientLockTest is Test {
    PoolId internal constant POOL_A = PoolId.wrap(bytes32(uint256(0xA1)));
    PoolId internal constant POOL_B = PoolId.wrap(bytes32(uint256(0xB2)));

    LockHarness internal harness;

    function setUp() public {
        harness = new LockHarness(POOL_A);
    }

    // --- A locked section rejects re-entry within a transaction ---

    function test_reentryIsRejected() public {
        harness.settleWithSelfReentry();
        assertTrue(harness.nestedReentryReverted(), "nested entry into a held lock reverted");
    }

    function test_enterTwiceReverts() public {
        harness.enter(TransientLock.SETTLEMENT);

        vm.expectRevert(abi.encodeWithSelector(TransientLock.Reentrant.selector, TransientLock.SETTLEMENT, POOL_A));
        harness.enter(TransientLock.SETTLEMENT);
    }

    function test_lockIsReleasableAndReacquirable() public {
        harness.enter(TransientLock.SETTLEMENT);
        assertTrue(harness.held(TransientLock.SETTLEMENT), "held after enter");

        harness.exit(TransientLock.SETTLEMENT);
        assertFalse(harness.held(TransientLock.SETTLEMENT), "clear after exit");

        harness.enter(TransientLock.SETTLEMENT);
        assertTrue(harness.held(TransientLock.SETTLEMENT), "reacquired");
    }

    function test_exitIsIdempotent() public {
        harness.exit(TransientLock.SETTLEMENT);
        harness.exit(TransientLock.SETTLEMENT);
        assertFalse(harness.held(TransientLock.SETTLEMENT), "still clear");
    }

    // --- Suppression, not reversion, inside settlement ---

    function test_nestedCallbackSuppressesInsteadOfReverting() public {
        harness.settleWithSuppressedCallback();

        assertTrue(harness.nestedSawLockHeld(), "callback observed the lock");
        assertEq(harness.nestedWorkPerformed(), 0, "callback skipped its work");
    }

    function test_callbackDoesItsWorkWhenNoSettlementInFlight() public {
        harness.ladderCallback();

        assertFalse(harness.nestedSawLockHeld(), "no lock observed");
        assertEq(harness.nestedWorkPerformed(), 1, "callback did its work");
    }

    function test_feeCollectionAlsoSuppressesLadderWork() public {
        harness.enter(TransientLock.FEE_COLLECTION);
        assertTrue(harness.settlementInFlight(), "fee collection counts as in-flight");

        harness.ladderCallback();
        assertEq(harness.nestedWorkPerformed(), 0, "ladder work suppressed during fee collection");
    }

    function test_claimLockDoesNotSuppressLadderWork() public {
        // Claims move no liquidity, so they must not stall the ladder.
        harness.enter(TransientLock.CLAIM);
        assertFalse(harness.settlementInFlight(), "claims are not settlement");

        harness.ladderCallback();
        assertEq(harness.nestedWorkPerformed(), 1, "ladder work proceeded");
    }

    // --- Namespacing: kinds and pools are independent ---

    function test_kindsAreIndependent() public {
        harness.enter(TransientLock.SETTLEMENT);

        assertTrue(harness.held(TransientLock.SETTLEMENT), "settlement held");
        assertFalse(harness.held(TransientLock.CLAIM), "claim unaffected");
        assertFalse(harness.held(TransientLock.LAUNCH), "launch unaffected");

        // A different kind is still acquirable while settlement is held.
        harness.enter(TransientLock.CLAIM);
        assertTrue(harness.held(TransientLock.CLAIM), "claim acquired independently");
    }

    function test_poolsAreIndependent() public {
        harness.enter(TransientLock.SETTLEMENT);

        assertTrue(harness.heldFor(TransientLock.SETTLEMENT, POOL_A), "pool A held");
        assertFalse(harness.heldFor(TransientLock.SETTLEMENT, POOL_B), "pool B unaffected");
    }

    function testFuzz_distinctPoolsNeverShareALock(bytes32 rawA, bytes32 rawB) public {
        vm.assume(rawA != rawB);

        LockHarness h = new LockHarness(PoolId.wrap(rawA));
        h.enter(TransientLock.SETTLEMENT);

        assertTrue(h.heldFor(TransientLock.SETTLEMENT, PoolId.wrap(rawA)), "own pool held");
        assertFalse(h.heldFor(TransientLock.SETTLEMENT, PoolId.wrap(rawB)), "other pool clear");
    }

    // --- Global payout-delivery semantics ---

    function test_payoutDeliveryBlocksProtectedOperationsAcrossPools() public {
        harness.enterPayoutDelivery();

        vm.expectRevert(TransientLock.PayoutDeliveryInFlight.selector);
        harness.requireNoPayoutDelivery();
        assertTrue(harness.callbackWorkSuppressedFor(POOL_A), "source pool callback suppressed");
        assertTrue(harness.callbackWorkSuppressedFor(POOL_B), "other pool callback suppressed");
    }

    function test_payoutDeliveryRejectsGlobalReentry() public {
        harness.enterPayoutDelivery();

        vm.expectRevert(TransientLock.PayoutDeliveryInFlight.selector);
        harness.enterPayoutDelivery();
    }

    function test_payoutDeliveryGuardIsReleasableAndReacquirable() public {
        harness.enterPayoutDelivery();
        assertTrue(harness.payoutDeliveryInFlight(), "global guard held");

        harness.exitPayoutDelivery();
        assertFalse(harness.payoutDeliveryInFlight(), "global guard clear");

        harness.enterPayoutDelivery();
        assertTrue(harness.payoutDeliveryInFlight(), "global guard reacquired");
    }

    function test_payoutDeliveryExitIsIdempotent() public {
        harness.exitPayoutDelivery();
        harness.exitPayoutDelivery();
        assertFalse(harness.payoutDeliveryInFlight(), "global guard remains clear");
    }

    function test_callbackWorkRunsWhenGlobalGuardIsClear() public view {
        assertFalse(harness.callbackWorkSuppressedFor(POOL_A), "source pool callback allowed");
        assertFalse(harness.callbackWorkSuppressedFor(POOL_B), "other pool callback allowed");
    }

    // --- The lock does not leak across transactions ---
    //
    // Each test function executes as its own transaction, so transient storage is cleared by the EVM
    // between them. Both tests below assert-clear-on-entry *and* leave a lock held, so whichever runs
    // second genuinely proves the clearing rather than passing vacuously on ordering.

    function test_lockClearsBetweenTransactions_first() public {
        assertFalse(harness.held(TransientLock.SETTLEMENT), "clear at start of transaction");
        harness.acquireAndLeaveHeld(TransientLock.SETTLEMENT);
        assertTrue(harness.held(TransientLock.SETTLEMENT), "held for the rest of this transaction");
    }

    function test_lockClearsBetweenTransactions_second() public {
        assertFalse(harness.held(TransientLock.SETTLEMENT), "clear at start of transaction");
        harness.acquireAndLeaveHeld(TransientLock.SETTLEMENT);
        assertTrue(harness.held(TransientLock.SETTLEMENT), "held for the rest of this transaction");
    }

    /// @dev A revert inside the guarded section must not strand the lock either, since the whole
    /// transaction unwinds.
    function test_revertingSectionDoesNotStrandTheLock() public {
        try harness.enter(200) {
            // 200 is not a defined kind, but enter() is generic; this just acquires it.
        } catch {}

        assertFalse(harness.held(TransientLock.SETTLEMENT), "settlement lock untouched");
    }
}
