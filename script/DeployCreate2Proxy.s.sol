// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

/// @notice Deploys the Arachnid deterministic CREATE2 proxy (as a plain CREATE
/// from the broadcast account; its concrete address is then passed to the
/// launchpad deployer via CREATE2_DEPLOYER).
contract DeployCreate2Proxy is Script {
    bytes constant PROXY_RUNTIME = hex"6020360360205f375f35602036035f34f58015601d575f526014600cf35b5f80fd";

    function run() external {
        address deployer = vm.envAddress("DEPLOYER");
        vm.startBroadcast(deployer);
        bytes memory init = hex"602180600a5f395ff3fe";
        init = abi.encodePacked(init, PROXY_RUNTIME);
        address proxy;
        assembly {
            proxy := create(0, add(init, 0x20), mload(init))
        }
        require(proxy != address(0), "proxy create failed");
        require(proxy.code.length == PROXY_RUNTIME.length, "proxy code mismatch");
        vm.stopBroadcast();
        console2.log("create2 proxy", proxy);
    }
}
