// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {Upgrades, Options} from "@openzeppelin-foundry-upgrades/Upgrades.sol";
import {Stablecoin} from "src/Stablecoin.sol";

/// @dev Full upgrade script for when the broadcaster IS the admin (EOA flow).
///
/// Supports dry-run by omitting --broadcast.
///
/// Usage:
///   REINIT_DATA=$(cast calldata "initializeV2(uint256)" $MAX_SUPPLY)
///   forge clean && forge script script/UpgradeStablecoin.s.sol \
///       --broadcast --private-key $ADMIN_KEY --rpc-url $RPC_URL \
///       --sig 'run(address,string,bytes,string)' \
///       $PROXY "StablecoinV2.sol" $REINIT_DATA "Stablecoin.sol"
contract UpgradeStablecoin is Script {
    function run(
        address proxyAddress,
        string memory contractName,
        bytes memory reinitData,
        string memory referenceContract
    ) public {
        // ── Pre-upgrade checks ──────────────────────────────────
        require(proxyAddress.code.length > 0, "Proxy address has no code");

        address implBefore = Upgrades.getImplementationAddress(proxyAddress);
        console.log("Proxy address:", proxyAddress);
        console.log("Current implementation:", implBefore);

        Stablecoin coin = Stablecoin(proxyAddress);
        console.log("Name:", coin.name());
        console.log("Symbol:", coin.symbol());
        console.log("Decimals:", coin.decimals());
        console.log("Total supply:", coin.totalSupply());
        console.log("Paused:", coin.paused());

        // ── Upgrade (validates storage layout automatically) ────
        Options memory opts;
        opts.referenceContract = referenceContract;

        console.log("");
        console.log("Upgrading to", contractName);

        vm.startBroadcast();
        Upgrades.upgradeProxy(proxyAddress, contractName, reinitData, opts);
        vm.stopBroadcast();

        // ── Post-upgrade checks ─────────────────────────────────
        address implAfter = Upgrades.getImplementationAddress(proxyAddress);
        require(implAfter != implBefore, "Implementation address did not change");
        require(implAfter != address(0), "Implementation address is zero");

        console.log("");
        console.log("Upgrade complete!");
        console.log("New implementation:", implAfter);
        console.log("Name:", coin.name());
        console.log("Total supply:", coin.totalSupply());
    }
}
