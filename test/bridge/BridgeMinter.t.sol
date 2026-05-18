// SPDX-License-Identifier: Apache-2.0
pragma solidity =0.8.30;

import {BridgeTestBase} from "./BridgeTestBase.sol";
import {BridgeMinter} from "../../src/bridge/BridgeMinter.sol";
import {TokenMintMessage} from "../../src/bridge/TokenMintMessage.sol";

contract BridgeMinterTest is BridgeTestBase {
    uint256 public constant SRC_CHAIN = 42;
    address public constant SRC_SENDER = address(0xAAAA);
    uint256 public constant MINTER_ALLOWANCE = 1_000_000e6;

    function setUp() public override {
        super.setUp();

        vm.startPrank(ADMIN);
        // Add BridgeMinter as a minter on the stablecoin
        stablecoin.addMinter(address(bridge.bridgeMinter), MINTER_ALLOWANCE);
        // Set allowed sender
        bridge.bridgeMinter.setAllowedSender(SRC_CHAIN, SRC_SENDER);
        vm.stopPrank();
    }

    function test_HandleMessageMints() public {
        address recipient = address(0xBEEF);
        uint256 amount = 500e6;
        bytes memory payload = TokenMintMessage.encode(recipient, amount);

        // Call from inbox
        vm.prank(address(bridge.inbox));
        bridge.bridgeMinter.handleMessage(SRC_CHAIN, SRC_SENDER, payload);

        assertEq(stablecoin.balanceOf(recipient), amount);
    }

    function test_OnlyInboxCanCallHandleMessage() public {
        bytes memory payload = TokenMintMessage.encode(address(0xBEEF), 100);

        vm.prank(address(0x9999));
        vm.expectRevert(BridgeMinter.OnlyInbox.selector);
        bridge.bridgeMinter.handleMessage(SRC_CHAIN, SRC_SENDER, payload);
    }

    function test_DisallowedSenderReverts() public {
        address wrongSender = address(0xBBBB);
        bytes memory payload = TokenMintMessage.encode(address(0xBEEF), 100);

        vm.prank(address(bridge.inbox));
        vm.expectRevert(abi.encodeWithSelector(BridgeMinter.DisallowedSender.selector, SRC_CHAIN, wrongSender));
        bridge.bridgeMinter.handleMessage(SRC_CHAIN, wrongSender, payload);
    }

    function test_UnknownChainReverts() public {
        uint256 unknownChain = 999;
        bytes memory payload = TokenMintMessage.encode(address(0xBEEF), 100);

        vm.prank(address(bridge.inbox));
        vm.expectRevert(abi.encodeWithSelector(BridgeMinter.DisallowedSender.selector, unknownChain, SRC_SENDER));
        bridge.bridgeMinter.handleMessage(unknownChain, SRC_SENDER, payload);
    }

    function test_OnlyOwnerCanSetAllowedSender() public {
        address nonOwner = address(0x9999);
        vm.prank(nonOwner);
        vm.expectRevert();
        bridge.bridgeMinter.setAllowedSender(1, address(0xBEEF));
    }

    function test_OnlyOwnerCanSetInbox() public {
        address nonOwner = address(0x9999);
        vm.prank(nonOwner);
        vm.expectRevert();
        bridge.bridgeMinter.setInbox(address(0x1111));
    }

    function test_OnlyOwnerCanSetStablecoin() public {
        address nonOwner = address(0x9999);
        vm.prank(nonOwner);
        vm.expectRevert();
        bridge.bridgeMinter.setStablecoin(address(0x1111));
    }
}
