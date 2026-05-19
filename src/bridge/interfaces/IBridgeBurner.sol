// SPDX-License-Identifier: Apache-2.0
pragma solidity =0.8.30;

/// @title IBridgeBurner
/// @notice Interface for the bridge entry point that burns tokens and initiates a cross-chain transfer.
interface IBridgeBurner {
    /// @notice Burn tokens from the caller and send a mint message to the destination chain.
    /// @param dstChain Chain ID of the destination chain.
    /// @param recipient Address that will receive minted tokens on the destination chain.
    /// @param amount Number of tokens to burn and mint.
    function sendTo(uint256 dstChain, address recipient, uint256 amount) external;
}
