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
import {Phase, ProtocolTemplate, WAD} from "./types/LaunchTypes.sol";
import {PluginEntry, PluginRole} from "./types/PayoutTypes.sol";

/// @title MilestonePayoutPaths
/// @notice Cold payout-pot redemption, isolated plugin delivery, carry retry, and creator entitlement.
/// @dev Reached only by delegatecall from {MilestoneHook}; all mutable state is declared in
/// {MilestoneBase}. Plugin calls run under one protocol-global transient guard.
contract MilestonePayoutPaths is MilestoneBase {
    uint256 private constant _TIP_DENOMINATOR = 100;
    uint256 public constant CALL_FIXED_GAS = 15_000;
    uint256 public constant POST_CALL_GAS = 100_000;
    uint256 public constant FINALIZE_GAS = 100_000;
    uint256 public constant MAX_PLUGIN_CALL_GAS = 500_000;

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

    /// @notice Delivers a pool's complete new pot and retries every carried allocation.
    ///
    /// @dev The guard is asserted *before* the empty-state return, not after. A plugin re-entering
    /// mid-delivery reaches this function with the pot already zeroed and its own carry bit already
    /// cleared, so an emptiness check placed first would return quietly and report a successful flush
    /// from inside the very delivery it is meant to exclude. Rejecting on the guard first makes every
    /// nested flush observably fail, whatever the pool's momentary balances happen to be.
    function flush(PoolId poolId) external onlyDelegated {
        TransientLock.requireNoPayoutDelivery();
        if (_payoutPot[poolId] == 0 && _carryBitmap[poolId] == 0) return;
        TransientLock.enterPayoutDelivery();
        _flushHeld(poolId, msg.sender, false, address(0));
        TransientLock.exitPayoutDelivery();
    }

    /// @notice Flushes first, then pays complete creator-path entitlement to the initiating NFT holder.
    /// @dev The self-flush tip remains in the final attempt. A rejecting recipient restores the full amount.
    function claimCreatorPath(PoolId poolId) external onlyDelegated returns (bool success, uint256 attemptedAmount) {
        TransientLock.requireNoPayoutDelivery();
        address holder = revenueNFT.ownerOf(revenueNFT.tokenIdOf(poolId));
        if (msg.sender != holder) revert NotRevenueNftHolder(poolId, msg.sender);

        TransientLock.enterPayoutDelivery();
        uint256 retainedTip = _flushHeld(poolId, holder, true, holder);

        address currentHolder = revenueNFT.ownerOf(revenueNFT.tokenIdOf(poolId));
        if (currentHolder != holder) revert RevenueNftOwnerChanged(poolId, holder, currentHolder);

        uint256 entitlement = _creatorPathClaimable[poolId];
        attemptedAmount = entitlement + retainedTip;
        if (entitlement != 0) {
            _creatorPathClaimable[poolId] = 0;
            _totalCreatorPathLiability -= entitlement;
        }

        if (attemptedAmount == 0) {
            success = true;
            emit CreatorPathClaimed(poolId, holder, 0);
        } else {
            // The final transfer is bounded and preflighted for the same reason a plugin call is. The
            // specs require that a failed transfer *not* revert — the whole amount is restored, an event
            // reports the failure, and the call returns `(false, attempted)`. With all remaining gas
            // forwarded, a hostile recipient could consume it and leave EIP-150's 1/64th too thin to
            // restore both ledgers, emit, re-check solvency and clear the guard, converting a specified
            // recoverable failure into an out-of-gas revert of the holder's own claim. Reserving
            // {FINALIZE_GAS} outside a call capped at {MAX_PLUGIN_CALL_GAS} is what makes the restoration
            // path reachable by construction rather than by the recipient's good behaviour.
            uint256 callGas = MAX_PLUGIN_CALL_GAS;
            uint256 required = FINALIZE_GAS + callGas + (callGas + 62) / 63 + CALL_FIXED_GAS;
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

        _assertSolvent();
        TransientLock.exitPayoutDelivery();
    }

    function _flushHeld(PoolId poolId, address flusher, bool retainTip, address expectedHolder)
        private
        returns (uint256 tip)
    {
        uint256 newPot = _payoutPot[poolId];
        uint256 carryBits = _carryBitmap[poolId];
        if (newPot == 0 && carryBits == 0) return 0;
        if (_pools[poolId].phase == Phase.NONE) revert NotInBondingCurvePhase(poolId, Phase.NONE);

        uint256 distributable;
        if (newPot != 0) {
            _payoutPot[poolId] = 0;
            _totalPayoutPotLiability -= newPot;
            poolManager.unlock(abi.encode(uint8(UnlockAction.REDEEM_PAYOUT_POT), poolId, newPot));
            emit PayoutPotRedeemed(poolId, newPot);

            tip = newPot / _TIP_DENOMINATOR;
            distributable = newPot - tip;
            if (tip != 0 && !retainTip) {
                _sendEth(flusher, tip);
                emit PayoutTipPaid(poolId, flusher, tip);
            }
        }

        // A new pot allocates across the plan and retries carry in the same pass, so both bitmaps are
        // in scope. A carry-only retry allocates nothing: a selected entry with no carry would resolve to
        // a zero attempt, contribute no call, and only inflate the reserve every real call must clear —
        // so the retry iterates the carry bitmap alone, which is also exactly the set the design names.
        uint256 plan = _pools[poolId].payoutPlan;
        uint256 bits = newPot != 0 ? plan | carryBits : carryBits;
        uint256 remainingEntries = _populationCount(bits);
        uint256 allocated;
        uint256 redirected;

        while (bits != 0) {
            uint8 index = uint8(BitMath.leastSignificantBit(bits));
            bits &= bits - 1;

            PluginEntry memory entry = payoutPluginRegistry.entry(index);
            uint256 currentShare;
            if (newPot != 0 && plan & (uint256(1) << index) != 0) {
                currentShare = FullMath.mulDiv(distributable, entry.takeWad, WAD);
                allocated += currentShare;
            }

            uint256 previousCarry = _pluginCarry[poolId][index];
            uint256 attempted = currentShare + previousCarry;
            if (attempted == 0) {
                unchecked {
                    --remainingEntries;
                }
                continue;
            }

            if (previousCarry != 0) {
                _pluginCarry[poolId][index] = 0;
                _carryBitmap[poolId] &= ~(uint256(1) << index);
                _totalPluginCarryLiability -= previousCarry;
            }

            if (!_entryActive(entry)) {
                redirected += attempted;
                emit PluginPayoutRedirected(poolId, index, currentShare, previousCarry, attempted);
                unchecked {
                    --remainingEntries;
                }
                continue;
            }

            if (_deliver(entry, poolId, _pools[poolId].token, attempted, remainingEntries)) {
                emit PluginPayoutDelivered(poolId, index, entry.plugin, currentShare, previousCarry, attempted);
            } else {
                _pluginCarry[poolId][index] = attempted;
                _carryBitmap[poolId] |= uint256(1) << index;
                _totalPluginCarryLiability += attempted;
                emit PluginPayoutCarried(poolId, index, entry.plugin, currentShare, previousCarry, attempted);
            }

            if (expectedHolder != address(0)) {
                address currentHolder = revenueNFT.ownerOf(revenueNFT.tokenIdOf(poolId));
                if (currentHolder != expectedHolder) {
                    revert RevenueNftOwnerChanged(poolId, expectedHolder, currentHolder);
                }
            }

            unchecked {
                --remainingEntries;
            }
        }

        // The creator receives the complete post-tip arithmetic remainder plus every permanent redirect.
        uint256 creatorAmount = distributable - allocated + redirected;
        if (creatorAmount != 0) {
            _creatorPathClaimable[poolId] += creatorAmount;
            _totalCreatorPathLiability += creatorAmount;
            emit CreatorPathAccrued(poolId, creatorAmount);
        }

        _assertSolvent();
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
        uint256 reserve = remainingCalls * POST_CALL_GAS + FINALIZE_GAS;
        uint256 eip150Margin = (callGas + 62) / 63;
        uint256 required = reserve + callGas + eip150Margin + CALL_FIXED_GAS;
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
