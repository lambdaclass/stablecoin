// SPDX-License-Identifier: UNLICENSED
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
    /// @notice Emitted when the stablecoin reference is set or replaced.
    /// @dev `previousStablecoin == address(0)` on the initial wiring after deployment;
    /// any subsequent emission represents a swap and should be alerted on by operators.
    event StablecoinChanged(address indexed previousStablecoin, address indexed newStablecoin);

    error OnlyInbox();
    error DisallowedSender(uint256 srcChain, address srcSender);
    error ZeroAddress();
    error StablecoinNotSet();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize the BridgeMinter proxy.
    /// @dev The stablecoin address is intentionally NOT a parameter here: encoding a
    /// per-chain stablecoin address into the proxy creation bytecode would make the
    /// BridgeMinter's CREATE2 address chain-dependent, breaking the deterministic
    /// "same address across every EVM chain" invariant that BridgeDeploy provides.
    /// The owner MUST call `setStablecoin` immediately after deployment; until then
    /// `handleMessage` reverts with `StablecoinNotSet`.
    /// @param owner_ Address that will own the contract (can configure and upgrade).
    /// @param inbox_ Address of the Inbox contract authorized to deliver messages.
    function initialize(address owner_, address inbox_) public initializer {
        require(inbox_ != address(0), ZeroAddress());
        __Ownable_init(owner_);
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

    /// @notice Set or replace the stablecoin contract reference.
    /// @dev SENSITIVE MAINTENANCE OPERATION. Replacing a non-zero `stablecoin` while
    /// the bridge is live can route inflight inbound mints (already burned on the
    /// source chain) into a different token. Operators MUST pause this chain's Inbox
    /// AND every counterpart chain's Outbox and let the attestor flow drain before
    /// swapping. The accidental-overwrite case is also detectable: `StablecoinChanged`
    /// carries the previous address, so any emission with `previousStablecoin != 0`
    /// should trigger an operator alert.
    /// @param stablecoin_ Address of the new stablecoin contract.
    function setStablecoin(address stablecoin_) external onlyOwner {
        require(stablecoin_ != address(0), ZeroAddress());
        address previous = address(stablecoin);
        stablecoin = Stablecoin(stablecoin_);
        emit StablecoinChanged(previous, stablecoin_);
    }

    /// @inheritdoc IMessageReceiver
    function handleMessage(uint256 srcChain, address srcSender, bytes calldata payload) external {
        require(msg.sender == inbox, OnlyInbox());
        require(address(stablecoin) != address(0), StablecoinNotSet());
        address allowed = allowedSenders[srcChain];
        require(allowed != address(0) && allowed == srcSender, DisallowedSender(srcChain, srcSender));

        (address recipient, uint256 amount) = TokenMintMessage.decode(payload);
        stablecoin.mint(recipient, amount);
    }

    /// @dev Authorize UUPS upgrades. Restricted to the contract owner.
    function _authorizeUpgrade(address) internal override onlyOwner {}
}
