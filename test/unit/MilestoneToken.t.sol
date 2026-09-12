// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MilestoneToken} from "../../src/MilestoneToken.sol";

/// @notice Unit tests for add-payout-plugins task 5.4, covering the `token-launch` spec scenarios
/// "Protocol initially receives the full minted supply", "Supply is fixed after launch", and
/// "Token remains standard ERC20".
contract MilestoneTokenTest is Test {
    MilestoneToken internal token;

    address internal constant HOOK = address(0xBEEF);
    address internal constant CREATOR = address(0xC0FFEE);
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);

    uint256 internal constant SUPPLY = 1_000_000_000 ether;

    function setUp() public {
        token = new MilestoneToken("Milestone", "MILE", "https://example.test/mile.json", SUPPLY, HOOK);
    }

    /// @dev Asserts a selector is not callable on the token: with no matching function and no
    /// fallback, the call must revert.
    function _assertNotCallable(bytes memory payload, string memory reason) internal {
        (bool ok,) = address(token).call(payload);
        assertFalse(ok, reason);
    }

    // --- Scenario: Protocol initially receives the full minted supply ---

    function test_protocolInitiallyReceivesTheFullMintedSupply() public view {
        assertEq(token.totalSupply(), SUPPLY, "total supply");
        assertEq(token.balanceOf(HOOK), SUPPLY, "hook holds everything");
        assertEq(token.hook(), HOOK, "hook recorded");
        assertEq(token.initialSupply(), SUPPLY, "initial supply recorded");
    }

    function test_creatorHoldsNothingAtLaunch() public view {
        assertEq(token.balanceOf(CREATOR), 0, "creator balance is zero");
        assertEq(token.balanceOf(address(this)), 0, "deployer balance is zero");
    }

    function testFuzz_fullSupplyHeldByHook(uint256 supply, address hook) public {
        vm.assume(supply > 0);
        vm.assume(hook != address(0));

        MilestoneToken t = new MilestoneToken("N", "S", "", supply, hook);
        assertEq(t.balanceOf(hook), supply, "hook holds everything");
        assertEq(t.totalSupply(), supply, "supply matches");
    }

    function test_rejectsZeroHook() public {
        vm.expectRevert(MilestoneToken.ZeroHook.selector);
        new MilestoneToken("N", "S", "", SUPPLY, address(0));
    }

    function test_rejectsZeroSupply() public {
        vm.expectRevert(MilestoneToken.ZeroSupply.selector);
        new MilestoneToken("N", "S", "", 0, HOOK);
    }

    // --- Scenario: Supply is fixed after launch ---

    /// @dev There is no mint entry point at all. Probing the conventional selectors proves it.
    function test_noMintPathExists() public {
        uint256 before = token.totalSupply();

        _assertNotCallable(abi.encodeWithSignature("mint(address,uint256)", ALICE, 1 ether), "no mint(address,uint256)");
        _assertNotCallable(abi.encodeWithSignature("mint(uint256)", 1 ether), "no mint(uint256)");
        _assertNotCallable(abi.encodeWithSignature("mint(address)", ALICE), "no mint(address)");

        assertEq(token.totalSupply(), before, "total supply unchanged");
    }

    function test_noPrivilegedRoleExists() public {
        _assertNotCallable(abi.encodeWithSignature("owner()"), "no owner()");
        _assertNotCallable(abi.encodeWithSignature("minter()"), "no minter()");
        _assertNotCallable(abi.encodeWithSignature("transferOwnership(address)", ALICE), "no transferOwnership");
        _assertNotCallable(abi.encodeWithSignature("setMinter(address)", ALICE), "no setMinter");
        _assertNotCallable(abi.encodeWithSignature("pause()"), "no pause");
    }

    // --- Burn: required by the ladder's buyback, scoped to the caller ---

    function test_burnReducesTotalSupply() public {
        vm.prank(HOOK);
        token.burn(100 ether);

        assertEq(token.totalSupply(), SUPPLY - 100 ether, "supply fell by the burn");
        assertEq(token.balanceOf(HOOK), SUPPLY - 100 ether, "hook balance fell by the burn");
    }

    function test_burnCannotExceedOwnBalance() public {
        vm.prank(ALICE);
        vm.expectRevert();
        token.burn(1 ether);
    }

    function test_noBurnFromPathExists() public {
        vm.prank(HOOK);
        token.transfer(ALICE, 10 ether);

        // A third party must not destroy Alice's tokens even holding an allowance.
        vm.prank(ALICE);
        token.approve(BOB, 10 ether);

        _assertNotCallable(abi.encodeWithSignature("burnFrom(address,uint256)", ALICE, 10 ether), "no burnFrom");
        assertEq(token.balanceOf(ALICE), 10 ether, "alice keeps her tokens");
    }

    // --- Scenario: Token remains standard ERC20 ---

    function test_metadata() public view {
        assertEq(token.name(), "Milestone", "name");
        assertEq(token.symbol(), "MILE", "symbol");
        assertEq(token.decimals(), 18, "decimals");
        // The URI is part of the same launch metadata: stored once at construction, never editable.
        assertEq(token.tokenURI(), "https://example.test/mile.json", "uri");
    }

    // --- Token URI is fixed at launch: derived, no scenario of its own ---

    function test_tokenUriIsNotEditable() public {
        // There is no setter at all: the only address holding the URI is the token's own storage,
        // and no function writes it after construction. Prove the absence against the selector space.
        (bool ok,) =
            address(token).call(abi.encodeWithSignature("setTokenURI(string)", "https://evil.test/rewritten.json"));
        assertFalse(ok, "a URI setter exists");
        assertEq(token.tokenURI(), "https://example.test/mile.json", "uri changed");
    }

    function test_transferMovesExactAmount() public {
        vm.prank(HOOK);
        token.transfer(ALICE, 100 ether);

        // No tax, no skim: the recipient gets exactly what was sent.
        assertEq(token.balanceOf(ALICE), 100 ether, "no transfer tax");
        assertEq(token.balanceOf(HOOK), SUPPLY - 100 ether, "sender debited exactly");
        assertEq(token.totalSupply(), SUPPLY, "transfers do not change supply");
    }

    function test_approveAndTransferFrom() public {
        vm.prank(HOOK);
        token.transfer(ALICE, 100 ether);

        vm.prank(ALICE);
        token.approve(BOB, 40 ether);
        assertEq(token.allowance(ALICE, BOB), 40 ether, "allowance set");

        vm.prank(BOB);
        token.transferFrom(ALICE, BOB, 40 ether);

        assertEq(token.balanceOf(BOB), 40 ether, "bob received");
        assertEq(token.balanceOf(ALICE), 60 ether, "alice debited");
        assertEq(token.allowance(ALICE, BOB), 0, "allowance consumed");
    }

    function test_transferFromWithoutAllowanceReverts() public {
        vm.prank(HOOK);
        token.transfer(ALICE, 100 ether);

        vm.prank(BOB);
        vm.expectRevert();
        token.transferFrom(ALICE, BOB, 1 ether);
    }

    function test_transferBeyondBalanceReverts() public {
        vm.prank(ALICE);
        vm.expectRevert();
        token.transfer(BOB, 1 ether);
    }

    /// @dev No address is privileged or blocked in transfers.
    function testFuzz_anyHolderCanTransfer(address to, uint256 amount) public {
        vm.assume(to != address(0) && to != HOOK);
        amount = bound(amount, 1, SUPPLY);

        vm.prank(HOOK);
        token.transfer(to, amount);
        assertEq(token.balanceOf(to), amount, "arbitrary recipient credited");

        vm.prank(to);
        token.transfer(HOOK, amount);
        assertEq(token.balanceOf(to), 0, "arbitrary holder can send back");
    }
}
