// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {Stablecoin} from "../../src/Stablecoin.sol";
import {StablecoinTimelock} from "../../src/StablecoinTimelock.sol";

/// @notice Step 2 of the upgrade integration test.
///
/// Reads `./integration-state.json` written by `IntegrationDeployAndSchedule`,
/// executes the matured `addMinter` operation through the timelock, and
/// asserts the final on-chain state. The bash orchestrator advances anvil's
/// clock past `minDelay` between step 1 and step 2 via `cast rpc
/// evm_increaseTime`.
contract IntegrationExecuteAndVerify is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");

        string memory state = vm.readFile("./integration-state.json");
        address proxyAddr = vm.parseJsonAddress(state, ".proxy");
        address timelockAddr = vm.parseJsonAddress(state, ".timelock");
        address newMinter = vm.parseJsonAddress(state, ".newMinter");
        uint256 newCap = vm.parseJsonUint(state, ".newCap");
        bytes32 salt = vm.parseJsonBytes32(state, ".salt");

        Stablecoin sc = Stablecoin(proxyAddr);
        StablecoinTimelock tl = StablecoinTimelock(payable(timelockAddr));

        vm.startBroadcast(deployerKey);

        // Reconstruct the same calldata the typed helper scheduled.
        bytes memory data = abi.encodeCall(Stablecoin.addMinter, (newMinter, newCap));
        tl.execute(proxyAddr, 0, data, bytes32(0), salt);

        vm.stopBroadcast();

        // Post-conditions: minter role granted with the expected allowance,
        // and admin set unchanged from step 1 (deployer + timelock, count 2).
        require(sc.hasRole(sc.MINTER_ROLE(), newMinter), "MINTER_ROLE not granted to newMinter");
        require(sc.minterAllowance(newMinter) == newCap, "minter allowance mismatch");
        require(sc.getRoleMemberCount(sc.ADMIN_ROLE()) == 2, "unexpected admin set size");
        require(sc.hasRole(sc.ADMIN_ROLE(), timelockAddr), "timelock lost ADMIN_ROLE");

        console.log("=== IntegrationExecuteAndVerify PASSED ===");
        console.log("MINTER_ROLE holder:", newMinter);
        console.log("allowance:         ", sc.minterAllowance(newMinter));
        console.log("admin set size:    ", sc.getRoleMemberCount(sc.ADMIN_ROLE()));
    }
}
