// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.30;

import {Test} from "forge-std/Test.sol";
import {Upgrades, Options} from "@openzeppelin-foundry-upgrades/Upgrades.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Stablecoin} from "../src/Stablecoin.sol";
import {StablecoinV2} from "../src/upgrades/StablecoinV2.sol";

contract UpgradeStablecoinTest is Test {
    struct StateSnapshot {
        string name;
        string symbol;
        uint8 decimals;
        uint256 totalSupply;
        uint256 user1Balance;
        uint256 user2Balance;
        bool paused;
        bool user2Frozen;
        bool adminHasRole;
        bool minterHasRole;
        bool burnerHasRole;
        bool pauserHasRole;
        bool freezerHasRole;
        uint256 minterAllowance;
        uint256 minter2Allowance;
        uint256 minterCount;
    }

    Stablecoin public stablecoin;
    address public proxy;

    // Same test addresses as Stablecoin.t.sol
    address public constant ADMIN = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
    address public constant MINTER = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    address public constant BURNER = 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC;
    address public constant PAUSER = 0x90F79bf6EB2c4f870365E785982E1f101E93b906;
    address public constant FREEZER = 0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65;

    address public constant MINTER2 = address(0xAA);
    address public constant USER1 = address(0xBB);
    address public constant USER2 = address(0xCC);

    uint256 public constant MAX_SUPPLY = 1_000_000e6;

    function setUp() public {
        bytes memory initData =
            abi.encodeCall(Stablecoin.initialize, ("Stablecoin", "STBL", 6, ADMIN, BURNER, PAUSER, FREEZER));

        proxy = Upgrades.deployUUPSProxy("Stablecoin.sol", initData);
        stablecoin = Stablecoin(proxy);

        // Set up some initial state for testing preservation
        vm.startPrank(ADMIN);
        stablecoin.addMinter(MINTER, 10_000e6);
        stablecoin.addMinter(MINTER2, 5_000e6);
        vm.stopPrank();

        // Mint some tokens
        vm.prank(MINTER);
        stablecoin.mint(USER1, 1_000e6);

        vm.prank(MINTER);
        stablecoin.mint(USER2, 500e6);

        // Freeze an account
        vm.prank(FREEZER);
        stablecoin.freeze(USER2);
    }

    // ─── Helpers ───────────────────────────────────────────────────

    function _upgradeToV2() internal {
        bytes memory reinitData = abi.encodeCall(StablecoinV2.initializeV2, (MAX_SUPPLY));
        Options memory opts;
        opts.referenceContract = "Stablecoin.sol";
        Upgrades.upgradeProxy(proxy, "StablecoinV2.sol", reinitData, opts, ADMIN);
    }

    /// @dev Mimics the two-script flow: DeployNewImplementation + SwitchImplementation
    function _upgradeToV2TwoStep() internal returns (address newImpl) {
        bytes memory reinitData = abi.encodeCall(StablecoinV2.initializeV2, (MAX_SUPPLY));

        // Step 1: Deploy implementation (DeployNewImplementation.s.sol)
        Options memory opts;
        opts.referenceContract = "Stablecoin.sol";
        Upgrades.validateUpgrade("StablecoinV2.sol", opts);
        newImpl = Upgrades.prepareUpgrade("StablecoinV2.sol", opts);

        // Step 2: Switch proxy to new implementation (SwitchImplementation.s.sol)
        vm.prank(ADMIN);
        UUPSUpgradeable(proxy).upgradeToAndCall(newImpl, reinitData);
    }

    // ─── Tests ────────────────────────────────────────────────────

    function _snapshot() internal view returns (StateSnapshot memory s) {
        s.name = stablecoin.name();
        s.symbol = stablecoin.symbol();
        s.decimals = stablecoin.decimals();
        s.totalSupply = stablecoin.totalSupply();
        s.user1Balance = stablecoin.balanceOf(USER1);
        s.user2Balance = stablecoin.balanceOf(USER2);
        s.paused = stablecoin.paused();
        s.user2Frozen = stablecoin.frozen(USER2);
        s.adminHasRole = stablecoin.hasRole(stablecoin.ADMIN_ROLE(), ADMIN);
        s.minterHasRole = stablecoin.hasRole(stablecoin.MINTER_ROLE(), MINTER);
        s.burnerHasRole = stablecoin.hasRole(stablecoin.BURNER_ROLE(), BURNER);
        s.pauserHasRole = stablecoin.hasRole(stablecoin.PAUSER_ROLE(), PAUSER);
        s.freezerHasRole = stablecoin.hasRole(stablecoin.FREEZER_ROLE(), FREEZER);
        s.minterAllowance = stablecoin.minterAllowance(MINTER);
        s.minter2Allowance = stablecoin.minterAllowance(MINTER2);
        s.minterCount = stablecoin.getMinterCount();
    }

    function _assertStateEqual(StateSnapshot memory before, StateSnapshot memory after_) internal pure {
        assertEq(after_.name, before.name);
        assertEq(after_.symbol, before.symbol);
        assertEq(after_.decimals, before.decimals);
        assertEq(after_.totalSupply, before.totalSupply);
        assertEq(after_.user1Balance, before.user1Balance);
        assertEq(after_.user2Balance, before.user2Balance);
        assertEq(after_.paused, before.paused);
        assertEq(after_.user2Frozen, before.user2Frozen);
        assertEq(after_.adminHasRole, before.adminHasRole);
        assertEq(after_.minterHasRole, before.minterHasRole);
        assertEq(after_.burnerHasRole, before.burnerHasRole);
        assertEq(after_.pauserHasRole, before.pauserHasRole);
        assertEq(after_.freezerHasRole, before.freezerHasRole);
        assertEq(after_.minterAllowance, before.minterAllowance);
        assertEq(after_.minter2Allowance, before.minter2Allowance);
        assertEq(after_.minterCount, before.minterCount);
    }

    function test_UpgradeToV2_PreservesAllState() public {
        StateSnapshot memory before = _snapshot();

        _upgradeToV2();

        StateSnapshot memory after_ = _snapshot();
        _assertStateEqual(before, after_);
    }

    function test_UpgradeToV2_NewFunctionalityWorks() public {
        _upgradeToV2();

        StablecoinV2 v2 = StablecoinV2(proxy);

        // version() returns "2.0.0"
        assertEq(v2.version(), "2.0.0");

        // maxSupply set by reinitializer
        assertEq(v2.maxSupply(), MAX_SUPPLY);

        // Admin can update maxSupply
        vm.prank(ADMIN);
        v2.setMaxSupply(2_000_000e6);
        assertEq(v2.maxSupply(), 2_000_000e6);
    }

    function test_UpgradeToV2_NonAdminCannotUpgrade() public {
        address nonAdmin = address(0xDEAD);

        // Deploy a V2 implementation directly
        StablecoinV2 newImpl = new StablecoinV2();

        bytes memory reinitData = abi.encodeCall(StablecoinV2.initializeV2, (MAX_SUPPLY));

        bytes memory expectedError = abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)", nonAdmin, stablecoin.ADMIN_ROLE()
        );
        vm.prank(nonAdmin);
        vm.expectRevert(expectedError);
        stablecoin.upgradeToAndCall(address(newImpl), reinitData);
    }

    function test_UpgradeToV2_CannotReinitializeTwice() public {
        _upgradeToV2();

        StablecoinV2 v2 = StablecoinV2(proxy);

        vm.expectRevert(abi.encodeWithSignature("InvalidInitialization()"));
        v2.initializeV2(999);
    }

    function test_UpgradeToV2_CannotReinitializeV1() public {
        _upgradeToV2();

        vm.expectRevert(abi.encodeWithSignature("InvalidInitialization()"));
        stablecoin.initialize("Hack", "HACK", 18, address(0xDEAD), address(0), address(0), address(0));
    }

    function test_UpgradeToV2_FrozenAccountsStillFrozen() public {
        // USER2 was frozen in setUp
        assertTrue(stablecoin.frozen(USER2));

        _upgradeToV2();

        // Still frozen after upgrade
        assertTrue(stablecoin.frozen(USER2));

        // Transfer TO frozen account still reverts
        vm.prank(USER1);
        vm.expectPartialRevert(Stablecoin.AccountIsFrozen.selector);
        bool success = stablecoin.transfer(USER2, 100e6);
        assertFalse(success);

        // Transfer FROM frozen account still reverts
        vm.prank(USER2);
        vm.expectPartialRevert(Stablecoin.AccountIsFrozen.selector);
        success = stablecoin.transfer(USER1, 100e6);
        assertFalse(success);
    }

    function test_UpgradeToV2_PausedStatePreserved() public {
        // Pause before upgrade
        vm.prank(PAUSER);
        stablecoin.pause();
        assertTrue(stablecoin.paused());

        // Upgrade succeeds even when paused (UUPS auth is not gated by whenNotPaused)
        _upgradeToV2();

        // Contract still paused after upgrade
        assertTrue(stablecoin.paused());

        // Minting reverts while paused
        vm.prank(MINTER);
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        stablecoin.mint(USER1, 100e6);

        // Unpause works
        vm.prank(PAUSER);
        stablecoin.unpause();
        assertFalse(stablecoin.paused());
    }

    function test_UpgradeToV2_MinterAllowancesPreserved() public {
        // MINTER started with 10_000e6, spent 1_500e6 (minted 1000 to USER1 + 500 to USER2)
        uint256 expectedMinterAllowance = 10_000e6 - 1_500e6;
        uint256 expectedMinter2Allowance = 5_000e6; // untouched

        assertEq(stablecoin.minterAllowance(MINTER), expectedMinterAllowance);
        assertEq(stablecoin.minterAllowance(MINTER2), expectedMinter2Allowance);
        assertEq(stablecoin.getMinterCount(), 2);

        _upgradeToV2();

        // Deep check: allowances preserved
        assertEq(stablecoin.minterAllowance(MINTER), expectedMinterAllowance);
        assertEq(stablecoin.minterAllowance(MINTER2), expectedMinter2Allowance);
        assertEq(stablecoin.getMinterCount(), 2);

        // getAllMinters returns correct data
        Stablecoin.MinterInfo[] memory minters = stablecoin.getAllMinters();
        assertEq(minters.length, 2);

        // Minting still works within allowances
        vm.prank(MINTER2);
        stablecoin.mint(USER1, 1_000e6);
        assertEq(stablecoin.minterAllowance(MINTER2), expectedMinter2Allowance - 1_000e6);
    }

    function test_UpgradeToV2_ImplementationAddressChanges() public {
        address implBefore = Upgrades.getImplementationAddress(proxy);
        assertTrue(implBefore != address(0));

        _upgradeToV2();

        address implAfter = Upgrades.getImplementationAddress(proxy);
        assertTrue(implAfter != address(0));
        assertTrue(implAfter != implBefore);
    }

    function test_ValidateUpgrade_AcceptsGoodV2() public {
        Options memory opts;
        opts.referenceContract = "Stablecoin.sol";

        // Should not revert
        Upgrades.validateUpgrade("StablecoinV2.sol", opts);
    }

    function test_ValidateUpgrade_RejectsBadV2() public {
        Options memory opts;
        opts.referenceContract = "Stablecoin.sol";

        // validateUpgrade uses FFI, so vm.expectRevert() doesn't work at the right depth.
        // Use try/catch via an external call instead.
        try this._callValidateUpgrade("StablecoinV2Bad.sol", opts) {
            fail("Expected validateUpgrade to revert for bad V2");
        } catch {
            // Expected: storage clash detected
        }
    }

    // External wrapper so try/catch can intercept the revert
    function _callValidateUpgrade(string memory contractName, Options memory opts) external {
        Upgrades.validateUpgrade(contractName, opts);
    }

    function test_UpgradeToV2_V1OperationsStillWork() public {
        _upgradeToV2();

        // Mint
        vm.prank(MINTER);
        stablecoin.mint(USER1, 100e6);
        assertEq(stablecoin.balanceOf(USER1), 1_100e6);

        // Transfer (USER2 is frozen, use USER1)
        vm.prank(USER1);
        assertTrue(stablecoin.transfer(BURNER, 50e6));
        assertEq(stablecoin.balanceOf(BURNER), 50e6);

        // Burn
        vm.prank(BURNER);
        stablecoin.burn(50e6);
        assertEq(stablecoin.balanceOf(BURNER), 0);

        // Unfreeze USER2, then freeze again
        vm.prank(FREEZER);
        stablecoin.unfreeze(USER2);
        assertFalse(stablecoin.frozen(USER2));

        vm.prank(FREEZER);
        stablecoin.freeze(USER2);
        assertTrue(stablecoin.frozen(USER2));

        // Pause / unpause
        vm.prank(PAUSER);
        stablecoin.pause();
        assertTrue(stablecoin.paused());

        vm.prank(PAUSER);
        stablecoin.unpause();
        assertFalse(stablecoin.paused());

        // Add / remove minter
        address newMinter = address(0xDD);
        vm.startPrank(ADMIN);
        stablecoin.addMinter(newMinter, 1_000e6);
        assertEq(stablecoin.getMinterCount(), 3);

        stablecoin.removeMinter(newMinter);
        assertEq(stablecoin.getMinterCount(), 2);
        vm.stopPrank();
    }

    // ─── Two-step upgrade flow tests ────────────────────────────

    function test_TwoStepUpgrade_PreservesAllState() public {
        StateSnapshot memory before = _snapshot();

        _upgradeToV2TwoStep();

        StateSnapshot memory after_ = _snapshot();
        _assertStateEqual(before, after_);
    }

    function test_TwoStepUpgrade_NewFunctionalityWorks() public {
        _upgradeToV2TwoStep();

        StablecoinV2 v2 = StablecoinV2(proxy);
        assertEq(v2.version(), "2.0.0");
        assertEq(v2.maxSupply(), MAX_SUPPLY);

        vm.prank(ADMIN);
        v2.setMaxSupply(2_000_000e6);
        assertEq(v2.maxSupply(), 2_000_000e6);
    }

    function test_TwoStepUpgrade_ImplementationMatchesDeployed() public {
        address newImpl = _upgradeToV2TwoStep();

        address implAfter = Upgrades.getImplementationAddress(proxy);
        assertEq(implAfter, newImpl);
    }

    function test_TwoStepUpgrade_NonAdminCannotSwitch() public {
        StablecoinV2 newImpl = new StablecoinV2();
        bytes memory reinitData = abi.encodeCall(StablecoinV2.initializeV2, (MAX_SUPPLY));
        address nonAdmin = address(0xDEAD);

        // Cache role hash before prank — stablecoin.ADMIN_ROLE() is an external call that would consume it
        bytes32 adminRole = stablecoin.ADMIN_ROLE();

        vm.prank(nonAdmin);
        vm.expectRevert(
            abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", nonAdmin, adminRole)
        );
        UUPSUpgradeable(proxy).upgradeToAndCall(address(newImpl), reinitData);
    }

    function test_TwoStepUpgrade_RejectsEOAAsImplementation() public {
        bytes memory reinitData = abi.encodeCall(StablecoinV2.initializeV2, (MAX_SUPPLY));
        address eoa = address(0xDEAD);

        // Stablecoin._authorizeUpgrade rejects non-contract implementations with
        // NotAContract before reaching UUPSUpgradeable's proxiableUUID staticcall.
        vm.prank(ADMIN);
        vm.expectRevert(abi.encodeWithSelector(Stablecoin.NotAContract.selector, eoa));
        UUPSUpgradeable(proxy).upgradeToAndCall(eoa, reinitData);
    }

    function test_TwoStepUpgrade_EmptyReinitData() public {
        Options memory opts;
        opts.referenceContract = "Stablecoin.sol";
        address newImpl = Upgrades.prepareUpgrade("StablecoinV2.sol", opts);

        // Switch with empty reinit data — upgrade succeeds but initializeV2 is not called
        vm.prank(ADMIN);
        UUPSUpgradeable(proxy).upgradeToAndCall(newImpl, "");

        StablecoinV2 v2 = StablecoinV2(proxy);
        assertEq(v2.version(), "2.0.0");
        // maxSupply was never initialized, so it should be 0
        assertEq(v2.maxSupply(), 0);
    }
}
