// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title MilestoneToken
/// @notice The plain ERC20 deployed once per launch. The entire supply is minted to the launch
/// hook at construction; the hook is the sole custodian from that moment on.
///
/// @dev Deliberate omissions, each traceable to the `token-launch` spec:
/// - No mint path of any kind after construction ("Supply is fixed after launch"). There is no
///   owner, no minter role, and no upgrade path that could introduce one.
/// - No transfer hooks, fee-on-transfer, blocklist, pause, or allowlist
///   ("Token behaves as a standard ERC20"). Transfers are exactly OZ's implementation.
/// - No EIP-2612 `permit`. `DESIGN.md §3` marks Permit2 support optional; Permit2 already works
///   against any plain ERC20 through a one-time approval, so a permit surface would add
///   signature-replay exposure without enabling anything new.
contract MilestoneToken is ERC20 {
    /// @notice The launch hook that received the entire supply at construction.
    address public immutable hook;

    /// @notice Supply minted at construction. Total supply can only ever fall from here, via burn.
    uint256 public immutable initialSupply;

    error ZeroHook();
    error ZeroSupply();

    constructor(string memory name_, string memory symbol_, uint256 supply_, address hook_) ERC20(name_, symbol_) {
        if (hook_ == address(0)) revert ZeroHook();
        if (supply_ == 0) revert ZeroSupply();

        hook = hook_;
        initialSupply = supply_;
        _mint(hook_, supply_);
    }

    /// @notice Burns tokens held by the caller, reducing total supply.
    /// @dev Required by the `milestone-ladder` scenario "Buyback reduces total supply": the hook
    /// buys the token with the harvest's buyback share and then burns what it bought. Scoped to the
    /// caller's own balance — there is no allowance-spending `burnFrom`, so no third party can
    /// destroy someone else's tokens.
    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }
}
