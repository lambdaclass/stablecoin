// SPDX-License-Identifier: Apache-2.0
pragma solidity =0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {Stablecoin} from "src/Stablecoin.sol";
import {Upgrades} from "@openzeppelin-foundry-upgrades/Upgrades.sol";

contract DeployStablecoin is Script {
    error ZeroAddress(bytes32 field);

    function run(
        string memory name,
        string memory symbol,
        uint8 decimals,
        address admin,
        address burner,
        address pauser,
        address freezer
    ) public {
        // Fail fast before encoding the initializer so a typo'd / missing env var
        // doesn't burn gas on a CREATE2 deploy that the contract would revert anyway.
        require(admin != address(0), ZeroAddress("admin"));
        require(burner != address(0), ZeroAddress("burner"));
        require(pauser != address(0), ZeroAddress("pauser"));
        require(freezer != address(0), ZeroAddress("freezer"));

        bytes memory initializerData =
            abi.encodeCall(Stablecoin.initialize, (name, symbol, decimals, admin, burner, pauser, freezer));

        vm.startBroadcast();
        address stablecoin = Upgrades.deployUUPSProxy("Stablecoin.sol", initializerData);
        vm.stopBroadcast();

        console.log("Stablecoin address: ", stablecoin);
    }
}
