// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.30;

import {BridgeTestBase} from "./BridgeTestBase.sol";
import {BridgeConfig} from "../../src/bridge/deploy/BridgeConfig.sol";
import {BridgeDeploy} from "../../src/bridge/deploy/BridgeDeploy.sol";
import {Stablecoin} from "../../src/Stablecoin.sol";
import {
    ERC1967Proxy
} from "lib/openzeppelin-contracts-upgradeable/lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract BridgeDeployTest is BridgeTestBase {
    function test_DeployProducesInitializedContracts() public view {
        // All proxies should have code
        assertTrue(address(bridge.outbox).code.length > 0, "outbox has no code");
        assertTrue(address(bridge.inbox).code.length > 0, "inbox has no code");
        assertTrue(address(bridge.bridgeBurner).code.length > 0, "bridgeBurner has no code");
        assertTrue(address(bridge.bridgeMinter).code.length > 0, "bridgeMinter has no code");

        // Owner is set correctly on all contracts
        assertEq(bridge.outbox.owner(), ADMIN);
        assertEq(bridge.inbox.owner(), ADMIN);
        assertEq(bridge.bridgeBurner.owner(), ADMIN);
        assertEq(bridge.bridgeMinter.owner(), ADMIN);

        // BridgeBurner has correct references
        assertEq(address(bridge.bridgeBurner.stablecoin()), address(stablecoin));
        assertEq(address(bridge.bridgeBurner.outbox()), address(bridge.outbox));

        // BridgeMinter has correct references
        assertEq(address(bridge.bridgeMinter.stablecoin()), address(stablecoin));
        assertEq(bridge.bridgeMinter.inbox(), address(bridge.inbox));
    }

    function test_ConfigureGrantsRoles() public {
        // Set up config
        address[] memory attestors = new address[](2);
        attestors[0] = attestor1;
        attestors[1] = attestor2;

        BridgeConfig.AllowedSender[] memory allowedSenders = new BridgeConfig.AllowedSender[](1);
        allowedSenders[0] = BridgeConfig.AllowedSender(42, address(0xAAAA));

        BridgeConfig.DstMinter[] memory dstMinters = new BridgeConfig.DstMinter[](1);
        dstMinters[0] = BridgeConfig.DstMinter(42, address(0xBBBB));

        BridgeConfig.Config memory config = BridgeConfig.Config({
            attestors: attestors,
            threshold: 2,
            minterAllowance: 1_000_000e6,
            allowedSenders: allowedSenders,
            dstMinters: dstMinters
        });

        vm.startPrank(ADMIN);
        BridgeConfig.configure(stablecoin, bridge, config);
        vm.stopPrank();

        // Verify roles
        assertTrue(stablecoin.hasRole(stablecoin.BURNER_ROLE(), address(bridge.bridgeBurner)));
        assertTrue(stablecoin.hasRole(stablecoin.MINTER_ROLE(), address(bridge.bridgeMinter)));
        assertEq(stablecoin.minterAllowance(address(bridge.bridgeMinter)), 1_000_000e6);

        // Verify inbox attestors
        assertTrue(bridge.inbox.isAttestor(attestor1));
        assertTrue(bridge.inbox.isAttestor(attestor2));
        assertEq(bridge.inbox.threshold(), 2);

        // Verify allowed senders
        assertEq(bridge.bridgeMinter.allowedSenders(42), address(0xAAAA));

        // Verify dst minters
        assertEq(bridge.bridgeBurner.dstMinters(42), address(0xBBBB));
    }

    // ─── Deterministic address invariant (M-02 / #2) ─────────────────

    function test_BridgeBurnerMinterAddressesIndependentOfStablecoin() public {
        // The base bridge in setUp() was deployed via BridgeDeploy.deployAll, which
        // (after the M-02 fix) no longer encodes the stablecoin address into the
        // BridgeBurner / BridgeMinter proxy creation bytecode. The proxies' CREATE2
        // addresses are therefore a pure function of (Arachnid, salt, owner, outbox/inbox)
        // and do NOT depend on which stablecoin is later wired in.
        //
        // Demonstration: swap to a freshly-deployed alternate stablecoin via
        // setStablecoin and verify the proxy addresses are unchanged.
        address baseBurner = address(bridge.bridgeBurner);
        address baseMinter = address(bridge.bridgeMinter);

        vm.startPrank(ADMIN);
        Stablecoin altImpl = new Stablecoin();
        ERC1967Proxy altProxy = new ERC1967Proxy(
            address(altImpl),
            abi.encodeCall(Stablecoin.initialize, ("AltStablecoin", "ALT", 6, ADMIN, BURNER, PAUSER, FREEZER))
        );
        Stablecoin altStablecoin = Stablecoin(address(altProxy));

        bridge.bridgeBurner.setStablecoin(address(altStablecoin));
        bridge.bridgeMinter.setStablecoin(address(altStablecoin));
        vm.stopPrank();

        // Proxy addresses are unchanged; only the in-storage stablecoin reference moved.
        assertEq(address(bridge.bridgeBurner), baseBurner);
        assertEq(address(bridge.bridgeMinter), baseMinter);
        assertEq(address(bridge.bridgeBurner.stablecoin()), address(altStablecoin));
        assertEq(address(bridge.bridgeMinter.stablecoin()), address(altStablecoin));
    }

    function test_DifferentSaltsYieldDifferentAddresses() public {
        // Sanity: salt actually matters, so the determinism above is non-vacuous.
        BridgeDeploy.Contracts memory other = BridgeDeploy.deployAll(bytes32(uint256(uint256(BASE_SALT) + 1)), ADMIN);
        assertTrue(address(other.bridgeBurner) != address(bridge.bridgeBurner));
        assertTrue(address(other.bridgeMinter) != address(bridge.bridgeMinter));
        assertTrue(address(other.outbox) != address(bridge.outbox));
        assertTrue(address(other.inbox) != address(bridge.inbox));
    }
}
