// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {LaunchpadTest} from "../Fixtures.sol";
import {Bounds, LaunchConfig} from "../../src/types/LaunchTypes.sol";
import {EconomicConfig} from "../../src/types/PayoutTypes.sol";

/// @notice The immutable static trading fee across time, lifecycle, and governed economics.
contract StaticFeeTest is LaunchpadTest {
    function _assertStaticFee(PoolId id, PoolKey memory k) internal view {
        assertEq(k.fee, Bounds.TRADING_FEE_HUNDREDTHS_BIP, "key fee is one percent");
        assertEq(_baseFeeOf(id), Bounds.TRADING_FEE_HUNDREDTHS_BIP, "slot fee is one percent");
        assertFalse(LPFeeLibrary.isDynamicFee(k.fee), "no dynamic flag");
    }

    // --- Scenario: One percent applies from genesis forever ---

    function test_onePercentAppliesFromGenesisForever() public {
        _assertStaticFee(poolId, key);
        _buyToLevel(10 ether, _level() + 50);
        _assertStaticFee(poolId, key);
        _graduate();
        _assertStaticFee(poolId, key);
    }

    // --- Scenario: Time does not affect the fee ---

    function test_timeDoesNotAffectTheFee() public {
        uint24 before = _baseFeeOf(poolId);
        // `years` was removed as a unit denomination; 36,500 days is the same century.
        vm.warp(launchTime + 36_500 days);
        _buyToLevel(10 ether, _level() + 50);
        assertEq(_baseFeeOf(poolId), before, "elapsed time cannot mutate fee");
        _assertStaticFee(poolId, key);
    }

    // --- Scenario: Milestones do not affect the fee ---

    function test_milestonesDoNotAffectTheFee() public {
        _graduate();
        _buyToLevel(5_000 ether, _bandUpper(2) + 50);
        assertGt(hook.poolState(poolId).completedMilestones, 0, "milestones completed");
        _assertStaticFee(poolId, key);
    }

    // --- Scenario: Governance cannot change the trading fee ---

    function test_governanceCannotChangeTheTradingFee() public {
        EconomicConfig memory config = EconomicConfig({
            harvestServiceFeeWad: 0.2e18,
            quoteCreatorShareWad: 0.9e18,
            tokenMilestoneFundShareWad: 0.5e18,
            version: 2
        });
        bytes32 salt = keccak256("static-fee");

        vm.prank(PROTOCOL_ADMIN);
        controller.scheduleEconomicConfig(config, salt);
        controller.executeEconomicConfig(config, salt);

        assertEq(hook.economicConfig().version, 2, "economic update executed");
        _assertStaticFee(poolId, key);
    }

    // --- Scenario: Pool has no dynamic fee state ---

    function test_poolHasNoDynamicFeeState() public {
        _assertStaticFee(poolId, key);
        (bool setter,) =
            address(hook).call(abi.encodeWithSignature("setBaseFee(bytes32,uint24)", PoolId.unwrap(poolId), 1));
        (bool updater,) =
            address(hook).call(abi.encodeWithSignature("updateDynamicLPFee(bytes32,uint24)", PoolId.unwrap(poolId), 1));
        assertFalse(setter, "no mutable fee setter");
        assertFalse(updater, "no dynamic fee update surface");
    }
}
