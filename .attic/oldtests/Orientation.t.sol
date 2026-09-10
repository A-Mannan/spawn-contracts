// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Orientation} from "../../src/libraries/Orientation.sol";

/// @notice External wrapper around the library. `Orientation`'s functions are `internal`, so they
/// inline into the caller's frame; `vm.expectRevert` needs the revert to happen at a deeper call
/// depth than the cheatcode. Routing the reverting cases through this harness provides that.
contract OrientationHarness {
    function levelRangeToTicks(int24 levelLower, int24 levelUpper) external pure returns (int24, int24) {
        return Orientation.levelRangeToTicks(levelLower, levelUpper);
    }

    function tickRangeToLevels(int24 tickLower, int24 tickUpper) external pure returns (int24, int24) {
        return Orientation.tickRangeToLevels(tickLower, tickUpper);
    }

    function toLevelChecked(int24 tick) external pure returns (int24) {
        return Orientation.toLevelChecked(tick);
    }

    function toTickChecked(int24 level) external pure returns (int24) {
        return Orientation.toTickChecked(level);
    }
}

/// @notice Unit and fuzz tests for task 3.2, the orientation boundary of design Decision 3.
///
/// The properties that matter: the tick <-> level round trip is the identity, level ordering is the
/// inverse of tick ordering, and range conversion swaps the bounds. If any of these break, bands get
/// placed on the wrong side of spot and fill instantly at the wrong price.
contract OrientationTest is Test {
    OrientationHarness internal harness;

    function setUp() public {
        harness = new OrientationHarness();
    }

    // --- Round trip is the identity ---

    function testFuzz_tickRoundTripIsIdentity(int24 tick) public pure {
        tick = int24(bound(int256(tick), TickMath.MIN_TICK, TickMath.MAX_TICK));

        assertEq(Orientation.toTick(Orientation.toLevel(tick)), tick, "tick -> level -> tick");
    }

    function testFuzz_levelRoundTripIsIdentity(int24 level) public pure {
        level = int24(bound(int256(level), Orientation.MIN_LEVEL, Orientation.MAX_LEVEL));

        assertEq(Orientation.toLevel(Orientation.toTick(level)), level, "level -> tick -> level");
    }

    /// @dev The round trip must hold across the *whole* int24 domain, not just valid ticks, so that
    /// no intermediate arithmetic can trap on an out-of-range value.
    function testFuzz_roundTripIsTotalOverInt24(int24 tick) public pure {
        vm.assume(tick != type(int24).min); // -type(int24).min is not representable
        assertEq(Orientation.toTick(Orientation.toLevel(tick)), tick, "round trip total");
    }

    function test_roundTripAtBoundaries() public pure {
        assertEq(Orientation.toTick(Orientation.toLevel(TickMath.MIN_TICK)), TickMath.MIN_TICK, "min tick");
        assertEq(Orientation.toTick(Orientation.toLevel(TickMath.MAX_TICK)), TickMath.MAX_TICK, "max tick");
        assertEq(Orientation.toLevel(0), 0, "zero is a fixed point");
    }

    /// @dev The symmetry that makes the negation total.
    function test_tickRangeIsSymmetricAboutZero() public pure {
        assertEq(TickMath.MIN_TICK, -TickMath.MAX_TICK, "tick range symmetric");
        assertEq(Orientation.MIN_LEVEL, -TickMath.MAX_TICK, "min level");
        assertEq(Orientation.MAX_LEVEL, -TickMath.MIN_TICK, "max level");
        assertEq(Orientation.MIN_LEVEL, -Orientation.MAX_LEVEL, "level range symmetric");
    }

    // --- Level ordering is the inverse of tick ordering ---

    function testFuzz_levelOrderingIsInverseOfTickOrdering(int24 tickA, int24 tickB) public pure {
        tickA = int24(bound(int256(tickA), TickMath.MIN_TICK, TickMath.MAX_TICK));
        tickB = int24(bound(int256(tickB), TickMath.MIN_TICK, TickMath.MAX_TICK));

        int24 levelA = Orientation.toLevel(tickA);
        int24 levelB = Orientation.toLevel(tickB);

        if (tickA < tickB) {
            assertGt(levelA, levelB, "lower tick is a higher level");
        } else if (tickA > tickB) {
            assertLt(levelA, levelB, "higher tick is a lower level");
        } else {
            assertEq(levelA, levelB, "equal ticks, equal levels");
        }
    }

    /// @dev Restates the economic claim: token price rising means tick falling, level rising.
    function test_risingTokenPriceMeansRisingLevel() public pure {
        int24 cheapTick = 1000; // more token per ETH => token is cheap
        int24 dearTick = -1000; // less token per ETH => token is dear

        assertLt(dearTick, cheapTick, "dearer token sits at a lower tick");
        assertGt(Orientation.toLevel(dearTick), Orientation.toLevel(cheapTick), "dearer token sits at a higher level");
    }

    // --- Range conversion swaps the bounds ---

    function testFuzz_levelRangeToTicksSwapsBounds(int24 levelLower, int24 levelGap) public pure {
        levelLower = int24(bound(int256(levelLower), Orientation.MIN_LEVEL, Orientation.MAX_LEVEL - 1));
        int24 maxGap = Orientation.MAX_LEVEL - levelLower;
        levelGap = int24(bound(int256(levelGap), 1, int256(maxGap)));
        int24 levelUpper = levelLower + levelGap;

        (int24 tickLower, int24 tickUpper) = Orientation.levelRangeToTicks(levelLower, levelUpper);

        assertLt(tickLower, tickUpper, "tick range stays ascending");
        assertEq(tickLower, Orientation.toTick(levelUpper), "tickLower comes from levelUpper");
        assertEq(tickUpper, Orientation.toTick(levelLower), "tickUpper comes from levelLower");
        assertEq(tickUpper - tickLower, levelUpper - levelLower, "width preserved");
    }

    function testFuzz_rangeConversionRoundTrips(int24 levelLower, int24 levelGap) public pure {
        levelLower = int24(bound(int256(levelLower), Orientation.MIN_LEVEL, Orientation.MAX_LEVEL - 1));
        int24 maxGap = Orientation.MAX_LEVEL - levelLower;
        levelGap = int24(bound(int256(levelGap), 1, int256(maxGap)));
        int24 levelUpper = levelLower + levelGap;

        (int24 tickLower, int24 tickUpper) = Orientation.levelRangeToTicks(levelLower, levelUpper);
        (int24 backLower, int24 backUpper) = Orientation.tickRangeToLevels(tickLower, tickUpper);

        assertEq(backLower, levelLower, "level lower round trips");
        assertEq(backUpper, levelUpper, "level upper round trips");
    }

    function test_levelRangeRejectsNonAscending() public {
        vm.expectRevert(abi.encodeWithSelector(Orientation.LevelRangeNotAscending.selector, int24(100), int24(100)));
        harness.levelRangeToTicks(100, 100);

        vm.expectRevert(abi.encodeWithSelector(Orientation.LevelRangeNotAscending.selector, int24(200), int24(100)));
        harness.levelRangeToTicks(200, 100);
    }

    function test_tickRangeRejectsNonAscending() public {
        vm.expectRevert(abi.encodeWithSelector(Orientation.LevelRangeNotAscending.selector, int24(50), int24(50)));
        harness.tickRangeToLevels(50, 50);
    }

    /// @dev A sell band sits above spot in price, which is *below* spot in tick space. This is the
    /// concrete claim the ladder depends on.
    function test_sellBandAboveSpotIsBelowSpotInTicks() public pure {
        int24 spotTick = 0;
        int24 spotLevel = Orientation.toLevel(spotTick);

        // A band one 2x step above spot in market cap.
        int24 bandLevelLower = spotLevel + 6931;
        int24 bandLevelUpper = bandLevelLower + 500;

        (int24 tickLower, int24 tickUpper) = Orientation.levelRangeToTicks(bandLevelLower, bandLevelUpper);

        assertLt(tickUpper, spotTick, "the whole band sits below spot in tick space");
        assertLt(tickLower, tickUpper, "band range ascending in ticks");
    }

    // --- Checked variants ---

    function test_checkedConversionsAcceptValidValues() public pure {
        assertEq(Orientation.toLevelChecked(TickMath.MAX_TICK), Orientation.MIN_LEVEL, "max tick checked");
        assertEq(Orientation.toTickChecked(Orientation.MAX_LEVEL), TickMath.MIN_TICK, "max level checked");
    }

    function test_checkedTickRejectsOutOfRange() public {
        int24 tooHigh = TickMath.MAX_TICK + 1;
        vm.expectRevert(abi.encodeWithSelector(Orientation.TickOutOfRange.selector, tooHigh));
        harness.toLevelChecked(tooHigh);

        int24 tooLow = TickMath.MIN_TICK - 1;
        vm.expectRevert(abi.encodeWithSelector(Orientation.TickOutOfRange.selector, tooLow));
        harness.toLevelChecked(tooLow);
    }

    function test_checkedLevelRejectsOutOfRange() public {
        int24 tooHigh = Orientation.MAX_LEVEL + 1;
        vm.expectRevert(abi.encodeWithSelector(Orientation.LevelOutOfRange.selector, tooHigh));
        harness.toTickChecked(tooHigh);
    }

    function testFuzz_validityPredicatesAgree(int24 tick) public pure {
        vm.assume(tick != type(int24).min);
        assertEq(Orientation.isValidTick(tick), Orientation.isValidLevel(Orientation.toLevel(tick)), "predicates agree");
    }
}
