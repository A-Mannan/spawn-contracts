// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolId} from "v4-core/src/types/PoolId.sol";
import {MilestoneBase} from "../../src/MilestoneBase.sol";
import {MilestoneHook} from "../../src/MilestoneHook.sol";
import {HarnessLaunchpadTest} from "../HarnessFixtures.sol";

/// @notice Holder contract that tries to re-enter the claim from its receive hook.
contract ReentrantHolder {
    MilestoneHook internal immutable hook;
    PoolId internal immutable poolId;

    bool public reentryAttempted;
    bool public reentryReverted;
    uint256 public received;

    constructor(MilestoneHook hook_, PoolId poolId_) {
        hook = hook_;
        poolId = poolId_;
    }

    function claim() external returns (uint256) {
        return hook.claimCreator(poolId);
    }

    receive() external payable {
        received += msg.value;

        if (!reentryAttempted) {
            reentryAttempted = true;
            try hook.claimCreator(poolId) {
                reentryReverted = false;
            } catch {
                reentryReverted = true;
            }
        }
    }
}

/// @notice Holder contract that refuses ETH, to prove a failed payout reverts rather than silently
/// zeroing the balance.
contract RejectingHolder {
    MilestoneHook internal immutable hook;

    constructor(MilestoneHook hook_) {
        hook = hook_;
    }

    function claim(PoolId poolId) external returns (uint256) {
        return hook.claimCreator(poolId);
    }

    receive() external payable {
        revert("no thanks");
    }
}

