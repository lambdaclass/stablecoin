// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.30;

import {
    ERC20BurnableUpgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20BurnableUpgradeable.sol";
import {
    ERC20PausableUpgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PausableUpgradeable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {EnumerableMap} from "@openzeppelin/contracts/utils/structs/EnumerableMap.sol";

/// @dev Deliberately broken V2 that introduces a storage clash by inserting
/// a new variable BEFORE existing storage variables. Used only for testing
/// that Upgrades.validateUpgrade() correctly rejects incompatible layouts.
/// @custom:oz-upgrades-from Stablecoin
contract StablecoinV2Bad is
    Initializable,
    ERC20Upgradeable,
    ERC20BurnableUpgradeable,
    ERC20PausableUpgradeable,
    AccessControlUpgradeable,
    UUPSUpgradeable
{
    using EnumerableMap for EnumerableMap.AddressToUintMap;

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");
    bytes32 public constant FREEZER_ROLE = keccak256("FREEZER_ROLE");
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    // === STORAGE CLASH: new variable inserted BEFORE existing ones ===
    uint256 private _badNewVariable;

    // Original variables (now shifted by one slot)
    EnumerableMap.AddressToUintMap private _minterAllowances;
    mapping(address => bool) public frozen;
    uint8 private _decimals;

    struct MinterInfo {
        address minter;
        uint256 allowance;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        string memory name,
        string memory symbol,
        uint8 decimals_,
        address admin,
        address burner,
        address pauser,
        address freezer
    ) public initializer {
        __ERC20_init(name, symbol);
        __ERC20Burnable_init();
        __ERC20Pausable_init();
        __AccessControl_init();
        _decimals = decimals_;
        _grantRole(ADMIN_ROLE, admin);
        _grantRole(BURNER_ROLE, burner);
        _grantRole(PAUSER_ROLE, pauser);
        _grantRole(FREEZER_ROLE, freezer);
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 value) public onlyRole(MINTER_ROLE) whenNotPaused {
        uint256 allowance = _minterAllowances.get(msg.sender);
        require(allowance >= value, "Value exceeds allowance");
        _minterAllowances.set(msg.sender, allowance - value);
        _mint(to, value);
    }

    function minterAllowance(address minter) public view returns (uint256) {
        (bool exists, uint256 allowance) = _minterAllowances.tryGet(minter);
        return exists ? allowance : 0;
    }

    function burn(uint256 value) public override onlyRole(BURNER_ROLE) whenNotPaused {
        _burn(_msgSender(), value);
    }

    function burnFrom(address account, uint256 value) public override onlyRole(BURNER_ROLE) whenNotPaused {
        _spendAllowance(account, _msgSender(), value);
        _burn(account, value);
    }

    function addMinter(address newMinter, uint256 allowance) public onlyRole(ADMIN_ROLE) whenNotPaused {
        (bool exists,) = _minterAllowances.tryGet(newMinter);
        require(!exists, "Minter already exists");
        _minterAllowances.set(newMinter, allowance);
        _grantRole(MINTER_ROLE, newMinter);
    }

    function removeMinter(address minter) public onlyRole(ADMIN_ROLE) whenNotPaused {
        (bool exists,) = _minterAllowances.tryGet(minter);
        require(exists, "Minter does not exist");
        _minterAllowances.remove(minter);
        _revokeRole(MINTER_ROLE, minter);
    }

    function modifyMinterAllowance(address minter, uint256 allowance) public onlyRole(ADMIN_ROLE) whenNotPaused {
        (bool exists,) = _minterAllowances.tryGet(minter);
        require(exists, "Minter does not exist");
        _minterAllowances.set(minter, allowance);
    }

    function getAllMinters() public view returns (MinterInfo[] memory) {
        uint256 length = _minterAllowances.length();
        MinterInfo[] memory result = new MinterInfo[](length);
        for (uint256 i = 0; i < length; i++) {
            (address minter, uint256 allowance) = _minterAllowances.at(i);
            result[i] = MinterInfo({minter: minter, allowance: allowance});
        }
        return result;
    }

    function getMinterCount() public view returns (uint256) {
        return _minterAllowances.length();
    }

    function freeze(address account) public onlyRole(FREEZER_ROLE) whenNotPaused {
        frozen[account] = true;
    }

    function unfreeze(address account) public onlyRole(FREEZER_ROLE) whenNotPaused {
        frozen[account] = false;
    }

    function pause() public onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() public onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    function _update(address from, address to, uint256 value)
        internal
        override(ERC20Upgradeable, ERC20PausableUpgradeable)
    {
        super._update(from, to, value);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(ADMIN_ROLE) {}
}
