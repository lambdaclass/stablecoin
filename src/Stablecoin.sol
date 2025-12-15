// SPDX-License-Identifier: UNLICENSED
// TODO: add the right license
pragma solidity ^0.8.13;

import {ERC20BurnableUpgradeable} from
    "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20BurnableUpgradeable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

contract Stablecoin is
    Initializable,
    ERC20Upgradeable,
    ERC20BurnableUpgradeable,
    AccessControlUpgradeable,
    UUPSUpgradeable
{
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    mapping(address => uint256) public minterAllowance;

    constructor() {
        _disableInitializers();
    }

    function initialize(string memory name, string memory symbol, address admin, address burner) public initializer {
        __ERC20_init(name, symbol);
        __ERC20Burnable_init();
        __AccessControl_init();

        _setRoleAdmin(MINTER_ROLE, ADMIN_ROLE);
        _setRoleAdmin(BURNER_ROLE, ADMIN_ROLE);
        _grantRole(ADMIN_ROLE, admin);
        _grantRole(BURNER_ROLE, burner);
    }

    function addMinter(address newMinter, uint256 amount) public onlyRole(ADMIN_ROLE) {
        minterAllowance[newMinter] = amount;
        grantRole(MINTER_ROLE, newMinter);
    }

    function addBurner(address newBurner) public onlyRole(ADMIN_ROLE) {
        grantRole(BURNER_ROLE, newBurner);
    }

    function mint(address to, uint256 value) public onlyRole(MINTER_ROLE) {
        require(minterAllowance[msg.sender] >= value, "Value exceeds allowance");
        minterAllowance[msg.sender] -= value;
        _mint(to, value);
    }

    function burn(uint256 value) public override onlyRole(BURNER_ROLE) {
        _burn(_msgSender(), value);
    }

    function burnFrom(address account, uint256 value) public override onlyRole(BURNER_ROLE) {
        _spendAllowance(account, _msgSender(), value);
        _burn(account, value);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(ADMIN_ROLE) {}
}
