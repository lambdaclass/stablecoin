// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.30;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {IBridgeBurner} from "./interfaces/IBridgeBurner.sol";
import {IOutbox} from "./interfaces/IOutbox.sol";
import {Stablecoin} from "../Stablecoin.sol";
import {TokenMintMessage} from "./TokenMintMessage.sol";

/// @title BridgeBurner
/// @notice Application-level bridge entry point. Burns tokens from the user via burnFrom,
/// then sends a message through the Outbox for the destination chain's BridgeMinter.
contract BridgeBurner is Initializable, OwnableUpgradeable, UUPSUpgradeable, IBridgeBurner {
    Stablecoin public stablecoin;
    IOutbox public outbox;

    /// @notice Per-destination-chain minter address (the BridgeMinter on that chain).
    mapping(uint256 => address) public dstMinters;

    event DstMinterSet(uint256 indexed dstChain, address minter);
    event OutboxSet(address outbox);
    event StablecoinSet(address stablecoin);

    error DstMinterNotSet(uint256 dstChain);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize the BridgeBurner proxy.
    /// @param owner_ Address that will own the contract (can configure and upgrade).
    /// @param stablecoin_ Address of the stablecoin contract to burn tokens from.
    /// @param outbox_ Address of the Outbox contract used to send cross-chain messages.
    function initialize(address owner_, address stablecoin_, address outbox_) public initializer {
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
    /// @param outbox_ Address of the new Outbox contract.
    function setOutbox(address outbox_) external onlyOwner {
        outbox = IOutbox(outbox_);
        emit OutboxSet(outbox_);
    }

    /// @notice Update the stablecoin contract reference.
    /// @param stablecoin_ Address of the new stablecoin contract.
    function setStablecoin(address stablecoin_) external onlyOwner {
        stablecoin = Stablecoin(stablecoin_);
        emit StablecoinSet(stablecoin_);
    }

    /// @inheritdoc IBridgeBurner
    function sendTo(uint256 dstChain, address recipient, uint256 amount) external {
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
