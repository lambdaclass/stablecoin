// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.30;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {IOutbox} from "./interfaces/IOutbox.sol";

/// @title Outbox
/// @notice Generic message outbox. Accepts messages and emits events for the off-chain attestation service.
/// Stateless: does not track messages or nonces.
contract Outbox is Initializable, OwnableUpgradeable, UUPSUpgradeable, IOutbox {
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize the Outbox proxy with an owner.
    /// @param owner_ Address that will own the contract (can authorize upgrades).
    function initialize(address owner_) public initializer {
        __Ownable_init(owner_);
    }

    /// @inheritdoc IOutbox
    function sendMessage(uint256 dstChain, address dstRecipient, bytes calldata payload) external {
        emit MessageSent(msg.sender, dstChain, dstRecipient, payload);
    }

    /// @dev Authorize UUPS upgrades. Restricted to the contract owner.
    function _authorizeUpgrade(address) internal override onlyOwner {}
}
