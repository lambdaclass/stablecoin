// SPDX-License-Identifier: Apache-2.0
pragma solidity =0.8.30;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {IOutbox} from "./interfaces/IOutbox.sol";

/// @title Outbox
/// @notice Generic message outbox. Accepts messages and emits events for the off-chain attestation service.
/// Stateless: does not track messages or nonces.
contract Outbox is Initializable, Ownable2StepUpgradeable, PausableUpgradeable, UUPSUpgradeable, IOutbox {
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize the Outbox proxy with an owner.
    /// @param owner_ Address that will own the contract (can authorize upgrades).
    function initialize(address owner_) public initializer {
        __Ownable_init(owner_);
        __Pausable_init();
    }

    /// @inheritdoc IOutbox
    function sendMessage(uint256 dstChain, address dstRecipient, bytes calldata payload) external whenNotPaused {
        emit MessageSent(msg.sender, dstChain, dstRecipient, payload);
    }

    /// @notice Pause the outbox, blocking all outbound messages.
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpause the outbox, resuming outbound messages.
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @dev Authorize UUPS upgrades. Restricted to the contract owner.
    function _authorizeUpgrade(address) internal override onlyOwner {}
}
