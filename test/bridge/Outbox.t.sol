// SPDX-License-Identifier: Apache-2.0
pragma solidity =0.8.30;

import {BridgeTestBase} from "./BridgeTestBase.sol";
import {IOutbox} from "../../src/bridge/interfaces/IOutbox.sol";

contract OutboxTest is BridgeTestBase {
    function test_SendMessageEmitsEvent() public {
        address sender = address(0xCAFE);
        uint256 dstChain = 137;
        address dstRecipient = address(0xBEEF);
        bytes memory payload = hex"1234";

        vm.prank(sender);
        vm.expectEmit(true, true, true, true);
        emit IOutbox.MessageSent(sender, dstChain, dstRecipient, payload);
        bridge.outbox.sendMessage(dstChain, dstRecipient, payload);
    }

    function test_AnyoneCanSendMessage() public {
        address randomUser = address(0x1234);
        vm.prank(randomUser);
        bridge.outbox.sendMessage(1, address(0xBEEF), hex"");
    }
}
