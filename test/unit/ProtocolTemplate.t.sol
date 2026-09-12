// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {LaunchpadTest} from "../Fixtures.sol";
import {CurveLib} from "../../src/libraries/CurveLib.sol";
import {MilestoneHook} from "../../src/MilestoneHook.sol";
import {ProtocolController} from "../../src/ProtocolController.sol";
import {Bounds, LaunchConfig, PoolState, ProtocolTemplate} from "../../src/types/LaunchTypes.sol";
import {EconomicConfig} from "../../src/types/PayoutTypes.sol";

/// @notice Immutable launch geometry and governed non-trading economic bounds.
contract ProtocolTemplateTest is LaunchpadTest {
    function _impliedFdvWei(PoolId id, uint256 totalSupply) internal view returns (uint256) {
        uint160 sqrtPriceX96 = _sqrtPriceOf(id);
        uint256 half = FullMath.mulDiv(totalSupply, 1 << 96, sqrtPriceX96);
        return FullMath.mulDiv(half, 1 << 96, sqrtPriceX96);
    }

    // --- Scenario: Starting price matches anchored FDV ---

    function test_startingPriceMatchesAnchoredFdv() public view {
        assertApproxEqRel(_impliedFdvWei(poolId, SUPPLY), template.openingFdvWei, 0.0005e18);
        assertEq(CurveLib.openingLevel(SUPPLY, template.openingFdvWei), hook.poolState(poolId).openingLevel);
    }

    // --- Scenario: One template applies to all launches ---

    function test_templateMatchesEveryCurrentField() public view {
        ProtocolTemplate memory t = hook.template();
        assertEq(keccak256(abi.encode(t)), keccak256(abi.encode(template)), "published template");
        assertEq(hook.templateHash(), coldPaths.templateHash(), "cold path parity");
        assertEq(hook.templateHash(), payoutPaths.templateHash(), "payout path parity");
    }

    /// @dev Supply is pinned protocol-wide and the FDV anchors are template constants, so every launch
    /// shares one geometry: derived, no scenario of its own.
    function test_launchesShareOneProtocolGeometry() public {
        LaunchConfig memory other = _defaultConfig("Other", "OTH");
        (PoolId otherId,,) = _launchDirect(other);
        PoolState memory a = hook.poolState(poolId);
        PoolState memory b = hook.poolState(otherId);
        assertEq(a.farLevel - a.openingLevel, b.farLevel - b.openingLevel, "same curve span");
        assertEq(a.openingLevel, b.openingLevel, "pinned supply pins the anchored opening level");
        assertEq(a.farLevel, b.farLevel, "and the same far level");
    }

    // --- Scenario: Default global configuration is published ---

    function test_defaultGlobalConfigurationIsPublished() public view {
        EconomicConfig memory c = hook.economicConfig();
        assertEq(c.harvestServiceFeeWad, 0.1e18, "service fee");
        assertEq(c.quoteCreatorShareWad, 0.75e18, "creator quote share");
        assertEq(c.tokenMilestoneFundShareWad, 1e18, "token fund share");
        assertEq(c.version, 1, "version");
        assertEq(keccak256(abi.encode(c)), keccak256(abi.encode(controller.economicConfig())), "controller parity");
    }

    function _next(uint64 service, uint64 creatorShare, uint64 tokenFund)
        internal
        pure
        returns (EconomicConfig memory)
    {
        return EconomicConfig({
            harvestServiceFeeWad: service,
            quoteCreatorShareWad: creatorShare,
            tokenMilestoneFundShareWad: tokenFund,
            version: 2
        });
    }

    // --- Scenario: Service-fee cap is enforced ---

    function test_serviceFeeCapIsEnforced() public {
        EconomicConfig memory c = _next(uint64(Bounds.MAX_HARVEST_SERVICE_FEE_WAD + 1), 0.75e18, 0.2e18);
        vm.prank(PROTOCOL_ADMIN);
        vm.expectRevert(ProtocolController.InvalidEconomicConfig.selector);
        controller.scheduleEconomicConfig(c, bytes32("service"));
    }

    // --- Scenario: Quote creator cap is enforced ---

    function test_quoteCreatorCapIsEnforced() public {
        EconomicConfig memory c = _next(0.1e18, uint64(Bounds.MAX_QUOTE_CREATOR_SHARE_WAD + 1), 0.2e18);
        vm.prank(PROTOCOL_ADMIN);
        vm.expectRevert(ProtocolController.InvalidEconomicConfig.selector);
        controller.scheduleEconomicConfig(c, bytes32("creator"));
    }

    // --- Scenario: Token-fund cap is enforced ---

    function test_tokenFundCapIsEnforced() public {
        EconomicConfig memory c = _next(0.1e18, 0.75e18, uint64(Bounds.MAX_TOKEN_MILESTONE_FUND_SHARE_WAD + 1));
        vm.prank(PROTOCOL_ADMIN);
        vm.expectRevert(ProtocolController.InvalidEconomicConfig.selector);
        controller.scheduleEconomicConfig(c, bytes32("token"));
    }

    // --- Scenario: Exact cap values are accepted ---

    function test_exactCapValuesAreAccepted() public {
        EconomicConfig memory c = _next(
            Bounds.MAX_HARVEST_SERVICE_FEE_WAD,
            Bounds.MAX_QUOTE_CREATOR_SHARE_WAD,
            Bounds.MAX_TOKEN_MILESTONE_FUND_SHARE_WAD
        );
        bytes32 salt = bytes32("caps");
        vm.prank(PROTOCOL_ADMIN);
        controller.scheduleEconomicConfig(c, salt);
        controller.executeEconomicConfig(c, salt);
        assertEq(keccak256(abi.encode(hook.economicConfig())), keccak256(abi.encode(c)), "caps active");
    }

    // --- Scenario: Trading fee remains immutable ---

    function test_tradingFeeRemainsImmutable() public view {
        assertEq(template.tradingFeeHundredthsBip, Bounds.TRADING_FEE_HUNDREDTHS_BIP);
        assertEq(key.fee, Bounds.TRADING_FEE_HUNDREDTHS_BIP);
        assertEq(_baseFeeOf(poolId), Bounds.TRADING_FEE_HUNDREDTHS_BIP);
    }

    // --- Scenario: Geometry is not configurable ---
    // --- Scenario: Harvest percentages are not configurable ---

    function test_launchConfigHasNoGeometryOrPercentageFields() public pure {
        bytes4 expected =
            bytes4(keccak256("launch((address,string,string,string,uint256,uint64,uint256,uint256),bytes)"));
        assertEq(MilestoneHook.launch.selector, expected, "current LaunchConfig is the public ABI");
    }

    function test_noTemplateSetterExists() public {
        string[4] memory sigs =
            ["setTemplate(bytes)", "setGeometry(bytes)", "setTradingFee(uint24)", "setHarvestSplit(bytes)"];
        for (uint256 i = 0; i < sigs.length; i++) {
            (bool ok,) = address(hook).call(abi.encodeWithSignature(sigs[i]));
            assertFalse(ok, sigs[i]);
        }
    }
}
