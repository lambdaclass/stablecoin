// SPDX-License-Identifier: Apache-2.0
pragma solidity =0.8.30;

/// @title IOutbox
/// @notice Interface for the generic message outbox.
interface IOutbox {
    /// @notice Emitted when a message is sent to a destination chain.
    event MessageSent(address indexed sender, uint256 indexed dstChain, address indexed dstRecipient, bytes payload);

    /// @notice Send a message to a contract on a destination chain.
    /// @param dstChain Chain ID of the destination chain.
    /// @param dstRecipient Address of the receiver contract on the destination chain.
    /// @param payload Application-level data, opaque to the transport layer.
    function sendMessage(uint256 dstChain, address dstRecipient, bytes calldata payload) external;
}
