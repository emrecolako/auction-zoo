// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import "../src/sealed-bid/sneaky-auction/ISneakyAuctionErrors.sol";
import "../src/sealed-bid/sneaky-auction/SneakyAuctionLowestUniqueBid.sol";
import "forge-std/Test.sol";

contract SneakyAuctionLowestUniqueBidTest {
SneakyAuctionLowestUniqueBid auction;


constructor() public {
    auction = new SneakyAuctionLowestUniqueBid();
}


// Test function to ensure that a new auction can be created
function testNewAuction() public {
    // Define auction parameters
    address tokenContract = address(0x123456);
    uint256 tokenId = 123;
    address seller = address(0xabcdef);
    uint32 bidPeriod = 1000;
    uint32 revealPeriod = 1000;
    uint48 reservePrice = 100000;

    // Create a new auction
    auction.createAuction(tokenContract, tokenId,bidPeriod, revealPeriod, reservePrice);

    // Retrieve the created auction
    SneakyAuctionLowestUniqueBid.Auction memory createdAuction = auction.auctions(tokenContract, tokenId, 0);

    // Verify that the auction has been created correctly
    assertEq(createdAuction.seller, seller);
    assertEq(createdAuction.endOfBiddingPeriod, bidPeriod);
    assertEq(createdAuction.endOfRevealPeriod, revealPeriod);
    assertEq(createdAuction.index, 0);
    assertEq(createdAuction.reservePrice, reservePrice);
    assertEq(createdAuction.highestBid, 0);
}

// Test function to ensure that a bid can be placed and that the highest bid is updated correctly
function testPlaceBid() public {
    // Define auction parameters
    address tokenContract = 0x123456;
    uint256 tokenId = 123;
    address seller = 0xabcdef;
    uint32 bidPeriod = 1000;
    uint32 revealPeriod = 1000;
    uint256 reservePrice = 100000;

    // Create a new auction
    auction.newAuction(tokenContract, tokenId, seller, bidPeriod, revealPeriod, reservePrice);

    // Place a bid
    address bidder = 0x789012;
    uint256 bidValue = 200000;
    uint256 bidSalt = 123456;
    auction.placeBid(tokenContract, tokenId, bidder, bidValue, bidSalt);

    // Retrieve the updated auction
    SneakyAuctionLowestUniqueBid.Auction memory updatedAuction = auction.auctions(tokenContract, tokenId, 0);

    // Verify that the highest bid has been updated correctly
    assert.equal(updatedAuction.highestBid, bidValue, "Highest bid is incorrect");
}

// Test function to ensure that a commitment can be opened and that the highest bid is updated correctly
function testOpenCommitment() public {
// Define auction parameters
address tokenContract = 0x123456;
uint256 tokenId = 123;
address seller = 0xabcdef;
uint32 bidPeriod = 1000;
uint32 revealPeriod = 1000;
uint256 reservePrice = 100000;


    // Create a new auction
    auction.newAuction(tokenContract, tokenId, seller, bidPeriod, revealPeriod, reservePrice);

    // Place a bid
    address bidder = 0x789012;
    uint256 bidValue = 200000;
    uint256 bidSalt = 123456;
    auction.placeBid(tokenContract, tokenId, bidder, bidValue, bidSalt);

    // Open the commitment
    bytes32 commitment = auction.getCommitment(bidder, tokenContract, tokenId, bidValue, bidSalt);
    auction.openCommitment(tokenContract, tokenId, commitment, bidValue, bidder);

    // Retrieve the updated auction
    SneakyAuctionLowestUniqueBid.Auction memory updatedAuction = auction.auctions(tokenContract, tokenId, 0);

    // Verify that the highest bid has been updated correctly
    assert.equal(updatedAuction.highestBid, bidValue, "Highest bid is incorrect");
    assert.equal(updatedAuction.highestBidder, bidder, "Highest bidder is incorrect");
}

// Test function to ensure that a bid can be revealed and that the winner is correctly determined
function testRevealBid() public {
    // Define auction parameters
    address tokenContract = 0x123456;
    uint256 tokenId = 123;
    address seller = 0xabcdef;
    uint32 bidPeriod = 1000;
    uint32 revealPeriod = 1000;
    uint256 reservePrice = 100000;

    // Create a new auction
    auction.newAuction(tokenContract, tokenId, seller, bidPeriod, revealPeriod, reservePrice);

    // Place a bid
    address bidder = 0x789012;
    uint256 bidValue = 200000;
    uint256 bidSalt = 123456;
    auction.placeBid(tokenContract, tokenId, bidder, bidValue, bidSalt);

    // Open the commitment
    bytes32 commitment = auction.getCommitment(bidder, tokenContract, tokenId, bidValue, bidSalt);
    auction.openCommitment(tokenContract, tokenId, commitment, bidValue, bidder);

    // Reveal the bid
    auction.revealBid(tokenContract, tokenId, bidder, bidValue, bidSalt);

    // Retrieve the updated auction
    SneakyAuctionLowestUniqueBid.Auction memory updatedAuction = auction.auctions(tokenContract, tokenId, 0);

    // Verify that the winner has been correctly determined
    assert.equal(updatedAuction.winner, bidder, "Winner is incorrect");
}

}
