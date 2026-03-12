// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.30;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {EIP712Upgradeable} from "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IInbox} from "./interfaces/IInbox.sol";
import {IMessageReceiver} from "./interfaces/IMessageReceiver.sol";

/// @title Inbox
/// @notice Generic message inbox with k-of-n EIP-712 attestor verification, nonce replay protection,
/// and message delivery to receiver contracts.
contract Inbox is Initializable, OwnableUpgradeable, UUPSUpgradeable, EIP712Upgradeable, IInbox {
    /// @notice Minimum number of valid attestor signatures required.
    uint256 public threshold;

    /// @notice Set of recognized attestors (nonzero = active).
    /// @dev Uses uint256 instead of bool to skip the read-modify-write the
    /// compiler emits for sub-word types. See OZ ReentrancyGuard for rationale:
    /// https://github.com/OpenZeppelin/openzeppelin-contracts/blob/fcbae5394ae8ad52d8e580a3477db99814b9d565/contracts/utils/ReentrancyGuard.sol#L39-L43
    mapping(address => uint256) private _isAttestor;

    /// @notice Nonces that have already been consumed (nonzero = used).
    /// @dev Uses uint256 instead of bool to skip the read-modify-write the
    /// compiler emits for sub-word types. See OZ ReentrancyGuard for rationale:
    /// https://github.com/OpenZeppelin/openzeppelin-contracts/blob/fcbae5394ae8ad52d8e580a3477db99814b9d565/contracts/utils/ReentrancyGuard.sol#L39-L43
    mapping(bytes32 => uint256) public usedNonces;

    event MessageDelivered(bytes32 indexed nonce, address indexed dstRecipient);
    event AttestorAdded(address indexed attestor);
    event AttestorRemoved(address indexed attestor);
    event ThresholdSet(uint256 threshold);

    error InvalidSignatureCount();
    error BelowThreshold();
    error DuplicateSigner();
    error SignerNotAttestor(address signer);
    error NonceAlreadyUsed(bytes32 nonce);
    error WrongDestinationChain(uint256 expected, uint256 actual);
    error ZeroAddress();
    error AlreadyAttestor(address attestor);
    error NotAttestor(address attestor);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize the Inbox proxy with an owner and EIP-712 domain.
    /// @param owner_ Address that will own the contract (can manage attestors, threshold, and upgrades).
    function initialize(address owner_) public initializer {
        __Ownable_init(owner_);
        __EIP712_init("Inbox", "1");
    }

    /// @notice Check whether an address is a recognized attestor.
    /// @param account Address to check.
    /// @return True if the address is an active attestor.
    function isAttestor(address account) public view returns (bool) {
        return _isAttestor[account] != 0;
    }

    // ─── Attestor management (owner-only) ────────────────────────────

    /// @notice Add an address to the attestor set.
    /// @param attestor Address to add. Must not be zero or already an attestor.
    function addAttestor(address attestor) external onlyOwner {
        require(attestor != address(0), ZeroAddress());
        require(!isAttestor(attestor), AlreadyAttestor(attestor));
        _isAttestor[attestor] = 1;
        emit AttestorAdded(attestor);
    }

    /// @notice Remove an address from the attestor set.
    /// @dev WARNING: if removing this attestor leaves fewer active attestors than the current
    /// threshold, all message delivery will be blocked until the threshold is lowered or new
    /// attestors are added.
    /// @param attestor Address to remove. Must be a current attestor.
    function removeAttestor(address attestor) external onlyOwner {
        require(isAttestor(attestor), NotAttestor(attestor));
        _isAttestor[attestor] = 0;
        emit AttestorRemoved(attestor);
    }

    /// @notice Update the minimum number of attestor signatures required to deliver a message.
    /// @dev WARNING: a threshold of 0 or higher than the number of active attestors will cause
    /// all message delivery to be rejected until the threshold is updated.
    /// @param threshold_ New threshold value.
    function setThreshold(uint256 threshold_) external onlyOwner {
        threshold = threshold_;
        emit ThresholdSet(threshold_);
    }

    // ─── Message reception ───────────────────────────────────────────

    /// @inheritdoc IInbox
    function recvMessage(bytes calldata message, bytes calldata signatures) external {
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
        // Fail-closed: reject all messages when threshold is unconfigured (zero).
        require(threshold > 0, BelowThreshold());
        uint256 sigCount = signatures.length / 65;
        require(signatures.length == sigCount * 65, InvalidSignatureCount());
        require(sigCount >= threshold, BelowThreshold());

        bytes32 digest = _hashMessage(message);

        address prevSigner = address(0);
        for (uint256 i = 0; i < sigCount; i++) {
            uint256 offset = i * 65;
            address signer = ECDSA.recoverCalldata(digest, signatures[offset:offset + 65]);

            // Enforce ascending order to detect duplicates in O(n)
            require(signer > prevSigner, DuplicateSigner());
            require(_isAttestor[signer] != 0, SignerNotAttestor(signer));

            prevSigner = signer;
        }
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

    /// @dev Authorize UUPS upgrades. Restricted to the contract owner.
    function _authorizeUpgrade(address) internal override onlyOwner {}
}
