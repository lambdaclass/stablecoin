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
    bytes public constant FREEZED_ACCOUNT_ERROR = "Frozen account";

    function setUp() public {
        vm.startPrank(ADMIN);
        Stablecoin impl = new Stablecoin();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeCall(Stablecoin.initialize, ("Stablecoin", "Stablecoin", ADMIN, BURNER, PAUSER, FREEZER))
        );
        stablecoin = Stablecoin(address(proxy));
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

    function test_OnlyAdminCanAddMinter() public {
        address newMinter = address(1);
        uint256 amount = 1000;
        address nonAdmin = address(2);

        bytes memory expectedError = abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)", nonAdmin, stablecoin.ADMIN_ROLE()
        );
        vm.prank(nonAdmin);
        vm.expectRevert(expectedError);
        stablecoin.addMinter(newMinter, amount);
    }

    function test_RemoveMinter() public {
        address newMinter = address(1);
        uint256 amount = 1000;
        vm.startPrank(ADMIN);
        stablecoin.addMinter(newMinter, amount);
        stablecoin.removeMinter(newMinter);
        vm.stopPrank();

        // Check the role is revoked and allowance is set to 0
        assertFalse(stablecoin.hasRole(stablecoin.MINTER_ROLE(), newMinter));
        assertEq(stablecoin.minterAllowance(newMinter), 0);
    }

    function test_IncreaseMinterAllowance() public {
        uint256 amount = 1000;
        uint256 minterAllowance = stablecoin.minterAllowance(MINTER);

        vm.startPrank(ADMIN);
        stablecoin.increaseMinterAllowance(MINTER, amount);
        vm.stopPrank();

        assertEq(stablecoin.minterAllowance(MINTER), minterAllowance + amount);
    }

    function test_OnlyAdminCanIncreaseMinterAllowance() public {
        address nonAdmin = address(2);
        uint256 amount = 1000;

        bytes memory expectedError = abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)", nonAdmin, stablecoin.ADMIN_ROLE()
        );

        vm.prank(nonAdmin);
        vm.expectRevert(expectedError);
        stablecoin.increaseMinterAllowance(MINTER, amount);
    }

    function test_OnlyAdminCanRemoveMinter() public {
        address newMinter = address(1);
        uint256 amount = 1000;
        address nonAdmin = address(2);

        vm.prank(ADMIN);
        stablecoin.addMinter(newMinter, amount);

        bytes memory expectedError = abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)", nonAdmin, stablecoin.ADMIN_ROLE()
        );
        vm.prank(nonAdmin);
        vm.expectRevert(expectedError);
        stablecoin.removeMinter(newMinter);
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
        bytes memory expectedError = abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)", nonMinter, stablecoin.MINTER_ROLE()
        );
        vm.prank(nonMinter);
        vm.expectRevert(expectedError);
        stablecoin.mint(nonMinter, amount);
    }

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
        bytes memory expectedError = abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)", nonBurnerAccount, stablecoin.BURNER_ROLE()
        );

        vm.prank(nonBurnerAccount);
        vm.expectRevert(expectedError);
        stablecoin.burn(amount);

        vm.prank(nonBurnerAccount);
        vm.expectRevert(expectedError);
        stablecoin.burnFrom(nonBurnerAccount, amount);
    }

    function test_PauseUnpause() public {
        vm.prank(PAUSER);
        stablecoin.pause();
        assertTrue(stablecoin.paused());

        vm.prank(PAUSER);
        stablecoin.unpause();
        assertFalse(stablecoin.paused());
    }

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

    function test_CannotMintToFrozenAccount() public {
        address frozenAccount = address(1);
        uint256 amount = 1000;

        vm.prank(FREEZER);
        stablecoin.freeze(frozenAccount);

        vm.prank(MINTER);
        vm.expectRevert(FREEZED_ACCOUNT_ERROR);
        stablecoin.mint(frozenAccount, amount);
    }

    function test_CannotTransferFromFrozenAccount() public {
        address frozenAccount = address(1);
        address otherAccount = address(2);
        uint256 amount = 1000;

        vm.prank(FREEZER);
        stablecoin.freeze(frozenAccount);

        vm.prank(frozenAccount);
        vm.expectRevert(FREEZED_ACCOUNT_ERROR);
        stablecoin.transfer(otherAccount, amount);
    }

    function test_CannotTransferToFrozenAccount() public {
        address frozenAccount = address(1);
        address otherAccount = address(2);
        uint256 amount = 1000;

        vm.prank(FREEZER);
        stablecoin.freeze(frozenAccount);

        vm.prank(otherAccount);
        vm.expectRevert(FREEZED_ACCOUNT_ERROR);
        stablecoin.transfer(frozenAccount, amount);
    }

    function test_CannotCallTransferFromWhenSpenderIsFrozen() public {
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

    function test_CannotCallTransferFromWhenOwnerIsFrozen() public {
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

    function test_CannotCallTransferFromWhenReceiverIsFrozen() public {
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
        assertTrue(stablecoin.frozen(account));

        // Unfreeze the account
        vm.prank(FREEZER);
        stablecoin.unfreeze(account);
        assertFalse(stablecoin.frozen(account));
    }
}
