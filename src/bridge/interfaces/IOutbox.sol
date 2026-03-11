// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.30;

interface IOutbox {
    event MessageSent(address indexed sender, uint256 indexed dstChain, address indexed dstRecipient, bytes payload);

    function sendMessage(uint256 dstChain, address dstRecipient, bytes calldata payload) external;
}
