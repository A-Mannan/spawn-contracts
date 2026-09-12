// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Orientation} from "../../src/libraries/Orientation.sol";
import {LaunchpadTest, TestRouter} from "../Fixtures.sol";

/// @notice Unit tests for tasks 5.5 and 5.6: liquidity is the hook's exclusively, trading is nobody's
/// exclusively, and the curve's shape is fixed for as long as the pool lives.
///
/// @dev The curve's *geometry* — how many positions exist, where they start, how their liquidity
/// staircases — is `NestedCurve.t.sol`'s subject. What is asserted here is the surrounding contract with
/// the outside world: who may touch liquidity, who may trade, and what the passage of time is allowed to
/// change. Both suites read the same pool; neither restates the other.
contract BondingCurveTest is LaunchpadTest {
    // --- Curve custody at launch ---

    /// @dev Single-sided means literally one currency: the positions sit entirely below spot in tick
    /// space, so the pool holds launch token and not one wei of ETH. That is what makes the curve a
    /// sell-only book at the opening price, and it is why a buy is the only trade the pool can fill first.
    function test_curvePositionsAreSingleSidedToken() public view {
        assertEq(address(manager).balance, 0, "no ETH in the pool at launch");
        assertGt(token.balanceOf(address(manager)), 0, "token in the pool at launch");
    }

    // --- Rising fill price across the nested staircase ---

    /// @dev The economic consequence of the nested shape: each tranche of ETH buys less token than the
    /// one before it, with no schedule, oracle, or phase counter involved — only the book.
    function test_phasedPricingProducesARisingFillPrice() public {
        BalanceDelta first = _buy(1 ether);
        uint256 firstOut = uint256(uint128(first.amount1()));

        BalanceDelta second = _buy(1 ether);
        uint256 secondOut = uint256(uint128(second.amount1()));

        assertGt(firstOut, 0, "first tranche filled");
        assertGt(secondOut, 0, "second tranche filled");
        assertLt(secondOut, firstOut, "later buyers get less token per ETH");
    }

    // --- Scenario: Buyers can always buy ---

    function test_buyersCanBuy() public {
        uint256 before = token.balanceOf(address(router));
        _buy(1 ether);

        assertGt(token.balanceOf(address(router)) - before, 0, "buyer received token");
    }

    function test_tradingMovesTheTickDownAsPriceRises() public {
        (, int24 tickBefore) = _slot0();

        _buy(10 ether);

        (, int24 tickAfter) = _slot0();
        assertLt(tickAfter, tickBefore, "buying pushes the tick down (token price up)");
        assertGt(Orientation.toLevel(tickAfter), Orientation.toLevel(tickBefore), "level rises");
    }

    // --- Scenario: Sellers can always sell ---

    function test_sellersCanAlwaysSell() public {
        _buy(5 ether);
        uint256 acquired = token.balanceOf(address(router));
        assertGt(acquired, 0, "acquired token to sell");

        uint256 ethBefore = address(router).balance;
        _sell(acquired / 2);

        assertGt(address(router).balance, ethBefore, "seller received ETH back");
    }

    function test_sellingMovesTheTickBackUp() public {
        _buy(10 ether);
        (, int24 tickAfterBuy) = _slot0();

        _sell(token.balanceOf(address(router)) / 2);
        (, int24 tickAfterSell) = _slot0();

        assertGt(tickAfterSell, tickAfterBuy, "selling pushes the tick back up");
    }

    // --- Scenario: No caller is privileged or blocked ---

    function test_twoRoutersGetTheSameTreatment() public {
        TestRouter other = new TestRouter(IPoolManager(address(manager)));
        vm.deal(address(other), 1_000 ether);

        BalanceDelta a = _buy(1 ether);
        BalanceDelta b = other.swap(key, true, -1 ether);

        // Not equal amounts (price moved), but both succeeded on identical terms.
        assertGt(uint256(uint128(a.amount1())), 0, "first router filled");
        assertGt(uint256(uint128(b.amount1())), 0, "second router filled");
    }

    // --- Scenario: External liquidity addition is rejected ---

    function test_externalLiquidityAdditionIsRejected() public {
        vm.expectRevert();
        router.addLiquidity(key, -6000, -5000, 1e18);
    }

    /// @dev The guard is on the operation, not on the identity: the creator is no more able to provide
    /// liquidity than a stranger is, which is what keeps the curve's shape a protocol property.
    function test_creatorCannotAddLiquidityEither() public {
        TestRouter creatorRouter = new TestRouter(IPoolManager(address(manager)));
        vm.deal(address(creatorRouter), 100 ether);

        vm.prank(creator);
        vm.expectRevert();
        creatorRouter.addLiquidity(key, -6000, -5000, 1e18);
    }

    // --- Scenario: External liquidity removal is rejected ---

    function test_externalLiquidityRemovalIsRejected() public {
        vm.expectRevert();
        router.removeLiquidity(key, -6000, -5000, -1e18);
    }

    // --- Scenario: Hook-initiated liquidity operations succeed ---

    /// @dev The positive half of the same guard, and the reason it cannot simply reject everything: the
    /// genesis position is a `modifyLiquidity` call that passed through `beforeAddLiquidity`, and the
    /// price path deploys more of them as it advances. So the operation an external caller cannot perform
    /// at all is one the hook performs repeatedly, on the same pool, in the same phase.
    function test_hookInitiatedLiquidityOperationsSucceed() public {
        assertGt(_curveLiquidity(0), 0, "the hook's own genesis position is live");

        uint256 deployedBefore = _deployedCurveCount();
        _buy(50 ether);

        assertGt(_deployedCurveCount(), deployedBefore, "and the hook adds more as the price advances");

        vm.expectRevert();
        router.addLiquidity(key, -6000, -5000, 1e18);
    }

    // --- Scenario: No just-in-time LP exposure during fundraising ---

    /// @dev The sandwich is impossible because its first leg cannot execute; the pool is otherwise
    /// untouched by the attempt.
    function test_justInTimeSandwichIsImpossible() public {
        vm.expectRevert();
        router.addLiquidity(key, -7000, -100, 1e18);

        _buy(1 ether);
        assertGt(token.balanceOf(address(router)), 0, "pool still functions");
    }

    // --- Scenario: No caller can reprice curves ---

    function test_noCallerCanRepriceCurves() public view {
        bytes32 raw = PoolId.unwrap(poolId);
        string[4] memory sigs =
            ["rebalance(bytes32)", "adjustCurves(bytes32)", "repriceCurves(bytes32)", "setCurves(bytes32)"];

        for (uint256 i = 0; i < sigs.length; i++) {
            (bool ok,) = HOOK_ADDR.staticcall(abi.encodeWithSignature(sigs[i], raw));
            assertFalse(ok, "no reprice path exists");
        }
    }

    // --- Scenario: Price advances only through trading ---

    function test_priceAdvancesOnlyThroughTrading() public {
        (uint160 priceBefore,) = _slot0();

        vm.warp(launchTime + 30 days);
        (uint160 priceAfterTime,) = _slot0();
        assertEq(priceAfterTime, priceBefore, "time alone does not move the price");

        _buy(1 ether);
        (uint160 priceAfterTrade,) = _slot0();
        assertTrue(priceAfterTrade != priceBefore, "trading moves the price");
    }

    // --- Scenario: No refund or cancellation path exists ---

    function test_noRefundOrCancellationPathExists() public view {
        bytes32 raw = PoolId.unwrap(poolId);
        string[4] memory sigs = ["cancel(bytes32)", "refund(bytes32)", "abort(bytes32)", "withdrawProceeds(bytes32)"];

        for (uint256 i = 0; i < sigs.length; i++) {
            (bool ok,) = HOOK_ADDR.staticcall(abi.encodeWithSignature(sigs[i], raw));
            assertFalse(ok, "no cancellation path");
        }
    }

    // --- Scenario: Holders are never trapped ---
    // --- Scenario: Trading continues long after launch ---

    /// @dev The exit is taken years later, with no keeper having touched the pool in between.
    function test_holdersAreNeverTrappedEvenLongAfterLaunch() public {
        _buy(0.5 ether);
        uint256 held = token.balanceOf(address(router));

        vm.warp(launchTime + 5 * 365 days);

        uint256 ethBefore = address(router).balance;
        _sell(held);

        assertGt(address(router).balance, ethBefore, "exit still possible years later");
        assertEq(token.balanceOf(address(router)), 0, "sold the whole position");
    }
}
