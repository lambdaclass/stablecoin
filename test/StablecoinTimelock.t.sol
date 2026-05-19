// SPDX-License-Identifier: Apache-2.0
pragma solidity =0.8.30;

import {Test} from "forge-std/Test.sol";
import {Stablecoin} from "../src/Stablecoin.sol";
import {StablecoinTimelock} from "../src/StablecoinTimelock.sol";
import {
    ERC1967Proxy
} from "lib/openzeppelin-contracts-upgradeable/lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract StablecoinTimelockTest is Test {
    Stablecoin internal stablecoin;
    StablecoinTimelock internal timelock;

    address internal constant ADMIN = address(0xA11CE);
    address internal constant PROPOSER = address(0xC0DE);
    uint256 internal constant DELAY = 1 days;

    function setUp() public {
        Stablecoin impl = new Stablecoin();
        bytes memory initData =
            abi.encodeCall(Stablecoin.initialize, ("Demo USD", "dUSD", 18, ADMIN, ADMIN, ADMIN, ADMIN));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        stablecoin = Stablecoin(address(proxy));

        address[] memory proposers = new address[](1);
        proposers[0] = PROPOSER;
        address[] memory executors = new address[](1);
        executors[0] = address(0); // open execution
        timelock = new StablecoinTimelock(stablecoin, DELAY, proposers, executors, address(0));

        vm.startPrank(ADMIN);
        stablecoin.grantRole(stablecoin.ADMIN_ROLE(), address(timelock));
        stablecoin.renounceRole(stablecoin.ADMIN_ROLE(), ADMIN);
        vm.stopPrank();
    }

    // ============ setup sanity ============

    function test_SetUpHandedOverAdminRole() public {
        bytes32 adminRole = stablecoin.ADMIN_ROLE();
        assertTrue(stablecoin.hasRole(adminRole, address(timelock)));
        assertFalse(stablecoin.hasRole(adminRole, ADMIN));
        assertEq(stablecoin.getRoleMemberCount(adminRole), 1);
    }

    // ============ construction guards ============

    function test_RevertsOnZeroStablecoin() public {
        address[] memory proposers = new address[](1);
        proposers[0] = PROPOSER;
        address[] memory executors = new address[](0);

        vm.expectRevert(StablecoinTimelock.ZeroStablecoin.selector);
        new StablecoinTimelock(Stablecoin(address(0)), DELAY, proposers, executors, address(0));
    }

    function test_AcceptsArbitraryMinDelay() public {
        // No hardcoded floor on minDelay — operators set whatever value they want.
        // The chosen value becomes the permanent floor via deploymentMinDelay.
        address[] memory proposers = new address[](1);
        proposers[0] = PROPOSER;
        address[] memory executors = new address[](0);

        StablecoinTimelock shortDelay = new StablecoinTimelock(stablecoin, 1, proposers, executors, address(0));
        assertEq(shortDelay.getMinDelay(), 1);
        assertEq(shortDelay.deploymentMinDelay(), 1);
    }

    function test_RevertsOnEmptyProposers() public {
        address[] memory proposers = new address[](0);
        address[] memory executors = new address[](0);

        vm.expectRevert(StablecoinTimelock.NoProposers.selector);
        new StablecoinTimelock(stablecoin, DELAY, proposers, executors, address(0));
    }

    function test_ConstructionStoresImmutableStablecoin() public {
        assertEq(address(timelock.stablecoin()), address(stablecoin));
        assertEq(timelock.deploymentMinDelay(), DELAY);
        assertEq(timelock.getMinDelay(), DELAY);
    }

    // ============ calldata helpers (for equivalence checks) ============

    function _adminCalldata(address newAdmin) internal view returns (bytes memory) {
        return abi.encodeCall(stablecoin.grantRole, (stablecoin.ADMIN_ROLE(), newAdmin));
    }

    function _revokeAdminCalldata(address oldAdmin) internal view returns (bytes memory) {
        return abi.encodeCall(stablecoin.revokeRole, (stablecoin.ADMIN_ROLE(), oldAdmin));
    }

    function _addMinterCalldata(address minter, uint256 cap) internal view returns (bytes memory) {
        return abi.encodeCall(stablecoin.addMinter, (minter, cap));
    }

    function _removeMinterCalldata(address minter) internal view returns (bytes memory) {
        return abi.encodeCall(stablecoin.removeMinter, (minter));
    }

    function _modifyAllowanceCalldata(address minter, int256 delta) internal view returns (bytes memory) {
        return abi.encodeCall(stablecoin.modifyMinterAllowance, (minter, delta));
    }

    function _upgradeCalldata(address newImpl, bytes memory data) internal pure returns (bytes memory) {
        return abi.encodeWithSignature("upgradeToAndCall(address,bytes)", newImpl, data);
    }

    // ============ scheduleGrantAdmin ============

    function test_GrantAdminCalldataMatchesManual() public {
        address newAdmin = address(0xAD1);
        bytes32 salt = bytes32(uint256(1));

        bytes memory expected = _adminCalldata(newAdmin);
        bytes32 manualId = timelock.hashOperation(address(stablecoin), 0, expected, bytes32(0), salt);

        vm.prank(PROPOSER);
        timelock.scheduleGrantAdmin(newAdmin, salt, DELAY);

        assertTrue(timelock.isOperation(manualId));
    }

    function test_E2E_GrantAdmin() public {
        bytes32 adminRole = stablecoin.ADMIN_ROLE();
        address newAdmin = address(0xAD1);
        bytes32 salt = bytes32(uint256(2));
        bytes memory data = _adminCalldata(newAdmin);

        vm.prank(PROPOSER);
        timelock.scheduleGrantAdmin(newAdmin, salt, DELAY);

        vm.expectRevert();
        timelock.execute(address(stablecoin), 0, data, bytes32(0), salt);

        vm.warp(block.timestamp + DELAY + 1);
        timelock.execute(address(stablecoin), 0, data, bytes32(0), salt);

        assertTrue(stablecoin.hasRole(adminRole, newAdmin));
        assertEq(stablecoin.getRoleMemberCount(adminRole), 2);
    }

    // ============ scheduleRevokeAdmin ============

    function test_RevokeAdminCalldataMatchesManual() public {
        // Grant a second admin first — scheduleRevokeAdmin now requires a positive role
        // check at schedule time, so the target must actually hold ADMIN_ROLE (see C1).
        address otherAdmin = address(0xAD1);
        bytes32 grantSalt = bytes32(uint256(100));
        bytes memory grantData = _adminCalldata(otherAdmin);
        vm.prank(PROPOSER);
        timelock.scheduleGrantAdmin(otherAdmin, grantSalt, DELAY);
        vm.warp(block.timestamp + DELAY + 1);
        timelock.execute(address(stablecoin), 0, grantData, bytes32(0), grantSalt);

        bytes32 salt = bytes32(uint256(3));
        bytes memory expected = _revokeAdminCalldata(otherAdmin);
        bytes32 manualId = timelock.hashOperation(address(stablecoin), 0, expected, bytes32(0), salt);

        vm.prank(PROPOSER);
        timelock.scheduleRevokeAdmin(otherAdmin, salt, DELAY);

        assertTrue(timelock.isOperation(manualId));
    }

    function test_E2E_RevokeAdmin() public {
        bytes32 adminRole = stablecoin.ADMIN_ROLE();
        address otherAdmin = address(0xAD1);

        // Grant first so there are two admins.
        bytes32 grantSalt = bytes32(uint256(4));
        bytes memory grantData = _adminCalldata(otherAdmin);
        vm.prank(PROPOSER);
        timelock.scheduleGrantAdmin(otherAdmin, grantSalt, DELAY);
        vm.warp(block.timestamp + DELAY + 1);
        timelock.execute(address(stablecoin), 0, grantData, bytes32(0), grantSalt);
        assertEq(stablecoin.getRoleMemberCount(adminRole), 2);

        // Now revoke the second admin via the helper.
        bytes32 revokeSalt = bytes32(uint256(5));
        bytes memory revokeData = _revokeAdminCalldata(otherAdmin);
        vm.prank(PROPOSER);
        timelock.scheduleRevokeAdmin(otherAdmin, revokeSalt, DELAY);
        vm.warp(block.timestamp + DELAY + 1);
        timelock.execute(address(stablecoin), 0, revokeData, bytes32(0), revokeSalt);

        assertFalse(stablecoin.hasRole(adminRole, otherAdmin));
        assertEq(stablecoin.getRoleMemberCount(adminRole), 1);
    }

    // ============ scheduleAddMinter ============

    function test_AddMinterCalldataMatchesManual() public {
        bytes32 salt = bytes32(uint256(6));
        bytes memory expected = _addMinterCalldata(address(0xBEEF), 1000);
        bytes32 manualId = timelock.hashOperation(address(stablecoin), 0, expected, bytes32(0), salt);

        vm.prank(PROPOSER);
        timelock.scheduleAddMinter(address(0xBEEF), 1000, salt, DELAY);

        assertTrue(timelock.isOperation(manualId));
    }

    function test_E2E_AddMinter() public {
        address minter = address(0xBEEF);
        uint256 cap = 1000;
        bytes32 salt = bytes32(uint256(7));
        bytes memory data = _addMinterCalldata(minter, cap);

        vm.prank(PROPOSER);
        timelock.scheduleAddMinter(minter, cap, salt, DELAY);

        vm.expectRevert();
        timelock.execute(address(stablecoin), 0, data, bytes32(0), salt);

        vm.warp(block.timestamp + DELAY + 1);
        timelock.execute(address(stablecoin), 0, data, bytes32(0), salt);

        assertTrue(stablecoin.hasRole(stablecoin.MINTER_ROLE(), minter));
        assertEq(stablecoin.minterAllowance(minter), cap);
    }

    // ============ scheduleRemoveMinter ============

    function test_RemoveMinterCalldataMatchesManual() public {
        bytes32 salt = bytes32(uint256(8));
        bytes memory expected = _removeMinterCalldata(address(0xBEEF));
        bytes32 manualId = timelock.hashOperation(address(stablecoin), 0, expected, bytes32(0), salt);

        vm.prank(PROPOSER);
        timelock.scheduleRemoveMinter(address(0xBEEF), salt, DELAY);

        assertTrue(timelock.isOperation(manualId));
    }

    function test_E2E_RemoveMinter() public {
        address minter = address(0xBEEF);

        // Add the minter first.
        bytes32 addSalt = bytes32(uint256(9));
        bytes memory addData = _addMinterCalldata(minter, 1000);
        vm.prank(PROPOSER);
        timelock.scheduleAddMinter(minter, 1000, addSalt, DELAY);
        vm.warp(block.timestamp + DELAY + 1);
        timelock.execute(address(stablecoin), 0, addData, bytes32(0), addSalt);

        // Now remove via the helper.
        bytes32 removeSalt = bytes32(uint256(10));
        bytes memory removeData = _removeMinterCalldata(minter);
        vm.prank(PROPOSER);
        timelock.scheduleRemoveMinter(minter, removeSalt, DELAY);
        vm.warp(block.timestamp + DELAY + 1);
        timelock.execute(address(stablecoin), 0, removeData, bytes32(0), removeSalt);

        assertFalse(stablecoin.hasRole(stablecoin.MINTER_ROLE(), minter));
        assertEq(stablecoin.minterAllowance(minter), 0);
    }

    // ============ scheduleModifyMinterAllowance ============

    function test_ModifyMinterAllowanceCalldataMatchesManual() public {
        bytes32 salt = bytes32(uint256(11));
        bytes memory expected = _modifyAllowanceCalldata(address(0xBEEF), 5000);
        bytes32 manualId = timelock.hashOperation(address(stablecoin), 0, expected, bytes32(0), salt);

        vm.prank(PROPOSER);
        timelock.scheduleModifyMinterAllowance(address(0xBEEF), 5000, salt, DELAY);

        assertTrue(timelock.isOperation(manualId));
    }

    function test_E2E_ModifyMinterAllowance() public {
        address minter = address(0xBEEF);

        bytes32 addSalt = bytes32(uint256(12));
        bytes memory addData = _addMinterCalldata(minter, 1000);
        vm.prank(PROPOSER);
        timelock.scheduleAddMinter(minter, 1000, addSalt, DELAY);
        vm.warp(block.timestamp + DELAY + 1);
        timelock.execute(address(stablecoin), 0, addData, bytes32(0), addSalt);

        // Signed delta API: starting allowance is 1000, +5000 delta -> 6000.
        bytes32 modifySalt = bytes32(uint256(13));
        bytes memory modifyData = _modifyAllowanceCalldata(minter, 5000);
        vm.prank(PROPOSER);
        timelock.scheduleModifyMinterAllowance(minter, 5000, modifySalt, DELAY);
        vm.warp(block.timestamp + DELAY + 1);
        timelock.execute(address(stablecoin), 0, modifyData, bytes32(0), modifySalt);

        assertEq(stablecoin.minterAllowance(minter), 6000);
    }

    // ============ scheduleUpgrade ============

    function test_UpgradeCalldataMatchesManual() public {
        // Use a real deployed contract — scheduleUpgrade rejects non-contracts at schedule time (see I1).
        address newImpl = address(new Stablecoin());
        bytes32 salt = bytes32(uint256(14));
        bytes memory expected = _upgradeCalldata(newImpl, "");
        bytes32 manualId = timelock.hashOperation(address(stablecoin), 0, expected, bytes32(0), salt);

        vm.prank(PROPOSER);
        timelock.scheduleUpgrade(newImpl, "", salt, DELAY);

        assertTrue(timelock.isOperation(manualId));
    }

    function test_E2E_Upgrade() public {
        Stablecoin newImpl = new Stablecoin();
        bytes32 salt = bytes32(uint256(15));
        bytes memory data = _upgradeCalldata(address(newImpl), "");

        vm.prank(PROPOSER);
        timelock.scheduleUpgrade(address(newImpl), "", salt, DELAY);

        vm.warp(block.timestamp + DELAY + 1);
        timelock.execute(address(stablecoin), 0, data, bytes32(0), salt);

        // ERC1967 implementation slot: bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1).
        // Mirrors the constant in OZ's ERC1967Utils.IMPLEMENTATION_SLOT (internal, so not directly importable).
        bytes32 implSlot = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
        address storedImpl = address(uint160(uint256(vm.load(address(stablecoin), implSlot))));
        assertEq(storedImpl, address(newImpl));
    }

    // ============ delay enforcement ============

    function test_HelperRevertsWhenDelayBelowMinDelay() public {
        bytes32 salt = bytes32(uint256(17));
        uint256 tooShort = DELAY - 1;

        vm.prank(PROPOSER);
        vm.expectRevert(abi.encodeWithSignature("TimelockInsufficientDelay(uint256,uint256)", tooShort, DELAY));
        timelock.scheduleGrantAdmin(address(0xAD1), salt, tooShort);
    }

    // ============ cancel ============

    function test_CancelScheduledOp() public {
        address newAdmin = address(0xAD1);
        bytes32 salt = bytes32(uint256(18));
        bytes memory data = _adminCalldata(newAdmin);
        bytes32 opId = timelock.hashOperation(address(stablecoin), 0, data, bytes32(0), salt);

        vm.prank(PROPOSER);
        timelock.scheduleGrantAdmin(newAdmin, salt, DELAY);
        assertTrue(timelock.isOperation(opId));

        // Proposers are granted CANCELLER_ROLE by the OZ constructor.
        vm.prank(PROPOSER);
        timelock.cancel(opId);
        assertFalse(timelock.isOperation(opId));
    }

    // ============ paused stablecoin behaviour ============

    function test_E2E_AddMinterRevertsWhenStablecoinPaused() public {
        address minter = address(0xBEEF);
        bytes32 salt = bytes32(uint256(19));
        bytes memory data = _addMinterCalldata(minter, 1000);

        // Pause the stablecoin (ADMIN retained PAUSER_ROLE through setUp).
        vm.prank(ADMIN);
        stablecoin.pause();

        // Scheduling still succeeds — the timelock only queues calldata.
        vm.prank(PROPOSER);
        timelock.scheduleAddMinter(minter, 1000, salt, DELAY);

        // Execution after the delay reverts because addMinter is whenNotPaused.
        vm.warp(block.timestamp + DELAY + 1);
        vm.expectRevert();
        timelock.execute(address(stablecoin), 0, data, bytes32(0), salt);
    }

    // ============ updateDelay floor ============

    function test_UpdateDelayCannotGoBelowDeployedFloor() public {
        // Schedule a self-call to updateDelay(0). Scheduling succeeds; the floor
        // is enforced at execute-time by our override.
        bytes memory data = abi.encodeCall(timelock.updateDelay, (uint256(0)));
        bytes32 salt = bytes32(uint256(20));

        vm.prank(PROPOSER);
        timelock.schedule(address(timelock), 0, data, bytes32(0), salt, DELAY);

        vm.warp(block.timestamp + DELAY + 1);
        vm.expectRevert();
        timelock.execute(address(timelock), 0, data, bytes32(0), salt);

        assertEq(timelock.getMinDelay(), DELAY);
        assertEq(timelock.deploymentMinDelay(), DELAY);
    }

    function test_UpdateDelayCanRaiseAboveDeployedFloor() public {
        uint256 raised = 7 days;
        bytes memory data = abi.encodeCall(timelock.updateDelay, (raised));
        bytes32 salt = bytes32(uint256(21));

        vm.prank(PROPOSER);
        timelock.schedule(address(timelock), 0, data, bytes32(0), salt, DELAY);

        vm.warp(block.timestamp + DELAY + 1);
        timelock.execute(address(timelock), 0, data, bytes32(0), salt);

        assertEq(timelock.getMinDelay(), raised);
        assertEq(timelock.deploymentMinDelay(), DELAY);
    }

    // ============ updateDelay self-call guard (boundary + direct call) ============

    function test_DirectUpdateDelayReverts() public {
        address caller = address(0xDEAD);
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSignature("TimelockUnauthorizedCaller(address)", caller));
        timelock.updateDelay(DELAY);
    }

    function test_UpdateDelayExactlyAtFloorSucceeds() public {
        // Raise the delay first so there is room to lower it back to the floor.
        uint256 raised = 7 days;
        bytes memory raiseData = abi.encodeCall(timelock.updateDelay, (raised));
        bytes32 raiseSalt = bytes32(uint256(22));
        vm.prank(PROPOSER);
        timelock.schedule(address(timelock), 0, raiseData, bytes32(0), raiseSalt, DELAY);
        vm.warp(block.timestamp + DELAY + 1);
        timelock.execute(address(timelock), 0, raiseData, bytes32(0), raiseSalt);
        assertEq(timelock.getMinDelay(), raised);

        // Lower to exactly the deployment floor — boundary case, override uses `<`.
        bytes memory lowerData = abi.encodeCall(timelock.updateDelay, (DELAY));
        bytes32 lowerSalt = bytes32(uint256(23));
        vm.prank(PROPOSER);
        timelock.schedule(address(timelock), 0, lowerData, bytes32(0), lowerSalt, raised);
        vm.warp(block.timestamp + raised + 1);
        timelock.execute(address(timelock), 0, lowerData, bytes32(0), lowerSalt);

        assertEq(timelock.getMinDelay(), DELAY);
        assertEq(timelock.deploymentMinDelay(), DELAY);
    }

    // ============ last-admin guard fires when reached through the timelock ============

    function test_E2E_RevokeLastAdminRevertsThroughTimelock() public {
        // Timelock is the only admin (per setUp). Scheduling revokeAdmin(timelock) is fine —
        // the timelock just queues calldata. Execution must revert with the stablecoin's
        // AdminRoleCannotBeEmpty guard. OZ's TimelockController bubbles the raw inner
        // revert via Address.verifyCallResult, so the selector match catches the
        // exact error path and would notice a regression that swapped the cause.
        bytes32 salt = bytes32(uint256(24));
        bytes memory data = _revokeAdminCalldata(address(timelock));

        vm.prank(PROPOSER);
        timelock.scheduleRevokeAdmin(address(timelock), salt, DELAY);

        vm.warp(block.timestamp + DELAY + 1);
        vm.expectRevert(Stablecoin.AdminRoleCannotBeEmpty.selector);
        timelock.execute(address(stablecoin), 0, data, bytes32(0), salt);

        assertTrue(stablecoin.hasRole(stablecoin.ADMIN_ROLE(), address(timelock)));
        assertEq(stablecoin.getRoleMemberCount(stablecoin.ADMIN_ROLE()), 1);
    }

    // ============ scheduleUpgrade forwards reinitializer data verbatim ============

    function test_ScheduleUpgradeWithReinitializerDataCalldataMatchesManual() public {
        // Use a real deployed contract — scheduleUpgrade rejects non-contracts at schedule time (see I1).
        address newImpl = address(new Stablecoin());
        bytes memory reinitCall = abi.encodeWithSignature("reinitialize(uint8)", uint8(2));
        bytes32 salt = bytes32(uint256(25));

        bytes memory expected = _upgradeCalldata(newImpl, reinitCall);
        bytes32 manualId = timelock.hashOperation(address(stablecoin), 0, expected, bytes32(0), salt);

        vm.prank(PROPOSER);
        timelock.scheduleUpgrade(newImpl, reinitCall, salt, DELAY);

        assertTrue(timelock.isOperation(manualId));
    }

    // ============ paused stablecoin: removeMinter path ============

    /// @dev PR #5 (pause-minter-mgmt-race) intentionally makes `removeMinter`
    /// callable while paused so a compromised minter can be revoked during an
    /// emergency pause. This test pins that behaviour through the timelock
    /// flow: scheduling+executing a remove during a pause must succeed.
    function test_E2E_RemoveMinterSucceedsWhenStablecoinPaused() public {
        address minter = address(0xBEEF);

        // Add the minter first while unpaused.
        bytes32 addSalt = bytes32(uint256(26));
        bytes memory addData = _addMinterCalldata(minter, 1000);
        vm.prank(PROPOSER);
        timelock.scheduleAddMinter(minter, 1000, addSalt, DELAY);
        vm.warp(block.timestamp + DELAY + 1);
        timelock.execute(address(stablecoin), 0, addData, bytes32(0), addSalt);
        assertTrue(stablecoin.hasRole(stablecoin.MINTER_ROLE(), minter));

        // Pause, schedule remove, then execute. Must succeed.
        vm.prank(ADMIN);
        stablecoin.pause();

        bytes32 removeSalt = bytes32(uint256(27));
        bytes memory removeData = _removeMinterCalldata(minter);
        vm.prank(PROPOSER);
        timelock.scheduleRemoveMinter(minter, removeSalt, DELAY);

        vm.warp(block.timestamp + DELAY + 1);
        timelock.execute(address(stablecoin), 0, removeData, bytes32(0), removeSalt);

        // Minter is gone — emergency revocation succeeded under pause.
        assertFalse(stablecoin.hasRole(stablecoin.MINTER_ROLE(), minter));
        assertEq(stablecoin.minterAllowance(minter), 0);
    }

    // ============ access control ============

    function test_NonProposerCannotCallHelpers() public {
        address nonProposer = address(0xDEAD);
        bytes32 salt = bytes32(uint256(16));

        bytes memory expectedError = abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)", nonProposer, timelock.PROPOSER_ROLE()
        );

        vm.prank(nonProposer);
        vm.expectRevert(expectedError);
        timelock.scheduleGrantAdmin(address(0xAD1), salt, DELAY);
    }

    // ============ scheduleUpgrade input validation (I1) ============

    /// @notice Scheduling an upgrade to an EOA / unallocated address must revert
    /// at schedule time so the proposer doesn't burn a full minDelay window
    /// before discovering the implementation has no code.
    function test_ScheduleUpgradeRevertsOnNonContractImplementation() public {
        address nonContract = address(0xCAFEBABE);
        assertEq(nonContract.code.length, 0, "precondition: address must have no code");
        bytes32 salt = bytes32(uint256(28));

        vm.prank(PROPOSER);
        vm.expectRevert(abi.encodeWithSelector(StablecoinTimelock.NotAContract.selector, nonContract));
        timelock.scheduleUpgrade(nonContract, "", salt, DELAY);
    }

    function test_ScheduleUpgradeRevertsOnZeroAddressImplementation() public {
        bytes32 salt = bytes32(uint256(29));

        vm.prank(PROPOSER);
        vm.expectRevert(abi.encodeWithSelector(StablecoinTimelock.NotAContract.selector, address(0)));
        timelock.scheduleUpgrade(address(0), "", salt, DELAY);
    }

    function test_ScheduleUpgradeAcceptsRealContract() public {
        Stablecoin newImpl = new Stablecoin();
        bytes32 salt = bytes32(uint256(30));

        vm.prank(PROPOSER);
        timelock.scheduleUpgrade(address(newImpl), "", salt, DELAY);

        bytes memory data = _upgradeCalldata(address(newImpl), "");
        bytes32 opId = timelock.hashOperation(address(stablecoin), 0, data, bytes32(0), salt);
        assertTrue(timelock.isOperation(opId));
    }

    // ============ scheduleRevokeAdmin input validation (C1) ============

    /// @notice Scheduling a revoke against an address that doesn't hold ADMIN_ROLE
    /// must revert at schedule time. Otherwise the operator burns a full minDelay
    /// window only to discover the revoke silently no-ops at execute time.
    function test_ScheduleRevokeAdminRevertsOnNonAdmin() public {
        address typo = address(0xBADBAD);
        assertFalse(stablecoin.hasRole(stablecoin.ADMIN_ROLE(), typo), "precondition: must not be admin");
        bytes32 salt = bytes32(uint256(31));

        vm.prank(PROPOSER);
        vm.expectRevert(abi.encodeWithSelector(StablecoinTimelock.NotAnAdmin.selector, typo));
        timelock.scheduleRevokeAdmin(typo, salt, DELAY);
    }

    function test_ScheduleRevokeAdminRevertsOnZeroAddress() public {
        bytes32 salt = bytes32(uint256(32));

        vm.prank(PROPOSER);
        vm.expectRevert(abi.encodeWithSelector(StablecoinTimelock.NotAnAdmin.selector, address(0)));
        timelock.scheduleRevokeAdmin(address(0), salt, DELAY);
    }

    function test_ScheduleRevokeAdminAcceptsExistingAdmin() public {
        // First grant a second admin so revoking is allowed by the last-admin guard.
        address otherAdmin = address(0xAD1);
        bytes32 grantSalt = bytes32(uint256(33));
        bytes memory grantData = _adminCalldata(otherAdmin);
        vm.prank(PROPOSER);
        timelock.scheduleGrantAdmin(otherAdmin, grantSalt, DELAY);
        vm.warp(block.timestamp + DELAY + 1);
        timelock.execute(address(stablecoin), 0, grantData, bytes32(0), grantSalt);
        assertTrue(stablecoin.hasRole(stablecoin.ADMIN_ROLE(), otherAdmin));

        // Now scheduling a revoke against the real admin must succeed at schedule time.
        bytes32 revokeSalt = bytes32(uint256(34));
        vm.prank(PROPOSER);
        timelock.scheduleRevokeAdmin(otherAdmin, revokeSalt, DELAY);

        bytes memory revokeData = _revokeAdminCalldata(otherAdmin);
        bytes32 opId = timelock.hashOperation(address(stablecoin), 0, revokeData, bytes32(0), revokeSalt);
        assertTrue(timelock.isOperation(opId));
    }

    // ============ raw schedule() bypass — defense in depth at the Stablecoin layer ============
    //
    // The typed helpers (scheduleRevokeAdmin / scheduleUpgrade) catch typos at schedule time.
    // A proposer can still bypass them by calling raw `timelock.schedule(target, value, data, ...)`
    // with the same calldata. The Stablecoin contract itself enforces the same invariants
    // at execute time, so the silent no-op stays closed even on the raw path.

    function test_RawScheduleRevokeAdminWithNonAdminRevertsAtExecuteTime() public {
        address typo = address(0xBADBAD);
        assertFalse(stablecoin.hasRole(stablecoin.ADMIN_ROLE(), typo), "precondition: must not be admin");

        bytes memory data = _revokeAdminCalldata(typo);
        bytes32 salt = bytes32(uint256(35));

        // Bypass the helper — go straight to the inherited schedule().
        vm.prank(PROPOSER);
        timelock.schedule(address(stablecoin), 0, data, bytes32(0), salt, DELAY);

        vm.warp(block.timestamp + DELAY + 1);
        vm.expectRevert(abi.encodeWithSelector(Stablecoin.NotAnAdmin.selector, typo));
        timelock.execute(address(stablecoin), 0, data, bytes32(0), salt);
    }

    function test_RawScheduleUpgradeWithNonContractRevertsAtExecuteTime() public {
        address nonContract = address(0xCAFEBABE);
        assertEq(nonContract.code.length, 0, "precondition: address must have no code");

        bytes memory data = _upgradeCalldata(nonContract, "");
        bytes32 salt = bytes32(uint256(36));

        // Bypass the helper — go straight to the inherited schedule().
        vm.prank(PROPOSER);
        timelock.schedule(address(stablecoin), 0, data, bytes32(0), salt, DELAY);

        vm.warp(block.timestamp + DELAY + 1);
        vm.expectRevert(abi.encodeWithSelector(Stablecoin.NotAContract.selector, nonContract));
        timelock.execute(address(stablecoin), 0, data, bytes32(0), salt);
    }
}
