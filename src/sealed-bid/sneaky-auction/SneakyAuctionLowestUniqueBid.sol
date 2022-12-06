// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import "solmate/tokens/ERC721.sol";
import "solmate/utils/ReentrancyGuard.sol";
import "./ISneakyAuctionErrors.sol";
import "./LibBalanceProof.sol";
import "./SneakyVault.sol";

// In this modified version, the `highestBid` and `secondHighestBid` fields have been replaced with `lowestBid` and `secondLowestBid`, respectively. Additionally, the `highestBidVault` field has been renamed to `lowestBidVault`.

// The `revealBid` function has been updated to compare the bid value to the `lowestBid` and `secondLowestBid` fields instead of the `highestBid` and `secondHighestBid` fields. If the bid value is lower than the `lowestBid`, then it becomes the new `lowestBid` and the previous `lowestBid` becomes the `secondLowestBid`. Otherwise, if the bid value is higher than the `lowestBid` but lower than the `secondLowestBid`, then it becomes the new `secondLowestBid`.

// The `finalizeAuction` function has also been updated to transfer the winning bid to the seller from the `lowestBidVault` instead of the `highestBidVault`.

contract SneakyAuctionLowestUniqueBid is ISneakyAuctionErrors, ReentrancyGuard {
    /// @notice The base unit for bids. The reserve price and bid value parameters
    ///         for this contract's functions are denominated in this base unit,
    ///         _not_ wei. 1000 gwei = 1e12 wei.
    uint256 public constant BID_BASE_UNIT = 1000 gwei;

    /// @dev Representation of an auction in storage. Occupies three slots.
    /// @param seller The address selling the auctioned asset.
    /// @param endOfBiddingPeriod The unix timestamp after which bids can no
    ///        longer be placed.
    /// @param endOfRevealPeriod The unix timestamp after which commitments can
    ///        no longer be opened.
    /// @param index Auctions selling the same asset (i.e. tokenContract-tokenId
    ///        pair) share the same storage. This value is incremented for
    ///        each new auction of a particular asset.
    /// @param lowestBid The value of the lowest bid revealed so far, or
    ///        the reserve price if no bids have reached it. In bid base units
    ///        (1000 gwei).
    /// @param secondHighestBid The value of the second-lowest bid revealed
    ///        so far, or the reserve price if no two bids have reached it.
    ///        In bid base units (1000 gwei).
    /// @param lowestBidVault The address of the `SneakyVault` containing the
    ///        the collateral for the lowest unique bid.
    /// @param collateralizationDeadlineBlockHash The hash of the block considered
    ///        to be the deadline for collateralization. This is set when the first
    ///        bid is revealed, and all other bids must have been collateralized
    ///        before the deadline block.
    
    struct Auction {
        address seller;
        uint32 endOfBiddingPeriod;
        uint32 endOfRevealPeriod;
        uint32 index;
        // =====================
        uint48 lowestUniqueBid;
        uint48 secondLowestUniqueBid;
        address lowestUniqueBidVault;
        mapping(uint48 => uint) numBids;

        // =====================
        bytes32 collateralizationDeadlineBlockHash;
    }

    /// @dev A Merkle proof and block header, in conjunction with the
    ///      stored `collateralizationDeadlineBlockHash` for an auction,
    ///      is used to prove that a bidder's `SneakyVault` was sufficiently
    ///      collateralized by the time the first bid was revealed.
    /// @param accountMerkleProof The Merkle proof of a particular account's
    ///        state, as returned by the `eth_getProof` RPC method.
    /// @param blockHeaderRLP The RLP-encoded header of the block
    ///        for which the account balance is being proven.
    struct CollateralizationProof {
        bytes[] accountMerkleProof;
        bytes blockHeaderRLP;
    }

    /// @notice Emitted when an auction is created.
    /// @param tokenContract The address of the ERC721 contract for the asset
    ///        being auctioned.
    /// @param tokenId The ERC721 token ID of the asset being auctioned.
    /// @param seller The address selling the auctioned asset.
    /// @param bidPeriod The duration of the bidding period, in seconds.
    /// @param revealPeriod The duration of the commitment reveal period,
    ///        in seconds.
    /// @param reservePrice The minimum price (in wei) that the asset will be sold
    ///        for. If not bids exceed this price, the asset is returned to `seller`.
    event AuctionCreated(
        address tokenContract,
        uint256 tokenId,
        address seller,
        uint32 bidPeriod,
        uint32 revealPeriod,
        uint256 reservePrice
    );

    /// @notice Emitted when a bid is revealed.
    /// @param tokenContract The address of the ERC721 contract for the asset
    ///        being auctioned.
    /// @param tokenId The ERC721 token ID of the asset being auctioned.
    /// @param bidVault The vault holding the bid collateral.
    /// @param bidder The bidder whose bid was revealed.
    /// @param salt The random input used to obfuscate the commitment.
    /// @param bidValue The value of the bid in wei.
    event BidRevealed(
        address tokenContract,
        uint256 tokenId,
        address bidVault,
        address bidder,
        bytes32 salt,
        uint256 bidValue
    );

    /// @notice Emitted when the first bid is revealed for an auction. All
    ///         subsequent bid openings must submit a Merkle proof that their
    ///         vault was sufficiently collateralized by the deadline block.
    /// @param tokenContract The address of the ERC721 contract for the asset
    ///        being auctioned.
    /// @param tokenId The ERC721 token ID of the asset being auctioned.
    /// @param index The auction index for the asset.
    /// @param deadlineBlockNumber The block number by which bidders' vaults
    ///        must have been collateralized.
    event CollateralizationDeadlineSet(
        address tokenContract,
        uint256 tokenId,
        uint32 index,
        uint256 deadlineBlockNumber
    );

    /// @notice A mapping storing auction parameters and state, indexed by
    ///         the ERC721 contract address and token ID of the asset being
    ///         auctioned.
    mapping(address => mapping(uint256 => Auction)) public auctions;

    /// @notice A mapping storing whether or not the bid for a `SneakyVault` was revealed.
    mapping(address => bool) public revealedVaults;

    /// @notice Creates an auction for the given ERC721 asset with the given
    ///         auction parameters.
    /// @param tokenContract The address of the ERC721 contract for the asset
    ///        being auctioned.
    /// @param tokenId The ERC721 token ID of the asset being auctioned.
    /// @param bidPeriod The duration of the bidding period, in seconds.
    /// @param revealPeriod The duration of the commitment reveal period,
    ///        in seconds.
    /// @param reservePrice The minimum price that the asset will be sold for.
    ///        If not bids exceed this price, the asset is returned to `seller`.
    ///        In bid base units (1000 gwei).
    function createAuction(
        address tokenContract,
        uint256 tokenId,
        uint32 bidPeriod,
        uint32 revealPeriod,
        uint48 reservePrice
    ) external nonReentrant {
        Auction storage auction = auctions[tokenContract][tokenId];

        if (bidPeriod < 1 hours) {
            revert BidPeriodTooShortError(bidPeriod);
        }
        if (revealPeriod < 1 hours) {
            revert RevealPeriodTooShortError(revealPeriod);
        }

        auction.seller = msg.sender;
        auction.endOfBiddingPeriod = uint32(block.timestamp) + bidPeriod;
        auction.endOfRevealPeriod =
            uint32(block.timestamp) +
            bidPeriod +
            revealPeriod;
        // Increment auction index for this item
        auction.index++;
        // Both lowest and second-lowest bid are set to the reserve price.
        // Any winning bid must be at least this price, and the winner will
        // pay at least this price.
        auction.lowestUniqueBid = reservePrice;
        auction.secondLowestUniqueBid = reservePrice;
        // Reset
        auction.lowestUniqueBidVault = address(0);
        auction.collateralizationDeadlineBlockHash = bytes32(0);

        ERC721(tokenContract).transferFrom(msg.sender, address(this), tokenId);
        emit AuctionCreated(
            tokenContract,
            tokenId,
            msg.sender,
            bidPeriod,
            revealPeriod,
            reservePrice * BID_BASE_UNIT
        );
    }

    /// @notice Reveals the value of a bid that was previously committed to.
    /// @param tokenContract The address of the ERC721 contract for the asset
    ///        being auctioned.
    /// @param tokenId The ERC721 token ID of the asset being auctioned.
    /// @param bidValue The value of the bid. In bid base units (1000 gwei).
    /// @param salt The random input used to obfuscate the commitment.
    /// @param proof The proof that the vault corresponding to this bid was
    ///        sufficiently collateralized before any bids were revealed. This
    ///        may be null if this is the first bid revealed for the auction.
    function revealBid(
        address tokenContract,
        uint256 tokenId,
        uint48 bidValue,
        bytes32 salt,
        CollateralizationProof calldata proof

    ) external nonReentrant {
        Auction storage auction = auctions[tokenContract][tokenId];

        if (
            block.timestamp <= auction.endOfBiddingPeriod ||
            block.timestamp > auction.endOfRevealPeriod
        ) {
            revert NotInRevealPeriodError();
        }

        uint32 auctionIndex = auction.index;
        address vault = getVaultAddress(
            tokenContract,
            tokenId,
            auctionIndex,
            msg.sender,
            bidValue,
            salt
        );

        if (revealedVaults[vault]) {
            revert BidAlreadyRevealedError(vault);
        }
        revealedVaults[vault] = true;

        uint256 bidValueWei = bidValue * BID_BASE_UNIT;
        bool isCollateralized = true;

        // If this is the first bid revealed, record the block hash of the
        // previous block. All other bids must have been collateralized by
        // that block.
        if (auction.collateralizationDeadlineBlockHash == bytes32(0)) {
            // by waiting until this block to collateralize.
            if (vault.balance < bidValueWei) {
                // Deploy vault to return ETH to bidder
                new SneakyVault{salt: salt}(
                    tokenContract,
                    tokenId,
                    auctionIndex,
                    msg.sender,
                    bidValue
                );
                isCollateralized = false;
            } else {
                auction.collateralizationDeadlineBlockHash = blockhash(
                    block.number - 1
                );
                emit CollateralizationDeadlineSet(
                    tokenContract,
                    tokenId,
                    auctionIndex,
                    block.number - 1
                );
            }
        } else {
            // All other bidders must prove that their balance was
            // sufficiently collateralized by the deadline block.
            uint256 vaultBalance = _getProvenAccountBalance(
                proof.accountMerkleProof,
                proof.blockHeaderRLP,
                auction.collateralizationDeadlineBlockHash,
                vault
            );
            if (vaultBalance < bidValueWei) {
                // Deploy vault to return ETH to bidder
                new SneakyVault{salt: salt}(
                    tokenContract,
                    tokenId,
                    auctionIndex,
                    msg.sender,
                    bidValue
                );
                isCollateralized = false;
            }
            if (isCollateralized) {
                // Update record of (second-)lowest bid as necessary
                uint48 currentLowestUniqueBid = auction.lowestUniqueBid;
                uint currentNumBids = auction.numBids[bidValue];

                if (currentNumBids==0 ){
                    //No bids have been made at this value, so this is a unique bid
                    auction.numBids[bidValue]=1;

                    if (bidValue < currentLowestUniqueBid) {
                        auction.lowestUniqueBid = bidValue;
                        auction.secondLowestUniqueBid = currentLowestUniqueBid;
                        auction.lowestUniqueBidVault = vault;
                    } else {
                        if (bidValue < auction.secondLowestUniqueBid){
                            auction.secondLowestUniqueBid = bidValue;
                        }
                        // Deploy vault to return ETH to bidder
                        new SneakyVault{salt: salt}(
                            tokenContract,
                            tokenId,
                            auctionIndex,
                            msg.sender,
                            bidValue
                        );
                    }
                } else {
                    // There is at already at least one bid at this value, so this is not a unique bid
                    auction.numBids[bidValue]++;
                    // Deploy vault to return ETH to bidder
                    new SneakyVault{salt: salt}(
                        tokenContract,
                        tokenId,
                        auctionIndex,
                        msg.sender,
                        bidValue
                    );
                }
                emit BidRevealed(
                    tokenContract,
                    tokenId,
                    vault,
                    msg.sender,
                    salt,
                    bidValueWei
                );
            }
        }
    }

    function setCollateralizationDeadline(
        address tokenContract,
        uint256 tokenId,
        uint32 auctionIndex,
        uint256 deadlineBlockNumber,
        bytes32 deadlineBlockHash
    ) external nonReentrant {
        Auction storage auction = auctions[tokenContract][tokenId];

        if (auctionIndex != auction.index) {
            revert InvalidAuctionIndexError(auctionIndex);
        }

        if (deadlineBlockNumber < block.number) {
            revert CollateralizationDeadlineTooEarlyError();
        }

        auction.collateralizationDeadlineBlockHash = deadlineBlockHash;
        emit CollateralizationDeadlineSet(
            tokenContract,
            tokenId,
            auctionIndex,
            deadlineBlockNumber
        );
    }

    function endAuction(
        address tokenContract,
        uint256 tokenId,
        address lowestUniqueBidder,
        uint48 lowestUniqueBid,
        bytes32 lowestUniqueBidSalt
    ) external nonReentrant {
        Auction storage auction = auctions[tokenContract][tokenId];
        if (auction.index == 0) {
            revert InvalidAuctionIndexError(0);
        }

        if (block.timestamp <= auction.endOfRevealPeriod) {
            revert RevealPeriodOngoingError();
        }

        address lowestBidVault = auction.lowestUniqueBidVault;
        if (lowestBidVault == address(0)) {
            // No winner, return asset to seller.
            ERC721(tokenContract).safeTransferFrom(
                address(this),
                auction.seller,
                tokenId
            );
        } else {
            uint32 auctionIndex = auction.index;

            address vaultAddress = getVaultAddress(
                tokenContract,
                tokenId,
                auctionIndex,
                lowestUniqueBidder,
                lowestUniqueBid,
                lowestUniqueBidSalt
            );
            if (vaultAddress != lowestBidVault) {
                revert IncorrectVaultAddressError(lowestBidVault, vaultAddress);
            }
            // Transfer auctioned asset to lowest unique bidder
            ERC721(tokenContract).transferFrom(
                address(this),
                lowestUniqueBidder,
                tokenId
            );
            new SneakyVault{salt: lowestUniqueBidSalt}(
                tokenContract,
                tokenId,
                auctionIndex,
                lowestUniqueBidder,
                lowestUniqueBid
            );
        }
    }

    /// @notice Computes the `CREATE2` address of the `SneakyVault` with the given
    ///         parameters. Note that the vault contract may not be deployed yet.
    /// @param tokenContract The address of the ERC721 contract for the asset auctioned.
    /// @param tokenId The ERC721 token ID of the asset auctioned.
    /// @param auctionIndex The index of the auction.
    /// @param bidder The address of the bidder.
    /// @param bidValue The amount bid. In bid base units (1000 gwei).
    /// @param salt The random input used to obfuscate the commitment.
    /// @return vault The address of the `SneakyVault`.
    function getVaultAddress(
        address tokenContract,
        uint256 tokenId,
        uint32 auctionIndex,
        address bidder,
        uint48 bidValue,
        bytes32 salt
    ) public view returns (address vault) {
        // Compute `CREATE2` address of vault
        return
            address(
                uint160(
                    uint256(
                        keccak256(
                            abi.encodePacked(
                                bytes1(0xff),
                                address(this),
                                salt,
                                keccak256(
                                    abi.encodePacked(
                                        type(SneakyVault).creationCode,
                                        abi.encode(
                                            tokenContract,
                                            tokenId,
                                            auctionIndex,
                                            bidder,
                                            bidValue
                                        )
                                    )
                                )
                            )
                        )
                    )
                )
            );
    }

    /// @dev Gets the balance of the given account at a past block by
    ///      traversing the given Merkle proof for the state trie. Wraps
    ///      LibBalanceProof.getProvenAccountBalance so that this function
    ///      can be overriden for testing.
    /// @param proof A Merkle proof for the given account's balance in
    ///        the state trie of a past block.
    /// @param blockHeaderRLP The RLP-encoded block header for the past
    ///        block for which the balance is being queried.
    /// @param blockHash The expected blockhash. Should be equal to the
    ///        Keccak256 hash of `blockHeaderRLP`.
    /// @param account The account whose past balance is being queried.
    /// @return accountBalance The proven past balance of the account.
    function _getProvenAccountBalance(
        bytes[] memory proof,
        bytes memory blockHeaderRLP,
        bytes32 blockHash,
        address account
    ) internal view virtual returns (uint256 accountBalance) {
        return
            LibBalanceProof.getProvenAccountBalance(
                proof,
                blockHeaderRLP,
                blockHash,
                account
            );
    }
}
