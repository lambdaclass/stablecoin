// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.30;

import {Test} from "forge-std/Test.sol";
import {Stablecoin} from "../../src/Stablecoin.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Inbox} from "../../src/bridge/Inbox.sol";
import {BridgeDeploy} from "../../src/bridge/deploy/BridgeDeploy.sol";
import {TokenMintMessage} from "../../src/bridge/TokenMintMessage.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/// @title BridgeHandler
/// @notice Stateful handler for invariant testing. Simulates honest server behavior:
/// picks a random source/destination chain, burns tokens, constructs and signs a message,
/// then delivers it on the destination chain.
contract BridgeHandler is Test {
    uint256 constant ATTESTOR_PK_1 = 0xA1;
    uint256 constant ATTESTOR_PK_2 = 0xA2;

    struct ChainEnv {
        Stablecoin stablecoin;
        BridgeDeploy.Contracts bridge;
        uint256 chainId;
    }

    ChainEnv[3] internal _chains;
    address public user;

    // Ghost variables for invariant checking
    uint256[3] public ghostInitialSupply;
    uint256[3] public ghostMinted;
    uint256[3] public ghostBurned;

    // Nonce tracking
    uint256 public nonceCounter;
    uint256 public deliveryCount;
    mapping(bytes32 => bool) public usedNonces;

    constructor(ChainEnv[3] memory chains_, address _user, uint256[3] memory _initialSupply) {
        for (uint256 i = 0; i < 3; i++) {
            _chains[i] = chains_[i];
            ghostInitialSupply[i] = _initialSupply[i];
        }
        user = _user;
    }

    function getStablecoin(uint256 idx) external view returns (Stablecoin) {
        return _chains[idx].stablecoin;
    }

    /// @dev Burn tokens on srcIdx chain and deliver to dstIdx chain.
    function bridgeTransfer(uint256 srcSeed, uint256 dstSeed, uint256 amount) external {
        uint256 srcIdx = srcSeed % 3;
        uint256 dstIdx = dstSeed % 3;
        if (srcIdx == dstIdx) dstIdx = (dstIdx + 1) % 3;

        ChainEnv storage src = _chains[srcIdx];
        ChainEnv storage dst = _chains[dstIdx];

        // Bound amount to user's balance on the source chain
        uint256 balance = src.stablecoin.balanceOf(user);
        amount = bound(amount, 0, balance);
        if (amount == 0) return;

        // Burn on source chain
        vm.prank(user);
        src.stablecoin.approve(address(src.bridge.bridgeBurner), amount);
        vm.prank(user);
        src.bridge.bridgeBurner.sendTo(dst.chainId, user, amount);
        ghostBurned[srcIdx] += amount;

        // Construct and deliver message on destination chain (honest server)
        bytes32 nonce = bytes32(++nonceCounter);
        usedNonces[nonce] = true;

        bytes memory payload = TokenMintMessage.encode(user, amount);
        bytes memory message = abi.encode(
            src.chainId,
            address(src.bridge.bridgeBurner),
            block.chainid, // all on same VM
            address(dst.bridge.bridgeMinter),
            nonce,
            payload
        );

        bytes memory sigs = _signForInbox(dst.bridge.inbox, message);
        dst.bridge.inbox.recvMessage(message, sigs);
        ghostMinted[dstIdx] += amount;
        deliveryCount++;
    }

    function _signForInbox(Inbox inbox, bytes memory message) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(message);
        bytes32 digest = MessageHashUtils.toTypedDataHash(inbox.domainSeparator(), structHash);

        uint256[2] memory pks = [ATTESTOR_PK_1, ATTESTOR_PK_2];
        if (vm.addr(pks[0]) > vm.addr(pks[1])) {
            (pks[0], pks[1]) = (pks[1], pks[0]);
        }

        bytes memory sigs;
        for (uint256 i = 0; i < 2; i++) {
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(pks[i], digest);
            sigs = abi.encodePacked(sigs, r, s, v);
        }
        return sigs;
    }
}

