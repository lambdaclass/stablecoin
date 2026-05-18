// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.30;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {Outbox} from "../Outbox.sol";
import {Inbox} from "../Inbox.sol";
import {BridgeBurner} from "../BridgeBurner.sol";
import {BridgeMinter} from "../BridgeMinter.sol";

/// @title BridgeDeploy
/// @notice Deploys all bridge contracts (implementation + ERC1967Proxy) via the Arachnid
/// deterministic CREATE2 deployer, producing identical addresses across all EVM chains
/// — provided the deployer aligns every input the CREATE2 address depends on (see dev
/// note below).
///
/// @dev The BridgeBurner / BridgeMinter initializers no longer take the stablecoin
/// address — that decoupling is what makes their CREATE2 addresses independent of
/// the (chain-specific) stablecoin proxy address. The deployer is responsible for
/// calling `setStablecoin` on both contracts after `deployAll` returns;
/// `BridgeConfig.configure` does this automatically.
///
/// @dev Cross-chain address invariance requires aligning EVERY input to the CREATE2
/// derivation. For each chain the bridge is deployed to, the following must be
/// byte-identical:
///
///   1. The Arachnid factory address (`0x4e59…4956C`). Present on most major EVM
///      chains via the canonical OZ-blessed transaction; absent on chains with
///      non-standard CREATE2 (notably zkSync Era) and on some new L2s until the
///      factory is manually seeded. Verify before deploying.
///   2. `baseSalt` — the operator-supplied salt.
///   3. `owner` — the address of the owner contract. Crucially, `owner` is encoded
///      into the BridgeBurner/Minter proxy init code via `abi.encodeCall(initialize,
///      (owner, …))`, so a different `owner` per chain ⇒ different proxy addresses
///      per chain. If `owner` is a Safe, the Safe itself must be deployed at the
///      same address on every chain (use the same SafeProxyFactory `(singleton,
///      owners[], threshold, fallbackHandler, saltNonce)` tuple).
///   4. Outbox/Inbox implementations and proxies (these are *also* deployed here via
///      CREATE2 and encode `owner` into their init code; their addresses feed into
///      BridgeBurner/Minter's init code as `outbox`/`inbox`). Determinism therefore
///      cascades: a wrong `owner` poisons Outbox/Inbox addresses, which in turn
///      poison BridgeBurner/Minter addresses.
///   5. Compiler version + optimizer settings — these change `type(Outbox).creationCode`,
///      `type(Inbox).creationCode`, `type(BridgeBurner).creationCode`,
///      `type(BridgeMinter).creationCode`, and `type(ERC1967Proxy).creationCode`,
///      all of which are inputs to the CREATE2 hash. Pin `foundry.toml`'s
///      `solc_version` and `optimizer` settings identically across deployment hosts.
///
/// If any of those diverges, the BridgeBurner/Minter addresses diverge per chain
/// and the cross-chain `allowed_senders` / `dst_minters` configuration in
/// `bridge-config.example.toml` becomes wrong. Misconfigured routing causes
/// `BridgeMinter.handleMessage` to reject inbound messages with `DisallowedSender`
/// AFTER `BridgeBurner.sendTo` has already burned the user's tokens, stranding
/// funds until the configuration is corrected and the attestor flow retries the
/// message.
library BridgeDeploy {
    address constant ARACHNID = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    struct Contracts {
        Outbox outbox;
        Inbox inbox;
        BridgeBurner bridgeBurner;
        BridgeMinter bridgeMinter;
    }

    /// @notice Deploy all bridge contracts using deterministic CREATE2 addresses.
    /// @dev The stablecoin address is intentionally not a parameter — see contract-level
    /// dev note. Configure the stablecoin on the returned contracts via `setStablecoin`
    /// (or use `BridgeConfig.configure`, which handles it for you).
    /// @dev For the returned addresses to match the addresses produced by this same
    /// call on a different chain, `baseSalt` AND `owner` MUST be byte-identical across
    /// chains, and the contract bytecode must match (same compiler / optimizer settings).
    /// See the contract-level dev note for the full list of determinism preconditions.
    /// @param baseSalt Base salt from which per-contract salts are derived. Must match
    /// across chains.
    /// @param owner Owner of all bridge contracts (can upgrade and configure). Must match
    /// across chains — encoded into every proxy's init code, so any divergence yields
    /// chain-specific BridgeBurner / BridgeMinter / Outbox / Inbox addresses.
    function deployAll(bytes32 baseSalt, address owner) internal returns (Contracts memory c) {
        c.outbox = _deployOutbox(baseSalt, owner);
        c.inbox = _deployInbox(baseSalt, owner);
        c.bridgeBurner = _deployBridgeBurner(baseSalt, owner, address(c.outbox));
        c.bridgeMinter = _deployBridgeMinter(baseSalt, owner, address(c.inbox));
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

    function _deployBridgeBurner(bytes32 baseSalt, address owner, address outbox) private returns (BridgeBurner) {
        address impl = _deploy(keccak256(abi.encodePacked(baseSalt, "burner-impl")), type(BridgeBurner).creationCode);
        address proxy = _deploy(
            keccak256(abi.encodePacked(baseSalt, "burner-proxy")),
            abi.encodePacked(
                type(ERC1967Proxy).creationCode,
                abi.encode(impl, abi.encodeCall(BridgeBurner.initialize, (owner, outbox)))
            )
        );
        return BridgeBurner(proxy);
    }

    function _deployBridgeMinter(bytes32 baseSalt, address owner, address inbox) private returns (BridgeMinter) {
        address impl = _deploy(keccak256(abi.encodePacked(baseSalt, "minter-impl")), type(BridgeMinter).creationCode);
        address proxy = _deploy(
            keccak256(abi.encodePacked(baseSalt, "minter-proxy")),
            abi.encodePacked(
                type(ERC1967Proxy).creationCode,
                abi.encode(impl, abi.encodeCall(BridgeMinter.initialize, (owner, inbox)))
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
