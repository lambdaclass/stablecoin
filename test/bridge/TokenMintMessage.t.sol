// SPDX-License-Identifier: Apache-2.0
pragma solidity =0.8.30;

import {Test} from "forge-std/Test.sol";
import {TokenMintMessage} from "../../src/bridge/TokenMintMessage.sol";

contract TokenMintMessageTest is Test {
    function test_EncodeDecodeRoundtrip() public view {
        address recipient = address(0xBEEF);
        uint256 amount = 1000e6;

        bytes memory encoded = TokenMintMessage.encode(recipient, amount);
        (address decodedRecipient, uint256 decodedAmount) = this._decode(encoded);

        assertEq(decodedRecipient, recipient);
        assertEq(decodedAmount, amount);
    }

    function testFuzz_EncodeDecodeRoundtrip(address recipient, uint256 amount) public view {
        bytes memory encoded = TokenMintMessage.encode(recipient, amount);
        (address decodedRecipient, uint256 decodedAmount) = this._decode(encoded);

        assertEq(decodedRecipient, recipient);
        assertEq(decodedAmount, amount);
    }

    /// @dev Wrapper to call decode with calldata (library uses calldata param).
    function _decode(bytes calldata payload) external pure returns (address, uint256) {
        return TokenMintMessage.decode(payload);
    }
}
