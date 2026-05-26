// SPDX-License-Identifier: Apache-2.0
pragma solidity =0.8.30;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {EIP712Upgradeable} from "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IInbox} from "./interfaces/IInbox.sol";
import {IMessageReceiver} from "./interfaces/IMessageReceiver.sol";
import {IOutbox} from "./interfaces/IOutbox.sol";

/// @title Inbox
/// @notice Generic message inbox with k-of-n EIP-712 attestor verification, nonce replay protection,
/// and message delivery to receiver contracts.
/// @custom:security-contact security@lambdaclass.com
contract Inbox is
    Initializable,
    Ownable2StepUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable,
    EIP712Upgradeable,
    IInbox
{
    using EnumerableSet for EnumerableSet.AddressSet;

    /// @notice Length in bytes of a packed ECDSA signature (r || s || v).
    uint256 internal constant SIGNATURE_LENGTH = 65;

    /// @notice Minimum number of valid attestor signatures required.
    uint256 public threshold;

    /// @notice Set of recognized attestors (enumerable for off-chain queries).
    EnumerableSet.AddressSet private _attestors;

    /// @notice Nonces that have already been consumed (nonzero = used).
    /// @dev Uses uint256 instead of bool to skip the read-modify-write the
    /// compiler emits for sub-word types. See OZ ReentrancyGuard for rationale:
    /// https://github.com/OpenZeppelin/openzeppelin-contracts/blob/fcbae5394ae8ad52d8e580a3477db99814b9d565/contracts/utils/ReentrancyGuard.sol#L39-L43
    mapping(bytes32 nonce => uint256 used) public usedNonces;

    /// @notice Per-source-chain canonical Outbox address. A message is only accepted
    /// when its `srcOutbox` field equals `srcOutboxes[srcChain]`. This enforces the
    /// "one canonical Outbox per source chain" invariant on which the nonce
    /// derivation depends — the nonce includes `srcOutbox`, so a quorum that signs
    /// for a stranger Outbox produces a nonce that the Inbox refuses to recognize.
    mapping(uint256 srcChain => address outbox) public srcOutboxes;

    /// @notice Emitted on every successful `recvMessage` delivery.
    event MessageDelivered(bytes32 indexed nonce, address indexed dstRecipient);
    /// @notice Emitted when an address is added to the attestor set.
    event AttestorAdded(address indexed attestor);
    /// @notice Emitted when an address is removed from the attestor set.
    event AttestorRemoved(address indexed attestor);
    /// @notice Emitted when the signature threshold is updated.
    event ThresholdSet(uint256 threshold);
    /// @notice Emitted when the canonical Outbox for `srcChain` is configured or replaced.
    event SrcOutboxSet(uint256 indexed srcChain, address outbox);

    error InvalidSignatureCount();
    error BelowThreshold();
    error DuplicateSigner();
    error SignerNotAttestor(address signer);
    error NonceAlreadyUsed(bytes32 nonce);
    error WrongDestinationChain(uint256 expected, uint256 actual);
    error ZeroAddress(bytes32 field);
    error AlreadyAttestor(address attestor);
    error NotAttestor(address attestor);
    error InvalidThreshold(uint256 threshold, uint256 attestorCount);
    /// @notice Thrown by `setSrcOutbox` when a non-zero entry already exists for
    /// `srcChain`. Operators must explicitly clear the entry (set to `address(0)`)
    /// during a paused-and-drained window before pointing at a new Outbox; this
    /// guards against the "swap Outbox while messages are in flight" footgun, in
    /// which already-signed messages reference the old `srcOutbox` and would be
    /// rejected silently after the swap.
    error SrcOutboxAlreadySet(uint256 srcChain, address current);
    /// @notice Thrown by `recvMessage` when the message's `srcOutbox` does not
    /// match the configured `srcOutboxes[srcChain]`. Without this check, attestors
    /// could sign messages that claim to originate from any Outbox; with it, the
    /// derived nonce is only valid when computed against the canonical source
    /// Outbox.
    error UnknownSrcOutbox(uint256 srcChain, address claimed, address expected);
    /// @notice Thrown by `setSrcOutbox` when the candidate has no bytecode or
    /// does not advertise `IOutbox` via ERC-165. Mirrors `BridgeBurner._validateOutbox`.
    error InvalidOutbox(address outbox);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize the Inbox proxy with an owner and EIP-712 domain.
    /// @param owner_ Address that will own the contract (can manage attestors, threshold, and upgrades).
    function initialize(address owner_) public initializer {
        __Ownable_init(owner_);
        __Pausable_init();
        __EIP712_init("Inbox", "1");
    }

    /// @notice Check whether an address is a recognized attestor.
    /// @param account Address to check.
    /// @return True if the address is an active attestor.
    function isAttestor(address account) public view returns (bool) {
        return _attestors.contains(account);
    }

    /// @notice Return the full list of current attestor addresses.
    /// @return Array of attestor addresses (order is not guaranteed to be stable).
    function getAttestors() external view returns (address[] memory) {
        return _attestors.values();
    }

    /// @notice Return the number of active attestors.
    /// @return The size of the attestor set.
    function getAttestorCount() external view returns (uint256) {
        return _attestors.length();
    }

    // ─── Attestor management (owner-only) ────────────────────────────

    /// @notice Add an address to the attestor set.
    /// @param attestor Address to add. Must not be zero or already an attestor.
    function addAttestor(address attestor) external onlyOwner {
        require(attestor != address(0), ZeroAddress("attestor"));
        require(_attestors.add(attestor), AlreadyAttestor(attestor));
        emit AttestorAdded(attestor);
    }

    /// @notice Remove an address from the attestor set.
    /// @dev Rejects the removal if it would leave fewer active attestors than the current
    /// threshold. The owner must lower `threshold` first (via setThreshold) before pruning
    /// the set below it.
    /// @param attestor Address to remove. Must be a current attestor.
    function removeAttestor(address attestor) external onlyOwner {
        require(_attestors.remove(attestor), NotAttestor(attestor));
        uint256 newCount = _attestors.length();
        require(newCount >= threshold, InvalidThreshold(threshold, newCount));
        emit AttestorRemoved(attestor);
    }

    /// @notice Update the minimum number of attestor signatures required to deliver a message.
    /// @dev Enforces `0 < threshold_ <= attestorCount` so the new threshold is always
    /// satisfiable by the current attestor set.
    /// @param threshold_ New threshold value.
    function setThreshold(uint256 threshold_) external onlyOwner {
        uint256 attestorCount = _attestors.length();
        require(threshold_ > 0 && threshold_ <= attestorCount, InvalidThreshold(threshold_, attestorCount));
        threshold = threshold_;
        emit ThresholdSet(threshold_);
    }

    /// @notice Configure or clear the canonical Outbox address for a source chain.
    /// @dev Pass `outbox = address(0)` to clear a route — this is the operator-side
    /// step required before swapping a chain's Outbox: pause, drain in-flight, clear
    /// here, then set the new Outbox.
    ///
    /// When setting a non-zero outbox, the candidate must (a) have bytecode and
    /// (b) advertise `IOutbox` via ERC-165. The two checks mirror
    /// `BridgeBurner._validateOutbox` and catch the most common operator typos
    /// (EOA, unrelated contract, undeployed CREATE2 target).
    ///
    /// Refuses to overwrite a non-zero entry — the operator must clear first.
    /// This prevents the silent "swap Outbox while messages are in flight" footgun.
    /// @param srcChain Source chain id whose Outbox to (re)configure.
    /// @param outbox  Canonical Outbox address on that chain, or `address(0)` to clear.
    function setSrcOutbox(uint256 srcChain, address outbox) external onlyOwner {
        address current = srcOutboxes[srcChain];
        if (outbox == address(0)) {
            srcOutboxes[srcChain] = address(0);
            emit SrcOutboxSet(srcChain, address(0));
            return;
        }
        require(current == address(0), SrcOutboxAlreadySet(srcChain, current));
        _validateOutbox(outbox);
        srcOutboxes[srcChain] = outbox;
        emit SrcOutboxSet(srcChain, outbox);
    }

    /// @dev Validate that `outbox_` is a contract advertising `IOutbox` via ERC-165.
    /// Same shape as `BridgeBurner._validateOutbox` — the explicit `code.length`
    /// check routes EOAs through `InvalidOutbox` instead of solc's lower-level
    /// "call to non-contract address" revert that try/catch does not catch.
    function _validateOutbox(address outbox_) internal view {
        require(outbox_.code.length > 0, InvalidOutbox(outbox_));
        try IERC165(outbox_).supportsInterface(type(IOutbox).interfaceId) returns (bool ok) {
            require(ok, InvalidOutbox(outbox_));
        } catch {
            revert InvalidOutbox(outbox_);
        }
    }

    // ─── Message reception ───────────────────────────────────────────

    /// @inheritdoc IInbox
    function recvMessage(bytes calldata message, bytes calldata signatures) external whenNotPaused {
        // Decode the transport-level message. The transport nonce is not part of
        // the wire format — it is derived from a subset of the signed fields, so
        // attestors cannot choose it independently of the source event.
        (
            uint256 srcChain,
            address srcOutbox,
            address srcSender,
            uint256 srcSeq,
            uint256 dstChain,
            address dstRecipient,
            bytes memory payload
        ) = abi.decode(message, (uint256, address, address, uint256, uint256, address, bytes));

        // Check destination chain
        require(dstChain == block.chainid, WrongDestinationChain(block.chainid, dstChain));

        // Authenticate the source Outbox: must match the canonical entry for `srcChain`.
        // A zero entry (route disabled) or a different entry both reject the message.
        address expectedOutbox = srcOutboxes[srcChain];
        require(
            expectedOutbox != address(0) && srcOutbox == expectedOutbox,
            UnknownSrcOutbox(srcChain, srcOutbox, expectedOutbox)
        );

        // Derive the replay-protection nonce. Must use the SAME field encoding as
        // `Outbox.sendMessage` so a valid source event produces a matching key.
        bytes32 nonce = keccak256(abi.encode(srcChain, srcOutbox, srcSender, srcSeq));

        // Check nonce replay
        require(usedNonces[nonce] == 0, NonceAlreadyUsed(nonce));
        usedNonces[nonce] = 1;

        // Verify signatures
        _verifySignatures(message, signatures);

        // Deliver to receiver
        IMessageReceiver(dstRecipient).handleMessage(srcChain, srcSender, payload);

        emit MessageDelivered(nonce, dstRecipient);
    }

    // ─── EIP-712 ─────────────────────────────────────────────────────

    /// @notice Return the EIP-712 domain separator for this contract.
    /// @return The domain separator hash, bound to the contract address and chain ID.
    function domainSeparator() public view returns (bytes32) {
        return _domainSeparatorV4();
    }

    // ─── Internal ────────────────────────────────────────────────────

    /// @dev Verify that `signatures` contains at least `threshold` valid attestor signatures
    /// over the EIP-712 digest of `message`. Signatures must be sorted by signer address
    /// in ascending order to detect duplicates in O(n).
    function _verifySignatures(bytes calldata message, bytes calldata signatures) internal view {
        // Cache storage read once for the two comparisons below.
        uint256 threshold_ = threshold;

        // Fail-closed: reject all messages when threshold is unconfigured (zero).
        require(threshold_ > 0, BelowThreshold());
        uint256 sigCount = signatures.length / SIGNATURE_LENGTH;
        require(signatures.length == sigCount * SIGNATURE_LENGTH, InvalidSignatureCount());
        require(sigCount >= threshold_, BelowThreshold());

        bytes32 digest = _hashMessage(message);

        // Snapshot the attestor set into memory once so the membership check
        // inside the loop doesn't re-read storage on every iteration.
        address[] memory attestors = _attestors.values();

        address prevSigner = address(0);
        for (uint256 i = 0; i < sigCount; ++i) {
            uint256 offset = i * SIGNATURE_LENGTH;
            address signer = ECDSA.recoverCalldata(digest, signatures[offset:offset + SIGNATURE_LENGTH]);

            // Enforce ascending order to detect duplicates in O(n)
            require(signer > prevSigner, DuplicateSigner());
            require(_containsAddress(attestors, signer), SignerNotAttestor(signer));

            prevSigner = signer;
        }
    }

    /// @dev Linear membership check over an in-memory address array. Used by
    /// `_verifySignatures` after snapshotting the attestor set so the
    /// per-signature check no longer hits storage.
    function _containsAddress(address[] memory haystack, address needle) private pure returns (bool) {
        uint256 len = haystack.length;
        for (uint256 i = 0; i < len; i++) {
            if (haystack[i] == needle) return true;
        }
        return false;
    }

    /// @notice Hashes raw message bytes with the EIP-712 domain separator for
    /// chain/contract binding, without full EIP-712 struct encoding (no
    /// typeHash prefix) since attestors are automated, not wallet signers.
    function _hashMessage(bytes calldata message) internal view returns (bytes32) {
        bytes32 structHash;

        // Uses assembly to avoid a memory allocation: hashes at the free
        // pointer as scratch space without advancing it.
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            calldatacopy(ptr, message.offset, message.length)
            structHash := keccak256(ptr, message.length)
        }

        return _hashTypedDataV4(structHash);
    }

    /// @notice Pause the inbox, blocking all inbound message delivery.
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpause the inbox, resuming inbound message delivery.
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @dev Authorize UUPS upgrades. Restricted to the contract owner.
    function _authorizeUpgrade(address) internal override onlyOwner {}
}
