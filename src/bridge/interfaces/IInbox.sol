// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.30;

interface IInbox {
    /// @param message ABI-encoded (srcChain, srcSender, dstChain, dstRecipient, nonce, payload).
    /// @param signatures Packed ECDSA signatures (65 bytes each: r[32] || s[32] || v[1]).
    function recvMessage(bytes calldata message, bytes calldata signatures) external;
}
