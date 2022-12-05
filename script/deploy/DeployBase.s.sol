pragma solidity >=0.8.0;

import "forge-std/Script.sol";
import "../../src/sealed-bid/sneaky-auction/SneakyAuction.sol";

import "../../src/sealed-bid/sneaky-auction/ISneakyAuctionErrors.sol";
import "../../src/sealed-bid/sneaky-auction/SneakyAuction.sol";
import "test/utils/TestActors.sol";
import "test/utils/TestERC721.sol";



contract SneakyAuctionWrapper is SneakyAuction {
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

contract DeployBase is Script {

    SneakyAuctionWrapper auction;
    TestERC721 erc721;
    uint48 constant ONE_ETH = uint48(1 ether / 1000 gwei);
    uint256 constant TOKEN_ID = 1;
    
    function setUp() public {
        // super.setUp();
        auction = new SneakyAuctionWrapper();
        erc721 = new TestERC721();
        // erc721.mint(alice, TOKEN_ID);
        // hoax(alice);
        // erc721.setApprovalForAll(address(auction), true);
    }

    function run() public{
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        SneakyAuction sneakyImpl = new SneakyAuction();

        console2.log("SneakyAuction: ");
        console2.log(address(sneakyImpl));
        // console2.log("Draw Impl: ");
        // console2.log(address(drawImpl));
        // vm.label(address(factory), "factory");
        vm.stopBroadcast();
        

    }

}