// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {Position} from "v4-core/src/libraries/Position.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
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
import {Bounds, Curve, LaunchConfig, Phase, PoolState} from "../../src/types/LaunchTypes.sol";
import {TestRouter} from "./BondingCurve.t.sol";

/// @notice Unit tests for task group 7 — the permissionless in-place graduation.
contract GraduationTest is Test {
    using StateLibrary for IPoolManager;

    address internal constant HOOK_ADDR = address(uint160((uint160(0xBEEF) << 20) | 15040));
    address internal constant PROTOCOL_ADMIN = address(0xADD1);
    address internal constant PROTOCOL_RECIPIENT = address(0xFEE5);
    address internal constant CREATOR = address(0xC0FFEE);
    address internal constant STRANGER = address(0xBAD);

    uint256 internal constant SUPPLY = 1_000_000_000 ether;

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

        vm.deal(address(router), 10_000_000 ether);
        // Past the anti-snipe window so buying through the curve is affordable.
        vm.warp(block.timestamp + 61);
    }

    function _level() internal view returns (int24) {
        (, int24 tick,,) = IPoolManager(address(manager)).getSlot0(poolId);
        return Orientation.toLevel(tick);
    }

    /// @dev Buys through the curve in modest increments until the far level is reached.
    ///
    /// Size matters here. The default curve holds 25% of a billion-token supply at roughly 1e6 tokens
    /// per ETH, so the whole fan is worth only a few hundred ETH. A single oversized buy exhausts every
    /// position and slams the price to `MIN_SQRT_PRICE`, which is not a graduation — it is running out
    /// of book.
    function _buyToFarLevel() internal {
        int24 farLevel = hook.launchConfig(poolId).farLevel;

        // A price-limited buy: large enough to clear the whole fan, stopped exactly at the far level.
        // This is the realistic graduation path — an unbounded buy would consume the last position and
        // run spot into the empty range above the curve.
        router.swapToLimit(key, true, -10_000 ether, TickMath.getSqrtPriceAtTick(Orientation.toTick(farLevel)));

        require(_level() >= farLevel, "could not reach the far level");
    }

    function _fullRangeLiquidity() internal view returns (uint128) {
        PoolState memory state = hook.poolState(poolId);
        return IPoolManager(address(manager)).getPositionLiquidity(
            poolId,
            Position.calculatePositionKey(
                HOOK_ADDR, state.fullRangeTickLower, state.fullRangeTickUpper, hook.FULL_RANGE_SALT()
            )
        );
    }

    // --- Scenario: Graduation is rejected below the far tick ---

    function test_graduationRejectedBelowFarLevel() public {
        int24 farLevel = hook.launchConfig(poolId).farLevel;

        vm.expectRevert(abi.encodeWithSelector(MilestoneBase.FarLevelNotReached.selector, _level(), farLevel));
        hook.graduate(key);

        assertEq(uint8(hook.poolPhase(poolId)), uint8(Phase.BONDING_CURVE), "still on the curve");
    }

    function test_graduationRejectedPartWayUpTheCurve() public {
        router.swap(key, true, -20 ether);
        assertLt(_level(), hook.launchConfig(poolId).farLevel, "not there yet");

        vm.expectRevert();
        hook.graduate(key);
    }

    // --- Scenario: Graduation succeeds at or above the far tick ---

    function test_graduationSucceedsAtFarLevel() public {
        _buyToFarLevel();

        hook.graduate(key);

        assertEq(uint8(hook.poolPhase(poolId)), uint8(Phase.GRADUATED), "graduated");
        assertGe(hook.poolState(poolId).graduationLevel, hook.launchConfig(poolId).farLevel, "level recorded");
        assertEq(hook.poolState(poolId).graduatedAt, block.timestamp, "timestamp recorded");
    }

    // --- Scenario: No privileged trigger ---

    function test_anyoneCanTriggerGraduation() public {
        _buyToFarLevel();

        vm.prank(STRANGER);
        hook.graduate(key);

        assertEq(uint8(hook.poolPhase(poolId)), uint8(Phase.GRADUATED), "a stranger graduated it");
    }

    // --- Scenario: Tick condition is evaluated at call time ---

    /// @dev A pool that touched the far level and fell back has not graduated. Nothing is recorded when
    /// the level is crossed, so there is no stale flag to exploit.
    function test_fallingBackBelowFarLevelBlocksGraduation() public {
        _buyToFarLevel();

        // Sell back down below the far level without graduating.
        uint256 held = token.balanceOf(address(router));
        router.swap(key, false, -int256(held / 2));

        if (_level() < hook.launchConfig(poolId).farLevel) {
            vm.expectRevert();
            hook.graduate(key);
            assertEq(uint8(hook.poolPhase(poolId)), uint8(Phase.BONDING_CURVE), "not graduated");
        }
    }

    // --- Scenario: Graduation happens once ---

    function test_graduationHappensOnce() public {
        _buyToFarLevel();
        hook.graduate(key);

        uint128 liquidityAfterFirst = _fullRangeLiquidity();
        uint256 creatorAfterFirst = hook.creatorClaimable(poolId);

        vm.expectRevert(abi.encodeWithSelector(MilestoneBase.NotInBondingCurvePhase.selector, poolId, Phase.GRADUATED));
        hook.graduate(key);

        assertEq(_fullRangeLiquidity(), liquidityAfterFirst, "nothing re-minted");
        assertEq(hook.creatorClaimable(poolId), creatorAfterFirst, "nothing re-split");
    }

    function test_graduationRejectedOnAnUnlaunchedPool() public {
        PoolKey memory foreign = key;
        foreign.tickSpacing = 60;

        vm.expectRevert();
        hook.graduate(foreign);
    }

    // --- Scenario: All curve positions are burned ---

    function test_allCurvePositionsAreBurned() public {
        _buyToFarLevel();
        hook.graduate(key);

        LaunchConfig memory config = hook.launchConfig(poolId);
        Curve[] memory curves = hook.curves(poolId);

        for (uint256 c = 0; c < curves.length; c++) {
            for (uint256 p = 0; p < curves[c].numPositions; p++) {
                (int24 levelLower, int24 levelUpper) = CurveLib.positionLevels(curves[c], config.farLevel, p);
                (int24 tickLower, int24 tickUpper) = Orientation.levelRangeToTicks(levelLower, levelUpper);

                uint128 liquidity = IPoolManager(address(manager)).getPositionLiquidity(
                    poolId, Position.calculatePositionKey(HOOK_ADDR, tickLower, tickUpper, hook.curvePositionSalt(c, p))
                );
                assertEq(liquidity, 0, "curve position fully burned");
            }
        }
    }

    // --- Scenario: Bonding curve proceeds split ---

    function test_defaultSplitIsApplied() public {
        _buyToFarLevel();

        vm.recordLogs();
        hook.graduate(key);

        (uint256 proceeds, uint256 lpSeed, uint256 creatorQuote, uint256 protocolQuote) = _graduatedEvent();

        assertGt(proceeds, 0, "the curve raised something");
        assertApproxEqRel(lpSeed, (proceeds * 40) / 100, 0.001e18, "40% LP seed");
        assertApproxEqRel(creatorQuote, (proceeds * 55) / 100, 0.001e18, "55% creator");
        assertApproxEqRel(protocolQuote, (proceeds * 5) / 100, 0.001e18, "5% protocol");
    }

    function _graduatedEvent()
        internal
        view
        returns (uint256 proceeds, uint256 lpSeed, uint256 creatorQuote, uint256 protocolQuote)
    {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == MilestoneBase.Graduated.selector) {
                (, proceeds, lpSeed, creatorQuote, protocolQuote,) =
                    abi.decode(logs[i].data, (int24, uint256, uint256, uint256, uint256, uint128));
                return (proceeds, lpSeed, creatorQuote, protocolQuote);
            }
        }
        revert("no Graduated event");
    }

    function test_splitAllocationsSumToProceeds() public {
        _buyToFarLevel();

        vm.recordLogs();
        hook.graduate(key);

        (uint256 proceeds, uint256 lpSeed, uint256 creatorQuote, uint256 protocolQuote) = _graduatedEvent();
        assertEq(lpSeed + creatorQuote + protocolQuote, proceeds, "exact partition, no dust lost");
    }

    function test_configuredLpSeedShareIsHonoured() public {
        // A fresh launch with a 60% LP seed.
        MilestoneBase.LaunchParams memory p;
        p.name = "Second";
        p.symbol = "SEC";
        p.config = LaunchConfigLib.defaults(SUPPLY);
        p.config.proceedsSplit.lpSeedWad = 0.6e18;
        p.config.proceedsSplit.creatorWad = 0.35e18;
        p.config.proceedsSplit.protocolWad = 0.05e18;
        p.curves = CurveLib.defaultCurves();

        vm.prank(CREATOR);
        (PoolId id,, PoolKey memory k) = hook.launch(p);

        poolId = id;
        key = k;

        // This pool launched just now, so its own anti-snipe window is still open. Without clearing it
        // the buy would pay 99% and never reach the far level.
        vm.warp(block.timestamp + 61);
        _buyToFarLevel();

        vm.recordLogs();
        hook.graduate(k);

        (uint256 proceeds, uint256 lpSeed,,) = _graduatedEvent();
        assertApproxEqRel(lpSeed, (proceeds * 60) / 100, 0.001e18, "60% LP seed honoured");
    }

    /// @dev Scenario: "Creator proceeds are not pushed".
    function test_creatorProceedsAreCreditedNotPushed() public {
        uint256 before = CREATOR.balance;

        _buyToFarLevel();
        hook.graduate(key);

        assertEq(CREATOR.balance, before, "nothing transferred during graduation");
        assertGt(hook.creatorClaimable(poolId), 0, "credited instead");
    }

    function test_creatorCanClaimAfterGraduation() public {
        _buyToFarLevel();
        hook.graduate(key);

        uint256 owed = hook.creatorClaimable(poolId);
        assertGt(owed, 0, "something accrued");

        vm.prank(CREATOR);
        assertEq(hook.claimCreator(poolId), owed, "claimed in full");
        assertEq(CREATOR.balance, owed, "paid in native ETH");
    }

    function test_protocolCanClaimAfterGraduation() public {
        _buyToFarLevel();
        hook.graduate(key);

        uint256 owed = hook.protocolClaimable(poolId);
        assertGt(owed, 0, "something accrued");

        vm.prank(PROTOCOL_RECIPIENT);
        assertEq(hook.claimProtocol(poolId), owed, "claimed in full");
    }

    /// @dev Custody must actually hold what the ledger promises, or a claim would revert.
    function test_custodyCoversTheAccruedClaims() public {
        _buyToFarLevel();
        hook.graduate(key);

        uint256 promised = hook.creatorClaimable(poolId) + hook.protocolClaimable(poolId);
        assertGe(HOOK_ADDR.balance, promised, "custody covers every credited claim");
    }

    // --- Scenario: Full-range position seeding ---

    function test_fullRangePositionIsCreated() public {
        _buyToFarLevel();
        hook.graduate(key);

        PoolState memory state = hook.poolState(poolId);
        assertGt(state.fullRangeLiquidity, 0, "liquidity recorded");
        // Wide, but deliberately inside TickMath's extremes — see Bounds.FULL_RANGE_TICK_BOUND for why a
        // literal full range would make graduation revert from a drained curve.
        assertEq(state.fullRangeTickLower, -Bounds.FULL_RANGE_TICK_BOUND, "spans the low end");
        assertEq(state.fullRangeTickUpper, Bounds.FULL_RANGE_TICK_BOUND, "spans the high end");
        assertGt(state.fullRangeTickLower, TickMath.minUsableTick(Bounds.POOL_TICK_SPACING), "inside the extreme");
        assertLt(state.fullRangeTickUpper, TickMath.maxUsableTick(Bounds.POOL_TICK_SPACING), "inside the extreme");
        assertEq(_fullRangeLiquidity(), state.fullRangeLiquidity, "pool agrees with recorded liquidity");
    }

    function test_fullRangeIsFundedFromBothSides() public {
        _buyToFarLevel();
        hook.graduate(key);

        // After graduation the pool backs one full-range position, so it must hold both assets.
        assertGt(address(manager).balance, 0, "pool holds ETH");
        assertGt(token.balanceOf(address(manager)), 0, "pool holds token");
    }

    /// @dev Scenario: "Ladder inventory is untouched by seeding".
    function test_ladderInventoryIsUntouched() public {
        uint256 reserved = hook.poolState(poolId).ladderInventoryRemaining;

        _buyToFarLevel();
        hook.graduate(key);

        assertEq(hook.poolState(poolId).ladderInventoryRemaining, reserved, "ladder reservation unchanged");
        assertGe(token.balanceOf(HOOK_ADDR), reserved, "custody still holds the ladder share");
    }

    // --- Scenario: Full-range position is permanently locked ---

    function test_noCallerCanWithdrawTheFullRange() public {
        _buyToFarLevel();
        hook.graduate(key);

        PoolState memory state = hook.poolState(poolId);

        vm.expectRevert();
        router.removeLiquidity(key, state.fullRangeTickLower, state.fullRangeTickUpper, -1e18);

        vm.prank(CREATOR);
        vm.expectRevert();
        router.removeLiquidity(key, state.fullRangeTickLower, state.fullRangeTickUpper, -1e18);

        assertEq(_fullRangeLiquidity(), state.fullRangeLiquidity, "untouched");
    }

    function test_noRemovalEntryPointExists() public {
        _buyToFarLevel();
        hook.graduate(key);
        bytes32 raw = PoolId.unwrap(poolId);

        string[5] memory sigs = [
            "removeFullRange(bytes32)",
            "withdrawLp(bytes32)",
            "unlockLp(bytes32)",
            "burnFullRange(bytes32)",
            "migrate(bytes32,address)"
        ];
        for (uint256 i = 0; i < sigs.length; i++) {
            (bool ok,) = HOOK_ADDR.call(abi.encodeWithSignature(sigs[i], raw));
            assertFalse(ok, "no removal or migration path");
        }
    }

    // --- Scenario: In-place phase transition ---

    function test_poolIdentityIsUnchanged() public {
        PoolKey memory before = key;

        _buyToFarLevel();
        hook.graduate(key);

        assertEq(PoolId.unwrap(before.toIdPublic()), PoolId.unwrap(poolId), "same pool id");
        assertEq(address(before.hooks), HOOK_ADDR, "same hook");
        assertEq(hook.poolState(poolId).token, address(token), "same token");
    }

    function test_tradingContinuesAfterGraduation() public {
        _buyToFarLevel();
        hook.graduate(key);

        // The full-range position is real liquidity, so the pool keeps working in both directions.
        uint256 tokenBefore = token.balanceOf(address(router));
        router.swap(key, true, -1 ether);
        assertGt(token.balanceOf(address(router)), tokenBefore, "buy filled after graduation");

        uint256 ethBefore = address(router).balance;
        router.swap(key, false, -int256(token.balanceOf(address(router)) / 4));
        assertGt(address(router).balance, ethBefore, "sell filled after graduation");
    }

    function test_externalLiquidityStillRejectedAfterGraduation() public {
        _buyToFarLevel();
        hook.graduate(key);

        vm.expectRevert();
        router.addLiquidity(key, -200_000, -100_000, 1e18);
    }
}

/// @dev Small extension so the test can recompute a pool id from a key it captured earlier.
library PoolKeyTestLib {
    function toIdPublic(PoolKey memory key) internal pure returns (PoolId) {
        return PoolId.wrap(keccak256(abi.encode(key)));
    }
}

using PoolKeyTestLib for PoolKey;
