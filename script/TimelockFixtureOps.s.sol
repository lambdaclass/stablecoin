// SPDX-License-Identifier: Apache-2.0
pragma solidity =0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {Stablecoin} from "../src/Stablecoin.sol";
import {StablecoinTimelock} from "../src/StablecoinTimelock.sol";

/// @notice Companion to DeployTimelockFixture.s.sol that drives the two-phase
/// admin flow from an *EOA proposer/executor*. It is the FFI-free, no-Node
/// counterpart to script/integration/IntegrationExecuteAndVerify.s.sol, but
/// generalized to schedule / execute / cancel an `addMinter` via the typed
/// timelock helper.
///
/// This is the upstream-side helper used by the EOA-proposer topology when you
/// want to demonstrate the on-chain timelock cycle directly (without going
/// through the ops console). For the Safe-proposer topology the
/// schedule/cancel/execute calls are SafeTx-wrapped and submitted by the SPA;
/// this script is NOT used there (the backend assembles the SafeTx, the browser
/// signs+execs). See gaps in the runbook.
///
/// THREE entrypoints (pick with --sig):
///
///   schedule()  -> reads FIXTURE_OUT json + MINTER/CAP/SALT env, calls
///                  timelock.scheduleAddMinter(minter, cap, salt, minDelay)
///                  from PRIVATE_KEY (must hold PROPOSER_ROLE).
///   execute()   -> reconstructs the addMinter calldata and calls
///                  timelock.execute(proxy, 0, data, predecessor=0, salt) from
///                  PRIVATE_KEY. Run AFTER advancing anvil time past minDelay.
///                  Asserts the minter role + allowance landed.
///   cancel()    -> recomputes the operation id and calls timelock.cancel(id)
///                  from PRIVATE_KEY (must hold CANCELLER_ROLE — every proposer
///                  does). Asserts the op is no longer pending.
///
/// State is read from FIXTURE_OUT (default ./timelock-fixture-state.json) so the
/// bash wrapper can pass the same file the deploy step wrote.
contract TimelockFixtureOps is Script {
    function _state()
        internal
        view
        returns (Stablecoin token, StablecoinTimelock tl, address minter, uint256 cap, bytes32 salt)
    {
        string memory path = vm.envOr("FIXTURE_OUT", string("./timelock-fixture-state.json"));
        string memory state = vm.readFile(path);
        address proxyAddr = vm.parseJsonAddress(state, ".proxy");
        address timelockAddr = vm.parseJsonAddress(state, ".timelock");

        token = Stablecoin(proxyAddr);
        tl = StablecoinTimelock(payable(timelockAddr));

        // addMinter target params (env-overridable for repeat runs / fresh salts).
        minter = vm.envOr("MINTER", address(0xBEEF));
        cap = vm.envOr("CAP", uint256(5_000e18));
        salt = vm.envOr("SALT", bytes32(uint256(0xDEADBEEF)));
    }

    function schedule() external {
        uint256 key = vm.envUint("PRIVATE_KEY");
        (Stablecoin token, StablecoinTimelock tl, address minter, uint256 cap, bytes32 salt) = _state();
        uint256 delay = tl.getMinDelay();

        vm.startBroadcast(key);
        tl.scheduleAddMinter(minter, cap, salt, delay);
        vm.stopBroadcast();

        bytes memory data = abi.encodeCall(Stablecoin.addMinter, (minter, cap));
        bytes32 id = tl.hashOperation(address(token), 0, data, bytes32(0), salt);
        require(tl.isOperationPending(id), "scheduled op not pending");

        console.log("=== schedule(addMinter) queued ===");
        console.log("opId:");
        console.logBytes32(id);
        console.log("minter:", minter);
        console.log("cap:   ", cap);
        console.log("ready at (unix):", tl.getTimestamp(id));
    }

    function execute() external {
        uint256 key = vm.envUint("PRIVATE_KEY");
        (Stablecoin token, StablecoinTimelock tl, address minter, uint256 cap, bytes32 salt) = _state();

        bytes memory data = abi.encodeCall(Stablecoin.addMinter, (minter, cap));

        vm.startBroadcast(key);
        tl.execute(address(token), 0, data, bytes32(0), salt);
        vm.stopBroadcast();

        require(token.hasRole(token.MINTER_ROLE(), minter), "MINTER_ROLE not granted");
        require(token.minterAllowance(minter) == cap, "minter allowance mismatch");

        console.log("=== execute(addMinter) PASSED ===");
        console.log("minter:   ", minter);
        console.log("allowance:", token.minterAllowance(minter));
    }

    function cancel() external {
        uint256 key = vm.envUint("PRIVATE_KEY");
        (Stablecoin token, StablecoinTimelock tl, address minter, uint256 cap, bytes32 salt) = _state();

        bytes memory data = abi.encodeCall(Stablecoin.addMinter, (minter, cap));
        bytes32 id = tl.hashOperation(address(token), 0, data, bytes32(0), salt);
        require(tl.isOperation(id), "op does not exist (nothing to cancel)");
        // Cancel is only meaningful BEFORE execution — refuse to "cancel" an op
        // that already ran (isOperationDone), which would otherwise revert in OZ.
        require(!tl.isOperationDone(id), "op already executed (nothing to cancel)");

        vm.startBroadcast(key);
        tl.cancel(id);
        vm.stopBroadcast();

        // The single canonical post-condition: the op is gone from the timelock.
        // We deliberately do NOT assert anything about the minter's role here —
        // the same minter address may already hold MINTER_ROLE from a prior,
        // separately-scheduled-and-executed op (cancel only nullifies THIS
        // pending op, it doesn't revoke unrelated prior grants).
        require(!tl.isOperation(id), "op still exists after cancel");

        console.log("=== cancel(addMinter) done ===");
        console.log("opId:");
        console.logBytes32(id);
        console.log("op exists now:", tl.isOperation(id));
    }
}
