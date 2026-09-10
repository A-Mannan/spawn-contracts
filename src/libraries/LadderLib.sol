// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FixedPoint96} from "v4-core/src/libraries/FixedPoint96.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {SwapMath} from "v4-core/src/libraries/SwapMath.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Orientation} from "./Orientation.sol";

/// @title LadderLib
/// @notice Band geometry, inventory arithmetic, and the swap-path simulation that drives deployment.
///
/// @dev **Geometry.** Bands are *derived*, never stored. Band `i` is a narrow level range sitting
/// `i + 1` uniform spacing steps above the graduation level:
///
///     levelLower(i) = graduationLevel + (i + 1) * bandLevelSpacing
///     levelUpper(i) = levelLower(i) + bandWidthLevels
///
/// Three properties fall out of that formula, each a requirement of the `milestone-ladder` spec:
///
/// - **Any observer can compute the ladder** from the protocol template plus the graduation level, with
///   no protocol state and no privileged read.
/// - **Uniform level spacing is geometric in market cap.** Level is `-tick` and price is `1.0001^tick`,
///   so a constant level step is a constant price *ratio*: 2235 levels is `1.0001^2235 ~= 1.2504x`, and
///   every band is the same multiple above the one below it.
/// - **One geometry applies to every band and every launch**, because the spacing and width are
///   template immutables rather than per-launch fields (design Decision 16).
///
/// The first band starts one full step *above* graduation rather than at it, so graduating does not
/// instantly fill a milestone. Fee-funded bands (index `>= coreBandCount`) continue the same formula,
/// which is what makes "a new band one spacing step above the last" free rather than a special case.
///
/// **Simulation.** {Walk} and {advance} are design Decision 15: rather than waiting for the price to
/// enter a deploy window, the hook walks the incoming swap's own price path with v4's `SwapMath` and
/// mints every position the path will cross, *before* the swap executes. That closes the two holes the
/// window had — an undeployed band straddling spot could neither deploy nor be skipped, and a sweep
/// through undeployed space sold nothing there.
///
/// The walk can be exact because the whole liquidity profile is protocol-owned and deterministic: one
/// code-locked full-range position plus hook-minted bands, whose bounds are derived and whose
/// liquidity is readable. Nothing is `extsload`ed from manager internals, and between walls there are
/// no tick boundaries at all, so the walk is O(bands crossed).
library LadderLib {
    /// @notice v4's per-tick liquidity ceiling at this protocol's fixed tick spacing of 1.
    ///
    /// @dev `type(uint128).max / 1774545`, where 1774545 is the number of usable ticks. Hardcoded rather
    /// than imported so production bytecode does not carry `Pool.sol`'s dependency graph for one pure
    /// function; `LadderLib.t.sol` asserts it still equals
    /// `Pool.tickSpacingToMaxLiquidityPerTick(Bounds.POOL_TICK_SPACING)`, so a change in v4 cannot drift
    /// past CI.
    ///
    /// It matters because `Pool.modifyLiquidity` reverts with `TickLiquidityOverflow` above this value,
    /// and a band mint happens inside `beforeSwap` — where the `milestone-ladder` spec forbids the hook
    /// from ever blocking a swap. Clamping is the difference between "an extreme launch makes bands
    /// smaller" and "an extreme launch bricks the pool".
    uint128 internal constant MAX_LIQUIDITY_PER_TICK = 191757530477355301479181766273477;

    /// @notice Upper bound on iterations of the deployment walk, independent of the deploy cap.
    ///
    /// @dev The walk also steps over bands it does *not* deploy — already-deployed ones it must traverse
    /// to price the gap beyond, and skipped ones below spot. Those cost no `modifyLiquidity` and so are
    /// not charged against `maxDeploysPerSwap`, but they still cost gas, so the loop needs its own
    /// ceiling. Stopping early can only under-deploy, which degrades to the specified skip-and-carry.
    uint256 internal constant MAX_WALK_STEPS = 64;

    /// @notice The running state of a simulated swap path.
    /// @dev `amountRemaining` follows v4's own sign convention: negative is exact input, positive is
    /// exact output. Carrying it in that form is what lets {advance} hand it straight to `SwapMath`.
    struct Walk {
        uint160 sqrtPriceX96;
        int256 amountRemaining;
        uint160 sqrtPriceLimitX96;
        uint24 feePips;
    }

    /// @notice Level bounds of band `index`.
    ///
    /// @dev Returns `exists == false` instead of reverting when the band would run past the top of tick
    /// space. That case is reachable — the fee-funded extension can address a level above
    /// `Orientation.MAX_LEVEL` — and it is evaluated inside `beforeSwap`, so the only acceptable outcome
    /// is "the ladder ends here", not a reverted swap.
    ///
    /// Arithmetic runs in `int256`: `index` is bounded only by the extension cap, so the product leaves
    /// `int24` long before it leaves `int256`.
    function bandLevels(int24 graduationLevel, int24 levelSpacing, int24 widthLevels, uint256 index)
        internal
        pure
        returns (int24 levelLower, int24 levelUpper, bool exists)
    {
        int256 lower = int256(graduationLevel) + (int256(index) + 1) * int256(levelSpacing);
        int256 upper = lower + int256(widthLevels);

        // Only the top needs checking: the spacing and width are both positive template values, so
        // `lower > graduationLevel >= Orientation.MIN_LEVEL` and `upper > lower`.
        if (upper > int256(Orientation.MAX_LEVEL)) return (0, 0, false);

        return (int24(lower), int24(upper), true);
    }

    /// @notice The token inventory each of the `coreBandCount` core bands is entitled to.
    /// @dev The ladder's whole supply share divided evenly. Bands are equal by design: the ladder share
    /// and the band count are both template values, so there is no per-band allocation to drift.
    function perBandInventory(uint256 totalSupply, uint64 ladderSupplyShareWad, uint8 coreBandCount)
        internal
        pure
        returns (uint256)
    {
        if (coreBandCount == 0) return 0;
        return ladderSupply(totalSupply, ladderSupplyShareWad) / coreBandCount;
    }

    /// @notice The ladder's total token allocation, as fixed at launch.
    function ladderSupply(uint256 totalSupply, uint64 ladderSupplyShareWad) internal pure returns (uint256) {
        return FullMath.mulDiv(totalSupply, ladderSupplyShareWad, 1e18);
    }

    /// @notice Splits the tokens available to a band into the amount it takes and the amount carried on.
    ///
    /// @dev A band's inventory is capped at a template multiple of its configured share so that carried
    /// inventory from skipped bands and accrued milestone-fund tokens top up the next band without
    /// concentrating the entire ladder into one position. Whatever exceeds the cap stays carried and
    /// tops up the band after it.
    /// @param available Everything the band could draw: its own share, carried inventory, accrued fund.
    /// @param perBand The configured per-band share, which sets the cap.
    /// @param capMultiple Template multiple of `perBand` a single band may hold.
    /// @return amount What the band takes.
    /// @return carried What is left for the next band.
    function sizeInventory(uint256 available, uint256 perBand, uint8 capMultiple)
        internal
        pure
        returns (uint256 amount, uint256 carried)
    {
        uint256 cap = mulSaturating(perBand, capMultiple);
        if (available > cap) return (cap, available - cap);
        return (available, 0);
    }

    /// @notice Liquidity for a single-sided token position, clamped so v4 cannot reject the mint.
    ///
    /// @dev This is `LiquidityAmounts.getLiquidityForAmount1` with the `uint128` cast replaced by a
    /// clamp. The cast is the problem: `amount1 * Q96 / (sqrtUpper - sqrtLower)` grows without bound as
    /// the band narrows and the price rises, and a `SafeCastOverflow` or `TickLiquidityOverflow` inside
    /// `beforeSwap` would revert the swap — which the `milestone-ladder` spec forbids outright.
    ///
    /// So the *amount* is clamped first, to the largest one whose liquidity still fits under
    /// {MAX_LIQUIDITY_PER_TICK}, and the multiplication is then guaranteed in range. The caller mints the
    /// returned liquidity, learns the tokens actually consumed from the resulting balance delta, and
    /// carries the difference forward — so a clamp costs nothing but a smaller band.
    function boundedLiquidity(uint160 sqrtLower, uint160 sqrtUpper, uint256 amount1)
        internal
        pure
        returns (uint128 liquidity)
    {
        if (sqrtUpper <= sqrtLower || amount1 == 0) return 0;

        uint256 denominator = uint256(sqrtUpper) - uint256(sqrtLower);
        uint256 maxAmount1 = FullMath.mulDiv(MAX_LIQUIDITY_PER_TICK, denominator, FixedPoint96.Q96);
        if (amount1 > maxAmount1) amount1 = maxAmount1;

        // In range by construction: `amount1 <= maxAmount1` bounds the quotient by MAX_LIQUIDITY_PER_TICK.
        liquidity = uint128(FullMath.mulDiv(amount1, FixedPoint96.Q96, denominator));
    }

    /// @notice One past the highest addressable band index.
    ///
    /// @dev Band membership is stored as one bit per index in a `uint256`, so index 256 has nowhere to
    /// live. That ceiling is *not* implied by the creation caps: a level the price jumped is skipped
    /// rather than created, and a skip advances the cursor without consuming an extension, so the
    /// absolute index can outrun `coreBandCount + maxFeeFundedBands` without bound. Left unchecked,
    /// `1 << 256` evaluates to zero — the band would mint, record no deployed bit, and never appear in
    /// the live set to be harvested, stranding its inventory in a position nothing can burn.
    uint256 internal constant MAX_BAND_COUNT = 256;

    /// @notice Whether band `index` may still be created at all.
    /// @dev Core bands are always addressable. Fee-funded bands stop at the template cap, counted in
    /// bands actually created — a level the price jumped was never created and so does not consume one.
    /// Every index is additionally bounded by {MAX_BAND_COUNT}, which is the bitmap's width rather than
    /// an economic limit; reaching it ends the ladder the same way running out of tick space does.
    function withinLadderCap(uint8 coreBandCount, uint256 index, uint32 feeFundedBandsCreated, uint8 maxFeeFunded)
        internal
        pure
        returns (bool)
    {
        if (index >= MAX_BAND_COUNT) return false;
        if (index < coreBandCount) return true;
        return feeFundedBandsCreated < maxFeeFunded;
    }

    /// @notice `a * b`, saturating at `type(uint256).max` instead of reverting.
    ///
    /// @dev Total supply is unbounded above, so an inventory capacity expressed as a multiple of a
    /// per-band share can leave `uint256` for a large enough launch. Reverting there would be worse than
    /// saturating: the products this guards are compared against real inventory and then clamped by a
    /// fee amount, so a saturated ceiling is indistinguishable from the true one at every reachable
    /// input, while a revert would permanently brick fee collection for that pool.
    function mulSaturating(uint256 a, uint256 b) internal pure returns (uint256) {
        if (a == 0 || b == 0) return 0;
        unchecked {
            uint256 product = a * b;
            if (product / a != b) return type(uint256).max;
            return product;
        }
    }

    // --- Swap-path simulation (design Decision 15) ---

    /// @notice Advances the walk toward `targetSqrtPriceX96` through `liquidity`.
    ///
    /// @dev A buy in this pool is `zeroForOne`: ETH in, token out, price *falling* in tick space and
    /// therefore *rising* in level space. So the walk always moves downward in sqrt-price, and the
    /// effective target is `max(next, limit)` — v4's own {SwapMath.getSqrtPriceTarget} for that
    /// direction.
    ///
    /// The step itself is `SwapMath.computeSwapStep`, the identical function `Pool.swap` will call a
    /// moment later on the identical inputs. That is what makes the simulation exact rather than an
    /// estimate: the only thing that can differ between this walk and the real execution is the
    /// liquidity profile the caller supplies, and every position in this pool is protocol-owned.
    ///
    /// @return reached True when the price arrived at the requested target — meaning the swap really
    /// will cross this boundary, and whatever sits there is worth deploying.
    function advance(Walk memory walk, uint160 targetSqrtPriceX96, uint128 liquidity)
        internal
        pure
        returns (bool reached)
    {
        if (walk.amountRemaining == 0) return false;
        // Already at or beyond the boundary; nothing to spend to get there.
        if (targetSqrtPriceX96 >= walk.sqrtPriceX96) return true;

        uint160 target = SwapMath.getSqrtPriceTarget(true, targetSqrtPriceX96, walk.sqrtPriceLimitX96);
        // The caller's own price limit stops the swap short of this boundary, so nothing beyond it is
        // reachable however large the budget.
        if (target >= walk.sqrtPriceX96) return false;

        (uint160 next, uint256 amountIn, uint256 amountOut, uint256 feeAmount) =
            SwapMath.computeSwapStep(walk.sqrtPriceX96, target, liquidity, walk.amountRemaining, walk.feePips);

        if (walk.amountRemaining > 0) {
            walk.amountRemaining -= int256(amountOut);
        } else {
            walk.amountRemaining += int256(amountIn + feeAmount);
        }
        walk.sqrtPriceX96 = next;

        return next == targetSqrtPriceX96;
    }

    /// @notice Sqrt price at a level, for use as a walk target.
    /// @dev The one place the simulation crosses the orientation boundary: a level bound becomes the
    /// tick bound of the same price.
    function sqrtPriceAtLevel(int24 level) internal pure returns (uint160) {
        return TickMath.getSqrtPriceAtTick(Orientation.toTick(level));
    }
}
