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
    uint256 public constant BID_BASE_UNIT = 1000 gwei;

    struct Auction {
        address seller;
        uint32 endOfBiddingPeriod;
        uint32 endOfRevealPeriod;
        uint32 index;
        // =====================
        uint48 lowestBid;
        uint48 secondLowestBid;
        address lowestBidVault;
        // =====================
        bytes32 collateralizationDeadlineBlockHash;
    }

    struct CollateralizationProof {
        bytes[] accountMerkleProof;
        bytes blockHeaderRLP;
    }

    event AuctionCreated(
        address tokenContract,
        uint256 tokenId,
        address seller,
        uint32 bidPeriod,
        uint32 revealPeriod,
        uint256 reservePrice
    );

    event BidRevealed(
        address tokenContract,
        uint256 tokenId,
        address bidVault,
        address bidder,
        bytes32 salt,
        uint256 bidValue
    );

    event CollateralizationDeadlineSet(
        address tokenContract,
        uint256 tokenId,
        uint32 index,
        uint256 deadlineBlockNumber
    );

    mapping(address => mapping(uint256 => Auction)) public auctions;

    mapping(address => bool) public revealedVaults;

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
        auction.lowestBid = reservePrice;
        auction.secondLowestBid = reservePrice;
        // Reset
        auction.lowestBidVault = address(0);
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
                uint48 currentLowestBid = auction.lowestBid;
                if (bidValue < currentLowestBid) {
                    auction.lowestBid = bidValue;
                    auction.secondLowestBid = currentLowestBid;
                    auction.lowestBidVault = vault;
                } else {
                    if (bidValue < auction.secondLowestBid) {
                        auction.secondLowestBid = bidValue;
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

        address lowestBidVault = auction.lowestBidVault;
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
