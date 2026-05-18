// SPDX-License-Identifier: Apache-2.0
pragma solidity =0.8.30;

import {Stablecoin} from "../Stablecoin.sol";

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
