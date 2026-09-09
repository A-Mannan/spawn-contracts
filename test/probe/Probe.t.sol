// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LaunchpadTest} from "../Fixtures.sol";
import {PoolState} from "../../src/types/LaunchTypes.sol";

contract ProbeTest is LaunchpadTest {
    function test_probeGraduateAndLadder() public {
        int24 far = hook.poolState(poolId).farLevel;
        uint256 ethBefore = address(router).balance;
        _buyToLevel(2_000 ether, far);
        emit log_named_uint("eth spent to graduate", ethBefore - address(router).balance);
        emit log_named_int("level after crossing", _level());

        _buy(1_000);
        emit log_named_uint("phase", uint256(hook.poolPhase(poolId)));
        PoolState memory s = hook.poolState(poolId);
        emit log_named_int("graduationLevel", s.graduationLevel);
        emit log_named_uint("fullRangeLiquidity", s.fullRangeLiquidity);
        emit log_named_uint("creatorClaimable", hook.creatorClaimable(poolId));
        emit log_named_uint("protocolClaimable", hook.protocolClaimable());
        emit log_named_uint("payoutPot", hook.payoutPot(poolId));
        emit log_named_uint("creatorPathClaimable", hook.creatorPathClaimable(poolId));
        emit log_named_uint("carriedInventory", s.carriedInventory);
        emit log_named_uint("ladderRemaining", s.ladderInventoryRemaining);
        emit log_named_uint("hookEth", HOOK_ADDR.balance);

        (int24 b0l, int24 b0u,) = hook.bandLevels(poolId, 0);
        emit log_named_int("band0 lower", b0l);
        emit log_named_int("band0 upper", b0u);

        // Now buy into band 0.
        _buyToLevel(500 ether, b0u);
        emit log_named_uint("bands deployed", _deployedBandCount());
        emit log_named_int("level", _level());
        emit log_named_uint("band0 liq", _bandLiquidity(0));
        emit log_named_uint("completed", hook.poolState(poolId).completedMilestones);

        // Push past band 0's top.
        (int24 b3l,,) = hook.bandLevels(poolId, 3);
        _buyToLevel(5_000 ether, b3l);
        emit log_named_int("level2", _level());
        emit log_named_uint("bands deployed2", _deployedBandCount());
        emit log_named_uint("completed2", hook.poolState(poolId).completedMilestones);
        emit log_named_uint("creatorClaimable2", hook.creatorClaimable(poolId));
    }
}
