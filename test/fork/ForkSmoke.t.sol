// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Bounds, Phase, PoolState} from "../../src/types/LaunchTypes.sol";

import {BaseForkTest} from "./ForkFixtures.sol";

/// @notice The fork layer's smoke test: a relayed signed launch and one buy, against the deployed Base v4
/// `PoolManager` rather than a locally compiled one (task 12.1).
///
/// @dev Deliberately thin. Its job is to fail loudly and early if the layer's premise is broken — wrong
/// chain, no manager at the pinned address, an interface drift between the pinned submodule and the
/// deployed singleton — so that a failure in the lifecycle, orientation or adversarial suites can be read
/// as being about the ladder rather than about the harness. Everything asserted here is asserted again in
/// substance by those suites; this is the one that says *where*.
contract ForkSmokeTest is BaseForkTest {
    // --- The fork is bound to live v4: derived, no scenario of its own ---

    function test_theCounterpartyIsTheDeployedBaseV4Singleton() public view {
        assertEq(block.chainid, BASE_CHAIN_ID, "chain id");
        assertEq(block.number, BASE_FORK_BLOCK, "the fork is pinned where it says it is");
        assertEq(address(manager), BASE_POOL_MANAGER, "the fixture bound the live manager");

        // Not our build of it: this code was on Base before this repo compiled anything.
        assertGt(address(manager).code.length, 0, "the live manager has code");
        assertEq(address(hook).code.length > 0, true, "the hook was placed");

        // The pool exists *in the live manager's* storage, which is the whole claim of this layer.
        (uint160 sqrtPriceX96,) = _slot0();
        assertGt(sqrtPriceX96, 0, "the launch initialised a pool in the deployed singleton");
    }

    function test_theActorSetIsFunded() public view {
        assertEq(BUYER.balance, FORK_FLOAT, "buyer");
        assertEq(RELAYER.balance, FORK_FLOAT, "relayer");
        assertEq(STRANGER.balance, FORK_FLOAT, "stranger");
        assertEq(creator.balance, FORK_FLOAT, "creator");
        assertEq(address(router).balance, FORK_FLOAT, "router float");
    }

    // --- Scenario (token-launch): Relayer launches for the signer ---

    function test_aRelayerCanLaunchOnTheCreatorsBehalf() public view {
        PoolState memory state = hook.poolState(poolId);

        assertEq(uint8(state.phase), uint8(Phase.BONDING_CURVE), "phase");
        assertEq(state.creator, creator, "the recovered signer is the creator, not the relayer");
        assertEq(state.token, address(token), "token");
        assertEq(state.totalSupply, SUPPLY, "supply");
        assertEq(token.totalSupply(), SUPPLY, "the deployed token agrees");

        // Relaying only changes the transaction sender; the signed creator remains the launch identity.
        assertEq(token.balanceOf(creator), 0, "the creator holds nothing yet");
    }

    // --- Scenario (revenue-claims): NFT is minted to the creator at launch ---

    function test_theRevenueNftIsMintedToTheCreator() public view {
        uint256 tokenId = nft.tokenIdOf(poolId);
        assertEq(nft.ownerOf(tokenId), creator, "the NFT went to the signer, not the relayer");
    }

    // --- Scenario (bonding-curve-phase): Genesis mints only the first curve position ---

    function test_genesisMintsOnlyTheFirstCurvePosition() public view {
        assertEq(_deployedCurveCount(), 1, "one curve position at genesis");
        assertGt(_curveLiquidity(0), 0, "and it is live in the deployed manager");
        assertEq(_curveLiquidity(1), 0, "position 1 waits for the price to approach it");
    }

    // --- Scenario (token-launch): Starting price matches anchored FDV ---

    function test_theStartingPriceIsTheAnchoredOpeningLevel() public view {
        PoolState memory state = hook.poolState(poolId);
        assertEq(_level(), state.openingLevel, "the live pool opened exactly at the anchored level");
        assertEq(int256(state.farLevel - state.openingLevel), int256(template.curveSpanLevels), "curve span");
    }

    // --- Scenario (token-launch): Pool has no dynamic-fee flag ---
    // --- Scenario (token-launch): Pool uses static one percent ---

    function test_thePoolUsesStaticOnePercent() public view {
        assertEq(uint256(key.fee), uint256(Bounds.TRADING_FEE_HUNDREDTHS_BIP), "the key publishes one percent");
        assertEq(
            uint256(_baseFeeOf(poolId)), uint256(Bounds.TRADING_FEE_HUNDREDTHS_BIP), "the live fee stays one percent"
        );
    }

    // --- Scenario (bonding-curve-phase): Buyers can always buy ---

    function test_oneBuyExecutesAgainstRealV4() public {
        int24 openingLevel = _level();
        uint256 managerEthBefore = address(manager).balance;

        _buy(1 ether);

        assertGt(_level(), openingLevel, "the buy moved the level up, so the curve is on the right side");
        assertGt(token.balanceOf(address(router)), 0, "the buyer received token out of the curve");
        assertEq(address(manager).balance - managerEthBefore, 1 ether, "the deployed manager took the ETH in");
    }

    /// @dev The half of Decision 15 a single small buy does not reach: positions 1-31 exist only because the
    /// deploy simulation runs against v4's own math, so "the simulation agrees with the real pool" is a
    /// claim only the live manager can settle.
    function test_theCurveDeploysJustInTimeAgainstRealV4() public {
        PoolState memory state = hook.poolState(poolId);
        int24 halfway = state.openingLevel + template.curveSpanLevels / 2;

        _buyToLevel(FORK_FLOAT, halfway);

        assertGe(_level(), halfway, "the buy reached halfway up the curve span");
        assertGt(_deployedCurveCount(), 1, "which deployed curve positions beyond genesis");
        assertEq(uint8(hook.poolPhase(poolId)), uint8(Phase.BONDING_CURVE), "and did not graduate on the way");
    }
}
