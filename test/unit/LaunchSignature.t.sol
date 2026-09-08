// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolId} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {LaunchpadTest} from "../Fixtures.sol";
import {MilestoneToken} from "../../src/MilestoneToken.sol";
import {LaunchSignature} from "../../src/libraries/LaunchSignature.sol";
import {LaunchConfig, Phase} from "../../src/types/LaunchTypes.sol";

/// @notice Unit tests for task 15.3 — the signed-config relay (design Decision 19): EIP-712 hashing, the
/// deadline, creator identity, and the CREATE2 salt that makes a token address knowable and reserved.
///
/// @dev The whole point of this mechanism is that launching costs the creator nothing and *anyone* may
/// relay, so the tests are mostly about what a hostile relayer cannot do: alter a field, claim the
/// creator slot, replay, or occupy the address a token page has already advertised.
contract LaunchSignatureTest is LaunchpadTest {
    // --- Scenario: A relayer can launch on the creator's behalf ---

    function test_aRelayerCanLaunchOnTheCreatorsBehalf() public {
        LaunchConfig memory config = _defaultConfig("Relayed", "RLY");

        (PoolId id,, MilestoneToken t) = _launchRelayed(config, RELAYER);

        assertEq(hook.poolState(id).creator, creator, "the signer is the creator, not the relayer");
        assertTrue(hook.poolState(id).creator != RELAYER, "the relayer is not the creator");
        assertEq(nft.ownerOf(uint256(PoolId.unwrap(id))), creator, "the revenue NFT went to the signer");
        assertEq(uint8(hook.poolPhase(id)), uint8(Phase.BONDING_CURVE), "the pool is live");

        // The whole supply is in protocol custody, split between the hook's own balance and the curve
        // position minted during the launch — v4 holds a position's inventory in the manager, so the
        // hook's balance alone is short by exactly what position 0 consumed.
        assertEq(
            t.balanceOf(address(hook)) + t.balanceOf(address(manager)),
            config.totalSupply,
            "the whole supply is protocol-held"
        );
        assertEq(t.balanceOf(RELAYER), 0, "the relayer holds none of it");
        assertEq(t.balanceOf(creator), 0, "and neither does the creator");
    }

    /// @dev No allowlist, no approval, no privileged role: the property is that an arbitrary address the
    /// protocol has never seen can relay. `STRANGER` is used nowhere else in this suite.
    function test_anyAddressCanRelayWithoutAuthorisation() public {
        LaunchConfig memory config = _defaultConfig("Stranger", "STR");

        (PoolId id,,) = _launchRelayedSignedBy(config, STRANGER, CREATOR_PK);

        assertEq(hook.poolState(id).creator, creator, "identity comes from the signature alone");
    }

    // --- Scenario: A creator can launch directly without a signature ---

    /// @dev The second half of the scenario is the interesting half: the direct path must land on the
    /// *same* address the creator's signature would have produced, so publishing a configuration and
    /// later self-launching is not a different token.
    function test_aCreatorCanLaunchDirectlyWithoutASignature() public {
        LaunchConfig memory config = _defaultConfig("Direct", "DIR");
        address predicted = support.predictToken(config, HOOK_ADDR);

        (PoolId id,, MilestoneToken t) = _launchDirect(config);

        assertEq(hook.poolState(id).creator, creator, "the sender is the creator");
        assertEq(address(t), predicted, "the direct path lands where the signature would have");
    }

    /// @dev A relayer cannot simply omit the signature and declare themselves: the empty-signature path
    /// checks `msg.sender` against the declaration rather than overwriting it.
    function test_theDirectPathRejectsASenderOtherThanTheDeclaredCreator() public {
        LaunchConfig memory config = _defaultConfig("Direct", "DIR");

        vm.prank(RELAYER);
        vm.expectRevert(abi.encodeWithSelector(LaunchSignature.CreatorMismatch.selector, creator, RELAYER));
        hook.launch(config, "");
    }

    // --- Scenario: A relayer cannot alter the configuration ---

    /// @dev Every economic field, one at a time. The signature is taken over the original and the relay
    /// submits the edit, which is exactly the attack: the relayer holds a valid signature for *something*
    /// and wants it to authorise something else.
    ///
    /// The revert is `CreatorMismatch` rather than a signature-shape error, and that is the mechanism
    /// working as designed — the edit recovers some unrelated address, and comparing that against the
    /// configuration's declared creator is what rejects it. Recovering the creator *from* the signature
    /// instead would have launched every one of these edits, credited to the recovered address.
    ///
    /// Each edit is built fresh rather than copied from the signed configuration: `LaunchConfig memory x =
    /// y` aliases the same memory in Solidity, so mutating a "copy" would silently rewrite the original
    /// and the final control assertion would be testing the last edit.
    function test_aRelayerCannotAlterTheConfiguration() public {
        LaunchConfig memory signed = _defaultConfig("Honest", "HON");
        bytes memory signature = _sign(signed, CREATOR_PK);

        uint256 fieldCount = 7;
        for (uint256 i = 0; i < fieldCount; i++) {
            LaunchConfig memory edited = _editedConfig(i);

            vm.prank(RELAYER);
            vm.expectRevert();
            hook.launch(edited, signature);
        }

        // The unedited configuration still launches with that same signature, which is what proves the
        // rejections above came from the edits and not from a malformed signature.
        vm.prank(RELAYER);
        (PoolId id,,) = hook.launch(signed, signature);
        assertEq(hook.poolState(id).creator, creator, "the unedited configuration is fine");
    }

    /// @dev The signed configuration with field `index` altered, and nothing else touched.
    function _editedConfig(uint256 index) internal view returns (LaunchConfig memory edited) {
        edited = _defaultConfig("Honest", "HON");

        if (index == 0) {
            edited.creator = RELAYER;
        } else if (index == 1) {
            edited.name = "Hostile";
        } else if (index == 2) {
            edited.symbol = "HOS";
        } else if (index == 3) {
            edited.totalSupply = edited.totalSupply * 2;
        } else if (index == 4) {
            edited.devBuyShareWad = 0.05e18;
        } else if (index == 5) {
            edited.devBuyVestingSeconds = 30 days;
        } else {
            edited.harvestSplit = _split(0.7e18, 0.1e18, 0.1e18);
        }
    }

    /// @dev The deadline is signed too, so extending it is an alteration like any other — a relayer
    /// cannot hold a lapsed signature and push its expiry out.
    function test_aRelayerCannotExtendTheDeadline() public {
        LaunchConfig memory config = _defaultConfig("Deadline", "DLN");
        config.deadline = launchTime + 1 hours;
        bytes memory signature = _sign(config, CREATOR_PK);

        config.deadline = launchTime + 365 days;

        vm.prank(RELAYER);
        vm.expectRevert();
        hook.launch(config, signature);
    }

    /// @dev A signature over a *different* configuration, replayed onto this one. Distinct from the edits
    /// above: here both configurations are legitimately signed, and the question is whether one
    /// signature can be lifted onto the other.
    function test_aSignatureDoesNotTransferBetweenConfigurations() public {
        LaunchConfig memory first = _defaultConfig("First", "ONE");
        LaunchConfig memory second = _defaultConfig("Second", "TWO");

        bytes memory signatureForFirst = _sign(first, CREATOR_PK);

        vm.prank(RELAYER);
        vm.expectRevert();
        hook.launch(second, signatureForFirst);
    }

    // --- Scenario: Replay is rejected ---

    /// @dev No nonce and no consumed-signature set: the salt is a function of the configuration and its
    /// creator, so the second launch collides with the deployed token. The revert comes from CREATE2
    /// failing rather than from a protocol check, which is why it is asserted as a bare revert.
    function test_replayIsRejected() public {
        LaunchConfig memory config = _defaultConfig("Replay", "RPL");
        bytes memory signature = _sign(config, CREATOR_PK);

        vm.prank(RELAYER);
        hook.launch(config, signature);

        vm.prank(RELAYER);
        vm.expectRevert();
        hook.launch(config, signature);
    }

    /// @dev Replay is defeated by the configuration hash, not by the signature bytes, so re-signing the
    /// same configuration with a fresh deadline does not unlock a second launch either.
    function test_replayIsRejectedEvenWithAFreshSignature() public {
        LaunchConfig memory config = _defaultConfig("Fresh", "FRS");
        config.deadline = launchTime + 1 hours;

        _launchRelayed(config, RELAYER);

        config.deadline = launchTime + 2 hours;
        bytes memory reSigned = _sign(config, CREATOR_PK);

        vm.prank(RELAYER);
        vm.expectRevert();
        hook.launch(config, reSigned);
    }

    /// @dev And the creator cannot self-launch a configuration a relayer already landed, since both
    /// entries derive the identical salt.
    function test_theDirectPathCannotReplayARelayedLaunch() public {
        LaunchConfig memory config = _defaultConfig("Both", "BTH");

        _launchRelayed(config, RELAYER);

        vm.prank(creator);
        vm.expectRevert();
        hook.launch(config, "");
    }

    // --- Scenario: An expired signature is rejected ---

    function test_anExpiredSignatureIsRejected() public {
        LaunchConfig memory config = _defaultConfig("Expiring", "EXP");
        config.deadline = launchTime + 1 hours;
        bytes memory signature = _sign(config, CREATOR_PK);

        vm.warp(launchTime + 1 hours + 1);

        vm.prank(RELAYER);
        vm.expectRevert(
            abi.encodeWithSelector(
                LaunchSignature.SignatureExpired.selector, launchTime + 1 hours, launchTime + 1 hours + 1
            )
        );
        hook.launch(config, signature);
    }

    /// @dev The boundary itself is inside the window: the check is `block.timestamp > deadline`, so a
    /// launch landing in the deadline's own second succeeds.
    function test_aSignatureIsValidInItsDeadlineSecond() public {
        LaunchConfig memory config = _defaultConfig("Boundary", "BND");
        config.deadline = launchTime + 1 hours;
        bytes memory signature = _sign(config, CREATOR_PK);

        vm.warp(launchTime + 1 hours);

        vm.prank(RELAYER);
        (PoolId id,,) = hook.launch(config, signature);
        assertEq(hook.poolState(id).creator, creator, "the deadline second is still valid");
    }

    /// @dev The deadline binds only the relayed path. A creator's own transaction proves identity by
    /// origin, so there is no signature to expire and a lapsed deadline is irrelevant to it.
    function test_theDeadlineDoesNotBindTheDirectPath() public {
        LaunchConfig memory config = _defaultConfig("Lapsed", "LPS");
        config.deadline = launchTime + 1 hours;

        vm.warp(launchTime + 365 days);

        (PoolId id,,) = _launchDirect(config);
        assertEq(hook.poolState(id).creator, creator, "the direct path ignores the deadline");
    }

    // --- Scenario: Token address is knowable before launch ---

    /// @dev Derived from the published configuration alone — no signature, no recovery, and no launch
    /// transaction in existence. The prediction is taken before the launch and compared to what deploys.
    function test_tokenAddressIsKnowableBeforeLaunch() public {
        LaunchConfig memory config = _defaultConfig("Knowable", "KNW");

        address predicted = support.predictToken(config, HOOK_ADDR);
        assertTrue(predicted != address(0), "a prediction exists before the launch");
        assertEq(predicted.code.length, 0, "and nothing is deployed there yet");

        (,, MilestoneToken t) = _launchRelayed(config, RELAYER);

        assertEq(address(t), predicted, "the token landed at the advertised address");
    }

    /// @dev The prediction is stable across who relays it, because the salt binds the creator and the
    /// relayer appears nowhere in the derivation.
    function test_thePredictedAddressDoesNotDependOnTheRelayer() public {
        LaunchConfig memory config = _defaultConfig("Anyone", "ANY");

        address predicted = support.predictToken(config, HOOK_ADDR);

        (,, MilestoneToken t) = _launchRelayedSignedBy(config, STRANGER, CREATOR_PK);

        assertEq(address(t), predicted, "an unexpected relayer does not move the address");
    }

    // --- Scenario: A different signer cannot occupy the advertised address ---

    /// @dev Two halves. An imposter who signs the creator's configuration *as published* is rejected
    /// outright, because the declared creator is part of what the signature must match. An imposter who
    /// rewrites the declaration to themselves gets a launch — but a different token at a different
    /// address, credited to them — and the creator's advertised address is untouched and still available.
    function test_aDifferentSignerCannotOccupyTheAdvertisedAddress() public {
        LaunchConfig memory published = _defaultConfig("Contested", "CON");
        address advertised = support.predictToken(published, HOOK_ADDR);

        // The imposter signs the published configuration verbatim and relays it first.
        bytes memory imposterSignature = _sign(published, IMPOSTER_PK);
        vm.prank(imposter);
        vm.expectRevert(abi.encodeWithSelector(LaunchSignature.CreatorMismatch.selector, creator, imposter));
        hook.launch(published, imposterSignature);

        // So the imposter's only option is to claim the creator slot, which moves the address. Built
        // fresh rather than copied: a memory-to-memory struct assignment aliases in Solidity, and
        // mutating an alias here would rewrite the very configuration whose address is under test.
        LaunchConfig memory theirs = _defaultConfig("Contested", "CON");
        theirs.creator = imposter;
        (PoolId imposterPool,, MilestoneToken imposterToken) = _launchRelayedSignedBy(theirs, imposter, IMPOSTER_PK);

        assertTrue(address(imposterToken) != advertised, "a separate token at a different address");
        assertEq(hook.poolState(imposterPool).creator, imposter, "credited to the imposter");
        assertEq(advertised.code.length, 0, "the advertised address is still unoccupied");

        // And the creator's launch still lands exactly where it was advertised.
        (PoolId creatorPool,, MilestoneToken creatorToken) = _launchRelayed(published, RELAYER);

        assertEq(address(creatorToken), advertised, "the creator's address is unaffected");
        assertEq(hook.poolState(creatorPool).creator, creator, "and credited to the creator");
    }

    // --- Scenario: A re-signed configuration lands at the same address ---

    /// @dev The deadline is inside the EIP-712 struct hash but outside the configuration hash the salt is
    /// built from, so re-signing changes what verifies without moving where the token lands.
    function test_aReSignedConfigurationLandsAtTheSameAddress() public {
        LaunchConfig memory config = _defaultConfig("Patient", "PAT");
        config.deadline = launchTime + 1 hours;

        address advertised = support.predictToken(config, HOOK_ADDR);
        bytes32 firstConfigHash = support.configHash(config);
        bytes32 firstDigest = support.launchDigest(config, HOOK_ADDR);

        // The signature lapses unused.
        vm.warp(launchTime + 1 days);

        config.deadline = launchTime + 2 days;

        assertEq(support.configHash(config), firstConfigHash, "the configuration hash is unchanged");
        assertTrue(support.launchDigest(config, HOOK_ADDR) != firstDigest, "but the signed digest is not");
        assertEq(support.predictToken(config, HOOK_ADDR), advertised, "the address is unchanged");

        (,, MilestoneToken t) = _launchRelayed(config, RELAYER);
        assertEq(address(t), advertised, "and that is where it deploys");
    }

    // --- Scenario: Launch identity is unique per pool ---

    /// @dev Two launches from the same creator differing only in metadata: distinct tokens, distinct pool
    /// ids, and neither one's state readable as the other's.
    function test_launchIdentityIsUniquePerPool() public {
        (PoolId firstId,, MilestoneToken firstToken) = _launchRelayed(_defaultConfig("First", "ONE"), RELAYER);
        (PoolId secondId,, MilestoneToken secondToken) = _launchRelayed(_defaultConfig("Second", "TWO"), RELAYER);

        assertTrue(PoolId.unwrap(firstId) != PoolId.unwrap(secondId), "distinct pool ids");
        assertTrue(address(firstToken) != address(secondToken), "distinct tokens");
        assertEq(hook.poolState(firstId).token, address(firstToken), "each pool names its own token");
        assertEq(hook.poolState(secondId).token, address(secondToken), "and only its own");
    }

    // --- EIP-712 domain ---

    /// @dev The domain names the hook as `verifyingContract` even though the EIP-712 arithmetic lives on
    /// {LaunchSupport}: the satellite executes as the hook, and an immutable resolved from the satellite's
    /// own bytecode would name the wrong contract. Passing the address explicitly is what avoids that, and
    /// this pins it.
    function test_theDomainNamesTheHookAsVerifyingContract() public view {
        bytes32 expected = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("MilestoneLaunchpad"),
                keccak256("1"),
                block.chainid,
                HOOK_ADDR
            )
        );

        assertEq(support.domainSeparator(HOOK_ADDR), expected, "the hook is the verifying contract");
        assertTrue(support.domainSeparator(address(coldPaths)) != expected, "and the satellite's domain differs");
    }

    /// @dev A signature is bound to one chain, so a fork cannot replay it onto the other.
    function test_aSignatureIsBoundToItsChain() public {
        LaunchConfig memory config = _defaultConfig("Chained", "CHN");
        bytes memory signature = _sign(config, CREATOR_PK);

        vm.chainId(block.chainid + 1);

        vm.prank(RELAYER);
        vm.expectRevert();
        hook.launch(config, signature);
    }

    /// @dev And to one hook deployment, so a signature for another launchpad is not valid here.
    function test_aSignatureIsBoundToItsHook() public {
        LaunchConfig memory config = _defaultConfig("Bound", "BND");

        bytes32 wrongDomainDigest = support.launchDigest(config, address(coldPaths));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(CREATOR_PK, wrongDomainDigest);

        vm.prank(RELAYER);
        vm.expectRevert();
        hook.launch(config, abi.encodePacked(r, s, v));
    }

    // --- Signature shape ---

    /// @dev `ECDSA.recover` reverts on a malformed or malleable signature rather than resolving it to an
    /// unrelated address, so a garbage signature cannot become a launch under some arbitrary creator.
    function test_aMalformedSignatureIsRejected() public {
        LaunchConfig memory config = _defaultConfig("Garbage", "GBG");

        vm.prank(RELAYER);
        vm.expectRevert();
        hook.launch(config, hex"dead");

        vm.prank(RELAYER);
        vm.expectRevert();
        hook.launch(config, new bytes(65));
    }

    /// @dev An empty signature is not a malformed one — it selects the direct path. Worth pinning
    /// explicitly, because the two are one byte-length apart and confusing them would either lock
    /// creators out of self-launching or let a relayer bypass the signature entirely.
    function test_anEmptySignatureSelectsTheDirectPath() public {
        LaunchConfig memory config = _defaultConfig("Empty", "EMP");

        vm.prank(creator);
        (PoolId id,,) = hook.launch(config, "");

        assertEq(hook.poolState(id).creator, creator, "the empty signature took the sender's identity");
    }

    // --- Validation precedence ---

    /// @dev Configuration validity is checked before identity, so an out-of-bounds configuration reverts
    /// on the bound it breaks whoever submits it. This is the one ordering that matters: the alternative
    /// would report a signature problem for what is actually an invalid launch.
    function test_anInvalidConfigurationIsRejectedBeforeTheSignature() public {
        LaunchConfig memory config = _defaultConfig("Invalid", "INV");
        config.devBuyShareWad = 0.5e18; // above the 10% cap

        bytes memory signature = _sign(config, CREATOR_PK);

        vm.prank(RELAYER);
        vm.expectRevert(abi.encodeWithSignature("DevBuyAboveCap(uint64)", 0.5e18));
        hook.launch(config, signature);
    }
}
