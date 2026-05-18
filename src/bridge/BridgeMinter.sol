// SPDX-License-Identifier: Apache-2.0
pragma solidity =0.8.30;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {IMessageReceiver} from "./interfaces/IMessageReceiver.sol";
import {Stablecoin} from "../Stablecoin.sol";
import {TokenMintMessage} from "./TokenMintMessage.sol";

/// @title BridgeMinter
/// @notice Application-level bridge exit point. Receives messages from the Inbox,
/// validates the source chain and sender, then mints tokens to the recipient.
contract BridgeMinter is Initializable, Ownable2StepUpgradeable, UUPSUpgradeable, IMessageReceiver {
    Stablecoin public stablecoin;
    address public inbox;

    /// @notice Mapping from source chain ID to the expected sender address (BridgeBurner on that chain).
    /// A source chain is allowed if and only if the mapped address is non-zero.
    mapping(uint256 => address) public allowedSenders;

    event AllowedSenderSet(uint256 indexed srcChain, address sender);
    event InboxSet(address inbox);
    event StablecoinSet(address stablecoin);

    error OnlyInbox();
    error DisallowedSender(uint256 srcChain, address srcSender);
    error ZeroAddress();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize the BridgeMinter proxy.
    /// @param owner_ Address that will own the contract (can configure and upgrade).
    /// @param stablecoin_ Address of the stablecoin contract to mint tokens on.
    /// @param inbox_ Address of the Inbox contract authorized to deliver messages.
    function initialize(address owner_, address stablecoin_, address inbox_) public initializer {
        require(stablecoin_ != address(0), ZeroAddress());
        require(inbox_ != address(0), ZeroAddress());
        __Ownable_init(owner_);
        stablecoin = Stablecoin(stablecoin_);
        inbox = inbox_;
    }

    /// @notice Set the expected sender for a source chain.
    function setAllowedSender(uint256 srcChain, address sender) external onlyOwner {
        allowedSenders[srcChain] = sender;
        emit AllowedSenderSet(srcChain, sender);
    }

    /// @notice Update the Inbox contract reference.
    /// @param inbox_ Address of the new Inbox contract.
    function setInbox(address inbox_) external onlyOwner {
        require(inbox_ != address(0), ZeroAddress());
        inbox = inbox_;
        emit InboxSet(inbox_);
    }

    /// @notice Update the stablecoin contract reference.
    /// @param stablecoin_ Address of the new stablecoin contract.
    function setStablecoin(address stablecoin_) external onlyOwner {
        require(stablecoin_ != address(0), ZeroAddress());
        stablecoin = Stablecoin(stablecoin_);
        emit StablecoinSet(stablecoin_);
    }

    /// @inheritdoc IMessageReceiver
    function handleMessage(uint256 srcChain, address srcSender, bytes calldata payload) external {
        require(msg.sender == inbox, OnlyInbox());
        address allowed = allowedSenders[srcChain];
        require(allowed != address(0) && allowed == srcSender, DisallowedSender(srcChain, srcSender));

        (address recipient, uint256 amount) = TokenMintMessage.decode(payload);
        stablecoin.mint(recipient, amount);
    }

    /// @dev Authorize UUPS upgrades. Restricted to the contract owner.
    function _authorizeUpgrade(address) internal override onlyOwner {}
}
