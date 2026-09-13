// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";

import {BuybackAndBurnPlugin} from "../src/BuybackAndBurnPlugin.sol";
import {LaunchSupport} from "../src/LaunchSupport.sol";
import {MilestoneColdPaths} from "../src/MilestoneColdPaths.sol";
import {MilestoneHook} from "../src/MilestoneHook.sol";
import {MilestonePayoutPaths} from "../src/MilestonePayoutPaths.sol";
import {PayoutPluginRegistry} from "../src/PayoutPluginRegistry.sol";
import {ProtocolController} from "../src/ProtocolController.sol";
import {RevenueNFT} from "../src/RevenueNFT.sol";
import {Bounds, ProtocolTemplate} from "../src/types/LaunchTypes.sol";
import {EconomicConfig, PAYOUT_WAD, PluginEntry, PluginRole} from "../src/types/PayoutTypes.sol";

/// @notice Every address one complete protocol deployment produces, plus the salt that placed the hook.
struct Deployment {
    RevenueNFT nft;
    PayoutPluginRegistry registry;
    ProtocolController controller;
    LaunchSupport support;
    MilestoneColdPaths coldPaths;
    MilestonePayoutPaths payoutPaths;
    MilestoneHook hook;
    BuybackAndBurnPlugin buyback;
    uint8 buybackIndex;
    uint256 canonicalPayoutPlan;
    bytes32 hookSalt;
}

/// @notice The environment-specific inputs to a deployment: everything that is not the template.
///
/// @dev `create2Deployer` is a parameter rather than a constant because the address the hook lands at
/// depends on who issues the `CREATE2`, and that differs between the two ways this library is run.
/// {HookMiner} documents the split: under `forge test` the deployer is the calling contract, under
/// `forge script` it is the deterministic-deployment proxy the broadcast wallet calls. A salt mined for
/// one is worthless for the other, so the same value must reach both the miner and the deployment.
///
/// `selfIssuesCreate2` says which of those two the caller is, and it is a declaration rather than
/// something this library infers. Inferring it would mean comparing `create2Deployer` against
/// `address(this)`, and `forge script` refuses to execute `ADDRESS` inside a broadcasting script contract
/// at all — ephemeral script addresses are exactly what must not be relied on. Declaring it costs a field
/// that could disagree with `create2Deployer`, but that disagreement cannot survive: the hook would land
/// somewhere other than the mined address, which {LaunchpadDeploy.deployAll} already asserts against.
struct DeployParams {
    IPoolManager poolManager;
    address create2Deployer;
    bool selfIssuesCreate2;
    address bootstrapAdministrator;
    address protocolAdmin;
    address protocolRecipient;
    address trustedOperator;
}

/// @notice The two read-only inputs to a deployment, bundled behind one memory pointer.
///
/// @dev Purely a `via_ir` accommodation, and a load-bearing one. The deployment chain is a sequence of
/// small private steps that the IR optimiser inlines into a single frame, and each step that took the
/// parameters and the template separately kept two live pointers there on top of the {Deployment} being
/// filled in. Three simultaneous pointers put that frame one slot past the sixteen the Yul stack can
/// reach; two do not. Nothing outside this library sees this type, and no public signature changed —
/// splitting the steps further does not help, because inlining collapses them again.
struct DeployInputs {
    DeployParams p;
    ProtocolTemplate template;
}

