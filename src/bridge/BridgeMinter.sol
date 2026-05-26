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
/// @custom:security-contact security@lambdaclass.com
contract BridgeMinter is Initializable, Ownable2StepUpgradeable, UUPSUpgradeable, IMessageReceiver {
    /// @notice Stablecoin decimals every chain's deployment MUST use. See the
    /// equivalent constant on `BridgeBurner` for the full rationale — both ends
    /// of a bridge must agree on this value or the wire amount is misinterpreted.
    uint8 public constant EXPECTED_DECIMALS = 6;

    /// @notice Target Stablecoin for mints triggered by inbound messages.
    Stablecoin public stablecoin;
    /// @notice Inbox authorized to deliver messages to this minter (caller of handleMessage).
    address public inbox;

    /// @notice Mapping from source chain ID to the expected sender address (BridgeBurner on that chain).
    /// A source chain is allowed if and only if the mapped address is non-zero.
    mapping(uint256 srcChain => address sender) public allowedSenders;

    /// @notice Emitted when the allowed BridgeBurner for `srcChain` is configured.
    event AllowedSenderSet(uint256 indexed srcChain, address sender);
    /// @notice Emitted when the authorized Inbox is updated.
    event InboxSet(address inbox);
    /// @notice Emitted when the stablecoin reference is set or replaced.
    /// @dev `previousStablecoin == address(0)` on the initial wiring after deployment;
    /// any subsequent emission represents a swap and should be alerted on by operators.
    event StablecoinChanged(address indexed previousStablecoin, address indexed newStablecoin);

    error OnlyInbox();
    error DisallowedSender(uint256 srcChain, address srcSender);
    error ZeroAddress(bytes32 field);
    error StablecoinNotSet();
    /// @notice Thrown by `setStablecoin` when the target address does not expose the
    /// Stablecoin shape (no `BURNER_ROLE()` accessor returning the canonical constant).
    error NotAStablecoin(address target);
    /// @notice Thrown by `setStablecoin` when the target's `decimals()` does not
    /// match `EXPECTED_DECIMALS`.
    error DecimalsMismatch(uint8 expected, uint8 actual);

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
        require(inbox_ != address(0), ZeroAddress("inbox"));
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
        require(inbox_ != address(0), ZeroAddress("inbox"));
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
    /// @dev Performs a shape probe (`BURNER_ROLE()` returns the canonical constant) to
    /// catch the most common operator mistakes: pasting an EOA, a wrong-contract address,
    /// or an undeployed CREATE2 target. This is NOT a cross-chain identity check — a
    /// matching Stablecoin shape on the wrong chain still passes. Cross-chain wiring
    /// correctness must be verified out-of-band before bridging real value.
    function setStablecoin(address stablecoin_) external onlyOwner {
        require(stablecoin_ != address(0), ZeroAddress("stablecoin"));
        _requireStablecoinShape(stablecoin_);
        uint8 actual = Stablecoin(stablecoin_).decimals();
        require(actual == EXPECTED_DECIMALS, DecimalsMismatch(EXPECTED_DECIMALS, actual));
        address previous = address(stablecoin);
        stablecoin = Stablecoin(stablecoin_);
        emit StablecoinChanged(previous, stablecoin_);
    }

    /// @dev Reverts if `target` is not a Stablecoin-shaped contract. The explicit
    /// `code.length` check is required because Solidity 0.8.x's compiler-inserted
    /// extcodesize check sits AROUND the external call (not inside it), so a call to
    /// an EOA reverts with "call to non-contract address" that try/catch does NOT
    /// catch. Once the codesize check passes, the try/catch handles the remaining
    /// failure modes: a contract that lacks `BURNER_ROLE()` (call reverts → catch
    /// branch) and a contract whose `BURNER_ROLE()` returns the wrong value (require
    /// branch in the success arm).
    function _requireStablecoinShape(address target) private view {
        require(target.code.length > 0, NotAStablecoin(target));
        try Stablecoin(target).BURNER_ROLE() returns (bytes32 role) {
            require(role == keccak256("BURNER_ROLE"), NotAStablecoin(target));
        } catch {
            revert NotAStablecoin(target);
        }
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
