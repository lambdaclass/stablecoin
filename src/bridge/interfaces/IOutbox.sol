// SPDX-License-Identifier: Apache-2.0
pragma solidity =0.8.30;

/// @title IOutbox
/// @notice Interface for the generic message outbox.
/// @dev Each `MessageSent` event carries a per-sender sequence number AND a
/// derived nonce. The Inbox on the destination chain recomputes the nonce from
/// `(srcChain, srcOutbox, srcSender, srcSeq)` and uses it as the replay-protection
/// key, so attestors cannot choose the nonce independently of the source event.
interface IOutbox {
    /// @notice Emitted when a message is sent to a destination chain.
    /// @param sender The application contract calling `sendMessage` (e.g., BridgeBurner).
    /// @param dstChain Chain ID of the destination chain.
    /// @param dstRecipient Address of the receiver contract on the destination chain.
    /// @param srcSeq Per-sender monotonic sequence number assigned by this Outbox.
    /// @param nonce `keccak256(abi.encode(srcChain, srcOutbox, sender, srcSeq))` —
    /// emitted for off-chain observability; the Inbox recomputes it from the same
    /// fields in the signed message envelope.
    /// @param payload Application-level data, opaque to the transport layer.
    event MessageSent(
        address indexed sender,
        uint256 indexed dstChain,
        address indexed dstRecipient,
        uint256 srcSeq,
        bytes32 nonce,
        bytes payload
    );

    /// @notice Send a message to a contract on a destination chain.
    /// @param dstChain Chain ID of the destination chain.
    /// @param dstRecipient Address of the receiver contract on the destination chain.
    /// @param payload Application-level data, opaque to the transport layer.
    /// @return srcSeq Per-sender sequence number assigned to this message.
    /// @return nonce Derived nonce — see the `MessageSent` event docs.
    function sendMessage(uint256 dstChain, address dstRecipient, bytes calldata payload)
        external
        returns (uint256 srcSeq, bytes32 nonce);

    /// @notice Current sequence number assigned to the next message from `sender`.
    /// @param sender Application contract whose counter to read.
    /// @return Next sequence number that `sendMessage` would consume.
    function nextSeq(address sender) external view returns (uint256);
}
