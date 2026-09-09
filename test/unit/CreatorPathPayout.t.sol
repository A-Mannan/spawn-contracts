// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolId} from "v4-core/src/types/PoolId.sol";
import {MilestoneBase} from "../../src/MilestoneBase.sol";
import {PayoutTestFixture} from "../mocks/PayoutTestHook.sol";
import {
    ICreatorPathTarget,
    IRevenueTransfer,
    OwnershipChangingPayoutPlugin,
    RecordingPayoutPlugin,
    RejectingRevenueHolder,
    SwitchablePayoutPlugin
} from "../mocks/PayoutReferenceMocks.sol";

contract CreatorPathPayoutTest is PayoutTestFixture {
    // --- Scenario: Arbitrary flush records rather than pushes creator value ---
    function test_arbitraryFlushRecordsRatherThanPushesCreatorValue() public {
        _fundPot(poolId, 0, 100 ether);
        uint256 creatorBefore = creator.balance;
        vm.prank(STRANGER);
        hook.flush(poolId);
        assertEq(creator.balance, creatorBefore);
        assertEq(hook.creatorPathClaimable(poolId), 89.1 ether);
    }

    // --- Scenario: Creator value follows NFT ownership ---
    function test_creatorValueFollowsNftOwnership() public {
        _fundPot(poolId, 0, 100 ether);
        hook.flush(poolId);
        uint256 tokenId = nft.tokenIdOf(poolId);
        vm.prank(creator);
        nft.transferFrom(creator, STRANGER, tokenId);
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(MilestoneBase.NotRevenueNftHolder.selector, poolId, creator));
        hook.claimCreatorPath(poolId);
        uint256 beforeBalance = STRANGER.balance;
        vm.prank(STRANGER);
        (bool success, uint256 attempted) = hook.claimCreatorPath(poolId);
        assertTrue(success);
        assertEq(attempted, 89.1 ether);
        assertEq(STRANGER.balance - beforeBalance, attempted);
    }

    // --- Scenario: Creator-path and direct ledgers remain separate ---
    function test_creatorPathAndDirectLedgersRemainSeparate() public {
        payoutHook.accrueDirectCreator{value: 3 ether}(poolId, 3 ether);
        _fundPot(poolId, 0, 100 ether);
        hook.flush(poolId);
        assertEq(hook.creatorClaimable(poolId), 3 ether);
        assertEq(hook.creatorPathClaimable(poolId), 89.1 ether);
    }

    // --- Scenario: Creator payout flushes first ---
    function test_creatorPayoutFlushesFirst() public {
        _fundPot(poolId, 0, 100 ether);
        uint256 beforeBalance = creator.balance;
        vm.prank(creator);
        (bool success, uint256 attempted) = hook.claimCreatorPath(poolId);
        assertTrue(success);
        assertEq(hook.payoutPot(poolId), 0);
        assertEq(hook.creatorPathClaimable(poolId), 0);
        assertEq(creator.balance - beforeBalance, attempted);
    }

    // --- Scenario: Creator self-flush preserves the tip ---
    function test_creatorSelfFlushPreservesTheTip() public {
        RecordingPayoutPlugin plugin = new RecordingPayoutPlugin();
        uint8 index = _registerPayoutPlugin(address(plugin), 0.5e18);
        (PoolId id,,) = _launchWithPlan("Self Flush", "SELF", _plan(index));
        _fundPot(id, 0, 100 ether);
        vm.prank(creator);
        (bool success, uint256 attempted) = hook.claimCreatorPath(id);
        assertTrue(success);
        assertEq(plugin.totalReceived(), 44.55 ether);
        assertEq(attempted, 45.45 ether);
    }

    // --- Scenario: Ownership change during plugins reverts payout ---
    function test_ownershipChangeDuringPluginsRevertsPayout() public {
        OwnershipChangingPayoutPlugin plugin = new OwnershipChangingPayoutPlugin();
        uint8 index = _registerPayoutPlugin(address(plugin), 0.5e18);
        (PoolId id,,) = _launchWithPlan("Move", "MOVE", _plan(index));
        uint256 tokenId = nft.tokenIdOf(id);
        vm.prank(creator);
        nft.transferFrom(creator, address(plugin), tokenId);
        plugin.configureOwnershipChange(IRevenueTransfer(address(nft)), tokenId, STRANGER);
        _fundPot(id, 0, 100 ether);
        vm.expectRevert(
            abi.encodeWithSelector(MilestoneBase.RevenueNftOwnerChanged.selector, id, address(plugin), STRANGER)
        );
        plugin.claimCreatorPath(ICreatorPathTarget(address(payoutHook)), id);
        assertEq(nft.ownerOf(tokenId), address(plugin));
        assertEq(hook.payoutPot(id), 90 ether);
        assertEq(plugin.calls(), 0);
        assertEq(plugin.totalReceived(), 0);
    }

    // --- Scenario: Failed recipient transfer preserves entitlement ---
    function test_failedRecipientTransferPreservesEntitlement() public {
        RejectingRevenueHolder holder = new RejectingRevenueHolder();
        uint256 tokenId = nft.tokenIdOf(poolId);
        vm.prank(creator);
        nft.transferFrom(creator, address(holder), tokenId);
        _fundPot(poolId, 0, 100 ether);
        (bool success, uint256 attempted) = holder.claimCreatorPath(address(hook), poolId);
        assertFalse(success);
        assertEq(attempted, 90 ether);
        assertEq(hook.creatorPathClaimable(poolId), attempted);
        assertEq(hook.payoutPot(poolId), 0);
    }
}

