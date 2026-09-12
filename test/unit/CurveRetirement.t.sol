// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LaunchpadTest} from "../Fixtures.sol";
import {CurveLib} from "../../src/libraries/CurveLib.sol";
import {Phase, PoolState, WAD} from "../../src/types/LaunchTypes.sol";

/// @notice What graduation does to the nested curve (task 16.3): burns the positions that exist, collects
/// what they accrued, and routes the released token to the ladder rather than to a recipient.
///
/// @dev The premise worth stating up front, because it decides what several of these tests can assert.
/// Graduation triggers at the far level, and under Decision 17 *every* curve position ends at the far
/// level. So a pool that graduates has necessarily crossed all 32 start levels and sold all 32 positions:
/// it cannot graduate holding unbought curve principal, and every position sits at its own lower bound
/// holding no token. Any token the burn returns is therefore fee, which makes the token-side assertions
/// sharp rather than approximate.
///
/// `_burnCurves` nonetheless accounts for undeployed positions' nominal inventory. That branch is the
/// safety net for the specified "a simulation mismatch can only under-deploy" case and is unreachable
/// from outside the contract, which is why it is documented here rather than exercised.
contract CurveRetirementTest is LaunchpadTest {
    // --- Scenario: All curve positions are burned ---

    function test_allCurvePositionsAreBurned() public {
        _graduate();

        assertEq(uint8(hook.poolState(poolId).phase), uint8(Phase.GRADUATED), "the pool graduated");

        for (uint256 i = 0; i < template.curvePositions; i++) {
            assertEq(_curveLiquidity(i), 0, "no curve position holds liquidity");
        }
    }

    /// @dev Graduation runs the whole curve range, not just the positions the price happened to reach, so
    /// a pool that graduated having deployed every position is burned as completely as one that did not.
    function test_everyDeployedPositionIsBurnedWhateverTheDeployedCount() public {
        uint256 deployedBeforeGraduation = _deployedCurveCount();
        assertEq(deployedBeforeGraduation, 1, "one position at genesis");

        _graduate();

        // The bitmap is not cleared — it is the record of what was minted, and nothing reads it after
        // graduation. What matters is that the pool holds none of it.
        for (uint256 i = 0; i < template.curvePositions; i++) {
            assertEq(_curveLiquidity(i), 0, "burned regardless of whether the bitmap still names it");
        }
    }

    // --- Scenario: Accrued curve fees are collected ---

    /// @dev Curve positions earn the pool's ordinary fee on every swap during the phase, and the burn's
    /// returned delta carries principal and fees together — which is why the graduation split ends up
    /// including curve fees without accounting for them separately.
    ///
    /// Pinned against the manager's own ETH balance, which is the sharp form: nothing but the curve
    /// positions holds ETH in this pool before graduation, so that balance *is* the quote the burn
    /// releases, fees included. Reading it between the crossing buy and the graduating swap is exact,
    /// because auto-graduation runs in the triggering swap's `beforeSwap`, before that swap settles a wei.
    function test_accruedCurveFeesAreCollected() public {
        _buy(0.5 ether);
        _sell(token.balanceOf(address(router)) / 2);

        int24 far = hook.poolState(poolId).farLevel;
        _buyToLevel(2_000 ether, far);

        uint256 proceeds = address(manager).balance;
        assertGt(proceeds, 0, "the curves hold quote at the crossing");

        _buy(1_000); // triggers auto-graduation in `beforeSwap`

        uint256 lpSeed = (proceeds * template.lpSeedWad) / WAD;
        uint256 expectedCreator = (proceeds * template.proceedsCreatorWad) / WAD;
        uint256 expectedProtocol = proceeds - lpSeed - expectedCreator;

        uint256 creator_ = hook.creatorClaimable(poolId);
        uint256 protocol_ = hook.protocolClaimable();

        // Approximate in the specified direction. Each of the 32 burns rounds against the hook by up to a
        // wei, so the credits are dust-short of the balance rather than over it — dust the hook retains,
        // never a shortfall charged to a claimant.
        assertLe(creator_, expectedCreator, "the creator is credited no more than the whole balance implies");
        assertApproxEqAbs(creator_, expectedCreator, 200, "and that much up to burn rounding dust");
        assertLe(protocol_, expectedProtocol, "likewise the protocol");
        assertApproxEqAbs(protocol_, expectedProtocol, 200, "so the fee portion was collected rather than left behind");
    }

    /// @dev The token side, and a precise one. A pool graduates at the far level, where every curve
    /// position sits at its own lower bound and therefore holds no token principal at all — so any token
    /// the burn returns is fee. A sell before the crossing pays its fee in token, and that is what shows
    /// up as ladder inventory.
    function test_curveTokenFeesReachTheLadderNotARecipient() public {
        _buy(0.5 ether);
        _sell(token.balanceOf(address(router)) / 2);

        _graduate();

        assertEq(_deployedCurveCount(), template.curvePositions, "the whole curve was deployed and sold");

        PoolState memory state = hook.poolState(poolId);
        assertGt(state.carriedInventory, 0, "so the token carried to the ladder is fee, not principal");

        uint256 curveSupply = (state.totalSupply * template.curveSupplyShareWad) / WAD;
        assertLt(state.carriedInventory, curveSupply, "and is fee-scale, well under the curve's own share");
    }

    // --- Scenario (graduation): Curve tokens become ladder inventory ---

    /// @dev The reachable shape of this scenario. Graduation triggers at the far level and every curve
    /// position *ends* at the far level, so reaching it means the simulation crossed every start and the
    /// buyers consumed every position: a pool cannot graduate holding unbought curve principal.
    ///
    /// The consequence is that with no token-denominated fees there is nothing to carry, and the correct
    /// answer is zero. `_burnCurves` still accounts for undeployed positions' nominal inventory — that
    /// branch is the safety net for the specified "a simulation mismatch can only under-deploy" case,
    /// where the real swap outruns the walk and a position the price passed was never minted. It cannot be
    /// provoked from outside the contract, because the walk is exact by construction.
    function test_aPoolCannotGraduateHoldingUnboughtCurveInventory() public {
        _graduate();

        assertEq(_deployedCurveCount(), template.curvePositions, "every position was deployed");

        PoolState memory state = hook.poolState(poolId);
        uint256 curveSupply = (state.totalSupply * template.curveSupplyShareWad) / WAD;

        uint256 undeployedNominal;
        for (uint256 i = 0; i < template.curvePositions; i++) {
            if (!hook.curvePositionDeployed(poolId, i)) {
                undeployedNominal += CurveLib.positionAmount(curveSupply, template.curvePositions, i);
            }
        }

        assertEq(undeployedNominal, 0, "so no position's inventory went unsettled");
        assertEq(state.carriedInventory, 0, "and a pure-buy graduation carries nothing: there was nothing to carry");
    }

    /// @dev Whatever *is* carried has to be backed by real custody, or the first band mint would fail on a
    /// transfer the balance cannot cover. Asserted against both ledgers at once, since the band path draws
    /// on `ladderInventoryRemaining` and `carriedInventory` together.
    function test_carriedLadderInventoryIsBackedByHookCustody() public {
        _buy(0.5 ether);
        _sell(token.balanceOf(address(router)) / 2);

        _graduate();

        PoolState memory state = hook.poolState(poolId);
        assertGt(state.carriedInventory, 0, "there is carried inventory to back");
        assertGe(
            token.balanceOf(address(hook)),
            state.ladderInventoryRemaining + state.carriedInventory,
            "hook custody covers both ladder ledgers"
        );
    }

    /// @dev "never to a recipient" — the token side of graduation credits no claimable balance and pushes
    /// nothing. The creator and protocol ledgers are quote-only (Decision 21), so there is no token ledger
    /// for this inventory to leak into.
    function test_ladderInventoryIsNeverCreditedToARecipient() public {
        _buy(0.5 ether);
        _sell(token.balanceOf(address(router)) / 2);

        uint256 creatorTokenBefore = token.balanceOf(creator);
        uint256 protocolTokenBefore = token.balanceOf(PROTOCOL_RECIPIENT);

        _graduate();

        assertEq(token.balanceOf(creator), creatorTokenBefore, "no token was pushed to the creator");
        assertEq(token.balanceOf(PROTOCOL_RECIPIENT), protocolTokenBefore, "nor to the protocol");
        assertGt(hook.poolState(poolId).carriedInventory, 0, "it is all ladder inventory");
    }

    // --- Scenario: Ladder inventory is untouched by seeding ---

    /// @dev The ladder's own supply share is untouched by graduation: the full-range seed is funded from
    /// the template's separate full-range share, never from band inventory.
    function test_theLadderSupplyShareIsUntouchedBySeeding() public {
        PoolState memory state = hook.poolState(poolId);
        uint256 ladderShare = (state.totalSupply * template.ladderSupplyShareWad) / WAD;

        _graduate();

        assertEq(hook.poolState(poolId).ladderInventoryRemaining, ladderShare, "the ladder supply share is unspent");
        assertGt(_fullRangeLiquidity(), 0, "even though the full-range position was seeded");
    }
}
