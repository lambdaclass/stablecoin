// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.30;

interface IMessageReceiver {
    function handleMessage(uint256 srcChain, address srcSender, bytes calldata payload) external;
}
