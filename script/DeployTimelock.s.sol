// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

/// @notice Deploys an OpenZeppelin TimelockController suitable for holding
/// `ADMIN_ROLE` on the Stablecoin contract. Any ADMIN_ROLE grant or revocation
/// (including rotation to a new TimelockController) must then be proposed,
/// wait `minDelay` seconds, and be executed, giving the team a window to
/// detect and cancel a hostile rotation before it lands on-chain.
///
/// `proposers` are the addresses (typically the team multisig) that can
/// schedule operations; `executors` are the addresses that can execute a
/// matured operation (use `address(0)` in `executors` to allow anyone — open
/// execution removes the need for a privileged executor keychain).
///
/// The TimelockController's own admin is left as `address(0)` so that the
/// timelock administers itself via timelocked operations. This matches the
/// recommended OpenZeppelin pattern for governance contracts.
///
/// Usage:
///   forge script script/DeployTimelock.s.sol \
///       --broadcast --private-key $DEPLOYER_KEY --rpc-url $RPC_URL \
///       --sig 'run(uint256,address[],address[])' \
///       $MIN_DELAY_SECONDS $PROPOSERS_ARRAY $EXECUTORS_ARRAY
///
/// The deployed address can then be passed as `admin` to DeployStablecoin.s.sol.
contract DeployTimelock is Script {
    function run(uint256 minDelay, address[] memory proposers, address[] memory executors) public {
        vm.startBroadcast();
        // admin = address(0) means the timelock is its own admin; rotations of
        // the proposer/executor sets must be timelocked.
        TimelockController timelock = new TimelockController(minDelay, proposers, executors, address(0));
        vm.stopBroadcast();

        console.log("TimelockController deployed at:", address(timelock));
        console.log("Min delay (seconds):", minDelay);
        console.log("Proposer count:", proposers.length);
        console.log("Executor count (0 means open execution):", executors.length);
    }
}
