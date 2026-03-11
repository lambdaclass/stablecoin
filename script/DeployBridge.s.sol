// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {Stablecoin} from "src/Stablecoin.sol";
import {BridgeDeploy} from "src/bridge/deploy/BridgeDeploy.sol";
import {BridgeConfig} from "src/bridge/deploy/BridgeConfig.sol";

/// @title DeployBridge
/// @notice Deploys and configures all bridge contracts from a TOML configuration file.
/// Usage: forge script script/DeployBridge.s.sol --sig "run(string)" <path-to-config.toml>
contract DeployBridge is Script {
    function run(string memory configPath) public {
        string memory toml = vm.readFile(configPath);

        // Parse core params
        address stablecoinAddr = vm.parseTomlAddress(toml, ".bridge.stablecoin");
        address owner = vm.parseTomlAddress(toml, ".bridge.owner");
        bytes32 baseSalt = vm.parseTomlBytes32(toml, ".bridge.salt");

        // Parse config
        BridgeConfig.Config memory config = _parseConfig(toml);

        vm.startBroadcast();

        BridgeDeploy.Contracts memory contracts = BridgeDeploy.deployAll(baseSalt, owner, stablecoinAddr);
        BridgeConfig.configure(Stablecoin(stablecoinAddr), contracts, config);

        vm.stopBroadcast();

        console.log("Outbox:       ", address(contracts.outbox));
        console.log("Inbox:        ", address(contracts.inbox));
        console.log("BridgeBurner: ", address(contracts.bridgeBurner));
        console.log("BridgeMinter: ", address(contracts.bridgeMinter));
    }

    function _parseConfig(string memory toml) internal pure returns (BridgeConfig.Config memory config) {
        config.threshold = vm.parseTomlUint(toml, ".bridge.inbox.threshold");
        config.attestors = vm.parseTomlAddressArray(toml, ".bridge.inbox.attestors");
        config.minterAllowance = vm.parseTomlUint(toml, ".bridge.minter.allowance");

        // Parse allowed senders
        uint256[] memory srcChains = vm.parseTomlUintArray(toml, ".bridge.allowed_senders.src_chain");
        address[] memory srcSenders = vm.parseTomlAddressArray(toml, ".bridge.allowed_senders.sender");
        require(srcChains.length == srcSenders.length, "allowed_senders length mismatch");

        config.allowedSenders = new BridgeConfig.AllowedSender[](srcChains.length);
        for (uint256 i = 0; i < srcChains.length; i++) {
            config.allowedSenders[i] = BridgeConfig.AllowedSender(srcChains[i], srcSenders[i]);
        }

        // Parse destination minters
        uint256[] memory dstChains = vm.parseTomlUintArray(toml, ".bridge.dst_minters.dst_chain");
        address[] memory dstMinters = vm.parseTomlAddressArray(toml, ".bridge.dst_minters.minter");
        require(dstChains.length == dstMinters.length, "dst_minters length mismatch");

        config.dstMinters = new BridgeConfig.DstMinter[](dstChains.length);
        for (uint256 i = 0; i < dstChains.length; i++) {
            config.dstMinters[i] = BridgeConfig.DstMinter(dstChains[i], dstMinters[i]);
        }
    }
}