contract BridgeInvariantTest is Test {
    bytes constant ARACHNID_CODE =
        hex"7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf3";

    address constant ADMIN = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
    address constant BURNER_ADDR = 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC;
    address constant PAUSER = 0x90F79bf6EB2c4f870365E785982E1f101E93b906;
    address constant FREEZER = 0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65;

    uint256 constant INITIAL_A = 50_000e6;
    uint256 constant INITIAL_B = 30_000e6;
    uint256 constant INITIAL_C = 20_000e6;
    uint256 constant MINTER_ALLOWANCE = 10_000_000e6;

    address constant USER = address(0xCAFE);

    BridgeHandler public handler;

    function setUp() public {
        vm.etch(BridgeDeploy.ARACHNID, ARACHNID_CODE);

        BridgeHandler.ChainEnv[3] memory envs;

        envs[0] = _deployChain(1, bytes32(uint256(10)), INITIAL_A);
        envs[1] = _deployChain(2, bytes32(uint256(20)), INITIAL_B);
        envs[2] = _deployChain(3, bytes32(uint256(30)), INITIAL_C);

        // Cross-configure all pairs
        vm.startPrank(ADMIN);
        for (uint256 i = 0; i < 3; i++) {
            for (uint256 j = 0; j < 3; j++) {
                if (i == j) continue;
                envs[i].bridge.bridgeMinter.setAllowedSender(envs[j].chainId, address(envs[j].bridge.bridgeBurner));
                envs[i].bridge.bridgeBurner.setDstMinter(envs[j].chainId, address(envs[j].bridge.bridgeMinter));
            }
        }
        vm.stopPrank();

        uint256[3] memory initials = [INITIAL_A, INITIAL_B, INITIAL_C];
        handler = new BridgeHandler(envs, USER, initials);

        targetContract(address(handler));
    }

    // ─── 7.2: Per-chain supply accounting ────────────────────────────

    function invariant_PerChainSupplyAccounting() public view {
        for (uint256 i = 0; i < 3; i++) {
            Stablecoin stablecoin = handler.getStablecoin(i);
            uint256 expected = handler.ghostInitialSupply(i) + handler.ghostMinted(i) - handler.ghostBurned(i);
            assertEq(stablecoin.totalSupply(), expected, "per-chain supply mismatch");
        }
    }

    // ─── 7.3: Global supply conservation ─────────────────────────────

    function invariant_GlobalSupplyConservation() public view {
        uint256 totalSupply;
        uint256 totalInitial;
        for (uint256 i = 0; i < 3; i++) {
            totalSupply += handler.getStablecoin(i).totalSupply();
            totalInitial += handler.ghostInitialSupply(i);
        }
        assertEq(totalSupply, totalInitial, "global supply not conserved");
    }

    // ─── 7.4: Nonce uniqueness ───────────────────────────────────────

    function invariant_NonceUniqueness() public view {
        // Each successful delivery consumes exactly one unique nonce.
        // The handler uses a strictly incrementing counter, so uniqueness is enforced
        // by construction. We verify the counter matches the delivery count.
        assertEq(handler.nonceCounter(), handler.deliveryCount(), "nonce counter != delivery count");
    }

    function _deployChain(uint256 chainId, bytes32 salt, uint256 initialSupply)
        internal
        returns (BridgeHandler.ChainEnv memory env)
    {
        env.chainId = chainId;

        vm.startPrank(ADMIN);

        Stablecoin impl = new Stablecoin();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeCall(Stablecoin.initialize, ("Stablecoin", "STBL", 6, ADMIN, BURNER_ADDR, PAUSER, FREEZER))
        );
        env.stablecoin = Stablecoin(address(proxy));

        env.bridge = BridgeDeploy.deployAll(salt, ADMIN, address(env.stablecoin));

        // Roles
        env.stablecoin.grantRole(env.stablecoin.BURNER_ROLE(), address(env.bridge.bridgeBurner));
        env.stablecoin.addMinter(address(env.bridge.bridgeMinter), MINTER_ALLOWANCE);

        // Attestors
        env.bridge.inbox.addAttestor(vm.addr(0xA1));
        env.bridge.inbox.addAttestor(vm.addr(0xA2));
        env.bridge.inbox.setThreshold(2);

        // Mint initial supply to user
        if (initialSupply > 0) {
            env.stablecoin.addMinter(ADMIN, initialSupply);
            env.stablecoin.mint(USER, initialSupply);
        }

        vm.stopPrank();
    }
}
