// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {CurveLib} from "../../src/libraries/CurveLib.sol";
import {LaunchConfigLib} from "../../src/libraries/LaunchConfigLib.sol";
import {Bounds, Curve, LaunchConfig, WAD} from "../../src/types/LaunchTypes.sol";

/// @dev External wrapper so `vm.expectRevert` sees reverts at a deeper call depth than the cheatcode.
contract CurveHarness {
    function validate(Curve[] memory curves, LaunchConfig memory config) external pure {
        CurveLib.validate(curves, config);
    }
}

/// @notice Unit tests for task 5.1: curve share accounting and the position fan.
contract CurveLibTest is Test {
    CurveHarness internal harness;

    uint256 internal constant SUPPLY = 1_000_000_000 ether;
    uint256 internal constant CURVE_SUPPLY = (SUPPLY * 25) / 100; // 25% bonding-curve share

    /// @dev Default opening level; curves must start below `farLevel`, which sits one 2x step above.
    int24 internal constant BASE = Bounds.DEFAULT_START_LEVEL;

    function setUp() public {
        harness = new CurveHarness();
    }

    function _config() internal pure returns (LaunchConfig memory) {
        return LaunchConfigLib.defaults(SUPPLY);
    }

    function _single(uint16 numPositions) internal pure returns (Curve[] memory curves) {
        curves = new Curve[](1);
        curves[0] = Curve({startingLevel: BASE, numPositions: numPositions, shareWad: uint64(WAD)});
    }

    // --- Scenario: Curve shares must sum to one whole ---

    function test_defaultCurvesAreValid() public view {
        harness.validate(CurveLib.defaultCurves(), _config());
    }

    function test_sharesSummingToWadAccepted() public view {
        Curve[] memory curves = new Curve[](3);
        curves[0] = Curve({startingLevel: BASE, numPositions: 5, shareWad: 0.5e18});
        curves[1] = Curve({startingLevel: BASE + 1000, numPositions: 5, shareWad: 0.3e18});
        curves[2] = Curve({startingLevel: BASE + 2000, numPositions: 5, shareWad: 0.2e18});

        harness.validate(curves, _config());
    }

    function test_sharesUnderWadRejected() public {
        Curve[] memory curves = _single(5);
        curves[0].shareWad = uint64(WAD - 1);

        vm.expectRevert(abi.encodeWithSelector(CurveLib.CurveSharesMustSumToWad.selector, uint256(WAD - 1)));
        harness.validate(curves, _config());
    }

    function test_sharesOverWadRejected() public {
        Curve[] memory curves = new Curve[](2);
        curves[0] = Curve({startingLevel: BASE, numPositions: 5, shareWad: 0.6e18});
        curves[1] = Curve({startingLevel: BASE + 100, numPositions: 5, shareWad: 0.5e18});

        vm.expectRevert(abi.encodeWithSelector(CurveLib.CurveSharesMustSumToWad.selector, uint256(1.1e18)));
        harness.validate(curves, _config());
    }

    function test_emptyCurveSetRejected() public {
        vm.expectRevert(CurveLib.NoCurves.selector);
        harness.validate(new Curve[](0), _config());
    }

    function test_tooManyCurvesRejected() public {
        Curve[] memory curves = new Curve[](CurveLib.MAX_CURVES + 1);
        for (uint256 i = 0; i < curves.length; i++) {
            curves[i] = Curve({startingLevel: BASE + int24(int256(i * 100)), numPositions: 2, shareWad: 1});
        }

        vm.expectRevert(abi.encodeWithSelector(CurveLib.TooManyCurves.selector, curves.length));
        harness.validate(curves, _config());
    }

    function test_zeroPositionsRejected() public {
        Curve[] memory curves = _single(0);

        vm.expectRevert(abi.encodeWithSelector(CurveLib.CurveHasNoPositions.selector, uint256(0)));
        harness.validate(curves, _config());
    }

    function test_tooManyPositionsRejected() public {
        Curve[] memory curves = _single(CurveLib.MAX_POSITIONS_PER_CURVE + 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                CurveLib.CurveTooManyPositions.selector, uint256(0), CurveLib.MAX_POSITIONS_PER_CURVE + 1
            )
        );
        harness.validate(curves, _config());
    }

    function test_zeroShareCurveRejected() public {
        Curve[] memory curves = new Curve[](2);
        curves[0] = Curve({startingLevel: BASE, numPositions: 5, shareWad: uint64(WAD)});
        curves[1] = Curve({startingLevel: BASE + 100, numPositions: 5, shareWad: 0});

        vm.expectRevert(abi.encodeWithSelector(CurveLib.CurveZeroShare.selector, uint256(1)));
        harness.validate(curves, _config());
    }

    // --- Scenario: Every curve terminates at the shared far level ---

    function test_curveAtOrAboveFarLevelRejected() public {
        LaunchConfig memory config = _config();

        Curve[] memory curves = _single(5);
        curves[0].startingLevel = config.farLevel;

        vm.expectRevert(
            abi.encodeWithSelector(
                CurveLib.CurveStartsAtOrAboveFarLevel.selector, uint256(0), config.farLevel, config.farLevel
            )
        );
        harness.validate(curves, config);
    }

    function test_everyPositionEndsAtOrBelowFarLevel() public pure {
        LaunchConfig memory config = _config();
        Curve memory curve = Curve({startingLevel: BASE + 100, numPositions: 7, shareWad: uint64(WAD)});

        for (uint256 i = 0; i < curve.numPositions; i++) {
            (int24 lower, int24 upper) = CurveLib.positionLevels(curve, config.farLevel, i);
            assertLe(upper, config.farLevel, "no position exceeds the far level");
            assertGe(lower, curve.startingLevel, "no position starts below the curve");
            assertLt(lower, upper, "ascending");
        }
    }

    /// @dev The fan is contiguous and terminates exactly at the far level, so no inventory sits in a
    /// gap that buyers can skip over.
    function test_positionFanIsContiguousAndTerminatesAtFarLevel() public pure {
        LaunchConfig memory config = _config();
        Curve memory curve = Curve({startingLevel: BASE, numPositions: 13, shareWad: uint64(WAD)});

        (int24 firstLower,) = CurveLib.positionLevels(curve, config.farLevel, 0);
        assertEq(firstLower, curve.startingLevel, "starts at the curve's own level");

        int24 previousUpper = firstLower;
        for (uint256 i = 0; i < curve.numPositions; i++) {
            (int24 lower, int24 upper) = CurveLib.positionLevels(curve, config.farLevel, i);
            assertEq(lower, previousUpper, "no gap between positions");
            previousUpper = upper;
        }

        assertEq(previousUpper, config.farLevel, "last position ends exactly at the far level");
    }

    function testFuzz_fanIsContiguousForAnyPositionCount(uint16 numPositions, int24 startingLevel) public pure {
        numPositions = uint16(bound(numPositions, 1, CurveLib.MAX_POSITIONS_PER_CURVE));
        startingLevel = int24(bound(int256(startingLevel), -300_000, 300_000));

        LaunchConfig memory config = _config();
        config.farLevel = startingLevel + 50_000;

        Curve memory curve = Curve({startingLevel: startingLevel, numPositions: numPositions, shareWad: uint64(WAD)});

        int24 previousUpper = startingLevel;
        for (uint256 i = 0; i < numPositions; i++) {
            (int24 lower, int24 upper) = CurveLib.positionLevels(curve, config.farLevel, i);
            assertEq(lower, previousUpper, "contiguous");
            previousUpper = upper;
        }
        assertEq(previousUpper, config.farLevel, "terminates at far level");
    }

    // --- Position amounts sum to the bonding curve supply share within dust ---

    function test_positionAmountsSumToCurveAllocationExactly() public pure {
        Curve memory curve = Curve({startingLevel: BASE, numPositions: 7, shareWad: uint64(WAD)});

        uint256 sum;
        for (uint256 i = 0; i < curve.numPositions; i++) {
            sum += CurveLib.positionAmount(curve, CURVE_SUPPLY, i);
        }

        // The final position absorbs the division remainder, so a single curve is exact.
        assertEq(sum, CURVE_SUPPLY, "single curve sums exactly");
    }

    function test_multiCurveAmountsSumToSupplyWithinDust() public pure {
        Curve[] memory curves = new Curve[](3);
        curves[0] = Curve({startingLevel: BASE, numPositions: 7, shareWad: 0.5e18});
        curves[1] = Curve({startingLevel: BASE + 1000, numPositions: 11, shareWad: 0.3e18});
        curves[2] = Curve({startingLevel: BASE + 2000, numPositions: 13, shareWad: 0.2e18});

        uint256 sum;
        for (uint256 c = 0; c < curves.length; c++) {
            for (uint256 i = 0; i < curves[c].numPositions; i++) {
                sum += CurveLib.positionAmount(curves[c], CURVE_SUPPLY, i);
            }
        }

        // Dust is bounded by one wei per curve, from the share multiplication only.
        assertLe(CURVE_SUPPLY - sum, curves.length, "dust bounded by curve count");
        assertLe(sum, CURVE_SUPPLY, "never overdraws the allocation");
    }

    function testFuzz_amountsNeverOverdrawTheAllocation(uint16 numPositions, uint64 shareWad, uint128 supply)
        public
        pure
    {
        numPositions = uint16(bound(numPositions, 1, CurveLib.MAX_POSITIONS_PER_CURVE));
        shareWad = uint64(bound(shareWad, 1, uint64(WAD)));
        supply = uint128(bound(supply, 1e18, type(uint128).max / 2));

        Curve memory curve = Curve({startingLevel: BASE, numPositions: numPositions, shareWad: shareWad});
        uint256 allocation = CurveLib.curveAllocation(curve, supply);

        uint256 sum;
        for (uint256 i = 0; i < numPositions; i++) {
            sum += CurveLib.positionAmount(curve, supply, i);
        }

        assertEq(sum, allocation, "positions sum to the curve allocation exactly");
    }

    // --- Scenario: Phased pricing across curves ---

    /// @dev A curve with a larger share concentrated over the same span holds more inventory per level,
    /// which is what makes early buying cheaper on average and later buying dearer.
    function test_phasedPricingConcentratesInventory() public pure {
        Curve memory early = Curve({startingLevel: BASE, numPositions: 4, shareWad: 0.7e18});
        Curve memory late = Curve({startingLevel: BASE + 3000, numPositions: 4, shareWad: 0.3e18});

        assertGt(
            CurveLib.curveAllocation(early, CURVE_SUPPLY),
            CurveLib.curveAllocation(late, CURVE_SUPPLY),
            "early curve holds more inventory"
        );
    }

    /// @dev More positions over the same span means finer granularity, not more inventory.
    function test_positionCountDoesNotChangeAllocation() public pure {
        Curve memory coarse = Curve({startingLevel: BASE, numPositions: 2, shareWad: uint64(WAD)});
        Curve memory fine = Curve({startingLevel: BASE, numPositions: 40, shareWad: uint64(WAD)});

        assertEq(
            CurveLib.curveAllocation(coarse, CURVE_SUPPLY),
            CurveLib.curveAllocation(fine, CURVE_SUPPLY),
            "same allocation"
        );
    }

    // --- Helpers ---

    function test_lowestStartingLevel() public pure {
        Curve[] memory curves = new Curve[](3);
        curves[0] = Curve({startingLevel: BASE + 500, numPositions: 5, shareWad: 0.4e18});
        curves[1] = Curve({startingLevel: BASE + 100, numPositions: 5, shareWad: 0.3e18});
        curves[2] = Curve({startingLevel: BASE + 900, numPositions: 5, shareWad: 0.3e18});

        assertEq(CurveLib.lowestStartingLevel(curves), BASE + 100, "minimum starting level");
    }

    function test_totalPositions() public pure {
        Curve[] memory curves = new Curve[](2);
        curves[0] = Curve({startingLevel: BASE, numPositions: 7, shareWad: 0.5e18});
        curves[1] = Curve({startingLevel: BASE + 100, numPositions: 11, shareWad: 0.5e18});

        assertEq(CurveLib.totalPositions(curves), 18, "summed positions");
    }
}
