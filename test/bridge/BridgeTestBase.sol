// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.30;

import {Test} from "forge-std/Test.sol";
import {Stablecoin} from "../../src/Stablecoin.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Outbox} from "../../src/bridge/Outbox.sol";
import {Inbox} from "../../src/bridge/Inbox.sol";
import {BridgeBurner} from "../../src/bridge/BridgeBurner.sol";
import {BridgeMinter} from "../../src/bridge/BridgeMinter.sol";
import {BridgeDeploy} from "../../src/bridge/deploy/BridgeDeploy.sol";
import {BridgeConfig} from "../../src/bridge/deploy/BridgeConfig.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/// @notice Base contract for bridge tests. Deploys the stablecoin and bridge contracts,
/// and provides helpers for EIP-712 signing.
contract BridgeTestBase is Test {
    // Arachnid deterministic deployer runtime bytecode
    bytes constant ARACHNID_CODE =
        hex"7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf3";

    address constant ADMIN = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
    address constant BURNER = 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC;
    address constant PAUSER = 0x90F79bf6EB2c4f870365E785982E1f101E93b906;
    address constant FREEZER = 0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65;

    bytes32 constant BASE_SALT = bytes32(uint256(1));

    // Attestor private keys (for EIP-712 signing in tests)
    uint256 constant ATTESTOR_PK_1 = 0xA1;
    uint256 constant ATTESTOR_PK_2 = 0xA2;
    uint256 constant ATTESTOR_PK_3 = 0xA3;

    Stablecoin public stablecoin;
    BridgeDeploy.Contracts public bridge;

    address public attestor1;
    address public attestor2;
    address public attestor3;

    function setUp() public virtual {
        // Derive attestor addresses from private keys
        attestor1 = vm.addr(ATTESTOR_PK_1);
        attestor2 = vm.addr(ATTESTOR_PK_2);
        attestor3 = vm.addr(ATTESTOR_PK_3);

        // Place the Arachnid deployer at its expected address
        vm.etch(BridgeDeploy.ARACHNID, ARACHNID_CODE);

        // Deploy stablecoin
        vm.startPrank(ADMIN);
        Stablecoin impl = new Stablecoin();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeCall(Stablecoin.initialize, ("Stablecoin", "STBL", 6, ADMIN, BURNER, PAUSER, FREEZER))
        );
        stablecoin = Stablecoin(address(proxy));

        // Deploy bridge contracts
        bridge = BridgeDeploy.deployAll(BASE_SALT, ADMIN, address(stablecoin));
        vm.stopPrank();
    }

    // ─── EIP-712 helpers ─────────────────────────────────────────────

    /// @dev Build the EIP-712 digest that the Inbox expects for a given message.
    function _inboxDigest(Inbox inbox, bytes memory message) internal view returns (bytes32) {
        bytes32 structHash = keccak256(message);
        return MessageHashUtils.toTypedDataHash(inbox.domainSeparator(), structHash);
    }

    /// @dev Sign a message with the given private key and return packed 65-byte signature.
    function _sign(uint256 pk, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @dev Create packed signatures from multiple attestors for a message.
    /// The keys must produce signers in ascending address order.
    function _signMessage(Inbox inbox, bytes memory message, uint256[] memory pks)
        internal
        view
        returns (bytes memory signatures)
    {
        bytes32 digest = _inboxDigest(inbox, message);

        // Sort private keys by their derived address (ascending) for the Inbox's duplicate check
        for (uint256 i = 0; i < pks.length; i++) {
            for (uint256 j = i + 1; j < pks.length; j++) {
                if (vm.addr(pks[i]) > vm.addr(pks[j])) {
                    (pks[i], pks[j]) = (pks[j], pks[i]);
                }
            }
        }

        for (uint256 i = 0; i < pks.length; i++) {
            signatures = abi.encodePacked(signatures, _sign(pks[i], digest));
        }
    }

    /// @dev Encode a transport-level message.
    function _encodeMessage(
        uint256 srcChain,
        address srcSender,
        uint256 dstChain,
        address dstRecipient,
        bytes32 nonce,
        bytes memory payload
    ) internal pure returns (bytes memory) {
        return abi.encode(srcChain, srcSender, dstChain, dstRecipient, nonce, payload);
    }
}
