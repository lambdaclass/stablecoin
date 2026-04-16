// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {Upgrades, Options} from "@openzeppelin-foundry-upgrades/Upgrades.sol";

/// @dev Deploys a new implementation contract for a multisig upgrade flow.
///
/// The multisig (Safe) admin calls `upgradeToAndCall` separately.
///
/// Usage:
///   forge clean && forge script script/DeployNewImplementation.s.sol \
///       --broadcast --private-key $DEPLOYER_KEY --rpc-url $RPC_URL \
///       --sig 'run(string,string)' "StablecoinV2.sol" "Stablecoin.sol"
contract DeployNewImplementation is Script {
    function run(string memory contractName, string memory referenceContract) public {
        Options memory opts;
        opts.referenceContract = referenceContract;

        // 1. Validate storage layout (reverts on incompatibility)
        console.log("Validating storage layout for", contractName);
        Upgrades.validateUpgrade(contractName, opts);
        console.log("Storage layout validation passed");

        // 2. Deploy new implementation
        vm.startBroadcast();
        address newImpl = Upgrades.prepareUpgrade(contractName, opts);
        vm.stopBroadcast();

        console.log("New implementation deployed at:", newImpl);
        console.log("");
        console.log("Next steps:");
        console.log("  1. Propose upgradeToAndCall() via your multisig");
        console.log("  2. Target: proxy address");
        console.log("  3. New implementation:", newImpl);
        console.log("  4. Include reinitializer calldata if needed");
    }
}
