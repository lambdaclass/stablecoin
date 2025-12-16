// SPDX-License-Identifier: UNLICENSED
// TODO: add the right license
pragma solidity ^0.8.13;

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

contract Stablecoin is
    Initializable,
    ERC20Upgradeable,
    ERC20BurnableUpgradeable,
    ERC20PausableUpgradeable,
    AccessControlUpgradeable,
    UUPSUpgradeable
{
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");
    bytes32 public constant FREEZER_ROLE = keccak256("FREEZER_ROLE");
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    mapping(address => uint256) public minterAllowance;
    // Freezed accounts
    mapping(address => bool) public freezed;

    modifier whenNotFreezed(address account) {
        _whenNotFreezed(account);
        _;
    }

    function initialize(
        string memory name,
        string memory symbol,
        address admin,
        address burner,
        address pauser,
        address freezer
    ) public initializer {
        __ERC20_init(name, symbol);
        __ERC20Burnable_init();
        __AccessControl_init();

        _setRoleAdmin(MINTER_ROLE, ADMIN_ROLE);
        _setRoleAdmin(BURNER_ROLE, ADMIN_ROLE);
        _setRoleAdmin(PAUSER_ROLE, ADMIN_ROLE);
        _setRoleAdmin(FREEZER_ROLE, ADMIN_ROLE);
        _grantRole(ADMIN_ROLE, admin);
        _grantRole(BURNER_ROLE, burner);
        _grantRole(PAUSER_ROLE, pauser);
        _grantRole(FREEZER_ROLE, freezer);
    }

    // TODO: define the number of decimals
    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 value) public onlyRole(MINTER_ROLE) whenNotPaused {
        require(minterAllowance[msg.sender] >= value, "Value exceeds allowance");
        minterAllowance[msg.sender] -= value;
        _mint(to, value);
    }

    function burn(uint256 value) public override onlyRole(BURNER_ROLE) whenNotPaused {
        _burn(_msgSender(), value);
    }

    function burnFrom(address account, uint256 value) public override onlyRole(BURNER_ROLE) whenNotPaused {
        _spendAllowance(account, _msgSender(), value);
        _burn(account, value);
    }

    function addMinter(address newMinter, uint256 amount) public onlyRole(ADMIN_ROLE) whenNotPaused {
        minterAllowance[newMinter] = amount;
        grantRole(MINTER_ROLE, newMinter);
    }

    function freeze(address account) public onlyRole(FREEZER_ROLE) whenNotPaused {
        freezed[account] = true;
    }

    function unfreeze(address account) public onlyRole(FREEZER_ROLE) whenNotPaused {
        freezed[account] = false;
    }

    function pause() public onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() public onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    /**
     * @dev Updates the balances of `from` and `to` by `value`.
     *
     * This internal function is used by `transfer`, `transferFrom`, `mint`,
     * `burn`, and `burnFrom`. As a result, any constraints enforced here
     * (whenNotPaused, whenNotFreezed) also apply to all of those operations.
     */
    function _update(address from, address to, uint256 value)
        internal
        override(ERC20Upgradeable, ERC20PausableUpgradeable)
        whenNotPaused
        whenNotFreezed(msg.sender)
        whenNotFreezed(from)
        whenNotFreezed(to)
    {
        super._update(from, to, value);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(ADMIN_ROLE) {}

    function _whenNotFreezed(address account) internal view {
        require(!freezed[account], "Freezed account");
    }
}
