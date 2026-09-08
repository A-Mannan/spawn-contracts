// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {HarvestSplit, LaunchConfig} from "../types/LaunchTypes.sol";

/// @title LaunchSignature
/// @notice EIP-712 hashing, signer recovery, and CREATE2 salt derivation for signed-config launches.
///
/// @dev design Decision 19. The creator signs the configuration off-chain and *anyone* may relay it —
/// the pump.fun posture, where creating a token costs the creator nothing and deployment timing is
/// whoever wants the market first. Decision 20's removal of the anti-snipe decay is what makes that
/// safe: with no wall re-arming at genesis, deployment timing is economically inert.
///
/// Three properties are load-bearing and each falls out of the hashing scheme rather than out of a
/// check somewhere:
///
/// - **A relayer cannot alter a single parameter.** The configuration declares its own creator and the
///   signature is checked against that declaration, so any edit changes {structHash}, recovers some other
///   address, and reverts as `CreatorMismatch`. Inferring the creator from recovery instead would make an
///   edited configuration *launch*, credited to whatever address fell out of the recovery.
/// - **The token address is knowable before launch, and reserved for the creator.** The CREATE2 salt is
///   `keccak256(configHash, creator)`, and `configHash` itself covers the declared creator — so the
///   address follows from the published configuration with no signature to recover from. Without the
///   identity binding, a griefer could sign the published configuration with their own key, relay first,
///   and occupy the very address every token page displays. With it, the same economics under a different
///   creator is a separate token at a separate address.
/// - **A lapsed signature can be re-signed without moving the address.** The deadline is inside
///   {structHash} but deliberately outside {configHash}, so a fresh deadline changes what verifies and
///   not where the token lands.
///
/// Replay protection needs no nonce and no consumed-signature set: the same configuration and the same
/// signer produce the same salt, so a second launch collides with the deployed token and reverts.
library LaunchSignature {
    bytes32 private constant _EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    bytes32 private constant _DOMAIN_NAME_HASH = keccak256("MilestoneLaunchpad");
    bytes32 private constant _DOMAIN_VERSION_HASH = keccak256("1");

    bytes32 private constant _HARVEST_SPLIT_TYPEHASH =
        keccak256("HarvestSplit(uint64 creatorWad,uint64 buybackWad,uint64 protocolWad,uint64 lpWad)");

    /// @dev EIP-712 requires referenced struct types to follow the primary type in alphabetical order,
    /// which for a single reference means `HarvestSplit` is appended verbatim.
    bytes32 private constant _LAUNCH_CONFIG_TYPEHASH = keccak256(
        "LaunchConfig(address creator,string name,string symbol,uint256 totalSupply,uint64 devBuyShareWad,uint32 devBuyVestingSeconds,HarvestSplit harvestSplit,uint256 deadline)HarvestSplit(uint64 creatorWad,uint64 buybackWad,uint64 protocolWad,uint64 lpWad)"
    );

    /// @notice Thrown when a relayed launch arrives after its signature's deadline.
    error SignatureExpired(uint256 deadline, uint256 now_);

    /// @notice Thrown when recovery yields the zero address, which no signer can be.
    error InvalidSignature();

    /// @notice Thrown when the signature does not belong to the configuration's declared creator.
    error CreatorMismatch(address declared, address recovered);

    /// @notice The domain separator naming `verifyingContract` as the domain.
    ///
    /// @dev Computed rather than cached in an immutable, and taking the address explicitly rather than
    /// reading `address(this)`. Both choices are forced by the delegatecall split: an immutable would
    /// resolve from the *satellite's* bytecode while the satellite executes, naming the wrong verifying
    /// contract, and an implicit `address(this)` would make this library unusable from the off-hook
    /// helper that answers "what will the creator sign?". The hook always passes its own address.
    ///
    /// The chain id is read live, so a fork cannot replay a signature onto the other chain.
    function domainSeparator(address verifyingContract) internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                _EIP712_DOMAIN_TYPEHASH, _DOMAIN_NAME_HASH, _DOMAIN_VERSION_HASH, block.chainid, verifyingContract
            )
        );
    }

    /// @notice The configuration's identity, excluding the deadline.
    /// @dev This is what the CREATE2 salt binds, so it is what makes an address stable across
    /// re-signing. Strings are hashed rather than concatenated so no two distinct configurations can
    /// collide by field-boundary ambiguity.
    ///
    /// `creator` is inside this hash, which is what makes the token address derivable from the
    /// configuration *alone* — an observer needs no signature to recover from. It also means two
    /// creators who publish byte-identical economics still occupy distinct addresses.
    function configHash(LaunchConfig memory config) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                config.creator,
                keccak256(bytes(config.name)),
                keccak256(bytes(config.symbol)),
                config.totalSupply,
                config.devBuyShareWad,
                config.devBuyVestingSeconds,
                harvestSplitHash(config.harvestSplit)
            )
        );
    }

    /// @notice The EIP-712 struct hash of a configuration, including its deadline.
    function structHash(LaunchConfig memory config) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                _LAUNCH_CONFIG_TYPEHASH,
                config.creator,
                keccak256(bytes(config.name)),
                keccak256(bytes(config.symbol)),
                config.totalSupply,
                config.devBuyShareWad,
                config.devBuyVestingSeconds,
                harvestSplitHash(config.harvestSplit),
                config.deadline
            )
        );
    }

    function harvestSplitHash(HarvestSplit memory split) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(_HARVEST_SPLIT_TYPEHASH, split.creatorWad, split.buybackWad, split.protocolWad, split.lpWad)
        );
    }

    /// @notice The full EIP-712 digest a creator signs, for `verifyingContract`'s domain.
    function digest(LaunchConfig memory config, address verifyingContract) internal view returns (bytes32) {
        return keccak256(abi.encodePacked(hex"1901", domainSeparator(verifyingContract), structHash(config)));
    }

    /// @notice Verifies a signed configuration against its declared creator, enforcing the deadline.
    ///
    /// @dev Returns `config.creator` rather than the recovered address, because the two are asserted
    /// equal. That assertion is what makes "a relayer cannot alter the configuration" a *revert* rather
    /// than a misattribution. With an inferred creator, editing a field would change {structHash}, yield
    /// some unrelated address, and launch a perfectly valid token credited to that address — the edit
    /// would succeed, silently, against a creator who never agreed to it. Comparing against a declared
    /// field turns every such edit into `CreatorMismatch`.
    ///
    /// `ECDSA.recover` rejects malleable and malformed signatures by reverting, so a bad signature cannot
    /// silently resolve to some unrelated address either.
    function recoverCreator(LaunchConfig memory config, bytes memory signature, address verifyingContract)
        internal
        view
        returns (address)
    {
        if (block.timestamp > config.deadline) revert SignatureExpired(config.deadline, block.timestamp);

        address signer = ECDSA.recover(digest(config, verifyingContract), signature);
        if (signer == address(0)) revert InvalidSignature();
        if (signer != config.creator) revert CreatorMismatch(config.creator, signer);

        return signer;
    }

    /// @notice The CREATE2 salt for a configuration launched by `creator`.
    /// @dev Both launch entries feed this same formula — a relayed signature's verified signer and a
    /// creator-direct transaction's sender — so a creator who publishes a signed configuration and
    /// later self-launches deploys to the advertised address either way.
    ///
    /// `creator` is already inside `configHash_`; passing it again is redundant arithmetic kept for the
    /// property it states at every call site, that no salt is ever derived without binding an identity.
    function tokenSalt(bytes32 configHash_, address creator) internal pure returns (bytes32) {
        return keccak256(abi.encode(configHash_, creator));
    }
}
