// SPDX-License-Identifier: Apache-2.0
pragma solidity =0.8.30;

import {BridgeTestBase} from "./BridgeTestBase.sol";
import {BridgeMinter} from "../../src/bridge/BridgeMinter.sol";
import {TokenMintMessage} from "../../src/bridge/TokenMintMessage.sol";
import {Stablecoin} from "../../src/Stablecoin.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

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

    // ─── setStablecoin shape probe ────────────────────────────────────
    //
    // The shape probe is a safety net against operator typos: pasting an EOA, an
    // unrelated contract, or an undeployed CREATE2 target should all revert before
    // the storage slot is corrupted.

    function test_SetStablecoinRevertsOnEoa() public {
        // 0xCAFE is an EOA (no code). The probe call returns success with empty
        // return data; the bytes32 decode fails and triggers the catch branch.
        vm.prank(ADMIN);
        vm.expectRevert(abi.encodeWithSelector(BridgeMinter.NotAStablecoin.selector, address(0xCAFE)));
        bridge.bridgeMinter.setStablecoin(address(0xCAFE));
    }

    function test_SetStablecoinRevertsOnNonStablecoinContract() public {
        // A real contract that lacks the Stablecoin shape — calling BURNER_ROLE()
        // on it triggers the EVM fallback / no-such-function path.
        address notAStablecoin = address(bridge.inbox);
        vm.prank(ADMIN);
        vm.expectRevert(abi.encodeWithSelector(BridgeMinter.NotAStablecoin.selector, notAStablecoin));
        bridge.bridgeMinter.setStablecoin(notAStablecoin);
    }

    function test_SetStablecoinAcceptsRealStablecoin() public {
        // Sanity check that the probe doesn't false-positive against the real type.
        // (BridgeTestBase already calls setStablecoin in setUp; re-doing it here
        // exercises the post-deploy maintenance path explicitly.)
        vm.prank(ADMIN);
        bridge.bridgeMinter.setStablecoin(address(stablecoin));
        assertEq(address(bridge.bridgeMinter.stablecoin()), address(stablecoin));
    }

    /// @notice `setStablecoin` on the minter side enforces the same decimals check
    /// as the burner side. Without it, an operator could wire a non-6-decimal
    /// stablecoin on the destination chain and bridging would silently mis-mint.
    function test_SetStablecoinRejectsWrongDecimals() public {
        Stablecoin impl = new Stablecoin();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl), abi.encodeCall(Stablecoin.initialize, ("BadDec", "BAD", 18, ADMIN, BURNER, PAUSER, FREEZER))
        );
        address badStablecoin = address(proxy);

        vm.prank(ADMIN);
        vm.expectRevert(abi.encodeWithSelector(BridgeMinter.DecimalsMismatch.selector, 6, 18));
        bridge.bridgeMinter.setStablecoin(badStablecoin);
    }

    function test_ExpectedDecimalsConstant() public {
        assertEq(bridge.bridgeMinter.EXPECTED_DECIMALS(), 6);
    }
}
