// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.30;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IBridgeBurner} from "./interfaces/IBridgeBurner.sol";
import {IOutbox} from "./interfaces/IOutbox.sol";
import {Stablecoin} from "../Stablecoin.sol";
import {TokenMintMessage} from "./TokenMintMessage.sol";

/// @title BridgeBurner
/// @notice Application-level bridge entry point. Burns tokens from the user via burnFrom,
/// then sends a message through the Outbox for the destination chain's BridgeMinter.
contract BridgeBurner is Initializable, Ownable2StepUpgradeable, UUPSUpgradeable, IBridgeBurner {
    Stablecoin public stablecoin;
    IOutbox public outbox;

    /// @notice Per-destination-chain minter address (the BridgeMinter on that chain).
    mapping(uint256 => address) public dstMinters;

    event DstMinterSet(uint256 indexed dstChain, address minter);
    event OutboxSet(address outbox);
    event StablecoinSet(address stablecoin);

    error DstMinterNotSet(uint256 dstChain);
    error ZeroAddress();
    error ZeroRecipient();
    error ZeroAmount();
    error SameChain();
    error InvalidOutbox(address outbox);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize the BridgeBurner proxy.
    /// @param owner_ Address that will own the contract (can configure and upgrade).
    /// @param stablecoin_ Address of the stablecoin contract to burn tokens from.
    /// @param outbox_ Address of the Outbox contract used to send cross-chain messages.
    function initialize(address owner_, address stablecoin_, address outbox_) public initializer {
        require(stablecoin_ != address(0), ZeroAddress());
        _validateOutbox(outbox_);
        __Ownable_init(owner_);
        stablecoin = Stablecoin(stablecoin_);
        outbox = IOutbox(outbox_);
    }

    /// @notice Set the BridgeMinter address on a destination chain.
    function setDstMinter(uint256 dstChain, address minter) external onlyOwner {
        dstMinters[dstChain] = minter;
        emit DstMinterSet(dstChain, minter);
    }

    /// @notice Update the Outbox contract reference.
    /// @dev Sensitive maintenance operation: should be performed during a paused window.
    /// The target MUST advertise IOutbox via ERC-165; rejecting `address(0)` alone is
    /// insufficient because a contract implementing `sendMessage(...)` without emitting
    /// `MessageSent` would otherwise let `sendTo` burn tokens without producing a
    /// verifiable bridge message.
    /// @param outbox_ Address of the new Outbox contract.
    function setOutbox(address outbox_) external onlyOwner {
        _validateOutbox(outbox_);
        outbox = IOutbox(outbox_);
        emit OutboxSet(outbox_);
    }

    /// @dev Reject zero address, EOAs, and any target that does not advertise
    /// `IOutbox` via ERC-165. The explicit `code.length` check routes EOAs through
    /// `InvalidOutbox` rather than the lower-level "call to non-contract address"
    /// revert solc emits for external calls into accounts with no code.
    function _validateOutbox(address outbox_) internal view {
        require(outbox_ != address(0), ZeroAddress());
        require(outbox_.code.length > 0, InvalidOutbox(outbox_));
        try IERC165(outbox_).supportsInterface(type(IOutbox).interfaceId) returns (bool ok) {
            require(ok, InvalidOutbox(outbox_));
        } catch {
            revert InvalidOutbox(outbox_);
        }
    }

    /// @notice Update the stablecoin contract reference.
    /// @param stablecoin_ Address of the new stablecoin contract.
    function setStablecoin(address stablecoin_) external onlyOwner {
        require(stablecoin_ != address(0), ZeroAddress());
        stablecoin = Stablecoin(stablecoin_);
        emit StablecoinSet(stablecoin_);
    }

    /// @inheritdoc IBridgeBurner
    function sendTo(uint256 dstChain, address recipient, uint256 amount) external {
        require(dstChain != block.chainid, SameChain());
        require(recipient != address(0), ZeroRecipient());
        require(amount > 0, ZeroAmount());

        address minter = dstMinters[dstChain];
        require(minter != address(0), DstMinterNotSet(dstChain));

        // Burn tokens from the caller (requires ERC20 approval)
        stablecoin.burnFrom(msg.sender, amount);

        // Encode the application payload and send through the Outbox
        bytes memory payload = TokenMintMessage.encode(recipient, amount);
        outbox.sendMessage(dstChain, minter, payload);
    }

    /// @dev Authorize UUPS upgrades. Restricted to the contract owner.
    function _authorizeUpgrade(address) internal override onlyOwner {}
}
