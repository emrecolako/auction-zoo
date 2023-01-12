// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import "sneaky-lowest-unique-bid-auction/ISneakyAuctionErrors.sol";
import "sneaky-lowest-unique-bid-auction/SneakyAuctionLowestUniqueBid.sol";
import "./utils/TestActors.sol";
import "./utils/TestERC721.sol";


contract SneakyAuctionWrapper is SneakyAuctionLowestUniqueBid {
    uint256 bal;

    function setBalance(uint256 _bal) external {
        bal = _bal;
    }

    // Overridden so we don't have to deal with proofs here.
    // See BalanceProofTest.sol for LibBalanceProof unit tests.
    function _getProvenAccountBalance(
        bytes[] memory /* proof */,
        bytes memory /* blockHeaderRLP */,
        bytes32 /* blockHash */,
        address /* account */
    )
        internal
        override
        view
        returns (uint256 accountBalance)
    {
        return bal;
    }
}

contract SneakyAuctionLowestUniqueBidTest is ISneakyAuctionErrors, TestActors {
    SneakyAuctionWrapper auction;
    TestERC721 erc721;
    
    uint48 constant ONE_ETH = uint48(1 ether / 1000 gwei);
    uint48 constant TWO_ETH = uint48(2 ether / 1000 gwei);
    
    uint constant TOKEN_ID = 1;
    
    function setUp() public override {
        super.setUp();
        auction = new SneakyAuctionWrapper();
        erc721 = new TestERC721();
        erc721.mint (alice, TOKEN_ID);
        hoax(alice);
        erc721.setApprovalForAll(address(auction),true);
        }
        
    function testRevealBid() external {
        SneakyAuctionLowestUniqueBid.Auction memory expectedState = 
            createAuction(TOKEN_ID);
        uint48 bidValue = ONE_ETH + 1;
        bytes32 salt = bytes32(uint256(123));
        address vault = commitBid(
            bob,
            bidValue,
            bidValue,
            salt
        );
        skip(1 hours + 30 minutes);
        hoax(bob);
        auction.revealBid(
            address(erc721),
            TOKEN_ID,
            bidValue,
            salt,
            nullProof()
        );
        expectedState.collateralizationDeadlineBlockHash = blockhash(block.number - 1);
        expectedState.secondLowestUniqueBid = expectedState.lowestUniqueBid;
        expectedState.lowestUniqueBid = bidValue;
        expectedState.lowestUniqueBidVault = vault;
        // assertAuctionsEqual(auction.getAuction(address(erc721), TOKEN_ID), expectedState);
        assertVaultRevealed(vault);        
    }

     function testCannotRevealBidBeforeRevealPeriod() external {
        createAuction(TOKEN_ID);
        uint48 bidValue = ONE_ETH + 1;
        bytes32 salt = bytes32(uint256(123));
        commitBid(
            bob,
            bidValue,
            bidValue,
            salt
        );
        vm.expectRevert(NotInRevealPeriodError.selector);
        hoax(bob);
        auction.revealBid(
            address(erc721),
            TOKEN_ID,
            bidValue,
            salt,
            nullProof()
        );
    }

function testUpdateLowestUniqueBidder() external {
    SneakyAuctionLowestUniqueBid.Auction memory expectedState = createAuction(TOKEN_ID);
        

    address aliceVault = commitBid(alice, ONE_ETH, ONE_ETH, bytes32(uint256(123)));
    address bobVault = commitBid(bob, ONE_ETH-1, ONE_ETH-1, bytes32(uint256(124)));
    address charlieVault = commitBid(charlie, ONE_ETH + 1, ONE_ETH + 1, bytes32(uint256(125)));
    address dannyVault = commitBid(danny, ONE_ETH - 2, ONE_ETH - 2, bytes32(uint256(126)));

    skip(1 hours + 30 minutes);

    hoax(alice);
    
    // console2.log("alice:\n");

    auction.revealBid(address(erc721), TOKEN_ID, ONE_ETH, bytes32(uint256(123)), nullProof());
    hoax(bob);
    // console2.log("bob:\n");

    auction.revealBid(address(erc721), TOKEN_ID, ONE_ETH-1, bytes32(uint256(124)), nullProof());

    hoax(charlie);
    // console2.log("charlie:\n");
    auction.revealBid(address(erc721), TOKEN_ID, ONE_ETH + 1, bytes32(uint256(125)), nullProof());
    hoax(danny);
    // console2.log("danny:\n");
    auction.revealBid(address(erc721), TOKEN_ID, ONE_ETH - 2, bytes32(uint256(126)), nullProof());

    expectedState.lowestUniqueBid = ONE_ETH-2;
    expectedState.secondLowestUniqueBid = ONE_ETH ;
    expectedState.lowestUniqueBidVault = dannyVault;
    expectedState.collateralizationDeadlineBlockHash = blockhash(block.number - 1);
        
    assertAuctionsEqual(auction.getAuction(address(erc721), TOKEN_ID), expectedState);
}





    function testRevealUsingDifferentSalt() external {
        SneakyAuctionLowestUniqueBid.Auction memory expectedState = createAuction(TOKEN_ID);
        uint48 bidValue = ONE_ETH + 1;
        bytes32 salt = bytes32(uint256(123));
        commitBid(
            bob,
            bidValue,
            bidValue,
            salt
        );
        skip(1 hours + 30 minutes);
        // Vault corresponding to different salt is empty
        hoax(bob);
        auction.revealBid(
            address(erc721),
            TOKEN_ID,
            bidValue,
            bytes32(uint256(salt) + 1),
            nullProof()
        );
        assertAuctionsEqual(
            auction.getAuction(address(erc721), TOKEN_ID), 
            expectedState
        );
        assertVaultRevealed(auction.getVaultAddress(
            address(erc721),
            TOKEN_ID,
            expectedState.index,
            bob,
            bidValue,
            bytes32(uint256(salt) + 1)
        ));
    }

function assertVaultRevealed(address vault) private {
        assertTrue(auction.revealedVaults(vault), "revealedVaults");
    }
   function nullProof()
        private
        pure
        returns (SneakyAuctionLowestUniqueBid.CollateralizationProof memory proof)
    {
        return proof;
    }
    
    function createAuction(uint256 tokenId) 
        private 
        returns (SneakyAuctionLowestUniqueBid.Auction memory a)
    {
        hoax(alice);
        auction.createAuction(
            address(erc721), 
            tokenId,
            1 hours, //bidPeriod
            1 hours, //revealPeriod
            0 // reservePrice
        );
        return auction.getAuction(address(erc721), tokenId);
    }


    function commitBid(
        address from,
        uint48 bidValue,
        uint48 collateral,
        bytes32 salt
    )
        private
        returns (address vault)
    {
        vault = auction.getVaultAddress(
            address(erc721),
            TOKEN_ID,
            1,
            from,
            bidValue,
            salt   
        );
        payable(vault).transfer(collateral * auction.BID_BASE_UNIT());
        auction.setBalance(collateral * auction.BID_BASE_UNIT());        
    }

        function assertAuctionsEqual(
        SneakyAuctionLowestUniqueBid.Auction memory actualAuction,
        SneakyAuctionLowestUniqueBid.Auction memory expectedAuction
    ) private {
        assertEq(actualAuction.seller, expectedAuction.seller, "seller");
        assertEq(actualAuction.endOfBiddingPeriod, expectedAuction.endOfBiddingPeriod, "endOfBiddingPeriod");
        assertEq(actualAuction.endOfRevealPeriod, expectedAuction.endOfRevealPeriod, "endOfRevealPeriod");
        assertEq(actualAuction.index, expectedAuction.index, "index");
        assertEq(actualAuction.lowestUniqueBid, expectedAuction.lowestUniqueBid, "lowestUniqueBid");
        assertEq(actualAuction.secondLowestUniqueBid, expectedAuction.secondLowestUniqueBid, "secondLowestUniqueBid");
        assertEq(actualAuction.lowestUniqueBidVault, expectedAuction.lowestUniqueBidVault, "lowestUniqueBidVault");
        // assertEq(actualAuction.secondLowestUniqueBidVault, expectedAuction.secondLowestUniqueBidVault, "secondLowestUniqueBidVault");
        assertEq(actualAuction.collateralizationDeadlineBlockHash, expectedAuction.collateralizationDeadlineBlockHash, "collateralizationDeadlineBlockHash");
    }

}










