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

    function setUp() public override {
        super.setUp();
        receiver = new MockReceiver();

        // Configure inbox with attestors and threshold=2
        vm.startPrank(ADMIN);
        bridge.inbox.addAttestor(attestor1);
        bridge.inbox.addAttestor(attestor2);
        bridge.inbox.addAttestor(attestor3);
        bridge.inbox.setThreshold(2);
        vm.stopPrank();
    }

    // ─── Valid k-of-n signatures ─────────────────────────────────────

    function test_ValidKOfNSignatures() public {
        bytes memory payload = hex"CAFE";
        bytes32 nonce = bytes32(uint256(1));
        bytes memory message = _encodeMessage(42, address(0xAAAA), block.chainid, address(receiver), nonce, payload);

        uint256[] memory pks = new uint256[](2);
        pks[0] = ATTESTOR_PK_1;
        pks[1] = ATTESTOR_PK_2;
        bytes memory sigs = _signMessage(bridge.inbox, message, pks);

        bridge.inbox.recvMessage(message, sigs);

        assertEq(receiver.callCount(), 1);
        assertEq(receiver.lastSrcChain(), 42);
        assertEq(receiver.lastSrcSender(), address(0xAAAA));
        assertEq(receiver.lastPayload(), payload);
    }

    function test_AllThreeSignatures() public {
        bytes32 nonce = bytes32(uint256(2));
        bytes memory message = _encodeMessage(42, address(0xAAAA), block.chainid, address(receiver), nonce, hex"");

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
        bytes32 nonce = bytes32(uint256(3));
        bytes memory message = _encodeMessage(42, address(0xAAAA), block.chainid, address(receiver), nonce, hex"");

        uint256[] memory pks = new uint256[](1);
        pks[0] = ATTESTOR_PK_1;
        bytes memory sigs = _signMessage(bridge.inbox, message, pks);

        vm.expectRevert(Inbox.BelowThreshold.selector);
        bridge.inbox.recvMessage(message, sigs);
    }

    // ─── Invalid signatures ──────────────────────────────────────────

    function test_InvalidSignerReverts() public {
        bytes32 nonce = bytes32(uint256(4));
        bytes memory message = _encodeMessage(42, address(0xAAAA), block.chainid, address(receiver), nonce, hex"");

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
        bytes32 nonce = bytes32(uint256(5));
        bytes memory message = _encodeMessage(42, address(0xAAAA), block.chainid, address(receiver), nonce, hex"");

        // Sign twice with the same key
        bytes32 digest = _inboxDigest(bridge.inbox, message);
        bytes memory sig = _sign(ATTESTOR_PK_1, digest);
        bytes memory sigs = abi.encodePacked(sig, sig);

        vm.expectRevert(Inbox.DuplicateSigner.selector);
        bridge.inbox.recvMessage(message, sigs);
    }

    // ─── Nonce replay ────────────────────────────────────────────────

    function test_NonceReplayReverts() public {
        bytes32 nonce = bytes32(uint256(6));
        bytes memory message = _encodeMessage(42, address(0xAAAA), block.chainid, address(receiver), nonce, hex"");

        uint256[] memory pks = new uint256[](2);
        pks[0] = ATTESTOR_PK_1;
        pks[1] = ATTESTOR_PK_2;
        bytes memory sigs = _signMessage(bridge.inbox, message, pks);

        // First delivery succeeds
        bridge.inbox.recvMessage(message, sigs);

        // Second delivery reverts
        vm.expectRevert(abi.encodeWithSelector(Inbox.NonceAlreadyUsed.selector, nonce));
        bridge.inbox.recvMessage(message, sigs);
    }

    // ─── Destination chain mismatch ──────────────────────────────────

    function test_WrongDstChainReverts() public {
        uint256 wrongChain = block.chainid + 1;
        bytes32 nonce = bytes32(uint256(7));
        bytes memory message = _encodeMessage(42, address(0xAAAA), wrongChain, address(receiver), nonce, hex"");

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
        bytes32 nonce = bytes32(uint256(8));
        bytes memory message = _encodeMessage(42, address(0xAAAA), block.chainid, address(receiver), nonce, hex"");

        // 64 bytes (not a multiple of 65)
        bytes memory badSigs = new bytes(64);

        vm.expectRevert(Inbox.InvalidSignatureCount.selector);
        bridge.inbox.recvMessage(message, badSigs);
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
