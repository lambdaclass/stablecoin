// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.30;

/// @title IMessageReceiver
/// @notice Interface for contracts that receive cross-chain messages from the Inbox.
interface IMessageReceiver {
    /// @notice Handle a verified message delivered by the Inbox.
    /// @param srcChain Chain ID where the message originated.
    /// @param srcSender Address that sent the message on the source chain.
    /// @param payload Application-level data.
    function handleMessage(uint256 srcChain, address srcSender, bytes calldata payload) external;
}
