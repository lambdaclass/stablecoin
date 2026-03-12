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

    /// @notice Set of recognized attestors.
    mapping(address => bool) public isAttestor;

    /// @notice Nonces that have already been consumed (replay protection).
    mapping(bytes32 => bool) public usedNonces;

    event MessageDelivered(bytes32 indexed nonce, address indexed dstRecipient);
    event AttestorAdded(address indexed attestor);
    event AttestorRemoved(address indexed attestor);
    event ThresholdSet(uint256 threshold);

    error InvalidSignatureCount();
    error BelowThreshold();
    error InvalidSignature();
    error DuplicateSigner();
    error SignerNotAttestor(address signer);
    error NonceAlreadyUsed(bytes32 nonce);
    error WrongDestinationChain(uint256 expected, uint256 actual);
    error ThresholdTooHigh(uint256 threshold, uint256 attestorCount);
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

    // ─── Attestor management (owner-only) ────────────────────────────

    function addAttestor(address attestor) external onlyOwner {
        require(attestor != address(0), ZeroAddress());
        require(!isAttestor[attestor], AlreadyAttestor(attestor));
        isAttestor[attestor] = true;
        emit AttestorAdded(attestor);
    }

    function removeAttestor(address attestor) external onlyOwner {
        require(isAttestor[attestor], NotAttestor(attestor));
        isAttestor[attestor] = false;
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
        require(!usedNonces[nonce], NonceAlreadyUsed(nonce));
        usedNonces[nonce] = true;

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
        uint256 sigCount = signatures.length / 65;
        require(signatures.length == sigCount * 65, InvalidSignatureCount());
        require(sigCount >= threshold, BelowThreshold());

        // Hash the raw message bytes with EIP-712
        bytes32 structHash = keccak256(message);
        bytes32 digest = _hashTypedDataV4(structHash);

        address prevSigner = address(0);
        for (uint256 i = 0; i < sigCount; i++) {
            // Extract r, s, v from packed signature
            uint256 offset = i * 65;
            bytes32 r = bytes32(signatures[offset:offset + 32]);
            bytes32 s = bytes32(signatures[offset + 32:offset + 64]);
            uint8 v = uint8(signatures[offset + 64]);

            address signer = ECDSA.recover(digest, v, r, s);

            // Enforce ascending order to detect duplicates in O(n)
            require(signer > prevSigner, DuplicateSigner());
            require(isAttestor[signer], SignerNotAttestor(signer));

            prevSigner = signer;
        }
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}
}
