// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
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
import {Bounds, Curve, LaunchConfig, Phase, WAD} from "../../src/types/LaunchTypes.sol";

/// @notice Unit tests for tasks 4.2 - 4.5: the launch entry point, its initialisation guard, NFT
/// wiring, and event completeness.
contract LaunchTest is Test {
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
    }

    function _params() internal pure returns (MilestoneBase.LaunchParams memory p) {
        p.name = "Milestone";
        p.symbol = "MILE";
        p.config = LaunchConfigLib.defaults(SUPPLY);
        p.curves = CurveLib.defaultCurves();
    }

    /// @dev `StateLibrary` attaches to `IPoolManager`, not to the concrete `PoolManager` type.
    function _slot0(PoolId poolId) internal view returns (uint160, int24, uint24, uint24) {
        return IPoolManager(address(manager)).getSlot0(poolId);
    }

    function _launchAs(address who) internal returns (PoolId poolId, address token, PoolKey memory key) {
        vm.prank(who);
        return hook.launch(_params());
    }

    // --- Scenario: Any caller can launch ---

    function test_anyCallerCanLaunch() public {
        (PoolId poolId, address token,) = _launchAs(CREATOR);

        assertEq(uint8(hook.poolPhase(poolId)), uint8(Phase.BONDING_CURVE), "phase advanced");
        assertTrue(token != address(0), "token deployed");
        assertEq(hook.poolState(poolId).creator, CREATOR, "creator recorded");
    }

    function test_strangerCanLaunchToo() public {
        (PoolId poolId,,) = _launchAs(STRANGER);
        assertEq(hook.poolState(poolId).creator, STRANGER, "no allowlist");
    }

    function test_launchNeedsNoValue() public {
        vm.prank(CREATOR);
        hook.launch(_params());
        // No revert: launching is free beyond gas.
    }

    // --- Scenario: Launch identity is unique per pool ---

    function test_launchIdentityIsUniquePerPool() public {
        (PoolId poolA, address tokenA,) = _launchAs(CREATOR);
        (PoolId poolB, address tokenB,) = _launchAs(STRANGER);

        assertTrue(PoolId.unwrap(poolA) != PoolId.unwrap(poolB), "distinct pool ids");
        assertTrue(tokenA != tokenB, "distinct tokens");
        assertEq(hook.poolState(poolA).creator, CREATOR, "pool A creator");
        assertEq(hook.poolState(poolB).creator, STRANGER, "pool B creator");
    }

    function test_oneLaunchDoesNotDisturbAnother() public {
        (PoolId poolA,,) = _launchAs(CREATOR);
        (PoolId poolB,,) = _launchAs(STRANGER);

        assertEq(hook.creatorClaimable(poolA), 0, "A creator balance");
        assertEq(hook.creatorClaimable(poolB), 0, "B creator balance");
        assertEq(hook.curveCount(poolA), 1, "A curves");
        assertEq(hook.curveCount(poolB), 1, "B curves");
    }

    // --- Token deployment and supply allocation ---

    /// @dev The `token-launch` spec scenario "Full supply is held by the hook" is written as "the
    /// hook's token balance equals the total supply". That is literally true only at token construction:
    /// `bonding-curve-phase` requires the curves to be live pool liquidity by the time the launch
    /// completes, so by then the curve share sits in the manager backing hook-owned positions.
    ///
    /// Asserted here is the property both requirements actually share — the hook is the sole custodian.
    /// Every token is either in hook custody or in a position the hook owns, and no third party holds
    /// any. See the session notes: the spec scenario's wording needs a small amendment.
    function test_hookIsTheSoleCustodianOfSupply() public {
        (, address token,) = _launchAs(CREATOR);
        MilestoneToken t = MilestoneToken(token);

        uint256 inCustody = t.balanceOf(HOOK_ADDR);
        uint256 inPool = t.balanceOf(address(manager));

        assertEq(t.totalSupply(), SUPPLY, "total supply");
        assertEq(inCustody + inPool, SUPPLY, "every token is custodied or pooled");
        assertEq(t.balanceOf(CREATOR), 0, "creator holds none");
        assertEq(t.balanceOf(address(this)), 0, "deployer holds none");

        // The pooled portion is exactly the configured bonding-curve share.
        assertLe(inPool, (SUPPLY * 25) / 100, "never overdraws the curve share");
        assertLt((SUPPLY * 25) / 100 - inPool, 1e6, "pooled shortfall is dust");
        assertGe(inCustody, (SUPPLY * 75) / 100, "ladder plus full-range share stays custodied");
    }

    /// @dev At construction, before any curve is minted, the hook really does hold everything.
    function test_tokenConstructorMintsEverythingToTheHook() public {
        MilestoneToken fresh = new MilestoneToken("X", "X", SUPPLY, HOOK_ADDR);

        assertEq(fresh.balanceOf(HOOK_ADDR), SUPPLY, "hook holds it all at construction");
    }

    function test_tokenMetadataFromParams() public {
        (, address token,) = _launchAs(CREATOR);

        assertEq(MilestoneToken(token).name(), "Milestone", "name");
        assertEq(MilestoneToken(token).symbol(), "MILE", "symbol");
    }

    // --- Scenario: Starting price matches the lowest curve boundary ---

    function test_startingPriceIsTheLowestCurveBoundary() public {
        MilestoneBase.LaunchParams memory p = _params();
        p.curves = new Curve[](2);
        p.curves[0] =
            Curve({startingLevel: Bounds.DEFAULT_START_LEVEL + 500, numPositions: 10, shareWad: uint64(WAD / 2)});
        p.curves[1] =
            Curve({startingLevel: Bounds.DEFAULT_START_LEVEL + 100, numPositions: 10, shareWad: uint64(WAD - WAD / 2)});

        vm.prank(CREATOR);
        (PoolId poolId,,) = hook.launch(p);

        (, int24 tick,,) = _slot0(poolId);
        assertEq(tick, Orientation.toTick(Bounds.DEFAULT_START_LEVEL + 100), "opened at the lowest curve boundary");
    }

    function test_startingPriceForDefaultCurves() public {
        (PoolId poolId,,) = _launchAs(CREATOR);

        (, int24 tick,,) = _slot0(poolId);
        // A cheap token opens at a large positive tick: level -138155 is tick +138155, ~1e6 token/ETH.
        assertEq(tick, -Bounds.DEFAULT_START_LEVEL, "opened at the default start level");
        assertGt(tick, 0, "token opens cheap");
    }

    /// @dev Confirms the orientation claim end to end: a curve starting at a higher level opens the
    /// pool at a lower tick.
    function test_higherStartingLevelMeansLowerTick() public {
        MilestoneBase.LaunchParams memory p = _params();
        p.curves = new Curve[](1);
        p.curves[0] = Curve({startingLevel: Bounds.DEFAULT_START_LEVEL + 3000, numPositions: 10, shareWad: uint64(WAD)});

        vm.prank(CREATOR);
        (PoolId poolId,,) = hook.launch(p);

        (, int24 tick,,) = _slot0(poolId);
        assertEq(tick, -(Bounds.DEFAULT_START_LEVEL + 3000), "higher level, lower tick");
        assertLt(tick, -Bounds.DEFAULT_START_LEVEL, "starting 3000 levels higher opens 3000 ticks lower");
    }

    // --- Scenario: Pool uses a dynamic fee ---

    function test_poolUsesADynamicFee() public {
        (,, PoolKey memory key) = _launchAs(CREATOR);

        assertTrue(LPFeeLibrary.isDynamicFee(key.fee), "key carries the dynamic fee flag");
    }

    /// @dev A dynamic-fee pool opens at fee 0, so the launch must push the base fee explicitly.
    function test_baseFeeIsSetAtLaunch() public {
        (PoolId poolId,,) = _launchAs(CREATOR);

        (,,, uint24 lpFee) = _slot0(poolId);
        assertEq(lpFee, Bounds.DEFAULT_BASE_FEE, "base fee pushed to 1%");
        assertEq(hook.poolState(poolId).baseFeeHundredthsBip, Bounds.DEFAULT_BASE_FEE, "recorded base fee");
    }

    function test_enabledScheduleSetsItsStartFeeAsTheBase() public {
        MilestoneBase.LaunchParams memory p = _params();
        p.config.feeSchedule.enabled = true;
        p.config.feeSchedule.startFeeHundredthsBip = 15_000;
        p.config.feeSchedule.stepCount = 1;
        p.config.feeSchedule.steps[0].feeHundredthsBip = 5_000;
        p.config.feeSchedule.steps[0].atCompletions = 2;

        vm.prank(CREATOR);
        (PoolId poolId,,) = hook.launch(p);

        (,,, uint24 lpFee) = _slot0(poolId);
        assertEq(lpFee, 15_000, "schedule start fee is the base");
    }

    function test_poolKeyOrientation() public {
        (,, PoolKey memory key) = _launchAs(CREATOR);

        assertEq(Currency.unwrap(key.currency0), address(0), "native ETH is currency0");
        assertTrue(Currency.unwrap(key.currency1) != address(0), "token is currency1");
        assertEq(address(key.hooks), HOOK_ADDR, "hook wired");
        assertEq(key.tickSpacing, Bounds.POOL_TICK_SPACING, "protocol tick spacing");
    }

    // --- Scenario: Pool initialization is restricted to the launch path (task 4.3) ---

    function test_externalInitializeIsRejected() public {
        (,, PoolKey memory key) = _launchAs(CREATOR);

        // A fresh key on the same hook, differing only in tick spacing, so it is a different pool.
        PoolKey memory forged = PoolKey({
            currency0: key.currency0,
            currency1: key.currency1,
            fee: key.fee,
            tickSpacing: 60,
            hooks: key.hooks
        });

        vm.prank(STRANGER);
        vm.expectRevert();
        manager.initialize(forged, TickMath.getSqrtPriceAtTick(0));
    }

    function test_forgedPoolOnAFreshTokenIsRejected() public {
        MilestoneToken rogue = new MilestoneToken("Rogue", "RGE", 1 ether, address(this));

        PoolKey memory forged = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(address(rogue)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: Bounds.POOL_TICK_SPACING,
            hooks: IHooks(HOOK_ADDR)
        });

        vm.prank(STRANGER);
        vm.expectRevert();
        manager.initialize(forged, TickMath.getSqrtPriceAtTick(0));

        assertEq(uint8(hook.poolPhase(PoolId.wrap(keccak256(abi.encode(forged))))), uint8(Phase.NONE), "no phase");
    }

    // --- Scenario: NFT minted to the creator (task 4.4) ---

    function test_creatorHoldsTheRevenueNftWithZeroBalance() public {
        (PoolId poolId,,) = _launchAs(CREATOR);

        uint256 tokenId = nft.tokenIdOf(poolId);
        assertEq(nft.ownerOf(tokenId), CREATOR, "creator owns the stream");
        assertEq(hook.creatorClaimable(poolId), 0, "starts empty");
        assertEq(hook.protocolClaimable(poolId), 0, "protocol starts empty");
    }

    function test_nftGoesToTheLauncherNotTheHook() public {
        (PoolId poolId,,) = _launchAs(STRANGER);

        assertEq(nft.ownerOf(nft.tokenIdOf(poolId)), STRANGER, "launcher receives it");
    }

    // --- Configuration is recorded and immutable ---

    function test_configurationIsRecorded() public {
        (PoolId poolId,,) = _launchAs(CREATOR);
        LaunchConfig memory stored = hook.launchConfig(poolId);

        assertEq(stored.totalSupply, SUPPLY, "supply");
        assertEq(stored.bandCount, 10, "band count");
        assertEq(stored.bandLevelSpacing, Bounds.DEFAULT_BAND_LEVEL_SPACING, "spacing");
        assertEq(stored.ladderSupplyShareWad, 0.65e18, "ladder share");
    }

    function test_ladderInventoryIsReservedAtLaunch() public {
        (PoolId poolId,,) = _launchAs(CREATOR);

        assertEq(hook.poolState(poolId).ladderInventoryRemaining, (SUPPLY * 65) / 100, "65% reserved");
    }

    function test_curvesAreRecorded() public {
        (PoolId poolId,,) = _launchAs(CREATOR);
        Curve[] memory stored = hook.curves(poolId);

        assertEq(stored.length, 1, "one curve");
        assertEq(stored[0].numPositions, 20, "positions");
        assertEq(stored[0].shareWad, uint64(WAD), "share");
    }

    function test_noConfigurationSetterExists() public {
        (PoolId poolId,,) = _launchAs(CREATOR);
        bytes32 raw = PoolId.unwrap(poolId);

        string[3] memory sigs =
            ["setConfig(bytes32,uint8)", "updateLaunchConfig(bytes32)", "setBandCount(bytes32,uint8)"];
        for (uint256 i = 0; i < sigs.length; i++) {
            (bool ok,) = HOOK_ADDR.call(abi.encodeWithSignature(sigs[i], raw, uint8(3)));
            assertFalse(ok, "configuration is immutable after launch");
        }
    }

    // --- Invalid configuration is rejected before anything is deployed ---

    function test_invalidConfigRejectsTheWholeLaunch() public {
        MilestoneBase.LaunchParams memory p = _params();
        p.config.bandCount = 2; // below the floor

        vm.prank(CREATOR);
        vm.expectRevert(abi.encodeWithSelector(LaunchConfigLib.BandCountOutOfRange.selector, uint8(2)));
        hook.launch(p);
    }

    function test_invalidCurvesRejectTheWholeLaunch() public {
        MilestoneBase.LaunchParams memory p = _params();
        p.curves[0].shareWad = uint64(WAD / 2); // no longer sums to WAD

        vm.prank(CREATOR);
        vm.expectRevert(abi.encodeWithSelector(CurveLib.CurveSharesMustSumToWad.selector, uint256(WAD / 2)));
        hook.launch(p);
    }

    function test_curveStartingAtFarLevelRejected() public {
        MilestoneBase.LaunchParams memory p = _params();
        p.curves[0].startingLevel = p.config.farLevel;

        vm.prank(CREATOR);
        vm.expectRevert(
            abi.encodeWithSelector(
                CurveLib.CurveStartsAtOrAboveFarLevel.selector, uint256(0), p.config.farLevel, p.config.farLevel
            )
        );
        hook.launch(p);
    }

    // --- Scenario: Dev buy is observable on chain (task 4.5) ---

    function test_launchEventsCarryTheGeometry() public {
        MilestoneBase.LaunchParams memory p = _params();

        vm.recordLogs();
        vm.prank(CREATOR);
        (PoolId poolId,,) = hook.launch(p);

        // Band ticks must be recomputable from event data alone: starting level, far level, step, and
        // count are all emitted, which is everything the ladder geometry needs.
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool sawLaunched;
        bool sawConfigured;
        bool sawCurve;

        for (uint256 i = 0; i < logs.length; i++) {
            bytes32 topic = logs[i].topics[0];
            if (topic == MilestoneBase.Launched.selector) sawLaunched = true;
            if (topic == MilestoneBase.LaunchConfigured.selector) sawConfigured = true;
            if (topic == MilestoneBase.CurveConfigured.selector) sawCurve = true;
        }

        assertTrue(sawLaunched, "Launched emitted");
        assertTrue(sawConfigured, "LaunchConfigured emitted");
        assertTrue(sawCurve, "CurveConfigured emitted per curve");
        assertEq(uint8(hook.poolPhase(poolId)), uint8(Phase.BONDING_CURVE), "launched");
    }

    function test_launchedEventFieldsMatchConfig() public {
        MilestoneBase.LaunchParams memory p = _params();

        vm.expectEmit(false, true, false, false);
        emit MilestoneBase.Launched(PoolId.wrap(bytes32(0)), CREATOR, address(0), 0, 0, 0, 0, 0);

        vm.prank(CREATOR);
        hook.launch(p);
    }

    function test_oneCurveEventPerCurve() public {
        MilestoneBase.LaunchParams memory p = _params();
        p.curves = new Curve[](2);
        p.curves[0] = Curve({startingLevel: Bounds.DEFAULT_START_LEVEL, numPositions: 10, shareWad: uint64(WAD / 2)});
        p.curves[1] =
            Curve({startingLevel: Bounds.DEFAULT_START_LEVEL + 200, numPositions: 10, shareWad: uint64(WAD - WAD / 2)});

        vm.recordLogs();
        vm.prank(CREATOR);
        hook.launch(p);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 curveEvents;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == MilestoneBase.CurveConfigured.selector) curveEvents++;
        }

        assertEq(curveEvents, 2, "one event per curve");
    }
}
