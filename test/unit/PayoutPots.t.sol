// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {MilestoneToken} from "../../src/MilestoneToken.sol";
import {PayoutTestFixture} from "../mocks/PayoutTestHook.sol";
import {SwitchablePayoutPlugin} from "../mocks/PayoutReferenceMocks.sol";

contract PayoutPotsTest is PayoutTestFixture {
    event PayoutPotFunded(
        PoolId indexed poolId,
        uint32 indexed milestoneIndex,
        uint256 grossQuote,
        uint256 serviceFee,
        uint256 netQuote,
        uint64 economicVersion
    );

    // --- Scenario: Gross harvest is attributable ---
    function test_grossHarvestIsAttributable() public {
        vm.expectEmit(true, true, false, true, address(hook));
        emit PayoutPotFunded(poolId, 7, 100 ether, 10 ether, 90 ether, 1);
        _fundPot(poolId, 7, 100 ether);
    }

    // --- Scenario: Service fee precedes pot funding ---
    function test_serviceFeePrecedesPotFunding() public {
        _fundPot(poolId, 0, 100 ether);
        assertEq(hook.protocolClaimable(), 10 ether);
        assertEq(hook.protocolClaimBacked(), 10 ether);
        assertEq(hook.payoutPot(poolId), 90 ether);
    }

    // --- Scenario: Pots are isolated across pools ---
    function test_potsAreIsolatedAcrossPools() public {
        (PoolId second,,) = _launchWithPlan("Second", "SEC", 0);
        _fundPot(poolId, 0, 100 ether);
        _fundPot(second, 0, 40 ether);
        hook.flush(poolId);
        assertEq(hook.payoutPot(poolId), 0);
        assertEq(hook.payoutPot(second), 36 ether);
        assertEq(hook.creatorPathClaimable(second), 0);
    }

    // --- Scenario: Multiple milestones aggregate without losing history ---
    function test_multipleMilestonesAggregateWithoutLosingHistory() public {
        vm.recordLogs();
        _fundPot(poolId, 2, 10 ether);
        _fundPot(poolId, 5, 20 ether);
        assertEq(hook.payoutPot(poolId), 27 ether);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 fundedSignature = keccak256("PayoutPotFunded(bytes32,uint32,uint256,uint256,uint256,uint64)");
        uint256 funded;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(hook) && logs[i].topics[0] == fundedSignature) ++funded;
        }
        assertEq(funded, 2);
    }

    // --- Scenario: Mid-swap pot and service-fee accrual remain solvent ---
    function test_midSwapPotAndServiceFeeAccrualRemainSolvent() public {
        _fundPot(poolId, 0, 100 ether);
        assertEq(address(hook).balance, 0);
        assertEq(hook.claimBacking(), 100 ether);
        assertEq(hook.claimBackedLiabilities(), 100 ether);
        assertEq(hook.rawEthLiabilities(), 0);
    }

    // --- Scenario: Aggregate liabilities equal component ledgers ---
    function test_aggregateLiabilitiesEqualComponentLedgers() public {
        SwitchablePayoutPlugin plugin = new SwitchablePayoutPlugin();
        uint8 index = _registerPayoutPlugin(address(plugin), 0.5e18);
        (PoolId id,,) = _launchWithPlan("Aggregate", "AGG", _plan(index));
        plugin.setShouldRevert(true);
        _fundPot(id, 0, 100 ether);
        hook.flush(id);
        (
            uint256 pots,
            uint256 carry,
            uint256 creatorPath,
            uint256 directCreator,
            uint256 protocol,
            uint256 protocolBacking
        ) = hook.aggregateLiabilities();
        assertEq(pots, 0);
        assertEq(carry, hook.pluginCarry(id, index));
        assertEq(creatorPath, hook.creatorPathClaimable(id));
        assertEq(directCreator, 0);
        assertEq(protocol, 10 ether);
        assertEq(protocolBacking, 10 ether);
        assertEq(hook.totalLiabilities(), carry + creatorPath + protocol);
    }

    // --- Scenario: Custody classes cover their liabilities ---
    function test_custodyClassesCoverTheirLiabilities() public {
        _fundPot(poolId, 0, 100 ether);
        payoutHook.accrueDirectCreator{value: 3 ether}(poolId, 3 ether);
        payoutHook.accrueRawProtocol{value: 2 ether}(poolId, 2 ether);
        assertEq(hook.claimBacking(), hook.claimBackedLiabilities());
        assertEq(address(hook).balance, hook.rawEthLiabilities());
        assertEq(hook.nativeBacking(), hook.totalLiabilities());
    }

    // --- Scenario: Protocol claim redeems only protocol backing ---
    // --- Scenario (revenue-claims): Protocol claim leaves payout backing intact ---
    function test_protocolClaimRedeemsOnlyProtocolBacking() public {
        _fundPot(poolId, 0, 100 ether);
        payoutHook.accrueRawProtocol{value: 2 ether}(poolId, 2 ether);
        uint256 beforeRecipient = PROTOCOL_RECIPIENT.balance;
        vm.prank(PROTOCOL_RECIPIENT);
        uint256 claimed = hook.claimProtocol();
        assertEq(claimed, 12 ether);
        assertEq(PROTOCOL_RECIPIENT.balance - beforeRecipient, 12 ether);
        assertEq(hook.claimBacking(), 90 ether);
        assertEq(hook.payoutPot(poolId), 90 ether);
        assertEq(hook.protocolClaimable(), 0);
        assertEq(hook.protocolClaimBacked(), 0);
    }
}
