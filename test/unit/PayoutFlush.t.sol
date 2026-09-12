// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolId} from "v4-core/src/types/PoolId.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IERC6909Claims} from "v4-core/src/interfaces/external/IERC6909Claims.sol";
import {MilestoneBase} from "../../src/MilestoneBase.sol";
import {PoolState} from "../../src/types/LaunchTypes.sol";
import {PayoutTestFixture} from "../mocks/PayoutTestHook.sol";
import {Vm} from "forge-std/Vm.sol";
import {RecordingPayoutPlugin, RejectingPayoutCaller, SwitchablePayoutPlugin} from "../mocks/PayoutReferenceMocks.sol";

contract PayoutFlushTest is PayoutTestFixture {
    event PayoutPotRedeemed(PoolId indexed poolId, uint256 amount);

    /// @dev no-via_ir stack limit: the before-state snapshot for {test_payoutsDoNotCompound}, bundled
    /// into one struct.
    struct NoCompoundBefore {
        PoolId id;
        PoolId defaultPoolId;
        uint128 recordedLiquidity;
        uint128 realLiquidity;
        uint256 defaultCreator;
        uint256 graduatedCreator;
        uint256 creatorPath;
        uint256 protocol;
        uint256 protocolBacking;
        uint256 flusherEth;
        uint256 expectedTip;
        uint256 expectedPlugin;
        uint256 expectedCreator;
        uint256 fundedPot;
    }

    // --- Scenario (graduation): Payouts do not compound ---
    function test_payoutsDoNotCompound() public {
        RecordingPayoutPlugin plugin = new RecordingPayoutPlugin();
        uint8 index = _registerPayoutPlugin(address(plugin), 0.4e18);
        PoolId defaultPoolId = poolId;
        (poolId, key, token) = _launchWithPlan("No Compound", "NOCMP", _plan(index));
        PoolId id = poolId;
        _graduate();

        uint256 grossQuote = 100 ether;
        _fundPot(id, 0, grossQuote);
        uint256 fundedPot = hook.payoutPot(id);
        uint256 expectedTip = fundedPot / 100;
        uint256 distributable = fundedPot - expectedTip;

        // no-via_ir stack limit: the before-state travels as one struct.
        NoCompoundBefore memory before = NoCompoundBefore({
            id: id,
            defaultPoolId: defaultPoolId,
            recordedLiquidity: hook.poolState(id).fullRangeLiquidity,
            realLiquidity: _fullRangeLiquidity(),
            defaultCreator: hook.creatorClaimable(defaultPoolId),
            graduatedCreator: hook.creatorClaimable(id),
            creatorPath: hook.creatorPathClaimable(id),
            protocol: hook.protocolClaimable(),
            protocolBacking: hook.protocolClaimBacked(),
            flusherEth: STRANGER.balance,
            expectedTip: expectedTip,
            expectedPlugin: distributable * 0.4e18 / 1e18,
            expectedCreator: distributable - (distributable * 0.4e18 / 1e18),
            fundedPot: fundedPot
        });
        assertGt(before.recordedLiquidity, 0, "graduation recorded no liquidity");

        vm.prank(STRANGER);
        hook.flushTo(id, STRANGER);

        _assertNothingCompounded(before, plugin);
    }

    /// @dev no-via_ir stack limit: the before/after comparison for {test_payoutsDoNotCompound}, in its
    /// own frame.
    function _assertNothingCompounded(NoCompoundBefore memory before, RecordingPayoutPlugin plugin) private {
        assertEq(before.realLiquidity, before.recordedLiquidity, "recorded and real liquidity differ");
        assertEq(hook.payoutPot(before.id), 0, "pot not completely flushed");
        assertEq(STRANGER.balance - before.flusherEth, before.expectedTip, "incorrect tip");
        assertEq(plugin.totalReceived(), before.expectedPlugin, "incorrect plugin allocation");
        assertEq(
            hook.creatorPathClaimable(before.id) - before.creatorPath,
            before.expectedCreator,
            "incorrect creator remainder"
        );
        assertEq(
            before.expectedTip + plugin.totalReceived() + before.expectedCreator,
            before.fundedPot,
            "pot partition incomplete"
        );
        assertEq(_fullRangeLiquidity(), before.realLiquidity, "real full-range liquidity changed");
        assertEq(hook.poolState(before.id).fullRangeLiquidity, before.recordedLiquidity, "recorded liquidity changed");
        assertEq(
            hook.creatorClaimable(before.defaultPoolId), before.defaultCreator, "unrelated pool creator ledger changed"
        );
        assertEq(hook.creatorClaimable(before.id), before.graduatedCreator, "direct creator ledger changed");
        assertEq(hook.protocolClaimable(), before.protocol, "protocol ledger changed");
        assertEq(hook.protocolClaimBacked(), before.protocolBacking, "protocol backing changed");
    }

    // --- Scenario: Any address can flush one pool ---
    function test_anyAddressCanFlushOnePool() public {
        _fundPot(poolId, 0, 100 ether);
        vm.prank(STRANGER);
        hook.flushTo(poolId, STRANGER);
        assertEq(hook.payoutPot(poolId), 0);
    }

    // --- Scenario: Whole new pot is redeemed once ---
    function test_wholeNewPotIsRedeemedOnce() public {
        _fundPot(poolId, 0, 100 ether);
        vm.expectEmit(true, false, false, true, address(hook));
        emit PayoutPotRedeemed(poolId, 90 ether);
        hook.flushTo(poolId, STRANGER);
        assertEq(hook.payoutPot(poolId), 0);
        assertEq(hook.claimBacking(), 10 ether);
        hook.flushTo(poolId, STRANGER);
        assertEq(hook.claimBacking(), 10 ether);
    }

    // --- Scenario: Flusher receives one percent of the net new pot ---
    function test_flusherReceivesOnePercentOfTheNetNewPot() public {
        _fundPot(poolId, 0, 100 ether);
        uint256 beforeBalance = STRANGER.balance;
        vm.prank(STRANGER);
        hook.flushTo(poolId, STRANGER);
        assertEq(STRANGER.balance - beforeBalance, 0.9 ether);
        assertEq(hook.creatorPathClaimable(poolId), 89.1 ether);
    }

    // --- Scenario: Protocol service fee is never tipped ---
    function test_protocolServiceFeeIsNeverTipped() public {
        _fundPot(poolId, 0, 100 ether);
        vm.prank(STRANGER);
        hook.flushTo(poolId, STRANGER);
        assertEq(STRANGER.balance, 0.9 ether);
        assertEq(hook.protocolClaimable(), 10 ether);
        assertEq(hook.protocolClaimBacked(), 10 ether);
    }

    // --- Scenario: Carry is not tipped twice ---
    function test_carryIsNotTippedTwice() public {
        SwitchablePayoutPlugin plugin = new SwitchablePayoutPlugin();
        uint8 index = _registerPayoutPlugin(address(plugin), 0.5e18);
        (PoolId id,,) = _launchWithPlan("Carry Tip", "CTIP", _plan(index));
        plugin.setShouldRevert(true);
        _fundPot(id, 0, 100 ether);
        vm.prank(STRANGER);
        hook.flushTo(id, STRANGER);
        uint256 carry = hook.pluginCarry(id, index);
        uint256 flusherAfterFirst = STRANGER.balance;
        plugin.setShouldRevert(false);
        vm.prank(STRANGER);
        hook.flushTo(id, STRANGER);
        assertEq(STRANGER.balance, flusherAfterFirst);
        assertEq(plugin.lastAmount(), carry);
    }

    // --- Scenario: Carry-only flush remains available ---
    function test_carryOnlyFlushRemainsAvailable() public {
        SwitchablePayoutPlugin plugin = new SwitchablePayoutPlugin();
        uint8 index = _registerPayoutPlugin(address(plugin), 0.5e18);
        (PoolId id,,) = _launchWithPlan("Carry Only", "CARRY", _plan(index));
        plugin.setShouldRevert(true);
        _fundPot(id, 0, 100 ether);
        hook.flushTo(id, STRANGER);
        uint256 carry = hook.pluginCarry(id, index);
        assertEq(hook.payoutPot(id), 0);
        plugin.setShouldRevert(false);
        hook.flushTo(id, STRANGER);
        assertEq(plugin.totalReceived(), carry);
        assertEq(hook.pluginCarry(id, index), 0);
    }

    // --- Scenario: Empty flush is a no-op ---
    function test_emptyFlushIsANoOp() public {
        uint256 claimBacking = hook.claimBacking();
        uint256 nativeBacking = address(hook).balance;
        hook.flushTo(poolId, STRANGER);
        assertEq(hook.claimBacking(), claimBacking);
        assertEq(address(hook).balance, nativeBacking);
        assertEq(hook.totalLiabilities(), 0);
    }

    // --- Scenario: Ordinary flusher tip failure is atomic ---
    function test_ordinaryFlusherTipFailureIsAtomic() public {
        RecordingPayoutPlugin plugin = new RecordingPayoutPlugin();
        uint8 index = _registerPayoutPlugin(address(plugin), 0.5e18);
        (PoolId id,,) = _launchWithPlan("Reject Tip", "RTIP", _plan(index));
        _fundPot(id, 0, 100 ether);
        RejectingPayoutCaller caller = new RejectingPayoutCaller();
        vm.expectRevert(abi.encodeWithSelector(MilestoneBase.EthTransferFailed.selector, address(caller), 0.9 ether));
        caller.flushTo(address(hook), id);
        assertEq(hook.payoutPot(id), 90 ether);
        assertEq(plugin.calls(), 0);
        assertEq(hook.creatorPathClaimable(id), 0);
        assertEq(hook.claimBacking(), 100 ether);
    }

    // --- Scenario: A batch redeems every pot in one unlock ---
    function test_aBatchRedeemsEveryPotInOneUnlock() public {
        RecordingPayoutPlugin pluginA = new RecordingPayoutPlugin();
        uint8 indexA = _registerPayoutPlugin(address(pluginA), 0.5e18);
        (PoolId idA,,) = _launchWithPlan("Batch A", "BTCA", _plan(indexA));
        _fundPot(idA, 0, 100 ether);
        RecordingPayoutPlugin pluginB = new RecordingPayoutPlugin();
        uint8 indexB = _registerPayoutPlugin(address(pluginB), 0.5e18);
        (PoolId idB,,) = _launchWithPlan("Batch B", "BTCB", _plan(indexB));
        _fundPot(idB, 0, 50 ether);

        uint256 claimsBefore = hook.claimBacking();
        vm.recordLogs();
        PoolId[] memory pools = new PoolId[](2);
        pools[0] = idA;
        pools[1] = idB;
        hook.flushBatch(pools, STRANGER);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // Exactly one ERC-6909 burn serves the whole batch: the shared redemption burns the combined
        // total once, where two independent flushes would burn once per pot.
        uint256 burns;
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(manager) && logs[i].topics[0] == IERC6909Claims.Transfer.selector
                    && logs[i].topics[2] == bytes32(0) && logs[i].topics[3] == bytes32(0)
            ) {
                burns += 1;
            }
        }
        assertEq(burns, 1, "the batch did not share exactly one redemption burn");
        // Attribution stays per pot even though the burn and take were shared. The burn covers the two
        // NET pots (90 + 45); the 15 ether service fee remains claim-backed in the protocol subset.
        assertEq(_countLogs(logs, MilestoneBase.PayoutPotRedeemed.selector), 2, "per-pot redemption lost");
        assertEq(claimsBefore - hook.claimBacking(), 135 ether, "the shared burn did not redeem the net pot total");
        assertEq(hook.payoutPot(idA), 0, "pot A survived the batch");
        assertEq(hook.payoutPot(idB), 0, "pot B survived the batch");
        assertEq(pluginA.totalReceived(), 44.55 ether, "pool A delivery wrong");
        assertEq(pluginB.totalReceived(), 22.275 ether, "pool B delivery wrong");
        assertEq(hook.creatorPathClaimable(idA), 44.55 ether, "pool A remainder wrong");
        assertEq(hook.creatorPathClaimable(idB), 22.275 ether, "pool B remainder wrong");
    }

    // --- Scenario: Batch tips transfer once ---
    function test_batchTipsTransferOnce() public {
        RecordingPayoutPlugin pluginA = new RecordingPayoutPlugin();
        uint8 indexA = _registerPayoutPlugin(address(pluginA), 0.5e18);
        (PoolId idA,,) = _launchWithPlan("Tip A", "TIPA", _plan(indexA));
        _fundPot(idA, 0, 100 ether);
        RecordingPayoutPlugin pluginB = new RecordingPayoutPlugin();
        uint8 indexB = _registerPayoutPlugin(address(pluginB), 0.5e18);
        (PoolId idB,,) = _launchWithPlan("Tip B", "TIPB", _plan(indexB));
        _fundPot(idB, 0, 50 ether);

        CountingTipRecipient recipient = new CountingTipRecipient();
        PoolId[] memory pools = new PoolId[](2);
        pools[0] = idA;
        pools[1] = idB;
        hook.flushBatch(pools, address(recipient));

        // Per-pot attribution in the events, one physical transfer to the recipient.
        assertEq(recipient.timesPaid(), 1, "tips left in more than one transfer");
        assertEq(address(recipient).balance, 0.9 ether + 0.45 ether, "combined tip amount wrong");
    }

    // --- Scenario: A batch is all-or-nothing ---
    function test_aBatchIsAllOrNothing() public {
        RecordingPayoutPlugin pluginA = new RecordingPayoutPlugin();
        uint8 indexA = _registerPayoutPlugin(address(pluginA), 0.5e18);
        (PoolId idA,,) = _launchWithPlan("Atom A", "ATMA", _plan(indexA));
        _fundPot(idA, 0, 100 ether);
        RecordingPayoutPlugin pluginB = new RecordingPayoutPlugin();
        uint8 indexB = _registerPayoutPlugin(address(pluginB), 0.5e18);
        (PoolId idB,,) = _launchWithPlan("Atom B", "ATMB", _plan(indexB));

        // Measure what one pool's flush costs, then starve the batch so pool A delivers but pool B's
        // first preflight finds too little gas left. The window is wide: a max-stipend preflight needs
        // about 723k gas, so anything between A's real cost and that leaves B failing and A complete
        // before the revert.
        uint256 start = gasleft();
        hook.flushTo(idA, STRANGER);
        uint256 singleCost = start - gasleft();
        assertEq(hook.payoutPot(idA), 0, "measurement flush did not complete");

        // Fund both pots through the test hook and rerun as a batch, starved.
        _fundPot(idA, 1, 100 ether);
        _fundPot(idB, 2, 100 ether);
        uint256 remainderBefore = hook.creatorPathClaimable(idA);
        PoolId[] memory pools = new PoolId[](2);
        pools[0] = idA;
        pools[1] = idB;
        vm.expectPartialRevert(MilestoneBase.InsufficientPayoutGas.selector);
        hook.flushBatch{gas: singleCost + 200_000}(pools, STRANGER);

        // Nothing from either pool survived the revert: pots, plugin deliveries, and the creator
        // remainder all match the pre-batch state.
        assertEq(hook.payoutPot(idA), 90 ether, "pool A's pot did not restore atomically");
        assertEq(hook.payoutPot(idB), 90 ether, "pool B's pot did not restore atomically");
        assertEq(pluginA.calls(), 1, "pool A's earlier single flush should be its only delivery");
        assertEq(pluginB.calls(), 0, "pool B's plugin must never have been reached");
        assertEq(hook.creatorPathClaimable(idA), remainderBefore, "pool A's remainder did not roll back");
    }

    /// @dev A zero tip recipient would silently burn the tips, so it is rejected outright.
    function test_flushToRejectsAZeroRecipient() public {
        _fundPot(poolId, 0, 100 ether);
        vm.expectRevert(abi.encodeWithSelector(MilestoneBase.ZeroAddress.selector));
        hook.flushTo(poolId, address(0));
        assertEq(hook.payoutPot(poolId), 90 ether, "rejected flush disturbed the pot");
    }

    // --- Flush and creator-path ceilings bound measured operations: derived, no scenario of its own ---

    /// @dev The batch-sizing contract: the published ceiling is an upper bound on real gas, including
    /// a carry retry of an entry that failed once.
    function test_flushGasCeilingCoversTheMeasuredFlush() public {
        SwitchablePayoutPlugin failing = new SwitchablePayoutPlugin();
        RecordingPayoutPlugin accepting = new RecordingPayoutPlugin();
        uint8 a = _registerPayoutPlugin(address(failing), 0.3e18);
        uint8 b = _registerPayoutPlugin(address(accepting), 0.3e18);
        (PoolId id,,) = _launchWithPlan("Ceiling", "CEIL", _plan(a, b));
        _fundPot(id, 0, 100 ether);

        failing.setShouldRevert(true);
        hook.flushTo(id, STRANGER);
        failing.setShouldRevert(false);

        uint256 start = gasleft();
        hook.flushTo(id, STRANGER);
        assertLe(start - gasleft(), hook.flushGasCeiling(id), "measured retry exceeded the published ceiling");
    }

    function test_creatorPathGasCeilingCoversTheMeasuredClaim() public {
        RecordingPayoutPlugin first = new RecordingPayoutPlugin();
        RecordingPayoutPlugin second = new RecordingPayoutPlugin();
        uint8 a = _registerPayoutPlugin(address(first), 0.3e18);
        uint8 b = _registerPayoutPlugin(address(second), 0.3e18);
        (PoolId id,,) = _launchWithPlan("Path Ceiling", "PCEI", _plan(a, b));
        _fundPot(id, 0, 100 ether);

        uint256 start = gasleft();
        vm.prank(creator);
        hook.claimCreatorPath(id);
        assertLe(start - gasleft(), hook.creatorPathGasCeiling(id), "measured claim exceeded the published ceiling");
    }

    // --- Scenario: Ordinary swaps do not flush ---
    function test_ordinarySwapsDoNotFlush() public {
        RecordingPayoutPlugin plugin = new RecordingPayoutPlugin();
        uint8 index = _registerPayoutPlugin(address(plugin), 0.5e18);
        (PoolId id,,) = _launchWithPlan("Swap", "SWAP", _plan(index));
        _fundPot(id, 0, 100 ether);
        vm.prank(BUYER);
        _buy(1 ether);
        assertEq(hook.payoutPot(id), 90 ether);
        assertEq(plugin.calls(), 0);
    }
}

/// @notice Counts physical native transfers, so a test can tell one combined tip transfer from several.
contract CountingTipRecipient {
    uint256 public timesPaid;

    receive() external payable {
        timesPaid += 1;
    }
}
