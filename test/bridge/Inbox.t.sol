// SPDX-License-Identifier: Apache-2.0
pragma solidity =0.8.30;

import {BridgeTestBase} from "./BridgeTestBase.sol";
import {Inbox} from "../../src/bridge/Inbox.sol";
import {IMessageReceiver} from "../../src/bridge/interfaces/IMessageReceiver.sol";

/// @dev Mock receiver that records calls for testing.
contract MockReceiver is IMessageReceiver {
    uint256 public lastSrcChain;
    address public lastSrcSender;
    bytes public lastPayload;
    uint256 public callCount;

    function handleMessage(uint256 srcChain, address srcSender, bytes calldata payload) external {
        lastSrcChain = srcChain;
        lastSrcSender = srcSender;
        lastPayload = payload;
        callCount++;
    }
}

contract InboxTest is BridgeTestBase {
    MockReceiver public receiver;
    uint256 public constant SRC_CHAIN = 42;

    function setUp() public override {
        super.setUp();
        receiver = new MockReceiver();

        // Configure inbox with attestors and threshold=2
        vm.startPrank(ADMIN);
        bridge.inbox.addAttestor(attestor1);
        bridge.inbox.addAttestor(attestor2);
        bridge.inbox.addAttestor(attestor3);
        bridge.inbox.setThreshold(2);
        // Register the canonical source Outbox for srcChain=42.
        bridge.inbox.setSrcOutbox(SRC_CHAIN, address(bridge.outbox));
        vm.stopPrank();
    }

    // ─── Valid k-of-n signatures ─────────────────────────────────────

    function test_ValidKOfNSignatures() public {
        bytes memory payload = hex"CAFE";
        bytes memory message = _encodeMessage(
            SRC_CHAIN, address(bridge.outbox), address(0xAAAA), 1, block.chainid, address(receiver), payload
        );

        uint256[] memory pks = new uint256[](2);
        pks[0] = ATTESTOR_PK_1;
        pks[1] = ATTESTOR_PK_2;
        bytes memory sigs = _signMessage(bridge.inbox, message, pks);

        bridge.inbox.recvMessage(message, sigs);

        assertEq(receiver.callCount(), 1);
        assertEq(receiver.lastSrcChain(), SRC_CHAIN);
        assertEq(receiver.lastSrcSender(), address(0xAAAA));
        assertEq(receiver.lastPayload(), payload);
    }

    function test_AllThreeSignatures() public {
        bytes memory message = _encodeMessage(
            SRC_CHAIN, address(bridge.outbox), address(0xAAAA), 2, block.chainid, address(receiver), hex""
        );

        uint256[] memory pks = new uint256[](3);
        pks[0] = ATTESTOR_PK_1;
        pks[1] = ATTESTOR_PK_2;
        pks[2] = ATTESTOR_PK_3;
        bytes memory sigs = _signMessage(bridge.inbox, message, pks);

        bridge.inbox.recvMessage(message, sigs);
        assertEq(receiver.callCount(), 1);
    }

    // ─── Below threshold ─────────────────────────────────────────────

    function test_BelowThresholdReverts() public {
        bytes memory message = _encodeMessage(
            SRC_CHAIN, address(bridge.outbox), address(0xAAAA), 3, block.chainid, address(receiver), hex""
        );

        uint256[] memory pks = new uint256[](1);
        pks[0] = ATTESTOR_PK_1;
        bytes memory sigs = _signMessage(bridge.inbox, message, pks);

        vm.expectRevert(Inbox.BelowThreshold.selector);
        bridge.inbox.recvMessage(message, sigs);
    }

    // ─── Invalid signatures ──────────────────────────────────────────

    function test_InvalidSignerReverts() public {
        bytes memory message = _encodeMessage(
            SRC_CHAIN, address(bridge.outbox), address(0xAAAA), 4, block.chainid, address(receiver), hex""
        );

        // Use a non-attestor private key
        uint256 fakePk = 0xDEAD;
        uint256[] memory pks = new uint256[](2);
        pks[0] = ATTESTOR_PK_1;
        pks[1] = fakePk;
        bytes memory sigs = _signMessage(bridge.inbox, message, pks);

        vm.expectRevert(abi.encodeWithSelector(Inbox.SignerNotAttestor.selector, vm.addr(fakePk)));
        bridge.inbox.recvMessage(message, sigs);
    }

    // ─── Duplicate signer ────────────────────────────────────────────

    function test_DuplicateSignerReverts() public {
        bytes memory message = _encodeMessage(
            SRC_CHAIN, address(bridge.outbox), address(0xAAAA), 5, block.chainid, address(receiver), hex""
        );

        // Sign twice with the same key
        bytes32 digest = _inboxDigest(bridge.inbox, message);
        bytes memory sig = _sign(ATTESTOR_PK_1, digest);
        bytes memory sigs = abi.encodePacked(sig, sig);

        vm.expectRevert(Inbox.DuplicateSigner.selector);
        bridge.inbox.recvMessage(message, sigs);
    }

    // ─── Nonce replay ────────────────────────────────────────────────

    function test_NonceReplayReverts() public {
        uint256 srcSeq = 6;
        bytes memory message = _encodeMessage(
            SRC_CHAIN, address(bridge.outbox), address(0xAAAA), srcSeq, block.chainid, address(receiver), hex""
        );
        bytes32 expectedNonce = _deriveNonce(SRC_CHAIN, address(bridge.outbox), address(0xAAAA), srcSeq);

        uint256[] memory pks = new uint256[](2);
        pks[0] = ATTESTOR_PK_1;
        pks[1] = ATTESTOR_PK_2;
        bytes memory sigs = _signMessage(bridge.inbox, message, pks);

        // First delivery succeeds
        bridge.inbox.recvMessage(message, sigs);

        // Second delivery reverts on the derived nonce.
        vm.expectRevert(abi.encodeWithSelector(Inbox.NonceAlreadyUsed.selector, expectedNonce));
        bridge.inbox.recvMessage(message, sigs);
    }

    // ─── Destination chain mismatch ──────────────────────────────────

    function test_WrongDstChainReverts() public {
        uint256 wrongChain = block.chainid + 1;
        bytes memory message =
            _encodeMessage(SRC_CHAIN, address(bridge.outbox), address(0xAAAA), 7, wrongChain, address(receiver), hex"");

        uint256[] memory pks = new uint256[](2);
        pks[0] = ATTESTOR_PK_1;
        pks[1] = ATTESTOR_PK_2;
        bytes memory sigs = _signMessage(bridge.inbox, message, pks);

        vm.expectRevert(abi.encodeWithSelector(Inbox.WrongDestinationChain.selector, block.chainid, wrongChain));
        bridge.inbox.recvMessage(message, sigs);
    }

    // ─── Attestor management (owner-only) ────────────────────────────

    function test_OnlyOwnerCanAddAttestor() public {
        address nonOwner = address(0x9999);
        vm.prank(nonOwner);
        vm.expectRevert();
        bridge.inbox.addAttestor(address(0xBBBB));
    }

    function test_OnlyOwnerCanRemoveAttestor() public {
        address nonOwner = address(0x9999);
        vm.prank(nonOwner);
        vm.expectRevert();
        bridge.inbox.removeAttestor(attestor1);
    }

    function test_OnlyOwnerCanSetThreshold() public {
        address nonOwner = address(0x9999);
        vm.prank(nonOwner);
        vm.expectRevert();
        bridge.inbox.setThreshold(3);
    }

    function test_CannotAddDuplicateAttestor() public {
        vm.prank(ADMIN);
        vm.expectRevert(abi.encodeWithSelector(Inbox.AlreadyAttestor.selector, attestor1));
        bridge.inbox.addAttestor(attestor1);
    }

    function test_CannotRemoveNonAttestor() public {
        vm.prank(ADMIN);
        vm.expectRevert(abi.encodeWithSelector(Inbox.NotAttestor.selector, address(0x1111)));
        bridge.inbox.removeAttestor(address(0x1111));
    }

    // ─── Attestor enumeration ───────────────────────────────────────

    function test_GetAttestorsReturnsAllActive() public view {
        address[] memory attestors = bridge.inbox.getAttestors();
        assertEq(attestors.length, 3);

        // All three should be present (order not guaranteed)
        bool found1;
        bool found2;
        bool found3;
        for (uint256 i = 0; i < attestors.length; i++) {
            if (attestors[i] == attestor1) found1 = true;
            if (attestors[i] == attestor2) found2 = true;
            if (attestors[i] == attestor3) found3 = true;
        }
        assertTrue(found1, "attestor1 missing");
        assertTrue(found2, "attestor2 missing");
        assertTrue(found3, "attestor3 missing");
    }

    function test_GetAttestorCount() public view {
        assertEq(bridge.inbox.getAttestorCount(), 3);
    }

    function test_GetAttestorsAfterRemoval() public {
        vm.prank(ADMIN);
        bridge.inbox.removeAttestor(attestor2);

        address[] memory attestors = bridge.inbox.getAttestors();
        assertEq(attestors.length, 2);
        assertEq(bridge.inbox.getAttestorCount(), 2);

        for (uint256 i = 0; i < attestors.length; i++) {
            assertTrue(attestors[i] != attestor2, "removed attestor still present");
        }
    }

    // ─── Threshold / attestor-count invariant (S-4 / #24) ───────────

    function test_SetThresholdRejectsZero() public {
        vm.prank(ADMIN);
        vm.expectRevert(abi.encodeWithSelector(Inbox.InvalidThreshold.selector, 0, 3));
        bridge.inbox.setThreshold(0);
    }

    function test_SetThresholdRejectsValueAboveAttestorCount() public {
        // 3 attestors are configured in setUp; threshold 4 is unsatisfiable.
        vm.prank(ADMIN);
        vm.expectRevert(abi.encodeWithSelector(Inbox.InvalidThreshold.selector, 4, 3));
        bridge.inbox.setThreshold(4);
    }

    function test_SetThresholdAcceptsExactlyAttestorCount() public {
        // Boundary: threshold == attestorCount must succeed.
        vm.prank(ADMIN);
        bridge.inbox.setThreshold(3);
        assertEq(bridge.inbox.threshold(), 3);
    }

    function test_RemoveAttestorRejectedIfDropsBelowThreshold() public {
        // Raise threshold to the attestor count so any removal violates the invariant.
        vm.prank(ADMIN);
        bridge.inbox.setThreshold(3);

        vm.prank(ADMIN);
        vm.expectRevert(abi.encodeWithSelector(Inbox.InvalidThreshold.selector, 3, 2));
        bridge.inbox.removeAttestor(attestor2);

        // Set is unchanged.
        assertEq(bridge.inbox.getAttestorCount(), 3);
        assertTrue(bridge.inbox.isAttestor(attestor2));
    }

    function test_RemoveAttestorAcceptedAtThresholdBoundary() public {
        // Start: 3 attestors, threshold 2. Remove one: 2 attestors, still >= threshold.
        vm.prank(ADMIN);
        bridge.inbox.removeAttestor(attestor3);
        assertEq(bridge.inbox.getAttestorCount(), 2);

        // Removing another would drop below threshold and must revert.
        vm.prank(ADMIN);
        vm.expectRevert(abi.encodeWithSelector(Inbox.InvalidThreshold.selector, 2, 1));
        bridge.inbox.removeAttestor(attestor2);
    }

    // ─── Invalid signature length ────────────────────────────────────

    function test_InvalidSignatureLengthReverts() public {
        bytes memory message = _encodeMessage(
            SRC_CHAIN, address(bridge.outbox), address(0xAAAA), 8, block.chainid, address(receiver), hex""
        );

        // 64 bytes (not a multiple of 65)
        bytes memory badSigs = new bytes(64);

        vm.expectRevert(Inbox.InvalidSignatureCount.selector);
        bridge.inbox.recvMessage(message, badSigs);
    }

    /// @notice The message does not carry a transport nonce — the Inbox derives
    /// it from `(srcChain, srcOutbox, srcSender, srcSeq)`. Re-attesting the same
    /// source event under a different transport nonce is not possible; any valid
    /// attestation for the same source event produces the same key, and the Inbox
    /// refuses the replay.
    function test_NoncePoCBlockedByDerivedKey() public {
        // Without source-bound nonces, "one source burn, two valid attested messages
        // with different nonces, minting 2× amount on the destination" would be
        // exploitable. With the derived nonce there is no separate transport nonce
        // field: the attestors can only sign a
        // message whose derived nonce matches the source event's `srcSeq`. Re-
        // submitting the same (srcChain, srcOutbox, srcSender, srcSeq) tuple is
        // exactly a replay and gets rejected by `usedNonces`.
        bytes memory message = _encodeMessage(
            SRC_CHAIN, address(bridge.outbox), address(0xAAAA), 99, block.chainid, address(receiver), hex"FEED"
        );
        bytes32 expectedNonce = _deriveNonce(SRC_CHAIN, address(bridge.outbox), address(0xAAAA), 99);

        uint256[] memory pks = new uint256[](2);
        pks[0] = ATTESTOR_PK_1;
        pks[1] = ATTESTOR_PK_2;
        bytes memory sigs = _signMessage(bridge.inbox, message, pks);

        bridge.inbox.recvMessage(message, sigs);
        assertEq(receiver.callCount(), 1);

        // Replay with the same tuple ⇒ same derived nonce ⇒ rejected.
        vm.expectRevert(abi.encodeWithSelector(Inbox.NonceAlreadyUsed.selector, expectedNonce));
        bridge.inbox.recvMessage(message, sigs);
    }

    /// @notice An attestor quorum cannot bypass the source-event binding by claiming
    /// the message came from a stranger Outbox: `srcOutboxes[srcChain]` is the
    /// canonical Outbox, and the Inbox refuses anything else.
    function test_StrangerSrcOutboxRejected() public {
        address strangerOutbox = address(0xBEEF);
        bytes memory message =
            _encodeMessage(SRC_CHAIN, strangerOutbox, address(0xAAAA), 1, block.chainid, address(receiver), hex"");

        uint256[] memory pks = new uint256[](2);
        pks[0] = ATTESTOR_PK_1;
        pks[1] = ATTESTOR_PK_2;
        bytes memory sigs = _signMessage(bridge.inbox, message, pks);

        vm.expectRevert(
            abi.encodeWithSelector(Inbox.UnknownSrcOutbox.selector, SRC_CHAIN, strangerOutbox, address(bridge.outbox))
        );
        bridge.inbox.recvMessage(message, sigs);
    }

    /// @notice A message whose `srcChain` has no configured Outbox is rejected.
    function test_UnconfiguredSrcChainRejected() public {
        uint256 unconfiguredChain = 7777;
        bytes memory message = _encodeMessage(
            unconfiguredChain, address(bridge.outbox), address(0xAAAA), 1, block.chainid, address(receiver), hex""
        );

        uint256[] memory pks = new uint256[](2);
        pks[0] = ATTESTOR_PK_1;
        pks[1] = ATTESTOR_PK_2;
        bytes memory sigs = _signMessage(bridge.inbox, message, pks);

        vm.expectRevert(
            abi.encodeWithSelector(
                Inbox.UnknownSrcOutbox.selector, unconfiguredChain, address(bridge.outbox), address(0)
            )
        );
        bridge.inbox.recvMessage(message, sigs);
    }

    /// @notice `setSrcOutbox` refuses to overwrite a non-zero entry directly — the
    /// operator must explicitly clear first. Prevents the silent "swap Outbox while
    /// messages are in flight" footgun.
    function test_SetSrcOutboxRefusesSilentOverwrite() public {
        // SRC_CHAIN was already wired in setUp.
        address newOutbox = address(bridge.outbox); // shape-valid candidate
        vm.prank(ADMIN);
        vm.expectRevert(abi.encodeWithSelector(Inbox.SrcOutboxAlreadySet.selector, SRC_CHAIN, address(bridge.outbox)));
        bridge.inbox.setSrcOutbox(SRC_CHAIN, newOutbox);
    }

    /// @notice `setSrcOutbox(srcChain, address(0))` clears the route. Pause-and-drain
    /// is the operator-side prerequisite to swapping Outboxes.
    function test_SetSrcOutboxAllowsClear() public {
        vm.prank(ADMIN);
        bridge.inbox.setSrcOutbox(SRC_CHAIN, address(0));
        assertEq(bridge.inbox.srcOutboxes(SRC_CHAIN), address(0));

        // After clearing, the chain has no canonical Outbox and recvMessage rejects.
        bytes memory message = _encodeMessage(
            SRC_CHAIN, address(bridge.outbox), address(0xAAAA), 1, block.chainid, address(receiver), hex""
        );
        uint256[] memory pks = new uint256[](2);
        pks[0] = ATTESTOR_PK_1;
        pks[1] = ATTESTOR_PK_2;
        bytes memory sigs = _signMessage(bridge.inbox, message, pks);
        vm.expectRevert();
        bridge.inbox.recvMessage(message, sigs);
    }

    /// @notice `setSrcOutbox` validates candidates the same way `BridgeBurner.setOutbox` does:
    /// zero-check + bytecode check + ERC-165 advertisement.
    function test_SetSrcOutboxRejectsEoa() public {
        address eoa = address(0xCAFEBABE);
        vm.prank(ADMIN);
        // No previous entry → goes through validation; EOA has no code.
        bridge.inbox.setSrcOutbox(123, address(0)); // ensure clear
        vm.prank(ADMIN);
        vm.expectRevert(abi.encodeWithSelector(Inbox.InvalidOutbox.selector, eoa));
        bridge.inbox.setSrcOutbox(123, eoa);
    }

    function test_OnlyOwnerCanSetSrcOutbox() public {
        address nonOwner = address(0x9999);
        vm.prank(nonOwner);
        vm.expectRevert();
        bridge.inbox.setSrcOutbox(123, address(0xBEEF));
    }

    // ─── Selector collision safety ──────────

    /// @dev Verify that handleMessage's selector doesn't collide with any
    /// function on contracts the Inbox might be tricked into calling.
    ///
    /// Attack scenario: attacker sets dstRecipient to an unrelated contract
    /// (e.g. the Stablecoin). Inbox calls handleMessage(srcChain, srcSender,
    /// payload) on it. If the selector collides with e.g. mint(address,uint256),
    /// the target interprets the call as that function. The attacker controls
    /// srcChain, srcSender, and payload, so they can craft arguments to match
    /// the colliding function's ABI layout.
    ///
    /// Our bridge shouldn't be affected since the Inbox only has permission to
    /// call BridgeMinter.handleMessage, but this is a defense-in-depth check
    /// inspired by previous bridge exploits where selector collisions were used
    /// to invoke privileged functions through relay contracts.
    function test_NoHandleMessageSelectorCollision() public pure {
        bytes4 handleMessage = IMessageReceiver.handleMessage.selector;

        // ERC20 core
        bytes4[6] memory erc20 = [
            bytes4(keccak256("transfer(address,uint256)")),
            bytes4(keccak256("transferFrom(address,address,uint256)")),
            bytes4(keccak256("approve(address,uint256)")),
            bytes4(keccak256("mint(address,uint256)")),
            bytes4(keccak256("burn(uint256)")),
            bytes4(keccak256("burnFrom(address,uint256)"))
        ];

        // AccessControl + Ownable
        bytes4[5] memory access = [
            bytes4(keccak256("grantRole(bytes32,address)")),
            bytes4(keccak256("revokeRole(bytes32,address)")),
            bytes4(keccak256("renounceRole(bytes32,address)")),
            bytes4(keccak256("transferOwnership(address)")),
            bytes4(keccak256("renounceOwnership()"))
        ];

        // UUPS + Proxy
        bytes4[2] memory proxy =
            [bytes4(keccak256("upgradeToAndCall(address,bytes)")), bytes4(keccak256("proxiableUUID()"))];

        // Stablecoin-specific
        bytes4[6] memory stablecoin = [
            bytes4(keccak256("addMinter(address,uint256)")),
            bytes4(keccak256("removeMinter(address)")),
            bytes4(keccak256("modifyMinterAllowance(address,int256)")),
            bytes4(keccak256("freeze(address)")),
            bytes4(keccak256("unfreeze(address)")),
            bytes4(keccak256("pause()"))
        ];

        for (uint256 i = 0; i < erc20.length; i++) {
            assertTrue(handleMessage != erc20[i], "handleMessage collides with ERC20 selector");
        }
        for (uint256 i = 0; i < access.length; i++) {
            assertTrue(handleMessage != access[i], "handleMessage collides with access control selector");
        }
        for (uint256 i = 0; i < proxy.length; i++) {
            assertTrue(handleMessage != proxy[i], "handleMessage collides with proxy selector");
        }
        for (uint256 i = 0; i < stablecoin.length; i++) {
            assertTrue(handleMessage != stablecoin[i], "handleMessage collides with Stablecoin selector");
        }
    }
}
