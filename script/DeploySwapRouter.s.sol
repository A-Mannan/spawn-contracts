// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {SpawnSwapRouter} from "../src/SpawnSwapRouter.sol";

/// @notice Deploys the minimal exact-input swap router against an existing
/// PoolManager. The address is recorded in deployments/<chainId>.json as
/// `swapRouter` and consumed by the frontend swap ticket.
contract DeploySwapRouter is Script {
    function run() external {
        address pm = vm.envAddress("POOL_MANAGER");
        uint256 key = vm.envUint("DEPLOYER_KEY");
        vm.startBroadcast(key);
        SpawnSwapRouter router = new SpawnSwapRouter(IPoolManager(pm));
        vm.stopBroadcast();
        console2.log("swap router       ", address(router));
    }
}
