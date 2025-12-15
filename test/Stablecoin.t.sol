// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {Stablecoin} from "../src/Stablecoin.sol";
import {ERC1967Proxy} from "lib/openzeppelin-contracts-upgradeable/lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";


contract StablecoinTest is Test {
    Stablecoin public stablecoin;
    address public admin = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;

    function setUp() public {
        vm.startPrank(admin);
        address impl = address(new Stablecoin());
        address proxy = address(new ERC1967Proxy(impl, abi.encodeCall(Stablecoin.initialize, ("Stablecoin", "Stablecoin"))));
        stablecoin = Stablecoin(proxy);
        vm.stopPrank();
    }

    function test_AddMinter() public {
        address newMinter = address(1);
        vm.prank(admin);
        stablecoin.addMinter(newMinter);
        
        bool hasRole = stablecoin.hasRole(stablecoin.MINTER_ROLE(), newMinter);
        assertTrue(hasRole);
    }
}
