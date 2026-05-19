// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.30;

import {BridgeTestBase} from "./BridgeTestBase.sol";
import {BridgeConfig} from "../../src/bridge/deploy/BridgeConfig.sol";
import {BridgeDeploy} from "../../src/bridge/deploy/BridgeDeploy.sol";
import {BridgeBurner} from "../../src/bridge/BridgeBurner.sol";
import {BridgeMinter} from "../../src/bridge/BridgeMinter.sol";
import {Outbox} from "../../src/bridge/Outbox.sol";
import {Inbox} from "../../src/bridge/Inbox.sol";
import {Stablecoin} from "../../src/Stablecoin.sol";
import {TokenMintMessage} from "../../src/bridge/TokenMintMessage.sol";
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

    // ─── computeAddresses ↔ deployAll correspondence ──────────────────
    //
    // `computeAddresses` is the source of truth for ConfigureBridge — it derives the
    // proxy addresses purely (no chain RPC, no deployment) from (salt, owner). If the
    // derivation ever diverges from `deployAll`, ConfigureBridge will silently target
    // wrong addresses on production chains. The two functions must agree exactly.

    function test_ComputeAddressesMatchesDeployedAddresses() public view {
        BridgeDeploy.Contracts memory computed = BridgeDeploy.computeAddresses(BASE_SALT, ADMIN);
        assertEq(address(computed.outbox), address(bridge.outbox), "outbox address mismatch");
        assertEq(address(computed.inbox), address(bridge.inbox), "inbox address mismatch");
        assertEq(address(computed.bridgeBurner), address(bridge.bridgeBurner), "bridgeBurner address mismatch");
        assertEq(address(computed.bridgeMinter), address(bridge.bridgeMinter), "bridgeMinter address mismatch");
    }

    function testFuzz_ComputeAddressesMatchesDeployedAddresses(bytes32 salt, address owner) public {
        // Skip the salt we already used in setUp to avoid CREATE2 collisions.
        vm.assume(salt != BASE_SALT);
        vm.assume(owner != address(0));

        BridgeDeploy.Contracts memory computed = BridgeDeploy.computeAddresses(salt, owner);
        BridgeDeploy.Contracts memory deployed = BridgeDeploy.deployAll(salt, owner);

        assertEq(address(computed.outbox), address(deployed.outbox));
        assertEq(address(computed.inbox), address(deployed.inbox));
        assertEq(address(computed.bridgeBurner), address(deployed.bridgeBurner));
        assertEq(address(computed.bridgeMinter), address(deployed.bridgeMinter));
    }

    // ─── Bytecode metadata regression guard ──────────────────────────
    //
    // solc appends a CBOR-encoded metadata blob (~53 bytes, includes an IPFS hash of
    // the source) to every contract's bytecode unless explicitly stripped. The blob's
    // IPFS hash drifts with file paths, comments, and imported-library patch versions,
    // even when the executable opcodes are byte-identical — silently drifting every
    // CREATE2 address. Foundry strips it via `bytecode_hash = "none"` and
    // `cbor_metadata = false` in foundry.toml. This test fails CI if either setting
    // ever regresses, by scanning each bridge contract's creationCode for solc's
    // CBOR-IPFS marker (`0xa2 0x64 "ipfs" 0x58 0x22` = 8 bytes starting any IPFS
    // metadata appendix). The marker is too specific to appear in real opcodes by
    // chance.

    function test_CreationCodeHasNoMetadataAppendix() public pure {
        _assertNoMetadata("Outbox", type(Outbox).creationCode);
        _assertNoMetadata("Inbox", type(Inbox).creationCode);
        _assertNoMetadata("BridgeBurner", type(BridgeBurner).creationCode);
        _assertNoMetadata("BridgeMinter", type(BridgeMinter).creationCode);
    }

    function _assertNoMetadata(string memory name, bytes memory code) internal pure {
        bytes memory marker = hex"a264697066735822"; // CBOR map + "ipfs" key + 34-byte string header
        require(
            !_contains(code, marker),
            string.concat(
                "metadata appendix detected in ",
                name,
                " creationCode - foundry.toml must keep bytecode_hash = \"none\" and cbor_metadata = false"
            )
        );
    }

    function _contains(bytes memory haystack, bytes memory needle) internal pure returns (bool) {
        if (needle.length == 0 || needle.length > haystack.length) return false;
        uint256 limit = haystack.length - needle.length;
        for (uint256 i = 0; i <= limit; i++) {
            bool match_ = true;
            for (uint256 j = 0; j < needle.length; j++) {
                if (haystack[i + j] != needle[j]) {
                    match_ = false;
                    break;
                }
            }
            if (match_) return true;
        }
        return false;
    }

    // ─── Safety net: the StablecoinNotSet guard is what makes the "armed but
    //     unloaded" window between deployAll and setStablecoin safe. Without these
    //     tests, a future refactor that drops the require(address(stablecoin) != 0)
    //     check from sendTo / handleMessage would silently reintroduce M-02 / #2.

    function test_SendToRevertsWhenStablecoinNotSet() public {
        // Fresh deploy with no setStablecoin — stablecoin slot is still address(0).
        BridgeDeploy.Contracts memory fresh = BridgeDeploy.deployAll(bytes32(uint256(uint256(BASE_SALT) + 100)), ADMIN);

        vm.expectRevert(BridgeBurner.StablecoinNotSet.selector);
        fresh.bridgeBurner.sendTo(block.chainid + 1, address(0xBEEF), 1);
    }

    function test_HandleMessageRevertsWhenStablecoinNotSet() public {
        // Fresh deploy with no setStablecoin — stablecoin slot is still address(0).
        BridgeDeploy.Contracts memory fresh = BridgeDeploy.deployAll(bytes32(uint256(uint256(BASE_SALT) + 101)), ADMIN);

        // Spoof a call from the Inbox so the OnlyInbox check passes and we exercise
        // the StablecoinNotSet guard specifically. The handler reverts BEFORE
        // touching allowedSenders, so no further wiring is needed.
        bytes memory payload = TokenMintMessage.encode(address(0xBEEF), 1);
        vm.prank(address(fresh.inbox));
        vm.expectRevert(BridgeMinter.StablecoinNotSet.selector);
        fresh.bridgeMinter.handleMessage(block.chainid + 1, address(0xCAFE), payload);
    }
}
