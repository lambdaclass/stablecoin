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

        // Deploy new implementation. prepareUpgrade runs validateUpgrade internally and
        // reverts on storage-layout incompatibility, so an explicit prior call would be
        // redundant.
        console.log("Validating storage layout and deploying new implementation for", contractName);
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
