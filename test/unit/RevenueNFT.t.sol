// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {RevenueNFT} from "../../src/RevenueNFT.sol";

/// @notice Unit tests for task 2.2, covering the `revenue-claims` spec scenarios
/// "NFT is minted to the creator at launch", "NFT identity maps to the pool",
/// "NFT is freely transferable", and "No second NFT is issued for a pool".
contract RevenueNFTTest is Test {
    RevenueNFT internal nft;

    address internal constant HOOK = address(0xBEEF);
    address internal constant CREATOR = address(0xC0FFEE);
    address internal constant BUYER = address(0xB0B);
    address internal constant STRANGER = address(0xDEAD);

    PoolId internal constant POOL_A = PoolId.wrap(bytes32(uint256(0xA1)));
    PoolId internal constant POOL_B = PoolId.wrap(bytes32(uint256(0xB2)));

    function setUp() public {
        nft = new RevenueNFT();
        nft.setMinter(HOOK);
    }

    // --- Minter wiring ---

    function test_minterIsWiredOnce() public view {
        assertEq(nft.minter(), HOOK, "minter wired");
        assertEq(nft.deployer(), address(this), "deployer recorded");
    }

    function test_setMinterIsOneShot() public {
        vm.expectRevert(RevenueNFT.MinterAlreadySet.selector);
        nft.setMinter(STRANGER);

        assertEq(nft.minter(), HOOK, "minter unchanged");
    }

    function test_setMinterRejectsNonDeployer() public {
        RevenueNFT fresh = new RevenueNFT();

        vm.prank(STRANGER);
        vm.expectRevert(RevenueNFT.NotDeployer.selector);
        fresh.setMinter(STRANGER);
    }

    function test_setMinterRejectsZero() public {
        RevenueNFT fresh = new RevenueNFT();

        vm.expectRevert(RevenueNFT.ZeroMinter.selector);
        fresh.setMinter(address(0));
    }

    function test_mintBeforeMinterWiredReverts() public {
        RevenueNFT fresh = new RevenueNFT();

        vm.prank(HOOK);
        vm.expectRevert(RevenueNFT.MinterNotSet.selector);
        fresh.mint(POOL_A, CREATOR);
    }

    // --- Scenario: NFT is minted to the creator at launch ---

    function test_mintToCreator() public {
        vm.prank(HOOK);
        uint256 tokenId = nft.mint(POOL_A, CREATOR);

        assertEq(nft.ownerOf(tokenId), CREATOR, "creator owns the stream");
        assertEq(nft.balanceOf(CREATOR), 1, "exactly one token");
        assertTrue(nft.exists(POOL_A), "pool has a revenue NFT");
    }

    function test_onlyMinterCanMint() public {
        vm.prank(STRANGER);
        vm.expectRevert(RevenueNFT.NotMinter.selector);
        nft.mint(POOL_A, CREATOR);

        // Not even the deployer, once the minter is wired.
        vm.expectRevert(RevenueNFT.NotMinter.selector);
        nft.mint(POOL_A, CREATOR);

        assertFalse(nft.exists(POOL_A), "nothing minted");
    }

    function test_mintRejectsZeroRecipient() public {
        vm.prank(HOOK);
        vm.expectRevert(RevenueNFT.ZeroRecipient.selector);
        nft.mint(POOL_A, address(0));
    }

    // --- Scenario: NFT identity maps to the pool ---

    function test_tokenIdDerivesFromPoolId() public view {
        assertEq(nft.tokenIdOf(POOL_A), uint256(PoolId.unwrap(POOL_A)), "tokenId is the poolId");
    }

    function testFuzz_poolIdRoundTripsThroughTokenId(bytes32 raw) public view {
        PoolId poolId = PoolId.wrap(raw);
        uint256 tokenId = nft.tokenIdOf(poolId);

        assertEq(PoolId.unwrap(nft.poolIdOf(tokenId)), raw, "round trip is the identity");
    }

    /// @dev One-to-one, not merely deterministic: distinct pools never collide.
    function testFuzz_distinctPoolsGiveDistinctTokenIds(bytes32 rawA, bytes32 rawB) public view {
        vm.assume(rawA != rawB);

        assertTrue(nft.tokenIdOf(PoolId.wrap(rawA)) != nft.tokenIdOf(PoolId.wrap(rawB)), "distinct pools, distinct ids");
    }

    // --- Scenario: No second NFT is issued for a pool ---

    function test_secondMintForSamePoolReverts() public {
        vm.prank(HOOK);
        uint256 tokenId = nft.mint(POOL_A, CREATOR);

        vm.prank(HOOK);
        vm.expectRevert(abi.encodeWithSelector(RevenueNFT.AlreadyMinted.selector, tokenId));
        nft.mint(POOL_A, CREATOR);

        assertEq(nft.balanceOf(CREATOR), 1, "still exactly one");
    }

    function test_secondMintRevertsEvenToADifferentRecipient() public {
        vm.prank(HOOK);
        uint256 tokenId = nft.mint(POOL_A, CREATOR);

        vm.prank(HOOK);
        vm.expectRevert(abi.encodeWithSelector(RevenueNFT.AlreadyMinted.selector, tokenId));
        nft.mint(POOL_A, BUYER);
    }

    function test_secondMintRevertsAfterTransfer() public {
        vm.prank(HOOK);
        uint256 tokenId = nft.mint(POOL_A, CREATOR);

        vm.prank(CREATOR);
        nft.transferFrom(CREATOR, BUYER, tokenId);

        vm.prank(HOOK);
        vm.expectRevert(abi.encodeWithSelector(RevenueNFT.AlreadyMinted.selector, tokenId));
        nft.mint(POOL_A, CREATOR);
    }

    function test_differentPoolsMintIndependently() public {
        vm.prank(HOOK);
        uint256 idA = nft.mint(POOL_A, CREATOR);
        vm.prank(HOOK);
        uint256 idB = nft.mint(POOL_B, BUYER);

        assertTrue(idA != idB, "distinct token ids");
        assertEq(nft.ownerOf(idA), CREATOR, "pool A owner");
        assertEq(nft.ownerOf(idB), BUYER, "pool B owner");
    }

    // --- Scenario: NFT is freely transferable ---

    function test_holderCanTransfer() public {
        vm.prank(HOOK);
        uint256 tokenId = nft.mint(POOL_A, CREATOR);

        vm.prank(CREATOR);
        nft.transferFrom(CREATOR, BUYER, tokenId);

        assertEq(nft.ownerOf(tokenId), BUYER, "new holder");
        assertEq(nft.balanceOf(CREATOR), 0, "old holder has none");
        assertEq(nft.balanceOf(BUYER), 1, "new holder has one");
    }

    function test_transferNeedsNoProtocolApproval() public {
        vm.prank(HOOK);
        uint256 tokenId = nft.mint(POOL_A, CREATOR);

        // No lockup, no protocol allowlist, no minter involvement: the holder acts alone.
        vm.prank(CREATOR);
        nft.transferFrom(CREATOR, BUYER, tokenId);
        assertEq(nft.ownerOf(tokenId), BUYER, "transferred without protocol involvement");
    }

    function test_operatorApprovalWorks() public {
        vm.prank(HOOK);
        uint256 tokenId = nft.mint(POOL_A, CREATOR);

        vm.prank(CREATOR);
        nft.setApprovalForAll(BUYER, true);

        vm.prank(BUYER);
        nft.transferFrom(CREATOR, BUYER, tokenId);
        assertEq(nft.ownerOf(tokenId), BUYER, "operator moved it");
    }

    function test_nonHolderCannotTransfer() public {
        vm.prank(HOOK);
        uint256 tokenId = nft.mint(POOL_A, CREATOR);

        vm.prank(STRANGER);
        vm.expectRevert();
        nft.transferFrom(CREATOR, STRANGER, tokenId);

        assertEq(nft.ownerOf(tokenId), CREATOR, "owner unchanged");
    }

    /// @dev Repeated transfers keep working; nothing in the protocol freezes the stream.
    function test_streamCanChangeHandsRepeatedly() public {
        vm.prank(HOOK);
        uint256 tokenId = nft.mint(POOL_A, CREATOR);

        address[3] memory chain = [BUYER, STRANGER, CREATOR];
        address from = CREATOR;
        for (uint256 i = 0; i < chain.length; i++) {
            vm.prank(from);
            nft.transferFrom(from, chain[i], tokenId);
            assertEq(nft.ownerOf(tokenId), chain[i], "hop landed");
            from = chain[i];
        }
    }

    // --- Metadata / standard conformance ---

    function test_metadataAndInterfaces() public view {
        assertEq(nft.name(), "Spawn Launchpad Revenue", "name");
        assertEq(nft.symbol(), "SPNREV", "symbol");
        assertTrue(nft.supportsInterface(0x80ac58cd), "ERC721");
        assertTrue(nft.supportsInterface(0x5b5e139f), "ERC721Metadata");
        assertTrue(nft.supportsInterface(0x01ffc9a7), "ERC165");
    }

    function test_ownerOfUnmintedReverts() public {
        // Resolve the id first: vm.expectRevert arms the *next* call, and an inner
        // tokenIdOf(...) evaluated as an argument would consume it.
        uint256 tokenId = nft.tokenIdOf(POOL_A);

        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, tokenId));
        nft.ownerOf(tokenId);
    }

    function test_existsIsFalseBeforeMint() public view {
        assertFalse(nft.exists(POOL_A), "no NFT yet");
    }
}
