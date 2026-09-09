// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {MilestoneBase} from "../../src/MilestoneBase.sol";
import {MilestoneToken} from "../../src/MilestoneToken.sol";
import {Bounds, LaunchConfig} from "../../src/types/LaunchTypes.sol";
import {LaunchpadTest} from "../Fixtures.sol";

/// @notice Immediate creator dev-buy behavior with no vesting state or release phase.
contract DevBuyTest is LaunchpadTest {
    uint256 private nonce;

    function _config(uint64 devBuyShareWad) internal returns (LaunchConfig memory config) {
        nonce += 1;
        config = Bounds.defaultConfig(creator, string.concat("Milestone ", vm.toString(nonce)), "MILE", SUPPLY);
        config.devBuyShareWad = devBuyShareWad;
    }

    function _launch(uint64 devBuyShareWad, uint256 value) internal returns (PoolId id, MilestoneToken t) {
        vm.prank(creator);
        (PoolId poolId_, address tokenAddr,) = hook.launch{value: value}(_config(devBuyShareWad), "");
        return (poolId_, MilestoneToken(tokenAddr));
    }

    function _curveTokenSettled(Vm.Log[] memory logs) internal pure returns (uint256 total) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] != MilestoneBase.CurvePositionsDeployed.selector) continue;
            (,, uint256 tokenSettled) = abi.decode(logs[i].data, (uint256, uint32, uint256));
            total += tokenSettled;
        }
    }

    // --- Scenario: No dev buy is the default ---

    function test_noDevBuyIsTheDefault() public {
        (PoolId id, MilestoneToken t) = _launch(0, 0);

        assertEq(t.balanceOf(creator), 0, "creator bought no token");
        assertEq(hook.poolState(id).curveDeployed, 1, "only genesis curve inventory deployed");
    }

    function test_ethWithoutADevBuyIsRejected() public {
        LaunchConfig memory config = _config(0);
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(MilestoneBase.DevBuyEthWithoutDevBuy.selector, 1 ether));
        hook.launch{value: 1 ether}(config, "");
    }

    // --- Scenario: Dev buy consumes curve inventory ---

    function test_devBuyConsumesCurveInventory() public {
        vm.recordLogs();
        (PoolId id, MilestoneToken t) = _launch(0.1e18, 50_000 ether);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256 purchased = SUPPLY / 10;
        uint256 settled = _curveTokenSettled(logs);
        assertEq(t.balanceOf(creator), purchased, "configured share bought");
        assertGt(settled, purchased, "curve deployed enough inventory");
        assertEq(t.balanceOf(address(manager)), settled - purchased, "purchase came from curve inventory");
    }

    function test_devBuyMovesPriceAndSpendsRealEth() public {
        (PoolId withoutDev,) = _launch(0, 0);
        uint256 before = creator.balance;
        (PoolId withDev,) = _launch(0.05e18, 50_000 ether);

        assertGt(_levelOf(withDev), _levelOf(withoutDev), "ordinary buy moved price");
        assertLt(creator.balance, before, "creator paid quote");
    }

    function test_unspentEthIsRefunded() public {
        uint256 before = creator.balance;
        (, MilestoneToken t) = _launch(0.01e18, 90_000 ether);
        uint256 spent = before - creator.balance;

        assertGt(spent, 0, "some quote spent");
        assertLt(spent, 90_000 ether, "unused budget refunded");
        assertEq(t.balanceOf(creator), SUPPLY / 100, "exact output delivered");
    }

    function test_insufficientEthRevertsTheWholeLaunch() public {
        LaunchConfig memory config = _config(0.1e18);
        vm.prank(creator);
        vm.expectRevert();
        hook.launch{value: 1 wei}(config, "");
    }

    // --- Scenario: Dev buy is capped at ten percent ---

    function test_devBuyAboveCapIsRejectedAtLaunch() public {
        LaunchConfig memory config = _config(uint64(Bounds.MAX_DEV_BUY_SHARE_WAD + 1));
        vm.prank(creator);
        vm.expectRevert();
        hook.launch{value: 90_000 ether}(config, "");
    }

    // --- Scenario: Dev buy requires creator transaction ---

    function test_relayedLaunchSkipsDevBuyAndLeavesInventory() public {
        LaunchConfig memory config = _config(0.05e18);
        vm.recordLogs();
        (PoolId id,, MilestoneToken t) = _launchRelayed(config, RELAYER);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(_countLogs(logs, MilestoneBase.DevBuySkipped.selector), 1, "skip announced");
        assertEq(_countLogs(logs, MilestoneBase.DevBuyExecuted.selector), 0, "no buy executed");
        assertEq(t.balanceOf(creator), 0, "creator received no relayed purchase");
        assertEq(hook.poolState(id).curveDeployed, 1, "share remains future curve inventory");
    }

    // --- Scenario: Dev buy is observable ---

    function test_devBuyIsObservable() public {
        uint256 before = creator.balance;
        vm.recordLogs();
        (PoolId id, MilestoneToken t) = _launch(0.05e18, 90_000 ether);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256 at = _firstLogAt(logs, MilestoneBase.DevBuyExecuted.selector);
        assertTrue(at != type(uint256).max, "event emitted");
        (uint256 tokensBought, uint256 ethSpent) = abi.decode(logs[at].data, (uint256, uint256));
        assertEq(logs[at].topics[1], PoolId.unwrap(id), "pool identified");
        assertEq(tokensBought, SUPPLY / 20, "tokens recorded");
        assertEq(ethSpent, before - creator.balance, "quote recorded");
        assertEq(t.balanceOf(creator), tokensBought, "recipient proven by resulting balance");
    }

    // --- Scenario: Tokens are delivered fully at launch ---

    function test_tokensAreDeliveredFullyBeforeLaunchReturns() public {
        (, MilestoneToken t) = _launch(0.1e18, 90_000 ether);
        assertEq(t.balanceOf(creator), SUPPLY / 10, "complete purchase already held");
    }

    // --- Scenario: No vesting state is created ---

    function test_noVestingStateOrReleaseSurfaceExists() public {
        (, MilestoneToken t) = _launch(0.05e18, 90_000 ether);
        assertEq(t.balanceOf(creator), SUPPLY / 20, "nothing retained for release");

        (bool releasable,) = address(hook).staticcall(abi.encodeWithSignature("releasableDevBuy(bytes32)", bytes32(0)));
        (bool release,) = address(hook).call(abi.encodeWithSignature("releaseDevBuy(bytes32)", bytes32(0)));
        assertFalse(releasable, "no releasable view");
        assertFalse(release, "no release action");
    }
}
