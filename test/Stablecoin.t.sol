// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {Stablecoin} from "../src/Stablecoin.sol";
import {ERC1967Proxy} from
    "lib/openzeppelin-contracts-upgradeable/lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract StablecoinTest is Test {
    Stablecoin public stablecoin;
    address public admin = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
    address public minter = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    address public burner = 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC;

    function setUp() public {
        vm.startPrank(admin);
        address impl = address(new Stablecoin());
        address proxy = address(
            new ERC1967Proxy(impl, abi.encodeCall(Stablecoin.initialize, ("Stablecoin", "Stablecoin", admin, burner)))
        );
        stablecoin = Stablecoin(proxy);
        stablecoin.addMinter(minter, 1000);
        vm.stopPrank();
    }

    function test_AddMinter() public {
        address newMinter = address(1);
        uint256 amount = 1000;
        vm.prank(admin);
        stablecoin.addMinter(newMinter, amount);

        bool hasRole = stablecoin.hasRole(stablecoin.MINTER_ROLE(), newMinter);
        assertTrue(hasRole);
        assertEq(stablecoin.minterAllowance(newMinter), amount);

        vm.prank(newMinter);
        stablecoin.mint(newMinter, amount);
        assertEq(stablecoin.balanceOf(newMinter), amount);
        assertEq(stablecoin.minterAllowance(newMinter), 0);
    }

    function test_MinterCannotMintMoreThanAllowance() public {
        address newMinter = address(1);
        uint256 amount = 1000;
        vm.prank(admin);
        stablecoin.addMinter(newMinter, amount);

        vm.prank(newMinter);
        vm.expectRevert("Value exceeds allowance");
        stablecoin.mint(newMinter, amount + 1);
    }

    function test_NonMinterAccountCannotMint() public {
        address nonMinter = address(2);
        uint256 amount = 1000;
        vm.expectRevert();
        stablecoin.mint(nonMinter, amount);
    }

    // TODO: test edge cases
    function test_Burn() public {
        uint256 amount = 100;

        // Mint tokens to the burner
        vm.prank(minter);
        stablecoin.mint(burner, amount);
        uint256 burnerBalance = stablecoin.balanceOf(burner);

        // Burn the burner tokens
        vm.prank(burner);
        stablecoin.burn(amount);

        uint256 expectedBalance = burnerBalance - amount;
        assertEq(stablecoin.balanceOf(burner), expectedBalance);
    }

    function test_BurnFrom() public {
        address account = address(3);
        uint256 amount = 100;

        // Mint tokens to the account
        vm.prank(minter);
        stablecoin.mint(account, amount);
        uint256 initialAccountBalance = stablecoin.balanceOf(account);

        // Approve allowance to the burner from the account
        vm.prank(account);
        stablecoin.approve(burner, amount);

        vm.prank(burner);
        stablecoin.burnFrom(account, amount);
        assertEq(stablecoin.balanceOf(burner), initialAccountBalance - amount);
    }

    function test_NonBurnerAccountCannotBurn() public {
        address nonBurnerAccount = address(3);
        uint256 amount = 1000;
        vm.prank(nonBurnerAccount);
        vm.expectRevert();
        stablecoin.burn(amount);
    }
}
