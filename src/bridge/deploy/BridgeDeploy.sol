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
///   6. Bytecode metadata appendix — by default solc appends a CBOR-encoded
///      metadata blob (~53 bytes, includes an IPFS hash of the source files) to
///      the end of every contract's bytecode. The blob's IPFS hash changes with
///      file paths, comments, and any imported library's patch version, even when
///      the executable opcodes are byte-identical. That metadata is part of
///      `creationCode`, so it feeds the CREATE2 hash and a drifting blob silently
///      drifts every proxy address. Foundry strips it via `bytecode_hash = "none"`
///      and `cbor_metadata = false` in `foundry.toml` (both currently set). This
///      MUST stay that way; `BridgeDeployTest.test_CreationCodeHasNoMetadataAppendix`
///      asserts the strip is actually taking effect and fails CI if either setting
///      regresses.
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

    error Create2DeployFailed(bytes32 salt);
    error Create2DeploymentEmpty(bytes32 salt, address deployed);

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

    /// @notice Compute the CREATE2 proxy addresses that `deployAll(baseSalt, owner)`
    /// would produce, WITHOUT performing any deployment.
    /// @dev Pure mirror of `deployAll`'s address derivation. The salt strings, init-code
    /// shapes, and dependency chain (Outbox/Inbox proxies feed BridgeBurner/Minter init
    /// code) MUST stay identical to `_deployOutbox` / `_deployInbox` / `_deployBridgeBurner`
    /// / `_deployBridgeMinter` below. Any change to a salt suffix, initializer signature,
    /// or contract bytecode must be reflected in both places or the two will silently
    /// disagree and `ConfigureBridge` will target the wrong addresses.
    /// @dev Intended for a Safe-driven configure flow where the configure transaction
    /// is built and signed off-chain, separately from the deploy broadcast. See
    /// `script/ConfigureBridge.s.sol`.
    function computeAddresses(bytes32 baseSalt, address owner) internal pure returns (Contracts memory c) {
        address outboxImpl = Create2.computeAddress(
            keccak256(abi.encodePacked(baseSalt, "outbox-impl")), keccak256(type(Outbox).creationCode), ARACHNID
        );
        address outboxProxy = Create2.computeAddress(
            keccak256(abi.encodePacked(baseSalt, "outbox-proxy")),
            keccak256(
                abi.encodePacked(
                    type(ERC1967Proxy).creationCode, abi.encode(outboxImpl, abi.encodeCall(Outbox.initialize, (owner)))
                )
            ),
            ARACHNID
        );
        c.outbox = Outbox(outboxProxy);

        address inboxImpl = Create2.computeAddress(
            keccak256(abi.encodePacked(baseSalt, "inbox-impl")), keccak256(type(Inbox).creationCode), ARACHNID
        );
        address inboxProxy = Create2.computeAddress(
            keccak256(abi.encodePacked(baseSalt, "inbox-proxy")),
            keccak256(
                abi.encodePacked(
                    type(ERC1967Proxy).creationCode, abi.encode(inboxImpl, abi.encodeCall(Inbox.initialize, (owner)))
                )
            ),
            ARACHNID
        );
        c.inbox = Inbox(inboxProxy);

        address burnerImpl = Create2.computeAddress(
            keccak256(abi.encodePacked(baseSalt, "burner-impl")), keccak256(type(BridgeBurner).creationCode), ARACHNID
        );
        address burnerProxy = Create2.computeAddress(
            keccak256(abi.encodePacked(baseSalt, "burner-proxy")),
            keccak256(
                abi.encodePacked(
                    type(ERC1967Proxy).creationCode,
                    abi.encode(burnerImpl, abi.encodeCall(BridgeBurner.initialize, (owner, outboxProxy)))
                )
            ),
            ARACHNID
        );
        c.bridgeBurner = BridgeBurner(burnerProxy);

        address minterImpl = Create2.computeAddress(
            keccak256(abi.encodePacked(baseSalt, "minter-impl")), keccak256(type(BridgeMinter).creationCode), ARACHNID
        );
        address minterProxy = Create2.computeAddress(
            keccak256(abi.encodePacked(baseSalt, "minter-proxy")),
            keccak256(
                abi.encodePacked(
                    type(ERC1967Proxy).creationCode,
                    abi.encode(minterImpl, abi.encodeCall(BridgeMinter.initialize, (owner, inboxProxy)))
                )
            ),
            ARACHNID
        );
        c.bridgeMinter = BridgeMinter(minterProxy);
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
    /// Note on factory absence: on chains where the Arachnid factory is NOT deployed
    /// (notably zkSync Era and freshly-launched L2s before the canonical OZ-blessed
    /// seeding tx is broadcast), `ARACHNID.call(...)` returns `success = true` because
    /// calls to an EOA / empty account succeed. The post-check
    /// `require(deployed.code.length > 0, ...)` is therefore the load-bearing detector
    /// — without it the function would silently return an address with no code.
    function _deploy(bytes32 salt, bytes memory bytecode) private returns (address deployed) {
        deployed = Create2.computeAddress(salt, keccak256(bytecode), ARACHNID);
        (bool success,) = ARACHNID.call(abi.encodePacked(salt, bytecode));
        require(success, Create2DeployFailed(salt));
        require(deployed.code.length > 0, Create2DeploymentEmpty(salt, deployed));
    }
}
