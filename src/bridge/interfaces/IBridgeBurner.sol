// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.30;

interface IBridgeBurner {
    function sendTo(uint256 dstChain, address recipient, uint256 amount) external;
}
