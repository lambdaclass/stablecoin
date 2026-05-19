// SPDX-License-Identifier: UNLICENSED
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
    function scheduleRevokeAdmin(address oldAdmin, bytes32 salt, uint256 delay) external {
        bytes memory data = abi.encodeCall(stablecoin.revokeRole, (stablecoin.ADMIN_ROLE(), oldAdmin));
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

    /// @notice Schedules `modifyMinterAllowance(minter, newCap)` on the bound stablecoin.
    function scheduleModifyMinterAllowance(address minter, uint256 newCap, bytes32 salt, uint256 delay) external {
        bytes memory data = abi.encodeCall(stablecoin.modifyMinterAllowance, (minter, newCap));
        _scheduleStablecoinCall(data, salt, delay);
    }

    /// @notice Schedules a UUPS `upgradeToAndCall(newImplementation, data)` on the
    /// bound stablecoin proxy. Use empty `data` for a pure implementation swap;
    /// pass ABI-encoded reinitializer calldata for staged migrations.
    function scheduleUpgrade(address newImplementation, bytes calldata data, bytes32 salt, uint256 delay) external {
        bytes memory payload = abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (newImplementation, data));
        _scheduleStablecoinCall(payload, salt, delay);
    }

    function _scheduleStablecoinCall(bytes memory data, bytes32 salt, uint256 delay) private {
        Address.functionDelegateCall(
            address(this), abi.encodeCall(this.schedule, (address(stablecoin), 0, data, bytes32(0), salt, delay))
        );
    }
}
