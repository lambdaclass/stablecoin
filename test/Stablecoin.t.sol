// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {Stablecoin} from "../src/Stablecoin.sol";
import {
    ERC1967Proxy
} from "lib/openzeppelin-contracts-upgradeable/lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract StablecoinTest is Test {
    Stablecoin public stablecoin;
    address public admin = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
    address public minter = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    address public burner = 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC;
    address public pauser = 0x90F79bf6EB2c4f870365E785982E1f101E93b906;
    address public freezer = 0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65;

    bytes public ENFORCED_PAUSE_ERROR = abi.encodeWithSignature("EnforcedPause()");

    function setUp() public {
        vm.startPrank(admin);
        address impl = address(new Stablecoin());
        address proxy = address(
            new ERC1967Proxy(
                impl,
                abi.encodeCall(Stablecoin.initialize, ("Stablecoin", "Stablecoin", admin, burner, pauser, freezer))
            )
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

    // TODO: test more functions when paused
    function test_CannotMintWhenPaused() public {
        vm.prank(pauser);
        stablecoin.pause();

        vm.prank(minter);
        vm.expectRevert(ENFORCED_PAUSE_ERROR);
        stablecoin.mint(minter, 1000);
    }

    function test_CannotBurnWhenPaused() public {
        vm.prank(pauser);
        stablecoin.pause();

        vm.prank(burner);
        vm.expectRevert(ENFORCED_PAUSE_ERROR);
        stablecoin.burn(1000);

        address account = address(1);
        vm.prank(burner);
        vm.expectRevert(ENFORCED_PAUSE_ERROR);
        stablecoin.burnFrom(account, 1000);
    }

    function test_CannotTransferWhenPaused() public {
        address account = address(1);
        address otherAccount = address(2);
        vm.prank(pauser);
        stablecoin.pause();

        vm.prank(account);
        vm.expectRevert(ENFORCED_PAUSE_ERROR);
        stablecoin.transfer(otherAccount, 1000);
    }

    function test_CannotFreezeWhenPaused() public {
        address account = address(1);
        vm.prank(pauser);
        stablecoin.pause();

        vm.prank(freezer);
        vm.expectRevert(ENFORCED_PAUSE_ERROR);
        stablecoin.freeze(account);
    }

    function test_CannotUnfreezeWhenPaused() public {
        address account = address(1);
        vm.prank(pauser);
        stablecoin.pause();

        vm.prank(freezer);
        vm.expectRevert(ENFORCED_PAUSE_ERROR);
        stablecoin.unfreeze(account);
    }

    function test_CannotAddMinterWhenPaused() public {
        address account = address(1);
        vm.prank(pauser);
        stablecoin.pause();

        vm.prank(admin);
        vm.expectRevert(ENFORCED_PAUSE_ERROR);
        stablecoin.addMinter(account, 1000);
    }

    function test_CannotAddBurnerWhenPaused() public {
        address account = address(1);
        vm.prank(pauser);
        stablecoin.pause();

        vm.prank(admin);
        vm.expectRevert(ENFORCED_PAUSE_ERROR);
        stablecoin.addBurner(account);
    }

    function test_FreezeAccount() public {
        address freezedAccount = address(1);
        address otherAccount = address(2);

        // Freeze the account
        vm.prank(freezer);
        stablecoin.freeze(freezedAccount);

        // Check minting to freezed account fails
        vm.prank(minter);
        vm.expectRevert("Freezed account");
        stablecoin.mint(freezedAccount, 1000);

        // Check transferring from freezed account fails
        vm.prank(freezedAccount);
        vm.expectRevert("Freezed account");
        stablecoin.transfer(otherAccount, 1000);

        vm.prank(minter);
        stablecoin.mint(otherAccount, 1000);

        // Check transferring to freezed account fails
        vm.prank(otherAccount);
        vm.expectRevert("Freezed account");
        stablecoin.transfer(freezedAccount, 1000);
    }
}
