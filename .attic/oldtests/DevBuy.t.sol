// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {MilestoneBase} from "../../src/MilestoneBase.sol";
import {MilestoneHook} from "../../src/MilestoneHook.sol";
import {MilestoneColdPaths} from "../../src/MilestoneColdPaths.sol";
import {MilestoneToken} from "../../src/MilestoneToken.sol";
import {RevenueNFT} from "../../src/RevenueNFT.sol";
import {LaunchSupport} from "../../src/LaunchSupport.sol";
import {CurveLib} from "../../src/libraries/CurveLib.sol";
import {LaunchConfigLib} from "../../src/libraries/LaunchConfigLib.sol";
import {Bounds} from "../../src/types/LaunchTypes.sol";

/// @notice Unit tests for tasks 5.3 and 5.4 — the optional dev buy and its hook-held linear vesting.
contract DevBuyTest is Test {
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

        vm.deal(CREATOR, 100_000 ether);
    }

    function _params(uint64 devBuyShareWad, uint32 vestingSeconds)
        internal
        pure
        returns (MilestoneBase.LaunchParams memory p)
    {
        p.name = "Milestone";
        p.symbol = "MILE";
        p.config = LaunchConfigLib.defaults(SUPPLY);
        p.config.devBuyShareWad = devBuyShareWad;
        p.config.devBuyVestingSeconds = vestingSeconds;
        p.curves = CurveLib.defaultCurves();
    }

    function _launch(uint64 devBuyShareWad, uint32 vestingSeconds, uint256 value)
        internal
        returns (PoolId poolId, MilestoneToken token)
    {
        vm.prank(CREATOR);
        (PoolId id, address tokenAddr,) = hook.launch{value: value}(_params(devBuyShareWad, vestingSeconds));
        return (id, MilestoneToken(tokenAddr));
    }

    // --- Scenario: No dev buy is the default ---

    function test_noDevBuyByDefault() public {
        (PoolId poolId, MilestoneToken token) = _launch(0, 0, 0);

        assertEq(hook.poolState(poolId).devBuyTotal, 0, "no dev buy recorded");
        assertEq(token.balanceOf(CREATOR), 0, "creator holds no token");
        assertEq(hook.releasableDevBuy(poolId), 0, "nothing to release");
    }

    function test_ethWithoutADevBuyIsRejected() public {
        vm.prank(CREATOR);
        vm.expectRevert(abi.encodeWithSelector(MilestoneBase.DevBuyEthWithoutDevBuy.selector, uint256(1 ether)));
        hook.launch{value: 1 ether}(_params(0, 0));
    }

    // --- Scenario: Dev buy consumes bonding curve inventory ---

    function test_devBuyConsumesCurveInventory() public {
        (PoolId poolIdNoDev,) = _launch(0, 0, 0);
        uint256 pooledWithoutDevBuy = _pooledToken(poolIdNoDev);

        (PoolId poolId, MilestoneToken token) = _launch(0.1e18, 0, 50_000 ether);

        // The dev buy's tokens came out of the pool, so the pool holds less than an identical launch
        // without one, by roughly the purchased amount.
        uint256 pooled = token.balanceOf(address(manager));
        assertLt(pooled, pooledWithoutDevBuy, "pool holds less after a dev buy");

        uint256 purchased = hook.poolState(poolId).devBuyTotal;
        assertEq(purchased, (SUPPLY * 10) / 100, "purchased the configured share");
        assertApproxEqRel(pooledWithoutDevBuy - pooled, purchased, 0.01e18, "the shortfall is the dev buy");
    }

    function _pooledToken(PoolId poolId) internal view returns (uint256) {
        return MilestoneToken(hook.poolState(poolId).token).balanceOf(address(manager));
    }

    function test_devBuyMovesThePriceLikeAnyBuy() public {
        (PoolId withoutDev,) = _launch(0, 0, 0);
        (, int24 tickWithout,,) = IPoolManager(address(manager)).getSlot0(withoutDev);

        (PoolId withDev,) = _launch(0.1e18, 0, 50_000 ether);
        (, int24 tickWith,,) = IPoolManager(address(manager)).getSlot0(withDev);

        assertLt(tickWith, tickWithout, "the dev buy pushed the price up like any buy");
    }

    function test_devBuyPaysRealEth() public {
        uint256 before = CREATOR.balance;
        _launch(0.05e18, 0, 50_000 ether);

        assertLt(CREATOR.balance, before, "creator paid for the tokens");
    }

    function test_unspentEthIsRefunded() public {
        uint256 before = CREATOR.balance;
        (PoolId poolId,) = _launch(0.01e18, 0, 90_000 ether);

        uint256 spent = before - CREATOR.balance;
        assertLt(spent, 90_000 ether, "the whole budget was not consumed");
        assertGt(spent, 0, "something was spent");
        assertEq(hook.poolState(poolId).devBuyTotal, SUPPLY / 100, "bought exactly the configured share");
    }

    function test_insufficientEthRevertsTheWholeLaunch() public {
        vm.prank(CREATOR);
        vm.expectRevert();
        hook.launch{value: 1 wei}(_params(0.1e18, 0));
    }

    // --- Scenario: Dev buy is capped below the bonding curve share ---
    // (validator-level; proved end to end here)

    function test_devBuyAboveCapIsRejectedAtLaunch() public {
        vm.prank(CREATOR);
        vm.expectRevert();
        hook.launch{value: 90_000 ether}(_params(uint64(Bounds.MAX_DEV_BUY_SHARE_WAD + 1), 0));
    }

    function test_devBuyEqualToCurveShareIsRejectedAtLaunch() public {
        MilestoneBase.LaunchParams memory p = _params(0.25e18, 0);

        vm.prank(CREATOR);
        vm.expectRevert();
        hook.launch{value: 90_000 ether}(p);
    }

    // --- Scenario: Zero vesting releases immediately ---

    function test_zeroVestingReleasesImmediately() public {
        (PoolId poolId, MilestoneToken token) = _launch(0.05e18, 0, 90_000 ether);

        uint256 expected = (SUPPLY * 5) / 100;
        assertEq(token.balanceOf(CREATOR), expected, "creator received the tokens at launch");
        assertEq(hook.releasableDevBuy(poolId), 0, "nothing left to release");
        assertEq(hook.poolState(poolId).devBuyReleased, expected, "recorded as released");
    }

    // --- Scenario: Vested tokens are held by the hook ---

    function test_vestedTokensAreHeldByTheHook() public {
        (PoolId poolId, MilestoneToken token) = _launch(0.05e18, 180 days, 90_000 ether);

        assertEq(token.balanceOf(CREATOR), 0, "creator holds nothing yet");
        assertEq(hook.poolState(poolId).devBuyTotal, (SUPPLY * 5) / 100, "recorded");
        assertEq(hook.releasableDevBuy(poolId), 0, "nothing vested at t=0");
    }

    // --- Scenario: Linear release over the vesting period ---

    function test_linearReleaseOverThePeriod() public {
        uint32 duration = 180 days;
        (PoolId poolId, MilestoneToken token) = _launch(0.05e18, duration, 90_000 ether);
        uint256 total = (SUPPLY * 5) / 100;

        vm.warp(block.timestamp + duration / 2);
        assertApproxEqAbs(hook.releasableDevBuy(poolId), total / 2, 1e12, "half vested at the midpoint");

        vm.prank(CREATOR);
        uint256 released = hook.releaseDevBuy(poolId);

        assertApproxEqAbs(released, total / 2, 1e12, "released about half");
        assertEq(token.balanceOf(CREATOR), released, "creator holds exactly what was released");
        assertEq(hook.releasableDevBuy(poolId), 0, "nothing left right now");
    }

    function test_releaseIsIncrementalAcrossTheSchedule() public {
        uint32 duration = 100 days;
        (PoolId poolId, MilestoneToken token) = _launch(0.05e18, duration, 90_000 ether);
        uint256 total = (SUPPLY * 5) / 100;

        // Warp targets are computed from a base captured once, not from repeated `block.timestamp`
        // reads. Under via_ir solc common-subexpression-eliminates `block.timestamp` — valid, since it is
        // constant within a real transaction — so `vm.warp(block.timestamp + x)` in a loop would advance
        // the clock only once.
        uint256 start = block.timestamp;
        uint256 releasedSoFar;
        for (uint256 i = 1; i <= 4; i++) {
            vm.warp(start + (uint256(duration) / 4) * i);
            vm.prank(CREATOR);
            releasedSoFar += hook.releaseDevBuy(poolId);
        }

        assertEq(releasedSoFar, total, "the whole allocation released over the schedule");
        assertEq(token.balanceOf(CREATOR), total, "creator holds it all");
    }

    // --- Scenario: Full release after the vesting period ---

    function test_fullReleaseAfterThePeriod() public {
        uint32 duration = 90 days;
        (PoolId poolId, MilestoneToken token) = _launch(0.05e18, duration, 90_000 ether);
        uint256 total = (SUPPLY * 5) / 100;

        vm.warp(block.timestamp + duration + 1);

        vm.prank(CREATOR);
        assertEq(hook.releaseDevBuy(poolId), total, "everything vested");
        assertEq(token.balanceOf(CREATOR), total, "creator holds it all");

        // Further claims transfer nothing.
        vm.prank(CREATOR);
        assertEq(hook.releaseDevBuy(poolId), 0, "nothing further");
        assertEq(token.balanceOf(CREATOR), total, "balance unchanged");
    }

    function test_vestingNeverOverReleases() public {
        uint32 duration = 30 days;
        (PoolId poolId,) = _launch(0.05e18, duration, 90_000 ether);
        uint256 total = (SUPPLY * 5) / 100;

        vm.warp(block.timestamp + 10 * 365 days);
        assertEq(hook.releasableDevBuy(poolId), total, "capped at the purchased amount");
    }

    // --- Scenario: Only the creator can claim vested tokens ---

    function test_onlyCreatorCanRelease() public {
        (PoolId poolId,) = _launch(0.05e18, 90 days, 90_000 ether);
        vm.warp(block.timestamp + 45 days);

        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(MilestoneBase.NotCreator.selector, poolId, STRANGER));
        hook.releaseDevBuy(poolId);

        vm.prank(PROTOCOL_ADMIN);
        vm.expectRevert(abi.encodeWithSelector(MilestoneBase.NotCreator.selector, poolId, PROTOCOL_ADMIN));
        hook.releaseDevBuy(poolId);
    }

    /// @dev Selling the revenue NFT does not hand over the vesting schedule: the two are separate
    /// entitlements, and only the NFT is transferable.
    function test_transferringTheRevenueNftDoesNotMoveTheVestingSchedule() public {
        (PoolId poolId,) = _launch(0.05e18, 90 days, 90_000 ether);

        uint256 tokenId = nft.tokenIdOf(poolId);
        vm.prank(CREATOR);
        nft.transferFrom(CREATOR, STRANGER, tokenId);

        vm.warp(block.timestamp + 45 days);

        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(MilestoneBase.NotCreator.selector, poolId, STRANGER));
        hook.releaseDevBuy(poolId);

        vm.prank(CREATOR);
        assertGt(hook.releaseDevBuy(poolId), 0, "creator still releases their own vesting");
    }

    function testFuzz_vestedAmountIsMonotonic(uint32 elapsed) public {
        uint32 duration = 365 days;
        (PoolId poolId,) = _launch(0.05e18, duration, 90_000 ether);

        elapsed = uint32(bound(elapsed, 0, duration));
        uint256 start = block.timestamp;

        vm.warp(start + elapsed);
        uint256 first = hook.releasableDevBuy(poolId);

        vm.warp(start + duration);
        uint256 later = hook.releasableDevBuy(poolId);

        assertGe(later, first, "vested amount never decreases");
        assertEq(later, (SUPPLY * 5) / 100, "fully vested at the end");
    }
}
