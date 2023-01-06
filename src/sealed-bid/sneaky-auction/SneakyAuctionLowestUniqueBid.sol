// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import "solmate/tokens/ERC721.sol";
import "solmate/utils/ReentrancyGuard.sol";
import "./ISneakyAuctionErrors.sol";
import "./LibBalanceProof.sol";
import "./SneakyVaultLUB.sol";

/// @title An on-chain, exact-collateralization, sealed-bid, second-price auction
contract SneakyAuctionLowestUniqueBid is ISneakyAuctionErrors, ReentrancyGuard {
    /// @notice The base unit for bids. The reserve price and bid value parameters
    /// for this contract's functions are denominated in this base unit,
    /// not wei. 1000 gwei = 1e12 wei.
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
    /// @param lowestUniqueBid The value of the lowest unique bid revealed so far,
    ///        or the reserve price if no unique bids have been placed. In bid base units
    ///        (1000 gwei).
    /// @param lowestUniqueBidVault The address of the `SneakyVaultLUB` containing the
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
        address secondLowestUniqueBidVault;
        // =====================
        bytes32 collateralizationDeadlineBlockHash;
    }

    /// @dev A Merkle proof and block header, in conjunction with the
    ///      stored `collateralizationDeadlineBlockHash` for an auction,
    ///      is used to prove that a bidder's `SneakyVaultLUB` was sufficiently
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

    /// @notice A mapping storing whether or not the bid for a `SneakyVaultLUB` was revealed.
    mapping(address => bool) public revealedVaults;

    /// @notice A mapping
    mapping(uint48 => uint) public bidCounts;

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
    ///        may be null if this is the first bid revealed for the auction
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
            // As the first bid revealed, we don't care when the vault was
            // collateralized (e.g. this block). With the exception of racing
            // `revealBid` transactions in the public mempool, the bidder
            // shouldn't be able to gain additional info about other bids

            // by waiting until this block to collateralize.
            if (vault.balance < bidValueWei) {
                // Deploy vault to return ETH to bidder
                new SneakyVaultLUB{salt: salt}(
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
                new SneakyVaultLUB{salt: salt}(
                    tokenContract,
                    tokenId,
                    auctionIndex,
                    msg.sender,
                    bidValue
                );
                isCollateralized = false;
            }
        }
        if (isCollateralized) {
            // Update record of lowest unique bid as necessary
            uint48 currentLowestBid = auction.lowestUniqueBid;
            if (bidValue < currentLowestBid || currentLowestBid == 0) {
                auction.lowestUniqueBid = bidValue;
                auction.lowestUniqueBidVault = vault;
                // Update record of second lowest unique bid as necessary
                uint48 currentSecondLowestBid = auction.secondLowestUniqueBid;
                if (
                    currentSecondLowestBid == 0 ||
                    currentSecondLowestBid > currentLowestBid
                ) {
                    auction.secondLowestUniqueBid = currentLowestBid;
                    auction.secondLowestUniqueBidVault = auction
                        .lowestUniqueBidVault;
                }
            } else if (bidValue == currentLowestBid) {
                auction.lowestUniqueBidVault = address(0);
            } else if (
                bidValue < auction.secondLowestUniqueBid ||
                auction.secondLowestUniqueBid == 0
            ) {
                auction.secondLowestUniqueBid = bidValue;
                auction.secondLowestUniqueBidVault = vault;
            }
            // Increment bid count for this value
            bidCounts[bidValue]++;
            // Deploy vault to return ETH to bidder
            new SneakyVaultLUB{salt: salt}(
                tokenContract,
                tokenId,
                auctionIndex,
                msg.sender,
                bidValue
            );
            // and make sure that the bid value is unique
            if (bidCounts[bidValue] == 1) {
                auction.lowestUniqueBid = bidValue;
                auction.lowestUniqueBidVault = vault;
            } else {
                // Deploy vault to return ETH to bidder
                new SneakyVaultLUB{salt: salt}(
                    tokenContract,
                    tokenId,
                    auctionIndex,
                    msg.sender,
                    bidValue
                );
            }
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

    function endAuction(
        address tokenContract,
        uint256 tokenId,
        address lowestBidder,
        uint48 lowestBid,
        bytes32 lowestBidSalt
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
            // Verify that the given bidder is in fact the lowest bidder by recomputing
            // the vault address and checking against the stored value.
            address vaultAddress = getVaultAddress(
                tokenContract,
                tokenId,
                auctionIndex,
                lowestBidder,
                lowestBid,
                lowestBidSalt
            );
            if (vaultAddress != lowestBidVault) {
                revert IncorrectVaultAddressError(lowestBidVault, vaultAddress);
            }
            // Transfer auctioned asset to lowest bidder
            ERC721(tokenContract).transferFrom(
                address(this),
                lowestBidder,
                tokenId
            );
            // Deploy vault to transfer ETH to seller, returning any excess to bidder
            new SneakyVaultLUB{salt: lowestBidSalt}(
                tokenContract,
                tokenId,
                auctionIndex,
                lowestBidder,
                lowestBid
            );
        }
    }

    /// @notice Withdraws collateral from a bidder's vault once an auction is over.
    ///         Bidder must have opened their bid commitment.
    /// @param tokenContract The address of the ERC721 contract for the asset
    ///        that was auctioned.
    /// @param tokenId The ERC721 token ID of the asset that was auctioned.
    /// @param auctionIndex The index of the auction that was being bid on.
    /// @param salt The random input used to obfuscate the commitment.
    /// @param bidValue The amount bid. In bid base units (1000 gwei).
    function withdrawCollateral(
        address tokenContract,
        uint256 tokenId,
        uint32 auctionIndex,
        bytes32 salt,
        uint48 bidValue
    ) external nonReentrant {
        Auction storage auction = auctions[tokenContract][tokenId];
        uint32 currentAuctionIndex = auction.index;
        if (auctionIndex > currentAuctionIndex) {
            revert InvalidAuctionIndexError(auctionIndex);
        }

        address vaultAddress = getVaultAddress(
            tokenContract,
            tokenId,
            auctionIndex,
            msg.sender,
            bidValue,
            salt
        );

        if (!revealedVaults[vaultAddress]) {
            revert UnrevealedBidError();
        }

        if (auctionIndex == currentAuctionIndex) {
            // If bidder has revealed their bid and is not currently in the
            // running to win the auction, they can withdraw their collateral.
            if (vaultAddress == auction.lowestUniqueBidVault) {
                revert CannotWithdrawError();
            }
        }
        // Deploy vault to return ETH to bidder
        new SneakyVaultLUB{salt: salt}(
            tokenContract,
            tokenId,
            auctionIndex,
            msg.sender,
            bidValue
        );
    }

    /// @notice Returns the seller for the most recent auction of the given asset.
    /// @param tokenContract The address of the ERC721 contract for the asset auctioned.
    /// @param tokenId The ERC721 token ID of the asset auctioned.
    /// @return seller The address of the seller.
    function getSeller(
        address tokenContract,
        uint256 tokenId
    ) external view returns (address seller) {
        return auctions[tokenContract][tokenId].seller;
    }

    /// @notice Returns the second highest bid (in wei) for the most recent auction of
    ///         the given asset.
    /// @param tokenContract The address of the ERC721 contract for the asset auctioned.
    /// @param tokenId The ERC721 token ID of the asset auctioned.
    /// @return bid The value of the second lowest unique bid (in wei).
    function getSecondLowestUniqueBid(
        address tokenContract,
        uint256 tokenId
    ) external view returns (uint256 bid) {
        return
            auctions[tokenContract][tokenId].secondLowestUniqueBid *
            BID_BASE_UNIT;
    }

    /// @notice Computes the `CREATE2` address of the `SneakyVaultLUB` with the given
    ///         parameters. Note that the vault contract may not be deployed yet.
    /// @param tokenContract The address of the ERC721 contract for the asset auctioned.
    /// @param tokenId The ERC721 token ID of the asset auctioned.
    /// @param auctionIndex The index of the auction.
    /// @param bidder The address of the bidder.
    /// @param bidValue The amount bid. In bid base units (1000 gwei).
    /// @param salt The random input used to obfuscate the commitment.
    /// @return vault The address of the `SneakyVaultLUB`.
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
                                        type(SneakyVaultLUB).creationCode,
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

    /// @notice Returns vault address associated with the highest bid for the most
    ///         recent auction of the given asset.
    /// @param tokenContract The address of the ERC721 contract for the asset auctioned.
    /// @param tokenId The ERC721 token ID of the asset auctioned.
    /// @return vault The address of the vault holding the collateral for the lowest unique bid
    function getLowestUniqueBidVault(
        address tokenContract,
        uint256 tokenId
    ) external view returns (address vault) {
        return auctions[tokenContract][tokenId].lowestUniqueBidVault;
    }

    /// @notice Gets the parameters and state of an auction in storage.
    /// @param tokenContract The address of the ERC721 contract for the asset auctioned.
    /// @param tokenId The ERC721 token ID of the asset auctioned.
    function getAuction(
        address tokenContract,
        uint256 tokenId
    ) external view returns (Auction memory auction) {
        return auctions[tokenContract][tokenId];
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
