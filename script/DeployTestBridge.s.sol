// SPDX-License-Identifier: Apache-2.0
pragma solidity =0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Stablecoin} from "src/Stablecoin.sol";
import {Outbox} from "src/bridge/Outbox.sol";
import {Inbox} from "src/bridge/Inbox.sol";
import {BridgeBurner} from "src/bridge/BridgeBurner.sol";
import {BridgeMinter} from "src/bridge/BridgeMinter.sol";

/// @notice Deploys all bridge contracts directly (no CREATE2) for integration testing.
/// @dev Production cross-chain routes are configured per-direction: the BridgeMinter on chain B
/// accepts messages whose `srcChain` is chain A and whose sender is the BridgeBurner on chain A,
/// and the BridgeBurner on chain A routes outbound messages to the BridgeMinter on chain B.
/// The previous implementation passed `block.chainid` (the *local* chain) into both
/// `setAllowedSender` and `setDstMinter`, producing a same-chain loop that can never be used
/// because BridgeBurner.sendTo reverts when `dstChain == block.chainid`. The script now requires
/// the counterpart chain ID so the route at least *describes* a valid bridge topology, even when
/// the counterpart contract addresses are stubs supplied by the operator.
contract DeployTestBridge is Script {
    uint8 internal constant DECIMALS = 6;

    error CounterpartIsLocalChain(uint256 chainId);

    function run(
        address attestor,
        uint256 minterAllowance,
        uint256 counterpartChainId,
        address counterpartBurner,
        address counterpartMinter
    ) public {
        require(counterpartChainId != block.chainid, CounterpartIsLocalChain(block.chainid));

        address admin = msg.sender;

        vm.startBroadcast();

        Stablecoin stablecoin = _deployStablecoin(admin);
        Outbox outbox = _deployOutbox(admin);
        Inbox inbox = _deployInbox(admin);
        BridgeBurner bridgeBurner = _deployBurner(admin, address(stablecoin), address(outbox));
        BridgeMinter bridgeMinter = _deployMinter(admin, address(stablecoin), address(inbox));

        _configure(
            stablecoin,
            inbox,
            bridgeBurner,
            bridgeMinter,
            attestor,
            minterAllowance,
            counterpartChainId,
            counterpartBurner,
            counterpartMinter
        );

        vm.stopBroadcast();

        console.log("STABLECOIN=%s", address(stablecoin));
        console.log("OUTBOX=%s", address(outbox));
        console.log("INBOX=%s", address(inbox));
        console.log("BRIDGE_BURNER=%s", address(bridgeBurner));
        console.log("BRIDGE_MINTER=%s", address(bridgeMinter));
    }

    function _deployStablecoin(address admin) internal returns (Stablecoin) {
        Stablecoin impl_ = new Stablecoin();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl_),
            abi.encodeCall(Stablecoin.initialize, ("Stablecoin", "STBL", DECIMALS, admin, admin, admin, admin))
        );
        return Stablecoin(address(proxy));
    }

    function _deployOutbox(address admin) internal returns (Outbox) {
        Outbox impl_ = new Outbox();
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl_), abi.encodeCall(Outbox.initialize, (admin)));
        return Outbox(address(proxy));
    }

    function _deployInbox(address admin) internal returns (Inbox) {
        Inbox impl_ = new Inbox();
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl_), abi.encodeCall(Inbox.initialize, (admin)));
        return Inbox(address(proxy));
    }

    function _deployBurner(address admin, address stablecoin, address outbox) internal returns (BridgeBurner) {
        BridgeBurner impl_ = new BridgeBurner();
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl_), abi.encodeCall(BridgeBurner.initialize, (admin, outbox)));
        BridgeBurner burner = BridgeBurner(address(proxy));
        burner.setStablecoin(stablecoin);
        return burner;
    }

    function _deployMinter(address admin, address stablecoin, address inbox) internal returns (BridgeMinter) {
        BridgeMinter impl_ = new BridgeMinter();
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl_), abi.encodeCall(BridgeMinter.initialize, (admin, inbox)));
        BridgeMinter minter = BridgeMinter(address(proxy));
        minter.setStablecoin(stablecoin);
        return minter;
    }

    function _configure(
        Stablecoin stablecoin,
        Inbox inbox,
        BridgeBurner bridgeBurner,
        BridgeMinter bridgeMinter,
        address attestor,
        uint256 minterAllowance,
        uint256 counterpartChainId,
        address counterpartBurner,
        address counterpartMinter
    ) internal {
        stablecoin.grantRole(stablecoin.BURNER_ROLE(), address(bridgeBurner));
        stablecoin.addMinter(address(bridgeMinter), minterAllowance);
        // Also add msg.sender as minter for test convenience (minting test tokens)
        stablecoin.addMinter(msg.sender, minterAllowance);
        inbox.addAttestor(attestor);
        inbox.setThreshold(1);
        // The local BridgeMinter accepts messages from the counterpart chain's BridgeBurner;
        // the local BridgeBurner routes outbound messages to the counterpart chain's BridgeMinter.
        bridgeMinter.setAllowedSender(counterpartChainId, counterpartBurner);
        bridgeBurner.setDstMinter(counterpartChainId, counterpartMinter);
    }
}
