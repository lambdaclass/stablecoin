// SPDX-License-Identifier: Apache-2.0
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

        // Expect the Outbox MessageSent event: it carries the per-sender srcSeq
        // plus the derived source-bound nonce.
        bytes memory expectedPayload = TokenMintMessage.encode(recipient, amount);
        bytes32 expectedNonce =
            keccak256(abi.encode(block.chainid, address(bridge.outbox), address(bridge.bridgeBurner), uint256(0)));
        vm.expectEmit(true, true, true, true, address(bridge.outbox));
        emit IOutbox.MessageSent(
            address(bridge.bridgeBurner), DST_CHAIN, address(0xBEEF), 0, expectedNonce, expectedPayload
        );

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

    // ─── Outbox validation (L-04 / #7) ────────────────────────────────

    function test_SetOutboxRejectsZeroAddress() public {
        vm.prank(ADMIN);
        vm.expectRevert(abi.encodeWithSelector(BridgeBurner.ZeroAddress.selector, bytes32("outbox")));
        bridge.bridgeBurner.setOutbox(address(0));
    }

    function test_SetOutboxRejectsEOA() public {
        // An EOA has no code; the try/catch around supportsInterface fails and
        // _validateOutbox reverts with InvalidOutbox.
        address eoa = address(0xBADC0DE);
        vm.prank(ADMIN);
        vm.expectRevert(abi.encodeWithSelector(BridgeBurner.InvalidOutbox.selector, eoa));
        bridge.bridgeBurner.setOutbox(eoa);
    }

    function test_SetOutboxRejectsSilentOutbox() public {
        // A contract that exposes sendMessage but doesn't advertise IOutbox via
        // ERC-165 must be rejected — this is the failure mode the audit found
        // (tokens burn without a verifiable bridge message).
        SilentOutbox silent = new SilentOutbox();
        vm.prank(ADMIN);
        vm.expectRevert(abi.encodeWithSelector(BridgeBurner.InvalidOutbox.selector, address(silent)));
        bridge.bridgeBurner.setOutbox(address(silent));
    }

    function test_SetOutboxRejectsContractReturningFalse() public {
        // A contract that implements supportsInterface but returns false for
        // IOutbox is rejected by the require inside _validateOutbox.
        LyingOutbox lying = new LyingOutbox();
        vm.prank(ADMIN);
        vm.expectRevert(abi.encodeWithSelector(BridgeBurner.InvalidOutbox.selector, address(lying)));
        bridge.bridgeBurner.setOutbox(address(lying));
    }

    function test_SetOutboxAcceptsCanonicalOutbox() public {
        // The canonical Outbox deployed in setUp advertises IOutbox via ERC-165,
        // so swapping to a freshly-deployed canonical Outbox succeeds.
        address newOutbox = address(bridge.outbox);
        vm.prank(ADMIN);
        bridge.bridgeBurner.setOutbox(newOutbox);
        assertEq(address(bridge.bridgeBurner.outbox()), newOutbox);
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
        vm.expectRevert(abi.encodeWithSelector(BridgeBurner.NotAStablecoin.selector, address(0xCAFE)));
        bridge.bridgeBurner.setStablecoin(address(0xCAFE));
    }

    function test_SetStablecoinRevertsOnNonStablecoinContract() public {
        // A real contract that lacks the Stablecoin shape — calling BURNER_ROLE()
        // on it triggers the EVM fallback / no-such-function path.
        address notAStablecoin = address(bridge.outbox);
        vm.prank(ADMIN);
        vm.expectRevert(abi.encodeWithSelector(BridgeBurner.NotAStablecoin.selector, notAStablecoin));
        bridge.bridgeBurner.setStablecoin(notAStablecoin);
    }

    function test_SetStablecoinAcceptsRealStablecoin() public {
        // Sanity check that the probe doesn't false-positive against the real type.
        // (BridgeTestBase already calls setStablecoin in setUp; re-doing it here
        // exercises the post-deploy maintenance path explicitly.)
        vm.prank(ADMIN);
        bridge.bridgeBurner.setStablecoin(address(stablecoin));
        assertEq(address(bridge.bridgeBurner.stablecoin()), address(stablecoin));
    }
}

/// @dev Exposes `sendMessage` matching the IOutbox signature but does NOT emit
/// `MessageSent` and does NOT advertise IOutbox via ERC-165. Models the audit's
/// "silent Outbox" attack — `BridgeBurner.setOutbox` must reject this.
contract SilentOutbox {
    function sendMessage(uint256, address, bytes calldata) external pure {
        // no-op: deliberately does not emit MessageSent
    }
}

/// @dev Implements supportsInterface but returns false for every interface ID,
/// including IOutbox. `BridgeBurner.setOutbox` must reject this.
contract LyingOutbox {
    function sendMessage(uint256, address, bytes calldata) external pure {}

    function supportsInterface(bytes4) external pure returns (bool) {
        return false;
    }
}
