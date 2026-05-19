// SPDX-License-Identifier: UNLICENSED
// TODO: add the right license
pragma solidity =0.8.30;

import {
    ERC20BurnableUpgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20BurnableUpgradeable.sol";
import {
    ERC20PausableUpgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PausableUpgradeable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {
    AccessControlEnumerableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/**
 * @title Stablecoin
 * @dev Upgradeable ERC20 stablecoin with role-based access control.
 *
 * Roles:
 *  - ADMIN_ROLE: Manages minters and their allowances, authorizes upgrades, and
 *    administers itself (can grant or revoke ADMIN_ROLE on other accounts).
 *    For production deployments, the holder of ADMIN_ROLE MUST be an OpenZeppelin
 *    `TimelockController` (or equivalent delayed-execution governance contract);
 *    direct EOAs or unsynchronized multisigs SHOULD NOT hold ADMIN_ROLE because the
 *    role is self-administering and any rotation, grant, or revocation runs
 *    immediately.
 *  - MINTER_ROLE: Can mint tokens up to an individual allowance. Managed exclusively
 *    through addMinter/removeMinter to keep role and allowance state in sync.
 *  - BURNER_ROLE: Can burn tokens from own balance or via allowance (burnFrom).
 *  - PAUSER_ROLE: Can pause/unpause all token operations.
 *  - FREEZER_ROLE: Can freeze/unfreeze individual accounts.
 */
contract Stablecoin is
    Initializable,
    ERC20Upgradeable,
    ERC20BurnableUpgradeable,
    ERC20PausableUpgradeable,
    AccessControlEnumerableUpgradeable,
    UUPSUpgradeable
{
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");
    bytes32 public constant FREEZER_ROLE = keccak256("FREEZER_ROLE");
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    mapping(address => uint256) private _minterAllowances;
    // Frozen accounts
    mapping(address => bool) public frozen;
    // Token decimals
    uint8 private _decimals;

    // Struct for returning minter information
    struct MinterInfo {
        address minter;
        uint256 allowance;
    }

    event MinterAdded(address indexed minter, uint256 allowance);
    event MinterRemoved(address indexed minter);
    event MinterAllowanceChanged(address indexed minter, uint256 oldAllowance, uint256 newAllowance);
    event AccountFrozen(address indexed account);
    event AccountUnfrozen(address indexed account);

    /// @dev Reverts when a revoke or renounce of ADMIN_ROLE would empty the
    /// admin set. ADMIN_ROLE is self-administering, so a zero-member admin set
    /// is unrecoverable on-chain: minter management, role rotation, and UUPS
    /// upgrade authorization all become permanently unreachable.
    error AdminRoleCannotBeEmpty();

    /// @dev Reverts when a revoke or renounce of ADMIN_ROLE targets an address
    /// that does not currently hold the role. Without this guard, OZ's
    /// `_revokeRole` returns `false` silently with no event — indistinguishable
    /// from success at the caller. Critical for timelock-gated revocations
    /// where the operator would otherwise burn the `minDelay` window only to
    /// discover the revoke was a no-op on a typo'd address.
    error NotAnAdmin(address account);

    /// @dev Reverts when `_authorizeUpgrade` is reached with an implementation
    /// address that has no bytecode. UUPSUpgradeable's `proxiableUUID` staticcall
    /// would also fail downstream, but this earlier check produces a typed
    /// revert and closes the path where a raw timelock `schedule(...)` call
    /// bypasses the timelock helper's input validation.
    error NotAContract(address impl);

    modifier whenNotFrozen(address account) {
        _whenNotFrozen(account);
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @param name Token name.
     * @param symbol Token symbol.
     * @param decimals_ Token decimals.
     * @param admin Address granted ADMIN_ROLE.
     * @param burner Address granted BURNER_ROLE.
     * @param pauser Address granted PAUSER_ROLE.
     * @param freezer Address granted FREEZER_ROLE.
     *
     * @dev MINTER_ROLE is deliberately omitted from _setRoleAdmin calls.
     * This leaves its role admin as DEFAULT_ADMIN_ROLE (0x00), which no one holds,
     * making grantRole/revokeRole for MINTER_ROLE always revert. The only way to
     * manage minters is through addMinter/removeMinter, which atomically update both
     * the role and the allowance, preventing state divergence between the two.
     *
     * @dev ADMIN_ROLE is configured as its own admin so that an existing admin can
     * rotate the role on-chain (grant ADMIN_ROLE to a new account, revoke it from
     * an old one). Because the role is self-administering and grants/revocations
     * are immediate, the recommended `admin` value at initialize-time is an
     * OpenZeppelin `TimelockController` deployed via `script/DeployTimelock.s.sol`.
     * Routing rotations through a timelock gives the team a delay window to detect
     * and cancel a hostile rotation before it executes. Revoking or renouncing the
     * last remaining admin reverts (see `_revokeRole`).
     */
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
        __AccessControlEnumerable_init();

        _decimals = decimals_;

        // MINTER_ROLE intentionally not listed here — see @dev note above.
        _setRoleAdmin(ADMIN_ROLE, ADMIN_ROLE);
        _setRoleAdmin(BURNER_ROLE, ADMIN_ROLE);
        _setRoleAdmin(PAUSER_ROLE, ADMIN_ROLE);
        _setRoleAdmin(FREEZER_ROLE, ADMIN_ROLE);
        _grantRole(ADMIN_ROLE, admin);
        _grantRole(BURNER_ROLE, burner);
        _grantRole(PAUSER_ROLE, pauser);
        _grantRole(FREEZER_ROLE, freezer);
    }

    /// @notice One-time storage-slot repair for proxies that were initialized
    /// under a prior implementation where `_setRoleAdmin(ADMIN_ROLE, ADMIN_ROLE)`
    /// was never called. Sets `ADMIN_ROLE` as its own admin so the current
    /// admin can rotate the role (M-01).
    ///
    /// @dev Gated by `reinitializer(2)` so it can run at most once per proxy,
    /// and by `onlyRole(ADMIN_ROLE)` so only the legitimate admin can trigger
    /// the repair. On a freshly-deployed proxy the call is a no-op (the new
    /// `initialize` already sets the same value); on an upgraded proxy it
    /// repairs the previously-unset slot. Intended call sites:
    ///   proxy.upgradeToAndCall(newImpl, abi.encodeCall(this.reinitializeAdminRole, ()))
    /// so the upgrade and the storage repair happen atomically.
    function reinitializeAdminRole() public reinitializer(2) onlyRole(ADMIN_ROLE) {
        _setRoleAdmin(ADMIN_ROLE, ADMIN_ROLE);
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    /// @dev Mints `value` tokens to `to`, deducting from the caller's minter allowance.
    function mint(address to, uint256 value) public onlyRole(MINTER_ROLE) whenNotPaused {
        uint256 allowance = _minterAllowances[msg.sender];
        require(allowance >= value, "Value exceeds allowance");
        _minterAllowances[msg.sender] = allowance - value;
        _mint(to, value);
    }

    /**
     * @dev Returns the minting allowance for a minter.
     */
    function minterAllowance(address minter) public view returns (uint256) {
        return _minterAllowances[minter];
    }

    /// @dev Burns `value` tokens from the caller's balance. Restricted to BURNER_ROLE.
    function burn(uint256 value) public override onlyRole(BURNER_ROLE) whenNotPaused {
        _burn(_msgSender(), value);
    }

    /// @dev Burns `value` tokens from `account` using the caller's ERC20 allowance. Restricted to BURNER_ROLE.
    function burnFrom(address account, uint256 value) public override onlyRole(BURNER_ROLE) whenNotPaused {
        _spendAllowance(account, _msgSender(), value);
        _burn(account, value);
    }

    /// @dev Grants MINTER_ROLE and sets the minting allowance atomically.
    /// Uses _grantRole to bypass the external grantRole admin check (see initialize @dev note).
    function addMinter(address newMinter, uint256 allowance) public onlyRole(ADMIN_ROLE) whenNotPaused {
        require(!hasRole(MINTER_ROLE, newMinter), "Minter already exists");
        _minterAllowances[newMinter] = allowance;
        _grantRole(MINTER_ROLE, newMinter);
        emit MinterAdded(newMinter, allowance);
    }

    /// @dev Revokes MINTER_ROLE and clears the minting allowance atomically.
    function removeMinter(address minter) public onlyRole(ADMIN_ROLE) whenNotPaused {
        require(hasRole(MINTER_ROLE, minter), "Minter does not exist");
        delete _minterAllowances[minter];
        _revokeRole(MINTER_ROLE, minter);
        emit MinterRemoved(minter);
    }

    /// @dev Updates the minting allowance for an existing minter without changing their role.
    function modifyMinterAllowance(address minter, uint256 allowance) public onlyRole(ADMIN_ROLE) whenNotPaused {
        require(hasRole(MINTER_ROLE, minter), "Minter does not exist");
        uint256 oldAllowance = _minterAllowances[minter];
        _minterAllowances[minter] = allowance;
        emit MinterAllowanceChanged(minter, oldAllowance, allowance);
    }

    /**
     * @dev Returns all minters and their current allowances.
     */
    function getAllMinters() public view returns (MinterInfo[] memory) {
        address[] memory members = getRoleMembers(MINTER_ROLE);
        MinterInfo[] memory result = new MinterInfo[](members.length);
        for (uint256 i = 0; i < members.length; i++) {
            result[i] = MinterInfo({minter: members[i], allowance: _minterAllowances[members[i]]});
        }
        return result;
    }

    /**
     * @dev Returns the number of minters.
     */
    function getMinterCount() public view returns (uint256) {
        return getRoleMemberCount(MINTER_ROLE);
    }

    /**
     * @dev Returns all addresses with BURNER_ROLE.
     */
    function getAllBurners() public view returns (address[] memory) {
        return getRoleMembers(BURNER_ROLE);
    }

    /**
     * @dev Returns the number of burners.
     */
    function getBurnerCount() public view returns (uint256) {
        return getRoleMemberCount(BURNER_ROLE);
    }

    /// @dev Freezes `account`, blocking all transfers to, from, and on behalf of it.
    function freeze(address account) public onlyRole(FREEZER_ROLE) whenNotPaused {
        frozen[account] = true;
        emit AccountFrozen(account);
    }

    /// @dev Removes the freeze on `account`, restoring normal transfer capability.
    function unfreeze(address account) public onlyRole(FREEZER_ROLE) whenNotPaused {
        frozen[account] = false;
        emit AccountUnfrozen(account);
    }

    /// @dev Pauses all token transfers, minting, and burning.
    function pause() public onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /// @dev Resumes all token operations after a pause.
    function unpause() public onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    /**
     * @dev Updates the balances of `from` and `to` by `value`.
     *
     * This internal function is used by `transfer`, `transferFrom`, `mint`,
     * `burn`, and `burnFrom`. As a result, any constraints enforced here
     * (whenNotPaused, whenNotFrozen) also apply to all of those operations.
     */
    function _update(address from, address to, uint256 value)
        internal
        override(ERC20Upgradeable, ERC20PausableUpgradeable)
        whenNotPaused
        whenNotFrozen(msg.sender)
        whenNotFrozen(from)
        whenNotFrozen(to)
    {
        super._update(from, to, value);
    }

    /// @dev UUPS upgrade authorization — only ADMIN_ROLE can upgrade the implementation.
    /// Also rejects non-contract implementations so a fat-fingered EOA or
    /// `address(0)` cannot reach the `proxiableUUID` step (closes the raw
    /// `timelock.schedule(...)` bypass of `StablecoinTimelock.scheduleUpgrade`).
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(ADMIN_ROLE) {
        if (newImplementation.code.length == 0) revert NotAContract(newImplementation);
    }

    function _whenNotFrozen(address account) internal view {
        require(!frozen[account], "Frozen account");
    }

    /// @dev Centralized revoke hook for both `revokeRole` and `renounceRole`.
    /// For ADMIN_ROLE: rejects revocations targeting a non-holder (closes OZ's
    /// silent-no-op path, which would otherwise mask a typo'd address after a
    /// matured timelock window) and refuses to remove the last remaining
    /// holder (ADMIN_ROLE is its own admin, so a zero-admin state is
    /// unrecoverable on-chain). For other roles, behaves like OZ.
    function _revokeRole(bytes32 role, address account)
        internal
        override(AccessControlEnumerableUpgradeable)
        returns (bool)
    {
        if (role == ADMIN_ROLE) {
            if (!hasRole(ADMIN_ROLE, account)) revert NotAnAdmin(account);
            if (getRoleMemberCount(ADMIN_ROLE) == 1) revert AdminRoleCannotBeEmpty();
        }
        return super._revokeRole(role, account);
    }
}
