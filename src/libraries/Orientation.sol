// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TickMath} from "v4-core/src/libraries/TickMath.sol";

/// @title Orientation
/// @notice The single boundary between Uniswap tick space and the protocol's "level" space.
///
/// @dev Why this exists (design.md Decision 3):
///
/// Native ETH is `address(0)`, which sorts below every ERC20, so the launch token is *always*
/// `currency1`. Pool price is therefore denominated as token-per-ETH. When the token appreciates,
/// one ETH buys fewer tokens, so pool price *falls* and the tick *falls*. Every "the price went up"
/// statement in the specs is a "the tick went down" statement in the pool.
///
/// Rather than scatter negations across ladder, graduation and harvest arithmetic — where a sign
/// error is not a revert but a band silently placed on the wrong side of spot, filled instantly at
/// the wrong price — all protocol arithmetic runs in `level = -tick`, which rises monotonically with
/// token price. This library is the only place the sign flips.
///
/// The negation is total, not merely usually-safe: `TickMath.MIN_TICK == -TickMath.MAX_TICK`, so the
/// valid tick range is symmetric about zero and negating any valid tick yields another valid tick.
/// `int24` has headroom besides (its minimum is -8388608), so no negation here can overflow.
library Orientation {
    /// @notice Lowest meaningful level, corresponding to `TickMath.MAX_TICK`.
    int24 internal constant MIN_LEVEL = -TickMath.MAX_TICK;

    /// @notice Highest meaningful level, corresponding to `TickMath.MIN_TICK`.
    int24 internal constant MAX_LEVEL = -TickMath.MIN_TICK;

    /// @notice Thrown when a level range is not strictly ascending in level space.
    error LevelRangeNotAscending(int24 levelLower, int24 levelUpper);

    /// @notice Thrown when a tick is outside the range v4 accepts.
    error TickOutOfRange(int24 tick);

    /// @notice Thrown when a level is outside the range v4 accepts.
    error LevelOutOfRange(int24 level);

    /// @notice Converts a pool tick into protocol level space.
    /// @dev One of exactly two negation sites in the protocol.
    function toLevel(int24 tick) internal pure returns (int24) {
        return -tick;
    }

    /// @notice Converts a protocol level back into pool tick space.
    /// @dev The other of exactly two negation sites in the protocol.
    function toTick(int24 level) internal pure returns (int24) {
        return -level;
    }

    /// @notice Converts an ascending level range into the pool tick range covering the same prices.
    /// @dev The bounds *swap*: higher levels are lower ticks. This is the inversion most likely to
    /// be fumbled at a call site, which is why it lives here and is composed strictly from
    /// {toTick} rather than open-coding a second negation.
    /// @param levelLower The lower bound in level space (the cheaper price).
    /// @param levelUpper The upper bound in level space (the dearer price).
    /// @return tickLower The lower bound in tick space, derived from `levelUpper`.
    /// @return tickUpper The upper bound in tick space, derived from `levelLower`.
    function levelRangeToTicks(int24 levelLower, int24 levelUpper)
        internal
        pure
        returns (int24 tickLower, int24 tickUpper)
    {
        if (levelLower >= levelUpper) revert LevelRangeNotAscending(levelLower, levelUpper);

        tickLower = toTick(levelUpper);
        tickUpper = toTick(levelLower);
    }

    /// @notice Converts an ascending tick range into the level range covering the same prices.
    /// @dev Inverse of {levelRangeToTicks}; the bounds swap back.
    function tickRangeToLevels(int24 tickLower, int24 tickUpper)
        internal
        pure
        returns (int24 levelLower, int24 levelUpper)
    {
        if (tickLower >= tickUpper) revert LevelRangeNotAscending(tickLower, tickUpper);

        levelLower = toLevel(tickUpper);
        levelUpper = toLevel(tickLower);
    }

    /// @notice Whether a tick is inside the range v4 will accept.
    function isValidTick(int24 tick) internal pure returns (bool) {
        return tick >= TickMath.MIN_TICK && tick <= TickMath.MAX_TICK;
    }

    /// @notice Whether a level maps onto a tick v4 will accept.
    function isValidLevel(int24 level) internal pure returns (bool) {
        return level >= MIN_LEVEL && level <= MAX_LEVEL;
    }

    /// @notice {toLevel} with an explicit range check, for untrusted or derived ticks.
    function toLevelChecked(int24 tick) internal pure returns (int24) {
        if (!isValidTick(tick)) revert TickOutOfRange(tick);
        return toLevel(tick);
    }

    /// @notice {toTick} with an explicit range check, for derived levels that must reach the pool.
    function toTickChecked(int24 level) internal pure returns (int24) {
        if (!isValidLevel(level)) revert LevelOutOfRange(level);
        return toTick(level);
    }
}
