// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {FixedPoint96} from "v4-core/src/libraries/FixedPoint96.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {Pool} from "v4-core/src/libraries/Pool.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "v4-periphery/src/libraries/LiquidityAmounts.sol";
import {LadderLib} from "../../src/libraries/LadderLib.sol";
import {LaunchConfigLib} from "../../src/libraries/LaunchConfigLib.sol";
import {Orientation} from "../../src/libraries/Orientation.sol";
import {Bounds, LaunchConfig, WAD} from "../../src/types/LaunchTypes.sol";

/// @notice Unit tests for task 8.1 — ladder geometry, covering the `milestone-ladder` scenarios
/// "Band ticks are computable by any observer", "Uniform tick spacing yields geometric market caps",
/// "Band width is a fraction of the gap", and "One geometry setting applies to all bands".
contract LadderLibTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 ether;

    /// @dev A representative graduation level: the default far level.
    int24 internal graduationLevel;
    LaunchConfig internal config;
    UniswapLiquidityHarness internal uniswap;

    function setUp() public {
        config = LaunchConfigLib.defaults(SUPPLY);
        graduationLevel = config.farLevel;
        uniswap = new UniswapLiquidityHarness();
    }

    // --- Scenario: Band ticks are computable by any observer ---

    /// @dev The point of the scenario is that no protocol state is needed. So this recomputes the whole
    /// ladder from the two public inputs with open-coded arithmetic — deliberately not by calling the
    /// library — and requires the library to agree.
    function test_bandsAreDerivableFromConfigAndGraduationLevelAlone() public view {
        for (uint256 i = 0; i < config.bandCount; i++) {
            int24 expectedLower = graduationLevel + int24(int256(i + 1)) * config.bandLevelSpacing;
            int24 expectedUpper = expectedLower + config.bandWidthLevels;

            (int24 lower, int24 upper, bool exists) = LadderLib.bandLevels(config, graduationLevel, i);

            assertTrue(exists, "band exists");
            assertEq(lower, expectedLower, "lower level derivable");
            assertEq(upper, expectedUpper, "upper level derivable");
        }
    }

    /// @dev "lower tick, upper tick, and target inventory" — the tick bounds an observer would watch, and
    /// the inventory they would expect the band to hold.
    function test_bandTicksAndTargetInventoryAreComputable() public view {
        uint256 expectedPerBand = ((SUPPLY * config.ladderSupplyShareWad) / WAD) / config.bandCount;
        assertEq(LadderLib.perBandInventory(config), expectedPerBand, "target inventory computable");

        for (uint256 i = 0; i < config.bandCount; i++) {
            (int24 lower, int24 upper,) = LadderLib.bandLevels(config, graduationLevel, i);
            (int24 tickLower, int24 tickUpper) = Orientation.levelRangeToTicks(lower, upper);

            // Level is -tick, so the bounds swap: the band's dearer edge is its lower tick.
            assertEq(tickLower, -upper, "tick lower");
            assertEq(tickUpper, -lower, "tick upper");
            assertTrue(Orientation.isValidTick(tickLower) && Orientation.isValidTick(tickUpper), "usable ticks");
        }
    }

    /// @dev No band sits at or below graduation: the first is a full spacing step above it, so graduating
    /// does not instantly complete a milestone.
    function test_firstBandSitsOneFullStepAboveGraduation() public view {
        (int24 lower,,) = LadderLib.bandLevels(config, graduationLevel, 0);
        assertEq(lower - graduationLevel, config.bandLevelSpacing, "one full step above graduation");
        assertGt(lower, graduationLevel, "strictly above");
    }

    // --- Scenario: Uniform tick spacing yields geometric market caps ---

    function test_consecutiveBandOffsetsAreConstant() public view {
        int24 previousLower;
        for (uint256 i = 0; i < config.bandCount; i++) {
            (int24 lower,,) = LadderLib.bandLevels(config, graduationLevel, i);
            if (i > 0) {
                assertEq(lower - previousLower, config.bandLevelSpacing, "constant level offset");
            }
            previousLower = lower;
        }
    }

    /// @dev The geometric claim, checked against v4's own price curve rather than restated.
    ///
    /// Market cap per token is ETH-per-token, which is `1.0001^level`. A constant level offset is
    /// therefore a constant price *ratio*, and the ratio between two adjacent bands is
    /// `1.0001^bandLevelSpacing` for every pair.
    function test_marketCapMultipleIsConstantAcrossTheLadder() public view {
        uint256 firstRatio;
        for (uint256 i = 1; i < config.bandCount; i++) {
            (int24 lower,,) = LadderLib.bandLevels(config, graduationLevel, i);
            (int24 previousLower,,) = LadderLib.bandLevels(config, graduationLevel, i - 1);

            uint256 ratio = _capRatioQ96(previousLower, lower);
            if (i == 1) firstRatio = ratio;
            // Same multiple every step; the tolerance absorbs TickMath's fixed-point rounding only.
            assertApproxEqRel(ratio, firstRatio, 0.0001e18, "constant market-cap multiple");
        }
    }

    /// @dev The documented default: a 2x market-cap step is 6931 ticks, `ln(2) / ln(1.0001)`.
    function test_defaultSpacingIsATwoTimesMarketCapStep() public pure {
        assertEq(Bounds.DEFAULT_BAND_LEVEL_SPACING, 6931, "the documented constant");

        uint256 ratio = _capRatioQ96(0, Bounds.DEFAULT_BAND_LEVEL_SPACING);
        assertApproxEqRel(ratio, 2 * FixedPoint96.Q96, 0.001e18, "6931 levels doubles the market cap");
    }

    /// @dev And the floor of the bounds table is a 1.5x step.
    function test_minimumSpacingIsAOnePointFiveTimesStep() public pure {
        uint256 ratio = _capRatioQ96(0, Bounds.MIN_BAND_LEVEL_SPACING);
        assertApproxEqRel(ratio, (3 * FixedPoint96.Q96) / 2, 0.001e18, "4055 levels is a 1.5x step");
    }

    /// @dev Market cap per token at `levelHigh` divided by the same at `levelLow`, in Q96.
    ///
    /// `sqrtPriceX96(tick) = sqrt(1.0001^tick) * 2^96` and `tick = -level`, so ETH-per-token at a level is
    /// `(2^96 / sqrtPriceX96)^2`. The ratio of two of those is `(sLow / sHigh)^2`.
    function _capRatioQ96(int24 levelLow, int24 levelHigh) internal pure returns (uint256) {
        uint160 sLow = TickMath.getSqrtPriceAtTick(Orientation.toTick(levelLow));
        uint160 sHigh = TickMath.getSqrtPriceAtTick(Orientation.toTick(levelHigh));
        return FullMath.mulDiv(FullMath.mulDiv(sLow, sLow, sHigh), FixedPoint96.Q96, sHigh);
    }

    // --- Scenario: Band width is a fraction of the gap ---

    function test_bandWidthIsTheConfiguredFractionOfTheGap() public view {
        for (uint256 i = 0; i < config.bandCount; i++) {
            (int24 lower, int24 upper,) = LadderLib.bandLevels(config, graduationLevel, i);
            assertEq(upper - lower, config.bandWidthLevels, "width is the configured value");
            assertLt(config.bandWidthLevels, config.bandLevelSpacing, "narrower than the gap");
        }

        // DESIGN.md 6.1 wants a band 5-10% of the gap wide; the defaults land at 7.5%.
        uint256 fractionWad = (uint256(uint24(config.bandWidthLevels)) * WAD) / uint256(uint24(config.bandLevelSpacing));
        assertGe(fractionWad, 0.05e18, "at least 5% of the gap");
        assertLe(fractionWad, 0.1e18, "at most 10% of the gap");
    }

    function test_noBandOverlapsItsNeighbour() public view {
        for (uint256 i = 1; i < config.bandCount; i++) {
            (, int24 previousUpper,) = LadderLib.bandLevels(config, graduationLevel, i - 1);
            (int24 lower,,) = LadderLib.bandLevels(config, graduationLevel, i);
            assertLt(previousUpper, lower, "strict gap between bands");
        }
    }

    /// @dev The deploy window is the other range that could overlap a neighbour. The validator caps it at
    /// `spacing - width`, which is exactly the clearance available.
    function test_deployWindowDoesNotReachTheBandBelow() public view {
        for (uint256 i = 1; i < config.bandCount; i++) {
            (, int24 previousUpper,) = LadderLib.bandLevels(config, graduationLevel, i - 1);
            (int24 lower,,) = LadderLib.bandLevels(config, graduationLevel, i);

            int24 windowLower = lower - config.deployWindowLevels;
            assertGe(windowLower, previousUpper, "window starts at or above the band below");
            assertFalse(LadderLib.inDeployWindow(previousUpper - 1, lower, config.deployWindowLevels), "not yet");
        }
    }

    // --- Scenario: One geometry setting applies to all bands ---

    /// @dev Spacing and width are scalars in `LaunchConfig`, so uniformity is structural. This asserts the
    /// observable consequence across every addressable band, core and fee-funded alike.
    function test_geometryIsUniformAcrossEveryAddressableBand() public view {
        uint256 last = uint256(config.bandCount) + Bounds.MAX_FEE_FUNDED_BANDS - 1;

        int24 previousLower;
        for (uint256 i = 0; i <= last; i++) {
            (int24 lower, int24 upper, bool exists) = LadderLib.bandLevels(config, graduationLevel, i);
            assertTrue(exists, "default geometry fits inside tick space for the whole ladder");

            assertEq(upper - lower, config.bandWidthLevels, "same width for every band");
            if (i > 0) assertEq(lower - previousLower, config.bandLevelSpacing, "same spacing for every band");
            previousLower = lower;
        }
    }

    /// @dev Fee-funded bands are not a separate geometry: index `bandCount` continues the core formula.
    function test_feeFundedBandsContinueTheSameFormula() public view {
        (int24 lastCoreLower,,) = LadderLib.bandLevels(config, graduationLevel, uint256(config.bandCount) - 1);
        (int24 firstExtraLower,,) = LadderLib.bandLevels(config, graduationLevel, config.bandCount);

        assertEq(firstExtraLower - lastCoreLower, config.bandLevelSpacing, "one step above the last core band");
    }

    /// @dev Per-band inventory has no override either: it is the ladder share over the band count.
    function test_perBandInventoryIsUniform() public view {
        uint256 perBand = LadderLib.perBandInventory(config);
        assertGt(perBand, 0, "non-trivial");
        assertLe(perBand * config.bandCount, LadderLib.ladderSupply(config), "the bands fit inside the share");
        assertLe((perBand * WAD) / SUPPLY, Bounds.MAX_PER_BAND_SUPPLY_SHARE_WAD, "within the per-band supply bound");
    }

    // --- Out-of-range bands ---

    /// @dev A band past the top of tick space reports "does not exist" rather than reverting, because the
    /// hook evaluates this inside `beforeSwap` where a revert would block the swap.
    function test_bandBeyondTickSpaceDoesNotExist() public pure {
        // Graduating near the ceiling leaves no room for a band above it.
        int24 nearTheTop = Orientation.MAX_LEVEL - 100;
        (,, bool exists) = LadderLib.bandLevels(nearTheTop, Bounds.DEFAULT_BAND_LEVEL_SPACING, 520, 0);
        assertFalse(exists, "no room above");
    }

    function test_ladderEndsRatherThanRevertingWhenItRunsOffTheTop() public pure {
        // A huge spacing puts even band 0 out of reach from a mid-range graduation.
        (,, bool exists) = LadderLib.bandLevels(0, type(int24).max, 1, 0);
        assertFalse(exists, "band 0 out of range");

        // And every later band stays out of reach, so the cursor can never wrap into a valid band.
        for (uint256 i = 1; i < 8; i++) {
            (,, bool later) = LadderLib.bandLevels(0, type(int24).max, 1, i);
            assertFalse(later, "still out of range");
        }
    }

    function test_lastValidBandIsFollowedByAnInvalidOne() public pure {
        int24 spacing = 100_000;
        int24 width = 500;
        uint256 i;
        while (true) {
            (, int24 upper, bool exists) = LadderLib.bandLevels(0, spacing, width, i);
            if (!exists) break;
            assertLe(upper, Orientation.MAX_LEVEL, "every existing band is inside tick space");
            i++;
        }
        assertGt(i, 0, "some bands existed before the ladder ran out");
    }

    // --- Deploy window ---

    function test_deployWindowBoundaries() public pure {
        int24 lower = 1000;
        int24 window = 200;

        assertFalse(LadderLib.inDeployWindow(799, lower, window), "one below the window");
        assertTrue(LadderLib.inDeployWindow(800, lower, window), "the window's lower edge is inclusive");
        assertTrue(LadderLib.inDeployWindow(999, lower, window), "just below the band");
        assertFalse(LadderLib.inDeployWindow(1000, lower, window), "the band's lower bound is not the window");
        assertFalse(LadderLib.inDeployWindow(1200, lower, window), "inside the band");
    }

    /// @dev The window arithmetic runs in int256 because `levelLower - deployWindowLevels` can underflow
    /// int24 for a low graduation level and a wide window.
    function test_deployWindowDoesNotUnderflowNearTheFloor() public pure {
        int24 lower = Orientation.MIN_LEVEL + 10;
        assertTrue(LadderLib.inDeployWindow(lower - 1, lower, type(int24).max), "no underflow");
        assertFalse(LadderLib.inDeployWindow(lower, lower, type(int24).max), "still excludes the band itself");
    }

    // --- Inventory sizing ---

    function test_inventoryUnderTheCapIsTakenWhole() public pure {
        (uint256 amount, uint256 carried) = LadderLib.sizeInventory(700 ether, 1000 ether);
        assertEq(amount, 700 ether, "all of it");
        assertEq(carried, 0, "nothing carried");
    }

    function test_inventoryAtTheCapIsTakenWhole() public pure {
        (uint256 amount, uint256 carried) = LadderLib.sizeInventory(2000 ether, 1000 ether);
        assertEq(amount, 2000 ether, "exactly the cap");
        assertEq(carried, 0, "nothing carried");
    }

    function test_inventoryAboveTheCapIsCarried() public pure {
        (uint256 amount, uint256 carried) = LadderLib.sizeInventory(2500 ether, 1000 ether);
        assertEq(amount, 2000 ether, "capped at 2x the per-band share");
        assertEq(carried, 500 ether, "the excess is carried to the next band");
    }

    function testFuzz_sizeInventoryConservesTokens(uint128 available, uint128 perBand) public pure {
        (uint256 amount, uint256 carried) = LadderLib.sizeInventory(available, perBand);
        assertEq(amount + carried, available, "no tokens created or destroyed");
        assertLe(amount, uint256(perBand) * Bounds.BAND_INVENTORY_CAP_MULTIPLE, "cap respected");
    }

    // --- Bounded liquidity ---

    /// @dev The drift guard for the hardcoded ceiling. `Pool.sol` is imported by the test, not by
    /// production code, so the constant stays out of the hook's dependency graph but cannot go stale.
    function test_maxLiquidityPerTickMatchesV4() public pure {
        assertEq(
            LadderLib.MAX_LIQUIDITY_PER_TICK,
            Pool.tickSpacingToMaxLiquidityPerTick(Bounds.POOL_TICK_SPACING),
            "ceiling still agrees with v4"
        );
    }

    function test_boundedLiquidityMatchesTheUniswapFormulaBelowTheCap() public view {
        for (uint256 i = 0; i < config.bandCount; i++) {
            (int24 lower, int24 upper,) = LadderLib.bandLevels(config, graduationLevel, i);
            (int24 tickLower, int24 tickUpper) = Orientation.levelRangeToTicks(lower, upper);
            uint160 sqrtLower = TickMath.getSqrtPriceAtTick(tickLower);
            uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(tickUpper);

            uint256 amount = LadderLib.perBandInventory(config);
            uint128 expected = LiquidityAmounts.getLiquidityForAmount1(sqrtLower, sqrtUpper, amount);

            assertEq(LadderLib.boundedLiquidity(sqrtLower, sqrtUpper, amount), expected, "same as Uniswap's");
        }
    }

    /// @dev The case that would otherwise revert inside `beforeSwap`: a very narrow band holding a very
    /// large inventory. Uniswap's helper overflows the uint128 cast; this one clamps.
    function test_boundedLiquidityClampsWhereUniswapWouldOverflow() public {
        // One tick wide, near the top of level space, holding an absurd inventory.
        int24 levelLower = 800_000;
        (int24 tickLower, int24 tickUpper) = Orientation.levelRangeToTicks(levelLower, levelLower + 1);
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(tickUpper);
        uint256 amount = type(uint128).max;

        // Through a harness: `vm.expectRevert` cannot observe a revert raised inside an internal library
        // call, because there is no call frame to unwind.
        vm.expectRevert();
        uniswap.getLiquidityForAmount1(sqrtLower, sqrtUpper, amount);

        uint128 clamped = LadderLib.boundedLiquidity(sqrtLower, sqrtUpper, amount);
        // Clamping the *amount* first means the quotient lands just under the ceiling rather than exactly
        // on it — two floors, not one. Both facts matter: it is mintable, and it is not wastefully small.
        assertLe(clamped, LadderLib.MAX_LIQUIDITY_PER_TICK, "mintable");
        assertApproxEqRel(uint256(clamped), LadderLib.MAX_LIQUIDITY_PER_TICK, 0.0001e18, "uses the ceiling");
    }

    /// @dev And the clamp is not merely "does not revert": v4 must actually accept the value.
    function test_clampedLiquidityIsUnderV4sPerTickCeiling() public view {
        int24 levelLower = 800_000;
        (int24 tickLower, int24 tickUpper) = Orientation.levelRangeToTicks(levelLower, levelLower + 1);

        uint128 clamped = LadderLib.boundedLiquidity(
            TickMath.getSqrtPriceAtTick(tickLower), TickMath.getSqrtPriceAtTick(tickUpper), type(uint128).max
        );
        assertLe(clamped, Pool.tickSpacingToMaxLiquidityPerTick(Bounds.POOL_TICK_SPACING), "v4 would accept it");
    }

    function test_boundedLiquidityIsZeroForDegenerateInputs() public pure {
        uint160 s = TickMath.getSqrtPriceAtTick(0);
        assertEq(LadderLib.boundedLiquidity(s, s, 1 ether), 0, "empty range");
        assertEq(LadderLib.boundedLiquidity(s + 1, s, 1 ether), 0, "inverted range");
        assertEq(LadderLib.boundedLiquidity(s, s + 1, 0), 0, "no inventory");
    }

    function testFuzz_boundedLiquidityNeverExceedsTheCap(int24 levelLower, uint16 width, uint256 amount) public pure {
        levelLower = int24(bound(levelLower, Orientation.MIN_LEVEL, Orientation.MAX_LEVEL - 1));
        int24 levelUpper =
            int24(bound(int256(uint256(width)) + 1, 1, int256(Orientation.MAX_LEVEL - levelLower))) + levelLower;

        (int24 tickLower, int24 tickUpper) = Orientation.levelRangeToTicks(levelLower, levelUpper);
        uint128 liquidity = LadderLib.boundedLiquidity(
            TickMath.getSqrtPriceAtTick(tickLower), TickMath.getSqrtPriceAtTick(tickUpper), amount
        );

        assertLe(liquidity, LadderLib.MAX_LIQUIDITY_PER_TICK, "always mintable");
    }

    // --- Ladder cap ---

    function test_coreBandsAreAlwaysWithinTheCap() public view {
        for (uint256 i = 0; i < config.bandCount; i++) {
            assertTrue(LadderLib.withinLadderCap(config.bandCount, i, Bounds.MAX_FEE_FUNDED_BANDS), "core band");
        }
    }

    function test_feeFundedBandsStopAtTheCap() public view {
        uint256 firstExtra = config.bandCount;
        assertTrue(LadderLib.withinLadderCap(config.bandCount, firstExtra, 0), "room to extend");
        assertTrue(LadderLib.withinLadderCap(config.bandCount, firstExtra, Bounds.MAX_FEE_FUNDED_BANDS - 1), "last one");
        assertFalse(LadderLib.withinLadderCap(config.bandCount, firstExtra, Bounds.MAX_FEE_FUNDED_BANDS), "cap reached");
    }

    // --- Fuzzed geometry ---

    function testFuzz_geometryIsNonOverlappingAndUniform(int24 gradLevel, int24 spacing, int24 width) public pure {
        gradLevel = int24(bound(gradLevel, Orientation.MIN_LEVEL, 0));
        spacing = int24(bound(spacing, Bounds.MIN_BAND_LEVEL_SPACING, 200_000));
        width = int24(bound(width, 1, spacing - 1));

        int24 previousLower;
        int24 previousUpper;
        for (uint256 i = 0; i < 20; i++) {
            (int24 lower, int24 upper, bool exists) = LadderLib.bandLevels(gradLevel, spacing, width, i);
            if (!exists) break;

            assertEq(upper - lower, width, "uniform width");
            assertLe(upper, Orientation.MAX_LEVEL, "inside tick space");
            if (i > 0) {
                assertEq(lower - previousLower, spacing, "uniform spacing");
                assertLt(previousUpper, lower, "no overlap");
            }
            previousLower = lower;
            previousUpper = upper;
        }
    }
}

/// @dev External wrapper so `vm.expectRevert` can observe Uniswap's unclamped helper reverting; an
/// internal library call raises no frame for the cheatcode to catch.
contract UniswapLiquidityHarness {
    function getLiquidityForAmount1(uint160 sqrtLower, uint160 sqrtUpper, uint256 amount1)
        external
        pure
        returns (uint128)
    {
        return LiquidityAmounts.getLiquidityForAmount1(sqrtLower, sqrtUpper, amount1);
    }
}
