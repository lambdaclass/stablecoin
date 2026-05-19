// SPDX-License-Identifier: Apache-2.0
pragma solidity =0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {BridgeDeploy} from "src/bridge/deploy/BridgeDeploy.sol";

/// @title DeployBridge
/// @notice Deploys all bridge contracts (Outbox, Inbox, BridgeBurner, BridgeMinter) via
/// the Arachnid CREATE2 factory to deterministic addresses. Does NOT configure them
/// — see `ConfigureBridge.s.sol` for the configure step.
///
/// @dev DEPLOY/CONFIGURE SPLIT — IMPORTANT
///
/// The deploy and configure steps are intentionally split into two scripts because the
/// configure step calls `onlyOwner` functions on the bridge contracts AND `ADMIN_ROLE`-
/// gated functions on the stablecoin. In production both of those are typically held
/// by a Safe / multisig, while the deploy broadcast is a single EOA. A combined
/// "deploy + configure" broadcast can only work if the broadcaster IS the owner — that
/// holds in dev (Anvil account #0 is both) but breaks in production.
///
/// Splitting also preserves cross-chain address determinism: `owner` is encoded into
/// every proxy's init code, so a "deploy with owner = EOA, then transferOwnership to
/// Safe" workaround would yield a different CREATE2 address per chain (see BridgeDeploy
/// dev note). With this split, `owner` is the Safe from t=0, identical on every chain.
///
/// Usage:
///   forge script script/DeployBridge.s.sol \
///     --sig "run(string)" <path-to-config.toml> \
///     --rpc-url <RPC> --broadcast --private-key $DEPLOYER_PK
contract DeployBridge is Script {
    function run(string memory configPath) public {
        string memory toml = vm.readFile(configPath);

        address owner = vm.parseTomlAddress(toml, ".bridge.owner");
        bytes32 baseSalt = vm.parseTomlBytes32(toml, ".bridge.salt");

        vm.startBroadcast();
        BridgeDeploy.Contracts memory contracts = BridgeDeploy.deployAll(baseSalt, owner);
        vm.stopBroadcast();

        console.log("Outbox:       ", address(contracts.outbox));
        console.log("Inbox:        ", address(contracts.inbox));
        console.log("BridgeBurner: ", address(contracts.bridgeBurner));
        console.log("BridgeMinter: ", address(contracts.bridgeMinter));
        console.log("");
        console.log("Next step: run ConfigureBridge.s.sol from the owner (Safe) to wire");
        console.log("the stablecoin, attestors, allowed senders, and destination minters.");
    }
}
