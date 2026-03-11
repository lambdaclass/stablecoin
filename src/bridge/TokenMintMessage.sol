// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.30;

/// @title TokenMintMessage
/// @notice Encodes and decodes the application-level bridge payload (recipient + amount).
library TokenMintMessage {
    function encode(address recipient, uint256 amount) internal pure returns (bytes memory) {
        return abi.encode(recipient, amount);
    }

    function decode(bytes calldata payload) internal pure returns (address recipient, uint256 amount) {
        (recipient, amount) = abi.decode(payload, (address, uint256));
    }
}
