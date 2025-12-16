// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {Stablecoin} from "../src/Stablecoin.sol";
import {
    ERC1967Proxy
} from "lib/openzeppelin-contracts-upgradeable/lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract StablecoinTest is Test {
    Stablecoin public stablecoin;
    address public constant ADMIN = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
    address public constant MINTER = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    address public constant BURNER = 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC;
    address public constant PAUSER = 0x90F79bf6EB2c4f870365E785982E1f101E93b906;
    address public constant FREEZER = 0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65;

    bytes public constant ENFORCED_PAUSE_ERROR = abi.encodeWithSignature("EnforcedPause()");
    bytes public constant FREEZED_ACCOUNT_ERROR = "Freezed account";

    function setUp() public {
        vm.startPrank(ADMIN);
        address impl = address(new Stablecoin());
        address proxy = address(
            new ERC1967Proxy(
                impl,
                abi.encodeCall(Stablecoin.initialize, ("Stablecoin", "Stablecoin", ADMIN, BURNER, PAUSER, FREEZER))
            )
        );
        stablecoin = Stablecoin(proxy);
        stablecoin.addMinter(MINTER, 1000);
        vm.stopPrank();
    }

    function test_AddMinter() public {
        address newMinter = address(1);
        uint256 amount = 1000;
        vm.prank(ADMIN);
        stablecoin.addMinter(newMinter, amount);

        bool hasRole = stablecoin.hasRole(stablecoin.MINTER_ROLE(), newMinter);
        assertTrue(hasRole);
        assertEq(stablecoin.minterAllowance(newMinter), amount);

        vm.prank(newMinter);
        stablecoin.mint(newMinter, amount);
        assertEq(stablecoin.balanceOf(newMinter), amount);
        assertEq(stablecoin.minterAllowance(newMinter), 0);
    }

    function test_Transfer() public {
        address sender = address(1);
        address receiver = address(2);
        uint256 totalAmount = 1000;
        uint256 transferredAmount = 100;

        vm.prank(MINTER);
        stablecoin.mint(sender, totalAmount);

        vm.prank(sender);
        assertTrue(stablecoin.transfer(receiver, transferredAmount));

        assertEq(stablecoin.balanceOf(sender), totalAmount - transferredAmount);
        assertEq(stablecoin.balanceOf(receiver), transferredAmount);
    }

    function test_Approve() public {
        address owner = address(1);
        address spender = address(2);
        uint256 amount = 1000;

        vm.prank(owner);
        assertTrue(stablecoin.approve(spender, amount));

        assertEq(stablecoin.allowance(owner, spender), amount);
    }

    function test_ApproveAndTransferFrom() public {
        address owner = address(1);
        address spender = address(2);
        address receiver = address(3);
        uint256 amount = 1000;

        vm.prank(MINTER);
        stablecoin.mint(owner, amount);

        uint256 ownerBalance = stablecoin.balanceOf(owner);
        uint256 receiverBalance = stablecoin.balanceOf(receiver);

        vm.prank(owner);
        assertTrue(stablecoin.approve(spender, amount));

        vm.prank(spender);
        stablecoin.transferFrom(owner, receiver, amount);

        assertEq(stablecoin.balanceOf(owner), ownerBalance - amount);
        assertEq(stablecoin.balanceOf(receiver), receiverBalance + amount);
    }

    function test_MinterCannotMintMoreThanAllowance() public {
        address newMinter = address(1);
        uint256 amount = 1000;
        vm.prank(ADMIN);
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
        vm.prank(MINTER);
        stablecoin.mint(BURNER, amount);
        uint256 burnerBalance = stablecoin.balanceOf(BURNER);

        // Burn the burner tokens
        vm.prank(BURNER);
        stablecoin.burn(amount);

        uint256 expectedBalance = burnerBalance - amount;
        assertEq(stablecoin.balanceOf(BURNER), expectedBalance);
    }

    function test_BurnFrom() public {
        address account = address(3);
        uint256 amount = 100;

        // Mint tokens to the account
        vm.prank(MINTER);
        stablecoin.mint(account, amount);
        uint256 initialAccountBalance = stablecoin.balanceOf(account);

        // Approve allowance to the burner from the account
        vm.prank(account);
        stablecoin.approve(BURNER, amount);

        vm.prank(BURNER);
        stablecoin.burnFrom(account, amount);
        assertEq(stablecoin.balanceOf(BURNER), initialAccountBalance - amount);
    }

    function test_NonBurnerAccountCannotBurn() public {
        address nonBurnerAccount = address(3);
        uint256 amount = 1000;
        vm.prank(nonBurnerAccount);
        vm.expectRevert();
        stablecoin.burn(amount);
    }

    function test_PauseUnpause() public {
        vm.prank(PAUSER);
        stablecoin.pause();
        assertTrue(stablecoin.paused());

        vm.prank(PAUSER);
        stablecoin.unpause();
        assertFalse(stablecoin.paused());
    }

    // TODO: test more functions when paused
    function test_CannotMintWhenPaused() public {
        vm.prank(PAUSER);
        stablecoin.pause();

        vm.prank(MINTER);
        vm.expectRevert(ENFORCED_PAUSE_ERROR);
        stablecoin.mint(MINTER, 1000);
    }

    function test_CannotBurnWhenPaused() public {
        vm.prank(PAUSER);
        stablecoin.pause();

        vm.prank(BURNER);
        vm.expectRevert(ENFORCED_PAUSE_ERROR);
        stablecoin.burn(1000);

        address account = address(1);
        vm.prank(BURNER);
        vm.expectRevert(ENFORCED_PAUSE_ERROR);
        stablecoin.burnFrom(account, 1000);
    }

    function test_CannotTransferWhenPaused() public {
        address account = address(1);
        address otherAccount = address(2);
        vm.prank(PAUSER);
        stablecoin.pause();

        vm.prank(account);
        vm.expectRevert(ENFORCED_PAUSE_ERROR);
        stablecoin.transfer(otherAccount, 1000);
    }

    function test_CannotTransferFromWhenPaused() public {
        address owner = address(1);
        address spender = address(2);
        uint256 amount = 1000;

        vm.prank(owner);
        stablecoin.approve(spender, amount);

        vm.prank(PAUSER);
        stablecoin.pause();

        vm.prank(spender);
        vm.expectRevert(ENFORCED_PAUSE_ERROR);
        stablecoin.transferFrom(owner, spender, amount);
    }

    function test_CannotFreezeWhenPaused() public {
        address account = address(1);
        vm.prank(PAUSER);
        stablecoin.pause();

        vm.prank(FREEZER);
        vm.expectRevert(ENFORCED_PAUSE_ERROR);
        stablecoin.freeze(account);
    }

    function test_CannotUnfreezeWhenPaused() public {
        address account = address(1);
        vm.prank(PAUSER);
        stablecoin.pause();

        vm.prank(FREEZER);
        vm.expectRevert(ENFORCED_PAUSE_ERROR);
        stablecoin.unfreeze(account);
    }

    function test_CannotAddMinterWhenPaused() public {
        address account = address(1);
        vm.prank(PAUSER);
        stablecoin.pause();

        vm.prank(ADMIN);
        vm.expectRevert(ENFORCED_PAUSE_ERROR);
        stablecoin.addMinter(account, 1000);
    }

    function test_CannotMintToFreezedAccount() public {
        address freezedAccount = address(1);
        uint256 amount = 1000;

        vm.prank(FREEZER);
        stablecoin.freeze(freezedAccount);

        vm.prank(MINTER);
        vm.expectRevert(FREEZED_ACCOUNT_ERROR);
        stablecoin.mint(freezedAccount, amount);
    }

    function test_CannotTransferFromFreezedAccount() public {
        address freezedAccount = address(1);
        address otherAccount = address(2);
        uint256 amount = 1000;

        vm.prank(FREEZER);
        stablecoin.freeze(freezedAccount);

        vm.prank(freezedAccount);
        vm.expectRevert(FREEZED_ACCOUNT_ERROR);
        stablecoin.transfer(otherAccount, amount);
    }

    function test_CannotTransferToFreezedAccount() public {
        address freezedAccount = address(1);
        address otherAccount = address(2);
        uint256 amount = 1000;

        vm.prank(FREEZER);
        stablecoin.freeze(freezedAccount);

        vm.prank(otherAccount);
        vm.expectRevert(FREEZED_ACCOUNT_ERROR);
        stablecoin.transfer(freezedAccount, amount);
    }

    function test_CannotCallTransferFromWhenSpenderIsFreezed() public {
        address owner = address(1);
        address spender = address(2);
        address receiver = address(3);
        uint256 amount = 1000;

        vm.prank(owner);
        stablecoin.approve(spender, amount);

        // Freeze the spender
        vm.prank(FREEZER);
        stablecoin.freeze(spender);

        vm.prank(spender);
        vm.expectRevert(FREEZED_ACCOUNT_ERROR);
        stablecoin.transferFrom(owner, receiver, amount);
    }

    function test_CannotCallTransferFromWhenOwnerIsFreezed() public {
        address owner = address(1);
        address spender = address(2);
        address receiver = address(3);
        uint256 amount = 1000;

        vm.prank(owner);
        stablecoin.approve(spender, amount);

        // Freeze the owner
        vm.prank(FREEZER);
        stablecoin.freeze(owner);

        vm.prank(spender);
        vm.expectRevert(FREEZED_ACCOUNT_ERROR);
        stablecoin.transferFrom(owner, receiver, amount);
    }

    function test_CannotCallTransferFromWhenReceiverIsFreezed() public {
        address owner = address(1);
        address spender = address(2);
        address receiver = address(3);
        uint256 amount = 1000;

        vm.prank(owner);
        stablecoin.approve(spender, amount);

        // Freeze the receiver
        vm.prank(FREEZER);
        stablecoin.freeze(receiver);

        vm.prank(spender);
        vm.expectRevert(FREEZED_ACCOUNT_ERROR);
        stablecoin.transferFrom(owner, receiver, amount);
    }

    function test_UnfreezeAccount() public {
        address account = address(1);

        // Freeze the account
        vm.prank(FREEZER);
        stablecoin.freeze(account);
        assertTrue(stablecoin.freezed(account));

        // Unfreeze the account
        vm.prank(FREEZER);
        stablecoin.unfreeze(account);
        assertFalse(stablecoin.freezed(account));
    }
}
