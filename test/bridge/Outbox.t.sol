// SPDX-License-Identifier: Apache-2.0
pragma solidity =0.8.30;

import {BridgeTestBase} from "./BridgeTestBase.sol";
import {IOutbox} from "../../src/bridge/interfaces/IOutbox.sol";

contract OutboxTest is BridgeTestBase {
    function test_SendMessageEmitsEventWithDerivedNonce() public {
        address sender = address(0xCAFE);
        uint256 dstChain = 137;
        address dstRecipient = address(0xBEEF);
        bytes memory payload = hex"1234";

        // First message from `sender` consumes srcSeq=0; nonce derives from
        // (this chain id, this outbox addr, sender, 0). Must match the Outbox
        // formula exactly.
        bytes32 expectedNonce = keccak256(abi.encode(block.chainid, address(bridge.outbox), sender, uint256(0)));

        vm.prank(sender);
        vm.expectEmit(true, true, true, true);
        emit IOutbox.MessageSent(sender, dstChain, dstRecipient, 0, expectedNonce, payload);
        bridge.outbox.sendMessage(dstChain, dstRecipient, payload);

        // Counter advanced.
        assertEq(bridge.outbox.nextSeq(sender), 1);
    }

    /// @notice Each sender has its own monotonically-increasing counter. Sending from
    /// sender A does not affect sender B's sequence.
    function test_PerSenderCounterIndependence() public {
        address a = address(0xA);
        address b = address(0xB);

        vm.prank(a);
        bridge.outbox.sendMessage(1, address(0xBEEF), hex"01");
        vm.prank(a);
        bridge.outbox.sendMessage(1, address(0xBEEF), hex"02");
        vm.prank(b);
        bridge.outbox.sendMessage(1, address(0xBEEF), hex"03");

        assertEq(bridge.outbox.nextSeq(a), 2);
        assertEq(bridge.outbox.nextSeq(b), 1);
    }

    /// @notice Re-sending the same logical content from the same sender yields a
    /// DIFFERENT nonce on every call, because the per-sender counter increments.
    /// This is what makes attestor re-attestation harmless: the same source event
    /// always derives the same nonce, but a *new* source event derives a *new* one.
    function test_NonceChangesAcrossSequentialSends() public {
        address sender = address(0xCAFE);

        vm.prank(sender);
        (uint256 seq0, bytes32 nonce0) = bridge.outbox.sendMessage(1, address(0xBEEF), hex"01");

        vm.prank(sender);
        (uint256 seq1, bytes32 nonce1) = bridge.outbox.sendMessage(1, address(0xBEEF), hex"02");

        assertEq(seq0, 0);
        assertEq(seq1, 1);
        assertTrue(nonce0 != nonce1);
    }

    function test_AnyoneCanSendMessage() public {
        address randomUser = address(0x1234);
        vm.prank(randomUser);
        bridge.outbox.sendMessage(1, address(0xBEEF), hex"");
    }
}
