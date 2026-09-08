// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";

import {Deploy} from "../../script/Deploy.s.sol";
import {Deployment, DeployParams, LaunchpadDeploy} from "../../script/LaunchpadDeploy.sol";
import {MineHookSalt} from "../../script/MineHookSalt.s.sol";

import {LaunchSupport} from "../../src/LaunchSupport.sol";
import {MilestoneColdPaths} from "../../src/MilestoneColdPaths.sol";
import {MilestoneHook} from "../../src/MilestoneHook.sol";
import {RevenueNFT} from "../../src/RevenueNFT.sol";
import {LadderLib} from "../../src/libraries/LadderLib.sol";
import {Bounds, LaunchConfig, Phase, PoolState, ProtocolTemplate} from "../../src/types/LaunchTypes.sol";

/// @notice The Migration Plan's dry run: {Deploy} executed against a locally deployed pool manager, with
/// every assertion the plan calls for checked from outside the script as well as inside it.
///
/// @dev Deliberately does not build on {LaunchpadTest}. The shared fixture places the hook with
/// `deployCodeTo` at a hand-written address, which is the right shortcut for testing behaviour and exactly
/// the wrong one here: what these tests exist to prove is that mining produces a valid address on its own,
/// so the address must come from the miner and the hook must be deployed by `CREATE2` at whatever it says.
///
/// The CREATE2 deployer is the {Deploy} script contract rather than this test contract, because the test
/// drives the script rather than the library — the same relationship the real broadcast has with the
/// deterministic-deployment proxy, and the reason the deployer is a parameter at all.
contract DeploymentTest is Test {
    PoolManager internal manager;
    Deploy internal deployScript;
    MineHookSalt internal mineScript;

    ProtocolTemplate internal template;
    DeployParams internal params;
    Deployment internal deployed;

    address internal constant PROTOCOL_ADMIN = address(0xADA1);
    address internal constant PROTOCOL_RECIPIENT = address(0xFEE1);

    function setUp() public {
        manager = new PoolManager(address(this));
        deployScript = new Deploy();
        mineScript = new MineHookSalt();
        template = Bounds.defaultTemplate();

        params = DeployParams({
            poolManager: IPoolManager(address(manager)),
            create2Deployer: address(deployScript),
            selfIssuesCreate2: true,
            protocolAdmin: PROTOCOL_ADMIN,
            protocolRecipient: PROTOCOL_RECIPIENT
        });

        deployed = deployScript.deploy(params, template);
    }

    // --- Salt mining ---

    function test_theMinedAddressEncodesExactlyTheRequiredFlags() public view {
        (address mined,) = mineScript.mine(deployed, params, template);

        assertEq(uint160(mined) & Hooks.ALL_HOOK_MASK, LaunchpadDeploy.REQUIRED_FLAGS, "flag word");
        assertEq(uint256(LaunchpadDeploy.REQUIRED_FLAGS), 15040, "the six declared callbacks");

        // The on-chain assertion: the address's low bits agree with what the hook itself declares it
        // needs, field by field, including every callback that must be *off*.
        Hooks.validateHookPermissions(IHooks(mined), deployed.hook.getHookPermissions());

        // Mining is deterministic, but {HookMiner.find} skips any candidate that already has code, so a
        // mine run *after* the hook exists walks past it to the next free matching address. Worth pinning
        // as behaviour rather than discovering it mid-deployment: re-running the mining script once the
        // hook is live does not reprint that hook's salt, and an operator who assumed it did would deploy
        // a second protocol beside the first.
        assertTrue(mined != address(deployed.hook), "the miner skipped the address it had already filled");
    }

    function test_theRecordedSaltReproducesTheHookAddress() public view {
        // The salt the deployment recorded plus the initcode it was mined against, and nothing else: the
        // whole of what an operator needs to reproduce the address independently of the deployment.
        assertEq(
            HookMiner.computeAddress(
                address(deployScript),
                uint256(deployed.hookSalt),
                LaunchpadDeploy.hookInitcode(deployed, params, template)
            ),
            address(deployed.hook),
            "salt reproduces the address from the initcode alone"
        );
        assertGt(address(deployed.hook).code.length, 0, "hook has code");
    }

    function test_theDeployedHookAddressPassesTheOnChainFlagAssertion() public view {
        Hooks.validateHookPermissions(IHooks(address(deployed.hook)), deployed.hook.getHookPermissions());
        assertEq(uint160(address(deployed.hook)) & Hooks.ALL_HOOK_MASK, LaunchpadDeploy.REQUIRED_FLAGS, "flag word");
    }

    // --- Migration Plan step 4: the two halves agree ---

    function test_theHookAndSatelliteShareIdenticalImmutables() public view {
        assertEq(address(deployed.hook.poolManager()), address(manager), "hook pool manager");
        assertEq(address(deployed.coldPaths.poolManager()), address(manager), "satellite pool manager");

        assertEq(address(deployed.hook.revenueNFT()), address(deployed.nft), "hook revenue nft");
        assertEq(address(deployed.coldPaths.revenueNFT()), address(deployed.nft), "satellite revenue nft");

        assertEq(address(deployed.hook.launchSupport()), address(deployed.support), "hook launch support");
        assertEq(address(deployed.coldPaths.launchSupport()), address(deployed.support), "satellite launch support");

        assertEq(keccak256(abi.encode(deployed.hook.template())), keccak256(abi.encode(template)), "template");
    }

    function test_coldPathsPointsAtTheDeployedSatellite() public view {
        assertEq(deployed.hook.coldPaths(), address(deployed.coldPaths), "coldPaths target");
        assertGt(deployed.hook.coldPaths().code.length, 0, "satellite has code");
    }

    /// @notice The step-4 assertions are the only thing standing between a mismatched pair and a protocol
    /// that fails at runtime, so prove they actually bite rather than passing on anything handed to them.
    ///
    /// @dev The same argument as `make size-gate-selftest`: a check nobody has seen fail is a check nobody
    /// has confirmed is running.
    function test_theWiringAssertionsAreNotVacuous() public {
        // A satellite built against a different pool manager — the mismatch the Migration Plan warns does
        // not revert at deployment.
        PoolManager otherManager = new PoolManager(address(this));
        Deployment memory wrongManager = deployed;
        wrongManager.coldPaths =
            new MilestoneColdPaths(IPoolManager(address(otherManager)), deployed.nft, deployed.support, template);
        vm.expectRevert(bytes("verify: satellite pool manager"));
        this.verifyImmutables(wrongManager, params, template);

        // A correctly configured satellite that simply is not the one the hook was mined against.
        Deployment memory wrongTarget = deployed;
        wrongTarget.coldPaths =
            new MilestoneColdPaths(IPoolManager(address(manager)), deployed.nft, deployed.support, template);
        vm.expectRevert(bytes("verify: coldPaths target"));
        this.verifyImmutables(wrongTarget, params, template);

        // A template that differs from the one the hook was constructed with, by one field.
        ProtocolTemplate memory mutated = template;
        mutated.coreBandCount = template.coreBandCount + 1;
        vm.expectRevert(bytes("verify: hook template"));
        this.verifyImmutables(deployed, params, mutated);

        // The admin the deployment was asked for.
        DeployParams memory wrongAdmin = params;
        wrongAdmin.protocolAdmin = address(0xBAD);
        vm.expectRevert(bytes("verify: protocol admin"));
        this.verifyImmutables(deployed, wrongAdmin, template);
    }

    /// @dev External so {vm.expectRevert} has a call frame to catch; the library's assertions are
    /// `internal` and run inside {Deploy} in the real thing.
    function verifyImmutables(Deployment memory d, DeployParams memory p, ProtocolTemplate memory t) public view {
        LaunchpadDeploy.verifyImmutables(d, p, t);
    }

    // --- Migration Plan step 5: the wiring ---

    function test_theAuthorisedMinterIsTheHook() public {
        assertEq(deployed.nft.minter(), address(deployed.hook), "minter");

        // No one but the deployer could ever have wired it...
        vm.expectRevert(RevenueNFT.NotDeployer.selector);
        deployed.nft.setMinter(address(this));

        // ...and the deployer itself cannot re-point it, so the wiring the plan verified is the wiring
        // that stands. Checked from the deployer because the deployer gate is the earlier of the two.
        vm.prank(address(deployScript));
        vm.expectRevert(RevenueNFT.MinterAlreadySet.selector);
        deployed.nft.setMinter(address(this));
    }

    function test_theProtocolFeeRecipientAndAdminAreSet() public view {
        assertEq(deployed.hook.protocolRecipient(), PROTOCOL_RECIPIENT, "recipient");
        assertEq(deployed.hook.protocolAdmin(), PROTOCOL_ADMIN, "admin");
    }

    // --- The dry run completes: a real launch through the freshly wired protocol ---

    /// @notice Launches a pool through the deployed hook, which is the only check that exercises the
    /// delegatecall pair rather than reading it.
    ///
    /// @dev It is also the only available proof of the satellite's {ProtocolTemplate}. The satellite has no
    /// view functions, and its runtime code embeds its own address, so its template can be compared neither
    /// field-by-field nor by code hash against a reference. What it *does* do is write template-derived
    /// values into the hook's storage during launch: the initial base fee, the curve's far level, and the
    /// ladder's share of supply all come from the satellite's immutables, while {MilestoneHook.template}
    /// reports the hook's. Agreement across all three is the functional form of "constructed with the same
    /// template".
    function test_theDryRunLaunchesThroughTheDeployedWiring() public {
        address creator = address(0xC0FFEE);
        uint256 totalSupply = 1_000_000_000 ether;
        LaunchConfig memory config = Bounds.defaultConfig(creator, "Deploy Rehearsal", "DRY", totalSupply);

        vm.prank(creator);
        (PoolId poolId, address token, PoolKey memory key) = deployed.hook.launch(config, "");

        assertEq(address(key.hooks), address(deployed.hook), "pool is bound to the deployed hook");

        PoolState memory state = deployed.hook.poolState(poolId);
        assertEq(uint8(state.phase), uint8(Phase.BONDING_CURVE), "phase");
        assertEq(state.creator, creator, "creator");
        assertEq(state.token, token, "token");

        // The minter wiring, exercised rather than read: only the hook can mint, and the stream lands on
        // the creator.
        assertEq(deployed.nft.ownerOf(deployed.nft.tokenIdOf(poolId)), creator, "revenue nft holder");

        // Three template fields the satellite wrote, against the template the hook reports.
        ProtocolTemplate memory reported = deployed.hook.template();
        assertEq(uint256(state.baseFeeHundredthsBip), uint256(reported.baseFeeHundredthsBip), "base fee");
        assertEq(int256(state.farLevel - state.openingLevel), int256(reported.curveSpanLevels), "curve span");
        assertEq(
            state.ladderInventoryRemaining,
            LadderLib.ladderSupply(totalSupply, reported.ladderSupplyShareWad),
            "ladder supply share"
        );
    }
}
