// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {MilestoneBase} from "../../src/MilestoneBase.sol";
import {MilestoneHook} from "../../src/MilestoneHook.sol";
import {MilestoneColdPaths} from "../../src/MilestoneColdPaths.sol";
import {MilestoneToken} from "../../src/MilestoneToken.sol";
import {RevenueNFT} from "../../src/RevenueNFT.sol";
import {LaunchSupport} from "../../src/LaunchSupport.sol";
import {CurveLib} from "../../src/libraries/CurveLib.sol";
import {LaunchConfigLib} from "../../src/libraries/LaunchConfigLib.sol";
import {Orientation} from "../../src/libraries/Orientation.sol";
import {Curve, LaunchConfig} from "../../src/types/LaunchTypes.sol";

/// @notice Router that performs swaps and liquidity operations through the manager on behalf of tests,
/// standing in for an ordinary third-party integrator.
contract TestRouter is IUnlockCallback {
    IPoolManager public immutable manager;

    enum Op {
        SWAP,
        ADD_LIQUIDITY,
        REMOVE_LIQUIDITY
    }

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    receive() external payable {}

    function swap(PoolKey memory key, bool zeroForOne, int256 amountSpecified)
        external
        payable
        returns (BalanceDelta)
    {
        uint160 limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        return _swap(key, zeroForOne, amountSpecified, limit);
    }

    /// @notice Swap with an explicit price limit, so a large buy stops at a chosen price rather than
    /// draining every position and running the price to the extreme.
    function swapToLimit(PoolKey memory key, bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96)
        external
        payable
        returns (BalanceDelta)
    {
        return _swap(key, zeroForOne, amountSpecified, sqrtPriceLimitX96);
    }

    function _swap(PoolKey memory key, bool zeroForOne, int256 amountSpecified, uint160 limit)
        private
        returns (BalanceDelta)
    {
        bytes memory result = manager.unlock(abi.encode(Op.SWAP, key, zeroForOne, amountSpecified, limit));
        return abi.decode(result, (BalanceDelta));
    }

    function addLiquidity(PoolKey memory key, int24 tickLower, int24 tickUpper, int256 liquidityDelta)
        external
        payable
    {
        manager.unlock(abi.encode(Op.ADD_LIQUIDITY, key, tickLower, tickUpper, liquidityDelta));
    }

    function removeLiquidity(PoolKey memory key, int24 tickLower, int24 tickUpper, int256 liquidityDelta) external {
        manager.unlock(abi.encode(Op.REMOVE_LIQUIDITY, key, tickLower, tickUpper, liquidityDelta));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "not manager");
        Op op = Op(uint8(uint256(bytes32(data[0:32]))));

        if (op == Op.SWAP) {
            (, PoolKey memory key, bool zeroForOne, int256 amountSpecified, uint160 limit) =
                abi.decode(data, (uint8, PoolKey, bool, int256, uint160));

            BalanceDelta delta = manager.swap(
                key,
                IPoolManager.SwapParams({
                    zeroForOne: zeroForOne,
                    amountSpecified: amountSpecified,
                    sqrtPriceLimitX96: limit
                }),
                ""
            );

            _settleOrTake(key.currency0, delta.amount0());
            _settleOrTake(key.currency1, delta.amount1());
            return abi.encode(delta);
        }

        (, PoolKey memory k, int24 tickLower, int24 tickUpper, int256 liquidityDelta) =
            abi.decode(data, (uint8, PoolKey, int24, int24, int256));

        (BalanceDelta d,) = manager.modifyLiquidity(
            k,
            IPoolManager.ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: liquidityDelta,
                salt: bytes32(0)
            }),
            ""
        );
        _settleOrTake(k.currency0, d.amount0());
        _settleOrTake(k.currency1, d.amount1());
        return "";
    }

    function _settleOrTake(Currency currency, int128 amount) private {
        if (amount < 0) {
            uint256 owed = uint256(uint128(-amount));
            if (currency.isAddressZero()) {
                manager.settle{value: owed}();
            } else {
                manager.sync(currency);
                currency.transfer(address(manager), owed);
                manager.settle();
            }
        } else if (amount > 0) {
            manager.take(currency, address(this), uint256(uint128(amount)));
        }
    }
}

