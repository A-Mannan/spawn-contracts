// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {MilestoneBase} from "../../src/MilestoneBase.sol";
import {MilestoneToken} from "../../src/MilestoneToken.sol";
import {IPayoutPlugin} from "../../src/interfaces/IPayoutPlugin.sol";
import {LadderLib} from "../../src/libraries/LadderLib.sol";
import {Bounds, LaunchConfig, Phase, WAD} from "../../src/types/LaunchTypes.sol";
import {PluginRole} from "../../src/types/PayoutTypes.sol";
import {LaunchpadTest} from "../Fixtures.sol";

contract LaunchPayoutPlugin is IPayoutPlugin {
    function onPayout(PoolId, address) external payable {}
}

/// @notice Unit tests for tasks 4.2 - 4.5: the launch entry point, its initialisation guard, NFT
/// wiring, and event completeness.
///
/// @dev What a launch *is* — who may relay it, whose signature names the creator, where the token
/// lands — belongs to `LaunchSignature.t.sol` (Decision 19) and is not restated here. This suite
/// covers what the launch leaves behind: the pool's opening configuration, the guard on initialising
/// it, and whether an observer with only the logs and the published template can reconstruct the
/// ladder.
contract LaunchTest is LaunchpadTest {
    /// @dev Distinguishes each launch's configuration, and so its CREATE2 address: the salt is the
    /// configuration hash plus the recovered signer, and the hash excludes the deadline, so two
    /// launches that differ in nothing else collide on one token address.
    uint256 private nonce;

    function _freshConfig() internal returns (LaunchConfig memory) {
        nonce += 1;
        return _defaultConfig(string.concat("Launch ", vm.toString(nonce)), "LNCH");
    }

    // --- Launch mechanics with no scenario of their own ---

    function test_launchNeedsNoValue() public {
        _launchDirect(_freshConfig());
        // No revert: launching is free beyond gas.
    }

    /// @dev The metadata has to survive the trip through `LaunchSupport`'s CREATE2 deployment, which is
    /// the only thing between the signed configuration and the token's own storage.
    function test_tokenMetadataFromParams() public {
        LaunchConfig memory config = _freshConfig();

        (,, MilestoneToken t) = _launchDirect(config);

        assertEq(t.name(), config.name, "name");
        assertEq(t.symbol(), config.symbol, "symbol");
    }

    function test_poolKeyOrientation() public {
        (, PoolKey memory k,) = _launchDirect(_freshConfig());

        assertEq(Currency.unwrap(k.currency0), address(0), "native ETH is currency0");
        assertTrue(Currency.unwrap(k.currency1) != address(0), "token is currency1");
        assertEq(address(k.hooks), HOOK_ADDR, "hook wired");
        assertEq(k.tickSpacing, Bounds.POOL_TICK_SPACING, "protocol tick spacing");
    }

    function test_ladderInventoryIsReservedAtLaunch() public {
        (PoolId id,,) = _launchDirect(_freshConfig());

        uint256 expected = (SUPPLY * template.ladderSupplyShareWad) / WAD;
        assertEq(hook.poolState(id).ladderInventoryRemaining, expected, "the ladder share is reserved");
    }

    // --- Scenario: Launch identity is isolated ---

    /// @dev Distinct pool ids and distinct creators are proved in `LaunchSignature.t.sol`. The half
    /// asserted here is isolation: no state of one launch is readable or mutable from the other.
    function test_oneLaunchDoesNotDisturbAnother() public {
        (PoolId a,,) = _launchDirect(_freshConfig());
        (PoolId b,,) = _launchRelayed(_freshConfig(), RELAYER);

        assertEq(hook.creatorClaimable(a), 0, "A creator balance");
        assertEq(hook.creatorClaimable(b), 0, "B creator balance");
        assertEq(hook.poolState(a).curveDeployed, 1, "A holds only its genesis position");
        assertEq(hook.poolState(b).curveDeployed, 1, "B holds only its genesis position");
    }

    // --- Scenario: Protocol initially receives the full minted supply ---

    /// @dev The scenario is written as "the hook's token balance equals the total supply", which is
    /// literally true only at token construction — `MilestoneToken.t.sol` asserts it there. By the time
    /// a launch returns, the genesis curve position has settled its inventory into the manager, so what
    /// the two requirements actually share is that the hook is the sole custodian: every token is either
    /// in hook custody or in a position the hook owns, and no third party holds any.
    ///
    /// The pooled portion is one curve position's worth, not the whole curve share: the curve is
    /// deployed just in time (Decision 17) and genesis mints position 0 alone.
    function test_hookIsTheSoleCustodianOfSupply() public {
        (,, MilestoneToken t) = _launchDirect(_freshConfig());

        uint256 inCustody = t.balanceOf(HOOK_ADDR);
        uint256 inPool = t.balanceOf(address(manager));

        assertEq(t.totalSupply(), SUPPLY, "total supply");
        assertEq(inCustody + inPool, SUPPLY, "every token is custodied or pooled");
        assertEq(t.balanceOf(creator), 0, "creator holds none");
        assertEq(t.balanceOf(address(this)), 0, "deployer holds none");

        uint256 perPosition = ((SUPPLY * template.curveSupplyShareWad) / WAD) / template.curvePositions;
        assertGt(inPool, 0, "the genesis position is live");
        assertLe(inPool, perPosition, "never overdraws one position's share");
        assertGt(inPool, (perPosition * 99) / 100, "and draws all but dust of it");
    }

    // --- Scenario: Pool has no dynamic-fee flag ---
    // --- Scenario: Pool uses static one percent ---

    function test_poolUsesStaticOnePercentWithoutDynamicFlag() public {
        (PoolId id, PoolKey memory k,) = _launchDirect(_freshConfig());

        assertEq(k.fee, Bounds.TRADING_FEE_HUNDREDTHS_BIP, "static one percent key");
        assertFalse(LPFeeLibrary.isDynamicFee(k.fee), "no dynamic fee flag");
        assertEq(_baseFeeOf(id), Bounds.TRADING_FEE_HUNDREDTHS_BIP, "manager records one percent");
    }

    // --- Scenario: Pool is tradable at launch ---

    function test_poolIsTradableAtLaunch() public {
        (PoolId id, PoolKey memory k, MilestoneToken t) = _launchDirect(_freshConfig());
        uint256 before = t.balanceOf(address(router));

        router.swapToLimit(k, true, -int256(1 ether), _sqrtAtLevel(_levelOf(id) + 50));

        assertGt(t.balanceOf(address(router)), before, "launch liquidity serves an immediate buy");
        assertTrue(hook.curvePositionDeployed(id, 0), "genesis position is live");
    }

    // --- Scenario: Pool initialization is restricted ---

    function test_externalInitializeIsRejected() public {
        (, PoolKey memory k,) = _launchDirect(_freshConfig());

        // A fresh key on the same hook, differing only in tick spacing, so it is a different pool.
        PoolKey memory forged =
            PoolKey({currency0: k.currency0, currency1: k.currency1, fee: k.fee, tickSpacing: 60, hooks: k.hooks});

        vm.prank(STRANGER);
        vm.expectRevert();
        manager.initialize(forged, TickMath.getSqrtPriceAtTick(0));
    }

    function test_forgedPoolOnAFreshTokenIsRejected() public {
        MilestoneToken rogue = new MilestoneToken("Rogue", "RGE", 1 ether, address(this));

        PoolKey memory forged = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(address(rogue)),
            fee: Bounds.TRADING_FEE_HUNDREDTHS_BIP,
            tickSpacing: Bounds.POOL_TICK_SPACING,
            hooks: IHooks(HOOK_ADDR)
        });

        vm.prank(STRANGER);
        vm.expectRevert();
        manager.initialize(forged, TickMath.getSqrtPriceAtTick(0));

        assertEq(uint8(hook.poolPhase(PoolId.wrap(keccak256(abi.encode(forged))))), uint8(Phase.NONE), "no phase");
    }

    // --- Scenario: NFT is minted to the creator at launch ---

    /// @dev `RevenueNFT.t.sol` mints directly from the hook address; what is asserted here is that a real
    /// launch does it, and that the stream it names starts empty on both ledgers.
    function test_creatorHoldsTheRevenueNftWithZeroBalance() public {
        (PoolId id,,) = _launchDirect(_freshConfig());

        assertEq(nft.ownerOf(nft.tokenIdOf(id)), creator, "creator owns the stream");
        assertEq(hook.creatorClaimable(id), 0, "starts empty");
        assertEq(hook.protocolClaimable(), 0, "global protocol ledger starts empty");
    }

    // --- Scenario: Geometry is not configurable ---

    /// @dev The configuration struct carrying no geometry field is asserted in `ProtocolTemplate.t.sol`.
    /// The other half of the scenario is that no privileged path can introduce one after the fact: the
    /// geometry is constructor immutables on the hook (Decision 16), so there is nothing to set.
    function test_noConfigurationSetterExists() public {
        (PoolId id,,) = _launchDirect(_freshConfig());
        bytes32 raw = PoolId.unwrap(id);

        string[4] memory sigs = [
            "setConfig(bytes32,uint8)",
            "updateLaunchConfig(bytes32)",
            "setBandCount(bytes32,uint8)",
            "setBandLevelSpacing(int24)"
        ];
        for (uint256 i = 0; i < sigs.length; i++) {
            (bool ok,) = HOOK_ADDR.call(abi.encodeWithSignature(sigs[i], raw, uint8(3)));
            assertFalse(ok, "configuration is immutable after launch");
        }
    }

    // --- Scenario: Harvest percentages are not configurable ---
    // --- Scenario: Preset names are absent ---

    function test_launchStoresOnlyTheExactPayoutPlan() public {
        LaunchConfig memory config = _freshConfig();
        config.payoutPlan = 0;
        (PoolId id,,) = _launchDirect(config);

        assertEq(hook.payoutPlan(id), config.payoutPlan, "exact bitset stored");
        assertEq(hook.poolState(id).payoutPlan, config.payoutPlan, "no preset or percentage expansion");
    }

    // --- Scenario: Band ticks are computable by any observer ---

    /// @dev The strong form of task 4.5's second clause: not that the events fired, but that their
    /// payload plus the published template is *sufficient* to rebuild the ladder. The recomputation
    /// below reads `farLevel` out of the `Launched` log and takes spacing and width from the template —
    /// it never touches `poolState`. It matches because `graduationLevel` is set to `farLevel` at launch
    /// and only re-set at graduation, which emits `Graduated` carrying the level it settled on.
    function test_launchEventsCarryTheGeometry() public {
        vm.recordLogs();
        (PoolId id,,) = _launchDirect(_freshConfig());
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(_countLogs(logs, MilestoneBase.Launched.selector), 1, "Launched emitted once");
        assertEq(_countLogs(logs, MilestoneBase.LaunchConfigured.selector), 1, "LaunchConfigured emitted once");
        assertEq(
            _countLogs(logs, MilestoneBase.CurvePositionsDeployed.selector), 1, "the genesis position is announced"
        );

        Vm.Log memory launched = logs[_firstLogAt(logs, MilestoneBase.Launched.selector)];
        (uint256 totalSupply, int24 openingLevel, int24 farLevel,) =
            abi.decode(launched.data, (uint256, int24, int24, bytes32));

        assertEq(totalSupply, SUPPLY, "supply is in the log");
        assertLt(openingLevel, farLevel, "the curve spans upward in level space");
        assertEq(farLevel - openingLevel, template.curveSpanLevels, "and spans the template's curve");

        // Everything from here uses only `farLevel` and the template.
        for (uint256 i = 0; i < template.coreBandCount; i++) {
            (int24 lower, int24 upper, bool exists) =
                LadderLib.bandLevels(farLevel, template.bandLevelSpacing, template.bandWidthLevels, i);
            (int24 hookLower, int24 hookUpper, bool hookExists) = hook.bandLevels(id, i);

            assertTrue(exists, "the observer computes a band");
            assertEq(hookExists, exists, "existence agrees");
            assertEq(hookLower, lower, "lower level agrees");
            assertEq(hookUpper, upper, "upper level agrees");
        }

        // The first rung clears the graduation level by a full spacing, so no band overlaps the curve.
        (int24 firstLower,,) = hook.bandLevels(id, 0);
        assertEq(firstLower, farLevel + template.bandLevelSpacing, "band 0 sits one rung above graduation");
    }

    /// @dev Decodes the log rather than using `expectEmit`, so the pool id, creator, and token in the
    /// topics are checked against state instead of being matched against values the test supplies.
    function test_launchedEventFieldsMatchConfig() public {
        LaunchConfig memory config = _freshConfig();

        vm.recordLogs();
        (PoolId id,, MilestoneToken t) = _launchDirect(config);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        Vm.Log memory launched = logs[_firstLogAt(logs, MilestoneBase.Launched.selector)];
        assertEq(launched.topics[1], PoolId.unwrap(id), "poolId topic");
        assertEq(address(uint160(uint256(launched.topics[2]))), config.creator, "creator topic");
        assertEq(address(uint160(uint256(launched.topics[3]))), address(t), "token topic");

        (uint256 totalSupply, int24 openingLevel, int24 farLevel, bytes32 configHash) =
            abi.decode(launched.data, (uint256, int24, int24, bytes32));

        assertEq(totalSupply, config.totalSupply, "supply");
        assertEq(openingLevel, hook.poolState(id).openingLevel, "opening level");
        assertEq(farLevel, hook.poolState(id).farLevel, "far level");
        assertEq(farLevel, hook.poolState(id).graduationLevel, "graduation level starts at far");
        assertTrue(configHash != bytes32(0), "the signed configuration is identified");
    }
}
