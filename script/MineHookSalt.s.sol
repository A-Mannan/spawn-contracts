// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";

import {Deployment, DeployParams, LaunchpadDeploy} from "./LaunchpadDeploy.sol";
import {LaunchSupport} from "../src/LaunchSupport.sol";
import {MilestoneColdPaths} from "../src/MilestoneColdPaths.sol";
import {MilestonePayoutPaths} from "../src/MilestonePayoutPaths.sol";
import {PayoutPluginRegistry} from "../src/PayoutPluginRegistry.sol";
import {ProtocolController} from "../src/ProtocolController.sol";
import {RevenueNFT} from "../src/RevenueNFT.sol";
import {Bounds, ProtocolTemplate} from "../src/types/LaunchTypes.sol";

/// @title MineHookSalt
/// @notice Migration Plan step 3, on its own: given an already-deployed satellite, find the `CREATE2`
/// salt that places the hook at an address encoding exactly the six permission flags.
///
/// @dev Separate from {Deploy} because the Migration Plan allows the steps to be run as separate
/// transactions — deploy the NFT, helper and satellite, confirm them on the explorer, then mine. Mining is
/// pure computation and broadcasts nothing, so this script is safe to run repeatedly; what it must not do
/// is outlive the satellite it mined against, since the satellite's address is hashed into the salt.
///
/// ```
/// POOL_MANAGER=0x… REVENUE_NFT=0x… LAUNCH_SUPPORT=0x… COLD_PATHS=0x… \
/// PROTOCOL_ADMIN=0x… PROTOCOL_RECIPIENT=0x… forge script script/MineHookSalt.s.sol
/// ```
contract MineHookSalt is Script {
    function run() external view returns (address hook, bytes32 salt) {
        DeployParams memory p = DeployParams({
            poolManager: IPoolManager(vm.envAddress("POOL_MANAGER")),
            create2Deployer: vm.envOr("CREATE2_DEPLOYER", CREATE2_FACTORY),
            selfIssuesCreate2: false,
            bootstrapAdministrator: vm.envAddress("BOOTSTRAP_ADMINISTRATOR"),
            protocolAdmin: vm.envAddress("PROTOCOL_ADMIN"),
            protocolRecipient: vm.envAddress("PROTOCOL_RECIPIENT"),
            trustedOperator: vm.envAddress("TRUSTED_OPERATOR")
        });

        Deployment memory d;
        d.nft = RevenueNFT(vm.envAddress("REVENUE_NFT"));
        d.registry = PayoutPluginRegistry(vm.envAddress("PAYOUT_PLUGIN_REGISTRY"));
        d.controller = ProtocolController(vm.envAddress("PROTOCOL_CONTROLLER"));
        d.support = LaunchSupport(vm.envAddress("LAUNCH_SUPPORT"));
        d.coldPaths = MilestoneColdPaths(vm.envAddress("COLD_PATHS"));
        d.payoutPaths = MilestonePayoutPaths(vm.envAddress("PAYOUT_PATHS"));

        (hook, salt) = mine(d, p, Bounds.defaultTemplate());
    }

    /// @notice The mining itself, with its inputs given rather than read from the environment.
    ///
    /// @dev Public so the dry-run test can assert against *this contract's* output rather than against a
    /// second call to the library, which is what makes the test a check on the script.
    function mine(Deployment memory d, DeployParams memory p, ProtocolTemplate memory template)
        public
        view
        returns (address hook, bytes32 salt)
    {
        (hook, salt) = LaunchpadDeploy.mineHookSalt(d, p, template);

        console2.log("create2 deployer  ", p.create2Deployer);
        console2.log("cold paths        ", address(d.coldPaths));
        console2.log("payout paths      ", address(d.payoutPaths));
        console2.log("hook address      ", hook);
        console2.log("hook salt         ", uint256(salt));
        console2.log("encoded flags     ", uint256(uint160(hook) & Hooks.ALL_HOOK_MASK));
        console2.log("required flags    ", uint256(LaunchpadDeploy.REQUIRED_FLAGS));
    }
}
