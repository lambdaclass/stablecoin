// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.30;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {EIP712Upgradeable} from "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {IInbox} from "./interfaces/IInbox.sol";
import {IMessageReceiver} from "./interfaces/IMessageReceiver.sol";

/// @title Inbox
/// @notice Generic message inbox with k-of-n EIP-712 attestor verification, nonce replay protection,
/// and message delivery to receiver contracts.
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

    /// @notice Emitted on every successful `recvMessage` delivery.
    event MessageDelivered(bytes32 indexed nonce, address indexed dstRecipient);
    /// @notice Emitted when an address is added to the attestor set.
    event AttestorAdded(address indexed attestor);
    /// @notice Emitted when an address is removed from the attestor set.
    event AttestorRemoved(address indexed attestor);
    /// @notice Emitted when the signature threshold is updated.
    event ThresholdSet(uint256 threshold);

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

    // ─── Message reception ───────────────────────────────────────────

    /// @inheritdoc IInbox
    function recvMessage(bytes calldata message, bytes calldata signatures) external whenNotPaused {
        // Decode the transport-level message
        (
            uint256 srcChain,
            address srcSender,
            uint256 dstChain,
            address dstRecipient,
            bytes32 nonce,
            bytes memory payload
        ) = abi.decode(message, (uint256, address, uint256, address, bytes32, bytes));

        // Check destination chain
        require(dstChain == block.chainid, WrongDestinationChain(block.chainid, dstChain));

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
