// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.30;

import {Stablecoin} from "../Stablecoin.sol";

/// @dev Illustrative V2 used to exercise the UUPS upgrade flow. `_maxSupply` is intentionally
/// stored and exposed but NOT enforced by `_update`: this contract demonstrates appending
/// storage and a reinitializer, not a supply-cap policy. Subclasses that want a real cap
/// must override `_update` (or the internal hook) to revert when `totalSupply() > _maxSupply`.
/// @custom:oz-upgrades-from Stablecoin
contract StablecoinV2 is Stablecoin {
    // New state variable appended after existing Stablecoin storage (slot 4+)
    uint256 private _maxSupply;

    function initializeV2(uint256 maxSupply_) public reinitializer(2) {
        _maxSupply = maxSupply_;
    }

    function version() public pure returns (string memory) {
        return "2.0.0";
    }

    function maxSupply() public view returns (uint256) {
        return _maxSupply;
    }

    function setMaxSupply(uint256 newMaxSupply) public onlyRole(ADMIN_ROLE) {
        _maxSupply = newMaxSupply;
    }
}
