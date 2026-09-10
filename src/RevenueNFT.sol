// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";

/// @title RevenueNFT
/// @notice One transferable NFT per launch, representing the creator's revenue stream. The claimable
/// balance itself lives in the hook, keyed by pool; this contract answers only "who owns the stream
/// right now". The hook gates claims on `ownerOf`, which is what makes the stream tradeable.
///
/// @dev A single shared collection across all launches, not one contract per launch: `tokenId` is
/// the `PoolId`, so identity is already unique without deploying anything per pool.
contract RevenueNFT is ERC721 {
    /// @notice Deployer, retained only to wire the minter once at deployment.
    address public immutable deployer;

    /// @notice The launch hook, and the only address that may mint. Set once, then permanent.
    address public minter;

    event MinterSet(address indexed minter);

    error NotDeployer();
    error MinterAlreadySet();
    error ZeroMinter();
    error MinterNotSet();
    error NotMinter();
    error AlreadyMinted(uint256 tokenId);
    error ZeroRecipient();

    constructor() ERC721("Spawn Launchpad Revenue", "SPNREV") {
        deployer = msg.sender;
    }

    /// @notice Wires the authorised minter. Callable once, by the deployer, per the design's
    /// Migration Plan ordering (NFT first, then hook, then wire).
    /// @dev One-shot by construction: once `minter` is non-zero this always reverts, so the
    /// deployer retains no ongoing authority over the collection. This keeps the contract inside
    /// design Decision 10's "minimal protocol authority" boundary.
    function setMinter(address minter_) external {
        if (msg.sender != deployer) revert NotDeployer();
        if (minter != address(0)) revert MinterAlreadySet();
        if (minter_ == address(0)) revert ZeroMinter();

        minter = minter_;
        emit MinterSet(minter_);
    }

    /// @notice Mints the revenue NFT for a pool to its creator. Exactly one per pool, ever.
    /// @dev Uses `_mint`, not `_safeMint`, on purpose. `_safeMint` invokes
    /// `onERC721Received` on the recipient, which during a launch would hand control to
    /// creator-supplied code in the middle of pool initialisation and curve minting — a reentrancy
    /// vector into the launch path. Creators receiving to a contract are responsible for that
    /// contract being able to hold an ERC721.
    function mint(PoolId poolId, address to) external returns (uint256 tokenId) {
        if (minter == address(0)) revert MinterNotSet();
        if (msg.sender != minter) revert NotMinter();
        if (to == address(0)) revert ZeroRecipient();

        tokenId = tokenIdOf(poolId);
        if (_ownerOf(tokenId) != address(0)) revert AlreadyMinted(tokenId);

        _mint(to, tokenId);
    }

    /// @notice The one-to-one mapping from pool to token id.
    function tokenIdOf(PoolId poolId) public pure returns (uint256) {
        return uint256(PoolId.unwrap(poolId));
    }

    /// @notice Inverse of {tokenIdOf}, which is what makes the mapping one-to-one rather than
    /// merely deterministic.
    function poolIdOf(uint256 tokenId) public pure returns (PoolId) {
        return PoolId.wrap(bytes32(tokenId));
    }

    /// @notice Whether this pool's revenue NFT has been minted yet.
    function exists(PoolId poolId) external view returns (bool) {
        return _ownerOf(tokenIdOf(poolId)) != address(0);
    }
}
