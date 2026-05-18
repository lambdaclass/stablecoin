// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {Stablecoin} from "../src/Stablecoin.sol";
import {StablecoinTimelock} from "../src/StablecoinTimelock.sol";

/// @notice Deploys a `StablecoinTimelock` suitable for holding `ADMIN_ROLE` on
/// the given Stablecoin proxy. The deployed timelock has `address(0)` as its
/// own admin so it administers itself via timelocked operations (standard OZ
/// pattern). It is bound at construction to a single Stablecoin and exposes
/// typed `schedule*` helpers for every ADMIN_ROLE-gated operation.
///
/// `proposers` are the addresses (typically the team multisig) that can
/// schedule operations; `executors` are the addresses that can execute a
/// matured operation (use `address(0)` in `executors` to allow anyone — open
/// execution removes the need for a privileged executor keychain).
///
/// Usage:
///   forge script script/DeployTimelock.s.sol \
///       --broadcast --private-key $DEPLOYER_KEY --rpc-url $RPC_URL \
///       --sig 'run(address,uint256,address[],address[])' \
///       $STABLECOIN $MIN_DELAY_SECONDS $PROPOSERS_ARRAY $EXECUTORS_ARRAY
///
/// The deployed timelock address can then be passed as `admin` to
/// DeployStablecoin.s.sol (fresh stablecoin), or granted ADMIN_ROLE from the
/// current admin (already-deployed stablecoin).
contract DeployTimelock is Script {
    function run(address stablecoin, uint256 minDelay, address[] memory proposers, address[] memory executors) public {
        require(stablecoin != address(0), "DeployTimelock: stablecoin == address(0)");

        vm.startBroadcast();
        StablecoinTimelock timelock =
            new StablecoinTimelock(Stablecoin(stablecoin), minDelay, proposers, executors, address(0));
        vm.stopBroadcast();

        console.log("StablecoinTimelock deployed at:", address(timelock));
        console.log("Bound stablecoin:", stablecoin);
        console.log("Min delay (seconds):", minDelay);
        console.log("Proposer count:", proposers.length);
        console.log("Executor count (0 means open execution):", executors.length);
    }
}
