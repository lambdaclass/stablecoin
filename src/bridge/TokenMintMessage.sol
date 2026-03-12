// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.30;

/// @title TokenMintMessage
/// @notice Encodes and decodes the application-level bridge payload (recipient + amount).
library TokenMintMessage {
    /// @notice ABI-encode a mint payload.
    /// @param recipient Address that will receive the minted tokens.
    /// @param amount Number of tokens to mint.
    /// @return The ABI-encoded payload.
    function encode(address recipient, uint256 amount) internal pure returns (bytes memory) {
        return abi.encode(recipient, amount);
    }

    /// @notice ABI-decode a mint payload.
    /// @param payload The ABI-encoded payload produced by `encode`.
    /// @return recipient Address that will receive the minted tokens.
    /// @return amount Number of tokens to mint.
    function decode(bytes calldata payload) internal pure returns (address recipient, uint256 amount) {
        (recipient, amount) = abi.decode(payload, (address, uint256));
    }
}
