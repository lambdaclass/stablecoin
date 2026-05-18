// SPDX-License-Identifier: Apache-2.0
pragma solidity =0.8.30;

import {BridgeTestBase} from "./BridgeTestBase.sol";
import {BridgeConfig} from "../../src/bridge/deploy/BridgeConfig.sol";

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
}
