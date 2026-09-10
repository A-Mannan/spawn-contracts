// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LaunchConfig, Phase, PoolState, WAD} from "../../src/types/LaunchTypes.sol";

import {BaseForkHarnessTest} from "./ForkFixtures.sol";

/// @notice One launch driven through graduation, payout delivery, fee collection, and claims against Base v4.
contract ForkLifecycleTest is BaseForkHarnessTest {
    uint256 private constant DEV_BUY_BUDGET = 50_000 ether;
    uint64 private constant DEV_BUY_SHARE_WAD = 0.02e18;
    uint256 private constant RUNUP_BUDGET = 1_000_000 ether;
    uint32 private constant SWEEP_TOP = 4;
    int24 private constant INSIDE = 100;

    function test_theWholeLifecycleRunsAgainstLiveV4() public {
        _launchWithDeliveredDevBuy();
        _fillTheCurveAndGraduate();
        _harvestFundsThePotAndCreatorClaimsIt();
        _feesAccrueWithoutCompounding();
        _directAndGlobalClaimsSettle();
    }

    // --- Scenario (token-launch): Dev buy consumes curve inventory ---
    // --- Scenario (token-launch): Tokens are delivered fully at launch ---
    // --- Scenario (token-launch): No vesting state is created ---
    function _launchWithDeliveredDevBuy() private {
        LaunchConfig memory config = _defaultConfig("Lifecycle", "LIFE");
        config.devBuyShareWad = DEV_BUY_SHARE_WAD;
        uint256 requested = config.totalSupply * DEV_BUY_SHARE_WAD / WAD;

        (poolId, key, token) = _launchSignedByCreatorWithValue(config, DEV_BUY_BUDGET);

        assertEq(token.balanceOf(creator), requested, "the creator receives the complete dev buy immediately");
        assertEq(token.totalSupply(), config.totalSupply, "the dev buy consumes inventory rather than minting");
        assertGt(_deployedCurveCount(), 1, "the order deploys enough curve positions to fill itself");
        assertLt(_deployedCurveCount(), template.curvePositions, "deployment remains just in time");
    }

    // --- Scenario (graduation): Default split is applied ---
    // --- Scenario (graduation): Curve tokens become ladder inventory ---
    // --- Scenario (graduation): Graduation seeds both sides from original allocations ---
    function _fillTheCurveAndGraduate() private {
        PoolState memory before = hook.poolState(poolId);
        int24 halfway = before.openingLevel + template.curveSpanLevels / 2;
        _buyToLevel(FORK_FLOAT, halfway);
        assertGe(_level(), halfway, "the live manager fills the just-in-time curve");
        assertGt(_deployedCurveCount(), 1, "later curve positions are live");

        _buyToLevel(FORK_FLOAT, before.farLevel);
        assertEq(uint8(hook.poolPhase(poolId)), uint8(Phase.BONDING_CURVE), "the crossing swap does not graduate");
        _buy(1_000);

        PoolState memory state = hook.poolState(poolId);
        assertEq(uint8(state.phase), uint8(Phase.GRADUATED), "the next swap graduates in place");
        assertEq(_deployedCurveCount(), 0, "every curve position is removed");
        assertGt(state.fullRangeLiquidity, 0, "graduation seeds locked full-range liquidity");
        assertEq(_fullRangeLiquidity(), state.fullRangeLiquidity, "the live manager agrees with state");
        assertGt(state.ladderInventoryRemaining, 0, "curve inventory becomes ladder inventory");
    }

    // --- Scenario (milestone-ladder): Active service fee is applied ---
    // --- Scenario (milestone-ladder): Net harvest funds only its source pool ---
    // --- Scenario (payout-plugins): Creator self-flush preserves the tip ---
    // --- Scenario (payout-plugins): Empty plan pays the creator ---
    function _harvestFundsThePotAndCreatorClaimsIt() private {
        uint256 directBefore = hook.creatorClaimable(poolId);
        uint256 protocolBefore = hook.protocolClaimable();
        uint256 potBefore = hook.payoutPot(poolId);

        _buyToLevel(RUNUP_BUDGET, _bandLower(SWEEP_TOP) + INSIDE);

        uint256 potFunded = hook.payoutPot(poolId) - potBefore;
        uint256 serviceFee = hook.protocolClaimable() - protocolBefore;
        uint256 gross = potFunded + serviceFee;
        assertGt(potFunded, 0, "completed bands fund a net payout pot");
        assertEq(serviceFee, gross / 10, "the active ten percent service fee precedes pot funding");
        assertEq(hook.creatorClaimable(poolId), directBefore, "harvest does not credit direct creator revenue");
        assertGt(_completedBandCount(), 0, "the live manager completed milestones");

        uint256 creatorEthBefore = creator.balance;
        vm.prank(creator);
        (bool success, uint256 attempted) = hook.claimCreatorPath(poolId);
        assertTrue(success, "the current NFT holder receives the creator path");
        assertEq(attempted, potFunded, "the empty plan and retained tip preserve the complete net pot");
        assertEq(creator.balance - creatorEthBefore, attempted, "creator receives real ETH");
        assertEq(hook.payoutPot(poolId), 0, "the new pot is redeemed exactly once");
        assertEq(hook.creatorPathClaimable(poolId), 0, "the successful transfer clears creator-path liability");
    }

    // --- Scenario (swap-fees): Default quote split is 75 25 ---
    // --- Scenario (swap-fees): Default token routing funds 20 and burns 80 ---
    // --- Scenario (swap-fees): Collected fees never compound ---
    // --- Scenario (swap-fees): Any address can collect ---
    function _feesAccrueWithoutCompounding() private {
        _sellAllToLevel(_bandLower(SWEEP_TOP) - 4 * INSIDE);
        _buyToLevel(RUNUP_BUDGET, _bandLower(SWEEP_TOP) + 2 * INSIDE);

        uint256 creatorBefore = hook.creatorClaimable(poolId);
        uint256 protocolBefore = hook.protocolClaimable();
        uint256 fundBefore = hook.poolState(poolId).milestoneFundAccrued;
        uint256 supplyBefore = token.totalSupply();
        uint128 liquidityBefore = _fullRangeLiquidity();

        vm.prank(STRANGER);
        (uint256 quoteFees, uint256 tokenFees) = hook.collectFees(key);

        assertGt(quoteFees, 0, "buy-side quote fees were collected");
        assertGt(tokenFees, 0, "sell-side token fees were collected");
        assertEq(hook.creatorClaimable(poolId) - creatorBefore, quoteFees * 75 / 100, "creator receives 75 percent");
        assertEq(
            hook.protocolClaimable() - protocolBefore, quoteFees - quoteFees * 75 / 100, "protocol receives residual"
        );
        assertGe(hook.poolState(poolId).milestoneFundAccrued, fundBefore, "token fees can fund the next band");
        assertLt(token.totalSupply(), supplyBefore, "the token-fee remainder is burned");
        assertEq(_fullRangeLiquidity(), liquidityBefore, "fee collection never compounds liquidity");
    }

    // --- Scenario (revenue-claims): Current holder claims direct revenue ---
    // --- Scenario (revenue-claims): Current recipient claims globally ---
    // --- Scenario (revenue-claims): Protocol claim leaves payout backing intact ---
    function _directAndGlobalClaimsSettle() private {
        uint256 creatorOwed = hook.creatorClaimable(poolId);
        vm.prank(creator);
        assertEq(hook.claimCreator(poolId), creatorOwed, "the holder claims all direct revenue");
        assertEq(hook.creatorClaimable(poolId), 0, "direct creator ledger clears");

        uint256 potBefore = hook.payoutPot(poolId);
        uint256 protocolOwed = hook.protocolClaimable();
        uint256 recipientBefore = PROTOCOL_RECIPIENT.balance;
        vm.prank(PROTOCOL_RECIPIENT);
        assertEq(hook.claimProtocol(), protocolOwed, "the recipient claims the global ledger");
        assertEq(PROTOCOL_RECIPIENT.balance - recipientBefore, protocolOwed, "the recipient receives real ETH");
        assertEq(hook.protocolClaimable(), 0, "global protocol ledger clears");
        assertEq(hook.payoutPot(poolId), potBefore, "protocol settlement leaves payout backing intact");
    }
}
