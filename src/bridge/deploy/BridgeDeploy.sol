// SPDX-License-Identifier: Apache-2.0
pragma solidity =0.8.30;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {Outbox} from "../Outbox.sol";
import {Inbox} from "../Inbox.sol";
import {BridgeBurner} from "../BridgeBurner.sol";
import {BridgeMinter} from "../BridgeMinter.sol";

/// @title BridgeDeploy
/// @notice Deploys all bridge contracts (implementation + ERC1967Proxy) via the Arachnid
/// deterministic CREATE2 deployer, producing identical addresses across all EVM chains.
library BridgeDeploy {
    address constant ARACHNID = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    struct Contracts {
        Outbox outbox;
        Inbox inbox;
        BridgeBurner bridgeBurner;
        BridgeMinter bridgeMinter;
    }

    /// @notice Deploy all bridge contracts using deterministic CREATE2 addresses.
    /// @param baseSalt Base salt from which per-contract salts are derived.
    /// @param owner Owner of all bridge contracts (can upgrade and configure).
    /// @param stablecoin The stablecoin address (must already be deployed).
    function deployAll(bytes32 baseSalt, address owner, address stablecoin) internal returns (Contracts memory c) {
        c.outbox = _deployOutbox(baseSalt, owner);
        c.inbox = _deployInbox(baseSalt, owner);
        c.bridgeBurner = _deployBridgeBurner(baseSalt, owner, stablecoin, address(c.outbox));
        c.bridgeMinter = _deployBridgeMinter(baseSalt, owner, stablecoin, address(c.inbox));
    }

    function _deployOutbox(bytes32 baseSalt, address owner) private returns (Outbox) {
        address impl = _deploy(keccak256(abi.encodePacked(baseSalt, "outbox-impl")), type(Outbox).creationCode);
        address proxy = _deploy(
            keccak256(abi.encodePacked(baseSalt, "outbox-proxy")),
            abi.encodePacked(
                type(ERC1967Proxy).creationCode, abi.encode(impl, abi.encodeCall(Outbox.initialize, (owner)))
            )
        );
        return Outbox(proxy);
    }

    function _deployInbox(bytes32 baseSalt, address owner) private returns (Inbox) {
        address impl = _deploy(keccak256(abi.encodePacked(baseSalt, "inbox-impl")), type(Inbox).creationCode);
        address proxy = _deploy(
            keccak256(abi.encodePacked(baseSalt, "inbox-proxy")),
            abi.encodePacked(
                type(ERC1967Proxy).creationCode, abi.encode(impl, abi.encodeCall(Inbox.initialize, (owner)))
            )
        );
        return Inbox(proxy);
    }

    function _deployBridgeBurner(bytes32 baseSalt, address owner, address stablecoin, address outbox)
        private
        returns (BridgeBurner)
    {
        address impl = _deploy(keccak256(abi.encodePacked(baseSalt, "burner-impl")), type(BridgeBurner).creationCode);
        address proxy = _deploy(
            keccak256(abi.encodePacked(baseSalt, "burner-proxy")),
            abi.encodePacked(
                type(ERC1967Proxy).creationCode,
                abi.encode(impl, abi.encodeCall(BridgeBurner.initialize, (owner, stablecoin, outbox)))
            )
        );
        return BridgeBurner(proxy);
    }

    function _deployBridgeMinter(bytes32 baseSalt, address owner, address stablecoin, address inbox)
        private
        returns (BridgeMinter)
    {
        address impl = _deploy(keccak256(abi.encodePacked(baseSalt, "minter-impl")), type(BridgeMinter).creationCode);
        address proxy = _deploy(
            keccak256(abi.encodePacked(baseSalt, "minter-proxy")),
            abi.encodePacked(
                type(ERC1967Proxy).creationCode,
                abi.encode(impl, abi.encodeCall(BridgeMinter.initialize, (owner, stablecoin, inbox)))
            )
        );
        return BridgeMinter(proxy);
    }

    /// @dev Deploy bytecode via the Arachnid CREATE2 factory and return the deployed address.
    function _deploy(bytes32 salt, bytes memory bytecode) private returns (address deployed) {
        deployed = Create2.computeAddress(salt, keccak256(bytecode), ARACHNID);
        (bool success,) = ARACHNID.call(abi.encodePacked(salt, bytecode));
        require(success, "BridgeDeploy: CREATE2 failed");
        require(deployed.code.length > 0, "BridgeDeploy: deployment produced no code");
    }
}
