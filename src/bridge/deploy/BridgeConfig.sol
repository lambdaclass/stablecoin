// SPDX-License-Identifier: Apache-2.0
pragma solidity =0.8.30;

import {Stablecoin} from "../../Stablecoin.sol";
import {BridgeDeploy} from "./BridgeDeploy.sol";

/// @title BridgeConfig
/// @notice Configures deployed bridge contracts: grants stablecoin roles, sets up
/// the Inbox attestor set, and configures BridgeMinter allowed senders.
library BridgeConfig {
    struct AllowedSender {
        uint256 srcChain;
        address sender;
    }

    struct DstMinter {
        uint256 dstChain;
        address minter;
    }

    struct Config {
        address[] attestors;
        uint256 threshold;
        uint256 minterAllowance;
        AllowedSender[] allowedSenders;
        DstMinter[] dstMinters;
    }

    error NoAttestors();
    error ThresholdZero();
    error ThresholdTooHigh(uint256 threshold, uint256 attestorCount);
    error MinterAllowanceZero();
    error ZeroAllowedSender(uint256 index);
    error ZeroDstMinter(uint256 index);

    /// @notice Configure all bridge contracts after deployment.
    /// @dev The caller must have ADMIN_ROLE on the stablecoin and be the owner of
    /// all bridge contracts.
    function configure(Stablecoin stablecoin, BridgeDeploy.Contracts memory c, Config memory config) internal {
        _validateConfig(config);

        // 0. Wire the (chain-specific) stablecoin into BridgeBurner and BridgeMinter.
        // The stablecoin address is intentionally NOT part of the proxy creation
        // bytecode (see BridgeDeploy dev note), so we set it post-deployment here.
        c.bridgeBurner.setStablecoin(address(stablecoin));
        c.bridgeMinter.setStablecoin(address(stablecoin));

        // 1. Grant BURNER_ROLE to BridgeBurner on the stablecoin
        stablecoin.grantRole(stablecoin.BURNER_ROLE(), address(c.bridgeBurner));

        // 2. Add BridgeMinter as a minter with the configured allowance
        stablecoin.addMinter(address(c.bridgeMinter), config.minterAllowance);

        // 3. Set up Inbox attestors and threshold
        for (uint256 i = 0; i < config.attestors.length; ++i) {
            c.inbox.addAttestor(config.attestors[i]);
        }
        c.inbox.setThreshold(config.threshold);

        // 4. Set BridgeMinter allowed senders (srcChain => expected BridgeBurner address)
        for (uint256 i = 0; i < config.allowedSenders.length; ++i) {
            c.bridgeMinter.setAllowedSender(config.allowedSenders[i].srcChain, config.allowedSenders[i].sender);
        }

        // 5. Set BridgeBurner destination minters (dstChain => BridgeMinter address on that chain)
        for (uint256 i = 0; i < config.dstMinters.length; ++i) {
            c.bridgeBurner.setDstMinter(config.dstMinters[i].dstChain, config.dstMinters[i].minter);
        }
    }

    /// @dev Validate the entire config before any state changes, so configure either
    /// fully succeeds or reverts without partial side effects.
    function _validateConfig(Config memory config) private pure {
        // Attestor / threshold coherence
        require(config.attestors.length > 0, NoAttestors());
        require(config.threshold > 0, ThresholdZero());
        require(
            config.threshold <= config.attestors.length, ThresholdTooHigh(config.threshold, config.attestors.length)
        );

        // Minter allowance
        require(config.minterAllowance > 0, MinterAllowanceZero());

        // Zero-address checks on array entries. Attestors are checked by Inbox.addAttestor
        // at configure-time, so they're not re-validated here.
        for (uint256 i = 0; i < config.allowedSenders.length; ++i) {
            require(config.allowedSenders[i].sender != address(0), ZeroAllowedSender(i));
        }
        for (uint256 i = 0; i < config.dstMinters.length; ++i) {
            require(config.dstMinters[i].minter != address(0), ZeroDstMinter(i));
        }
    }
}
