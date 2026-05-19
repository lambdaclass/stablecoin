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
import {SignedMath} from "@openzeppelin/contracts/utils/math/SignedMath.sol";

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
    /// @notice Role that manages minters/allowances and authorizes UUPS upgrades.
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    /// @notice Role authorized to burn tokens (own balance or via allowance).
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");
    /// @notice Role authorized to freeze/unfreeze accounts.
    bytes32 public constant FREEZER_ROLE = keccak256("FREEZER_ROLE");
    /// @notice Role authorized to mint tokens up to a per-minter allowance.
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    /// @notice Role authorized to pause/unpause the contract.
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    /// @dev Per-minter mint allowance, decremented on each mint().
    mapping(address minter => uint256 allowance) private _minterAllowances;
    /// @notice Accounts blocked from sending, receiving, or operating on token transfers.
    mapping(address account => bool isFrozen) public frozen;
    /// @dev Token decimals captured at initialize and returned by `decimals()`.
    uint8 private _decimals;

    /// @notice Pair returned by `getAllMinters()` describing a minter and its remaining allowance.
    struct MinterInfo {
        address minter;
        uint256 allowance;
    }

    /// @notice Emitted when `minter` is added with the initial `allowance`.
    event MinterAdded(address indexed minter, uint256 allowance);
    /// @notice Emitted when `minter` is revoked.
    event MinterRemoved(address indexed minter);
    /// @notice Emitted when `minter`'s allowance is updated from `oldAllowance` to `newAllowance`.
    event MinterAllowanceChanged(address indexed minter, uint256 oldAllowance, uint256 newAllowance);
    /// @notice Emitted when `account` is frozen.
    event AccountFrozen(address indexed account);
    /// @notice Emitted when `account` is unfrozen.
    event AccountUnfrozen(address indexed account);

    error ZeroAddress(bytes32 role);
    error ValueExceedsAllowance(uint256 requested, uint256 allowance);
    error MinterAlreadyExists(address minter);
    error MinterDoesNotExist(address minter);
    error AccountIsFrozen(address account);

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
        if (admin == address(0)) revert ZeroAddress(ADMIN_ROLE);
        if (burner == address(0)) revert ZeroAddress(BURNER_ROLE);
        if (pauser == address(0)) revert ZeroAddress(PAUSER_ROLE);
        if (freezer == address(0)) revert ZeroAddress(FREEZER_ROLE);

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

    /// @notice Returns the token decimals captured at initialize() time.
    /// @dev Overrides ERC20Upgradeable's hard-coded 18; the value is fixed at proxy
    /// initialization and cannot be changed post-deployment.
    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    /// @dev Mints `value` tokens to `to`, deducting from the caller's minter allowance.
    /// Marked `virtual` so subclasses (e.g. a future StablecoinV2) can override to layer
    /// additional invariants without abandoning the inheritance-based upgrade pattern.
    /// The pause check lives in `_update` (invoked by `_mint`); the public function does
    /// not need its own `whenNotPaused` modifier.
    function mint(address to, uint256 value) public virtual onlyRole(MINTER_ROLE) {
        address sender = _msgSender();
        uint256 allowance = _minterAllowances[sender];
        require(allowance >= value, ValueExceedsAllowance(value, allowance));
        _minterAllowances[sender] = allowance - value;
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
        require(_grantRole(MINTER_ROLE, newMinter), MinterAlreadyExists(newMinter));
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
        require(_revokeRole(MINTER_ROLE, minter), MinterDoesNotExist(minter));
        delete _minterAllowances[minter];
        emit MinterRemoved(minter);
    }

    /// @dev Applies a signed `delta` to the minter's allowance, relative to its current value.
    ///
    /// Using a delta (rather than an absolute replacement) closes a front-running window:
    /// with an absolute API, a planned change from A to B could be raced by a `mint(_, A)`
    /// that consumes the OLD allowance just before B is written — effectively spending
    /// both A and B. With a delta, the change is always relative to whatever the current
    /// allowance is at the moment the change lands, so a front-running mint can only ever
    /// shrink the post-state, never re-grant the consumed amount.
    ///
    /// Negative deltas saturate at zero (no underflow revert).
    ///
    /// While paused, only reductions (delta <= 0) are accepted, so the admin can de-risk
    /// a compromised minter without an unpause-window race, but cannot raise allowances
    /// until the contract is unpaused.
    function modifyMinterAllowance(address minter, int256 delta) public onlyRole(ADMIN_ROLE) {
        require(hasRole(MINTER_ROLE, minter), MinterDoesNotExist(minter));
        require(!paused() || delta <= 0, "Cannot increase allowance while paused");
        uint256 oldAllowance = _minterAllowances[minter];
        uint256 newAllowance;
        if (delta >= 0) {
            newAllowance = oldAllowance + uint256(delta);
        } else {
            uint256 magnitude = SignedMath.abs(delta);
            newAllowance = magnitude >= oldAllowance ? 0 : oldAllowance - magnitude;
        }
        _minterAllowances[minter] = newAllowance;
        emit MinterAllowanceChanged(minter, oldAllowance, newAllowance);
    }

    /**
     * @dev Returns all minters and their current allowances.
     */
    function getAllMinters() public view returns (MinterInfo[] memory) {
        address[] memory members = getRoleMembers(MINTER_ROLE);
        MinterInfo[] memory result = new MinterInfo[](members.length);
        for (uint256 i = 0; i < members.length; ++i) {
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
        whenNotFrozen(_msgSender())
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
    /// Also rejects non-contract implementations so a fat-fingered EOA or
    /// `address(0)` cannot reach the `proxiableUUID` step (closes the raw
    /// `timelock.schedule(...)` bypass of `StablecoinTimelock.scheduleUpgrade`).
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(ADMIN_ROLE) {
        if (newImplementation.code.length == 0) revert NotAContract(newImplementation);
    }

    function _whenNotFrozen(address account) internal view {
        require(!frozen[account], AccountIsFrozen(account));
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
