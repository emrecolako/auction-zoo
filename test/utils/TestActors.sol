// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import "forge-std/Test.sol";

abstract contract TestActors is Test {
    address constant alice = address(uint160(uint256(keccak256("alice"))));
    address constant bob = address(uint160(uint256(keccak256("bob"))));
    address constant charlie = address(uint160(uint256(keccak256("charlie"))));
    address constant danny = address(uint160(uint256(keccak256("danny"))));
    address constant eve = address(uint160(uint256(keccak256("eve"))));
    address constant nancy = address(uint160(uint256(keccak256("nancy"))));

    function setUp() public virtual {
        vm.label(alice, "Alice");
        vm.label(bob, "Bob");
        vm.label(charlie, "Charlie");
        vm.label(danny, "Danny");
        vm.label(eve, "Eve");
        vm.label(nancy, "Nancy");
    }
}
