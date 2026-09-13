// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

import {Deployment, DeployParams, LaunchpadDeploy} from "./LaunchpadDeploy.sol";
import {Bounds, ProtocolTemplate} from "../src/types/LaunchTypes.sol";
import {EconomicConfig} from "../src/types/PayoutTypes.sol";

/// @title Deploy
/// @notice The design's Migration Plan end to end: revenue NFT and launch helper, the satellite, the
/// mined hook, then the wiring — with every verification the plan calls for run before the wiring.
///
/// @dev The template comes from {Bounds.defaultTemplate} rather than from the environment. It is the one
/// place the published numbers are written down, and a deployment that used anything else would be a
/// protocol whose economics no front-end could quote from the source.
///
/// ```
/// POOL_MANAGER=0x… PROTOCOL_ADMIN=0x… PROTOCOL_RECIPIENT=0x… TRUSTED_OPERATOR=0x… \
/// forge script script/Deploy.s.sol --rpc-url "$BASE_RPC_URL" --broadcast
/// ```
///
/// Steps 1 and 2 are nonce-derived, so the salt this run mines is valid only for the satellite this run
/// deployed. A run that fails part way through must be restarted from step 1, not resumed with the salt it
/// printed — which is why mining happens inside {LaunchpadDeploy.deployAll} and not here. The configured
/// protocol multisig completes the final two-step handoff by calling `ProtocolController.acceptAdministrator`
/// directly; routing that call through this script contract would change `msg.sender` and fail acceptance.
///
/// A completed run writes `deployments/<chainId>.json` — the machine-readable manifest the frontend and
/// data layer consume (see docs/technical/integration.md). Only `run` writes it; the dry-run test drives {deploy}
/// directly precisely so a rehearsal leaves no artifacts behind. Values larger than a JavaScript-safe
/// integer (every WAD-denominated field among them) are serialized as decimal strings, never as numbers.
contract Deploy is Script {
    function run() external returns (Deployment memory d) {
        address bootstrapAdministrator = vm.envAddress("BOOTSTRAP_ADMINISTRATOR");
        DeployParams memory p = DeployParams({
            poolManager: IPoolManager(vm.envAddress("POOL_MANAGER")),
            create2Deployer: vm.envOr("CREATE2_DEPLOYER", CREATE2_FACTORY),
            selfIssuesCreate2: false,
            bootstrapAdministrator: bootstrapAdministrator,
            protocolAdmin: vm.envAddress("PROTOCOL_ADMIN"),
            protocolRecipient: vm.envAddress("PROTOCOL_RECIPIENT"),
            trustedOperator: vm.envOr("TRUSTED_OPERATOR", address(0))
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
        console2.log("buyback index     ", uint256(d.buybackIndex));
        console2.log("canonical plan    ", d.canonicalPayoutPlan);
        console2.log("hook salt         ", uint256(d.hookSalt));
        console2.log("bootstrap admin   ", d.controller.administrator());
        console2.log("pending admin     ", d.controller.pendingAdministrator());
        console2.log("protocol recipient", d.hook.protocolRecipient());
        console2.log("trusted operator  ", d.hook.trustedOperator());

        _writeManifest(d, p);
    }

    /// @notice Writes `deployments/<chainId>.json`: every address the run produced, the mined salt, the
    /// canonical payout plan, and the template plus economics snapshot the deployment actually ran with.
    ///
    /// @dev This is the handoff artifact for the frontend and the data layer — docs/technical/integration.md is its
    /// reader's guide. It is written after the logs and outside the broadcast window, so it never
    /// appears in the transaction list and never runs for the {deploy} rehearsal.
    ///
    /// WAD-denominated fields exceed JavaScript's `Number.MAX_SAFE_INTEGER`, so every one of them is
    /// serialized as a decimal string; consumers must parse them as bigint. The counts (positions, band
    /// counts, caps, fee in hundredths of a bip, version, chain id) stay numbers.
    function _writeManifest(Deployment memory d, DeployParams memory p) private {
        ProtocolTemplate memory t = d.hook.template();
        EconomicConfig memory e = d.hook.economicConfig();

        string memory json = "deployment";
        vm.serializeUint(json, "chainId", block.chainid);
        vm.serializeUint(json, "deployedAt", block.timestamp);
        vm.serializeAddress(json, "poolManager", address(p.poolManager));
        vm.serializeAddress(json, "bootstrapAdministrator", p.bootstrapAdministrator);
        vm.serializeAddress(json, "protocolAdmin", p.protocolAdmin);
        vm.serializeAddress(json, "protocolRecipient", p.protocolRecipient);
        vm.serializeAddress(json, "trustedOperator", p.trustedOperator);
        vm.serializeAddress(json, "hook", address(d.hook));
        vm.serializeAddress(json, "coldPaths", address(d.coldPaths));
        vm.serializeAddress(json, "payoutPaths", address(d.payoutPaths));
        vm.serializeAddress(json, "launchSupport", address(d.support));
        vm.serializeAddress(json, "revenueNft", address(d.nft));
        vm.serializeAddress(json, "payoutPluginRegistry", address(d.registry));
        vm.serializeAddress(json, "protocolController", address(d.controller));
        vm.serializeAddress(json, "buybackPlugin", address(d.buyback));
        vm.serializeUint(json, "buybackIndex", uint256(d.buybackIndex));
        vm.serializeBytes32(json, "canonicalPayoutPlan", bytes32(d.canonicalPayoutPlan));
        vm.serializeBytes32(json, "hookSalt", d.hookSalt);

        string memory template = "template";
        vm.serializeString(template, "openingFdvWei", vm.toString(t.openingFdvWei));
        vm.serializeUint(template, "curvePositions", uint256(t.curvePositions));
        vm.serializeInt(template, "curveSpanLevels", int256(t.curveSpanLevels));
        vm.serializeInt(template, "bandLevelSpacing", int256(t.bandLevelSpacing));
        vm.serializeInt(template, "bandWidthLevels", int256(t.bandWidthLevels));
        vm.serializeUint(template, "coreBandCount", uint256(t.coreBandCount));
        vm.serializeUint(template, "maxFeeFundedBands", uint256(t.maxFeeFundedBands));
        vm.serializeString(template, "curveSupplyShareWad", vm.toString(t.curveSupplyShareWad));
        vm.serializeString(template, "ladderSupplyShareWad", vm.toString(t.ladderSupplyShareWad));
        vm.serializeString(template, "fullRangeSupplyShareWad", vm.toString(t.fullRangeSupplyShareWad));
        vm.serializeString(template, "lpSeedWad", vm.toString(t.lpSeedWad));
        vm.serializeString(template, "proceedsCreatorWad", vm.toString(t.proceedsCreatorWad));
        vm.serializeString(template, "proceedsProtocolWad", vm.toString(t.proceedsProtocolWad));
        vm.serializeUint(template, "tradingFeeHundredthsBip", uint256(t.tradingFeeHundredthsBip));
        vm.serializeUint(template, "bandInventoryCapMultiple", uint256(t.bandInventoryCapMultiple));
        vm.serializeUint(template, "maxDeploysPerSwap", uint256(t.maxDeploysPerSwap));
        string memory templateJson = vm.serializeUint(template, "maxHarvestsPerSwap", uint256(t.maxHarvestsPerSwap));
        vm.serializeString(json, "template", templateJson);

        string memory economics = "economicConfig";
        vm.serializeString(economics, "harvestServiceFeeWad", vm.toString(e.harvestServiceFeeWad));
        vm.serializeString(economics, "quoteCreatorShareWad", vm.toString(e.quoteCreatorShareWad));
        vm.serializeString(economics, "tokenMilestoneFundShareWad", vm.toString(e.tokenMilestoneFundShareWad));
        string memory economicsJson = vm.serializeUint(economics, "version", uint256(e.version));
        string memory out = vm.serializeString(json, "economicConfig", economicsJson);

        string memory dir = string.concat(vm.projectRoot(), "/deployments");
        vm.createDir(dir, true);
        vm.writeJson(out, string.concat(dir, "/", vm.toString(block.chainid), ".json"));
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
