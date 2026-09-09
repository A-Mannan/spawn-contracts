// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

import {Deployment, DeployParams, LaunchpadDeploy} from "./LaunchpadDeploy.sol";
import {Bounds, ProtocolTemplate} from "../src/types/LaunchTypes.sol";

/// @title Deploy
/// @notice The design's Migration Plan end to end: revenue NFT and launch helper, the satellite, the
/// mined hook, then the wiring — with every verification the plan calls for run before the wiring.
///
/// @dev The template comes from {Bounds.defaultTemplate} rather than from the environment. It is the one
/// place the published numbers are written down, and a deployment that used anything else would be a
/// protocol whose economics no front-end could quote from the source.
///
/// ```
/// POOL_MANAGER=0x… PROTOCOL_ADMIN=0x… PROTOCOL_RECIPIENT=0x… \
/// forge script script/Deploy.s.sol --rpc-url "$BASE_RPC_URL" --broadcast
/// ```
///
/// Steps 1 and 2 are nonce-derived, so the salt this run mines is valid only for the satellite this run
/// deployed. A run that fails part way through must be restarted from step 1, not resumed with the salt it
/// printed — which is why mining happens inside {LaunchpadDeploy.deployAll} and not here. The configured
/// protocol multisig completes the final two-step handoff by calling `ProtocolController.acceptAdministrator`
/// directly; routing that call through this script contract would change `msg.sender` and fail acceptance.
contract Deploy is Script {
    function run() external returns (Deployment memory d) {
        address bootstrapAdministrator = vm.envAddress("BOOTSTRAP_ADMINISTRATOR");
        DeployParams memory p = DeployParams({
            poolManager: IPoolManager(vm.envAddress("POOL_MANAGER")),
            create2Deployer: vm.envOr("CREATE2_DEPLOYER", CREATE2_FACTORY),
            selfIssuesCreate2: false,
            bootstrapAdministrator: bootstrapAdministrator,
            protocolAdmin: vm.envAddress("PROTOCOL_ADMIN"),
            protocolRecipient: vm.envAddress("PROTOCOL_RECIPIENT")
        });

        vm.startBroadcast(bootstrapAdministrator);
        d = deploy(p, Bounds.defaultTemplate());
        vm.stopBroadcast();

        console2.log("revenue nft       ", address(d.nft));
        console2.log("plugin registry   ", address(d.registry));
        console2.log("protocol controller", address(d.controller));
        console2.log("launch support    ", address(d.support));
        console2.log("cold paths        ", address(d.coldPaths));
        console2.log("payout paths      ", address(d.payoutPaths));
        console2.log("hook              ", address(d.hook));
        console2.log("buyback plugin    ", address(d.buyback));
        console2.log("swap/flush helper ", address(d.helper));
        console2.log("buyback index     ", uint256(d.buybackIndex));
        console2.log("canonical plan    ", d.canonicalPayoutPlan);
        console2.log("hook salt         ", uint256(d.hookSalt));
        console2.log("bootstrap admin   ", d.controller.administrator());
        console2.log("pending admin     ", d.controller.pendingAdministrator());
        console2.log("protocol recipient", d.hook.protocolRecipient());
    }

    /// @notice The deployment itself, with its inputs given rather than read from the environment.
    ///
    /// @dev Public so the dry-run test drives *this contract*, making the CREATE2 deployer this script's
    /// own address — the same relationship the broadcast has with the deterministic-deployment proxy.
    function deploy(DeployParams memory p, ProtocolTemplate memory template) public returns (Deployment memory) {
        // Returned directly rather than through a named return: a named one allocates a second zeroed
        // `Deployment` beside the library's own, and the pair of live pointers is what pushes this frame
        // past `via_ir`'s reachable stack window.
        return LaunchpadDeploy.deployAll(p, template);
    }
}
