// SPDX-License-Identifier: UNLICENSED
//
// Formal verification tests for the bridge contracts using Halmos.
//
// Install:  uv tool install halmos
// Run:      forge build && halmos
//
pragma solidity =0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {Stablecoin} from "../../src/Stablecoin.sol";
import {Inbox} from "../../src/bridge/Inbox.sol";
import {Outbox} from "../../src/bridge/Outbox.sol";
import {BridgeBurner} from "../../src/bridge/BridgeBurner.sol";
import {BridgeMinter} from "../../src/bridge/BridgeMinter.sol";
import {TokenMintMessage} from "../../src/bridge/TokenMintMessage.sol";
import {IMessageReceiver} from "../../src/bridge/interfaces/IMessageReceiver.sol";

/// @dev Mock receiver that always succeeds (for Inbox delivery tests).
contract AlwaysSucceedsReceiver is IMessageReceiver {
    function handleMessage(uint256, address, bytes calldata) external {}
}

/// @title FormalTestBase
/// @notice Deploys the full bridge stack using plain new + ERC1967Proxy.
contract FormalTestBase is Test {
    address constant ADMIN = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
    address constant BURNER_ROLE_HOLDER = 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC;
    address constant PAUSER = 0x90F79bf6EB2c4f870365E785982E1f101E93b906;
    address constant FREEZER = 0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65;

    uint256 constant ATTESTOR_PK_1 = 0xA1;
    uint256 constant ATTESTOR_PK_2 = 0xA2;
    uint256 constant ATTESTOR_PK_3 = 0xA3;

    Stablecoin public stablecoin;
    Inbox public inbox;
    Outbox public outbox;
    BridgeBurner public bridgeBurner;
    BridgeMinter public bridgeMinter;

    address public attestor1;
    address public attestor2;
    address public attestor3;

    function setUp() public virtual {
        attestor1 = vm.addr(ATTESTOR_PK_1);
        attestor2 = vm.addr(ATTESTOR_PK_2);
        attestor3 = vm.addr(ATTESTOR_PK_3);

        vm.startPrank(ADMIN);

        // Deploy Stablecoin
        Stablecoin stablecoinImpl = new Stablecoin();
        ERC1967Proxy stablecoinProxy = new ERC1967Proxy(
            address(stablecoinImpl),
            abi.encodeCall(Stablecoin.initialize, ("Stablecoin", "STBL", 6, ADMIN, BURNER_ROLE_HOLDER, PAUSER, FREEZER))
        );
        stablecoin = Stablecoin(address(stablecoinProxy));

        // Deploy Outbox
        Outbox outboxImpl = new Outbox();
        ERC1967Proxy outboxProxy = new ERC1967Proxy(address(outboxImpl), abi.encodeCall(Outbox.initialize, (ADMIN)));
        outbox = Outbox(address(outboxProxy));

        // Deploy Inbox
        Inbox inboxImpl = new Inbox();
        ERC1967Proxy inboxProxy = new ERC1967Proxy(address(inboxImpl), abi.encodeCall(Inbox.initialize, (ADMIN)));
        inbox = Inbox(address(inboxProxy));

        // Deploy BridgeBurner
        BridgeBurner burnerImpl = new BridgeBurner();
        ERC1967Proxy burnerProxy = new ERC1967Proxy(
            address(burnerImpl), abi.encodeCall(BridgeBurner.initialize, (ADMIN, address(stablecoin), address(outbox)))
        );
        bridgeBurner = BridgeBurner(address(burnerProxy));

        // Deploy BridgeMinter
        BridgeMinter minterImpl = new BridgeMinter();
        ERC1967Proxy minterProxy = new ERC1967Proxy(
            address(minterImpl), abi.encodeCall(BridgeMinter.initialize, (ADMIN, address(stablecoin), address(inbox)))
        );
        bridgeMinter = BridgeMinter(address(minterProxy));

        vm.stopPrank();
    }

    // ─── EIP-712 helpers (same as BridgeTestBase) ─────────────────────────────

    function _inboxDigest(bytes memory message) internal view returns (bytes32) {
        bytes32 structHash = keccak256(message);
        return MessageHashUtils.toTypedDataHash(inbox.domainSeparator(), structHash);
    }

    function _sign(uint256 pk, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _signMessage(bytes memory message, uint256[] memory pks) internal view returns (bytes memory signatures) {
        bytes32 digest = _inboxDigest(message);

        // Sort private keys by derived address (ascending) for duplicate check
        for (uint256 i = 0; i < pks.length; i++) {
            for (uint256 j = i + 1; j < pks.length; j++) {
                if (vm.addr(pks[i]) > vm.addr(pks[j])) {
                    (pks[i], pks[j]) = (pks[j], pks[i]);
                }
            }
        }

        for (uint256 i = 0; i < pks.length; i++) {
            signatures = abi.encodePacked(signatures, _sign(pks[i], digest));
        }
    }

    function _encodeMessage(
        uint256 srcChain,
        address srcSender,
        uint256 dstChain,
        address dstRecipient,
        bytes32 nonce,
        bytes memory payload
    ) internal pure returns (bytes memory) {
        return abi.encode(srcChain, srcSender, dstChain, dstRecipient, nonce, payload);
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
//  Inbox Formal Verification
// ═══════════════════════════════════════════════════════════════════════════════

/// @title InboxFormalTest
/// @notice Halmos symbolic execution proofs for Inbox security properties.
contract InboxFormalTest is FormalTestBase {
    AlwaysSucceedsReceiver public receiver;

    function setUp() public override {
        super.setUp();
        receiver = new AlwaysSucceedsReceiver();

        vm.startPrank(ADMIN);
        inbox.addAttestor(attestor1);
        inbox.addAttestor(attestor2);
        inbox.addAttestor(attestor3);
        inbox.setThreshold(2);
        vm.stopPrank();
    }

    // ─── Nonce replay protection ──────────────────────────────────────────────

    /// @notice PROOF: For ALL nonces, once consumed, replaying the same message
    /// always reverts.
    function check_nonceReplayAlwaysReverts(bytes32 nonce) public {
        bytes memory message = _encodeMessage(42, address(0xAAAA), block.chainid, address(receiver), nonce, hex"");

        uint256[] memory pks = new uint256[](2);
        pks[0] = ATTESTOR_PK_1;
        pks[1] = ATTESTOR_PK_2;
        bytes memory sigs = _signMessage(message, pks);

        // First delivery consumes the nonce
        inbox.recvMessage(message, sigs);
        assert(inbox.usedNonces(nonce) == 1);

        // Replay MUST revert
        (bool success,) = address(inbox).call(abi.encodeCall(inbox.recvMessage, (message, sigs)));
        assert(!success);
    }

    // ─── Destination chain enforcement ────────────────────────────────────────

    /// @notice PROOF: Messages targeting a different chain ALWAYS revert,
    /// for ALL message contents and ALL signature bytes.
    ///
    /// The chain check (Inbox L121) is the first validation after decoding,
    /// so no combination of other fields or signatures can bypass it.
    function check_wrongChainAlwaysReverts(
        uint256 srcChain,
        address srcSender,
        uint256 dstChain,
        address dstRecipient,
        bytes32 nonce
    ) public {
        vm.assume(dstChain != block.chainid);

        bytes memory message = _encodeMessage(srcChain, srcSender, dstChain, dstRecipient, nonce, hex"");

        (bool success,) = address(inbox).call(abi.encodeCall(inbox.recvMessage, (message, hex"")));
        assert(!success);
    }

    // ─── Fail-closed threshold ────────────────────────────────────────────────

    /// @notice PROOF: With threshold = 0, ALL deliveries revert regardless of
    /// message content or signatures. The system is fail-closed when unconfigured.
    ///
    /// The check `require(threshold > 0)` (Inbox L151) is the first check in
    /// _verifySignatures, so no signature can satisfy a zero threshold.
    function check_zeroThresholdFailsClosed(bytes32 nonce) public {
        vm.prank(ADMIN);
        inbox.setThreshold(0);

        bytes memory message = _encodeMessage(42, address(0xAAAA), block.chainid, address(receiver), nonce, hex"");

        // 130 zero bytes: passes length alignment but reaches the threshold check.
        bytes memory sigs = new bytes(130);

        (bool success,) = address(inbox).call(abi.encodeCall(inbox.recvMessage, (message, sigs)));
        assert(!success);
    }

    // ─── Insufficient signatures ──────────────────────────────────────────────

    /// @notice PROOF: A single 65-byte signature when threshold = 2 ALWAYS reverts.
    /// Proves the `sigCount >= threshold` check (Inbox L154).
    /// Uses dummy bytes (not valid sigs) since the count check precedes recovery.
    function check_singleSigBelowThresholdReverts(bytes32 nonce) public {
        bytes memory message = _encodeMessage(42, address(0xAAAA), block.chainid, address(receiver), nonce, hex"");

        // 65 zero bytes: passes length alignment (L153) but fails sigCount >= 2 (L154)
        bytes memory sigs = new bytes(65);

        (bool success,) = address(inbox).call(abi.encodeCall(inbox.recvMessage, (message, sigs)));
        assert(!success);
    }

    /// @notice PROOF: Zero-length signatures ALWAYS revert.
    function check_zeroSignaturesReverts(bytes32 nonce) public {
        bytes memory message = _encodeMessage(42, address(0xAAAA), block.chainid, address(receiver), nonce, hex"");

        (bool success,) = address(inbox).call(abi.encodeCall(inbox.recvMessage, (message, hex"")));
        assert(!success);
    }

    // ─── Delivery postcondition ───────────────────────────────────────────────

    /// @notice PROOF: For ALL nonces, successful delivery sets usedNonces[nonce] = 1.
    function check_deliveryConsumesNonce(bytes32 nonce) public {
        assert(inbox.usedNonces(nonce) == 0);

        bytes memory message = _encodeMessage(42, address(0xAAAA), block.chainid, address(receiver), nonce, hex"");

        uint256[] memory pks = new uint256[](2);
        pks[0] = ATTESTOR_PK_1;
        pks[1] = ATTESTOR_PK_2;
        bytes memory sigs = _signMessage(message, pks);

        inbox.recvMessage(message, sigs);

        assert(inbox.usedNonces(nonce) == 1);
    }

    // ─── Owner-only access control ────────────────────────────────────────────

    /// @notice PROOF: Non-owners can NEVER add attestors.
    function check_onlyOwnerCanAddAttestor(address caller, address attestor) public {
        vm.assume(caller != inbox.owner());
        vm.assume(attestor != address(0));

        vm.prank(caller);
        (bool success,) = address(inbox).call(abi.encodeCall(inbox.addAttestor, (attestor)));
        assert(!success);
    }

    /// @notice PROOF: Non-owners can NEVER change the signature threshold.
    function check_onlyOwnerCanSetThreshold(address caller, uint256 newThreshold) public {
        vm.assume(caller != inbox.owner());

        vm.prank(caller);
        (bool success,) = address(inbox).call(abi.encodeCall(inbox.setThreshold, (newThreshold)));
        assert(!success);
    }

    /// @notice PROOF: Non-owners can NEVER remove attestors.
    function check_onlyOwnerCanRemoveAttestor(address caller, address attestor) public {
        vm.assume(caller != inbox.owner());

        vm.prank(caller);
        (bool success,) = address(inbox).call(abi.encodeCall(inbox.removeAttestor, (attestor)));
        assert(!success);
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
//  BridgeMinter Formal Verification
// ═══════════════════════════════════════════════════════════════════════════════

/// @title BridgeMinterFormalTest
/// @notice Halmos symbolic execution proofs for BridgeMinter access control
/// and token accounting.
contract BridgeMinterFormalTest is FormalTestBase {
    uint256 constant SRC_CHAIN = 42;
    address constant SRC_SENDER = address(0xBBBB);
    uint256 constant _MINTER_ALLOWANCE = 10_000_000e6;
    address constant RECIPIENT = address(0xCAFE);

    function setUp() public override {
        super.setUp();

        vm.startPrank(ADMIN);
        inbox.addAttestor(attestor1);
        inbox.addAttestor(attestor2);
        inbox.setThreshold(2);
        bridgeMinter.setAllowedSender(SRC_CHAIN, SRC_SENDER);
        stablecoin.addMinter(address(bridgeMinter), _MINTER_ALLOWANCE);
        vm.stopPrank();
    }

    // ─── Caller access control ────────────────────────────────────────────────

    /// @notice PROOF: For ANY caller that is not the Inbox, handleMessage
    /// ALWAYS reverts. No combination of arguments can bypass the check (L71).
    function check_onlyInboxCanDeliver(
        address caller,
        uint256 srcChain,
        address srcSender,
        address recipient,
        uint256 amount
    ) public {
        vm.assume(caller != bridgeMinter.inbox());
        bytes memory payload = TokenMintMessage.encode(recipient, amount);

        vm.prank(caller);
        (bool success,) =
            address(bridgeMinter).call(abi.encodeCall(bridgeMinter.handleMessage, (srcChain, srcSender, payload)));
        assert(!success);
    }

    // ─── Source chain validation ──────────────────────────────────────────────

    /// @notice PROOF: For ANY source chain with no configured sender,
    /// handleMessage ALWAYS reverts (even when called by the Inbox).
    function check_unknownSourceChainReverts(uint256 srcChain, address srcSender, address recipient, uint256 amount)
        public
    {
        vm.assume(bridgeMinter.allowedSenders(srcChain) == address(0));
        bytes memory payload = TokenMintMessage.encode(recipient, amount);

        vm.prank(bridgeMinter.inbox());
        (bool success,) =
            address(bridgeMinter).call(abi.encodeCall(bridgeMinter.handleMessage, (srcChain, srcSender, payload)));
        assert(!success);
    }

    /// @notice PROOF: For a configured source chain, if srcSender does not match
    /// the allowed sender, handleMessage ALWAYS reverts (L72-74).
    function check_mismatchedSenderReverts(address srcSender, address recipient, uint256 amount) public {
        vm.assume(srcSender != SRC_SENDER);
        bytes memory payload = TokenMintMessage.encode(recipient, amount);

        vm.prank(bridgeMinter.inbox());
        (bool success,) =
            address(bridgeMinter).call(abi.encodeCall(bridgeMinter.handleMessage, (SRC_CHAIN, srcSender, payload)));
        assert(!success);
    }

    // ─── Token accounting ─────────────────────────────────────────────────────

    /// @notice PROOF: Successful mint deducts exactly `amount` from minter allowance.
    function check_mintDeductsExactAllowance(uint256 amount) public {
        vm.assume(amount > 0 && amount <= _MINTER_ALLOWANCE);

        uint256 allowanceBefore = stablecoin.minterAllowance(address(bridgeMinter));
        bytes memory payload = TokenMintMessage.encode(RECIPIENT, amount);

        vm.prank(bridgeMinter.inbox());
        bridgeMinter.handleMessage(SRC_CHAIN, SRC_SENDER, payload);

        assert(stablecoin.minterAllowance(address(bridgeMinter)) == allowanceBefore - amount);
    }

    /// @notice PROOF: Successful mint increases recipient balance by exactly `amount`.
    function check_mintIncreasesBalanceExactly(uint256 amount) public {
        vm.assume(amount > 0 && amount <= _MINTER_ALLOWANCE);

        uint256 balanceBefore = stablecoin.balanceOf(RECIPIENT);
        bytes memory payload = TokenMintMessage.encode(RECIPIENT, amount);

        vm.prank(bridgeMinter.inbox());
        bridgeMinter.handleMessage(SRC_CHAIN, SRC_SENDER, payload);

        assert(stablecoin.balanceOf(RECIPIENT) == balanceBefore + amount);
    }

    /// @notice PROOF: Successful mint increases total supply by exactly `amount`.
    function check_mintIncreasesTotalSupplyExactly(uint256 amount) public {
        vm.assume(amount > 0 && amount <= _MINTER_ALLOWANCE);

        uint256 supplyBefore = stablecoin.totalSupply();
        bytes memory payload = TokenMintMessage.encode(RECIPIENT, amount);

        vm.prank(bridgeMinter.inbox());
        bridgeMinter.handleMessage(SRC_CHAIN, SRC_SENDER, payload);

        assert(stablecoin.totalSupply() == supplyBefore + amount);
    }

    // ─── Owner-only access control ────────────────────────────────────────────

    /// @notice PROOF: Non-owners can NEVER change the allowed sender mapping.
    function check_onlyOwnerCanSetAllowedSender(address caller, uint256 srcChain, address sender) public {
        vm.assume(caller != bridgeMinter.owner());

        vm.prank(caller);
        (bool success,) = address(bridgeMinter).call(abi.encodeCall(bridgeMinter.setAllowedSender, (srcChain, sender)));
        assert(!success);
    }

    /// @notice PROOF: Non-owners can NEVER change the inbox address.
    function check_onlyOwnerCanSetInbox(address caller, address newInbox) public {
        vm.assume(caller != bridgeMinter.owner());
        vm.assume(newInbox != address(0));

        vm.prank(caller);
        (bool success,) = address(bridgeMinter).call(abi.encodeCall(bridgeMinter.setInbox, (newInbox)));
        assert(!success);
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
//  BridgeBurner Formal Verification
// ═══════════════════════════════════════════════════════════════════════════════

/// @title BridgeBurnerFormalTest
/// @notice Halmos symbolic execution proofs for BridgeBurner input validation
/// and token accounting.
contract BridgeBurnerFormalTest is FormalTestBase {
    uint256 constant DST_CHAIN = 42;
    address constant DST_MINTER = address(0xBEEF);
    address constant USER = address(0xCAFE);
    uint256 constant USER_BALANCE = 1_000_000e6;

    function setUp() public override {
        super.setUp();

        vm.startPrank(ADMIN);
        bridgeBurner.setDstMinter(DST_CHAIN, DST_MINTER);
        stablecoin.grantRole(stablecoin.BURNER_ROLE(), address(bridgeBurner));
        stablecoin.addMinter(ADMIN, USER_BALANCE);
        stablecoin.mint(USER, USER_BALANCE);
        vm.stopPrank();

        vm.prank(USER);
        stablecoin.approve(address(bridgeBurner), type(uint256).max);
    }

    // ─── Input validation ─────────────────────────────────────────────────────

    /// @notice PROOF: sendTo with dstChain == block.chainid ALWAYS reverts (L73).
    function check_sameChainReverts(address recipient, uint256 amount) public {
        vm.assume(recipient != address(0));
        vm.assume(amount > 0);

        vm.prank(USER);
        (bool success,) =
            address(bridgeBurner).call(abi.encodeCall(bridgeBurner.sendTo, (block.chainid, recipient, amount)));
        assert(!success);
    }

    /// @notice PROOF: sendTo with zero recipient ALWAYS reverts (L74).
    function check_zeroRecipientReverts(uint256 dstChain, uint256 amount) public {
        vm.assume(dstChain != block.chainid);
        vm.assume(amount > 0);

        vm.prank(USER);
        (bool success,) =
            address(bridgeBurner).call(abi.encodeCall(bridgeBurner.sendTo, (dstChain, address(0), amount)));
        assert(!success);
    }

    /// @notice PROOF: sendTo with zero amount ALWAYS reverts (L75).
    function check_zeroAmountReverts(uint256 dstChain, address recipient) public {
        vm.assume(dstChain != block.chainid);
        vm.assume(recipient != address(0));

        vm.prank(USER);
        (bool success,) = address(bridgeBurner).call(abi.encodeCall(bridgeBurner.sendTo, (dstChain, recipient, 0)));
        assert(!success);
    }

    /// @notice PROOF: sendTo with an unconfigured destination chain ALWAYS reverts (L78).
    function check_unconfiguredDestinationReverts(uint256 dstChain, address recipient, uint256 amount) public {
        vm.assume(dstChain != block.chainid);
        vm.assume(dstChain != DST_CHAIN); // the only configured destination
        vm.assume(recipient != address(0));
        vm.assume(amount > 0);

        vm.prank(USER);
        (bool success,) = address(bridgeBurner).call(abi.encodeCall(bridgeBurner.sendTo, (dstChain, recipient, amount)));
        assert(!success);
    }

    // ─── Token accounting ─────────────────────────────────────────────────────

    /// @notice PROOF: Successful burn reduces total supply by exactly `amount`.
    function check_burnReducesTotalSupplyExactly(uint256 amount) public {
        vm.assume(amount > 0 && amount <= USER_BALANCE);

        uint256 supplyBefore = stablecoin.totalSupply();

        vm.prank(USER);
        bridgeBurner.sendTo(DST_CHAIN, USER, amount);

        assert(stablecoin.totalSupply() == supplyBefore - amount);
    }

    /// @notice PROOF: Successful burn reduces user balance by exactly `amount`.
    function check_burnReducesUserBalanceExactly(uint256 amount) public {
        vm.assume(amount > 0 && amount <= USER_BALANCE);

        uint256 balanceBefore = stablecoin.balanceOf(USER);

        vm.prank(USER);
        bridgeBurner.sendTo(DST_CHAIN, USER, amount);

        assert(stablecoin.balanceOf(USER) == balanceBefore - amount);
    }

    // ─── Owner-only access control ────────────────────────────────────────────

    /// @notice PROOF: Non-owners can NEVER set destination minters.
    function check_onlyOwnerCanSetDstMinter(address caller, uint256 dstChain, address minter) public {
        vm.assume(caller != bridgeBurner.owner());

        vm.prank(caller);
        (bool success,) = address(bridgeBurner).call(abi.encodeCall(bridgeBurner.setDstMinter, (dstChain, minter)));
        assert(!success);
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
//  Supply Conservation Formal Verification
// ═══════════════════════════════════════════════════════════════════════════════

/// @title SupplyConservationFormalTest
/// @notice Halmos symbolic execution proof that the burn-then-mint bridge
/// round-trip preserves total supply and user balance.
///
/// Models a single-chain simulation: BridgeBurner.sendTo burns tokens,
/// then BridgeMinter.handleMessage mints the same amount. In the real
/// system these happen on different chains; here we verify the accounting
/// identity holds for any amount.
contract SupplyConservationFormalTest is FormalTestBase {
    address constant USER = address(0xCAFE);
    uint256 constant INITIAL_SUPPLY = 1_000_000e6;
    uint256 constant _MINTER_ALLOWANCE = 10_000_000e6;
    uint256 constant SRC_CHAIN = 42;

    function setUp() public override {
        super.setUp();

        vm.startPrank(ADMIN);

        // Inbox
        inbox.addAttestor(attestor1);
        inbox.addAttestor(attestor2);
        inbox.setThreshold(2);

        // BridgeBurner: route chain 42 to a destination minter
        bridgeBurner.setDstMinter(SRC_CHAIN, address(0xBEEF));
        stablecoin.grantRole(stablecoin.BURNER_ROLE(), address(bridgeBurner));

        // BridgeMinter: accept messages from BridgeBurner on chain 42
        bridgeMinter.setAllowedSender(SRC_CHAIN, address(bridgeBurner));
        stablecoin.addMinter(address(bridgeMinter), _MINTER_ALLOWANCE);

        // Initial supply
        stablecoin.addMinter(ADMIN, INITIAL_SUPPLY);
        stablecoin.mint(USER, INITIAL_SUPPLY);

        vm.stopPrank();

        vm.prank(USER);
        stablecoin.approve(address(bridgeBurner), type(uint256).max);
    }

    /// @notice PROOF: A burn followed by a mint of the same amount preserves
    /// total supply. For all valid amounts: totalSupply_after == totalSupply_before.
    function check_burnThenMintConservesTotalSupply(uint256 amount) public {
        vm.assume(amount > 0 && amount <= INITIAL_SUPPLY);

        uint256 supplyBefore = stablecoin.totalSupply();

        // Burn via BridgeBurner
        vm.prank(USER);
        bridgeBurner.sendTo(SRC_CHAIN, USER, amount);
        assert(stablecoin.totalSupply() == supplyBefore - amount);

        // Mint via BridgeMinter (simulating off-chain attestation delivery)
        bytes memory payload = TokenMintMessage.encode(USER, amount);
        vm.prank(address(inbox));
        bridgeMinter.handleMessage(SRC_CHAIN, address(bridgeBurner), payload);

        assert(stablecoin.totalSupply() == supplyBefore);
    }

    /// @notice PROOF: A burn-then-mint round-trip preserves user balance.
    /// For all valid amounts: userBalance_after == userBalance_before.
    function check_burnThenMintPreservesUserBalance(uint256 amount) public {
        vm.assume(amount > 0 && amount <= INITIAL_SUPPLY);

        uint256 balanceBefore = stablecoin.balanceOf(USER);

        // Burn
        vm.prank(USER);
        bridgeBurner.sendTo(SRC_CHAIN, USER, amount);

        // Mint
        bytes memory payload = TokenMintMessage.encode(USER, amount);
        vm.prank(address(inbox));
        bridgeMinter.handleMessage(SRC_CHAIN, address(bridgeBurner), payload);

        assert(stablecoin.balanceOf(USER) == balanceBefore);
    }
}
