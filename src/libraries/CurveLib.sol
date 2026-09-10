// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FixedPoint96} from "v4-core/src/libraries/FixedPoint96.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Orientation} from "./Orientation.sol";

/// @title CurveLib
/// @notice Geometry, sizing, and the opening-price anchor for the pre-graduation bonding curve.
///
/// @dev **Attribution.** The curve shape implements the *Doppler Multicurve algorithm* (Adams, Czernik,
/// Kulkarni, Kunz, April 2025, eqs. 3.1–3.2): a set of nested single-sided positions all terminating at
/// a shared far bound, each holding an equal share of supply. The algorithm is reimplemented here in
/// this protocol's level-space orientation and salt families; the vendored reference implementation is
/// BUSL-1.1 licensed and no code is taken from it (design Decision 17).
///
/// **Shape.** Position `i` spans `[openingLevel + i * span / n, farLevel]` — every position ends at the
/// same far level, so they nest rather than tile. Because each holds the same token amount over a
/// progressively shorter level span, liquidity *staircases upward*: thinnest at the opening level,
/// densest approaching the far level. Two things follow, and both are why the shape was chosen over a
/// contiguous equal-slice fan:
///
/// - **Cheap supply is structurally scarce.** Position 0 alone spans the whole 2x range with 1/32 of
///   curve inventory, so a sniper at open buys into the thinnest book the curve ever offers. The paper
///   proves the static single-position alternative front-loads exactly the opposite way.
/// - **The graduation sweep meets a deep wall**, which is where the anti-snipe protection that
///   Decision 20 removed from the fee schedule actually lives now.
///
/// **JIT.** Only position 0 is minted at genesis; positions 1..n-1 are minted just before the price
/// reaches their start level, by the shared simulation path (Decision 15). Launch gas is therefore
/// independent of the position count, and a genesis dev buy pays deploy gas only for what it consumes.
library CurveLib {
    /// @notice Thrown when a launch's supply places its opening level outside usable tick space.
    error OpeningLevelOutOfRange(int24 level);

    /// @notice Thrown when a launch's far level would exceed usable tick space.
    error FarLevelOutOfRange(int24 level);

    /// @notice The level at which `totalSupply` is valued at `openingFdvWei`.
    ///
    /// @dev design Decision 16's anchor. A fixed opening *price* let a 100-billion-supply token open at
    /// a 400-million-dollar valuation; anchoring the FDV instead makes every launch comparable, and the
    /// anchor is denominated in ETH because there is no on-chain ETH/USD oracle and none is wanted.
    ///
    /// The arithmetic is a change of units, not an approximation. Pool price is token-per-ETH, so
    /// `price = totalSupply / openingFdvWei` is precisely the price at which the whole supply is worth
    /// the anchor — both sides are raw 18-decimal integers, so the decimals cancel. From there
    /// `sqrtPriceX96 = sqrt(price) * 2^96`, and v4's own {TickMath} converts that to a tick.
    ///
    /// `FullMath.mulDiv` is load-bearing: `totalSupply << 192` overflows 256 bits for any realistic
    /// supply, and mulDiv carries the full 512-bit product through the division.
    ///
    /// The returned level is v4's tick granularity (one basis point per tick), so the realised opening
    /// FDV is within 0.01% of the anchor rather than exactly on it.
    function openingLevel(uint256 totalSupply, uint256 openingFdvWei) internal pure returns (int24) {
        uint256 priceX192 = FullMath.mulDiv(totalSupply, 1 << 192, openingFdvWei);
        uint256 sqrtPriceX96 = Math.sqrt(priceX192);

        if (sqrtPriceX96 < TickMath.MIN_SQRT_PRICE || sqrtPriceX96 >= TickMath.MAX_SQRT_PRICE) {
            revert OpeningLevelOutOfRange(0);
        }

        int24 level = Orientation.toLevel(TickMath.getTickAtSqrtPrice(uint160(sqrtPriceX96)));
        if (!Orientation.isValidLevel(level)) revert OpeningLevelOutOfRange(level);

        return level;
    }

    /// @notice The far level a curve of `spanLevels` reaches from `opening`, range-checked.
    /// @dev Reaching this level is what makes the pool graduate, so it must be a level the pool can
    /// actually price. A supply small enough to open near the top of tick space is rejected here rather
    /// than at the first buy.
    function farLevel(int24 opening, int24 spanLevels) internal pure returns (int24) {
        int256 far = int256(opening) + int256(spanLevels);
        if (far > int256(Orientation.MAX_LEVEL)) revert FarLevelOutOfRange(int24(far));
        return int24(far);
    }

    /// @notice Start level of curve position `index`.
    /// @dev Computed from the span rather than accumulated, so rounding cannot drift across positions
    /// and position 0 starts exactly at the opening level.
    function positionStart(int24 opening, int24 far, uint16 positions, uint256 index) internal pure returns (int24) {
        int256 span = int256(far) - int256(opening);
        return int24(int256(opening) + (span * int256(index)) / int256(uint256(positions)));
    }

    /// @notice Token amount allocated to curve position `index`.
    /// @dev An equal share each, with the last position absorbing the division remainder so the
    /// per-position amounts sum to the curve's supply share exactly.
    function positionAmount(uint256 curveSupply, uint16 positions, uint256 index) internal pure returns (uint256) {
        uint256 each = curveSupply / positions;
        if (index + 1 == positions) return curveSupply - each * (positions - 1);
        return each;
    }

    /// @notice Liquidity of curve position `index`, derived from geometry alone.
    ///
    /// @dev Recomputed rather than read back from the pool, which matters on the swap path: the
    /// simulation needs the liquidity of every position it crosses, and thirty-two `extsload`s per buy
    /// would be a real cost where thirty-two multiplications are not. It is exact because the mint uses
    /// this same expression — a single-sided `currency1` position, so `L = amount1 * Q96 / dSqrtPrice`.
    function positionLiquidity(int24 opening, int24 far, uint16 positions, uint256 curveSupply, uint256 index)
        internal
        pure
        returns (uint128)
    {
        int24 start = positionStart(opening, far, positions, index);
        if (start >= far) return 0;

        (int24 tickLower, int24 tickUpper) = Orientation.levelRangeToTicks(start, far);
        uint256 denominator =
            uint256(TickMath.getSqrtPriceAtTick(tickUpper)) - uint256(TickMath.getSqrtPriceAtTick(tickLower));
        if (denominator == 0) return 0;

        uint256 liquidity =
            FullMath.mulDiv(positionAmount(curveSupply, positions, index), FixedPoint96.Q96, denominator);
        return liquidity > type(uint128).max ? type(uint128).max : uint128(liquidity);
    }

    /// @notice The lowest position index whose start level is strictly above `level`.
    ///
    /// @dev Where the simulation begins its walk: everything below this index is already at or below
    /// spot, so it either exists as liquidity already or can never be minted single-sided.
    ///
    /// The closed form is inverted from {positionStart} and then corrected, because integer division
    /// floors in both directions and can leave the estimate one index either side of the true answer.
    /// The correction loop runs at most twice.
    function firstPositionAbove(int24 opening, int24 far, uint16 positions, int24 level)
        internal
        pure
        returns (uint256 index)
    {
        if (level < opening) return 0;

        int256 span = int256(far) - int256(opening);
        if (span <= 0) return positions;

        int256 estimate = ((int256(level) - int256(opening)) * int256(uint256(positions))) / span;
        if (estimate < 0) estimate = 0;
        if (estimate > int256(uint256(positions))) estimate = int256(uint256(positions));
        index = uint256(estimate);

        // Walk down while the previous position is also above `level` (over-estimate), then up while
        // this one is not (under-estimate). At most one step in either direction.
        while (index > 0 && positionStart(opening, far, positions, index - 1) > level) {
            index -= 1;
        }
        while (index < positions && positionStart(opening, far, positions, index) <= level) {
            index += 1;
        }
    }
}
