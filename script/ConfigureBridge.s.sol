// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {Stablecoin} from "src/Stablecoin.sol";
import {BridgeDeploy} from "src/bridge/deploy/BridgeDeploy.sol";
import {BridgeConfig} from "src/bridge/deploy/BridgeConfig.sol";

/// @title ConfigureBridge
/// @notice Configures already-deployed bridge contracts from a TOML configuration file.
/// Must be run as the bridge owner (the address passed to `DeployBridge`) AND that
/// address must hold `ADMIN_ROLE` on the configured stablecoin.
///
/// @dev INTENDED EXECUTION MODEL
///
/// In production the bridge `owner` and the stablecoin `ADMIN_ROLE` holder are usually
/// the same Safe / multisig. This script is therefore meant to be executed via the
/// Safe transaction-builder flow:
///
///   forge script script/ConfigureBridge.s.sol \
///     --sig "run(string)" <path-to-config.toml> \
///     --rpc-url <RPC> --sender $SAFE_ADDRESS
///
/// With `--sender $SAFE_ADDRESS` and no `--broadcast`, forge simulates the script as
/// if the Safe sent the transactions and writes the resulting transaction data to
/// `broadcast/ConfigureBridge.s.sol/<chainId>/dry-run/run-latest.json`. That JSON can
/// be converted to a Safe-tx-builder bundle for signer review and on-chain execution.
///
/// In dev (Anvil) where deployer == owner == admin, the same script can be run with
/// `--broadcast --private-key $DEPLOYER_PK` to apply the configuration directly.
///
/// @dev ADDRESS RESOLUTION
///
/// This script does NOT read deployed contract addresses from the TOML. It re-derives
/// them from `(salt, owner)` via `BridgeDeploy.computeAddresses`, leveraging the same
/// CREATE2 determinism that makes addresses identical across chains. This eliminates
/// an entire class of operator error (pasting the wrong address from chain B into
/// chain A's config) and also doubles as a deployment-success check: every computed
/// address must have nonzero code, otherwise the configure transaction would silently
/// no-op the role grants for non-existent contracts.
contract ConfigureBridge is Script {
    error DeploymentMissing(string contractName, address expected);
    error AllowedSendersLengthMismatch(uint256 chainCount, uint256 senderCount);
    error DstMintersLengthMismatch(uint256 chainCount, uint256 minterCount);

    function run(string memory configPath) public {
        string memory toml = vm.readFile(configPath);

        address stablecoinAddr = vm.parseTomlAddress(toml, ".bridge.stablecoin");
        address owner = vm.parseTomlAddress(toml, ".bridge.owner");
        bytes32 baseSalt = vm.parseTomlBytes32(toml, ".bridge.salt");

        BridgeConfig.Config memory config = _parseConfig(toml);

        // Re-derive the deployed contract addresses from (salt, owner) and assert
        // each one is actually deployed before we try to call onlyOwner setters on it.
        BridgeDeploy.Contracts memory contracts = BridgeDeploy.computeAddresses(baseSalt, owner);
        _assertDeployed("Outbox", address(contracts.outbox));
        _assertDeployed("Inbox", address(contracts.inbox));
        _assertDeployed("BridgeBurner", address(contracts.bridgeBurner));
        _assertDeployed("BridgeMinter", address(contracts.bridgeMinter));
        _assertDeployed("Stablecoin", stablecoinAddr);

        console.log("Configuring bridge against:");
        console.log("  Stablecoin:    ", stablecoinAddr);
        console.log("  Outbox:        ", address(contracts.outbox));
        console.log("  Inbox:         ", address(contracts.inbox));
        console.log("  BridgeBurner:  ", address(contracts.bridgeBurner));
        console.log("  BridgeMinter:  ", address(contracts.bridgeMinter));

        vm.startBroadcast();
        BridgeConfig.configure(Stablecoin(stablecoinAddr), contracts, config);
        vm.stopBroadcast();
    }

    function _assertDeployed(string memory name, address target) internal view {
        require(target.code.length > 0, DeploymentMissing(name, target));
    }

    function _parseConfig(string memory toml) internal pure returns (BridgeConfig.Config memory config) {
        config.threshold = vm.parseTomlUint(toml, ".bridge.inbox.threshold");
        config.attestors = vm.parseTomlAddressArray(toml, ".bridge.inbox.attestors");
        config.minterAllowance = vm.parseTomlUint(toml, ".bridge.minter.allowance");

        uint256[] memory srcChains = vm.parseTomlUintArray(toml, ".bridge.allowed_senders.src_chain");
        address[] memory srcSenders = vm.parseTomlAddressArray(toml, ".bridge.allowed_senders.sender");
        require(srcChains.length == srcSenders.length, AllowedSendersLengthMismatch(srcChains.length, srcSenders.length));

        config.allowedSenders = new BridgeConfig.AllowedSender[](srcChains.length);
        for (uint256 i = 0; i < srcChains.length; i++) {
            config.allowedSenders[i] = BridgeConfig.AllowedSender(srcChains[i], srcSenders[i]);
        }

        uint256[] memory dstChains = vm.parseTomlUintArray(toml, ".bridge.dst_minters.dst_chain");
        address[] memory dstMinters = vm.parseTomlAddressArray(toml, ".bridge.dst_minters.minter");
        require(dstChains.length == dstMinters.length, DstMintersLengthMismatch(dstChains.length, dstMinters.length));

        config.dstMinters = new BridgeConfig.DstMinter[](dstChains.length);
        for (uint256 i = 0; i < dstChains.length; i++) {
            config.dstMinters[i] = BridgeConfig.DstMinter(dstChains[i], dstMinters[i]);
        }
    }
}
