// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

import {LaunchSupport} from "../../src/LaunchSupport.sol";
import {MilestoneColdPaths} from "../../src/MilestoneColdPaths.sol";
import {MilestoneHook} from "../../src/MilestoneHook.sol";
import {MilestoneToken} from "../../src/MilestoneToken.sol";
import {RevenueNFT} from "../../src/RevenueNFT.sol";
import {Bounds, LaunchConfig} from "../../src/types/LaunchTypes.sol";

import {LaunchpadTest, TestRouter} from "../Fixtures.sol";
import {MilestoneHookHarness} from "../harness/MilestoneHookHarness.sol";

/// @notice {LaunchpadTest} with the *live* Base v4 `PoolManager` as the counterparty instead of a locally
/// deployed one.
///
/// @dev design Decision 11 puts the fork layer here for one reason: "a local harness can share our own
/// sign mistakes". Every unit test in this repo trades against a `PoolManager` this repo compiled from the
/// pinned submodule, so a level/tick confusion that our own arithmetic and our own harness agree on is
/// invisible there. Against the deployed singleton it is not — a band placed on the wrong side of spot
/// fills instantly at the wrong price, and real v4 is the only witness that cannot be in on the mistake.
///
/// Only the manager changes. The satellite, the NFT minter, the shared template and all forty-odd helpers
/// on {LaunchpadTest} are the production wiring, which is what makes this layer a re-run of the specs
/// against a different counterparty rather than a second, divergent suite.
///
/// Two deliberate non-changes:
///
/// The hook is still placed with `deployCodeTo` at {LaunchpadTest.HOOK_ADDR} rather than mined. The address
/// only has to encode the permission flags, and that mining produces such an address unaided is a claim
/// about the deployment scripts, asserted where it belongs — `test/unit/Deployment.t.sol`, which runs the
/// real `CREATE2` path. Mining here would additionally break {LaunchpadTest._sign}, whose EIP-712 digest is
/// bound to `HOOK_ADDR`.
///
/// The fork block is pinned. An unpinned fork re-prices every run against whatever Base did overnight,
/// which turns a failure into an archaeology problem; pinning also lets Foundry serve the run from its
/// per-block RPC cache after the first fetch.
abstract contract BaseForkTest is LaunchpadTest {
    /// @notice Uniswap v4's `PoolManager` on Base mainnet — the deployed singleton, not our build of it.
    address internal constant BASE_POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b;

    uint256 internal constant BASE_CHAIN_ID = 8453;

    /// @dev A block long past finality at the time of writing. Bump it deliberately, never incidentally.
    uint256 internal constant BASE_FORK_BLOCK = 50_800_000;

    /// @dev The `[rpc_endpoints]` alias in `foundry.toml`, which resolves to `${BASE_RPC_URL}`. Named
    /// rather than inlined so no endpoint or key is ever committed — see that file's own note.
    string internal constant BASE_RPC_ALIAS = "base";

    /// @dev The ladder's run-ups cross three orders of magnitude in price, so the default 100k float the
    /// unit fixture deals would bind before the ladder did. Sized off {LadderExtensionTest}'s float.
    uint256 internal constant FORK_FLOAT = 5_000_000 ether;

    function setUp() public virtual override {
        vm.createSelectFork(BASE_RPC_ALIAS, BASE_FORK_BLOCK);

        // Cheap, and the difference between "the ladder is wrong" and "the fork never attached".
        assertEq(block.chainid, BASE_CHAIN_ID, "fork is not Base mainnet");
        assertGt(BASE_POOL_MANAGER.code.length, 0, "no v4 PoolManager at the pinned Base address");

        creator = vm.addr(CREATOR_PK);
        imposter = vm.addr(IMPOSTER_PK);

        _deployProtocolAgainstLiveV4();

        // Relayed rather than creator-sent: Decision 11 describes the fork lifecycle as beginning with a
        // relayed signed launch, and it is the entry a front-end actually uses.
        (poolId, key, token) = _launchRelayed(_defaultConfig("Milestone", "MILE"), RELAYER);
        launchTime = block.timestamp;

        vm.deal(BUYER, FORK_FLOAT);
        vm.deal(RELAYER, FORK_FLOAT);
        vm.deal(STRANGER, FORK_FLOAT);
        vm.deal(creator, FORK_FLOAT);
        vm.deal(address(router), FORK_FLOAT);
    }

    /// @dev {LaunchpadTest._deployProtocol} is reproduced here with one line changed, because it deploys
    /// its own manager and is not virtual. Everything else is copied deliberately: a divergence between
    /// this wiring and the unit fixture's would be a difference between the layers that is not the
    /// counterparty, which is the one thing this layer is trying to isolate.
    function _deployProtocolAgainstLiveV4() private {
        manager = PoolManager(BASE_POOL_MANAGER);
        nft = new RevenueNFT();
        support = new LaunchSupport();
        template = Bounds.defaultTemplate();

        coldPaths = new MilestoneColdPaths(IPoolManager(address(manager)), nft, support, template);

        deployCodeTo(
            _hookArtifact(),
            abi.encode(
                IPoolManager(address(manager)),
                nft,
                support,
                template,
                address(coldPaths),
                PROTOCOL_ADMIN,
                PROTOCOL_RECIPIENT
            ),
            HOOK_ADDR
        );
        hook = MilestoneHook(payable(HOOK_ADDR));
        nft.setMinter(HOOK_ADDR);

        router = new TestRouter(IPoolManager(address(manager)));
    }

    /// @notice A signed launch the creator submits themselves, carrying a dev buy.
    ///
    /// @dev The fixture's own helpers cover the two pure cases — {LaunchpadTest._launchDirectWithValue}
    /// sends value with no signature, {LaunchpadTest._launchRelayedSignedBy} sends a signature with no
    /// value — and the lifecycle needs both at once. Both gates are satisfied honestly rather than
    /// bypassed: the signature is verified against the declared creator exactly as on a relay, and the dev
    /// buy rides because `msg.sender` *is* the creator, which is the whole of what
    /// `MilestoneColdPaths.launch` checks (design Decision 19; `token-launch`'s "Dev buy requires the
    /// creator's own transaction"). A signature is not what suppresses a dev buy — a foreign sender is.
    function _launchSignedByCreatorWithValue(LaunchConfig memory config, uint256 value)
        internal
        returns (PoolId id, PoolKey memory k, MilestoneToken t)
    {
        bytes memory signature = _sign(config, CREATOR_PK);
        vm.deal(creator, creator.balance + value);
        vm.prank(creator);
        (PoolId poolId_, address tokenAddr, PoolKey memory key_) = hook.launch{value: value}(config, signature);
        return (poolId_, key_, MilestoneToken(tokenAddr));
    }
}

/// @notice {BaseForkTest} with the recording harness at {LaunchpadTest.HOOK_ADDR}.
///
/// @dev The mirror of {HarnessLaunchpadTest} for the fork layer, and needed for the same reasons: the
/// mid-transaction live-band snapshots, and the two boundary-state helpers that manufacture an exhausted
/// core ladder. Walking to the extension organically is self-defeating rather than merely slow — see
/// {LadderExtensionTest}'s rig note. The harness is the production hook plus a log, so the counterparty
/// under test is unchanged.
abstract contract BaseForkHarnessTest is BaseForkTest {
    MilestoneHookHarness internal harness;

    function setUp() public virtual override {
        super.setUp();
        harness = MilestoneHookHarness(payable(HOOK_ADDR));
    }

    function _hookArtifact() internal view virtual override returns (string memory) {
        return "MilestoneHookHarness.sol:MilestoneHookHarness";
    }
}