// // Test function to ensure that a new auction can be created
// function testNewAuction() public {
//     // Define auction parameters
//     address tokenContract = address(0x123456);
//     uint256 tokenId = 123;
//     address seller = address(0xabcdef);
//     uint32 bidPeriod = 1000;
//     uint32 revealPeriod = 1000;
//     uint48 reservePrice = 100000;

//     // Create a new auction
//     auction.createAuction(tokenContract, tokenId,bidPeriod, revealPeriod, reservePrice);

//     // Retrieve the created auction
//     SneakyAuctionLowestUniqueBid.Auction memory createdAuction = auction.auctions(tokenContract, tokenId);

//     // Verify that the auction has been created correctly
//     assertEq(createdAuction.seller, seller);
//     assertEq(createdAuction.endOfBiddingPeriod, bidPeriod);
//     assertEq(createdAuction.endOfRevealPeriod, revealPeriod);
//     assertEq(createdAuction.index, 0);
//     assertEq(createdAuction.reservePrice, reservePrice);
//     assertEq(createdAuction.highestBid, 0);
// }

// // Test function to ensure that a bid can be placed and that the highest bid is updated correctly
// function testPlaceBid() public {
//     // Define auction parameters
//     address tokenContract = 0x123456;
//     uint256 tokenId = 123;
//     address seller = 0xabcdef;
//     uint32 bidPeriod = 1000;
//     uint32 revealPeriod = 1000;
//     uint256 reservePrice = 100000;