/// @notice Unit tests for tasks 5.2, 5.5 and 5.6 — curve minting under an explicit unlock, the
/// hook-exclusive liquidity guards, and static liquidity with unrestricted two-way trading.
contract BondingCurveTest is Test {
    using StateLibrary for IPoolManager;

    address internal constant HOOK_ADDR = address(uint160((uint160(0xBEEF) << 20) | 15040));
    address internal constant PROTOCOL_ADMIN = address(0xADD1);
    address internal constant PROTOCOL_RECIPIENT = address(0xFEE5);
    address internal constant CREATOR = address(0xC0FFEE);
    address internal constant BUYER = address(0xB0B);

    uint256 internal constant SUPPLY = 1_000_000_000 ether;
    uint256 internal constant CURVE_SUPPLY = (SUPPLY * 25) / 100;

    PoolManager internal manager;
    MilestoneHook internal hook;
    RevenueNFT internal nft;
    LaunchSupport internal support;
    TestRouter internal router;

    PoolId internal poolId;
    PoolKey internal key;
    MilestoneToken internal token;

    function setUp() public {
        manager = new PoolManager(address(this));
        nft = new RevenueNFT();
        support = new LaunchSupport();

        MilestoneColdPaths coldPaths = new MilestoneColdPaths(IPoolManager(address(manager)), nft, support);

        deployCodeTo(
            "MilestoneHook.sol:MilestoneHook",
            abi.encode(IPoolManager(address(manager)), nft, support, coldPaths, PROTOCOL_ADMIN, PROTOCOL_RECIPIENT),
            HOOK_ADDR
        );
        hook = MilestoneHook(payable(HOOK_ADDR));
        nft.setMinter(HOOK_ADDR);

        router = new TestRouter(IPoolManager(address(manager)));

        MilestoneBase.LaunchParams memory p;
        p.name = "Milestone";
        p.symbol = "MILE";
        p.config = LaunchConfigLib.defaults(SUPPLY);
        p.curves = CurveLib.defaultCurves();

        vm.prank(CREATOR);
        (PoolId id, address tokenAddr, PoolKey memory k) = hook.launch(p);
        poolId = id;
        key = k;
        token = MilestoneToken(tokenAddr);

        vm.deal(BUYER, 10_000 ether);
        vm.deal(address(router), 10_000 ether);

        // Past the 60s anti-snipe window. These tests are about curve mechanics; at t=0 every swap
        // would pay the 99% snipe fee and barely move the price, which would test the wrong thing.
        // The window itself is covered in AntiSnipe.t.sol.
        vm.warp(block.timestamp + 61);
    }

    function _slot0() internal view returns (uint160 sqrtPriceX96, int24 tick) {
        (sqrtPriceX96, tick,,) = IPoolManager(address(manager)).getSlot0(poolId);
    }

    // --- Scenario: Curves are minted as pool liquidity at launch ---

    /// @dev Note `getLiquidity` is *active* liquidity at the current tick, which is legitimately zero
    /// here: every curve position has `tickUpper <= openingTick`, and a v4 position is active only when
    /// `tickLower <= tick < tickUpper`. The pool opens at the cheapest price with the whole fan waiting
    /// just below, and the first buy moves the tick down into the top position.
    function test_curvesAreLivePoolLiquidityAtLaunch() public view {
        // Dust: `getLiquidityForAmount1` floors the liquidity, so each position deposits a few wei
        // less than its computed amount. Always in the protocol's favour, never overdrawn.
        assertLe(token.balanceOf(address(manager)), CURVE_SUPPLY, "never overdraws the curve share");
        assertLt(CURVE_SUPPLY - token.balanceOf(address(manager)), 1e6, "shortfall is dust");
        assertEq(IPoolManager(address(manager)).getLiquidity(poolId), 0, "nothing active at the opening tick");

        // The positions themselves exist and hold liquidity.
        LaunchConfig memory config = hook.launchConfig(poolId);
        Curve[] memory curves = hook.curves(poolId);
        uint256 positionsWithLiquidity;

        for (uint256 p = 0; p < curves[0].numPositions; p++) {
            (int24 levelLower, int24 levelUpper) = CurveLib.positionLevels(curves[0], config.farLevel, p);
            (int24 tickLower, int24 tickUpper) = Orientation.levelRangeToTicks(levelLower, levelUpper);

            uint128 liquidity = IPoolManager(address(manager)).getPositionLiquidity(
                poolId, keccak256(abi.encodePacked(HOOK_ADDR, tickLower, tickUpper, hook.curvePositionSalt(0, p)))
            );
            if (liquidity > 0) positionsWithLiquidity++;
        }

        assertEq(positionsWithLiquidity, curves[0].numPositions, "every curve position holds liquidity");
    }

    /// @dev The first buy activates the top position, so liquidity becomes active as soon as the tick
    /// moves off the opening boundary.
    function test_liquidityBecomesActiveOnTheFirstBuy() public {
        router.swap(key, true, -1 ether);

        assertGt(IPoolManager(address(manager)).getLiquidity(poolId), 0, "liquidity active after the first buy");
    }

    /// @dev The exact invariant is conservation, not equality with the nominal share: tokens only ever
    /// move between hook custody and the pool, so the two must sum to total supply exactly.
    function test_supplyIsConservedAcrossCustodyAndPool() public view {
        assertEq(token.balanceOf(HOOK_ADDR) + token.balanceOf(address(manager)), SUPPLY, "conserved exactly");
    }

    function test_hookRetainsLadderAndFullRangeShares() public view {
        assertGe(token.balanceOf(HOOK_ADDR), SUPPLY - CURVE_SUPPLY, "at least 75% stays custodied");
        assertLt(token.balanceOf(HOOK_ADDR) - (SUPPLY - CURVE_SUPPLY), 1e6, "excess is only dust");
    }

    /// @dev The positions are single-sided token liquidity: the pool holds token but no ETH.
    function test_curvePositionsAreSingleSidedToken() public view {
        assertEq(address(manager).balance, 0, "no ETH in the pool at launch");
        assertGt(token.balanceOf(address(manager)), 0, "token in the pool at launch");
    }

    /// @dev Every curve position sits at or below the opening tick, which is what makes it token-only.
    function test_everyCurvePositionSitsAtOrBelowTheOpeningTick() public view {
        (, int24 tick) = _slot0();
        LaunchConfig memory config = hook.launchConfig(poolId);
        Curve[] memory curves = hook.curves(poolId);

        for (uint256 c = 0; c < curves.length; c++) {
            for (uint256 p = 0; p < curves[c].numPositions; p++) {
                (int24 levelLower, int24 levelUpper) = CurveLib.positionLevels(curves[c], config.farLevel, p);
                (int24 tickLower, int24 tickUpper) = Orientation.levelRangeToTicks(levelLower, levelUpper);

                assertLe(tickUpper, tick, "position upper bound at or below spot");
                assertLt(tickLower, tickUpper, "ascending tick range");
            }
        }
    }

    function test_curvesMintedEventEmitted() public {
        // Re-launch to capture the event.
        MilestoneBase.LaunchParams memory p;
        p.name = "Second";
        p.symbol = "SEC";
        p.config = LaunchConfigLib.defaults(SUPPLY);
        p.curves = CurveLib.defaultCurves();

        vm.recordLogs();
        vm.prank(CREATOR);
        hook.launch(p);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool saw;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == MilestoneBase.CurvesMinted.selector) saw = true;
        }
        assertTrue(saw, "CurvesMinted emitted");
    }

    // --- Scenario: Phased pricing across curves ---

    function test_phasedPricingProducesARisingFillPrice() public {
        // Buy in two equal ETH tranches and compare how much token each returns.
        BalanceDelta first = router.swap{value: 0}(key, true, -1 ether);
        uint256 firstOut = uint256(uint128(first.amount1()));

        BalanceDelta second = router.swap{value: 0}(key, true, -1 ether);
        uint256 secondOut = uint256(uint128(second.amount1()));

        assertGt(firstOut, 0, "first tranche filled");
        assertGt(secondOut, 0, "second tranche filled");
        assertLt(secondOut, firstOut, "later buyers get less token per ETH");
    }

    // --- Scenario: Buyers can always buy / Sellers can always sell ---

    function test_buyersCanBuy() public {
        uint256 before = token.balanceOf(address(router));
        router.swap(key, true, -1 ether);

        assertGt(token.balanceOf(address(router)) - before, 0, "buyer received token");
    }

    function test_sellersCanAlwaysSell() public {
        router.swap(key, true, -5 ether);
        uint256 acquired = token.balanceOf(address(router));
        assertGt(acquired, 0, "acquired token to sell");

        uint256 ethBefore = address(router).balance;
        router.swap(key, false, -int256(acquired / 2));

        assertGt(address(router).balance, ethBefore, "seller received ETH back");
    }

    function test_tradingMovesTheTickDownAsPriceRises() public {
        (, int24 tickBefore) = _slot0();

        router.swap(key, true, -10 ether);

        (, int24 tickAfter) = _slot0();
        assertLt(tickAfter, tickBefore, "buying pushes the tick down (token price up)");
        assertGt(Orientation.toLevel(tickAfter), Orientation.toLevel(tickBefore), "level rises");
    }

    function test_sellingMovesTheTickBackUp() public {
        router.swap(key, true, -10 ether);
        (, int24 tickAfterBuy) = _slot0();

        router.swap(key, false, -int256(token.balanceOf(address(router)) / 2));
        (, int24 tickAfterSell) = _slot0();

        assertGt(tickAfterSell, tickAfterBuy, "selling pushes the tick back up");
    }

    /// @dev Scenario: "No caller is privileged or blocked".
    function test_twoRoutersGetTheSameTreatment() public {
        TestRouter other = new TestRouter(IPoolManager(address(manager)));
        vm.deal(address(other), 1_000 ether);

        BalanceDelta a = router.swap(key, true, -1 ether);
        BalanceDelta b = other.swap(key, true, -1 ether);

        // Not equal amounts (price moved), but both succeeded on identical terms.
        assertGt(uint256(uint128(a.amount1())), 0, "first router filled");
        assertGt(uint256(uint128(b.amount1())), 0, "second router filled");
    }

    // --- Scenario: External liquidity addition / removal is rejected (task 5.5) ---

    function test_externalLiquidityAdditionIsRejected() public {
        vm.expectRevert();
        router.addLiquidity(key, -6000, -5000, 1e18);
    }

    function test_externalLiquidityRemovalIsRejected() public {
        vm.expectRevert();
        router.removeLiquidity(key, -6000, -5000, -1e18);
    }

    /// @dev Scenario: "No just-in-time LP exposure during fundraising" — the sandwich is impossible
    /// because its first leg cannot execute.
    function test_justInTimeSandwichIsImpossible() public {
        vm.expectRevert();
        router.addLiquidity(key, -7000, -100, 1e18);

        // The pool is unchanged and still tradeable.
        router.swap(key, true, -1 ether);
        assertGt(token.balanceOf(address(router)), 0, "pool still functions");
    }

    function test_creatorCannotAddLiquidityEither() public {
        TestRouter creatorRouter = new TestRouter(IPoolManager(address(manager)));
        vm.deal(address(creatorRouter), 100 ether);

        vm.prank(CREATOR);
        vm.expectRevert();
        creatorRouter.addLiquidity(key, -6000, -5000, 1e18);
    }

    // --- Scenario: Bonding curve liquidity is static (task 5.6) ---

    function test_noRebalancingOccursOverTime() public {
        uint256 liquidityBefore = IPoolManager(address(manager)).getLiquidity(poolId);
        uint256 poolTokenBefore = token.balanceOf(address(manager));

        vm.warp(block.timestamp + 365 days);
        vm.roll(block.number + 1_000_000);

        assertEq(IPoolManager(address(manager)).getLiquidity(poolId), liquidityBefore, "liquidity unchanged");
        assertEq(token.balanceOf(address(manager)), poolTokenBefore, "inventory unchanged");
    }

    function test_noCallerCanRepriceCurves() public {
        bytes32 raw = PoolId.unwrap(poolId);
        string[4] memory sigs =
            ["rebalance(bytes32)", "adjustCurves(bytes32)", "repriceCurves(bytes32)", "setCurves(bytes32)"];

        for (uint256 i = 0; i < sigs.length; i++) {
            (bool ok,) = HOOK_ADDR.call(abi.encodeWithSignature(sigs[i], raw));
            assertFalse(ok, "no reprice path exists");
        }
    }

    function test_priceAdvancesOnlyThroughTrading() public {
        (uint160 priceBefore,) = _slot0();

        vm.warp(block.timestamp + 30 days);
        (uint160 priceAfterTime,) = _slot0();
        assertEq(priceAfterTime, priceBefore, "time alone does not move the price");

        router.swap(key, true, -1 ether);
        (uint160 priceAfterTrade,) = _slot0();
        assertTrue(priceAfterTrade != priceBefore, "trading moves the price");
    }

    // --- Scenario: No refund or cancellation path exists ---

    function test_noRefundOrCancellationPathExists() public {
        bytes32 raw = PoolId.unwrap(poolId);
        string[4] memory sigs = ["cancel(bytes32)", "refund(bytes32)", "abort(bytes32)", "withdrawProceeds(bytes32)"];

        for (uint256 i = 0; i < sigs.length; i++) {
            (bool ok,) = HOOK_ADDR.call(abi.encodeWithSignature(sigs[i], raw));
            assertFalse(ok, "no cancellation path");
        }
    }

    /// @dev Scenario: "Holders are never trapped" / "Trading continues long after launch".
    function test_holdersAreNeverTrappedEvenLongAfterLaunch() public {
        router.swap(key, true, -5 ether);
        uint256 held = token.balanceOf(address(router));

        vm.warp(block.timestamp + 5 * 365 days);

        uint256 ethBefore = address(router).balance;
        router.swap(key, false, -int256(held));

        assertGt(address(router).balance, ethBefore, "exit still possible years later");
        assertEq(token.balanceOf(address(router)), 0, "sold the whole position");
    }
}
