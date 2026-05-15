// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.30;

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
            abi.encodeCall(Stablecoin.initialize, ("Stablecoin", "STBL", 6, ADMIN, BURNER, PAUSER, FREEZER))
        );
        stablecoin = Stablecoin(address(proxy));
        stablecoin.addMinter(MINTER, 1000);
        vm.stopPrank();
    }

    function test_AddMinter() public {
        address newMinter = address(1);
        uint256 amount = 1000;
        vm.prank(ADMIN);
        vm.expectEmit();
        emit Stablecoin.MinterAdded(newMinter, amount);
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

    function test_CannotAddExistingMinter() public {
        address newMinter = address(1);
        uint256 amount = 1000;

        vm.startPrank(ADMIN);
        stablecoin.addMinter(newMinter, amount);

        // Try to add the same minter again - should revert
        vm.expectRevert("Minter already exists");
        stablecoin.addMinter(newMinter, amount);
        vm.stopPrank();
    }

    function test_RemoveMinter() public {
        address newMinter = address(1);
        uint256 amount = 1000;
        vm.startPrank(ADMIN);
        stablecoin.addMinter(newMinter, amount);
        vm.expectEmit();
        emit Stablecoin.MinterRemoved(newMinter);
        stablecoin.removeMinter(newMinter);
        vm.stopPrank();

        // Check the role is revoked and allowance is set to 0
        assertFalse(stablecoin.hasRole(stablecoin.MINTER_ROLE(), newMinter));
        assertEq(stablecoin.minterAllowance(newMinter), 0);
    }

    function test_ModifyMinterAllowanceIncreasesByDelta() public {
        uint256 oldAllowance = stablecoin.minterAllowance(MINTER);
        int256 delta = 4000;
        uint256 newAllowance = oldAllowance + uint256(delta);

        vm.startPrank(ADMIN);
        vm.expectEmit();
        emit Stablecoin.MinterAllowanceChanged(MINTER, oldAllowance, newAllowance);
        stablecoin.modifyMinterAllowance(MINTER, delta);
        vm.stopPrank();

        assertEq(stablecoin.minterAllowance(MINTER), newAllowance);
    }

    function test_ModifyMinterAllowanceDecreasesByDelta() public {
        uint256 initialAllowance = stablecoin.minterAllowance(MINTER);
        int256 delta = -int256(initialAllowance / 2);

        vm.startPrank(ADMIN);
        stablecoin.modifyMinterAllowance(MINTER, delta);
        vm.stopPrank();

        assertEq(stablecoin.minterAllowance(MINTER), initialAllowance - uint256(-delta));
    }

    function test_ModifyMinterAllowanceNegativeDeltaSaturatesAtZero() public {
        uint256 initialAllowance = stablecoin.minterAllowance(MINTER);

        vm.prank(ADMIN);
        stablecoin.modifyMinterAllowance(MINTER, -int256(initialAllowance) - 1);

        assertEq(stablecoin.minterAllowance(MINTER), 0);
    }

    function test_OnlyAdminCanModifyMinterAllowance() public {
        address nonAdmin = address(2);

        bytes memory expectedError = abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)", nonAdmin, stablecoin.ADMIN_ROLE()
        );

        vm.prank(nonAdmin);
        vm.expectRevert(expectedError);
        stablecoin.modifyMinterAllowance(MINTER, 1000);
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
        uint256 totalSupplyBefore = stablecoin.totalSupply();

        // Burn the burner tokens
        vm.prank(BURNER);
        stablecoin.burn(amount);

        uint256 expectedBalance = burnerBalance - amount;
        assertEq(stablecoin.balanceOf(BURNER), expectedBalance);
        assertEq(stablecoin.totalSupply(), totalSupplyBefore - amount);
    }

    function test_BurnFrom() public {
        address account = address(3);
        uint256 amount = 100;

        // Mint tokens to the account
        vm.prank(MINTER);
        stablecoin.mint(account, amount);
        uint256 initialAccountBalance = stablecoin.balanceOf(account);
        uint256 totalSupplyBefore = stablecoin.totalSupply();

        // Approve allowance to the burner from the account
        vm.prank(account);
        stablecoin.approve(BURNER, amount);

        vm.prank(BURNER);
        stablecoin.burnFrom(account, amount);

        // burnFrom burns tokens from `account`, not from the caller
        assertEq(stablecoin.balanceOf(account), initialAccountBalance - amount);
        assertEq(stablecoin.totalSupply(), totalSupplyBefore - amount);
        // Allowance should be consumed
        assertEq(stablecoin.allowance(account, BURNER), 0);
    }

    function test_NonBurnerAccountCannotBurn() public {
        address nonBurnerAccount = address(3);
        uint256 amount = 100;

        // Give the account tokens first to ensure we're testing role, not balance
        vm.prank(MINTER);
        stablecoin.mint(nonBurnerAccount, amount);

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
        address account = address(1);
        uint256 amount = 100;

        // Setup: mint tokens to burner and account, set up approval
        vm.prank(MINTER);
        stablecoin.mint(BURNER, amount);
        vm.prank(MINTER);
        stablecoin.mint(account, amount);
        vm.prank(account);
        stablecoin.approve(BURNER, amount);

        // Now pause
        vm.prank(PAUSER);
        stablecoin.pause();

        vm.prank(BURNER);
        vm.expectRevert(ENFORCED_PAUSE_ERROR);
        stablecoin.burn(amount);

        vm.prank(BURNER);
        vm.expectRevert(ENFORCED_PAUSE_ERROR);
        stablecoin.burnFrom(account, amount);
    }

    function test_CannotTransferWhenPaused() public {
        address account = address(1);
        address otherAccount = address(2);
        uint256 amount = 100;

        // Give account tokens first
        vm.prank(MINTER);
        stablecoin.mint(account, amount);

        vm.prank(PAUSER);
        stablecoin.pause();

        vm.prank(account);
        vm.expectRevert(ENFORCED_PAUSE_ERROR);
        bool success = stablecoin.transfer(otherAccount, amount);
        success; // Silence unused variable warning (call reverts before this)
    }

    function test_CannotTransferFromWhenPaused() public {
        address owner = address(1);
        address spender = address(2);
        uint256 amount = 100;

        // Give owner tokens first
        vm.prank(MINTER);
        stablecoin.mint(owner, amount);

        vm.prank(owner);
        stablecoin.approve(spender, amount);

        vm.prank(PAUSER);
        stablecoin.pause();

        vm.prank(spender);
        vm.expectRevert(ENFORCED_PAUSE_ERROR);
        bool success = stablecoin.transferFrom(owner, spender, amount);
        success; // Silence unused variable warning (call reverts before this)
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

        // First freeze the account while not paused
        vm.prank(FREEZER);
        stablecoin.freeze(account);
        assertTrue(stablecoin.frozen(account));

        // Now pause
        vm.prank(PAUSER);
        stablecoin.pause();

        // Cannot unfreeze when paused
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
        uint256 amount = 100;

        // Give the frozen account tokens first
        vm.prank(MINTER);
        stablecoin.mint(frozenAccount, amount);

        vm.prank(FREEZER);
        stablecoin.freeze(frozenAccount);

        vm.prank(frozenAccount);
        vm.expectRevert(FREEZED_ACCOUNT_ERROR);
        bool success = stablecoin.transfer(otherAccount, amount);
        success; // Silence unused variable warning (call reverts before this)
    }

    function test_CannotTransferToFrozenAccount() public {
        address frozenAccount = address(1);
        address otherAccount = address(2);
        uint256 amount = 100;

        // Give the sender tokens first
        vm.prank(MINTER);
        stablecoin.mint(otherAccount, amount);

        vm.prank(FREEZER);
        stablecoin.freeze(frozenAccount);

        vm.prank(otherAccount);
        vm.expectRevert(FREEZED_ACCOUNT_ERROR);
        bool success = stablecoin.transfer(frozenAccount, amount);
        success; // Silence unused variable warning (call reverts before this)
    }

    function test_CannotCallTransferFromWhenSpenderIsFrozen() public {
        address owner = address(1);
        address spender = address(2);
        address receiver = address(3);
        uint256 amount = 100;

        // Give owner tokens first
        vm.prank(MINTER);
        stablecoin.mint(owner, amount);

        vm.prank(owner);
        stablecoin.approve(spender, amount);

        // Freeze the spender
        vm.prank(FREEZER);
        stablecoin.freeze(spender);

        vm.prank(spender);
        vm.expectRevert(FREEZED_ACCOUNT_ERROR);
        bool success = stablecoin.transferFrom(owner, receiver, amount);
        success; // Silence unused variable warning (call reverts before this)
    }

    function test_CannotCallTransferFromWhenOwnerIsFrozen() public {
        address owner = address(1);
        address spender = address(2);
        address receiver = address(3);
        uint256 amount = 100;

        // Give owner tokens first
        vm.prank(MINTER);
        stablecoin.mint(owner, amount);

        vm.prank(owner);
        stablecoin.approve(spender, amount);

        // Freeze the owner
        vm.prank(FREEZER);
        stablecoin.freeze(owner);

        vm.prank(spender);
        vm.expectRevert(FREEZED_ACCOUNT_ERROR);
        bool success = stablecoin.transferFrom(owner, receiver, amount);
        success; // Silence unused variable warning (call reverts before this)
    }

    function test_CannotCallTransferFromWhenReceiverIsFrozen() public {
        address owner = address(1);
        address spender = address(2);
        address receiver = address(3);
        uint256 amount = 100;

        // Give owner tokens first
        vm.prank(MINTER);
        stablecoin.mint(owner, amount);

        vm.prank(owner);
        stablecoin.approve(spender, amount);

        // Freeze the receiver
        vm.prank(FREEZER);
        stablecoin.freeze(receiver);

        vm.prank(spender);
        vm.expectRevert(FREEZED_ACCOUNT_ERROR);
        bool success = stablecoin.transferFrom(owner, receiver, amount);
        success; // Silence unused variable warning (call reverts before this)
    }

    function test_UnfreezeAccount() public {
        address account = address(1);

        // Freeze the account
        vm.prank(FREEZER);
        vm.expectEmit();
        emit Stablecoin.AccountFrozen(account);
        stablecoin.freeze(account);
        assertTrue(stablecoin.frozen(account));

        // Unfreeze the account
        vm.prank(FREEZER);
        vm.expectEmit();
        emit Stablecoin.AccountUnfrozen(account);
        stablecoin.unfreeze(account);
        assertFalse(stablecoin.frozen(account));
    }

    function test_NonAdminCannotUpgrade() public {
        address nonAdmin = address(1);
        address newImplementation = address(2);
        bytes memory data = hex"";
        bytes memory expectedError = abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)", nonAdmin, stablecoin.ADMIN_ROLE()
        );

        vm.prank(nonAdmin);
        vm.expectRevert(expectedError);
        stablecoin.upgradeToAndCall(newImplementation, data);
    }

    // ============ Minter Enumeration Tests ============

    function test_GetAllMinters() public {
        // Initial state: MINTER was added in setUp with allowance 1000
        Stablecoin.MinterInfo[] memory minters = stablecoin.getAllMinters();
        assertEq(minters.length, 1);
        assertEq(minters[0].minter, MINTER);
        assertEq(minters[0].allowance, 1000);

        // Add more minters
        address minter2 = address(0x100);
        address minter3 = address(0x101);
        vm.startPrank(ADMIN);
        stablecoin.addMinter(minter2, 2000);
        stablecoin.addMinter(minter3, 3000);
        vm.stopPrank();

        minters = stablecoin.getAllMinters();
        assertEq(minters.length, 3);

        // Verify all minters are present (order may vary due to EnumerableSet)
        uint256 totalAllowance = 0;
        for (uint256 i = 0; i < minters.length; i++) {
            totalAllowance += minters[i].allowance;
        }
        assertEq(totalAllowance, 1000 + 2000 + 3000);
    }

    function test_GetMinterCount() public {
        // Initial state: 1 minter from setUp
        assertEq(stablecoin.getMinterCount(), 1);

        // Add another minter
        vm.prank(ADMIN);
        stablecoin.addMinter(address(0x100), 1000);
        assertEq(stablecoin.getMinterCount(), 2);

        // Remove a minter
        vm.prank(ADMIN);
        stablecoin.removeMinter(MINTER);
        assertEq(stablecoin.getMinterCount(), 1);
    }

    function test_CannotRemoveNonExistentMinter() public {
        address nonMinter = address(0x999);
        vm.prank(ADMIN);
        vm.expectRevert("Minter does not exist");
        stablecoin.removeMinter(nonMinter);
    }

    function test_CannotModifyNonExistentMinterAllowance() public {
        address nonMinter = address(0x999);
        vm.prank(ADMIN);
        vm.expectRevert("Minter does not exist");
        stablecoin.modifyMinterAllowance(nonMinter, int256(1000));
    }

    // ============ Burner Enumeration Tests ============

    function test_GetAllBurners() public {
        // Initial state: BURNER was granted in initialize
        address[] memory burners = stablecoin.getAllBurners();
        assertEq(burners.length, 1);
        assertEq(burners[0], BURNER);

        // Add another burner
        address burner2 = address(0x200);
        bytes32 burnerRole = stablecoin.BURNER_ROLE();
        vm.prank(ADMIN);
        stablecoin.grantRole(burnerRole, burner2);

        burners = stablecoin.getAllBurners();
        assertEq(burners.length, 2);
    }

    function test_GetBurnerCount() public {
        // Initial state: 1 burner from initialize
        assertEq(stablecoin.getBurnerCount(), 1);

        // Add another burner
        address burner2 = address(0x200);
        bytes32 burnerRole = stablecoin.BURNER_ROLE();
        vm.prank(ADMIN);
        stablecoin.grantRole(burnerRole, burner2);
        assertEq(stablecoin.getBurnerCount(), 2);

        // Revoke a burner
        vm.prank(ADMIN);
        stablecoin.revokeRole(burnerRole, BURNER);
        assertEq(stablecoin.getBurnerCount(), 1);
    }

    function test_GetAllBurnersAfterRevoke() public {
        // Add a second burner, then revoke the first
        address burner2 = address(0x200);
        bytes32 burnerRole = stablecoin.BURNER_ROLE();
        vm.startPrank(ADMIN);
        stablecoin.grantRole(burnerRole, burner2);
        stablecoin.revokeRole(burnerRole, BURNER);
        vm.stopPrank();

        address[] memory burners = stablecoin.getAllBurners();
        assertEq(burners.length, 1);
        assertEq(burners[0], burner2);
    }

    // ============ Burn Edge Cases ============

    function test_CannotBurnMoreThanBalance() public {
        uint256 mintAmount = 100;
        vm.prank(MINTER);
        stablecoin.mint(BURNER, mintAmount);

        // Try to burn more than balance
        vm.prank(BURNER);
        vm.expectRevert(
            abi.encodeWithSignature(
                "ERC20InsufficientBalance(address,uint256,uint256)", BURNER, mintAmount, mintAmount + 1
            )
        );
        stablecoin.burn(mintAmount + 1);
    }

    function test_MintToSelf() public {
        uint256 amount = 500;
        uint256 initialAllowance = stablecoin.minterAllowance(MINTER);

        vm.prank(MINTER);
        stablecoin.mint(MINTER, amount);

        assertEq(stablecoin.balanceOf(MINTER), amount);
        assertEq(stablecoin.minterAllowance(MINTER), initialAllowance - amount);
    }

    // ============ Fuzz Tests ============

    function testFuzz_MintWithinAllowance(uint256 allowance, uint256 mintAmount) public {
        // Bound to uint128 to avoid overflow issues while still testing large values
        allowance = bound(allowance, 1, type(uint128).max);
        mintAmount = bound(mintAmount, 0, allowance);

        address testMinter = address(0x200);
        vm.prank(ADMIN);
        stablecoin.addMinter(testMinter, allowance);

        vm.prank(testMinter);
        stablecoin.mint(address(0x201), mintAmount);

        assertEq(stablecoin.minterAllowance(testMinter), allowance - mintAmount);
    }

    function testFuzz_MintExceedsAllowance(uint256 allowance, uint256 excess) public {
        allowance = bound(allowance, 1, type(uint128).max - 1);
        excess = bound(excess, 1, type(uint128).max);

        // Calculate mint amount with explicit overflow check
        uint256 mintAmount;
        unchecked {
            mintAmount = allowance + excess;
        }
        // Skip if overflow occurred (mintAmount wrapped around)
        vm.assume(mintAmount > allowance);

        address testMinter = address(0x200);
        vm.prank(ADMIN);
        stablecoin.addMinter(testMinter, allowance);

        vm.prank(testMinter);
        vm.expectRevert("Value exceeds allowance");
        stablecoin.mint(address(0x201), mintAmount);
    }

    function testFuzz_AddAndRemoveMinters(uint8 minterCount) public {
        minterCount = uint8(bound(minterCount, 1, 20)); // Reasonable number of minters

        address[] memory minters = new address[](minterCount);

        // Add minters
        vm.startPrank(ADMIN);
        for (uint8 i = 0; i < minterCount; i++) {
            minters[i] = address(uint160(0x300 + i));
            stablecoin.addMinter(minters[i], 1000 * (i + 1));
        }
        vm.stopPrank();

        // +1 for the MINTER added in setUp
        assertEq(stablecoin.getMinterCount(), minterCount + 1);

        // Remove all added minters
        vm.startPrank(ADMIN);
        for (uint8 i = 0; i < minterCount; i++) {
            stablecoin.removeMinter(minters[i]);
        }
        vm.stopPrank();

        assertEq(stablecoin.getMinterCount(), 1); // Only original MINTER remains
    }

    // ============ Missing Coverage Tests ============

    function test_FrozenMinterCannotMint() public {
        address recipient = address(1);
        uint256 amount = 100;

        // Freeze the minter
        vm.prank(FREEZER);
        stablecoin.freeze(MINTER);

        // Frozen minter cannot mint (msg.sender is checked in _update)
        vm.prank(MINTER);
        vm.expectRevert(FREEZED_ACCOUNT_ERROR);
        stablecoin.mint(recipient, amount);
    }

    function test_FrozenBurnerCannotBurn() public {
        uint256 amount = 100;

        // Mint tokens to burner first
        vm.prank(MINTER);
        stablecoin.mint(BURNER, amount);

        // Freeze the burner
        vm.prank(FREEZER);
        stablecoin.freeze(BURNER);

        // Frozen burner cannot burn (msg.sender is checked in _update)
        vm.prank(BURNER);
        vm.expectRevert(FREEZED_ACCOUNT_ERROR);
        stablecoin.burn(amount);
    }

    function test_FrozenBurnerCannotBurnFrom() public {
        address account = address(1);
        uint256 amount = 100;

        // Mint tokens to account and approve burner
        vm.prank(MINTER);
        stablecoin.mint(account, amount);
        vm.prank(account);
        stablecoin.approve(BURNER, amount);

        // Freeze the burner
        vm.prank(FREEZER);
        stablecoin.freeze(BURNER);

        // Frozen burner cannot burnFrom (msg.sender is checked in _update)
        vm.prank(BURNER);
        vm.expectRevert(FREEZED_ACCOUNT_ERROR);
        stablecoin.burnFrom(account, amount);
    }

    function test_CannotRemoveMinterWhenPaused() public {
        vm.prank(PAUSER);
        stablecoin.pause();

        vm.prank(ADMIN);
        vm.expectRevert(ENFORCED_PAUSE_ERROR);
        stablecoin.removeMinter(MINTER);
    }

    function test_CannotModifyMinterAllowanceWhenPaused() public {
        vm.prank(PAUSER);
        stablecoin.pause();

        vm.prank(ADMIN);
        vm.expectRevert(ENFORCED_PAUSE_ERROR);
        stablecoin.modifyMinterAllowance(MINTER, 5000);
    }

    // ============ Role Permission Tests ============

    function test_OnlyPauserCanPause() public {
        address nonPauser = address(1);
        bytes memory expectedError = abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)", nonPauser, stablecoin.PAUSER_ROLE()
        );

        vm.prank(nonPauser);
        vm.expectRevert(expectedError);
        stablecoin.pause();
    }

    function test_OnlyPauserCanUnpause() public {
        // First pause the contract
        vm.prank(PAUSER);
        stablecoin.pause();

        address nonPauser = address(1);
        bytes memory expectedError = abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)", nonPauser, stablecoin.PAUSER_ROLE()
        );

        vm.prank(nonPauser);
        vm.expectRevert(expectedError);
        stablecoin.unpause();
    }

    function test_OnlyFreezerCanFreeze() public {
        address nonFreezer = address(1);
        address target = address(2);
        bytes memory expectedError = abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)", nonFreezer, stablecoin.FREEZER_ROLE()
        );

        vm.prank(nonFreezer);
        vm.expectRevert(expectedError);
        stablecoin.freeze(target);
    }

    function test_OnlyFreezerCanUnfreeze() public {
        address target = address(2);

        // First freeze the target
        vm.prank(FREEZER);
        stablecoin.freeze(target);

        address nonFreezer = address(1);
        bytes memory expectedError = abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)", nonFreezer, stablecoin.FREEZER_ROLE()
        );

        vm.prank(nonFreezer);
        vm.expectRevert(expectedError);
        stablecoin.unfreeze(target);
    }

    // ============ Token Metadata Tests ============

    function test_TokenMetadata() public view {
        assertEq(stablecoin.name(), "Stablecoin");
        assertEq(stablecoin.symbol(), "STBL");
        assertEq(stablecoin.decimals(), 6);
    }

    // ============ Zero Address Tests ============

    function test_CannotMintToZeroAddress() public {
        vm.prank(MINTER);
        vm.expectRevert(abi.encodeWithSignature("ERC20InvalidReceiver(address)", address(0)));
        stablecoin.mint(address(0), 100);
    }

    function test_CannotTransferToZeroAddress() public {
        // Mint tokens first
        vm.prank(MINTER);
        stablecoin.mint(address(1), 100);

        vm.prank(address(1));
        vm.expectRevert(abi.encodeWithSignature("ERC20InvalidReceiver(address)", address(0)));
        bool success = stablecoin.transfer(address(0), 100);
        success; // Silence unused variable warning (call reverts before this)
    }

    // ============ BurnFrom Edge Cases ============

    function test_BurnFromWithInsufficientAllowance() public {
        address account = address(1);
        uint256 mintAmount = 100;
        uint256 approveAmount = 50;
        uint256 burnAmount = 75;

        // Mint tokens to account
        vm.prank(MINTER);
        stablecoin.mint(account, mintAmount);

        // Approve less than burn amount
        vm.prank(account);
        stablecoin.approve(BURNER, approveAmount);

        vm.prank(BURNER);
        vm.expectRevert(
            abi.encodeWithSignature(
                "ERC20InsufficientAllowance(address,uint256,uint256)", BURNER, approveAmount, burnAmount
            )
        );
        stablecoin.burnFrom(account, burnAmount);
    }

    function test_BurnFromFrozenAccount() public {
        address account = address(1);
        uint256 amount = 100;

        // Mint tokens to account and approve
        vm.prank(MINTER);
        stablecoin.mint(account, amount);
        vm.prank(account);
        stablecoin.approve(BURNER, amount);

        // Freeze the account (token holder)
        vm.prank(FREEZER);
        stablecoin.freeze(account);

        // Burner cannot burn from frozen account
        vm.prank(BURNER);
        vm.expectRevert(FREEZED_ACCOUNT_ERROR);
        stablecoin.burnFrom(account, amount);
    }

    // ============ Transfer Tests ============

    function test_SuccessfulTransfer() public {
        address sender = address(1);
        address receiver = address(2);
        uint256 amount = 100;

        vm.prank(MINTER);
        stablecoin.mint(sender, amount);

        vm.prank(sender);
        bool success = stablecoin.transfer(receiver, amount);
        assertTrue(success);

        assertEq(stablecoin.balanceOf(sender), 0);
        assertEq(stablecoin.balanceOf(receiver), amount);
    }

    function test_SuccessfulTransferFrom() public {
        address owner = address(1);
        address spender = address(2);
        address receiver = address(3);
        uint256 amount = 100;

        vm.prank(MINTER);
        stablecoin.mint(owner, amount);

        vm.prank(owner);
        stablecoin.approve(spender, amount);

        vm.prank(spender);
        bool success = stablecoin.transferFrom(owner, receiver, amount);
        assertTrue(success);

        assertEq(stablecoin.balanceOf(owner), 0);
        assertEq(stablecoin.balanceOf(receiver), amount);
        assertEq(stablecoin.allowance(owner, spender), 0);
    }

    // ============ Zero Amount Operations ============

    function test_MintZeroAmount() public {
        address recipient = address(1);
        uint256 initialBalance = stablecoin.balanceOf(recipient);
        uint256 initialSupply = stablecoin.totalSupply();
        uint256 initialAllowance = stablecoin.minterAllowance(MINTER);

        vm.prank(MINTER);
        stablecoin.mint(recipient, 0);

        assertEq(stablecoin.balanceOf(recipient), initialBalance);
        assertEq(stablecoin.totalSupply(), initialSupply);
        // Zero mint should not consume any allowance
        assertEq(stablecoin.minterAllowance(MINTER), initialAllowance);
    }

    function test_TransferZeroAmount() public {
        address sender = address(1);
        address receiver = address(2);

        // Give sender tokens
        vm.prank(MINTER);
        stablecoin.mint(sender, 100);

        uint256 senderBalanceBefore = stablecoin.balanceOf(sender);
        uint256 receiverBalanceBefore = stablecoin.balanceOf(receiver);

        vm.prank(sender);
        bool success = stablecoin.transfer(receiver, 0);
        assertTrue(success);

        assertEq(stablecoin.balanceOf(sender), senderBalanceBefore);
        assertEq(stablecoin.balanceOf(receiver), receiverBalanceBefore);
    }

    // ============ Minting Allowance Tracking ============

    function test_MintingDecreasesAllowance() public {
        uint256 initialAllowance = stablecoin.minterAllowance(MINTER);
        uint256 mintAmount = 500;

        vm.prank(MINTER);
        stablecoin.mint(address(1), mintAmount);

        assertEq(stablecoin.minterAllowance(MINTER), initialAllowance - mintAmount);
    }

    function test_MultipleMints() public {
        uint256 initialAllowance = stablecoin.minterAllowance(MINTER);
        uint256 firstMint = 300;
        uint256 secondMint = 200;

        vm.startPrank(MINTER);
        stablecoin.mint(address(1), firstMint);
        stablecoin.mint(address(2), secondMint);
        vm.stopPrank();

        assertEq(stablecoin.minterAllowance(MINTER), initialAllowance - firstMint - secondMint);
        assertEq(stablecoin.balanceOf(address(1)), firstMint);
        assertEq(stablecoin.balanceOf(address(2)), secondMint);
        assertEq(stablecoin.totalSupply(), firstMint + secondMint);
    }

    // ============ Additional Edge Cases ============

    function test_BurnZeroAmount() public {
        uint256 amount = 100;

        // Mint tokens to burner first
        vm.prank(MINTER);
        stablecoin.mint(BURNER, amount);

        uint256 balanceBefore = stablecoin.balanceOf(BURNER);
        uint256 supplyBefore = stablecoin.totalSupply();

        // Burn zero
        vm.prank(BURNER);
        stablecoin.burn(0);

        assertEq(stablecoin.balanceOf(BURNER), balanceBefore);
        assertEq(stablecoin.totalSupply(), supplyBefore);
    }

    function test_FreezeAlreadyFrozenAccount() public {
        address account = address(1);

        // Freeze the account
        vm.prank(FREEZER);
        stablecoin.freeze(account);
        assertTrue(stablecoin.frozen(account));

        // Freeze again - should succeed (no-op, still frozen)
        vm.prank(FREEZER);
        vm.expectEmit();
        emit Stablecoin.AccountFrozen(account);
        stablecoin.freeze(account);
        assertTrue(stablecoin.frozen(account));
    }

    function test_UnfreezeNonFrozenAccount() public {
        address account = address(1);

        // Account is not frozen initially
        assertFalse(stablecoin.frozen(account));

        // Unfreeze non-frozen account - should succeed (no-op, still not frozen)
        vm.prank(FREEZER);
        vm.expectEmit();
        emit Stablecoin.AccountUnfrozen(account);
        stablecoin.unfreeze(account);
        assertFalse(stablecoin.frozen(account));
    }

    function test_ImplementationCannotBeInitialized() public {
        // Deploy a new implementation directly (not through proxy)
        Stablecoin impl = new Stablecoin();

        // Try to initialize it - should fail because constructor called _disableInitializers()
        vm.expectRevert(abi.encodeWithSignature("InvalidInitialization()"));
        impl.initialize("Test", "TST", 6, ADMIN, BURNER, PAUSER, FREEZER);
    }

    function test_AdminCanUpgrade() public {
        // Deploy a new implementation
        Stablecoin newImpl = new Stablecoin();

        // Admin should be able to upgrade
        vm.prank(ADMIN);
        stablecoin.upgradeToAndCall(address(newImpl), "");

        // Verify state is preserved after upgrade
        assertEq(stablecoin.name(), "Stablecoin");
        assertEq(stablecoin.symbol(), "STBL");
        assertEq(stablecoin.decimals(), 6);
        assertTrue(stablecoin.hasRole(stablecoin.MINTER_ROLE(), MINTER));
    }

    function test_TransferWithInsufficientBalance() public {
        address sender = address(1);
        address receiver = address(2);
        uint256 mintAmount = 50;
        uint256 transferAmount = 100;

        // Mint some tokens (less than transfer amount)
        vm.prank(MINTER);
        stablecoin.mint(sender, mintAmount);

        // Try to transfer more than balance
        vm.prank(sender);
        vm.expectRevert(
            abi.encodeWithSignature(
                "ERC20InsufficientBalance(address,uint256,uint256)", sender, mintAmount, transferAmount
            )
        );
        bool success = stablecoin.transfer(receiver, transferAmount);
        success; // Silence unused variable warning (call reverts before this)
    }

    function test_TransferFromWithInsufficientBalance() public {
        address owner = address(1);
        address spender = address(2);
        address receiver = address(3);
        uint256 mintAmount = 50;
        uint256 approveAmount = 100;
        uint256 transferAmount = 100;

        // Mint less than approve/transfer amount
        vm.prank(MINTER);
        stablecoin.mint(owner, mintAmount);

        // Approve full amount
        vm.prank(owner);
        stablecoin.approve(spender, approveAmount);

        // Try to transfer more than owner's balance (but within allowance)
        vm.prank(spender);
        vm.expectRevert(
            abi.encodeWithSignature(
                "ERC20InsufficientBalance(address,uint256,uint256)", owner, mintAmount, transferAmount
            )
        );
        bool success = stablecoin.transferFrom(owner, receiver, transferAmount);
        success; // Silence unused variable warning (call reverts before this)
    }

    function test_ApproveAndAllowance() public {
        address owner = address(1);
        address spender = address(2);
        uint256 amount = 500;

        assertEq(stablecoin.allowance(owner, spender), 0);

        vm.prank(owner);
        stablecoin.approve(spender, amount);

        assertEq(stablecoin.allowance(owner, spender), amount);
    }

    // ============ Minter Role Protection Tests ============

    function test_CannotDirectlyGrantMinterRole() public {
        address newMinter = address(0x500);
        // MINTER_ROLE has no role admin set (defaults to DEFAULT_ADMIN_ROLE = 0x00),
        // so grantRole reverts for everyone, including ADMIN
        bytes32 minterRole = stablecoin.MINTER_ROLE();
        bytes32 defaultAdminRole = stablecoin.DEFAULT_ADMIN_ROLE();
        bytes memory expectedError =
            abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", ADMIN, defaultAdminRole);

        vm.prank(ADMIN);
        vm.expectRevert(expectedError);
        stablecoin.grantRole(minterRole, newMinter);
    }

    function test_CannotDirectlyRevokeMinterRole() public {
        // MINTER was added in setUp, try to revoke directly
        bytes32 minterRole = stablecoin.MINTER_ROLE();
        bytes32 defaultAdminRole = stablecoin.DEFAULT_ADMIN_ROLE();
        bytes memory expectedError =
            abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", ADMIN, defaultAdminRole);

        vm.prank(ADMIN);
        vm.expectRevert(expectedError);
        stablecoin.revokeRole(minterRole, MINTER);
    }

    function test_AddMinterStillWorksWithInternalGrant() public {
        address newMinter = address(0x501);
        uint256 allowance = 5000;

        vm.prank(ADMIN);
        stablecoin.addMinter(newMinter, allowance);

        assertTrue(stablecoin.hasRole(stablecoin.MINTER_ROLE(), newMinter));
        assertEq(stablecoin.minterAllowance(newMinter), allowance);
    }

    function test_RemoveMinterStillWorksWithInternalRevoke() public {
        vm.prank(ADMIN);
        stablecoin.removeMinter(MINTER);

        assertFalse(stablecoin.hasRole(stablecoin.MINTER_ROLE(), MINTER));
        assertEq(stablecoin.minterAllowance(MINTER), 0);
    }

    function test_RemovedMinterCannotMint() public {
        address newMinter = address(1);
        uint256 allowance = 1000;

        // Add minter
        vm.prank(ADMIN);
        stablecoin.addMinter(newMinter, allowance);
        assertTrue(stablecoin.hasRole(stablecoin.MINTER_ROLE(), newMinter));

        // Remove minter
        vm.prank(ADMIN);
        stablecoin.removeMinter(newMinter);
        assertFalse(stablecoin.hasRole(stablecoin.MINTER_ROLE(), newMinter));

        // Try to mint - should fail due to missing role
        bytes memory expectedError = abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)", newMinter, stablecoin.MINTER_ROLE()
        );
        vm.prank(newMinter);
        vm.expectRevert(expectedError);
        stablecoin.mint(address(2), 100);
    }
}