//     // Create a new auction
//     auction.newAuction(tokenContract, tokenId, seller, bidPeriod, revealPeriod, reservePrice);

//     // Place a bid
//     address bidder = 0x789012;
//     uint256 bidValue = 200000;
//     uint256 bidSalt = 123456;
//     auction.placeBid(tokenContract, tokenId, bidder, bidValue, bidSalt);

//     // Retrieve the updated auction
//     SneakyAuctionLowestUniqueBid.Auction memory updatedAuction = auction.auctions(tokenContract, tokenId, 0);

//     // Verify that the highest bid has been updated correctly
//     assert.equal(updatedAuction.highestBid, bidValue, "Highest bid is incorrect");
// }

// // Test function to ensure that a commitment can be opened and that the highest bid is updated correctly
// function testOpenCommitment() public {
// // Define auction parameters
// address tokenContract = 0x123456;
// uint256 tokenId = 123;
// address seller = 0xabcdef;
// uint32 bidPeriod = 1000;
// uint32 revealPeriod = 1000;
// uint256 reservePrice = 100000;


//     // Create a new auction
//     auction.newAuction(tokenContract, tokenId, seller, bidPeriod, revealPeriod, reservePrice);

//     // Place a bid
//     address bidder = 0x789012;
//     uint256 bidValue = 200000;
//     uint256 bidSalt = 123456;
//     auction.placeBid(tokenContract, tokenId, bidder, bidValue, bidSalt);

//     // Open the commitment
//     bytes32 commitment = auction.getCommitment(bidder, tokenContract, tokenId, bidValue, bidSalt);
//     auction.openCommitment(tokenContract, tokenId, commitment, bidValue, bidder);

//     // Retrieve the updated auction
//     SneakyAuctionLowestUniqueBid.Auction memory updatedAuction = auction.auctions(tokenContract, tokenId, 0);

//     // Verify that the highest bid has been updated correctly
//     assert.equal(updatedAuction.highestBid, bidValue, "Highest bid is incorrect");
//     assert.equal(updatedAuction.highestBidder, bidder, "Highest bidder is incorrect");
// }

// // Test function to ensure that a bid can be revealed and that the winner is correctly determined
// function testRevealBid() public {
//     // Define auction parameters
//     address tokenContract = 0x123456;
//     uint256 tokenId = 123;
//     address seller = 0xabcdef;
//     uint32 bidPeriod = 1000;
//     uint32 revealPeriod = 1000;
//     uint256 reservePrice = 100000;

//     // Create a new auction
//     auction.newAuction(tokenContract, tokenId, seller, bidPeriod, revealPeriod, reservePrice);

//     // Place a bid
//     address bidder = 0x789012;
//     uint256 bidValue = 200000;
//     uint256 bidSalt = 123456;
//     auction.placeBid(tokenContract, tokenId, bidder, bidValue, bidSalt);

//     // Open the commitment
//     bytes32 commitment = auction.getCommitment(bidder, tokenContract, tokenId, bidValue, bidSalt);
//     auction.openCommitment(tokenContract, tokenId, commitment, bidValue, bidder);

//     // Reveal the bid
//     auction.revealBid(tokenContract, tokenId, bidder, bidValue, bidSalt);

//     // Retrieve the updated auction
//     SneakyAuctionLowestUniqueBid.Auction memory updatedAuction = auction.auctions(tokenContract, tokenId, 0);

//     // Verify that the winner has been correctly determined
//     assert.equal(updatedAuction.winner, bidder, "Winner is incorrect");
// }

// }