/// @notice The `revenue-claims` boundary between the two creator ledgers and the two protocol backing
/// classes.
///
/// @dev The direct ledger and the creator path are separate destinations that happen to share one
/// recipient, so almost every way of getting them confused still pays the right person the right total.
/// What these tests hold is the separation itself: that a milestone never reaches the direct ledger, that
/// a direct claim never disturbs a pot, and that a plugin the protocol cannot control cannot stand between
/// a holder and revenue that was never the plugin's to touch.
contract DirectAndPathLedgerSeparationTest is PayoutTestFixture {
    /// @dev 100 ETH gross, less the 10% service fee, less the 1% flush tip on the 90 ETH net pot.
    uint256 internal constant DISTRIBUTABLE = 89.1 ether;

    // --- Scenario (revenue-claims): Direct claim does not flush ---

    /// @dev Both payout ledgers are put in a state a claim could plausibly disturb -- one plugin holding
    /// carry from an earlier failure, and a second, still-unflushed pot on top of it -- and then the direct
    /// claim runs. `claimCreator` is the path that must not flush; `claimCreatorPath` is the one that must.
    function test_directClaimDoesNotFlush() public {
        SwitchablePayoutPlugin plugin = new SwitchablePayoutPlugin();
        uint8 index = _registerPayoutPlugin(address(plugin), 0.5e18);
        (PoolId id,,) = _launchWithPlan("Hold", "HLD", _plan(index));

        plugin.setShouldRevert(true);
        _fundPot(id, 0, 100 ether);
        hook.flush(id);
        uint256 carry = hook.pluginCarry(id, index);
        assertEq(carry, DISTRIBUTABLE / 2, "the failed delivery is sitting in carry");

        _fundPot(id, 1, 50 ether);
        uint256 pot = hook.payoutPot(id);
        assertEq(pot, 45 ether, "and a second pot is waiting on top of it");

        payoutHook.accrueDirectCreator{value: 4 ether}(id, 4 ether);
        uint256 balanceBefore = creator.balance;
        vm.prank(creator);
        uint256 paid = hook.claimCreator(id);

        assertEq(paid, 4 ether, "the direct claim pays exactly the direct ledger");
        assertEq(creator.balance - balanceBefore, paid, "for real");
        assertEq(hook.payoutPot(id), pot, "the pot is untouched");
        assertEq(hook.pluginCarry(id, index), carry, "so is the carry");
        assertEq(hook.carryBitmap(id), uint256(1) << index, "and the retry bitmap still names the plugin");
        assertEq(plugin.calls(), 0, "no plugin was called");
    }

    // --- Scenario (revenue-claims): Milestone harvest does not credit direct creator revenue ---

    /// @dev Checked at both moments the requirement names. The harvest's accounting splits gross into a
    /// service fee and a pot, and the flush splits the pot into plugin allocations and a remainder; neither
    /// step may put a wei into the ledger `claimCreator` pays from, however much of it the creator ends up
    /// owed by the other route.
    function test_milestoneHarvestDoesNotCreditDirectCreatorRevenue() public {
        RecordingPayoutPlugin plugin = new RecordingPayoutPlugin();
        uint8 index = _registerPayoutPlugin(address(plugin), 0.5e18);
        (PoolId id,,) = _launchWithPlan("Split", "SPL", _plan(index));
        assertEq(hook.creatorClaimable(id), 0, "the pool opens with an empty direct ledger");

        _fundPot(id, 0, 100 ether);
        assertEq(hook.creatorClaimable(id), 0, "harvest accounting credits no direct revenue");

        hook.flush(id);
        assertEq(hook.creatorClaimable(id), 0, "and neither does the flush");
        assertEq(hook.creatorPathClaimable(id), DISTRIBUTABLE / 2, "the whole remainder went to the path");

        vm.prank(creator);
        assertEq(hook.claimCreator(id), 0, "so the direct claim has nothing to pay");
    }

    // --- Scenario (revenue-claims): New holder receives unpaid creator-path value ---

    /// @dev "Only the new holder" is two assertions, not one: the outgoing holder is refused, and the
    /// incoming holder is paid the entitlement recorded before the transfer rather than some share of it.
    function test_newHolderReceivesUnpaidCreatorPathValue() public {
        _fundPot(poolId, 0, 100 ether);
        hook.flush(poolId);
        uint256 unpaid = hook.creatorPathClaimable(poolId);
        assertEq(unpaid, DISTRIBUTABLE, "there is unpaid creator-path value to carry across");

        uint256 tokenId = nft.tokenIdOf(poolId);
        vm.prank(creator);
        nft.transferFrom(creator, STRANGER, tokenId);
        assertEq(hook.creatorPathClaimable(poolId), unpaid, "the transfer settled nothing");

        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(MilestoneBase.NotRevenueNftHolder.selector, poolId, creator));
        hook.claimCreatorPath(poolId);

        uint256 balanceBefore = STRANGER.balance;
        vm.prank(STRANGER);
        (bool success, uint256 attempted) = hook.claimCreatorPath(poolId);

        assertTrue(success, "the new holder can claim");
        assertEq(attempted, unpaid, "the whole pre-transfer entitlement");
        assertEq(STRANGER.balance - balanceBefore, attempted, "paid out for real");
        assertEq(hook.creatorPathClaimable(poolId), 0, "and the ledger is now empty");
    }

    // --- Scenario (revenue-claims): Plugin failure cannot block a direct claim ---

    /// @dev The worst case the requirement allows: every selected entry failing, so the plan delivers
    /// nothing at all and the whole distributable amount is stuck in carry. The direct ledger is a
    /// different liability class backed by raw ETH, so none of that is in the claim's way.
    function test_pluginFailureCannotBlockADirectClaim() public {
        SwitchablePayoutPlugin first = new SwitchablePayoutPlugin();
        SwitchablePayoutPlugin second = new SwitchablePayoutPlugin();
        uint8 a = _registerPayoutPlugin(address(first), 0.4e18);
        uint8 b = _registerPayoutPlugin(address(second), 0.4e18);
        (PoolId id,,) = _launchWithPlan("Broken", "BRK", _plan(a, b));

        first.setShouldRevert(true);
        second.setShouldRevert(true);
        _fundPot(id, 0, 100 ether);
        hook.flush(id);

        assertEq(first.calls(), 0, "neither plugin accepted delivery");
        assertEq(second.calls(), 0, "neither plugin accepted delivery");
        uint256 stuck = hook.pluginCarry(id, a) + hook.pluginCarry(id, b);
        assertEq(stuck, (DISTRIBUTABLE * 8) / 10, "and eighty percent of the pot is stuck in carry");

        payoutHook.accrueDirectCreator{value: 7 ether}(id, 7 ether);
        uint256 balanceBefore = creator.balance;
        vm.prank(creator);
        uint256 paid = hook.claimCreator(id);

        assertEq(paid, 7 ether, "the direct claim is unaffected");
        assertEq(creator.balance - balanceBefore, paid, "and really pays");
        assertEq(hook.pluginCarry(id, a) + hook.pluginCarry(id, b), stuck, "the carry is still there to retry");
    }

    // --- Scenario (revenue-claims): Plugin-pot proceeds remain separate ---

    /// @dev The remainder is per-pool on the creator path, which is what stops one pool's milestone from
    /// showing up as another's revenue or as this pool's direct balance. A direct accrual runs alongside it
    /// so the two ledgers are non-zero at the same time and cannot be told apart by one being empty.
    function test_pluginPotProceedsRemainSeparate() public {
        RecordingPayoutPlugin plugin = new RecordingPayoutPlugin();
        uint8 index = _registerPayoutPlugin(address(plugin), 0.5e18);
        (PoolId id,,) = _launchWithPlan("Ledger", "LDG", _plan(index));

        payoutHook.accrueDirectCreator{value: 2 ether}(id, 2 ether);
        _fundPot(id, 0, 100 ether);
        hook.flush(id);

        assertEq(plugin.totalReceived(), DISTRIBUTABLE / 2, "the plugin took its half");
        assertEq(hook.creatorPathClaimable(id), DISTRIBUTABLE / 2, "the remainder is creator-path entitlement");
        assertEq(hook.creatorClaimable(id), 2 ether, "the direct ledger holds only what accrued directly");
        assertEq(hook.creatorPathClaimable(poolId), 0, "and the other pool's path ledger never moved");
        assertEq(hook.creatorClaimable(poolId), 0, "nor its direct ledger");
    }

    // --- Scenario (revenue-claims): Protocol backing classes remain explicit ---

    /// @dev The two protocol sources land in one ledger but under different custody. A service fee is
    /// carved out of a harvest that has not been redeemed yet, so it is backed by a manager claim; quote-fee
    /// and graduation revenue is raw ETH. The claim-backed figure is a marker on the subset, so it has to
    /// track only the unredeemed service fee and stay inside the ledger it marks.
    function test_protocolBackingClassesRemainExplicit() public {
        uint256 claimableBefore = hook.protocolClaimable();
        uint256 backedBefore = hook.protocolClaimBacked();

        payoutHook.accrueRawProtocol{value: 5 ether}(poolId, 5 ether);
        assertEq(hook.protocolClaimable() - claimableBefore, 5 ether, "raw revenue reached the one ledger");
        assertEq(hook.protocolClaimBacked(), backedBefore, "without marking any of it claim-backed");

        _fundPot(poolId, 0, 100 ether);
        assertEq(hook.protocolClaimBacked() - backedBefore, 10 ether, "only the service fee is claim-backed");
        assertEq(hook.protocolClaimable() - claimableBefore, 15 ether, "and both sources are in the ledger");
        assertLe(hook.protocolClaimBacked(), hook.protocolClaimable(), "the subset never exceeds its ledger");
        assertEq(
            hook.claimBackedLiabilities(),
            hook.protocolClaimBacked() + hook.payoutPot(poolId),
            "the pot is a separate claim-backed liability, not part of the protocol's"
        );

        vm.prank(PROTOCOL_RECIPIENT);
        uint256 paid = hook.claimProtocol();

        assertEq(paid, claimableBefore + 15 ether, "the claim pays the whole ledger");
        assertEq(hook.protocolClaimBacked(), 0, "and nothing is left marked as backed");
        assertEq(hook.payoutPot(poolId), 90 ether, "the pot's own backing was not spent on it");
    }
}
