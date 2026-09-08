// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MilestoneToken} from "./MilestoneToken.sol";
import {LaunchConfigLib} from "./libraries/LaunchConfigLib.sol";
import {LaunchSignature} from "./libraries/LaunchSignature.sol";
import {LaunchConfig} from "./types/LaunchTypes.sol";

/// @title LaunchSupport
/// @notice Stateless launch-time helpers, kept outside the hook purely to free bytecode.
///
/// @dev design.md names the singleton hook's 24 KB budget as the leading structural risk, and both of
/// these are large, self-contained, and called exactly once per launch — so moving them out costs a
/// call and buys room for protocol logic:
///
/// - {deploy}: `new MilestoneToken(...)` embeds the token's whole creation bytecode into whatever
///   contract contains the expression.
/// - {validate}: the bounds table never touches pool state, so it has no reason to occupy the hook.
///
/// This holds no state and grants no authority, so it is not a trust edge and not a protocol entry
/// point. Anyone may call either function; {deploy} produces an ordinary ERC20 whose supply goes to the
/// caller's chosen recipient, and {validate} only reverts or returns. The hook calls a fixed, immutable
/// address chosen at its own construction and independently verifies that the token supply reached it,
/// so a launch cannot be pointed at a counterfeit token.
///
/// **Why this contract is the CREATE2 deployer.** design Decision 19 requires the token address to be
/// derivable before the launch transaction exists. CREATE2 addresses depend on the deploying contract,
/// so the deployer has to be a fixed, published address — which this is, being immutable on the hook
/// from construction. An observer computes the address from this address, the salt, and the initcode;
/// none of the three needs protocol state.
contract LaunchSupport {
    /// @notice Deploys a launch token at a deterministic address with its entire supply minted to
    /// `recipient`.
    ///
    /// @dev Replay protection needs no bookkeeping anywhere in the protocol: the salt binds the
    /// configuration and its creator, so a second launch of the same configuration by the same creator
    /// resolves to an address that already holds code, and `new ... {salt}` reverts on that collision.
    function deploy(string calldata name, string calldata symbol, uint256 supply, address recipient, bytes32 salt)
        external
        returns (address token)
    {
        token = address(new MilestoneToken{salt: salt}(name, symbol, supply, recipient));
    }

    /// @notice The address {deploy} will produce for these arguments.
    /// @dev Pure with respect to protocol state, so a front-end can advertise a token's address from a
    /// published configuration and signature alone: recover the signer, derive the salt, call this.
    function predict(string memory name, string memory symbol, uint256 supply, address recipient, bytes32 salt)
        public
        view
        returns (address)
    {
        bytes32 initCodeHash =
            keccak256(abi.encodePacked(type(MilestoneToken).creationCode, abi.encode(name, symbol, supply, recipient)));

        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, initCodeHash)))));
    }

    /// @notice Reverts unless the configuration satisfies every protocol bound.
    /// @dev Errors surface with `LaunchConfigLib` selectors, so callers and tests see the specific bound
    /// that failed rather than a generic rejection.
    function validate(LaunchConfig calldata config) external pure {
        LaunchConfigLib.validate(config);
    }

    // --- Observer helpers for the signed-launch flow (design Decision 19) ---
    //
    // These live here rather than on the hook for the same reason {deploy} and {validate} do: compiling
    // the EIP-712 body into the hot half cost it roughly a kilobyte it does not have, and nothing on the
    // swap path needs any of it. Taking the hook address as a parameter is what makes that possible —
    // the domain names the hook as its verifying contract, but the arithmetic does not care where it runs.

    /// @notice The configuration hash the CREATE2 salt is derived from — the deadline excluded.
    function configHash(LaunchConfig calldata config) external pure returns (bytes32) {
        return LaunchSignature.configHash(config);
    }

    /// @notice The EIP-712 domain separator for a hook deployment on this chain.
    function domainSeparator(address hook) external view returns (bytes32) {
        return LaunchSignature.domainSeparator(hook);
    }

    /// @notice The digest a creator signs to authorise `config` against `hook`.
    function launchDigest(LaunchConfig calldata config, address hook) external view returns (bytes32) {
        return LaunchSignature.digest(config, hook);
    }

    /// @notice The address `config`'s token will deploy to when launched against `hook`.
    /// @dev The "knowable before launch" property, answerable from the published configuration alone.
    /// No signature is needed and none is recovered: the configuration declares its creator, and the
    /// launch path refuses to proceed unless the signature matches that declaration, so the declaration
    /// is as good as a recovery for address purposes and is available strictly earlier.
    function predictToken(LaunchConfig calldata config, address hook) external view returns (address) {
        return predict(
            config.name,
            config.symbol,
            config.totalSupply,
            hook,
            LaunchSignature.tokenSalt(LaunchSignature.configHash(config), config.creator)
        );
    }
}
