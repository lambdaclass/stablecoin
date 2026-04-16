// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {Upgrades, Options} from "@openzeppelin-foundry-upgrades/Upgrades.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Stablecoin} from "src/Stablecoin.sol";

/// @dev Points a UUPS proxy to an already-deployed implementation.
///
/// Use this after deploying the implementation with DeployNewImplementation.s.sol.
/// The broadcaster must hold ADMIN_ROLE on the proxy.
///
/// Usage (with reinitializer calldata):
///   forge clean && forge script script/SwitchImplementation.s.sol \
///       --broadcast --private-key $ADMIN_KEY --rpc-url $RPC_URL \
///       --sig 'run(address,address,bytes,string,string)' \
///       $PROXY $NEW_IMPL $REINIT_DATA "StablecoinV2.sol" "Stablecoin.sol"
///
/// Usage (no reinitializer):
///   forge clean && forge script script/SwitchImplementation.s.sol \
///       --broadcast --private-key $ADMIN_KEY --rpc-url $RPC_URL \
///       --sig 'run(address,address,bytes,string,string)' \
///       $PROXY $NEW_IMPL 0x "StablecoinV2.sol" "Stablecoin.sol"
contract SwitchImplementation is Script {
    function run(
        address proxyAddress,
        address newImplementation,
        bytes memory reinitData,
        string memory contractName,
        string memory referenceContract
    ) public {
        // ── Pre-upgrade checks ──────────────────────────────────
        require(proxyAddress.code.length > 0, "Proxy address has no code");
        require(newImplementation.code.length > 0, "Implementation address has no code");

        address implBefore = Upgrades.getImplementationAddress(proxyAddress);
        require(newImplementation != implBefore, "Proxy already points to this implementation");

        Stablecoin coin = Stablecoin(proxyAddress);
        console.log("Proxy:", proxyAddress);
        console.log("Current implementation:", implBefore);
        console.log("New implementation:", newImplementation);
        console.log("Name:", coin.name());
        console.log("Symbol:", coin.symbol());
        console.log("Total supply:", coin.totalSupply());
        console.log("Reinit data length:", reinitData.length);

        // ── Validate storage layout ───────────────────────────
        Options memory opts;
        opts.referenceContract = referenceContract;
        console.log("Validating storage layout for", contractName);
        Upgrades.validateUpgrade(contractName, opts);
        console.log("Storage layout validation passed");

        // ── Upgrade ─────────────────────────────────────────────
        vm.startBroadcast();
        UUPSUpgradeable(proxyAddress).upgradeToAndCall(newImplementation, reinitData);
        vm.stopBroadcast();

        // ── Post-upgrade checks ─────────────────────────────────
        address implAfter = Upgrades.getImplementationAddress(proxyAddress);
        require(implAfter == newImplementation, "Implementation not updated correctly");

        console.log("");
        console.log("Upgrade complete!");
        console.log("Verified implementation:", implAfter);
        console.log("Name:", coin.name());
        console.log("Total supply:", coin.totalSupply());
    }
}
