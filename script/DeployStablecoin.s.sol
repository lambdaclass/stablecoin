// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {Stablecoin} from "src/Stablecoin.sol";
import {Upgrades} from "@openzeppelin-foundry-upgrades/Upgrades.sol";

contract DeployStablecoin is Script {
    function run(
        string memory name,
        string memory symbol,
        uint8 decimals,
        address admin,
        address burner,
        address pauser,
        address freezer
    ) public {
        bytes memory initializerData = abi.encodeCall(
            Stablecoin.initialize, (name, symbol, decimals, admin, burner, pauser, freezer)
        );

        vm.startBroadcast();
        address stablecoin = Upgrades.deployUUPSProxy("Stablecoin.sol", initializerData);
        vm.stopBroadcast();

        console.log("Stablecoin address: ", stablecoin);
    }
}
