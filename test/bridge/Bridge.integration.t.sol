// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.30;

import {Test} from "forge-std/Test.sol";
import {Stablecoin} from "../../src/Stablecoin.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Outbox} from "../../src/bridge/Outbox.sol";
import {Inbox} from "../../src/bridge/Inbox.sol";
import {BridgeBurner} from "../../src/bridge/BridgeBurner.sol";
import {BridgeMinter} from "../../src/bridge/BridgeMinter.sol";
import {BridgeDeploy} from "../../src/bridge/deploy/BridgeDeploy.sol";
import {BridgeConfig} from "../../src/bridge/deploy/BridgeConfig.sol";
import {TokenMintMessage} from "../../src/bridge/TokenMintMessage.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/// @title Bridge Integration Tests
/// @notice Three-chain setup (A=1, B=2, C=3) testing full burn-to-mint flows.
contract BridgeIntegrationTest is Test {
    bytes constant ARACHNID_CODE =
        hex"7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf3";

    address constant ADMIN = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
    address constant BURNER_ROLE_HOLDER = 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC;
    address constant PAUSER = 0x90F79bf6EB2c4f870365E785982E1f101E93b906;
    address constant FREEZER = 0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65;

    uint256 constant ATTESTOR_PK_1 = 0xA1;
    uint256 constant ATTESTOR_PK_2 = 0xA2;
    uint256 constant ATTESTOR_PK_3 = 0xA3;

    uint256 constant CHAIN_A = 1;
    uint256 constant CHAIN_B = 2;
    uint256 constant CHAIN_C = 3;

    uint256 constant INITIAL_SUPPLY = 100_000e6;
    uint256 constant MINTER_ALLOWANCE = 1_000_000e6;

    // Per-chain state
    struct ChainState {
        Stablecoin stablecoin;
        BridgeDeploy.Contracts bridge;
        uint256 chainId;
    }

    ChainState public chainA;
    ChainState public chainB;
    ChainState public chainC;

    address public attestor1;
    address public attestor2;
    address public attestor3;
    address public user;

    uint256 public nonceCounter;

    function setUp() public {
        attestor1 = vm.addr(ATTESTOR_PK_1);
        attestor2 = vm.addr(ATTESTOR_PK_2);
        attestor3 = vm.addr(ATTESTOR_PK_3);
        user = address(0xCAFE);

        vm.etch(BridgeDeploy.ARACHNID, ARACHNID_CODE);

        // Deploy three separate chain environments
        chainA = _deployChain(CHAIN_A, bytes32(uint256(10)));
        chainB = _deployChain(CHAIN_B, bytes32(uint256(20)));
        chainC = _deployChain(CHAIN_C, bytes32(uint256(30)));

        // Cross-configure: each chain's BridgeMinter allows the other two chains' BridgeBurners
        vm.startPrank(ADMIN);
        _crossConfigure(chainA, chainB);
        _crossConfigure(chainA, chainC);
        _crossConfigure(chainB, chainC);
        vm.stopPrank();

        // Mint initial supply to user on chain A
        vm.startPrank(ADMIN);
        chainA.stablecoin.addMinter(ADMIN, INITIAL_SUPPLY);
        vm.stopPrank();
        vm.prank(ADMIN);
        chainA.stablecoin.mint(user, INITIAL_SUPPLY);
    }

    // ─── 6.2: Happy path A→B ─────────────────────────────────────────

    function test_HappyPath_A_to_B() public {
        uint256 amount = 1000e6;
        address recipient = address(0xBEEF);

        // Step 1: Burn on chain A
        vm.prank(user);
        chainA.stablecoin.approve(address(chainA.bridge.bridgeBurner), amount);
        vm.prank(user);
        chainA.bridge.bridgeBurner.sendTo(CHAIN_B, recipient, amount);

        assertEq(chainA.stablecoin.balanceOf(user), INITIAL_SUPPLY - amount);

        // Step 2: Deliver on chain B (simulate server + attestation)
        _deliverMessage(
            chainA, chainB, address(chainA.bridge.bridgeBurner), address(chainB.bridge.bridgeMinter), recipient, amount
        );

        assertEq(chainB.stablecoin.balanceOf(recipient), amount);
    }

    // ─── 6.3: Cycle A→B→C→A ─────────────────────────────────────────

    function test_Cycle_A_B_C_A() public {
        uint256 amount = 500e6;
        address intermediary = address(0xDEAD);

        uint256 initialTotalSupply =
            chainA.stablecoin.totalSupply() + chainB.stablecoin.totalSupply() + chainC.stablecoin.totalSupply();

        // A→B
        vm.prank(user);
        chainA.stablecoin.approve(address(chainA.bridge.bridgeBurner), amount);
        vm.prank(user);
        chainA.bridge.bridgeBurner.sendTo(CHAIN_B, intermediary, amount);
        _deliverMessage(
            chainA,
            chainB,
            address(chainA.bridge.bridgeBurner),
            address(chainB.bridge.bridgeMinter),
            intermediary,
            amount
        );

        // B→C
        vm.prank(intermediary);
        chainB.stablecoin.approve(address(chainB.bridge.bridgeBurner), amount);
        vm.prank(intermediary);
        chainB.bridge.bridgeBurner.sendTo(CHAIN_C, intermediary, amount);
        _deliverMessage(
            chainB,
            chainC,
            address(chainB.bridge.bridgeBurner),
            address(chainC.bridge.bridgeMinter),
            intermediary,
            amount
        );

        // C→A
        vm.prank(intermediary);
        chainC.stablecoin.approve(address(chainC.bridge.bridgeBurner), amount);
        vm.prank(intermediary);
        chainC.bridge.bridgeBurner.sendTo(CHAIN_A, user, amount);
        _deliverMessage(
            chainC, chainA, address(chainC.bridge.bridgeBurner), address(chainA.bridge.bridgeMinter), user, amount
        );

        // Total supply conserved
        uint256 finalTotalSupply =
            chainA.stablecoin.totalSupply() + chainB.stablecoin.totalSupply() + chainC.stablecoin.totalSupply();
        assertEq(finalTotalSupply, initialTotalSupply);

        // User got tokens back on chain A
        assertEq(chainA.stablecoin.balanceOf(user), INITIAL_SUPPLY);
    }

    // ─── 6.4: Message reordering ────────────────────────────────────

    function test_MessageReordering() public {
        uint256 amount1 = 100e6;
        uint256 amount2 = 200e6;
        address recipient = address(0xBEEF);

        // Burn both messages on chain A
        vm.startPrank(user);
        chainA.stablecoin.approve(address(chainA.bridge.bridgeBurner), amount1 + amount2);
        chainA.bridge.bridgeBurner.sendTo(CHAIN_B, recipient, amount1);
        chainA.bridge.bridgeBurner.sendTo(CHAIN_B, recipient, amount2);
        vm.stopPrank();

        // Deliver msg2 first, then msg1 (different nonces, both succeed)
        bytes32 nonce1 = _nextNonce();
        bytes32 nonce2 = _nextNonce();

        _deliverMessageWithNonce(
            chainA,
            chainB,
            address(chainA.bridge.bridgeBurner),
            address(chainB.bridge.bridgeMinter),
            recipient,
            amount2,
            nonce2
        );
        _deliverMessageWithNonce(
            chainA,
            chainB,
            address(chainA.bridge.bridgeBurner),
            address(chainB.bridge.bridgeMinter),
            recipient,
            amount1,
            nonce1
        );

        assertEq(chainB.stablecoin.balanceOf(recipient), amount1 + amount2);
    }

    // ─── 6.5: Misrouted delivery ────────────────────────────────────

    function test_MisroutedDeliveryReverts() public {
        uint256 amount = 100e6;
        address recipient = address(0xBEEF);

        // Burn for chain B
        vm.prank(user);
        chainA.stablecoin.approve(address(chainA.bridge.bridgeBurner), amount);
        vm.prank(user);
        chainA.bridge.bridgeBurner.sendTo(CHAIN_B, recipient, amount);

        // Try to deliver on chain C (dstChain=B but delivering to C's inbox)
        bytes memory payload = TokenMintMessage.encode(recipient, amount);
        bytes32 nonce = _nextNonce();
        // Message specifies dstChain=CHAIN_B but we're delivering to chain C
        bytes memory message = abi.encode(
            CHAIN_A, address(chainA.bridge.bridgeBurner), CHAIN_B, address(chainC.bridge.bridgeMinter), nonce, payload
        );

        // Sign for chain C's inbox (but message says dstChain=B)
        bytes memory sigs = _signForInbox(chainC.bridge.inbox, message);

        // Chain C's inbox checks dstChain == block.chainid (which we set to CHAIN_C)
        // Since message has dstChain=CHAIN_B and we deliver to a VM with chainid=CHAIN_C... but
        // in a single Foundry VM block.chainid is the same for all. So we check the WrongDestinationChain
        // by constructing a message with wrong dstChain.
        vm.chainId(CHAIN_C);
        vm.expectRevert(abi.encodeWithSelector(Inbox.WrongDestinationChain.selector, CHAIN_C, CHAIN_B));
        chainC.bridge.inbox.recvMessage(message, sigs);
        vm.chainId(31337); // restore
    }

    // ─── 6.6: Replay ────────────────────────────────────────────────

    function test_ReplayReverts() public {
        uint256 amount = 100e6;
        address recipient = address(0xBEEF);

        vm.prank(user);
        chainA.stablecoin.approve(address(chainA.bridge.bridgeBurner), amount);
        vm.prank(user);
        chainA.bridge.bridgeBurner.sendTo(CHAIN_B, recipient, amount);

        // Deliver once
        bytes32 nonce = _nextNonce();
        bytes memory payload = TokenMintMessage.encode(recipient, amount);
        bytes memory message = abi.encode(
            CHAIN_A,
            address(chainA.bridge.bridgeBurner),
            block.chainid,
            address(chainB.bridge.bridgeMinter),
            nonce,
            payload
        );
        bytes memory sigs = _signForInbox(chainB.bridge.inbox, message);
        chainB.bridge.inbox.recvMessage(message, sigs);

        // Second delivery reverts
        vm.expectRevert(abi.encodeWithSelector(Inbox.NonceAlreadyUsed.selector, nonce));
        chainB.bridge.inbox.recvMessage(message, sigs);
    }

    // ─── 6.7: Disallowed sender ─────────────────────────────────────

    function test_DisallowedSenderReverts() public {
        address unknownSender = address(0x1111);
        address recipient = address(0xBEEF);
        uint256 amount = 100e6;
        bytes32 nonce = _nextNonce();

        bytes memory payload = TokenMintMessage.encode(recipient, amount);
        bytes memory message = abi.encode(
            CHAIN_A,
            unknownSender, // not chainA.bridge.bridgeBurner
            block.chainid,
            address(chainB.bridge.bridgeMinter),
            nonce,
            payload
        );
        bytes memory sigs = _signForInbox(chainB.bridge.inbox, message);

        vm.expectRevert(abi.encodeWithSelector(BridgeMinter.DisallowedSender.selector, CHAIN_A, unknownSender));
        chainB.bridge.inbox.recvMessage(message, sigs);
    }

    // ─── 6.8: Disallowed chain ──────────────────────────────────────

    function test_DisallowedChainReverts() public {
        uint256 unknownChain = 999;
        address recipient = address(0xBEEF);
        uint256 amount = 100e6;
        bytes32 nonce = _nextNonce();

        bytes memory payload = TokenMintMessage.encode(recipient, amount);
        bytes memory message = abi.encode(
            unknownChain,
            address(chainA.bridge.bridgeBurner), // valid sender address but wrong chain
            block.chainid,
            address(chainB.bridge.bridgeMinter),
            nonce,
            payload
        );
        bytes memory sigs = _signForInbox(chainB.bridge.inbox, message);

        vm.expectRevert(
            abi.encodeWithSelector(
                BridgeMinter.DisallowedSender.selector, unknownChain, address(chainA.bridge.bridgeBurner)
            )
        );
        chainB.bridge.inbox.recvMessage(message, sigs);
    }

    // ─── Helpers ─────────────────────────────────────────────────────

    function _deployChain(uint256 chainId, bytes32 salt) internal returns (ChainState memory state) {
        state.chainId = chainId;

        vm.startPrank(ADMIN);

        // Deploy stablecoin
        Stablecoin impl = new Stablecoin();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeCall(Stablecoin.initialize, ("Stablecoin", "STBL", 6, ADMIN, BURNER_ROLE_HOLDER, PAUSER, FREEZER))
        );
        state.stablecoin = Stablecoin(address(proxy));

        // Deploy bridge
        state.bridge = BridgeDeploy.deployAll(salt, ADMIN, address(state.stablecoin));

        // Configure: roles, attestors
        state.stablecoin.grantRole(state.stablecoin.BURNER_ROLE(), address(state.bridge.bridgeBurner));
        state.stablecoin.addMinter(address(state.bridge.bridgeMinter), MINTER_ALLOWANCE);
        state.bridge.inbox.addAttestor(attestor1);
        state.bridge.inbox.addAttestor(attestor2);
        state.bridge.inbox.addAttestor(attestor3);
        state.bridge.inbox.setThreshold(2);

        vm.stopPrank();
    }

    /// @dev Cross-configure two chains so each allows the other's BridgeBurner as a sender.
    function _crossConfigure(ChainState memory a, ChainState memory b) internal {
        // a's minter accepts messages from b's burner
        a.bridge.bridgeMinter.setAllowedSender(b.chainId, address(b.bridge.bridgeBurner));
        a.bridge.bridgeBurner.setDstMinter(b.chainId, address(b.bridge.bridgeMinter));

        // b's minter accepts messages from a's burner
        b.bridge.bridgeMinter.setAllowedSender(a.chainId, address(a.bridge.bridgeBurner));
        b.bridge.bridgeBurner.setDstMinter(a.chainId, address(a.bridge.bridgeMinter));
    }

    function _nextNonce() internal returns (bytes32) {
        return bytes32(++nonceCounter);
    }

    /// @dev Simulate the full server flow: construct message, sign, deliver.
    function _deliverMessage(
        ChainState memory src,
        ChainState memory dst,
        address srcSender,
        address dstRecipient,
        address recipient,
        uint256 amount
    ) internal {
        _deliverMessageWithNonce(src, dst, srcSender, dstRecipient, recipient, amount, _nextNonce());
    }

    function _deliverMessageWithNonce(
        ChainState memory src,
        ChainState memory dst,
        address srcSender,
        address dstRecipient,
        address recipient,
        uint256 amount,
        bytes32 nonce
    ) internal {
        bytes memory payload = TokenMintMessage.encode(recipient, amount);
        bytes memory message = abi.encode(src.chainId, srcSender, block.chainid, dstRecipient, nonce, payload);
        bytes memory sigs = _signForInbox(dst.bridge.inbox, message);
        dst.bridge.inbox.recvMessage(message, sigs);
    }

    function _signForInbox(Inbox inbox, bytes memory message) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(message);
        bytes32 digest = MessageHashUtils.toTypedDataHash(inbox.domainSeparator(), structHash);

        // Sort keys by address ascending
        uint256[3] memory pks = [ATTESTOR_PK_1, ATTESTOR_PK_2, ATTESTOR_PK_3];
        for (uint256 i = 0; i < 3; i++) {
            for (uint256 j = i + 1; j < 3; j++) {
                if (vm.addr(pks[i]) > vm.addr(pks[j])) {
                    (pks[i], pks[j]) = (pks[j], pks[i]);
                }
            }
        }

        // Sign with first 2 (threshold=2)
        bytes memory sigs;
        for (uint256 i = 0; i < 2; i++) {
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(pks[i], digest);
            sigs = abi.encodePacked(sigs, r, s, v);
        }
        return sigs;
    }
}