/// @notice Unit tests for tasks 3.4, 3.5 and 3.6 — the claim ledger, the claim entry points, and
/// transfer-carries-balance semantics.
///
/// @dev The ledger is keyed by `PoolId` and reads nothing else about a pool, so the two pools here are
/// synthetic ids with nothing but a revenue NFT behind them. That is the point: it keeps
/// "balances are isolated per pool" a statement about the ledger rather than about two launches, and it
/// gives the isolation tests a second pool without a second launch. The fixture's real launch still
/// stands behind {HOOK_ADDR}, so the claim path under test is the deployed one.
contract ClaimsTest is HarnessLaunchpadTest {
    PoolId internal constant POOL_A = PoolId.wrap(bytes32(uint256(0xA1)));
    PoolId internal constant POOL_B = PoolId.wrap(bytes32(uint256(0xB2)));

    /// @dev Cached so they are never evaluated as an argument inside a `vm.prank`/`vm.expectRevert`
    /// call — a nested external call there consumes the cheatcode instead of the intended call.
    uint256 internal tokenIdA;
    uint256 internal tokenIdB;

    function setUp() public override {
        super.setUp();

        tokenIdA = harness.mintRevenueNft(POOL_A, creator);
        tokenIdB = harness.mintRevenueNft(POOL_B, creator);

        // Custody is direct: the hook holds the ETH it will pay out. Topped up rather than overwritten,
        // so whatever the fixture's launch left in custody survives.
        vm.deal(HOOK_ADDR, HOOK_ADDR.balance + 1_000 ether);
    }

    // --- Scenario: Direct creator sources aggregate ---
    // (with the ledger's derived guards: credits sum, a zero accrual is a no-op, and direct
    // creator balances remain isolated by pool)

    function test_creditsAccumulate() public {
        harness.accrueCreator(POOL_A, 1 ether);
        harness.accrueCreator(POOL_A, 2 ether);
        harness.accrueCreator(POOL_A, 3 ether);

        assertEq(hook.creatorClaimable(POOL_A), 6 ether, "credits summed");
    }

    /// @dev Direct sources aggregate into the pool's creator ledger.
    function test_directCreatorSourcesAggregate() public {
        harness.accrueCreatorFrom(POOL_A, 5 ether, MilestoneBase.AccrualSource.CURVE_PROCEEDS);
        harness.accrueCreatorFrom(POOL_A, 1 ether, MilestoneBase.AccrualSource.SWAP_FEES);
        harness.accrueCreatorFrom(POOL_A, 2 ether, MilestoneBase.AccrualSource.SWAP_FEES);
        harness.accrueCreatorFrom(POOL_A, 3 ether, MilestoneBase.AccrualSource.CURVE_PROCEEDS);

        assertEq(hook.creatorClaimable(POOL_A), 11 ether, "direct sources aggregate into one balance");
    }

    function test_creatorAndGlobalProtocolLedgersAreIndependent() public {
        harness.accrueCreator(POOL_A, 7 ether);
        harness.accrueProtocol(POOL_A, 3 ether);

        assertEq(hook.creatorClaimable(POOL_A), 7 ether, "creator");
        assertEq(hook.protocolClaimable(), 3 ether, "global protocol");
    }

    function test_zeroAccrualIsANoOp() public {
        harness.accrueCreator(POOL_A, 0);
        assertEq(hook.creatorClaimable(POOL_A), 0, "nothing credited");
    }

    function testFuzz_ledgerIsPerPool(uint128 amountA, uint128 amountB) public {
        harness.accrueCreator(POOL_A, amountA);
        harness.accrueCreator(POOL_B, amountB);

        assertEq(hook.creatorClaimable(POOL_A), amountA, "pool A");
        assertEq(hook.creatorClaimable(POOL_B), amountB, "pool B");
    }

    // --- Scenario: Current holder claims direct revenue ---

    /// @dev Spec: "Current holder claims direct revenue".
    function test_currentHolderClaims() public {
        harness.accrueCreator(POOL_A, 10 ether);
        uint256 before = creator.balance;

        vm.prank(creator);
        uint256 claimed = hook.claimCreator(POOL_A);

        assertEq(claimed, 10 ether, "returned amount");
        assertEq(creator.balance - before, 10 ether, "holder paid");
        assertEq(hook.creatorClaimable(POOL_A), 0, "balance zeroed");
    }

    // --- Scenario: Non-holder direct claim is rejected ---

    /// @dev Spec: "Non-holder direct claim is rejected".
    function test_nonHolderClaimRejected() public {
        harness.accrueCreator(POOL_A, 10 ether);

        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(MilestoneBase.NotRevenueNftHolder.selector, POOL_A, STRANGER));
        hook.claimCreator(POOL_A);

        assertEq(hook.creatorClaimable(POOL_A), 10 ether, "balance untouched");
    }

    // --- Scenario: Empty direct claim is harmless ---

    /// @dev Spec: "Empty direct claim is harmless".
    function test_claimingEmptyBalanceTransfersNothing() public {
        uint256 before = creator.balance;

        vm.prank(creator);
        uint256 claimed = hook.claimCreator(POOL_A);

        assertEq(claimed, 0, "nothing claimed");
        assertEq(creator.balance, before, "nothing transferred");
    }

    // --- Scenario: Reentrant claim cannot exceed the ledger ---

    /// @dev Spec: "Reentrant claim cannot exceed the ledger".
    function test_claimCannotExceedAccruedBalance() public {
        harness.accrueCreator(POOL_A, 4 ether);
        uint256 before = creator.balance;

        vm.prank(creator);
        hook.claimCreator(POOL_A);

        vm.prank(creator);
        uint256 second = hook.claimCreator(POOL_A);

        assertEq(second, 0, "second claim transfers nothing");
        assertEq(creator.balance - before, 4 ether, "paid exactly once");
    }

    function test_reentrantClaimIsBlockedAndPaysOnce() public {
        ReentrantHolder holder = new ReentrantHolder(hook, POOL_A);

        vm.prank(creator);
        nft.transferFrom(creator, address(holder), tokenIdA);

        harness.accrueCreator(POOL_A, 5 ether);
        holder.claim();

        assertTrue(holder.reentryAttempted(), "re-entry was attempted");
        assertTrue(holder.reentryReverted(), "re-entry was rejected");
        assertEq(holder.received(), 5 ether, "paid exactly once");
        assertEq(hook.creatorClaimable(POOL_A), 0, "balance zeroed once");
    }

    function test_failedPayoutRevertsRatherThanBurningTheBalance() public {
        RejectingHolder holder = new RejectingHolder(hook);

        vm.prank(creator);
        nft.transferFrom(creator, address(holder), tokenIdA);

        harness.accrueCreator(POOL_A, 5 ether);

        vm.expectRevert();
        holder.claim(POOL_A);

        // The whole transaction unwound, so the balance is still there to claim later.
        assertEq(hook.creatorClaimable(POOL_A), 5 ether, "balance preserved");
    }

    // --- Scenario: New direct accrual remains claimable ---

    /// @dev Spec: "New direct accrual remains claimable".
    function test_accrualAfterClaimIsClaimableAgain() public {
        uint256 before = creator.balance;

        harness.accrueCreator(POOL_A, 2 ether);
        vm.prank(creator);
        hook.claimCreator(POOL_A);

        harness.accrueCreator(POOL_A, 3 ether);
        vm.prank(creator);
        uint256 claimed = hook.claimCreator(POOL_A);

        assertEq(claimed, 3 ether, "new accrual claimable");
        assertEq(creator.balance - before, 5 ether, "both claims paid");
    }

    // --- Scenario: Current recipient claims globally ---

    /// @dev Spec: "Current recipient claims globally".
    function test_protocolRecipientClaimsGlobalLedger() public {
        harness.accrueProtocol(POOL_A, 3 ether);
        harness.accrueProtocol(POOL_B, 5 ether);
        uint256 before = PROTOCOL_RECIPIENT.balance;

        vm.prank(PROTOCOL_RECIPIENT);
        uint256 claimed = hook.claimProtocol();

        assertEq(claimed, 8 ether, "returned aggregate amount");
        assertEq(PROTOCOL_RECIPIENT.balance - before, 8 ether, "recipient paid");
        assertEq(hook.protocolClaimable(), 0, "global balance zeroed");
        assertEq(hook.protocolClaimBacked(), 0, "backed subset zeroed");
    }

    // --- Scenario: Unauthorized protocol claim is rejected ---

    /// @dev Spec: "Unauthorized protocol claim is rejected".
    function test_unauthorisedProtocolClaimRejected() public {
        harness.accrueProtocol(POOL_A, 8 ether);

        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(MilestoneBase.NotProtocolRecipient.selector, STRANGER));
        hook.claimProtocol();

        vm.prank(PROTOCOL_ADMIN);
        vm.expectRevert(abi.encodeWithSelector(MilestoneBase.NotProtocolRecipient.selector, PROTOCOL_ADMIN));
        hook.claimProtocol();

        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(MilestoneBase.NotProtocolRecipient.selector, creator));
        hook.claimProtocol();

        assertEq(hook.protocolClaimable(), 8 ether, "balance untouched");
    }

    // --- Scenario: Recipient update transfers unclaimed entitlement ---

    function test_protocolClaimFollowsTheCurrentRecipient() public {
        harness.accrueProtocol(POOL_A, 6 ether);

        address next = address(0xFEED);
        bytes32 salt = bytes32("claims-recipient");
        vm.prank(PROTOCOL_ADMIN);
        controller.scheduleProtocolRecipient(next, salt);
        controller.executeProtocolRecipient(next, salt);

        vm.prank(PROTOCOL_RECIPIENT);
        vm.expectRevert(abi.encodeWithSelector(MilestoneBase.NotProtocolRecipient.selector, PROTOCOL_RECIPIENT));
        hook.claimProtocol();

        vm.prank(next);
        assertEq(hook.claimProtocol(), 6 ether, "new recipient claims");
    }

    // --- Scenario: New holder claims pre-transfer direct revenue ---

    /// @dev Spec: "New holder claims pre-transfer direct revenue". No settlement happens on transfer;
    /// the balance simply belongs to whoever holds the token when the claim runs.
    function test_newHolderClaimsThePreTransferBalance() public {
        harness.accrueCreator(POOL_A, 9 ether);
        uint256 buyerBefore = BUYER.balance;
        uint256 creatorBefore = creator.balance;

        vm.prank(creator);
        nft.transferFrom(creator, BUYER, tokenIdA);

        vm.prank(BUYER);
        uint256 claimed = hook.claimCreator(POOL_A);

        assertEq(claimed, 9 ether, "buyer claimed the pre-transfer balance");
        assertEq(BUYER.balance - buyerBefore, 9 ether, "buyer paid");
        assertEq(creator.balance, creatorBefore, "seller got nothing");
    }

    // --- Scenario: Previous holder loses all creator claim rights ---

    /// @dev Spec: "Previous holder loses all creator claim rights".
    function test_previousHolderLosesClaimRights() public {
        harness.accrueCreator(POOL_A, 9 ether);

        vm.prank(creator);
        nft.transferFrom(creator, BUYER, tokenIdA);

        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(MilestoneBase.NotRevenueNftHolder.selector, POOL_A, creator));
        hook.claimCreator(POOL_A);
    }

    // --- Scenario: New holder receives future direct accruals ---

    /// @dev Spec: "New holder receives future direct accruals".
    function test_newHolderReceivesFutureAccruals() public {
        vm.prank(creator);
        nft.transferFrom(creator, BUYER, tokenIdA);

        harness.accrueCreator(POOL_A, 4 ether);

        vm.prank(BUYER);
        assertEq(hook.claimCreator(POOL_A), 4 ether, "buyer claims later accruals");
    }

    // --- Scenario: Transfer performs no settlement ---

    function test_transferDoesNotSettleTheOutgoingHolder() public {
        harness.accrueCreator(POOL_A, 9 ether);
        uint256 before = creator.balance;

        vm.prank(creator);
        nft.transferFrom(creator, BUYER, tokenIdA);

        assertEq(creator.balance, before, "no payout on transfer");
        assertEq(hook.creatorClaimable(POOL_A), 9 ether, "balance untouched by the transfer");
    }

    // --- Scenario: Direct creator and protocol claims are isolated ---

    /// @dev Spec: "Direct creator and protocol claims are isolated".
    function test_claimsAreIsolatedBetweenCreatorAndProtocol() public {
        harness.accrueCreator(POOL_A, 7 ether);
        harness.accrueProtocol(POOL_A, 3 ether);

        vm.prank(creator);
        hook.claimCreator(POOL_A);
        assertEq(hook.protocolClaimable(), 3 ether, "protocol balance unchanged");

        vm.prank(PROTOCOL_RECIPIENT);
        hook.claimProtocol();
        assertEq(hook.creatorClaimable(POOL_A), 0, "creator balance still zero");
        assertEq(hook.protocolClaimable(), 0, "protocol balance now zero");
    }

    // --- Scenario: Creator claims are isolated across pools ---

    /// @dev Spec: "Creator claims are isolated across pools".
    function test_claimsAreIsolatedAcrossPools() public {
        harness.accrueCreator(POOL_A, 5 ether);
        harness.accrueCreator(POOL_B, 6 ether);

        vm.prank(creator);
        hook.claimCreator(POOL_A);

        assertEq(hook.creatorClaimable(POOL_A), 0, "pool A drained");
        assertEq(hook.creatorClaimable(POOL_B), 6 ether, "pool B untouched");
    }

    // --- Scenario: Multiple pools aggregate ---

    /// @dev Protocol revenue has source-pool attribution at accrual, but one claimable balance.
    function test_protocolBalancesAggregateGlobally() public {
        harness.accrueProtocol(POOL_A, 5 ether);
        harness.accrueProtocol(POOL_B, 6 ether);

        assertEq(hook.protocolClaimable(), 11 ether, "both source pools aggregate");

        vm.prank(PROTOCOL_RECIPIENT);
        assertEq(hook.claimProtocol(), 11 ether, "one global claim drains the aggregate");
        assertEq(hook.protocolClaimable(), 0, "global ledger drained");
    }

    // --- Scenario: No per-pool protocol claim exists ---

    function test_noPerPoolProtocolClaimExists() public {
        harness.accrueProtocol(POOL_A, 5 ether);
        harness.accrueProtocol(POOL_B, 6 ether);

        vm.prank(PROTOCOL_RECIPIENT);
        (bool ok,) = HOOK_ADDR.call(abi.encodeWithSignature("claimProtocol(bytes32)", PoolId.unwrap(POOL_A)));

        assertFalse(ok, "pool-scoped protocol claim is absent");
        assertEq(hook.protocolClaimable(), 11 ether, "failed selector cannot alter the global ledger");
    }

    /// @dev A claim on one pool must not let its holder reach another pool's balance.
    function test_holderOfOnePoolCannotClaimAnother() public {
        vm.prank(creator);
        nft.transferFrom(creator, BUYER, tokenIdA);

        harness.accrueCreator(POOL_B, 5 ether);

        vm.prank(BUYER);
        vm.expectRevert(abi.encodeWithSelector(MilestoneBase.NotRevenueNftHolder.selector, POOL_B, BUYER));
        hook.claimCreator(POOL_B);
    }

    // --- Scenario: Administrator has no implicit claim right ---

    function test_adminCannotReachBalancesOrCustody() public {
        harness.accrueCreator(POOL_A, 5 ether);
        harness.accrueProtocol(POOL_A, 5 ether);
        uint256 custodyBefore = HOOK_ADDR.balance;

        bytes32 salt = bytes32("admin-recipient");
        vm.prank(PROTOCOL_ADMIN);
        controller.scheduleProtocolRecipient(address(0xFEED), salt);
        controller.executeProtocolRecipient(address(0xFEED), salt);

        assertEq(hook.creatorClaimable(POOL_A), 5 ether, "creator balance untouched");
        assertEq(hook.protocolClaimable(), 5 ether, "protocol balance untouched");
        assertEq(HOOK_ADDR.balance, custodyBefore, "custody untouched");

        // And the admin still cannot claim.
        vm.prank(PROTOCOL_ADMIN);
        vm.expectRevert(abi.encodeWithSelector(MilestoneBase.NotProtocolRecipient.selector, PROTOCOL_ADMIN));
        hook.claimProtocol();
    }

    function test_noExternalAccrualEntryPointExists() public {
        string[4] memory sigs = [
            "accrue(bytes32,uint256)",
            "credit(bytes32,uint256)",
            "_accrueCreator(bytes32,uint256,uint8)",
            "setCreatorClaimable(bytes32,uint256)"
        ];

        for (uint256 i = 0; i < sigs.length; i++) {
            (bool ok,) = HOOK_ADDR.call(abi.encodeWithSignature(sigs[i], POOL_A, uint256(1 ether)));
            assertFalse(ok, "no external accrual path on the production hook");
        }
    }
}
