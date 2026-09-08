// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchSupport} from "../../src/LaunchSupport.sol";
import {LaunchConfigLib} from "../../src/libraries/LaunchConfigLib.sol";
import {Bounds, HarvestSplit, LaunchConfig, WAD} from "../../src/types/LaunchTypes.sol";

/// @notice Unit tests for tasks 15.2 and 18.4 — the launch validator after design Decision 16 shrank it
/// to the per-launch knob set, and the harvest-split bounds Decision 18 replaced.
///
/// @dev Table-driven against every remaining bound: rejection one step outside, acceptance exactly on
/// it. That pairing is the point — a validator that rejects the boundary is as wrong as one that admits
/// beyond it, and this is the only function whose behaviour is permanent for a pool's whole life
/// (design Decision 10).
///
/// What is *absent* matters as much as what is here. Band counts, spacings, widths, deploy windows,
/// supply splits, proceeds splits, fee schedules and anti-snipe windows all had bounds in this table
/// before the rework and now have no representation in the configuration at all — see
/// `ProtocolTemplate.t.sol` for the tests that assert that.
contract LaunchConfigLibTest is Test {
    LaunchSupport internal support;

    uint256 internal constant SUPPLY = 1_000_000_000 ether;
    address internal constant CREATOR = address(0xC0FFEE);

    function setUp() public {
        support = new LaunchSupport();
    }

    function _base() internal pure returns (LaunchConfig memory) {
        return Bounds.defaultConfig(CREATOR, "Milestone", "MILE", SUPPLY);
    }

    function _split(uint64 creatorWad, uint64 buybackWad, uint64 protocolWad, uint64 lpWad)
        internal
        pure
        returns (HarvestSplit memory)
    {
        return HarvestSplit({creatorWad: creatorWad, buybackWad: buybackWad, protocolWad: protocolWad, lpWad: lpWad});
    }

    // --- Scenario: Valid configuration at bound edges is accepted ---

    function test_theDefaultConfigurationIsValid() public view {
        support.validate(_base());
    }

    function test_configurationExactlyOnEveryBoundIsAccepted() public view {
        LaunchConfig memory config = _base();

        // Dev buy exactly at the 10% cap, vesting exactly at twelve months.
        config.devBuyShareWad = Bounds.MAX_DEV_BUY_SHARE_WAD;
        config.devBuyVestingSeconds = Bounds.MAX_DEV_BUY_VESTING_SECONDS;
        // Creator exactly at its 70% cap, buyback exactly at its 10% floor, protocol exactly at its 5%
        // floor. The LP share takes the remaining 15%.
        config.harvestSplit = _split(
            Bounds.MAX_CREATOR_HARVEST_SHARE_WAD,
            Bounds.MIN_BUYBACK_HARVEST_SHARE_WAD,
            Bounds.MIN_PROTOCOL_HARVEST_SHARE_WAD,
            uint64(
                WAD - Bounds.MAX_CREATOR_HARVEST_SHARE_WAD - Bounds.MIN_BUYBACK_HARVEST_SHARE_WAD
                    - Bounds.MIN_PROTOCOL_HARVEST_SHARE_WAD
            )
        );

        support.validate(config);
    }

    function test_buybackExactlyAtItsCeilingIsAccepted() public view {
        LaunchConfig memory config = _base();
        config.harvestSplit = _split(
            0.45e18,
            Bounds.MAX_BUYBACK_HARVEST_SHARE_WAD,
            Bounds.MIN_PROTOCOL_HARVEST_SHARE_WAD,
            uint64(WAD - 0.45e18 - Bounds.MAX_BUYBACK_HARVEST_SHARE_WAD - Bounds.MIN_PROTOCOL_HARVEST_SHARE_WAD)
        );

        support.validate(config);
    }

    /// @dev A zero LP share is legitimate: the LP still receives the harvest's integer-division dust and
    /// the unspent part of a partially-filled buyback, because {MilestoneHook-_routeHarvest} computes it
    /// as the remainder rather than from its own wad.
    function test_zeroLpShareIsAccepted() public view {
        LaunchConfig memory config = _base();
        config.harvestSplit = _split(0.7e18, 0.25e18, 0.05e18, 0);

        support.validate(config);
    }

    // --- Scenario: Creator share cap is enforced ---

    function test_creatorShareOneStepAboveTheCapIsRejected() public {
        LaunchConfig memory config = _base();
        config.harvestSplit = _split(
            Bounds.MAX_CREATOR_HARVEST_SHARE_WAD + 1,
            Bounds.MIN_BUYBACK_HARVEST_SHARE_WAD,
            Bounds.MIN_PROTOCOL_HARVEST_SHARE_WAD,
            uint64(
                WAD - Bounds.MAX_CREATOR_HARVEST_SHARE_WAD - 1 - Bounds.MIN_BUYBACK_HARVEST_SHARE_WAD
                    - Bounds.MIN_PROTOCOL_HARVEST_SHARE_WAD
            )
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                LaunchConfigLib.CreatorHarvestShareAboveCap.selector, Bounds.MAX_CREATOR_HARVEST_SHARE_WAD + 1
            )
        );
        support.validate(config);
    }

    function test_buybackShareOneStepBelowTheFloorIsRejected() public {
        LaunchConfig memory config = _base();
        config.harvestSplit = _split(
            0.6e18,
            Bounds.MIN_BUYBACK_HARVEST_SHARE_WAD - 1,
            Bounds.MIN_PROTOCOL_HARVEST_SHARE_WAD,
            uint64(WAD - 0.6e18 - (Bounds.MIN_BUYBACK_HARVEST_SHARE_WAD - 1) - Bounds.MIN_PROTOCOL_HARVEST_SHARE_WAD)
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                LaunchConfigLib.BuybackHarvestShareBelowFloor.selector, Bounds.MIN_BUYBACK_HARVEST_SHARE_WAD - 1
            )
        );
        support.validate(config);
    }

    /// @dev A zero buyback share is the degenerate case of the floor, and is rejected for the same
    /// reason: the buyback is how a completed milestone returns value to holders rather than only to the
    /// creator, so a launch cannot opt out of it.
    function test_zeroBuybackShareIsRejected() public {
        LaunchConfig memory config = _base();
        config.harvestSplit = _split(0.6e18, 0, 0.1e18, 0.3e18);

        vm.expectRevert(abi.encodeWithSelector(LaunchConfigLib.BuybackHarvestShareBelowFloor.selector, 0));
        support.validate(config);
    }

    function test_buybackShareOneStepAboveTheCeilingIsRejected() public {
        LaunchConfig memory config = _base();
        config.harvestSplit = _split(
            0.4e18,
            Bounds.MAX_BUYBACK_HARVEST_SHARE_WAD + 1,
            Bounds.MIN_PROTOCOL_HARVEST_SHARE_WAD,
            uint64(WAD - 0.4e18 - (Bounds.MAX_BUYBACK_HARVEST_SHARE_WAD + 1) - Bounds.MIN_PROTOCOL_HARVEST_SHARE_WAD)
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                LaunchConfigLib.BuybackHarvestShareAboveCap.selector, Bounds.MAX_BUYBACK_HARVEST_SHARE_WAD + 1
            )
        );
        support.validate(config);
    }

    function test_protocolShareOneStepBelowTheFloorIsRejected() public {
        LaunchConfig memory config = _base();
        config.harvestSplit = _split(
            0.6e18,
            0.2e18,
            Bounds.MIN_PROTOCOL_HARVEST_SHARE_WAD - 1,
            uint64(WAD - 0.6e18 - 0.2e18 - (Bounds.MIN_PROTOCOL_HARVEST_SHARE_WAD - 1))
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                LaunchConfigLib.ProtocolHarvestShareBelowFloor.selector, Bounds.MIN_PROTOCOL_HARVEST_SHARE_WAD - 1
            )
        );
        support.validate(config);
    }

    // --- Scenario: Harvest split that does not sum to one whole is rejected ---

    function test_harvestSplitOneWeiShortIsRejected() public {
        LaunchConfig memory config = _base();
        config.harvestSplit = _split(0.6e18, 0.2e18, 0.1e18, 0.1e18 - 1);

        vm.expectRevert(abi.encodeWithSelector(LaunchConfigLib.HarvestSplitMustSumToWad.selector, WAD - 1));
        support.validate(config);
    }

    function test_harvestSplitOneWeiOverIsRejected() public {
        LaunchConfig memory config = _base();
        config.harvestSplit = _split(0.6e18, 0.2e18, 0.1e18, 0.1e18 + 1);

        vm.expectRevert(abi.encodeWithSelector(LaunchConfigLib.HarvestSplitMustSumToWad.selector, WAD + 1));
        support.validate(config);
    }

    // --- Scenario: Dev buy is capped at 10% of supply ---

    function test_devBuyOneStepAboveTheCapIsRejected() public {
        LaunchConfig memory config = _base();
        config.devBuyShareWad = Bounds.MAX_DEV_BUY_SHARE_WAD + 1;

        vm.expectRevert(
            abi.encodeWithSelector(LaunchConfigLib.DevBuyAboveCap.selector, Bounds.MAX_DEV_BUY_SHARE_WAD + 1)
        );
        support.validate(config);
    }

    function test_devBuyVestingOneSecondTooLongIsRejected() public {
        LaunchConfig memory config = _base();
        config.devBuyVestingSeconds = Bounds.MAX_DEV_BUY_VESTING_SECONDS + 1;

        vm.expectRevert(
            abi.encodeWithSelector(
                LaunchConfigLib.DevBuyVestingTooLong.selector, Bounds.MAX_DEV_BUY_VESTING_SECONDS + 1
            )
        );
        support.validate(config);
    }

    // --- Token identity ---

    function test_zeroSupplyIsRejected() public {
        LaunchConfig memory config = _base();
        config.totalSupply = 0;

        vm.expectRevert(LaunchConfigLib.ZeroTotalSupply.selector);
        support.validate(config);
    }

    function test_emptyNameIsRejected() public {
        LaunchConfig memory config = _base();
        config.name = "";

        vm.expectRevert(LaunchConfigLib.EmptyTokenMetadata.selector);
        support.validate(config);
    }

    function test_emptySymbolIsRejected() public {
        LaunchConfig memory config = _base();
        config.symbol = "";

        vm.expectRevert(LaunchConfigLib.EmptyTokenMetadata.selector);
        support.validate(config);
    }

    // --- The bounds themselves ---

    /// @dev Pins the published numbers. These are the whole of the protocol's policy surface, so a change
    /// to any of them should be a deliberate edit here as well as in `Bounds`.
    function test_boundsMatchTheSpecification() public pure {
        assertEq(Bounds.MAX_DEV_BUY_SHARE_WAD, 0.1e18, "dev buy at most 10% of supply");
        assertEq(Bounds.MAX_DEV_BUY_VESTING_SECONDS, 365 days, "vesting at most twelve months");
        assertEq(Bounds.MAX_CREATOR_HARVEST_SHARE_WAD, 0.7e18, "creator share at most 70%");
        assertEq(Bounds.MIN_BUYBACK_HARVEST_SHARE_WAD, 0.1e18, "buyback share at least 10%");
        assertEq(Bounds.MIN_PROTOCOL_HARVEST_SHARE_WAD, 0.05e18, "protocol share at least 5%");
    }

    /// @dev Fuzz the whole split space: anything the validator admits must satisfy every bound and sum to
    /// exactly one whole, and anything it rejects must violate one. Written as a single implication in
    /// both directions so a bound that is checked but not enforced, or enforced but not checked, fails.
    function testFuzz_validatorAgreesWithTheBounds(uint64 creatorWad, uint64 buybackWad, uint64 protocolWad) public {
        creatorWad = uint64(bound(creatorWad, 0, WAD));
        buybackWad = uint64(bound(buybackWad, 0, WAD));
        protocolWad = uint64(bound(protocolWad, 0, WAD));
        uint256 sum = uint256(creatorWad) + buybackWad + protocolWad;
        vm.assume(sum <= WAD);

        LaunchConfig memory config = _base();
        config.harvestSplit = _split(creatorWad, buybackWad, protocolWad, uint64(WAD - sum));

        bool shouldPass = creatorWad <= Bounds.MAX_CREATOR_HARVEST_SHARE_WAD
            && buybackWad >= Bounds.MIN_BUYBACK_HARVEST_SHARE_WAD && buybackWad <= Bounds.MAX_BUYBACK_HARVEST_SHARE_WAD
            && protocolWad >= Bounds.MIN_PROTOCOL_HARVEST_SHARE_WAD;

        (bool ok,) = address(support).call(abi.encodeCall(LaunchSupport.validate, (config)));
        assertEq(ok, shouldPass, "validator and bounds agree");
    }
}
