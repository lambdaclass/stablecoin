// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {Stablecoin} from "src/Stablecoin.sol";
import {Upgrades} from "@openzeppelin-foundry-upgrades/Upgrades.sol";
import {Options} from "openzeppelin-foundry-upgrades/Options.sol";

contract DeployNewImplementation is Script {
    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        Options memory opts;

        vm.startBroadcast(deployerPrivateKey);
        address newImplementation = Upgrades.prepareUpgrade("Stablecoin.sol", opts);
        vm.stopBroadcast();

        console.log("New Stablecoin implementation deployed at:", newImplementation);
    }
}
