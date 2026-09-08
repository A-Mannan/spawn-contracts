// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";

import {LaunchSupport} from "../src/LaunchSupport.sol";
import {MilestoneColdPaths} from "../src/MilestoneColdPaths.sol";
import {MilestoneHook} from "../src/MilestoneHook.sol";
import {RevenueNFT} from "../src/RevenueNFT.sol";
import {ProtocolTemplate} from "../src/types/LaunchTypes.sol";

/// @notice Every address one complete protocol deployment produces, plus the salt that placed the hook.
struct Deployment {
    RevenueNFT nft;
    LaunchSupport support;
    MilestoneColdPaths coldPaths;
    MilestoneHook hook;
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
    address protocolAdmin;
    address protocolRecipient;
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
            p.poolManager, d.nft, d.support, template, address(d.coldPaths), p.protocolAdmin, p.protocolRecipient
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

    /// @notice Migration Plan step 3, mining half: the salt whose address encodes exactly the six flags.
    function mineHookSalt(Deployment memory d, DeployParams memory p, ProtocolTemplate memory template)
        internal
        view
        returns (address predicted, bytes32 salt)
    {
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
        require(address(p.poolManager) != address(0), "deploy: pool manager");
        require(p.create2Deployer != address(0), "deploy: create2 deployer");

        // --- Step 1: the revenue NFT and the launch-support helper ---
        d.nft = new RevenueNFT();
        d.support = new LaunchSupport();

        // --- Step 2: the satellite, before the hook, because the hook's constructor rejects a
        // codeless target and because its address is part of what the salt is mined against ---
        d.coldPaths = new MilestoneColdPaths(p.poolManager, d.nft, d.support, template);

        // --- Step 3: mine, then deploy the hook at the mined address ---
        address predicted;
        (predicted, d.hookSalt) = mineHookSalt(d, p, template);
        d.hook = MilestoneHook(payable(_create2(p, d.hookSalt, hookInitcode(d, p, template))));
        require(address(d.hook) == predicted, "deploy: hook address mismatch");

        // The flags again, now against the deployed contract's own declaration rather than against this
        // library's constant. The pre-deployment check proves the address matches what we asked for; this
        // proves what we asked for matches what the hook says it needs. Both run before any wiring.
        Hooks.validateHookPermissions(IHooks(address(d.hook)), d.hook.getHookPermissions());

        // --- Step 4: the two halves agree, and the hook points at the satellite we just deployed ---
        verifyImmutables(d, p, template);

        // --- Step 5: wire the authorised minter and confirm the fee recipient ---
        d.nft.setMinter(address(d.hook));
        require(d.nft.minter() == address(d.hook), "deploy: minter not wired");
        // The recipient is a constructor argument, so it is already set; {MilestoneHook.setProtocolRecipient}
        // exists for later changes and is gated on the admin, who is not necessarily the deployer. Asserted
        // rather than re-set, because a deployment that has to move it has already been mined wrong.
        require(d.hook.protocolRecipient() == p.protocolRecipient, "deploy: recipient not set");
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
        require(address(d.hook.revenueNFT()) == address(d.nft), "verify: hook revenue nft");
        require(address(d.coldPaths.revenueNFT()) == address(d.nft), "verify: satellite revenue nft");
        require(address(d.hook.launchSupport()) == address(d.support), "verify: hook launch support");
        require(address(d.coldPaths.launchSupport()) == address(d.support), "verify: satellite launch support");

        require(d.hook.coldPaths() == address(d.coldPaths), "verify: coldPaths target");
        require(d.hook.coldPaths().code.length != 0, "verify: satellite has no code");

        require(keccak256(abi.encode(d.hook.template())) == keccak256(abi.encode(template)), "verify: hook template");
        require(d.hook.protocolAdmin() == p.protocolAdmin, "verify: protocol admin");
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
