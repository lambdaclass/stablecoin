// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.30;

import {BridgeTestBase} from "./BridgeTestBase.sol";
import {BridgeBurner} from "../../src/bridge/BridgeBurner.sol";
import {IOutbox} from "../../src/bridge/interfaces/IOutbox.sol";
import {TokenMintMessage} from "../../src/bridge/TokenMintMessage.sol";

contract BridgeBurnerTest is BridgeTestBase {
    address public user = address(0xCAFE);
    uint256 public constant MINT_AMOUNT = 10_000e6;
    uint256 public constant DST_CHAIN = 137;

    function setUp() public override {
        super.setUp();

        vm.startPrank(ADMIN);
        // Grant BURNER_ROLE to BridgeBurner
        stablecoin.grantRole(stablecoin.BURNER_ROLE(), address(bridge.bridgeBurner));
        // Set destination minter
        bridge.bridgeBurner.setDstMinter(DST_CHAIN, address(0xBEEF));
        // Mint tokens to user for testing
        stablecoin.addMinter(ADMIN, MINT_AMOUNT);
        vm.stopPrank();

        vm.prank(ADMIN);
        stablecoin.mint(user, MINT_AMOUNT);
    }

    function test_BurnAndSendMessage() public {
        uint256 amount = 1000e6;
        address recipient = address(0xDEAD);

        // User approves BridgeBurner to spend tokens
        vm.prank(user);
        stablecoin.approve(address(bridge.bridgeBurner), amount);

        // Expect the Outbox MessageSent event
        bytes memory expectedPayload = TokenMintMessage.encode(recipient, amount);
        vm.expectEmit(true, true, true, true, address(bridge.outbox));
        emit IOutbox.MessageSent(address(bridge.bridgeBurner), DST_CHAIN, address(0xBEEF), expectedPayload);

        vm.prank(user);
        bridge.bridgeBurner.sendTo(DST_CHAIN, recipient, amount);

        // User balance decreased
        assertEq(stablecoin.balanceOf(user), MINT_AMOUNT - amount);
    }

    function test_RevertsWithoutApproval() public {
        vm.prank(user);
        vm.expectRevert(); // ERC20 insufficient allowance
        bridge.bridgeBurner.sendTo(DST_CHAIN, address(0xDEAD), 1000e6);
    }

    function test_RevertsForUnknownDestination() public {
        uint256 unknownChain = 999;
        vm.prank(user);
        stablecoin.approve(address(bridge.bridgeBurner), 1000e6);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(BridgeBurner.DstMinterNotSet.selector, unknownChain));
        bridge.bridgeBurner.sendTo(unknownChain, address(0xDEAD), 1000e6);
    }

    function test_OnlyOwnerCanSetDstMinter() public {
        address nonOwner = address(0x9999);
        vm.prank(nonOwner);
        vm.expectRevert();
        bridge.bridgeBurner.setDstMinter(1, address(0xBEEF));
    }

    function test_OnlyOwnerCanSetOutbox() public {
        address nonOwner = address(0x9999);
        vm.prank(nonOwner);
        vm.expectRevert();
        bridge.bridgeBurner.setOutbox(address(0x1111));
    }

    function test_OnlyOwnerCanSetStablecoin() public {
        address nonOwner = address(0x9999);
        vm.prank(nonOwner);
        vm.expectRevert();
        bridge.bridgeBurner.setStablecoin(address(0x1111));
    }
}
