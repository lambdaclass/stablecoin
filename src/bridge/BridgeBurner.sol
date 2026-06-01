// SPDX-License-Identifier: Apache-2.0
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
/// @custom:security-contact security@lambdaclass.com
contract BridgeBurner is Initializable, Ownable2StepUpgradeable, UUPSUpgradeable, IBridgeBurner {
    /// @notice Target Stablecoin for sendTo burns
    Stablecoin public stablecoin;
    /// @notice Outbox that dispatches the cross-chain bridge message.
    IOutbox public outbox;

    /// @notice Per-destination-chain minter address (the BridgeMinter on that chain).
    mapping(uint256 dstChain => address minter) public dstMinters;

    /// @notice Emitted when the destination minter address for `dstChain` is configured.
    event DstMinterSet(uint256 indexed dstChain, address minter);
    /// @notice Emitted when the Outbox reference is updated.
    event OutboxSet(address outbox);
    /// @notice Emitted when the stablecoin reference is set or replaced.
    /// @dev `previousStablecoin == address(0)` on the initial wiring after deployment;
    /// any subsequent emission represents a swap and should be alerted on by operators.
    event StablecoinChanged(address indexed previousStablecoin, address indexed newStablecoin);

    error DstMinterNotSet(uint256 dstChain);
    error ZeroAddress(bytes32 field);
    error ZeroRecipient();
    error ZeroAmount();
    error SameChain();
    error InvalidOutbox(address outbox);
    error StablecoinNotSet();
    /// @notice Thrown by `setStablecoin` when the target address does not expose the
    /// Stablecoin shape (no `BURNER_ROLE()` accessor returning the canonical constant).
    error NotAStablecoin(address target);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize the BridgeBurner proxy.
    /// @dev The stablecoin address is intentionally NOT a parameter here: encoding a
    /// per-chain stablecoin address into the proxy creation bytecode would make the
    /// BridgeBurner's CREATE2 address chain-dependent, breaking the deterministic
    /// "same address across every EVM chain" invariant that BridgeDeploy provides.
    /// The owner MUST call `setStablecoin` immediately after deployment; until then
    /// `sendTo` reverts with `StablecoinNotSet`.
    /// @param owner_ Address that will own the contract (can configure and upgrade).
    /// @param outbox_ Address of the Outbox contract used to send cross-chain messages.
    function initialize(address owner_, address outbox_) public initializer {
        _validateOutbox(outbox_);
        __Ownable_init(owner_);
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
        require(outbox_ != address(0), ZeroAddress("outbox"));
        require(outbox_.code.length > 0, InvalidOutbox(outbox_));
        try IERC165(outbox_).supportsInterface(type(IOutbox).interfaceId) returns (bool ok) {
            require(ok, InvalidOutbox(outbox_));
        } catch {
            revert InvalidOutbox(outbox_);
        }
    }

    /// @notice Set or replace the stablecoin contract reference.
    /// @dev SENSITIVE MAINTENANCE OPERATION. Replacing a non-zero `stablecoin` while
    /// the bridge is live can route inflight inbound mints (already burned on the
    /// source chain) into a different token. Operators MUST pause cross-chain
    /// activity (this chain's Outbox AND every counterpart chain's Inbox) and let
    /// the attestor flow drain before swapping. The accidental-overwrite case is
    /// also detectable: `StablecoinChanged` carries the previous address, so any
    /// emission with `previousStablecoin != 0` should trigger an operator alert.
    /// @param stablecoin_ Address of the new stablecoin contract.
    /// @dev Performs a shape probe (`BURNER_ROLE()` returns the canonical constant) to
    /// catch the most common operator mistakes: pasting an EOA, a wrong-contract address,
    /// or an undeployed CREATE2 target. This is NOT a cross-chain identity check — a
    /// matching Stablecoin shape on the wrong chain still passes. Cross-chain wiring
    /// correctness must be verified out-of-band before bridging real value.
    function setStablecoin(address stablecoin_) external onlyOwner {
        require(stablecoin_ != address(0), ZeroAddress("stablecoin"));
        _requireStablecoinShape(stablecoin_);
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

    /// @inheritdoc IBridgeBurner
    function sendTo(uint256 dstChain, address recipient, uint256 amount) external {
        require(address(stablecoin) != address(0), StablecoinNotSet());
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
