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
 *  - ADMIN_ROLE: Manages minters and their allowances, authorizes upgrades.
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
        _setRoleAdmin(BURNER_ROLE, ADMIN_ROLE);
        _setRoleAdmin(PAUSER_ROLE, ADMIN_ROLE);
        _setRoleAdmin(FREEZER_ROLE, ADMIN_ROLE);
        _grantRole(ADMIN_ROLE, admin);
        _grantRole(BURNER_ROLE, burner);
        _grantRole(PAUSER_ROLE, pauser);
        _grantRole(FREEZER_ROLE, freezer);
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    /// @dev Mints `value` tokens to `to`, deducting from the caller's minter allowance.
    /// Marked `virtual` so subclasses (e.g. a future StablecoinV2) can override to layer
    /// additional invariants without abandoning the inheritance-based upgrade pattern.
    /// The pause check lives in `_update` (invoked by `_mint`); the public function does
    /// not need its own `whenNotPaused` modifier.
    function mint(address to, uint256 value) public virtual onlyRole(MINTER_ROLE) {
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
    /// Pause is enforced inside `_update` (invoked by `_burn`).
    function burn(uint256 value) public override onlyRole(BURNER_ROLE) {
        _burn(_msgSender(), value);
    }

    /// @dev Burns `value` tokens from `account` using the caller's ERC20 allowance. Restricted to BURNER_ROLE.
    /// Pause is enforced inside `_update` (invoked by `_burn`).
    function burnFrom(address account, uint256 value) public override onlyRole(BURNER_ROLE) {
        _spendAllowance(account, _msgSender(), value);
        _burn(account, value);
    }

    /// @dev Grants MINTER_ROLE and sets the minting allowance atomically.
    /// Uses _grantRole to bypass the external grantRole admin check (see initialize @dev note).
    /// _grantRole returns false when the role was already held, so the pre-check via
    /// hasRole is redundant.
    function addMinter(address newMinter, uint256 allowance) public onlyRole(ADMIN_ROLE) whenNotPaused {
        require(_grantRole(MINTER_ROLE, newMinter), "Minter already exists");
        _minterAllowances[newMinter] = allowance;
        emit MinterAdded(newMinter, allowance);
    }

    /// @dev Revokes MINTER_ROLE and clears the minting allowance atomically.
    /// _revokeRole returns false when the role was not held, so the pre-check via
    /// hasRole is redundant.
    ///
    /// Available while paused so an emergency response (pause) does not block emergency
    /// revocation of a suspected-compromised minter. Token movements are still blocked
    /// by `_update`'s pause check, so this does not open a new token-flow path.
    function removeMinter(address minter) public onlyRole(ADMIN_ROLE) {
        require(_revokeRole(MINTER_ROLE, minter), "Minter does not exist");
        delete _minterAllowances[minter];
        emit MinterRemoved(minter);
    }

    /// @dev Updates the minting allowance for an existing minter without changing their role.
    ///
    /// While paused, only reductions (new <= current) are accepted, so the admin can de-risk
    /// a compromised minter without an unpause-window race, but cannot raise allowances until
    /// the contract is unpaused.
    function modifyMinterAllowance(address minter, uint256 allowance) public onlyRole(ADMIN_ROLE) {
        require(hasRole(MINTER_ROLE, minter), "Minter does not exist");
        uint256 oldAllowance = _minterAllowances[minter];
        require(!paused() || allowance <= oldAllowance, "Cannot increase allowance while paused");
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
    /// Reverts on `address(0)` because the zero address is used as `from` for mint and
    /// `to` for burn; freezing it would break both flows.
    function freeze(address account) public onlyRole(FREEZER_ROLE) whenNotPaused {
        require(account != address(0), "Cannot freeze zero address");
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
    /// @dev Marked `virtual` so subclasses can override to add invariants (supply cap,
    /// blacklist policy, etc.) that should apply to every token movement.
    function _update(address from, address to, uint256 value)
        internal
        virtual
        override(ERC20Upgradeable, ERC20PausableUpgradeable)
        whenNotPaused
        whenNotFrozen(msg.sender)
        whenNotFrozen(from)
        whenNotFrozen(to)
    {
        super._update(from, to, value);
    }

    /// @dev Block allowance grants while paused. `_update` already blocks token movement,
    /// but `approve` and `_spendAllowance` do not route through `_update`, so without
    /// this override `approve()` (and the allowance bookkeeping inside `transferFrom` /
    /// `burnFrom`) could still mutate state during a pause.
    function _approve(address owner, address spender, uint256 value, bool emitEvent)
        internal
        override
        whenNotPaused
    {
        super._approve(owner, spender, value, emitEvent);
    }

    /// @dev UUPS upgrade authorization — only ADMIN_ROLE can upgrade the implementation.
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(ADMIN_ROLE) {}

    function _whenNotFrozen(address account) internal view {
        require(!frozen[account], "Frozen account");
    }
}
