// SPDX-License-Identifier: Apache-2.0
pragma solidity =0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {Stablecoin} from "../src/Stablecoin.sol";
import {StablecoinTimelock} from "../src/StablecoinTimelock.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @notice One-shot fixture that stands up a *fresh* Stablecoin + StablecoinTimelock
/// on a local anvil so the ops console can IMPORT the token and exercise the
/// two-phase admin flow (schedule -> wait -> execute, and cancel).
///
/// HARD DESIGN CONSTRAINTS this script is built around:
///
///   1. The ops-console import verifier (Backend.StablecoinImport.Verifier)
///      requires (chain_id, proxy_address, deploy_tx_hash) where deploy_tx_hash
///      is the TOP-LEVEL CREATE tx whose receipt.contractAddress == proxy. So we
///      deploy `ERC1967Proxy` DIRECTLY (a plain `new`, one broadcast CREATE tx
///      from the deployer EOA) rather than via OpenZeppelin's
///      `Upgrades.deployUUPSProxy`. Two payoffs:
///        (a) the proxy's creation tx is a top-level EOA CREATE, so its receipt
///            carries contractAddress == proxy (exactly what the verifier reads),
///        (b) NO OZ Upgrades FFI -> NO Node/npx, NO `forge clean && forge build`
///            full-compilation requirement. This runs in a minimal environment.
///      The trade-off vs. the other integration scripts: we skip the
///      storage-layout safety validator. That validator is about *upgrades*; for
///      a from-scratch fixture deploy there is no reference contract to check
///      against, so skipping it is correct here, not a shortcut.
///
///   2. The impl MUST be the real LambdaClass `Stablecoin` (not a stub) or the
///      ops console indexer + action endpoints — keyed on the Stablecoin ABI —
///      won't operate the imported token. We deploy `new Stablecoin()` for the
///      impl, so this holds.
///
///   3. The timelock must hold ADMIN_ROLE on the proxy and `timelock.stablecoin()`
///      must return the proxy. Both are asserted below.
///
/// PROPOSER / EXECUTOR TOPOLOGY (the two cases the console must cover):
///
///   * EOA-proposer:   proposers = [deployer] (or any EOA), executors = [address(0)]
///                     (open execution — anyone can execute a matured op).
///   * Safe-proposer:  proposers = [safeAddress], executors = [address(0)] (or the
///                     Safe again for a closed-executor topology). The Safe must be
///                     deployed FIRST (see scripts/seed-timelock-fixture.sh, which
///                     deploys it via the SafeProxyFactory on a forked-mainnet
///                     anvil) and its address passed in as a proposer.
///
/// IMPORTANT OZ DETAIL: `TimelockController`'s constructor grants every proposer
/// BOTH `PROPOSER_ROLE` AND `CANCELLER_ROLE`
/// (openzeppelin-contracts/governance/TimelockController.sol:127-128). So whoever
/// is a proposer can also cancel — no extra wiring needed for the cancel path.
///
/// OUTPUT: writes a JSON state file (default ./timelock-fixture-state.json,
/// override with FIXTURE_OUT) with chainId/impl/proxy/timelock/minDelay/
/// proposers/executors. The proxy-creation deploy_tx_hash is NOT knowable from
/// inside the script (forge only exposes the deployed address, not the broadcast
/// tx hash), so the bash wrapper reads it out of
/// broadcast/DeployTimelockFixture.s.sol/<chainId>/run-latest.json — the entry
/// whose contractAddress == proxy. We re-emit `proxy` here so the wrapper can
/// match on it. The wrapper merges deployTxHash into the final state file the
/// ops console consumes.
///
/// PARAMETERS (all via env so the bash wrapper can drive it without --sig juggling):
///   PRIVATE_KEY   (uint)    deployer key; deployer becomes the EOA that signs all
///                           three CREATE txs + the grantRole tx. Also the EOA
///                           proposer in the EOA topology.
///   NAME          (string)  token name        (default "Timelock Pilot")
///   SYMBOL        (string)  token symbol       (default "TLP")
///   DECIMALS      (uint)    token decimals     (default 6)
///   ADMIN         (address) initial ADMIN_ROLE holder  (default = deployer)
///   BURNER        (address) initial BURNER_ROLE holder (default = deployer)
///   PAUSER        (address) initial PAUSER_ROLE holder (default = deployer)
///   FREEZER       (address) initial FREEZER_ROLE holder(default = deployer)
///   MIN_DELAY     (uint)    timelock min delay seconds (default 60)
///   PROPOSER      (address) the single proposer (default = deployer). For the
///                           Safe topology, the wrapper sets this to the Safe addr.
///   EXECUTOR      (address) the single executor (default = address(0) -> open).
///   KEEP_DEPLOYER_ADMIN (bool) if true, deployer KEEPS ADMIN_ROLE alongside the
///                           timelock (handy for local testing so you can also
///                           drive the token directly). If false, ADMIN_ROLE is
///                           moved entirely to the timelock (deployer revokes its
///                           own). Default true.
contract DeployTimelockFixture is Script {
    /// @dev Grouped config keeps `run()`'s live-local count low enough to dodge
    /// solc's "stack too deep" without via-ir (the upstream profile compiles
    /// legacy-codegen). Read once from env, threaded through helpers by ref.
    struct Config {
        uint256 deployerKey;
        address deployer;
        string name;
        string symbol;
        uint8 decimals;
        address admin;
        address burner;
        address pauser;
        address freezer;
        uint256 minDelay;
        address proposer;
        address executor;
        bool keepDeployerAdmin;
    }

    function _readConfig() internal view returns (Config memory c) {
        c.deployerKey = vm.envUint("PRIVATE_KEY");
        c.deployer = vm.addr(c.deployerKey);
        c.name = vm.envOr("NAME", string("Timelock Pilot"));
        c.symbol = vm.envOr("SYMBOL", string("TLP"));
        c.decimals = uint8(vm.envOr("DECIMALS", uint256(6)));
        c.admin = vm.envOr("ADMIN", c.deployer);
        c.burner = vm.envOr("BURNER", c.deployer);
        c.pauser = vm.envOr("PAUSER", c.deployer);
        c.freezer = vm.envOr("FREEZER", c.deployer);
        c.minDelay = vm.envOr("MIN_DELAY", uint256(60));
        c.proposer = vm.envOr("PROPOSER", c.deployer);
        c.executor = vm.envOr("EXECUTOR", address(0));
        c.keepDeployerAdmin = vm.envOr("KEEP_DEPLOYER_ADMIN", true);

        // Fail fast on the inputs `Stablecoin.initialize` would reject anyway,
        // so a typo doesn't burn a CREATE before the revert.
        require(c.admin != address(0), "ADMIN == 0");
        require(c.burner != address(0), "BURNER == 0");
        require(c.pauser != address(0), "PAUSER == 0");
        require(c.freezer != address(0), "FREEZER == 0");
        require(c.proposer != address(0), "PROPOSER == 0 (timelock needs >=1 proposer)");
    }

    function run() external {
        Config memory c = _readConfig();

        vm.startBroadcast(c.deployerKey);

        // ── Leg A: deploy the real Stablecoin implementation (plain CREATE).
        Stablecoin impl = new Stablecoin();

        // ── Leg B: deploy ERC1967Proxy directly, top-level CREATE from the EOA.
        // The proxy's creation tx receipt.contractAddress == address(proxy),
        // which is precisely the deploy_tx_hash + proxy pairing the ops-console
        // import verifier requires. initialize(...) runs inside the proxy ctor.
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeCall(
                Stablecoin.initialize, (c.name, c.symbol, c.decimals, c.admin, c.burner, c.pauser, c.freezer)
            )
        );
        Stablecoin token = Stablecoin(address(proxy));

        // ── Deploy the timelock bound to the proxy. One proposer, one executor
        // slot (executor == address(0) => open execution). admin arg = address(0)
        // so the timelock self-administers (standard OZ pattern; also what
        // DeployTimelock.s.sol does).
        StablecoinTimelock timelock = _deployTimelock(token, c);

        // ── Hand ADMIN_ROLE to the timelock so it can execute matured ops.
        token.grantRole(token.ADMIN_ROLE(), address(timelock));

        // ── Optionally move admin entirely off the deployer EOA. We only do
        // this when the deployer is itself an admin (i.e. ADMIN == deployer);
        // otherwise there's nothing on the deployer to revoke.
        if (!c.keepDeployerAdmin && token.hasRole(token.ADMIN_ROLE(), c.deployer)) {
            token.revokeRole(token.ADMIN_ROLE(), c.deployer);
        }

        vm.stopBroadcast();

        _assertWiring(impl, proxy, timelock, token, c.proposer);
        _writeState(impl, proxy, timelock, c);
    }

    function _deployTimelock(Stablecoin token, Config memory c) internal returns (StablecoinTimelock) {
        address[] memory proposers = new address[](1);
        proposers[0] = c.proposer;
        address[] memory executors = new address[](1);
        executors[0] = c.executor;
        return new StablecoinTimelock(token, c.minDelay, proposers, executors, address(0));
    }

    function _assertWiring(
        Stablecoin impl,
        ERC1967Proxy proxy,
        StablecoinTimelock timelock,
        Stablecoin token,
        address proposer
    ) internal view {
        // vm.getDeployedCode-style code checks + role/binding invariants.
        require(address(impl).code.length > 0, "impl has no code");
        require(address(proxy).code.length > 0, "proxy has no code");
        require(address(timelock).code.length > 0, "timelock has no code");
        require(address(timelock.stablecoin()) == address(proxy), "timelock not bound to proxy");
        require(token.hasRole(token.ADMIN_ROLE(), address(timelock)), "timelock missing ADMIN_ROLE");
        // Proposer holds PROPOSER_ROLE *and* CANCELLER_ROLE (OZ grants both).
        require(timelock.hasRole(timelock.PROPOSER_ROLE(), proposer), "proposer missing PROPOSER_ROLE");
        require(timelock.hasRole(timelock.CANCELLER_ROLE(), proposer), "proposer missing CANCELLER_ROLE");
    }

    function _writeState(Stablecoin impl, ERC1967Proxy proxy, StablecoinTimelock timelock, Config memory c)
        internal
    {
        // ── Serialize state. deployTxHash is filled in by the bash wrapper from
        // run-latest.json; we write a placeholder so the schema is stable.
        string memory json = "fixture";
        vm.serializeUint(json, "chainId", block.chainid);
        vm.serializeAddress(json, "impl", address(impl));
        vm.serializeAddress(json, "proxy", address(proxy));
        vm.serializeAddress(json, "timelock", address(timelock));
        vm.serializeAddress(json, "deployer", c.deployer);
        vm.serializeAddress(json, "proposer", c.proposer);
        vm.serializeAddress(json, "executor", c.executor);
        vm.serializeUint(json, "minDelay", c.minDelay);
        // Placeholder; wrapper overwrites with the real proxy-creation tx hash.
        string memory out = vm.serializeString(json, "deployTxHash", "0xFILL_FROM_RUN_LATEST");

        string memory outPath = vm.envOr("FIXTURE_OUT", string("./timelock-fixture-state.json"));
        vm.writeJson(out, outPath);

        console.log("=== DeployTimelockFixture complete ===");
        console.log("chainId:  ", block.chainid);
        console.log("impl:     ", address(impl));
        console.log("proxy:    ", address(proxy));
        console.log("timelock: ", address(timelock));
        console.log("proposer: ", c.proposer);
        console.log("executor: ", c.executor);
        console.log("minDelay: ", c.minDelay);
        console.log("state ->  ", outPath);
        console.log("NOTE: deployTxHash placeholder written; wrapper fills it from run-latest.json");
    }
}