/// @title LaunchpadDeploy
/// @notice The design's Migration Plan as executable code: deploy order, salt mining, and the
/// pre-wiring verification that is the whole of the deployment's safety margin.
///
/// @dev Written as a library so the `forge script` entry point and the dry-run test execute the *same*
/// sequence and the *same* assertions, rather than two hand-kept-in-sync copies. There is no upgrade path
/// anywhere in v1, so a deployment that is wired wrong is not repaired — it is abandoned and redone.
/// That is why every step below asserts rather than trusts, and why the assertions are `require`s that
/// hold in a broadcast as well as under a test harness.
library LaunchpadDeploy {
    /// @notice The flag word the hook's address must encode, spelled out from the flags themselves.
    ///
    /// @dev Must equal {MilestoneHook.getHookPermissions} exactly. Written as the disjunction rather than
    /// as the literal 15040 so that adding a callback to the hook and forgetting this line is a
    /// compile-time-visible edit rather than an arithmetic coincidence; the dry-run test pins the numeric
    /// value as well. The dynamic-fee flag is deliberately absent: it lives in `PoolKey.fee`, not in the
    /// hook address.
    uint160 internal constant REQUIRED_FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
            | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
    );

    uint64 internal constant CANONICAL_BUYBACK_TAKE_WAD = uint64((2 * PAYOUT_WAD) / 9);
    uint32 internal constant CANONICAL_BUYBACK_GAS_LIMIT = 500_000;
    bytes32 internal constant CANONICAL_BUYBACK_SALT = keccak256("MILESTONE_CANONICAL_BUYBACK_V1");

    /// @notice The hook's constructor arguments, encoded as the salt is mined against them.
    ///
    /// @dev Migration Plan step 3: the satellite's address and the template are constructor arguments and
    /// therefore part of the initcode hashed into the `CREATE2` address, so the salt is valid only for
    /// this exact argument set. Changing any of them — including redeploying the satellite — invalidates
    /// the salt, which is why mining happens inside the same run that produced the satellite.
    function hookArgs(Deployment memory d, DeployParams memory p, ProtocolTemplate memory template)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(
            p.poolManager,
            d.nft,
            d.support,
            template,
            address(d.coldPaths),
            address(d.payoutPaths),
            address(d.controller),
            p.protocolRecipient,
            p.trustedOperator
        );
    }

    /// @notice The full initcode the mined salt is paired with.
    function hookInitcode(Deployment memory d, DeployParams memory p, ProtocolTemplate memory template)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodePacked(type(MilestoneHook).creationCode, hookArgs(d, p, template));
    }

    function verifyMiningInputs(Deployment memory d, DeployParams memory p, ProtocolTemplate memory template)
        internal
        view
    {
        require(address(p.poolManager) != address(0), "mine: pool manager");
        require(p.create2Deployer != address(0), "mine: create2 deployer");
        require(address(d.nft).code.length != 0, "mine: revenue nft");
        require(address(d.registry).code.length != 0, "mine: registry");
        require(address(d.controller).code.length != 0, "mine: controller");
        require(address(d.support).code.length != 0, "mine: launch support");
        require(address(d.coldPaths).code.length != 0, "mine: cold paths");
        require(address(d.payoutPaths).code.length != 0, "mine: payout paths");
        require(address(d.support.payoutPluginRegistry()) == address(d.registry), "mine: support registry");
        require(address(d.controller.registry()) == address(d.registry), "mine: controller registry");
        require(address(d.coldPaths.poolManager()) == address(p.poolManager), "mine: cold pool manager");
        require(address(d.payoutPaths.poolManager()) == address(p.poolManager), "mine: payout pool manager");
        require(address(d.coldPaths.revenueNFT()) == address(d.nft), "mine: cold revenue nft");
        require(address(d.payoutPaths.revenueNFT()) == address(d.nft), "mine: payout revenue nft");
        require(address(d.coldPaths.launchSupport()) == address(d.support), "mine: cold launch support");
        require(address(d.payoutPaths.launchSupport()) == address(d.support), "mine: payout launch support");
        require(d.coldPaths.protocolController() == address(d.controller), "mine: cold controller");
        require(d.payoutPaths.protocolController() == address(d.controller), "mine: payout controller");
        bytes32 templateHash = keccak256(abi.encode(template));
        require(d.coldPaths.templateHash() == templateHash, "mine: cold template");
        require(d.payoutPaths.templateHash() == templateHash, "mine: payout template");
        require(d.controller.protocolRecipient() == p.protocolRecipient, "mine: protocol recipient");
    }

    /// @notice Migration Plan step 3, mining half: the salt whose address encodes exactly the six flags.
    function mineHookSalt(Deployment memory d, DeployParams memory p, ProtocolTemplate memory template)
        internal
        view
        returns (address predicted, bytes32 salt)
    {
        verifyMiningInputs(d, p, template);
        (predicted, salt) = HookMiner.find(
            p.create2Deployer, REQUIRED_FLAGS, type(MilestoneHook).creationCode, hookArgs(d, p, template)
        );
        // {HookMiner} already selects on this, but it is the one property the whole deployment turns on:
        // a hook whose low bits are wrong is not a misconfiguration, it is a hook the pool manager never
        // calls. Re-asserted here so the miner and the check are not the same line of code.
        require(uint160(predicted) & Hooks.ALL_HOOK_MASK == REQUIRED_FLAGS, "deploy: mined flags");
    }

    /// @notice The whole Migration Plan, in order, with every step's verification.
    ///
    /// @dev Steps 1 and 2 use plain `CREATE`, not `CREATE2`, for a reason that is easy to get wrong: the
    /// revenue NFT gates {RevenueNFT.setMinter} on its own deployer, so whoever creates it must be
    /// whoever wires it. Routing it through the deterministic-deployment proxy would make the *proxy* the
    /// deployer and leave the minter permanently unwirable. Only the hook needs a mined address, and only
    /// the hook goes through the proxy.
    ///
    /// The consequence is that steps 1-2 are nonce-derived, so a re-run lands them elsewhere and the
    /// previous salt no longer applies. That is exactly why mining is step 3 of the same function rather
    /// than a value pasted in from an earlier session.
    function deployAll(DeployParams memory p, ProtocolTemplate memory template)
        internal
        returns (Deployment memory d)
    {
        _requireParams(p);

        DeployInputs memory inputs = DeployInputs({p: p, template: template});
        _deployCore(d, inputs);
        _deployHook(d, inputs);
        _bootstrapCanonicalComponents(d, inputs);
    }

    /// @dev The direct execution principal must own bootstrap administration while all deterministic setup
    /// runs. Under `forge script --broadcast`, cheatcode interception emits each creation and call from the
    /// configured broadcast signer. In the direct dry-run path no interception exists, so the contract that
    /// issues CREATE2 is also the caller seen by the registry and controller.
    function _requireParams(DeployParams memory p) private pure {
        require(address(p.poolManager) != address(0), "deploy: pool manager");
        require(p.create2Deployer != address(0), "deploy: create2 deployer");
        require(p.bootstrapAdministrator != address(0), "deploy: bootstrap admin");
        require(p.protocolAdmin != address(0), "deploy: protocol admin");
        require(p.protocolRecipient != address(0), "deploy: protocol recipient");
        // A zero trusted operator is legal: governance names one later, and direct launches work.
        if (p.selfIssuesCreate2) {
            require(p.bootstrapAdministrator == p.create2Deployer, "deploy: bootstrap executor");
        }
    }

    // Split in two purely for the Yul stack. Each satellite's creation bytecode is a large inline
    // expression, and holding both alongside the governance deployments in one frame puts `via_ir` over
    // its 16-slot limit. The split is not cosmetic: recombining these reintroduces a build failure.
    function _deployCore(Deployment memory d, DeployInputs memory i) private {
        _deployGovernance(d, i.p);
        _deploySatellites(d, i);
    }

    /// @dev Bootstrap owns both governance contracts only long enough to complete deterministic setup.
    function _deployGovernance(Deployment memory d, DeployParams memory p) private {
        d.registry = new PayoutPluginRegistry(p.bootstrapAdministrator);
        d.controller = new ProtocolController(p.bootstrapAdministrator, p.protocolRecipient, d.registry, address(0));
        d.nft = new RevenueNFT();
        d.support = new LaunchSupport(d.registry);
    }

    function _deploySatellites(Deployment memory d, DeployInputs memory i) private {
        d.coldPaths = new MilestoneColdPaths(i.p.poolManager, d.nft, d.support, i.template, address(d.controller));
        d.payoutPaths = new MilestonePayoutPaths(i.p.poolManager, d.nft, d.support, i.template, address(d.controller));
    }

    function _deployHook(Deployment memory d, DeployInputs memory i) private {
        _mineAndCreateHook(d, i);
        verifyImmutables(d, i.p, i.template);
        _wireNftMinter(d);
    }

    /// @dev Mining and creation share one frame because the salt is only meaningful against the exact
    /// initcode that follows it; wiring is deliberately outside, since it is the first irreversible step.
    function _mineAndCreateHook(Deployment memory d, DeployInputs memory i) private {
        address predicted;
        (predicted, d.hookSalt) = mineHookSalt(d, i.p, i.template);
        d.hook = MilestoneHook(payable(_create2(i.p, d.hookSalt, hookInitcode(d, i.p, i.template))));
        require(address(d.hook) == predicted, "deploy: hook address mismatch");
        Hooks.validateHookPermissions(IHooks(address(d.hook)), d.hook.getHookPermissions());
    }

    /// @dev {RevenueNFT.setMinter} is one-way, so it runs only after {verifyImmutables} has proved the
    /// hook is the one this deployment intended.
    function _wireNftMinter(Deployment memory d) private {
        d.nft.setMinter(address(d.hook));
        require(d.nft.minter() == address(d.hook), "deploy: minter not wired");
    }

    // Split three ways for the Yul stack: each `new` expression is a large inline initcode literal, and
    // holding two of them alongside the deployment and parameter pointers overruns `via_ir`'s 16-slot
    // window. Recombining these reintroduces a build failure, so the split is structural, not cosmetic.
    function _bootstrapCanonicalComponents(Deployment memory d, DeployInputs memory i) private {
        _deployCanonicalComponents(d, i.p);
        _completeBootstrapWiring(d, i.p);
        verifyConfiguration(d, i.p, i.template, false);
    }

    function _deployCanonicalComponents(Deployment memory d, DeployParams memory p) private {
        d.buyback = new BuybackAndBurnPlugin(p.poolManager, address(d.hook), TickMath.MIN_SQRT_PRICE + 1);
    }

    /// @dev Bind the controller before handing it registry authority, then register the canonical entry
    /// through the same typed, guard-aware governance path every later append uses. With the initial zero
    /// delay the schedule and execution may share this bootstrap transaction, while operation identity still
    /// binds the complete terms. The empty registry makes the resulting stable index deterministically zero.
    function _completeBootstrapWiring(Deployment memory d, DeployParams memory p) private {
        d.controller.bindTarget(address(d.hook));
        d.registry.proposeAdministrator(address(d.controller));
        d.controller.acceptRegistryAdministration();

        d.controller.scheduleRegisterPlugin(
            address(d.buyback),
            CANONICAL_BUYBACK_TAKE_WAD,
            CANONICAL_BUYBACK_GAS_LIMIT,
            PluginRole.PAYOUT,
            CANONICAL_BUYBACK_SALT
        );
        d.buybackIndex = d.controller.executeRegisterPlugin(
            address(d.buyback),
            CANONICAL_BUYBACK_TAKE_WAD,
            CANONICAL_BUYBACK_GAS_LIMIT,
            PluginRole.PAYOUT,
            CANONICAL_BUYBACK_SALT
        );
        require(d.buybackIndex == 0, "deploy: canonical index");
        d.canonicalPayoutPlan = uint256(1) << d.buybackIndex;

        d.controller.proposeAdministrator(p.protocolAdmin);
    }

    /// @notice Migration Plan step 4. A mismatch here does not revert at deployment or at launch — it
    /// surfaces as a delegatecall pair that disagrees about its own configuration at runtime — so it has
    /// to be checked, and checked before the minter is wired.
    ///
    /// @dev The satellite exposes no view functions at all, so its {ProtocolTemplate} cannot be read back
    /// and compared field-by-field the way the hook's can. Nor can its runtime code be compared against a
    /// reference deployment: it holds its own address in an immutable, which is baked into that code, so
    /// two satellites built from identical arguments have different bytecode by construction. What closes
    /// the gap instead is that {deployAll} passes one in-memory `template` to both constructors in a
    /// single call, so divergence is impossible without editing this function — and the dry-run test
    /// proves the satellite's copy functionally, by launching a pool and checking that the geometry the
    /// satellite wrote agrees with the template the hook reports.
    function verifyImmutables(Deployment memory d, DeployParams memory p, ProtocolTemplate memory template)
        internal
        view
    {
        require(address(d.hook.poolManager()) == address(p.poolManager), "verify: hook pool manager");
        require(address(d.coldPaths.poolManager()) == address(p.poolManager), "verify: satellite pool manager");
        require(address(d.payoutPaths.poolManager()) == address(p.poolManager), "verify: payout pool manager");
        require(address(d.hook.revenueNFT()) == address(d.nft), "verify: hook revenue nft");
        require(address(d.coldPaths.revenueNFT()) == address(d.nft), "verify: satellite revenue nft");
        require(address(d.payoutPaths.revenueNFT()) == address(d.nft), "verify: payout revenue nft");
        require(address(d.hook.launchSupport()) == address(d.support), "verify: hook launch support");
        require(address(d.coldPaths.launchSupport()) == address(d.support), "verify: satellite launch support");
        require(address(d.payoutPaths.launchSupport()) == address(d.support), "verify: payout launch support");

        require(d.hook.coldPaths() == address(d.coldPaths), "verify: coldPaths target");
        require(d.hook.payoutPaths() == address(d.payoutPaths), "verify: payoutPaths target");
        require(d.hook.coldPaths().code.length != 0, "verify: satellite has no code");
        require(d.hook.payoutPaths().code.length != 0, "verify: payout has no code");

        require(address(d.support.payoutPluginRegistry()) == address(d.registry), "verify: support registry");
        require(address(d.hook.payoutPluginRegistry()) == address(d.registry), "verify: hook registry");
        require(address(d.coldPaths.payoutPluginRegistry()) == address(d.registry), "verify: cold registry");
        require(address(d.payoutPaths.payoutPluginRegistry()) == address(d.registry), "verify: payout registry");
        require(address(d.controller.registry()) == address(d.registry), "verify: controller registry");

        require(keccak256(abi.encode(d.hook.template())) == keccak256(abi.encode(template)), "verify: hook template");
        require(d.coldPaths.templateHash() == keccak256(abi.encode(template)), "verify: cold template");
        require(d.payoutPaths.templateHash() == keccak256(abi.encode(template)), "verify: payout template");
        require(d.hook.protocolController() == address(d.controller), "verify: protocol controller");
        require(d.coldPaths.protocolController() == address(d.controller), "verify: cold controller");
        require(d.payoutPaths.protocolController() == address(d.controller), "verify: payout controller");
        require(d.hook.protocolRecipient() == p.protocolRecipient, "verify: protocol recipient");
        require(d.hook.trustedOperator() == p.trustedOperator, "verify: trusted operator");
    }

    function verifyConfiguration(
        Deployment memory d,
        DeployParams memory p,
        ProtocolTemplate memory template,
        bool administrationAccepted
    ) internal view {
        verifyImmutables(d, p, template);
        require(address(d.controller.target()) == address(d.hook), "verify: controller target");
        require(d.controller.protocolRecipient() == p.protocolRecipient, "verify: controller recipient");
        require(d.controller.governanceDelay() == 0, "verify: governance delay");
        require(d.registry.administrator() == address(d.controller), "verify: registry authority");
        address expectedAdministrator = administrationAccepted ? p.protocolAdmin : p.bootstrapAdministrator;
        address expectedPendingAdministrator = administrationAccepted ? address(0) : p.protocolAdmin;
        require(d.controller.administrator() == expectedAdministrator, "verify: controller administrator");
        require(d.controller.pendingAdministrator() == expectedPendingAdministrator, "verify: pending administrator");

        EconomicConfig memory controllerConfig = d.controller.economicConfig();
        EconomicConfig memory hookConfig = d.hook.economicConfig();
        require(
            keccak256(abi.encode(controllerConfig)) == keccak256(abi.encode(hookConfig)), "verify: economics parity"
        );
        require(
            controllerConfig.harvestServiceFeeWad == Bounds.DEFAULT_HARVEST_SERVICE_FEE_WAD,
            "verify: harvest service fee"
        );
        require(
            controllerConfig.quoteCreatorShareWad == Bounds.DEFAULT_QUOTE_CREATOR_SHARE_WAD,
            "verify: quote creator share"
        );
        require(
            controllerConfig.tokenMilestoneFundShareWad == Bounds.DEFAULT_TOKEN_MILESTONE_FUND_SHARE_WAD,
            "verify: token fund share"
        );
        require(controllerConfig.version == 1, "verify: economic version");
        require(
            d.controller.MAX_HARVEST_SERVICE_FEE_WAD() == Bounds.MAX_HARVEST_SERVICE_FEE_WAD, "verify: harvest fee cap"
        );
        require(
            d.controller.MAX_QUOTE_CREATOR_SHARE_WAD() == Bounds.MAX_QUOTE_CREATOR_SHARE_WAD,
            "verify: quote creator cap"
        );
        require(
            d.controller.MAX_TOKEN_MILESTONE_FUND_SHARE_WAD() == Bounds.MAX_TOKEN_MILESTONE_FUND_SHARE_WAD,
            "verify: token fund cap"
        );

        require(d.registry.entryCount() == 1, "verify: registry entry count");
        require(d.buybackIndex == 0, "verify: canonical index");
        require(d.canonicalPayoutPlan == uint256(1) << d.buybackIndex, "verify: canonical plan");
        PluginEntry memory entry = d.registry.entry(d.buybackIndex);
        require(entry.plugin == address(d.buyback), "verify: canonical plugin");
        require(entry.takeWad == CANONICAL_BUYBACK_TAKE_WAD, "verify: canonical take");
        require(entry.gasLimit == CANONICAL_BUYBACK_GAS_LIMIT, "verify: canonical gas");
        require(entry.codeHash == address(d.buyback).codehash, "verify: canonical codehash");
        require(entry.role == PluginRole.PAYOUT && !entry.suspended, "verify: canonical state");
        require(d.registry.isSelectable(d.buybackIndex), "verify: canonical selectable");

        require(address(d.buyback.poolManager()) == address(p.poolManager), "verify: buyback pool manager");
        require(d.buyback.hook() == address(d.hook), "verify: buyback hook");
        require(d.buyback.sqrtPriceLimitX96() == TickMath.MIN_SQRT_PRICE + 1, "verify: buyback limit");
    }

    /// @dev The two `CREATE2` issuers {HookMiner} distinguishes. Mining is done against
    /// `p.create2Deployer`, so the deployment must issue from that same address or the hook lands
    /// somewhere with the wrong low bits — which is what the caller's `selfIssuesCreate2` declaration
    /// selects, and what {deployAll}'s address assertion catches if the two disagree.
    function _create2(DeployParams memory p, bytes32 salt, bytes memory initcode) private returns (address deployed) {
        if (p.selfIssuesCreate2) {
            assembly ("memory-safe") {
                deployed := create2(0, add(initcode, 0x20), mload(initcode), salt)
            }
            require(deployed != address(0), "deploy: create2 reverted");
        } else {
            // The deterministic-deployment proxy takes `salt ++ initcode` as raw calldata and returns the
            // 20 bytes of the created address, unpadded and not ABI-encoded.
            (bool ok, bytes memory ret) = p.create2Deployer.call(abi.encodePacked(salt, initcode));
            require(ok && ret.length == 20, "deploy: proxy create2 failed");
            assembly ("memory-safe") {
                deployed := shr(96, mload(add(ret, 0x20)))
            }
        }
    }
}
