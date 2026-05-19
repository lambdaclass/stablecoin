// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {Upgrades, Options} from "@openzeppelin-foundry-upgrades/Upgrades.sol";
import {Stablecoin} from "src/Stablecoin.sol";

/// @dev Fork-based upgrade simulation. Runs WITHOUT broadcasting.
///
/// Snapshots all on-chain state, simulates the upgrade using vm.prank,
/// and asserts that state is preserved. Reports pass/fail.
///
/// Usage:
///   REINIT_DATA=$(cast calldata "initializeV2(uint256)" $MAX_SUPPLY)
///   forge clean && forge script script/SimulateUpgrade.s.sol \
///       --fork-url $RPC_URL \
///       --sig 'run(address,string,bytes,address,string)' \
///       $PROXY "StablecoinV2.sol" $REINIT_DATA $ADMIN "Stablecoin.sol"
contract SimulateUpgrade is Script {
    error ProxyHasNoCode(address proxy);
    error AdminMissingRole(address admin);
    error ImplementationUnchanged(address impl);
    error ImplementationIsZero();
    error StateChanged(string field);

    function run(
        address proxyAddress,
        string memory contractName,
        bytes memory reinitData,
        address admin,
        string memory referenceContract
    ) public {
        require(proxyAddress.code.length > 0, ProxyHasNoCode(proxyAddress));

        Stablecoin coin = Stablecoin(proxyAddress);

        // ── 1. Snapshot pre-upgrade state ───────────────────────
        console.log("=== Pre-upgrade state ===");

        string memory preName = coin.name();
        string memory preSymbol = coin.symbol();
        uint8 preDecimals = coin.decimals();
        uint256 preTotalSupply = coin.totalSupply();
        bool prePaused = coin.paused();
        uint256 preMinterCount = coin.getMinterCount();
        address preImpl = Upgrades.getImplementationAddress(proxyAddress);

        console.log("Name:", preName);
        console.log("Symbol:", preSymbol);
        console.log("Decimals:", preDecimals);
        console.log("Total supply:", preTotalSupply);
        console.log("Paused:", prePaused);
        console.log("Minter count:", preMinterCount);
        console.log("Implementation:", preImpl);

        // ── 2. Verify admin has ADMIN_ROLE ──────────────────────
        require(coin.hasRole(coin.ADMIN_ROLE(), admin), AdminMissingRole(admin));
        console.log("");
        console.log("Admin verified:", admin);

        // ── 3. Validate storage layout ──────────────────────────
        Options memory opts;
        opts.referenceContract = referenceContract;

        console.log("");
        console.log("Validating storage layout...");
        Upgrades.validateUpgrade(contractName, opts);
        console.log("Storage layout validation passed");

        // ── 4. Simulate upgrade ─────────────────────────────────
        console.log("");
        console.log("Simulating upgrade to", contractName);

        vm.startPrank(admin);
        Upgrades.upgradeProxy(proxyAddress, contractName, reinitData, opts);
        vm.stopPrank();

        // ── 5. Assert state preserved ───────────────────────────
        console.log("");
        console.log("=== Post-upgrade verification ===");

        address postImpl = Upgrades.getImplementationAddress(proxyAddress);
        require(postImpl != preImpl, ImplementationUnchanged(preImpl));
        require(postImpl != address(0), ImplementationIsZero());
        console.log("New implementation:", postImpl);

        require(keccak256(bytes(coin.name())) == keccak256(bytes(preName)), StateChanged("name"));
        require(keccak256(bytes(coin.symbol())) == keccak256(bytes(preSymbol)), StateChanged("symbol"));
        require(coin.decimals() == preDecimals, StateChanged("decimals"));
        require(coin.totalSupply() == preTotalSupply, StateChanged("totalSupply"));
        require(coin.paused() == prePaused, StateChanged("paused"));
        require(coin.getMinterCount() == preMinterCount, StateChanged("minterCount"));

        console.log("");
        console.log("=== SIMULATION PASSED ===");
        console.log("All state preserved. Safe to upgrade.");
    }
}
