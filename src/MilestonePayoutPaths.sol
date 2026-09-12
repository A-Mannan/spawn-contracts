// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {BitMath} from "v4-core/src/libraries/BitMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {ImmutableState} from "v4-periphery/src/base/ImmutableState.sol";
import {IPayoutPlugin} from "./interfaces/IPayoutPlugin.sol";
import {MilestoneBase} from "./MilestoneBase.sol";
import {RevenueNFT} from "./RevenueNFT.sol";
import {LaunchSupport} from "./LaunchSupport.sol";
import {TransientLock} from "./libraries/TransientLock.sol";
import {Bounds, Phase, PoolState, ProtocolTemplate, WAD} from "./types/LaunchTypes.sol";
import {PluginEntry, PluginRole} from "./types/PayoutTypes.sol";

/// @title MilestonePayoutPaths
/// @notice Cold payout-pot redemption, isolated plugin delivery, carry retry, and creator entitlement.
/// @dev Reached only by delegatecall from {MilestoneHook}; all mutable state is declared in
/// {MilestoneBase}. Plugin calls run under one protocol-global transient guard. The batch is the
/// primitive: a single-pool flush is a batch of one, which is why there is no separate single-pool
/// delivery body to keep in sync.
contract MilestonePayoutPaths is MilestoneBase {
    uint256 private constant _TIP_DENOMINATOR = 100;

    address private immutable _self;

    error NotDelegated();

    modifier onlyDelegated() {
        if (address(this) == _self) revert NotDelegated();
        _;
    }

    constructor(
        IPoolManager poolManager_,
        RevenueNFT revenueNft_,
        LaunchSupport launchSupport_,
        ProtocolTemplate memory template_,
        address protocolController_
    ) ImmutableState(poolManager_) MilestoneBase(revenueNft_, launchSupport_, template_, protocolController_) {
        _self = address(this);
    }

    /// @notice Flushes one pool, directing the 1% tip to `tipTo`.
    /// @dev The tip recipient is always explicit. Bundlers and batch relays (Multicall3, Safe batches,
    /// keeper wrappers) accept no bare ETH, so a tip routed to them by default would fail the transfer
    /// and revert atomically; passing `msg.sender` reproduces the classic keep-the-tip flush.
    function flushTo(PoolId poolId, address tipTo) external onlyDelegated {
        if (tipTo == address(0)) revert ZeroAddress();
        PoolId[] memory pools = new PoolId[](1);
        pools[0] = poolId;
        _runFlush(pools, tipTo, false, address(0));
    }

    /// @notice Flushes every pool in `pools`, directing all tips to `tipTo`.
    ///
    /// @dev The batch is all-or-nothing: the pots are zeroed first, the complete total is redeemed in
    /// ONE shared unlock (one burn, one take), the combined tips leave in one transfer, and then each
    /// pool is delivered independently by the same ascending-index logic a single flush runs. Any
    /// unrecoverable failure — a rejecting tip recipient, an insufficient-gas preflight — reverts the
    /// complete batch with every pool's accounting unchanged; callers wanting per-pool isolation use
    /// multicall over single-pool {flushTo} instead. A zero tip recipient is rejected rather than
    /// silently burning the tips, and pools with neither pot nor carry are skipped.
    function flushBatch(PoolId[] memory pools, address tipTo) external onlyDelegated {
        if (tipTo == address(0)) revert ZeroAddress();
        _runFlush(pools, tipTo, false, address(0));
    }

    /// @notice Flushes first, then pays complete creator-path entitlement to the initiating NFT holder.
    /// @dev The self-flush tip remains in the final attempt. A rejecting recipient restores the full amount.
    function claimCreatorPath(PoolId poolId) external onlyDelegated returns (bool success, uint256 attemptedAmount) {
        PoolId[] memory pools = new PoolId[](1);
        pools[0] = poolId;
        (bool[] memory successes, uint256[] memory attempted) = _claimCreatorPathBatch(pools);
        return (successes[0], attempted[0]);
    }

    /// @notice Creator-path claim over many pools: one shared redemption, per-pool payment.
    ///
    /// @dev The caller must currently hold every pool's RevenueNFT. The shared flush runs once under
    /// one guard acquisition, ownership is rechecked for every pool after all plugin interactions (any
    /// change reverts the complete batch), and then each pool's complete entitlement — its retained
    /// self-flush tip included — is attempted for the holder. A failed final transfer restores only
    /// that pool's amount and reports `(false, attempted)` for it without reverting the batch.
    function claimCreatorPathBatch(PoolId[] memory pools)
        external
        onlyDelegated
        returns (bool[] memory successes, uint256[] memory attemptedAmounts)
    {
        return _claimCreatorPathBatch(pools);
    }

    function _claimCreatorPathBatch(PoolId[] memory pools)
        private
        returns (bool[] memory successes, uint256[] memory attemptedAmounts)
    {
        TransientLock.requireNoPayoutDelivery();
        address holder = msg.sender;
        uint256 len = pools.length;

        successes = new bool[](len);
        attemptedAmounts = new uint256[](len);
        for (uint256 i; i < len; ++i) {
            if (revenueNFT.ownerOf(revenueNFT.tokenIdOf(pools[i])) != holder) {
                revert NotRevenueNftHolder(pools[i], holder);
            }
        }

        TransientLock.enterPayoutDelivery();
        uint256[] memory tips = _flushBatchHeld(pools, holder, true, holder);

        for (uint256 i; i < len; ++i) {
            address currentHolder = revenueNFT.ownerOf(revenueNFT.tokenIdOf(pools[i]));
            if (currentHolder != holder) revert RevenueNftOwnerChanged(pools[i], holder, currentHolder);
        }

        for (uint256 i; i < len; ++i) {
            (successes[i], attemptedAmounts[i]) = _payCreatorPath(pools[i], holder, tips[i]);
        }

        _assertSolvent();
        TransientLock.exitPayoutDelivery();
    }

    /// @dev Guard lifecycle for a flush entry: the guard is asserted *before* the empty-state return,
    /// not after. A plugin re-entering mid-delivery reaches this function with the pots already zeroed
    /// and its own carry bit already cleared, so an emptiness check placed first would return quietly
    /// and report a successful flush from inside the very delivery it is meant to exclude. Rejecting on
    /// the guard first makes every nested flush observably fail, whatever the pools' momentary balances.
    function _runFlush(PoolId[] memory pools, address tipTo, bool retainTip, address expectedHolder) private {
        TransientLock.requireNoPayoutDelivery();
        if (!_hasWork(pools)) return;
        TransientLock.enterPayoutDelivery();
        _flushBatchHeld(pools, tipTo, retainTip, expectedHolder);
        TransientLock.exitPayoutDelivery();
    }

    function _hasWork(PoolId[] memory pools) private view returns (bool any) {
        uint256 len = pools.length;
        for (uint256 i; i < len; ++i) {
            PoolId id = pools[i];
            if (_payoutPot[id] != 0 || _carryBitmap[id] != 0) {
                if (_pools[id].phase == Phase.NONE) revert NotInBondingCurvePhase(id, Phase.NONE);
                any = true;
            }
        }
    }

    /// @dev The batch body. Assumes the payout-delivery guard is held. Four ordered phases keep the
    /// checks-effects-interactions discipline across the whole batch:
    ///
    /// 1. Snapshot every pot and zero each one, decrementing its aggregate liability, before any
    ///    external call. Duplicate pool entries are skipped on re-read: once a pot is zeroed, a second
    ///    occurrence observes zero and contributes nothing.
    /// 2. One shared `REDEEM_PAYOUT_POT` unlock redeems the complete total — one burn, one take — with
    ///    the per-pot amounts in the payload, and a per-pot `PayoutPotRedeemed` preserves attribution.
    /// 3. The combined tip leaves in ONE transfer to `tipTo`, attributed per pot by `PayoutTipPaid`.
    ///    Under `retainTip` no transfer happens and each pool's tip is returned to the caller, which is
    ///    what the creator-path batch folds into its final per-pool attempts.
    /// 4. Each pool with a new pot allocates its own post-tip remainder across its plan and retries its
    ///    carry, exactly as a single flush does; carry-only pools iterate their carry bitmap alone.
    function _flushBatchHeld(PoolId[] memory pools, address tipTo, bool retainTip, address expectedHolder)
        private
        returns (uint256[] memory tips)
    {
        uint256 len = pools.length;
        tips = new uint256[](len);
        uint256[] memory pots = new uint256[](len);
        uint256 totalPot;
        uint256 totalTip;

        for (uint256 i; i < len; ++i) {
            PoolId id = pools[i];
            uint256 pot = _payoutPot[id];
            pots[i] = pot;
            if (pot == 0) continue;

            // Zeroing on read makes a duplicate pool entry in the batch self-skipping: the second
            // occurrence observes an already-zeroed pot and contributes nothing.
            _payoutPot[id] = 0;
            _totalPayoutPotLiability -= pot;
            totalPot += pot;

            uint256 tip = pot / _TIP_DENOMINATOR;
            totalTip += tip;
            tips[i] = tip;
        }

        if (totalPot != 0) {
            poolManager.unlock(abi.encode(uint8(UnlockAction.REDEEM_PAYOUT_POT), pools, pots));
            for (uint256 i; i < len; ++i) {
                if (pots[i] != 0) emit PayoutPotRedeemed(pools[i], pots[i]);
            }

            if (totalTip != 0 && !retainTip) {
                _sendEth(tipTo, totalTip);
                for (uint256 i; i < len; ++i) {
                    if (tips[i] != 0) emit PayoutTipPaid(pools[i], tipTo, tips[i]);
                }
            }
        }

        for (uint256 i; i < len; ++i) {
            _deliverPool(pools[i], pots[i], expectedHolder);
        }
    }

    /// @dev no-via_ir stack limit: per-pool delivery accumulators, bundled so the delivery loop's frame
    /// stays small.
    struct DeliveryState {
        uint256 remainingEntries;
        uint256 allocated;
        uint256 redirected;
    }

    /// @dev Delivers one pool's post-tip pot and retries its carry. `newPot` is the pool's original
    /// snapshot value: non-zero means this pass allocated a fresh pot, zero means a carry-only retry.
    function _deliverPool(PoolId poolId, uint256 newPot, address expectedHolder) private {
        uint256 carryBits = _carryBitmap[poolId];
        if (newPot == 0 && carryBits == 0) return;

        // A new pot allocates across the plan and retries carry in the same pass, so both bitmaps are
        // in scope. A carry-only retry allocates nothing: a selected entry with no carry would resolve to
        // a zero attempt, contribute no call, and only inflate the reserve every real call must clear —
        // so the retry iterates the carry bitmap alone, which is also exactly the set the design names.
        PoolState storage poolState = _pools[poolId];
        uint256 plan = poolState.payoutPlan;
        uint256 bits = newPot != 0 ? plan | carryBits : carryBits;
        uint256 distributable = newPot != 0 ? newPot - newPot / _TIP_DENOMINATOR : 0;
        address token = poolState.token;
        DeliveryState memory st = DeliveryState({remainingEntries: _populationCount(bits), allocated: 0, redirected: 0});

        while (bits != 0) {
            uint8 index = uint8(BitMath.leastSignificantBit(bits));
            bits &= bits - 1;

            // no-via_ir stack limit: the whole per-entry body lives in its own frame. The accumulators
            // come back as the return value, since memory structs are copies.
            st = _processEntry(poolId, token, expectedHolder, newPot, distributable, plan, index, st);
        }

        // The creator receives the complete post-tip arithmetic remainder plus every permanent redirect.
        uint256 creatorAmount = distributable - st.allocated + st.redirected;
        if (creatorAmount != 0) {
            _creatorPathClaimable[poolId] += creatorAmount;
            _totalCreatorPathLiability += creatorAmount;
            emit CreatorPathAccrued(poolId, creatorAmount);
        }

        _assertSolvent();
    }

    /// @dev Resolves, delivers (or carries), and accounts one selected entry. Returns the updated
    /// accumulators; memory structs are copies, so the caller reassigns its own.
    function _processEntry(
        PoolId poolId,
        address token,
        address expectedHolder,
        uint256 newPot,
        uint256 distributable,
        uint256 plan,
        uint8 index,
        DeliveryState memory st
    ) private returns (DeliveryState memory) {
        PluginEntry memory entry = payoutPluginRegistry.entry(index);
        uint256 currentShare;
        if (newPot != 0 && plan & (uint256(1) << index) != 0) {
            currentShare = FullMath.mulDiv(distributable, entry.takeWad, WAD);
            st.allocated += currentShare;
        }

        uint256 previousCarry = _pluginCarry[poolId][index];
        uint256 attempted = currentShare + previousCarry;
        if (attempted == 0) {
            unchecked {
                --st.remainingEntries;
            }
            return st;
        }

        if (previousCarry != 0) {
            _pluginCarry[poolId][index] = 0;
            _carryBitmap[poolId] &= ~(uint256(1) << index);
            _totalPluginCarryLiability -= previousCarry;
        }

        if (!_entryActive(entry)) {
            st.redirected += attempted;
            emit PluginPayoutRedirected(poolId, index, currentShare, previousCarry, attempted);
            unchecked {
                --st.remainingEntries;
            }
            return st;
        }

        if (_deliver(entry, poolId, token, attempted, st.remainingEntries)) {
            emit PluginPayoutDelivered(poolId, index, entry.plugin, currentShare, previousCarry, attempted);
        } else {
            _pluginCarry[poolId][index] = attempted;
            _carryBitmap[poolId] |= uint256(1) << index;
            _totalPluginCarryLiability += attempted;
            emit PluginPayoutCarried(poolId, index, entry.plugin, currentShare, previousCarry, attempted);
        }

        if (expectedHolder != address(0)) {
            _assertHolder(poolId, expectedHolder);
        }

        unchecked {
            --st.remainingEntries;
        }
        return st;
    }

    function _assertHolder(PoolId poolId, address expectedHolder) private view {
        address currentHolder = revenueNFT.ownerOf(revenueNFT.tokenIdOf(poolId));
        if (currentHolder != expectedHolder) {
            revert RevenueNftOwnerChanged(poolId, expectedHolder, currentHolder);
        }
    }

    /// @notice Zeroes and pays one pool's creator-path entitlement, its retained flush tip included.
    /// @dev A failed transfer does not revert: the complete attempted amount is restored to the ledger
    /// and aggregate liability, and the failure is reported through the return pair and an event. The
    /// final transfer is bounded and preflighted for the same reason a plugin call is. The specs require
    /// that a failed transfer *not* revert — the whole amount is restored, an event reports the failure,
    /// and the call returns `(false, attempted)`. With all remaining gas forwarded, a hostile recipient
    /// could consume it and leave EIP-150's 1/64th too thin to restore both ledgers, emit, re-check
    /// solvency and clear the guard, converting a specified recoverable failure into an out-of-gas
    /// revert of the holder's own claim. Reserving {FINALIZE_GAS} outside a call capped at
    /// {MAX_PLUGIN_CALL_GAS} is what makes the restoration path reachable by construction rather than by
    /// the recipient's good behaviour.
    function _payCreatorPath(PoolId poolId, address holder, uint256 retainedTip)
        private
        returns (bool success, uint256 attemptedAmount)
    {
        uint256 entitlement = _creatorPathClaimable[poolId];
        attemptedAmount = entitlement + retainedTip;
        if (entitlement != 0) {
            _creatorPathClaimable[poolId] = 0;
            _totalCreatorPathLiability -= entitlement;
        }

        if (attemptedAmount == 0) {
            success = true;
            emit CreatorPathClaimed(poolId, holder, 0);
            return (true, 0);
        }

        uint256 callGas = Bounds.MAX_PLUGIN_CALL_GAS;
        uint256 required = Bounds.FINALIZE_GAS + callGas + (callGas + 62) / 63 + Bounds.CALL_FIXED_GAS;
        uint256 available = gasleft();
        if (available < required) revert InsufficientPayoutGas(available, required);

        (success,) = holder.call{value: attemptedAmount, gas: callGas}("");
        if (!success) {
            _creatorPathClaimable[poolId] += attemptedAmount;
            _totalCreatorPathLiability += attemptedAmount;
            emit CreatorPathClaimFailed(poolId, holder, attemptedAmount);
        } else {
            emit CreatorPathClaimed(poolId, holder, attemptedAmount);
        }
    }

    function _entryActive(PluginEntry memory entry) private view returns (bool) {
        return !entry.suspended && entry.role == PluginRole.PAYOUT && entry.codeHash != bytes32(0)
            && entry.plugin.codehash == entry.codeHash;
    }

    /// @dev Applies the published outer-gas reserve after calldata materialization, then ignores returndata.
    function _deliver(PluginEntry memory entry, PoolId poolId, address token, uint256 attempted, uint256 remainingCalls)
        private
        returns (bool ok)
    {
        bytes memory payload = abi.encodeCall(IPayoutPlugin.onPayout, (poolId, token));
        uint256 callGas = entry.gasLimit;
        uint256 reserve = remainingCalls * Bounds.POST_CALL_GAS + Bounds.FINALIZE_GAS;
        uint256 eip150Margin = (callGas + 62) / 63;
        uint256 required = reserve + callGas + eip150Margin + Bounds.CALL_FIXED_GAS;
        uint256 available = gasleft();
        if (available < required) revert InsufficientPayoutGas(available, required);

        // `callGas` is passed as the operand verbatim, which is what the published preflight formula
        // budgets for: it requires `callGas` to be available *on top of* the reserve, the EIP-150 margin
        // and {CALL_FIXED_GAS}. A value-bearing CALL additionally grants the callee the EVM's 2,300-gas
        // stipend, drawn from the 9,000-gas positive-value charge that {CALL_FIXED_GAS} already covers.
        // That stipend is intrinsic to transferring value and cannot be declined — netting it out of the
        // operand would neither remove it nor be expressible at all for the registry's legal limits below
        // 2,300, and it would silently contradict both the published constants and the accepted
        // registration range. The registered limit therefore bounds what this contract forwards; the
        // stipend the EVM adds on top is already paid for and accounted.
        address target = entry.plugin;
        assembly ("memory-safe") {
            ok := call(callGas, target, attempted, add(payload, 0x20), mload(payload), 0, 0)
        }
    }

    function _populationCount(uint256 bits) private pure returns (uint256 count) {
        while (bits != 0) {
            bits &= bits - 1;
            unchecked {
                ++count;
            }
        }
    }
}
