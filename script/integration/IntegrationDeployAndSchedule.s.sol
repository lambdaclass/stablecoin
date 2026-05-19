// SPDX-License-Identifier: Apache-2.0
pragma solidity =0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {Upgrades, Options} from "@openzeppelin-foundry-upgrades/Upgrades.sol";
import {Stablecoin} from "../../src/Stablecoin.sol";
import {StablecoinTimelock} from "../../src/StablecoinTimelock.sol";
import {OldStablecoin} from "./OldStablecoin.sol";

/// @notice Step 1 of the upgrade integration test, designed to mirror what a
/// real operator would run against mainnet.
///
/// Deliberately uses the same OpenZeppelin Foundry Upgrades plumbing as
/// `script/DeployStablecoin.s.sol` and `script/UpgradeStablecoin.s.sol`, so
/// the test exercises the same storage-layout safety checks the production
/// scripts rely on.
///
/// Sequence:
///   1. `Upgrades.deployUUPSProxy("OldStablecoin.sol", …)` — deploys the
///      pre-M-01 implementation and an ERC1967 proxy initialized to it. This
///      is identical to how a mainnet stablecoin from `main` was originally
///      deployed.
///   2. Sanity: `addMinter` works via the deployer on the *old* contract.
///   3. `Upgrades.upgradeProxy(proxy, "Stablecoin.sol", reinitData, opts)`
///      with `opts.referenceContract = "OldStablecoin.sol"`. OZ validates the
///      new contract's storage layout against the old one before calling
///      `upgradeToAndCall(newImpl, reinitData)` on the proxy. `reinitData`
///      is `abi.encodeCall(Stablecoin.reinitializeAdminRole, ())` so the slot
///      repair happens atomically with the implementation flip.
///   4. Verify the role-admin storage slot is now self-administering.
///   5. Deploy `StablecoinTimelock` bound to the proxy. `minDelay = 60s`
///      (small for test speed; production should pick 48h+).
///   6. Grant `ADMIN_ROLE` to the timelock. Deployer keeps admin too, so the
///      `_revokeRole` empty-admin guard isn't relevant for the test.
///   7. Schedule `addMinter(beef, 5000e18)` via the timelock.
///
/// State (proxy, timelock, op params) is serialized to
/// `./integration-state.json` for step 2 (`IntegrationExecuteAndVerify`).
contract IntegrationDeployAndSchedule is Script {
    uint256 internal constant MIN_DELAY = 60;
    address internal constant NEW_MINTER = address(0xBEEF);
    uint256 internal constant NEW_CAP = 5_000e18;
    bytes32 internal constant SALT = bytes32(uint256(0xDEADBEEF));

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        vm.startBroadcast(deployerKey);

        // 1. Deploy OldStablecoin behind a UUPS proxy via the OZ helper. This
        //    matches script/DeployStablecoin.s.sol exactly so the integration
        //    test produces the same on-chain shape a real operator would.
        bytes memory initData = abi.encodeCall(
            OldStablecoin.initialize, ("Test Stablecoin", "TSC", 18, deployer, deployer, deployer, deployer)
        );
        address proxyAddr = Upgrades.deployUUPSProxy("OldStablecoin.sol", initData);
        OldStablecoin oldProxy = OldStablecoin(proxyAddr);

        // 2. Sanity check on the old impl.
        oldProxy.addMinter(address(0xCAFE), 100e18);
        require(oldProxy.hasRole(oldProxy.MINTER_ROLE(), address(0xCAFE)), "old addMinter failed");

        // 3. Atomic upgrade + reinit via the OZ helper. With
        //    `referenceContract` set, OZ runs its storage-layout validator on
        //    OldStablecoin → Stablecoin before issuing the upgrade tx. If the
        //    layouts were incompatible, this would revert at simulation time
        //    — exactly the safety net we want operators to have on mainnet.
        bytes memory reinitData = abi.encodeCall(Stablecoin.reinitializeAdminRole, ());
        Options memory opts;
        opts.referenceContract = "OldStablecoin.sol";
        Upgrades.upgradeProxy(proxyAddr, "Stablecoin.sol", reinitData, opts);

        Stablecoin upgraded = Stablecoin(proxyAddr);

        // 4. The slot that `main`'s initialize never set is now self-administering.
        require(upgraded.getRoleAdmin(upgraded.ADMIN_ROLE()) == upgraded.ADMIN_ROLE(), "role admin not repaired");

        // 5. Deploy the timelock with open execution (executor = address(0)).
        address[] memory proposers = new address[](1);
        proposers[0] = deployer;
        address[] memory executors = new address[](1);
        executors[0] = address(0);
        StablecoinTimelock timelock = new StablecoinTimelock(upgraded, MIN_DELAY, proposers, executors, address(0));

        // 6. Hand admin to the timelock. Deployer also retains the role so we
        //    don't have to detour through the timelock for the test itself.
        upgraded.grantRole(upgraded.ADMIN_ROLE(), address(timelock));
        require(upgraded.hasRole(upgraded.ADMIN_ROLE(), address(timelock)), "timelock not granted admin");

        // 7. Schedule an addMinter through the timelock's typed helper.
        timelock.scheduleAddMinter(NEW_MINTER, NEW_CAP, SALT, MIN_DELAY);

        vm.stopBroadcast();

        // Hand off state to step 2.
        string memory json = "integration";
        vm.serializeAddress(json, "proxy", proxyAddr);
        vm.serializeAddress(json, "timelock", address(timelock));
        vm.serializeAddress(json, "newMinter", NEW_MINTER);
        vm.serializeUint(json, "newCap", NEW_CAP);
        vm.serializeBytes32(json, "salt", SALT);
        string memory out = vm.serializeUint(json, "minDelay", MIN_DELAY);
        vm.writeJson(out, "./integration-state.json");

        console.log("=== IntegrationDeployAndSchedule complete ===");
        console.log("proxy:    ", proxyAddr);
        console.log("timelock: ", address(timelock));
        console.log("newMinter:", NEW_MINTER);
        console.log("newCap:   ", NEW_CAP);
        console.log("minDelay: ", MIN_DELAY);
    }
}
