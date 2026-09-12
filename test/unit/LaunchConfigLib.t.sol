// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {IPayoutPlugin} from "../../src/interfaces/IPayoutPlugin.sol";
import {LaunchSupport} from "../../src/LaunchSupport.sol";
import {PayoutPluginRegistry} from "../../src/PayoutPluginRegistry.sol";
import {LaunchConfigLib} from "../../src/libraries/LaunchConfigLib.sol";
import {Bounds, LaunchConfig, WAD} from "../../src/types/LaunchTypes.sol";
import {PluginRole} from "../../src/types/PayoutTypes.sol";

contract ConfigPayoutPlugin is IPayoutPlugin {
    function onPayout(PoolId, address) external payable {}
}

/// @notice Launch-bound and exact payout-plan validation against the immutable registry.
contract LaunchConfigLibTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 ether;
    address internal constant CREATOR = address(0xC0FFEE);

    PayoutPluginRegistry internal registry;
    LaunchSupport internal support;

    function setUp() public {
        registry = new PayoutPluginRegistry(address(this));
        support = new LaunchSupport(registry);
    }

    function _base() internal pure returns (LaunchConfig memory) {
        return Bounds.defaultConfig(CREATOR, "Milestone", "MILE", SUPPLY);
    }

    function _register(uint64 takeWad) internal returns (uint8 index) {
        index = registry.registerPlugin(address(new ConfigPayoutPlugin()), takeWad, 100_000, PluginRole.PAYOUT);
    }

    // --- Scenario: Empty plan is accepted ---

    function test_emptyPlanIsAccepted() public view {
        support.validate(_base());
    }

    // --- Scenario: Unknown or suspended plan bit is rejected ---

    function test_unknownPlanBitIsRejected() public {
        LaunchConfig memory config = _base();
        config.payoutPlan = uint256(1) << 255;

        vm.expectRevert(PayoutPluginRegistry.EntryDoesNotExist.selector);
        support.validate(config);
    }

    function test_suspendedPlanBitIsRejected() public {
        uint8 index = _register(0.2e18);
        registry.setPluginSuspended(index, true);
        LaunchConfig memory config = _base();
        config.payoutPlan = uint256(1) << index;

        vm.expectRevert(PayoutPluginRegistry.EntryNotSelectable.selector);
        support.validate(config);
    }

    // --- Scenario: Enabled takes above one whole are rejected ---

    function test_selectedTakesAboveOneWholeAreRejected() public {
        uint8 first = _register(0.6e18);
        uint8 second = _register(0.5e18);
        LaunchConfig memory config = _base();
        config.payoutPlan = (uint256(1) << first) | (uint256(1) << second);

        vm.expectRevert(abi.encodeWithSelector(LaunchSupport.PayoutTakesAboveWad.selector, 1.1e18));
        support.validate(config);
    }

    // --- Scenario: More than eight plugins is rejected ---

    function test_moreThanEightPluginsIsRejected() public {
        LaunchConfig memory config = _base();
        for (uint256 i = 0; i < 9; i++) {
            config.payoutPlan |= uint256(1) << _register(0);
        }

        vm.expectRevert(abi.encodeWithSelector(LaunchSupport.TooManyPayoutPlugins.selector, 9));
        support.validate(config);
    }

    // --- Scenario: Exact whole plan is accepted ---

    function test_exactWholePlanIsAccepted() public {
        uint8 first = _register(0.4e18);
        uint8 second = _register(0.6e18);
        LaunchConfig memory config = _base();
        config.payoutPlan = (uint256(1) << first) | (uint256(1) << second);

        support.validate(config);
    }

    // --- Scenario: Dev buy is capped at ten percent ---

    function test_devBuyCapIsInclusiveAndImmutable() public {
        LaunchConfig memory config = _base();
        config.devBuyShareWad = Bounds.MAX_DEV_BUY_SHARE_WAD;
        support.validate(config);

        config.devBuyShareWad += 1;
        vm.expectRevert(
            abi.encodeWithSelector(LaunchConfigLib.DevBuyAboveCap.selector, Bounds.MAX_DEV_BUY_SHARE_WAD + 1)
        );
        support.validate(config);
    }

    // --- Scenario: Harvest percentages are not configurable ---
    // --- Scenario: Preset names are absent ---

    function test_launchConfigAbiContainsOnlyCurrentFields() public pure {
        bytes4 expected = bytes4(keccak256("validate((address,string,string,string,uint256,uint64,uint256,uint256))"));
        assertEq(LaunchSupport.validate.selector, expected, "only metadata, supply, dev buy, plan, and deadline");
    }

    function test_zeroCreatorIsRejected() public {
        LaunchConfig memory config = _base();
        config.creator = address(0);
        vm.expectRevert(LaunchConfigLib.ZeroCreator.selector);
        support.validate(config);
    }

    function test_zeroSupplyIsRejected() public {
        LaunchConfig memory config = _base();
        config.totalSupply = 0;
        vm.expectRevert(LaunchConfigLib.ZeroTotalSupply.selector);
        support.validate(config);
    }

    // --- Supply is a protocol constant, not a launch choice ---

    // --- Scenario (token-launch): Supply is the protocol constant ---

    /// @dev The full-range and wall tick bounds are constants derived from the graduation valuation the
    /// pinned supply produces, so any other supply would seed positions whose bounds do not match the
    /// price they were computed for.
    function test_supplyOtherThanThePinnedConstantIsRejected() public {
        LaunchConfig memory config = _base();
        config.totalSupply = Bounds.FIXED_TOTAL_SUPPLY / 100;
        vm.expectRevert(
            abi.encodeWithSelector(LaunchConfigLib.SupplyNotFixed.selector, Bounds.FIXED_TOTAL_SUPPLY / 100)
        );
        support.validate(config);

        config.totalSupply = Bounds.FIXED_TOTAL_SUPPLY * 2;
        vm.expectRevert(abi.encodeWithSelector(LaunchConfigLib.SupplyNotFixed.selector, Bounds.FIXED_TOTAL_SUPPLY * 2));
        support.validate(config);

        // And the pinned value itself passes every non-registry bound.
        config.totalSupply = Bounds.FIXED_TOTAL_SUPPLY;
        support.validate(config);
    }

    function test_emptyMetadataIsRejected() public {
        LaunchConfig memory config = _base();
        config.name = "";
        vm.expectRevert(LaunchConfigLib.EmptyTokenMetadata.selector);
        support.validate(config);

        config = _base();
        config.symbol = "";
        vm.expectRevert(LaunchConfigLib.EmptyTokenMetadata.selector);
        support.validate(config);
    }

    function test_publishedLaunchBoundsMatchTheSpecification() public pure {
        assertEq(Bounds.MAX_DEV_BUY_SHARE_WAD, 0.1e18, "dev buy cap");
        assertEq(WAD, 1e18, "payout denominator");
    }
}
