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
    mapping(address => uint256) private _attestor;

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

    function initialize(address owner_) public initializer {
        __Ownable_init(owner_);
        __EIP712_init("Inbox", "1");
    }

    function isAttestor(address account) public view returns (bool) {
        return _isAttestor(account);
    }

    // ─── Attestor management (owner-only) ────────────────────────────

    function addAttestor(address attestor) external onlyOwner {
        require(attestor != address(0), ZeroAddress());
        require(!_isAttestor(attestor), AlreadyAttestor(attestor));
        _attestor[attestor] = 1;
        emit AttestorAdded(attestor);
    }

    function removeAttestor(address attestor) external onlyOwner {
        require(_isAttestor(attestor), NotAttestor(attestor));
        _attestor[attestor] = 0;
        emit AttestorRemoved(attestor);
    }

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

    function domainSeparator() public view returns (bytes32) {
        return _domainSeparatorV4();
    }

    // ─── Internal ────────────────────────────────────────────────────

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
            require(_isAttestor(signer), SignerNotAttestor(signer));

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

    function _isAttestor(address account) private view returns (bool) {
        return _attestor[account] != 0;
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}
}
