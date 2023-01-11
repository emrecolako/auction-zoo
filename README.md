# The Auction Zoo - Lowest Unique Bid Auction

This is a fork of a16z (sealed bid auction)[https://github.com/a16z/auction-zoo/tree/main/src/sealed-bid/sneaky-auction]

The winner of the auction is determined by the lowest unique bid, and the contract does not include any mechanism for handling auctions that have not been successfully sold or for resolving disputes that may arise during the auction process.

In this contract, the winner of an auction is the person who has placed the lowest unique bid. When a bid is revealed, the contract compares the bid value to the current lowest unique bid for the auction. If the revealed bid is lower than the current lowest unique bid, the contract sets the revealed bid as the new lowest unique bid and stores the address of the vault where the bid was placed.

If multiple bidders place the same bid, the contract will consider it as a duplicate bid, and it will not count as a unique bid. 

Once the reveal period for the auction has ended, the winner can be determined by checking the lowest unique bid value and the address of the vault where it was placed. The winner can be the address of the account that revealed the lowest unique bid, and the ERC-721 token can be transferred to the winner.

## Potential Improvements


1. Handling of expired auctions: the current contract does not include any mechanism for handling auctions that have ended but have not been successfully sold. It could be improved by adding a process to handle expired auctions and return the ERC-721 token to the seller or perform other actions in case of a failed auction.

2. Bid retracting: The current contract does not include a mechanism to allow a bidder to retract their bid. It could be improved by allowing bidders to retract their bid before the reveal period has ended, as long as they haven't revealed it.

3. Handling of low-balance bidders: The current contract does not include any mechanism to handle bidders who do not have enough balance in their account to complete the transaction. It could be improved by adding a mechanism to handle this, such as refunds.

4. Multisignature on the token transfer: The contract currently doesn't provide any mechanism to check the validity of the transfer, it only emits an event, it could be improved by having a multi-sig mechanism, where the owner of the ERC721 token and the contract owner signs the transfer.

5. Adding a mechanism for dispute resolution: The current contract does not include any mechanism for resolving disputes that may arise in the auction process. It could be improved by adding a dispute resolution process where an unbiased third party can make a decision on any disputes that may arise.

## Accompanying blog posts
1. [On Paper to On-Chain: How Auction Theory Informs Implementations
](https://a16zcrypto.com/how-auction-theory-informs-implementations/)
2. [Hidden in Plain Sight: A Sneaky Solidity Implementation of a Sealed-Bid Auction](https://a16zcrypto.com/hidden-in-plain-sight-a-sneaky-solidity-implementation-of-a-sealed-bid-auction/)

## Usage

Requires [Foundry](https://book.getfoundry.sh/getting-started/installation).

Install: `forge install`

Build: `forge build`

Test: `forge test`


## Disclaimer

_These smart contracts are being provided as is. No guarantee, representation or warranty is being made, express or implied, as to the safety or correctness of the user interface or the smart contracts. They have not been audited and as such there can be no assurance they will work as intended, and users may experience delays, failures, errors, omissions or loss of transmitted information. THE SMART CONTRACTS CONTAINED HEREIN ARE FURNISHED AS IS, WHERE IS, WITH ALL FAULTS AND WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF MERCHANTABILITY, NON- INFRINGEMENT OR FITNESS FOR ANY PARTICULAR PURPOSE. Further, use of any of these smart contracts may be restricted or prohibited under applicable law, including securities laws, and it is therefore strongly advised for you to contact a reputable attorney in any jurisdiction where these smart contracts may be accessible for any questions or concerns with respect thereto. Further, no information provided in this repo should be construed as investment advice or legal advice for any particular facts or circumstances, and is not meant to replace competent counsel. a16z is not liable for any use of the foregoing, and users should proceed with caution and use at their own risk. See a16z.com/disclosures for more info._
