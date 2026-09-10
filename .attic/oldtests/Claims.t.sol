// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {MilestoneBase} from "../../src/MilestoneBase.sol";
import {MilestoneColdPaths} from "../../src/MilestoneColdPaths.sol";
import {RevenueNFT} from "../../src/RevenueNFT.sol";
import {LaunchSupport} from "../../src/LaunchSupport.sol";
import {MilestoneHookHarness} from "../harness/MilestoneHookHarness.sol";

/// @notice Holder contract that tries to re-enter the claim from its receive hook.
contract ReentrantHolder {
    MilestoneHookHarness internal immutable hook;
    PoolId internal immutable poolId;

    bool public reentryAttempted;
    bool public reentryReverted;
    uint256 public received;

    constructor(MilestoneHookHarness hook_, PoolId poolId_) {
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
    MilestoneHookHarness internal immutable hook;

    constructor(MilestoneHookHarness hook_) {
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
contract ClaimsTest is Test {
    address internal constant HOOK_ADDR = address(uint160((uint160(0xBEEF) << 20) | 15040));
    address internal constant POOL_MANAGER = address(0xBADBEEF);
    address internal constant PROTOCOL_ADMIN = address(0xADD1);
    address internal constant PROTOCOL_RECIPIENT = address(0xFEE5);

    address internal constant CREATOR = address(0xC0FFEE);
    address internal constant BUYER = address(0xB0B);
    address internal constant STRANGER = address(0xBAD);

    PoolId internal constant POOL_A = PoolId.wrap(bytes32(uint256(0xA1)));
    PoolId internal constant POOL_B = PoolId.wrap(bytes32(uint256(0xB2)));

    MilestoneHookHarness internal hook;
    RevenueNFT internal nft;
    LaunchSupport internal support;

    /// @dev Cached so they are never evaluated as an argument inside a `vm.prank`/`vm.expectRevert`
    /// call — a nested external call there consumes the cheatcode instead of the intended call.
    uint256 internal tokenIdA;
    uint256 internal tokenIdB;

    function setUp() public {
        nft = new RevenueNFT();
        support = new LaunchSupport();

        MilestoneColdPaths coldPaths = new MilestoneColdPaths(IPoolManager(POOL_MANAGER), nft, support);

        deployCodeTo(
            "MilestoneHookHarness.sol:MilestoneHookHarness",
            abi.encode(IPoolManager(POOL_MANAGER), nft, support, coldPaths, PROTOCOL_ADMIN, PROTOCOL_RECIPIENT),
            HOOK_ADDR
        );
        hook = MilestoneHookHarness(payable(HOOK_ADDR));

        nft.setMinter(HOOK_ADDR);

        tokenIdA = hook.mintRevenueNft(POOL_A, CREATOR);
        tokenIdB = hook.mintRevenueNft(POOL_B, CREATOR);

        // Custody is direct: the hook holds the ETH it will pay out.
        vm.deal(HOOK_ADDR, 1_000 ether);
    }

    // --- Task 3.4: the ledger accumulates and keeps parties independent ---

    function test_creditsAccumulate() public {
        hook.accrueCreator(POOL_A, 1 ether);
        hook.accrueCreator(POOL_A, 2 ether);
        hook.accrueCreator(POOL_A, 3 ether);

        assertEq(hook.creatorClaimable(POOL_A), 6 ether, "credits summed");
    }

    /// @dev Spec: "Accruals from all sources aggregate".
    function test_accrualsFromAllSourcesAggregate() public {
        hook.accrueCreatorFrom(POOL_A, 5 ether, MilestoneBase.AccrualSource.CURVE_PROCEEDS);
        hook.accrueCreatorFrom(POOL_A, 1 ether, MilestoneBase.AccrualSource.SWAP_FEES);
        hook.accrueCreatorFrom(POOL_A, 2 ether, MilestoneBase.AccrualSource.MILESTONE_HARVEST);
        hook.accrueCreatorFrom(POOL_A, 3 ether, MilestoneBase.AccrualSource.MILESTONE_HARVEST);

        assertEq(hook.creatorClaimable(POOL_A), 11 ether, "all sources aggregate into one balance");
    }

    function test_creatorAndProtocolLedgersAreIndependent() public {
        hook.accrueCreator(POOL_A, 7 ether);
        hook.accrueProtocol(POOL_A, 3 ether);

        assertEq(hook.creatorClaimable(POOL_A), 7 ether, "creator");
        assertEq(hook.protocolClaimable(POOL_A), 3 ether, "protocol");
    }

    function test_zeroAccrualIsANoOp() public {
        hook.accrueCreator(POOL_A, 0);
        assertEq(hook.creatorClaimable(POOL_A), 0, "nothing credited");
    }

    function testFuzz_ledgerIsPerPool(uint128 amountA, uint128 amountB) public {
        hook.accrueCreator(POOL_A, amountA);
        hook.accrueCreator(POOL_B, amountB);

        assertEq(hook.creatorClaimable(POOL_A), amountA, "pool A");
        assertEq(hook.creatorClaimable(POOL_B), amountB, "pool B");
    }

    // --- Task 3.5: creator claims ---

    /// @dev Spec: "Current holder claims successfully".
    function test_currentHolderClaims() public {
        hook.accrueCreator(POOL_A, 10 ether);
        uint256 before = CREATOR.balance;

        vm.prank(CREATOR);
        uint256 claimed = hook.claimCreator(POOL_A);

        assertEq(claimed, 10 ether, "returned amount");
        assertEq(CREATOR.balance - before, 10 ether, "holder paid");
        assertEq(hook.creatorClaimable(POOL_A), 0, "balance zeroed");
    }

    /// @dev Spec: "Non-holder claim is rejected".
    function test_nonHolderClaimRejected() public {
        hook.accrueCreator(POOL_A, 10 ether);

        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(MilestoneBase.NotRevenueNftHolder.selector, POOL_A, STRANGER));
        hook.claimCreator(POOL_A);

        assertEq(hook.creatorClaimable(POOL_A), 10 ether, "balance untouched");
    }

    /// @dev Spec: "Claiming an empty balance transfers nothing".
    function test_claimingEmptyBalanceTransfersNothing() public {
        uint256 before = CREATOR.balance;

        vm.prank(CREATOR);
        uint256 claimed = hook.claimCreator(POOL_A);

        assertEq(claimed, 0, "nothing claimed");
        assertEq(CREATOR.balance, before, "nothing transferred");
    }

    /// @dev Spec: "A claim cannot exceed the accrued balance" — including under re-entry.
    function test_claimCannotExceedAccruedBalance() public {
        hook.accrueCreator(POOL_A, 4 ether);

        vm.prank(CREATOR);
        hook.claimCreator(POOL_A);

        vm.prank(CREATOR);
        uint256 second = hook.claimCreator(POOL_A);

        assertEq(second, 0, "second claim transfers nothing");
        assertEq(CREATOR.balance, 4 ether, "paid exactly once");
    }

    function test_reentrantClaimIsBlockedAndPaysOnce() public {
        ReentrantHolder holder = new ReentrantHolder(hook, POOL_A);

        vm.prank(CREATOR);
        nft.transferFrom(CREATOR, address(holder), tokenIdA);

        hook.accrueCreator(POOL_A, 5 ether);
        holder.claim();

        assertTrue(holder.reentryAttempted(), "re-entry was attempted");
        assertTrue(holder.reentryReverted(), "re-entry was rejected");
        assertEq(holder.received(), 5 ether, "paid exactly once");
        assertEq(hook.creatorClaimable(POOL_A), 0, "balance zeroed once");
    }

    function test_failedPayoutRevertsRatherThanBurningTheBalance() public {
        RejectingHolder holder = new RejectingHolder(hook);

        vm.prank(CREATOR);
        nft.transferFrom(CREATOR, address(holder), tokenIdA);

        hook.accrueCreator(POOL_A, 5 ether);

        vm.expectRevert();
        holder.claim(POOL_A);

        // The whole transaction unwound, so the balance is still there to claim later.
        assertEq(hook.creatorClaimable(POOL_A), 5 ether, "balance preserved");
    }

    /// @dev Spec: "Accrual after a claim is claimable again".
    function test_accrualAfterClaimIsClaimableAgain() public {
        hook.accrueCreator(POOL_A, 2 ether);
        vm.prank(CREATOR);
        hook.claimCreator(POOL_A);

        hook.accrueCreator(POOL_A, 3 ether);
        vm.prank(CREATOR);
        uint256 claimed = hook.claimCreator(POOL_A);

        assertEq(claimed, 3 ether, "new accrual claimable");
        assertEq(CREATOR.balance, 5 ether, "both claims paid");
    }

    // --- Task 3.5: protocol claims ---

    /// @dev Spec: "Designated recipient claims successfully".
    function test_protocolRecipientClaims() public {
        hook.accrueProtocol(POOL_A, 8 ether);

        vm.prank(PROTOCOL_RECIPIENT);
        uint256 claimed = hook.claimProtocol(POOL_A);

        assertEq(claimed, 8 ether, "returned amount");
        assertEq(PROTOCOL_RECIPIENT.balance, 8 ether, "recipient paid");
        assertEq(hook.protocolClaimable(POOL_A), 0, "balance zeroed");
    }

    /// @dev Spec: "Unauthorised protocol claim is rejected" — including by the admin, who can name
    /// the recipient but is not one.
    function test_unauthorisedProtocolClaimRejected() public {
        hook.accrueProtocol(POOL_A, 8 ether);

        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(MilestoneBase.NotProtocolRecipient.selector, STRANGER));
        hook.claimProtocol(POOL_A);

        vm.prank(PROTOCOL_ADMIN);
        vm.expectRevert(abi.encodeWithSelector(MilestoneBase.NotProtocolRecipient.selector, PROTOCOL_ADMIN));
        hook.claimProtocol(POOL_A);

        vm.prank(CREATOR);
        vm.expectRevert(abi.encodeWithSelector(MilestoneBase.NotProtocolRecipient.selector, CREATOR));
        hook.claimProtocol(POOL_A);

        assertEq(hook.protocolClaimable(POOL_A), 8 ether, "balance untouched");
    }

    function test_protocolClaimFollowsTheCurrentRecipient() public {
        hook.accrueProtocol(POOL_A, 6 ether);

        address next = address(0xFEED);
        vm.prank(PROTOCOL_ADMIN);
        hook.setProtocolRecipient(next);

        vm.prank(PROTOCOL_RECIPIENT);
        vm.expectRevert(abi.encodeWithSelector(MilestoneBase.NotProtocolRecipient.selector, PROTOCOL_RECIPIENT));
        hook.claimProtocol(POOL_A);

        vm.prank(next);
        assertEq(hook.claimProtocol(POOL_A), 6 ether, "new recipient claims");
    }

    // --- Task 3.6: the unclaimed balance follows the NFT ---

    /// @dev Spec: "New holder can claim the pre-transfer balance". No settlement happens on transfer;
    /// the balance simply belongs to whoever holds the token when the claim runs.
    function test_newHolderClaimsThePreTransferBalance() public {
        hook.accrueCreator(POOL_A, 9 ether);

        vm.prank(CREATOR);
        nft.transferFrom(CREATOR, BUYER, tokenIdA);

        vm.prank(BUYER);
        uint256 claimed = hook.claimCreator(POOL_A);

        assertEq(claimed, 9 ether, "buyer claimed the pre-transfer balance");
        assertEq(BUYER.balance, 9 ether, "buyer paid");
        assertEq(CREATOR.balance, 0, "seller got nothing");
    }

    /// @dev Spec: "Previous holder loses claim rights immediately".
    function test_previousHolderLosesClaimRights() public {
        hook.accrueCreator(POOL_A, 9 ether);

        vm.prank(CREATOR);
        nft.transferFrom(CREATOR, BUYER, tokenIdA);

        vm.prank(CREATOR);
        vm.expectRevert(abi.encodeWithSelector(MilestoneBase.NotRevenueNftHolder.selector, POOL_A, CREATOR));
        hook.claimCreator(POOL_A);
    }

    /// @dev Spec: "New holder receives future accruals".
    function test_newHolderReceivesFutureAccruals() public {
        vm.prank(CREATOR);
        nft.transferFrom(CREATOR, BUYER, tokenIdA);

        hook.accrueCreator(POOL_A, 4 ether);

        vm.prank(BUYER);
        assertEq(hook.claimCreator(POOL_A), 4 ether, "buyer claims later accruals");
    }

    function test_transferDoesNotSettleTheOutgoingHolder() public {
        hook.accrueCreator(POOL_A, 9 ether);

        vm.prank(CREATOR);
        nft.transferFrom(CREATOR, BUYER, tokenIdA);

        assertEq(CREATOR.balance, 0, "no payout on transfer");
        assertEq(hook.creatorClaimable(POOL_A), 9 ether, "balance untouched by the transfer");
    }

    // --- Isolation ---

    /// @dev Spec: "Claims are isolated between creator and protocol".
    function test_claimsAreIsolatedBetweenCreatorAndProtocol() public {
        hook.accrueCreator(POOL_A, 7 ether);
        hook.accrueProtocol(POOL_A, 3 ether);

        vm.prank(CREATOR);
        hook.claimCreator(POOL_A);
        assertEq(hook.protocolClaimable(POOL_A), 3 ether, "protocol balance unchanged");

        vm.prank(PROTOCOL_RECIPIENT);
        hook.claimProtocol(POOL_A);
        assertEq(hook.creatorClaimable(POOL_A), 0, "creator balance still zero");
        assertEq(hook.protocolClaimable(POOL_A), 0, "protocol balance now zero");
    }

    /// @dev Spec: "Claims are isolated across pools".
    function test_claimsAreIsolatedAcrossPools() public {
        hook.accrueCreator(POOL_A, 5 ether);
        hook.accrueCreator(POOL_B, 6 ether);

        vm.prank(CREATOR);
        hook.claimCreator(POOL_A);

        assertEq(hook.creatorClaimable(POOL_A), 0, "pool A drained");
        assertEq(hook.creatorClaimable(POOL_B), 6 ether, "pool B untouched");
    }

    /// @dev Spec: "Protocol balances are isolated per pool".
    function test_protocolBalancesAreIsolatedPerPool() public {
        hook.accrueProtocol(POOL_A, 5 ether);
        hook.accrueProtocol(POOL_B, 6 ether);

        vm.prank(PROTOCOL_RECIPIENT);
        hook.claimProtocol(POOL_A);

        assertEq(hook.protocolClaimable(POOL_A), 0, "pool A drained");
        assertEq(hook.protocolClaimable(POOL_B), 6 ether, "pool B untouched");
    }

    /// @dev A claim on one pool must not let its holder reach another pool's balance.
    function test_holderOfOnePoolCannotClaimAnother() public {
        vm.prank(CREATOR);
        nft.transferFrom(CREATOR, BUYER, tokenIdA);

        hook.accrueCreator(POOL_B, 5 ether);

        vm.prank(BUYER);
        vm.expectRevert(abi.encodeWithSelector(MilestoneBase.NotRevenueNftHolder.selector, POOL_B, BUYER));
        hook.claimCreator(POOL_B);
    }

    // --- Task 3.6: the admin power reaches nothing else ---

    function test_adminCannotReachBalancesOrCustody() public {
        hook.accrueCreator(POOL_A, 5 ether);
        hook.accrueProtocol(POOL_A, 5 ether);
        uint256 custodyBefore = HOOK_ADDR.balance;

        vm.prank(PROTOCOL_ADMIN);
        hook.setProtocolRecipient(address(0xFEED));

        assertEq(hook.creatorClaimable(POOL_A), 5 ether, "creator balance untouched");
        assertEq(hook.protocolClaimable(POOL_A), 5 ether, "protocol balance untouched");
        assertEq(HOOK_ADDR.balance, custodyBefore, "custody untouched");

        // And the admin still cannot claim.
        vm.prank(PROTOCOL_ADMIN);
        vm.expectRevert(abi.encodeWithSelector(MilestoneBase.NotProtocolRecipient.selector, PROTOCOL_ADMIN));
        hook.claimProtocol(POOL_A);
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
