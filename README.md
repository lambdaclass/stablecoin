# Stablecoin Smart Contracts

Upgradeable ERC20 stablecoin using the UUPS proxy pattern with OpenZeppelin and Foundry.

## Upgrading the Contract

The contract uses [UUPS (ERC-1822)](https://eips.ethereum.org/EIPS/eip-1822) proxies. Only the `ADMIN_ROLE` holder can authorize upgrades. Upgrades work even when the contract is paused.

### Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation) installed
- Node.js installed (required for OZ storage layout validation via FFI)
- The admin private key for the deployed proxy

### Writing a New Version

Place the new contract in `src/upgrades/` (e.g. `src/upgrades/StablecoinV2.sol`). It must:

1. **Inherit from the previous version** and only append new storage variables at the end. Never reorder, rename, or remove existing storage.
2. **Use `reinitializer(n)`** (not `initializer`) for the upgrade init function, where `n` is the next version number.
3. **Include the `@custom:oz-upgrades-from` annotation** pointing to the previous contract name. This enables automatic storage layout validation.

Example:

```solidity
/// @custom:oz-upgrades-from Stablecoin
contract StablecoinV2 is Stablecoin {
    uint256 private _maxSupply; // new storage appended at the end

    function initializeV2(uint256 maxSupply_) public reinitializer(2) {
        _maxSupply = maxSupply_;
    }
}
```

## Example Migration
### Step 1: Run Tests

Always start by running the upgrade test suite against a clean build:

```bash
forge clean && forge test --match-contract UpgradeStablecoin -vvv
```

This runs storage layout validation and verifies that all existing state (balances, roles, minter allowances, frozen accounts, pause state) is preserved through the upgrade.

### Encoding Reinitializer Calldata

The upgrade scripts accept pre-encoded `bytes` for the reinitializer call. Use `cast calldata` to encode whatever reinitializer your new version needs:

```bash
# V1→V2: initializeV2(uint256 maxSupply)
MAX_SUPPLY=$(cast parse-units 1000000 6)    # 1000000000000 (6-decimal token)
REINIT_DATA=$(cast calldata "initializeV2(uint256)" $MAX_SUPPLY)

# V2→V3 (hypothetical): initializeV3(uint256 newParam, bool flag)
REINIT_DATA=$(cast calldata "initializeV3(uint256,bool)" 42 true)
```

### Step 2: Simulate on a Fork

Before broadcasting, simulate the full upgrade against a fork of the live network. This uses `vm.prank` to impersonate the admin without needing the private key:

```bash
REINIT_DATA=$(cast calldata "initializeV2(uint256)" $MAX_SUPPLY)

forge clean && forge script script/SimulateUpgrade.s.sol \
    --fork-url $RPC_URL \
    --sig 'run(address,string,bytes,address,string)' \
    $PROXY "StablecoinV2.sol" $REINIT_DATA $ADMIN "Stablecoin.sol"
```

| Parameter | Description |
|-----------|-------------|
| `$PROXY` | Address of the deployed proxy contract |
| `"StablecoinV2.sol"` | Filename of the new implementation in `src/upgrades/` |
| `$REINIT_DATA` | ABI-encoded reinitializer calldata (see [Encoding Reinitializer Calldata](#encoding-reinitializer-calldata)) |
| `$ADMIN` | Address that holds `ADMIN_ROLE` on the proxy |
| `"Stablecoin.sol"` | Reference contract for storage layout validation (the contract currently behind the proxy) |

The simulation will:
1. Snapshot all on-chain state (name, symbol, decimals, supply, minters, frozen accounts, roles)
2. Validate storage layout compatibility
3. Execute the upgrade via `vm.prank(admin)`
4. Assert every snapshotted value is unchanged

If it prints `=== SIMULATION PASSED ===`, the upgrade is safe.

### Step 3: Execute the Upgrade

You can perform the upgrade in **1 step** (script handles everything) or **2 steps** (deploy implementation first, then upgrade the proxy separately).

#### Option A: 1-Step Upgrade (Script)

The `UpgradeStablecoin.s.sol` script deploys the new implementation and calls `upgradeToAndCall` on the proxy in a single execution. It also runs storage layout validation and logs pre/post state.

**Dry run** (omit `--broadcast` to verify without submitting):

```bash
REINIT_DATA=$(cast calldata "initializeV2(uint256)" $MAX_SUPPLY)

forge clean && forge script script/UpgradeStablecoin.s.sol \
    --fork-url $RPC_URL \
    --private-key $ADMIN_KEY \
    --sig 'run(address,string,bytes,string)' \
    $PROXY "StablecoinV2.sol" $REINIT_DATA "Stablecoin.sol"
```

**Broadcast** (add `--broadcast` to send the transactions):

```bash
forge clean && forge script script/UpgradeStablecoin.s.sol \
    --broadcast --private-key $ADMIN_KEY --rpc-url $RPC_URL \
    --sig 'run(address,string,bytes,string)' \
    $PROXY "StablecoinV2.sol" $REINIT_DATA "Stablecoin.sol"
```

Transaction receipts are saved to `broadcast/`.

#### Option B: 2-Step Upgrade (Deploy + Upgrade Separately)

Use this when you want to inspect the deployed implementation before upgrading, or when the deployer and the proxy admin are different parties (e.g., a multisig holds `ADMIN_ROLE`).

**Step 1 — Deploy the new implementation:**

```bash
forge clean && forge script script/DeployNewImplementation.s.sol \
    --broadcast --private-key $DEPLOYER_KEY --rpc-url $RPC_URL \
    --sig 'run(string,string)' "StablecoinV2.sol" "Stablecoin.sol"
```

This validates storage layout, deploys the new implementation, and outputs its address. Save it:

```bash
NEW_IMPL=<address from output>
```

**Step 2 — Encode the reinitializer calldata and upgrade the proxy:**

```bash
# Encode initializeV2(uint256) calldata
REINIT_DATA=$(cast calldata "initializeV2(uint256)" $MAX_SUPPLY)

# Call upgradeToAndCall on the proxy (must be sent by the ADMIN_ROLE holder)
cast send $PROXY "upgradeToAndCall(address,bytes)" $NEW_IMPL $REINIT_DATA \
    --private-key $ADMIN_KEY \
    --rpc-url $RPC_URL
```

**Verify the upgrade succeeded:**

```bash
# Check the implementation address behind the proxy (EIP-1967 slot)
cast implementation $PROXY --rpc-url $RPC_URL

# Confirm new functionality is accessible
cast call $PROXY "version()(string)" --rpc-url $RPC_URL
cast call $PROXY "maxSupply()(uint256)" --rpc-url $RPC_URL
```

### Upgrading V2→V3 and Beyond

The scripts are version-agnostic. For a V2→V3 upgrade, the only things that change are the contract name, reinit data, and reference contract:

```bash
# The reference contract is now StablecoinV2.sol (the version currently deployed)
REINIT_DATA=$(cast calldata "initializeV3(uint256,bool)" $PARAM1 true)

forge clean && forge script script/UpgradeStablecoin.s.sol \
    --broadcast --private-key $ADMIN_KEY --rpc-url $RPC_URL \
    --sig 'run(address,string,bytes,string)' \
    $PROXY "StablecoinV3.sol" $REINIT_DATA "StablecoinV2.sol"
```

### Important Notes

- **Always run `forge clean` before any script or test.** Stale build artifacts in `out/` can cause storage layout validation to produce incorrect results silently.
- **Upgrades work while paused.** The `_authorizeUpgrade` function checks only `ADMIN_ROLE`, not `whenNotPaused`. This is intentional so the admin can upgrade during an emergency pause.
- **The reinitializer can only run once.** After the upgrade, calling `initializeV2` again will revert with `InvalidInitialization()`. The original `initialize` is also permanently locked.
- **Storage layout is validated automatically** by the scripts via the `referenceContract` parameter. This compares the new contract's layout against the specified reference and reverts on any incompatibility (reordered slots, type changes, etc.).

## Initial Deployment

```bash
forge clean && forge script script/DeployStablecoin.s.sol \
    --broadcast --private-key $ADMIN_KEY --rpc-url $RPC_URL \
    --sig 'run(string,string,uint8,address,address,address,address)' \
    $NAME $SYMBOL $DECIMALS $ADMIN $BURNER $PAUSER $FREEZER
```

This deploys the UUPS proxy with `Stablecoin.sol` as the initial implementation.

## License

This project is licensed under the Apache License, Version 2.0. See [LICENSE](./LICENSE) for the full text.
