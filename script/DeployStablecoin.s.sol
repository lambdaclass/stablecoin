// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {Stablecoin} from "src/Stablecoin.sol";
import {Upgrades} from "@openzeppelin-foundry-upgrades/Upgrades.sol";

contract DeployStablecoin is Script {
    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        string memory name = vm.envString("STABLECOIN_NAME");
        string memory symbol = vm.envString("STABLECOIN_SYMBOL");
        address admin = vm.envAddress("ADMIN_ADDRESS");
        address burner = vm.envAddress("BURNER_ADDRESS");
        address pauser = vm.envAddress("PAUSER_ADDRESS");
        address freezer = vm.envAddress("FREEZER_ADDRESS");

        bytes memory initializerData =
            abi.encodeCall(Stablecoin.initialize, (name, symbol, admin, burner, pauser, freezer));
        vm.startBroadcast(deployerPrivateKey);
        address stablecoin = Upgrades.deployUUPSProxy("Stablecoin.sol", initializerData);
        vm.stopBroadcast();

        console.log("Stablecoin address: ", stablecoin);
    }
}
