// SPDX-License-Identifier: Apache-2.0
pragma solidity =0.8.30;

import {Stablecoin} from "./Stablecoin.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";

/// @custom:security-contact security@lambdaclass.com
/// @title StablecoinTimelock
/// @notice An OpenZeppelin `TimelockController` bound to a single `Stablecoin`
/// instance, exposing typed `schedule*` helpers for every operation gated by
/// the stablecoin's `ADMIN_ROLE`. The helpers build calldata internally; raw
/// `schedule(...)` remains available for any other target.
///
/// @dev Helpers route through `Address.functionDelegateCall(address(this), ...)`
/// because OZ's `schedule(...)` takes `bytes calldata` and its `_schedule`
/// internal hook is `private`, so memory-encoded payloads cannot be forwarded
/// directly. Self-delegatecall preserves `msg.sender`, so the inherited
/// `onlyRole(PROPOSER_ROLE)` check on `schedule` still validates against the
/// original caller of the helper.
contract StablecoinTimelock is TimelockController {
    /// @notice The stablecoin this timelock is bound to. Set at construction
    /// and not changeable thereafter.
    Stablecoin public immutable stablecoin;

    /// @notice The `minDelay` passed at construction. Acts as a permanent floor
    /// on `updateDelay`: governance can raise the delay, but cannot lower it
    /// below this deploy-time value. Closes the path where a proposer schedules
    /// `updateDelay(0)` to undermine the timelock. Operators set the floor they
    /// want at deploy time — no hardcoded minimum is imposed by this contract.
    uint256 public immutable deploymentMinDelay;

    error ZeroStablecoin();
    error DelayBelowDeployedFloor();
    error NoProposers();
    /// @dev `scheduleUpgrade` was called with an implementation address that has
    /// no bytecode. Surfaces at schedule time so the proposer doesn't burn the
    /// `minDelay` window before discovering the typo at execute time.
    error NotAContract(address impl);
    /// @dev `scheduleRevokeAdmin` was called with an address that does not hold
    /// `ADMIN_ROLE` on the bound stablecoin. Without this check OZ's
    /// `_revokeRole` would silently return `false` at execute time after the
    /// `minDelay` window had already elapsed.
    error NotAnAdmin(address account);
    /// @dev `scheduleRevokeBurner` was called with an address that does not hold
    /// `BURNER_ROLE`. See `scheduleRevokeBurner` for why this guard matters and
    /// how it differs from the admin path.
    error NotABurner(address account);
    /// @dev `scheduleRevokePauser` was called with an address that does not hold
    /// `PAUSER_ROLE`. See `scheduleRevokeBurner` for the shared rationale.
    error NotAPauser(address account);
    /// @dev `scheduleRevokeFreezer` was called with an address that does not hold
    /// `FREEZER_ROLE`. See `scheduleRevokeBurner` for the shared rationale.
    error NotAFreezer(address account);

    constructor(
        Stablecoin stablecoin_,
        uint256 minDelay,
        address[] memory proposers,
        address[] memory executors,
        address admin
    ) TimelockController(minDelay, proposers, executors, admin) {
        if (address(stablecoin_) == address(0)) revert ZeroStablecoin();
        if (proposers.length == 0) revert NoProposers();
        stablecoin = stablecoin_;
        deploymentMinDelay = minDelay;
    }

    /// @notice Overrides `TimelockController.updateDelay` to refuse any new
    /// delay below the deploy-time `deploymentMinDelay`. Reachable only via a
    /// matured timelock operation targeting `address(this)`, same as OZ.
    function updateDelay(uint256 newDelay) public virtual override {
        if (newDelay < deploymentMinDelay) revert DelayBelowDeployedFloor();
        super.updateDelay(newDelay);
    }

    /// @notice Schedules `grantRole(ADMIN_ROLE, newAdmin)` on the bound stablecoin.
    function scheduleGrantAdmin(address newAdmin, bytes32 salt, uint256 delay) external {
        bytes memory data = abi.encodeCall(stablecoin.grantRole, (stablecoin.ADMIN_ROLE(), newAdmin));
        _scheduleStablecoinCall(data, salt, delay);
    }

    /// @notice Schedules `revokeRole(ADMIN_ROLE, oldAdmin)` on the bound stablecoin.
    /// @dev Rejects `oldAdmin` values that do not currently hold `ADMIN_ROLE`.
    /// Without this guard a typo'd address would queue a call that OZ's
    /// `_revokeRole` silently no-ops on at execute time, wasting the `minDelay`
    /// window. Asymmetric with `removeMinter`, which already requires positive
    /// existence; this brings the admin path in line.
    function scheduleRevokeAdmin(address oldAdmin, bytes32 salt, uint256 delay) external {
        if (!stablecoin.hasRole(stablecoin.ADMIN_ROLE(), oldAdmin)) revert NotAnAdmin(oldAdmin);
        bytes memory data = abi.encodeCall(stablecoin.revokeRole, (stablecoin.ADMIN_ROLE(), oldAdmin));
        _scheduleStablecoinCall(data, salt, delay);
    }

    /// @notice Schedules `grantRole(BURNER_ROLE, account)` on the bound stablecoin.
    /// @dev `BURNER_ROLE`'s role admin is `ADMIN_ROLE`, which this timelock holds,
    /// so the matured operation is authorized at execute time.
    function scheduleGrantBurner(address account, bytes32 salt, uint256 delay) external {
        bytes memory data = abi.encodeCall(stablecoin.grantRole, (stablecoin.BURNER_ROLE(), account));
        _scheduleStablecoinCall(data, salt, delay);
    }

    /// @notice Schedules `revokeRole(BURNER_ROLE, account)` on the bound stablecoin.
    /// @dev Rejects `account` values that do not currently hold `BURNER_ROLE`, for
    /// the same reason as `scheduleRevokeAdmin`: OZ's `_revokeRole` silently no-ops
    /// on a non-holder, so without this guard a typo'd address would burn the full
    /// `minDelay` window before failing to do anything at execute time.
    ///
    /// Unlike `ADMIN_ROLE`, `Stablecoin._revokeRole` applies no extra guard to
    /// `BURNER_ROLE`, so this schedule-time check is the *only* line of defense —
    /// a proposer bypassing the helper via raw `schedule(...)` would still hit the
    /// silent no-op at execute time. There is likewise no last-holder guard, so
    /// revoking the sole burner is permitted.
    function scheduleRevokeBurner(address account, bytes32 salt, uint256 delay) external {
        if (!stablecoin.hasRole(stablecoin.BURNER_ROLE(), account)) revert NotABurner(account);
        bytes memory data = abi.encodeCall(stablecoin.revokeRole, (stablecoin.BURNER_ROLE(), account));
        _scheduleStablecoinCall(data, salt, delay);
    }

    /// @notice Schedules `grantRole(PAUSER_ROLE, account)` on the bound stablecoin.
    /// @dev `PAUSER_ROLE`'s role admin is `ADMIN_ROLE`, which this timelock holds.
    function scheduleGrantPauser(address account, bytes32 salt, uint256 delay) external {
        bytes memory data = abi.encodeCall(stablecoin.grantRole, (stablecoin.PAUSER_ROLE(), account));
        _scheduleStablecoinCall(data, salt, delay);
    }

    /// @notice Schedules `revokeRole(PAUSER_ROLE, account)` on the bound stablecoin.
    /// @dev Rejects non-holders at schedule time; see `scheduleRevokeBurner` for the
    /// rationale and the admin-path asymmetry that applies identically here.
    function scheduleRevokePauser(address account, bytes32 salt, uint256 delay) external {
        if (!stablecoin.hasRole(stablecoin.PAUSER_ROLE(), account)) revert NotAPauser(account);
        bytes memory data = abi.encodeCall(stablecoin.revokeRole, (stablecoin.PAUSER_ROLE(), account));
        _scheduleStablecoinCall(data, salt, delay);
    }

    /// @notice Schedules `grantRole(FREEZER_ROLE, account)` on the bound stablecoin.
    /// @dev `FREEZER_ROLE`'s role admin is `ADMIN_ROLE`, which this timelock holds.
    function scheduleGrantFreezer(address account, bytes32 salt, uint256 delay) external {
        bytes memory data = abi.encodeCall(stablecoin.grantRole, (stablecoin.FREEZER_ROLE(), account));
        _scheduleStablecoinCall(data, salt, delay);
    }

    /// @notice Schedules `revokeRole(FREEZER_ROLE, account)` on the bound stablecoin.
    /// @dev Rejects non-holders at schedule time; see `scheduleRevokeBurner` for the
    /// rationale and the admin-path asymmetry that applies identically here.
    function scheduleRevokeFreezer(address account, bytes32 salt, uint256 delay) external {
        if (!stablecoin.hasRole(stablecoin.FREEZER_ROLE(), account)) revert NotAFreezer(account);
        bytes memory data = abi.encodeCall(stablecoin.revokeRole, (stablecoin.FREEZER_ROLE(), account));
        _scheduleStablecoinCall(data, salt, delay);
    }

    /// @notice Schedules `addMinter(minter, cap)` on the bound stablecoin.
    function scheduleAddMinter(address minter, uint256 cap, bytes32 salt, uint256 delay) external {
        bytes memory data = abi.encodeCall(stablecoin.addMinter, (minter, cap));
        _scheduleStablecoinCall(data, salt, delay);
    }

    /// @notice Schedules `removeMinter(minter)` on the bound stablecoin.
    function scheduleRemoveMinter(address minter, bytes32 salt, uint256 delay) external {
        bytes memory data = abi.encodeCall(stablecoin.removeMinter, (minter));
        _scheduleStablecoinCall(data, salt, delay);
    }

    /// @notice Schedules `modifyMinterAllowance(minter, delta)` on the bound stablecoin.
    /// @dev `delta` is a signed change applied relative to the minter's current allowance
    /// (see `Stablecoin.modifyMinterAllowance`).
    function scheduleModifyMinterAllowance(address minter, int256 delta, bytes32 salt, uint256 delay) external {
        bytes memory data = abi.encodeCall(stablecoin.modifyMinterAllowance, (minter, delta));
        _scheduleStablecoinCall(data, salt, delay);
    }

    /// @notice Schedules a UUPS `upgradeToAndCall(newImplementation, data)` on the
    /// bound stablecoin proxy. Use empty `data` for a pure implementation swap;
    /// pass ABI-encoded reinitializer calldata for staged migrations.
    /// @dev Rejects `newImplementation` values with no bytecode (EOAs,
    /// `address(0)`, never-deployed addresses). Without this guard a fat-finger
    /// would only surface at execute time, wasting the `minDelay` window.
    function scheduleUpgrade(address newImplementation, bytes calldata data, bytes32 salt, uint256 delay) external {
        if (newImplementation.code.length == 0) revert NotAContract(newImplementation);
        bytes memory payload = abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (newImplementation, data));
        _scheduleStablecoinCall(payload, salt, delay);
    }

    function _scheduleStablecoinCall(bytes memory data, bytes32 salt, uint256 delay) private {
        Address.functionDelegateCall(
            address(this), abi.encodeCall(this.schedule, (address(stablecoin), 0, data, bytes32(0), salt, delay))
        );
    }
}
