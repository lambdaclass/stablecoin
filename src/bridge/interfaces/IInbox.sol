// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.30;

/// @title IInbox
/// @notice Interface for the generic message inbox with attestor-verified delivery.
interface IInbox {
    /// @notice Verify attestor signatures and deliver a message to the destination receiver.
    ///         The message is delivered as an `IMessageReceiver.handleMessage` call to the recipient.
    /// @param message ABI-encoded (srcChain, srcSender, dstChain, dstRecipient, nonce, payload).
    /// @param signatures Packed ECDSA signatures (65 bytes each: r[32] || s[32] || v[1]).
    function recvMessage(bytes calldata message, bytes calldata signatures) external;
}
