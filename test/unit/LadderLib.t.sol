// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {FixedPoint96} from "v4-core/src/libraries/FixedPoint96.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {Pool} from "v4-core/src/libraries/Pool.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "v4-periphery/src/libraries/LiquidityAmounts.sol";
import {CurveLib} from "../../src/libraries/CurveLib.sol";
import {LadderLib} from "../../src/libraries/LadderLib.sol";
import {Orientation} from "../../src/libraries/Orientation.sol";
import {Bounds, ProtocolTemplate, WAD} from "../../src/types/LaunchTypes.sol";

/// @notice Unit tests for task 8.1 — ladder geometry, covering the `milestone-ladder` scenarios
/// "Band ticks are computable by any observer", "The schedule decays from a wide first step to the
/// floor spacing", "Band width is a fraction of the gap", and "One template applies to all launches".
///
/// @dev Deliberately on plain `Test` rather than the shared `LaunchpadTest` fixture: every function here
/// is a statement about the library and the immutable template, so a deployed protocol would add a launch
/// per test and prove nothing extra. The graduation level is derived through `CurveLib` rather than
/// hardcoded, which makes the two libraries' agreement on where the ladder starts part of the setUp.
contract LadderLibTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 ether;

    /// @dev A representative graduation level: the default template's far level, which is where the
    /// bonding curve terminates and therefore where band 0 is measured from.
    int24 internal graduationLevel;
    ProtocolTemplate internal template;
    UniswapLiquidityHarness internal uniswap;

    function setUp() public {
        template = Bounds.defaultTemplate();
        graduationLevel =
            CurveLib.farLevel(CurveLib.openingLevel(SUPPLY, template.openingFdvWei), template.curveSpanLevels);
        uniswap = new UniswapLiquidityHarness();
    }

    // --- Scenario: Band ticks are computable by any observer ---

    /// @dev The point of the scenario is that no protocol state is needed. So this recomputes the whole
    /// ladder from the public inputs with open-coded arithmetic — deliberately not by calling the
    /// library — and requires the library to agree. Step `i` (the gap between band `i-1` and band `i`)
    /// is `max(bandLevelSpacing, bandFirstStepLevels - bandStepDecayLevels*i)` levels.
    function test_bandsAreDerivableFromConfigAndGraduationLevelAlone() public view {
        int24 cumulative;
        for (uint256 i = 0; i < template.coreBandCount; i++) {
            int24 step = template.bandFirstStepLevels - int24(int256(i)) * template.bandStepDecayLevels;
            if (step < template.bandLevelSpacing) step = template.bandLevelSpacing;
            cumulative += step;

            int24 expectedLower = graduationLevel + cumulative;
            int24 expectedUpper = expectedLower + template.bandWidthLevels;

            (int24 lower, int24 upper, bool exists) = _band(i);

            assertTrue(exists, "band exists");
            assertEq(lower, expectedLower, "lower level derivable");
            assertEq(upper, expectedUpper, "upper level derivable");
        }
    }

    /// @dev "lower tick, upper tick, and target inventory" — the tick bounds an observer would watch, and
    /// the inventory they would expect the band to hold.
    function test_bandTicksAndTargetInventoryAreComputable() public view {
        uint256 expectedPerBand = ((SUPPLY * template.ladderSupplyShareWad) / WAD) / template.coreBandCount;
        assertEq(
            LadderLib.perBandInventory(SUPPLY, template.ladderSupplyShareWad, template.coreBandCount),
            expectedPerBand,
            "target inventory computable"
        );

        for (uint256 i = 0; i < template.coreBandCount; i++) {
            (int24 lower, int24 upper,) = _band(i);
            (int24 tickLower, int24 tickUpper) = Orientation.levelRangeToTicks(lower, upper);

            // Level is -tick, so the bounds swap: the band's dearer edge is its lower tick.
            assertEq(tickLower, -upper, "tick lower");
            assertEq(tickUpper, -lower, "tick upper");
            assertTrue(Orientation.isValidTick(tickLower) && Orientation.isValidTick(tickUpper), "usable ticks");
        }
    }

    /// @dev No band sits at or below graduation: the first is the full first step above it, so graduating
    /// does not instantly complete a milestone.
    function test_firstBandSitsOneFullStepAboveGraduation() public view {
        (int24 lower,,) = _band(0);
        assertEq(lower - graduationLevel, template.bandFirstStepLevels, "one full first step above graduation");
        assertGt(lower, graduationLevel, "strictly above");
    }

    // --- Scenario: The schedule decays from a wide first step to the floor spacing ---

    /// @dev The step between band `i-1` and band `i` is `max(spacing, firstStep - decay*i)`: shrinking
    /// until it reaches the floor, then constant. The decay runs exactly
    /// `(firstStep - spacing) / decay` shrinking steps before locking.
    function test_stepsDecayToTheFloorSpacing() public view {
        int24 previousLower;
        uint256 shrinking;
        for (uint256 i = 0; i < template.coreBandCount; i++) {
            (int24 lower,,) = _band(i);
            int24 step = template.bandFirstStepLevels - int24(int256(i)) * template.bandStepDecayLevels;
            if (step < template.bandLevelSpacing) step = template.bandLevelSpacing;
            else shrinking = i;

            if (i > 0) assertEq(lower - previousLower, step, "step follows the schedule");
            previousLower = lower;
        }

        // The schedule actually has both phases: it decays for a while, then locks at the floor.
        assertGt(shrinking, 0, "some steps are shrinking");
        assertLt(
            template.bandFirstStepLevels - int24(int256(shrinking + 1)) * template.bandStepDecayLevels,
            template.bandLevelSpacing,
            "the next step would fall below the floor, so it locks there"
        );
        (int24 lastLower,,) = _band(template.coreBandCount - 1);
        (int24 beforeLastLower,,) = _band(template.coreBandCount - 2);
        assertEq(lastLower - beforeLastLower, template.bandLevelSpacing, "the core ladder ends at the floor");
    }

    /// @dev The ratios the schedule fixes: the first step is a market-cap doubling, the floor is the
    /// documented 1.2504x step, and ratios only ever shrink toward it.
    function test_firstStepIsADoublingAndTheFloorIsOnePointTwoFive() public view {
        (int24 firstLower,,) = _band(0);
        (int24 secondLower,,) = _band(1);
        (int24 lastLower,,) = _band(template.coreBandCount - 1);
        (int24 beforeLastLower,,) = _band(template.coreBandCount - 2);

        assertApproxEqRel(
            _capRatioQ96(graduationLevel, firstLower),
            2 * FixedPoint96.Q96,
            0.001e18,
            "the first milestone is a 2x above graduation"
        );
        assertApproxEqRel(
            _capRatioQ96(firstLower, secondLower),
            _capRatioQ96(0, Bounds.BAND_FIRST_STEP_LEVELS - Bounds.BAND_STEP_DECAY_LEVELS),
            0.0001e18,
            "the second step is exactly one decay smaller"
        );
        assertApproxEqRel(
            _capRatioQ96(beforeLastLower, lastLower),
            (5 * FixedPoint96.Q96) / 4,
            0.001e18,
            "the last core step is the 1.25x floor"
        );
    }

    /// @dev The number the scenario fixes: 2,235 levels is a 1.25x market-cap step. The 2x constant is
    /// asserted alongside it because it is the *curve* span's unit, and reading one for the other is
    /// exactly the mix-up this checks against — the ladder rungs decay toward 1.25x, not 2x.
    function test_defaultSpacingIsAOnePointTwoFiveTimesMarketCapStep() public pure {
        assertEq(Bounds.BAND_LEVEL_SPACING, 2235, "the documented constant");
        assertApproxEqRel(
            _capRatioQ96(0, Bounds.BAND_LEVEL_SPACING),
            (5 * FixedPoint96.Q96) / 4,
            0.001e18,
            "2235 levels is a 1.25x market-cap step"
        );

        assertEq(Bounds.LEVELS_PER_DOUBLING, 6931, "and the doubling constant is unchanged");
        assertApproxEqRel(
            _capRatioQ96(0, Bounds.LEVELS_PER_DOUBLING),
            2 * FixedPoint96.Q96,
            0.001e18,
            "6931 levels doubles the market cap"
        );

        assertEq(Bounds.BAND_FIRST_STEP_LEVELS, 6932, "the first ladder step is one level past a doubling");
        assertEq(Bounds.BAND_STEP_DECAY_LEVELS, 391, "the per-step decay");
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
        for (uint256 i = 0; i < template.coreBandCount; i++) {
            (int24 lower, int24 upper,) = _band(i);
            assertEq(upper - lower, template.bandWidthLevels, "width is the configured value");
            assertLt(template.bandWidthLevels, template.bandLevelSpacing, "narrower than the gap");
        }

        // The scenario fixes the fraction exactly: 447 levels of the 2,235-level spacing, a clean fifth.
        assertEq(template.bandWidthLevels * 5, template.bandLevelSpacing, "exactly a fifth of the gap");
        uint256 fractionWad =
            (uint256(uint24(template.bandWidthLevels)) * WAD) / uint256(uint24(template.bandLevelSpacing));
        assertEq(fractionWad, 0.2e18, "20% of the gap");
    }

    function test_noBandOverlapsItsNeighbour() public view {
        for (uint256 i = 1; i < template.coreBandCount; i++) {
            (, int24 previousUpper,) = _band(i - 1);
            (int24 lower,,) = _band(i);
            assertLt(previousUpper, lower, "strict gap between bands");
        }
    }

    // --- Scenario: One template applies to all launches ---

    /// @dev Width and the schedule are scalars in `ProtocolTemplate`, so uniformity is structural. This
    /// asserts the observable consequence across every addressable band, core and fee-funded alike.
    function test_geometryIsUniformAcrossEveryAddressableBand() public view {
        uint256 last = uint256(template.coreBandCount) + template.maxFeeFundedBands - 1;

        int24 previousLower;
        for (uint256 i = 0; i <= last; i++) {
            (int24 lower, int24 upper, bool exists) = _band(i);
            assertTrue(exists, "default geometry fits inside tick space for the whole ladder");

            assertEq(upper - lower, template.bandWidthLevels, "same width for every band");
            if (i > 0) {
                int24 step = template.bandFirstStepLevels - int24(int256(i)) * template.bandStepDecayLevels;
                if (step < template.bandLevelSpacing) step = template.bandLevelSpacing;
                assertEq(lower - previousLower, step, "same schedule for every band");
            }
            previousLower = lower;
        }
    }

    /// @dev Fee-funded bands are not a separate geometry: index `coreBandCount` continues the core formula.
    function test_feeFundedBandsContinueTheSameFormula() public view {
        (int24 lastCoreLower,,) = _band(uint256(template.coreBandCount) - 1);
        (int24 firstExtraLower,,) = _band(template.coreBandCount);

        assertEq(firstExtraLower - lastCoreLower, template.bandLevelSpacing, "one step above the last core band");
    }

    /// @dev Per-band inventory has no override either: it is the ladder share over the band count.
    function test_perBandInventoryIsUniform() public view {
        uint256 perBand = LadderLib.perBandInventory(SUPPLY, template.ladderSupplyShareWad, template.coreBandCount);
        assertGt(perBand, 0, "non-trivial");
        assertLe(
            perBand * template.coreBandCount,
            LadderLib.ladderSupply(SUPPLY, template.ladderSupplyShareWad),
            "the bands fit inside the share"
        );
    }

    // --- Out-of-range bands ---

    /// @dev A band past the top of tick space reports "does not exist" rather than reverting, because the
    /// hook evaluates this inside `beforeSwap` where a revert would block the swap.
    function test_bandBeyondTickSpaceDoesNotExist() public pure {
        // Graduating near the ceiling leaves no room for a band above it.
        int24 nearTheTop = Orientation.MAX_LEVEL - 100;
        (,, bool exists) = LadderLib.bandLevels(
            nearTheTop, Bounds.BAND_FIRST_STEP_LEVELS, Bounds.BAND_STEP_DECAY_LEVELS, Bounds.BAND_LEVEL_SPACING, 520, 0
        );
        assertFalse(exists, "no room above");
    }

    function test_ladderEndsRatherThanRevertingWhenItRunsOffTheTop() public pure {
        // A huge first step puts even band 0 out of reach from a mid-range graduation.
        (,, bool exists) = LadderLib.bandLevels(0, type(int24).max, 1, Bounds.BAND_LEVEL_SPACING, 1, 0);
        assertFalse(exists, "band 0 out of range");

        // And every later band stays out of reach, so the cursor can never wrap into a valid band.
        for (uint256 i = 1; i < 8; i++) {
            (,, bool later) = LadderLib.bandLevels(0, type(int24).max, 1, Bounds.BAND_LEVEL_SPACING, 1, i);
            assertFalse(later, "still out of range");
        }
    }

    function test_lastValidBandIsFollowedByAnInvalidOne() public pure {
        int24 firstStep = 100_000;
        int24 width = 500;
        uint256 i;
        while (true) {
            // Decay of 1 with spacing equal to the first step is the uniform schedule, expressed in the
            // decayed form the library implements.
            (, int24 upper, bool exists) = LadderLib.bandLevels(0, firstStep, 1, firstStep, width, i);
            if (!exists) break;
            assertLe(upper, Orientation.MAX_LEVEL, "every existing band is inside tick space");
            i++;
        }
        assertGt(i, 0, "some bands existed before the ladder ran out");
    }

    // --- Inventory sizing ---

    function test_inventoryUnderTheCapIsTakenWhole() public view {
        (uint256 amount, uint256 carried) =
            LadderLib.sizeInventory(700 ether, 1000 ether, template.bandInventoryCapMultiple);
        assertEq(amount, 700 ether, "all of it");
        assertEq(carried, 0, "nothing carried");
    }

    function test_inventoryAtTheCapIsTakenWhole() public view {
        (uint256 amount, uint256 carried) =
            LadderLib.sizeInventory(2000 ether, 1000 ether, template.bandInventoryCapMultiple);
        assertEq(amount, 2000 ether, "exactly the cap");
        assertEq(carried, 0, "nothing carried");
    }

    function test_inventoryAboveTheCapIsCarried() public view {
        (uint256 amount, uint256 carried) =
            LadderLib.sizeInventory(2500 ether, 1000 ether, template.bandInventoryCapMultiple);
        assertEq(amount, 2000 ether, "capped at 2x the per-band share");
        assertEq(carried, 500 ether, "the excess is carried to the next band");
    }

    function testFuzz_sizeInventoryConservesTokens(uint128 available, uint128 perBand, uint8 capMultiple) public pure {
        (uint256 amount, uint256 carried) = LadderLib.sizeInventory(available, perBand, capMultiple);
        assertEq(amount + carried, available, "no tokens created or destroyed");
        assertLe(amount, uint256(perBand) * capMultiple, "cap respected");
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
        for (uint256 i = 0; i < template.coreBandCount; i++) {
            (int24 lower, int24 upper,) = _band(i);
            (int24 tickLower, int24 tickUpper) = Orientation.levelRangeToTicks(lower, upper);
            uint160 sqrtLower = TickMath.getSqrtPriceAtTick(tickLower);
            uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(tickUpper);

            uint256 amount = LadderLib.perBandInventory(SUPPLY, template.ladderSupplyShareWad, template.coreBandCount);
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
    function test_clampedLiquidityIsUnderV4sPerTickCeiling() public pure {
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
        for (uint256 i = 0; i < template.coreBandCount; i++) {
            assertTrue(
                LadderLib.withinLadderCap(
                    template.coreBandCount, i, template.maxFeeFundedBands, template.maxFeeFundedBands
                ),
                "core band, even with the extension cap already exhausted"
            );
        }
    }

    function test_feeFundedBandsStopAtTheCap() public view {
        uint256 firstExtra = template.coreBandCount;
        assertTrue(
            LadderLib.withinLadderCap(template.coreBandCount, firstExtra, 0, template.maxFeeFundedBands),
            "room to extend"
        );
        assertTrue(
            LadderLib.withinLadderCap(
                template.coreBandCount, firstExtra, template.maxFeeFundedBands - 1, template.maxFeeFundedBands
            ),
            "last one"
        );
        assertFalse(
            LadderLib.withinLadderCap(
                template.coreBandCount, firstExtra, template.maxFeeFundedBands, template.maxFeeFundedBands
            ),
            "cap reached"
        );
    }

    // --- Fuzzed geometry ---

    function testFuzz_geometryIsNonOverlappingAndScheduleShaped(int24 gradLevel, int24 firstStep, int24 width)
        public
        pure
    {
        gradLevel = int24(bound(gradLevel, Orientation.MIN_LEVEL, 0));
        int24 spacing = Bounds.BAND_LEVEL_SPACING;
        firstStep = int24(bound(firstStep, spacing, 200_000));
        width = int24(bound(width, 1, spacing - 1));
        int24 decay = Bounds.BAND_STEP_DECAY_LEVELS;

        int24 previousLower;
        int24 previousUpper;
        for (uint256 i = 0; i < 20; i++) {
            (int24 lower, int24 upper, bool exists) =
                LadderLib.bandLevels(gradLevel, firstStep, decay, spacing, width, i);
            if (!exists) break;

            assertEq(upper - lower, width, "uniform width");
            assertLe(upper, Orientation.MAX_LEVEL, "inside tick space");
            if (i > 0) {
                int24 step = firstStep - int24(int256(i)) * decay;
                if (step < spacing) step = spacing;
                assertEq(lower - previousLower, step, "schedule-shaped spacing");
                assertLt(previousUpper, lower, "no overlap");
            }
            previousLower = lower;
            previousUpper = upper;
        }
    }

    /// @dev The template geometry, applied at the index under test.
    function _band(uint256 index) internal view returns (int24 lower, int24 upper, bool exists) {
        return LadderLib.bandLevels(
            graduationLevel,
            template.bandFirstStepLevels,
            template.bandStepDecayLevels,
            template.bandLevelSpacing,
            template.bandWidthLevels,
            index
        );
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
