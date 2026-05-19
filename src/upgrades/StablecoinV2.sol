// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.30;

import {Stablecoin} from "../Stablecoin.sol";

/// @title StablecoinV2
/// @notice Illustrative second version of the Stablecoin used to exercise the UUPS upgrade
/// path. Adds a `_maxSupply` storage variable appended after V1 storage and a reinitializer
/// hook to populate it.
/// @dev `_maxSupply` is intentionally stored and exposed but NOT enforced by `_update`: this
/// contract demonstrates appending storage and a reinitializer, not a supply-cap policy.
/// Subclasses that want a real cap must override `_update` (or the internal hook) to revert
/// when `totalSupply() > _maxSupply`.
/// @custom:oz-upgrades-from Stablecoin
/// @custom:security-contact security@lambdaclass.com
contract StablecoinV2 is Stablecoin {
    /// @dev New storage slot appended after V1 layout (slot 4+).
    uint256 private _maxSupply;

    /// @notice Reinitializer that sets the initial supply cap. Must be invoked exactly once,
    /// keyed to version 2 of the proxy state.
    /// @param maxSupply_ Cap value to record.
    function initializeV2(uint256 maxSupply_) public reinitializer(2) {
        _maxSupply = maxSupply_;
    }

    /// @notice Returns the contract semantic version string.
    function version() public pure returns (string memory) {
        return "2.0.0";
    }

    /// @notice Returns the configured supply cap.
    function maxSupply() public view returns (uint256) {
        return _maxSupply;
    }

    /// @notice Update the supply cap. Restricted to ADMIN_ROLE.
    function setMaxSupply(uint256 newMaxSupply) public onlyRole(ADMIN_ROLE) {
        _maxSupply = newMaxSupply;
    }
}
