// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "v4-core/src/types/Currency.sol";

/// @notice Local dev deployment: v4 PoolManager first (the launchpad Deploy.s
/// expects one at POOL_MANAGER), funded native-drip not needed for singleton.
contract DeployPoolManager is Script {
    function run() external returns (IPoolManager pm) {
        address owner = vm.envAddress("OWNER");
        vm.startBroadcast(owner);
        pm = new PoolManager(owner);
        vm.stopBroadcast();
        console2.log("pool manager", address(pm));
    }
}
