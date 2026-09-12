// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FixedPoint96} from "v4-core/src/libraries/FixedPoint96.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {LiquidityAmounts} from "v4-periphery/src/libraries/LiquidityAmounts.sol";
import {Vm} from "forge-std/Vm.sol";
import {MilestoneBase} from "../../src/MilestoneBase.sol";
import {Bounds, PoolState, WAD} from "../../src/types/LaunchTypes.sol";
import {LaunchpadTest} from "../Fixtures.sol";

/// @notice Unit tests for the graduation seeding revision — the bounded full-range position and the wall.
///
/// @dev Covers the `milestone-ladder` scenario "Graduation seeds the bounded full range and its wall",
/// the wall's fee realization ("Realised wall fees join the same waterfall"), and the walk's wall-aware
/// pricing ("The deployment walk prices the wall in"). Where a property overlaps the graduation
/// capability's no-withdrawal guarantee, the scenario is named in the section header.
///
/// The magnitudes asserted here were derived independently from the template's published constants: at
/// the pinned 1B supply, the 2-ETH opening FDV, and the 20% LP seed share, the ETH-limited seed consumes
/// about 72.77M of the 650M-token full-range share and the wall absorbs the remaining 577.23M.
contract GraduationSeedingTest is LaunchpadTest {
    using StateLibrary for IPoolManager;

    // --- Scenario: Graduation seeds the bounded full range and its wall ---

    function test_fullRangeSpansTheBoundedMarketCapRange() public {
        _graduate();

        PoolState memory state = hook.poolState(poolId);
        assertEq(state.fullRangeTickLower, Bounds.FULL_RANGE_TICK_LOWER, "the $150B bound");
        assertEq(state.fullRangeTickUpper, Bounds.FULL_RANGE_TICK_UPPER, "the $5,100 bound");
        assertGt(state.fullRangeLiquidity, 0, "and the position is real");
    }

    function test_wallAbsorbsTheUnconsumedFullRangeShare() public {
        vm.recordLogs();
        _graduate();
        (,, uint256 lpSeed,,) = _graduatedEvent();

        PoolState memory state = hook.poolState(poolId);
        assertGt(state.wallLiquidity, 0, "the wall was seeded");

        // Derived bounds: the 880,000 levels directly above graduation.
        assertEq(state.wallTickUpper, -state.farLevel - 1, "one level above graduation");
        assertEq(state.wallTickLower, -(state.farLevel + Bounds.WALL_WIDTH_LEVELS), "the full wall width");

        // Every token of the full-range share was placed: the pool holds the seed's and the wall's
        // positions, and hook custody holds nothing beyond the ladder's own ledgers plus rounding dust.
        uint256 ladderLedgers = state.ladderInventoryRemaining + state.carriedInventory + state.milestoneFundAccrued;
        uint256 dust = token.balanceOf(HOOK_ADDR) - ladderLedgers;
        assertApproxEqAbs(
            token.balanceOf(address(manager)) + dust, _fullRangeShare(), 1e18, "the share is fully placed"
        );
        assertLt(dust, 2e17, "and the residue is rounding dust, not an allocation");

        // The seed is ETH-limited, so it consumed exactly the LP seed and left the rest for the wall.
        assertApproxEqAbs(address(manager).balance, lpSeed, 10_000, "the pool's ETH is exactly the seed");
        assertGt(lpSeed, 0, "the seed is non-trivial");
    }

    /// @dev The split's magnitude, recomputed from the published bounds: about a ninth of the share into
    /// the full-range position, the rest into the wall. Tolerances absorb TickMath rounding at the
    /// extreme bounds, not economics; the conservation test above makes the partition exact.
    function test_theSeedIsEthLimitedAndTheWallTakesTheRemainder() public {
        vm.recordLogs();
        _graduate();
        (,, uint256 lpSeedQuote,,) = _graduatedEvent();

        PoolState memory state = hook.poolState(poolId);
        (uint160 sqrtPriceX96,,,) = IPoolManager(address(manager)).getSlot0(poolId);

        uint128 expectedLiquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(Bounds.FULL_RANGE_TICK_LOWER),
            TickMath.getSqrtPriceAtTick(Bounds.FULL_RANGE_TICK_UPPER),
            lpSeedQuote,
            _fullRangeShare()
        );
        assertApproxEqRel(state.fullRangeLiquidity, expectedLiquidity, 0.0001e18, "the ETH-limited liquidity");

        uint256 coreTokens = FullMath.mulDiv(
            expectedLiquidity,
            sqrtPriceX96 - TickMath.getSqrtPriceAtTick(Bounds.FULL_RANGE_TICK_LOWER),
            FixedPoint96.Q96
        );
        assertApproxEqRel(coreTokens, 72_772_659e18, 0.0001e18, "the documented core consumption");

        uint256 wallTokens = FullMath.mulDiv(
            state.wallLiquidity,
            TickMath.getSqrtPriceAtTick(state.wallTickUpper) - TickMath.getSqrtPriceAtTick(state.wallTickLower),
            FixedPoint96.Q96
        );
        assertApproxEqRel(wallTokens, 577_227_341e18, 0.0001e18, "the documented wall placement");
    }

    // --- Scenario (graduation): No caller can withdraw the full-range position ---

    /// @dev The wall is code-locked the same way the full-range position is: no removal path exists.
    /// `make lock-check` asserts that structurally; this is the observable consequence for the wall.
    function test_theWallIsAProtocolPositionNoOneElseCanTouch() public {
        _graduate();

        vm.prank(address(router));
        vm.expectRevert();
        manager.unlock(abi.encode("external"));

        PoolState memory state = hook.poolState(poolId);
        assertGt(state.wallLiquidity, 0, "the wall still holds its liquidity");
    }

    // --- Scenario: Realised wall fees join the same waterfall ---

    /// @dev A buy that traverses only the wall's range (1 ETH cannot reach band 0) pays its 1% fee to
    /// the liquidity in range — the wall and the full-range position together, and nothing else. The
    /// wall carries about 89% of that liquidity, so collection realises close to the whole fee; a build
    /// that dropped the wall's collect would realise only the full-range position's ~11% share.
    function test_collectFeesRealisesTheWallsQuoteFees() public {
        _graduate();

        _buy(1 ether);
        (uint256 quoteFees, uint256 tokenFees) = hook.collectFees(key);

        uint256 expectedFee = FullMath.mulDiv(1 ether, Bounds.TRADING_FEE_HUNDREDTHS_BIP, 1e6);
        assertApproxEqRel(quoteFees, expectedFee, 0.05e18, "the wall's share was realised");
        assertEq(tokenFees, 0, "a buy pays its fee in quote only");
    }

    // --- Scenario: The deployment walk prices the wall in ---

    /// @dev A buy too small to reach band 0 must deploy nothing: against the wall's liquidity the budget
    /// dies well inside the first gap. A walk that ignored the wall would over-estimate the budget's
    /// reach, deploy bands the swap never comes near, and leave them live above spot.
    function test_aBuyBelowTheWallCostCannotReachTheLadder() public {
        _graduate();

        vm.recordLogs();
        _buy(1 ether);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(_countLogs(logs, MilestoneBase.BandDeployed.selector), 0, "no band was deployed");
        assertLt(_level(), _bandLower(0), "and the price is still below the ladder");
        assertGt(_level(), hook.poolState(poolId).graduationLevel, "but the buy did move the price");
    }

    // --- Helpers ---

    function _fullRangeShare() private view returns (uint256) {
        return FullMath.mulDiv(SUPPLY, template.fullRangeSupplyShareWad, WAD);
    }

    /// @dev The {MilestoneBase.Graduated} event of the graduation this test just ran. Indexed topic is
    /// the pool id; the data carries graduationLevel, quoteProceeds, lpSeedQuote, creatorQuote,
    /// protocolQuote, and fullRangeLiquidity.
    function _graduatedEvent()
        private
        view
        returns (
            int24 graduationLevel,
            uint256 quoteProceeds,
            uint256 lpSeed,
            uint256 creatorQuote,
            uint256 protocolQuote
        )
    {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == MilestoneBase.Graduated.selector) {
                (int24 level, uint256 proceeds, uint256 seed, uint256 creator, uint256 protocol,,) =
                    abi.decode(logs[i].data, (int24, uint256, uint256, uint256, uint256, uint128, uint128));
                return (level, proceeds, seed, creator, protocol);
            }
        }
        revert("no Graduated event");
    }
}
