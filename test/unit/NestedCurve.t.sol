// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolId} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {LaunchpadTest} from "../Fixtures.sol";
import {MilestoneToken} from "../../src/MilestoneToken.sol";
import {CurveLib} from "../../src/libraries/CurveLib.sol";
import {LaunchConfig, PoolState, WAD} from "../../src/types/LaunchTypes.sol";

/// @notice The nested curve's geometry (task 16.1) and its just-in-time deployment (task 16.2) —
/// design Decision 17 for the shape, Decision 15 for the trigger.
///
/// @dev The shape is the Doppler nested form: every position ends at the *shared* far level and starts
/// progressively higher, so they overlap rather than tile. Most of what follows is about that overlap,
/// because it is the property a contiguous equal-slice fan would silently lose — and losing it would not
/// revert anything, it would just make cheap supply abundant at open.
contract NestedCurveTest is LaunchpadTest {
    // --- Scenario: Genesis mints only the first curve position ---

    function test_genesisMintsOnlyTheFirstCurvePosition() public view {
        assertEq(_deployedCurveCount(), 1, "exactly one position exists");
        assertTrue(hook.curvePositionDeployed(poolId, 0), "and it is position 0");

        for (uint256 i = 1; i < template.curvePositions; i++) {
            assertFalse(hook.curvePositionDeployed(poolId, i), "no later position is deployed");
            assertEq(_curveLiquidity(i), 0, "and none holds liquidity");
        }
    }

    /// @dev Position 0 spans the whole opening-to-far range: one thirty-second of inventory stretched
    /// over the entire 2x, which is the thinnest the book ever gets. `_curveLiquidity` reconstructs the
    /// position key from the *far* level, so a non-zero result is itself the assertion that the minted
    /// range ends where the geometry says.
    function test_positionZeroSpansTheOpeningToFarRange() public view {
        PoolState memory state = hook.poolState(poolId);

        assertEq(hook.curvePositionStart(poolId, 0), state.openingLevel, "position 0 starts at the opening level");
        assertEq(
            _curveLiquidity(0),
            CurveLib.positionLiquidity(state.openingLevel, state.farLevel, template.curvePositions, _curveSupply(), 0),
            "and holds exactly the liquidity the geometry derives, over [opening, far]"
        );
    }

    /// @dev Its equal share of the curve supply, measured as the token the manager actually custodies.
    /// Approximate because liquidity is an integer: the mint rounds `L` down from the token amount, so
    /// the position holds up to one `dSqrtPrice`-worth of token less than requested. That is the
    /// specified rounding dust, and it lands in the hook's favour rather than a user's.
    function test_positionZeroHoldsItsEqualShareOfCurveSupply() public view {
        uint256 expected = CurveLib.positionAmount(_curveSupply(), template.curvePositions, 0);
        uint256 held = token.balanceOf(address(manager));

        assertLe(held, expected, "never more than its share");
        assertApproxEqRel(held, expected, 1e12, "and its share up to rounding dust");
    }

    /// @dev "and the pool is tradable" — the launch leaves a book a buyer can hit, which is why curve
    /// minting happens inside the launch transaction rather than in `afterInitialize` (Decision 5).
    function test_thePoolIsTradableAtGenesis() public {
        int24 before_ = _level();

        _buy(1 ether);

        assertGt(_level(), before_, "a buy at genesis moves the price up");
        assertGt(token.balanceOf(address(router)), 0, "and delivers token");
    }

    // --- Scenario: Positions form a nested staircase ---

    function test_startLevelsAscendFromTheOpeningByAUniformStep() public view {
        PoolState memory state = hook.poolState(poolId);
        int256 step = int256(template.curveSpanLevels) / int256(uint256(template.curvePositions));

        assertEq(hook.curvePositionStart(poolId, 0), state.openingLevel, "the first starts at the opening");

        for (uint256 i = 1; i < template.curvePositions; i++) {
            int24 previous = hook.curvePositionStart(poolId, i - 1);
            int24 start = hook.curvePositionStart(poolId, i);

            assertGt(start, previous, "start levels strictly ascend");
            assertLt(start, state.farLevel, "and stay below the shared far level");
            // Computed from the span rather than accumulated, so the step is uniform to within the one
            // level integer division can shave off any single difference.
            assertApproxEqAbs(int256(start) - int256(previous), step, 1, "by a uniform step");
        }
    }

    /// @dev Equal token each, summing to the curve's supply share exactly — the last position absorbs the
    /// division remainder, which is what makes the sum exact rather than approximate.
    function test_positionAmountsAreEqualAndSumToTheCurveShare() public view {
        uint256 curveSupply = _curveSupply();
        uint256 each = CurveLib.positionAmount(curveSupply, template.curvePositions, 0);
        uint256 total;

        for (uint256 i = 0; i < template.curvePositions; i++) {
            uint256 amount = CurveLib.positionAmount(curveSupply, template.curvePositions, i);
            total += amount;

            if (i + 1 < template.curvePositions) {
                assertEq(amount, each, "every position but the last holds an equal share");
            } else {
                assertGe(amount, each, "the last absorbs the remainder");
                assertLt(amount - each, template.curvePositions, "which is at most the divisor");
            }
        }

        assertEq(total, curveSupply, "the amounts sum to the curve supply share exactly");
    }

    /// @dev The staircase itself: equal token over a progressively shorter span is progressively more
    /// liquidity. This is the assertion that fails if the shape ever regresses to a contiguous fan.
    function test_liquidityStaircasesUpwardAcrossPositions() public view {
        PoolState memory state = hook.poolState(poolId);
        uint256 curveSupply = _curveSupply();

        uint128 previous;
        for (uint256 i = 0; i < template.curvePositions; i++) {
            uint128 liquidity =
                CurveLib.positionLiquidity(state.openingLevel, state.farLevel, template.curvePositions, curveSupply, i);

            if (i > 0) assertGt(liquidity, previous, "each position is denser than the last");
            previous = liquidity;
        }
    }

    /// @dev What a buyer actually meets. Just above the opening level only position 0 is in range; near
    /// the far level every position is, and the in-range total is their sum. Measured after a small buy
    /// rather than at genesis because at genesis spot sits exactly on position 0's boundary, where v4
    /// counts nothing as in range.
    function test_activeLiquidityIsThinnestAtTheOpeningAndDensestNearFar() public {
        PoolState memory state = hook.poolState(poolId);
        uint256 curveSupply = _curveSupply();

        // A buy small enough not to reach position 1's start, so the book is position 0 alone. Position
        // 0 holds an eighth of the curve over the whole span, so a fifth of a percent of the span in
        // ETH terms keeps the price well inside its first nested step.
        _buy(0.0001 ether);

        uint128 atOpening = _poolLiquidity(poolId);
        assertEq(_deployedCurveCount(), 1, "still only position 0 is deployed");
        assertEq(
            atOpening,
            CurveLib.positionLiquidity(state.openingLevel, state.farLevel, template.curvePositions, curveSupply, 0),
            "and it alone is in range"
        );

        // Drive the price to the last position's start, so every position is in range at once.
        int24 lastStart = hook.curvePositionStart(poolId, template.curvePositions - 1);
        _buyToLevel(20_000 ether, lastStart);

        uint128 expected;
        for (uint256 i = 0; i < template.curvePositions; i++) {
            if (hook.curvePositionStart(poolId, i) <= _level()) {
                expected += CurveLib.positionLiquidity(
                    state.openingLevel, state.farLevel, template.curvePositions, curveSupply, i
                );
            }
        }

        assertGt(_poolLiquidity(poolId), atOpening, "the book is deeper approaching the far level");
        assertEq(_poolLiquidity(poolId), expected, "by exactly the nested positions now in range");
    }

    // --- Scenario: Later curve positions deploy as price approaches ---

    /// @dev The simulation walks the incoming buy's own price path over the hook-owned liquidity profile
    /// and mints what that path will cross, so the buy fills real liquidity rather than finding a gap.
    ///
    /// The walk is exact, which is what lets this assert an equality rather than a bound: the deployed
    /// set is precisely the positions whose start the final price reached.
    function test_laterCurvePositionsDeployAsPriceApproaches() public {
        assertEq(_deployedCurveCount(), 1, "one position before the buy");

        _buyToLevel(500 ether, hook.curvePositionStart(poolId, 6));

        PoolState memory state = hook.poolState(poolId);
        uint256 reached =
            CurveLib.firstPositionAbove(state.openingLevel, state.farLevel, template.curvePositions, _level());

        assertGt(reached, 1, "the buy moved past position 0's start");
        assertEq(_deployedCurveCount(), reached, "and deployed exactly the positions its path reached");

        // Deployment is a prefix: strictly ascending, so a hole would mean the walk skipped one it crossed.
        for (uint256 i = 0; i < reached; i++) {
            assertTrue(hook.curvePositionDeployed(poolId, i), "every crossed position was minted");
        }
        for (uint256 i = reached; i < template.curvePositions; i++) {
            assertFalse(hook.curvePositionDeployed(poolId, i), "and nothing beyond the path was");
        }
    }

    /// @dev Minted *before* the price arrives, not after. Asserted through the fill: a single buy takes
    /// delivery of more token than position 0 holds in total, which is only possible if the later
    /// positions were already liquidity by the time the swap crossed their starts.
    function test_positionsAreMintedBeforeThePriceArrives() public {
        uint256 positionZeroInventory = CurveLib.positionAmount(_curveSupply(), template.curvePositions, 0);

        _buy(300 ether);

        assertGt(_deployedCurveCount(), 1, "the buy deployed as it went");
        assertGt(
            token.balanceOf(address(router)),
            positionZeroInventory,
            "and filled beyond position 0's entire inventory in one swap"
        );
    }

    /// @dev A sell can never deploy a curve position: the positions are single-sided token above spot,
    /// so a downward price path crosses no start level that could be minted.
    function test_aSellDeploysNoCurvePosition() public {
        _buy(50 ether);
        uint256 deployedBefore = _deployedCurveCount();
        assertGt(deployedBefore, 1, "the buy deployed some");

        _sell(token.balanceOf(address(router)) / 2);

        assertEq(_deployedCurveCount(), deployedBefore, "selling deploys nothing");
    }

    /// @dev The trigger is the price path, not the trade count. Ten small buys and one buy of their total
    /// arrive at the same place with the same positions deployed — the deployed set is a function of where
    /// the price got to, and the walk re-derives it from scratch on every swap.
    ///
    /// The two paths are compared through the invariant rather than by level equality, because per-swap
    /// fee rounding can leave the two final levels a tick apart.
    function test_deploymentFollowsThePricePathNotTheTradeCount() public {
        for (uint256 i = 0; i < 10; i++) {
            _buy(0.1 ether);
        }

        PoolState memory state = hook.poolState(poolId);
        uint256 stepwise = _deployedCurveCount();

        assertGt(stepwise, 1, "the small buys deployed past position 0");
        assertEq(
            stepwise,
            CurveLib.firstPositionAbove(state.openingLevel, state.farLevel, template.curvePositions, _level()),
            "and deployed exactly the positions below where they ended"
        );

        (PoolId id, PoolKey memory k,) = _launchDirect(_defaultConfig("OneGo", "ONE"));
        router.swap(k, true, -int256(1 ether));

        uint256 oneGo;
        for (uint256 i = 0; i < template.curvePositions; i++) {
            if (hook.curvePositionDeployed(id, i)) oneGo += 1;
        }

        assertEq(oneGo, stepwise, "one buy of the same total reaches the same deployed set");
        assertApproxEqAbs(_levelOf(id), _level(), 2, "having ended at the same level, up to fee rounding");
    }

    // --- A genesis dev buy deploys exactly the positions it consumes: derived from
    // "Later curve positions deploy as price approaches", which no scenario states for the dev buy ---

    /// @dev The dev buy is a hook self-swap, and v4 skips both swap callbacks when the hook is the
    /// swapper — so the curve path cannot rely on `beforeSwap` here, and the launch runs the deployment
    /// explicitly. Without that the dev buy would sweep position 0 alone, pricing the creator's own entry
    /// against the thinnest part of the book and leaving the public raise a gap to fill.
    function test_aGenesisDevBuyDeploysExactlyThePositionsItConsumes() public {
        LaunchConfig memory config = _defaultConfig("DevBuy", "DVB");
        config.devBuyShareWad = 0.05e18;

        (PoolId id,, MilestoneToken t) = _launchDirectWithValue(config, 100 ether);

        PoolState memory state = hook.poolState(id);
        uint256 consumed =
            CurveLib.firstPositionAbove(state.openingLevel, state.farLevel, template.curvePositions, _levelOf(id));

        assertGt(consumed, 1, "the dev buy consumed past position 0");

        uint256 deployed;
        for (uint256 i = 0; i < template.curvePositions; i++) {
            if (hook.curvePositionDeployed(id, i)) deployed += 1;
        }

        assertEq(deployed, consumed, "and exactly those positions were deployed");
        assertEq(
            t.balanceOf(config.creator),
            (config.totalSupply * config.devBuyShareWad) / WAD,
            "the creator received the configured share in full"
        );
    }

    /// @dev With no dev buy the launch deploys exactly one position, so the deployment above is
    /// attributable to the dev buy and not to the launch itself.
    function test_aLaunchWithoutADevBuyDeploysOnlyPositionZero() public {
        (PoolId id,,) = _launchDirect(_defaultConfig("NoDevBuy", "NDB"));

        uint256 deployed;
        for (uint256 i = 0; i < template.curvePositions; i++) {
            if (hook.curvePositionDeployed(id, i)) deployed += 1;
        }

        assertEq(deployed, 1, "only position 0");
    }

    // --- Scenario: No rebalancing occurs over time ---

    /// @dev Nothing about the curve is a function of time: no epochs, no decay, no expiry. A year of
    /// silence leaves ticks, liquidity, and count identical.
    function test_noRebalancingOccursOverTime() public {
        _buy(100 ether);

        uint256 countBefore = _deployedCurveCount();
        int24 levelBefore = _level();
        uint128[] memory liquidityBefore = new uint128[](template.curvePositions);
        int24[] memory startsBefore = new int24[](template.curvePositions);
        for (uint256 i = 0; i < template.curvePositions; i++) {
            liquidityBefore[i] = _curveLiquidity(i);
            startsBefore[i] = hook.curvePositionStart(poolId, i);
        }

        vm.warp(launchTime + 365 days);

        assertEq(_deployedCurveCount(), countBefore, "the count is unchanged");
        assertEq(_level(), levelBefore, "the price is unchanged");
        for (uint256 i = 0; i < template.curvePositions; i++) {
            assertEq(_curveLiquidity(i), liquidityBefore[i], "every position's liquidity is unchanged");
            assertEq(hook.curvePositionStart(poolId, i), startsBefore[i], "and so are its ticks");
        }
    }

    // --- Helpers ---

    function _curveSupply() internal view returns (uint256) {
        return (hook.poolState(poolId).totalSupply * template.curveSupplyShareWad) / WAD;
    }
}
