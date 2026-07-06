# Upgrade guide: pre-audit `Stablecoin` → audited `main` (Safe-admin)

This runbook walks the **Safe multisig** that holds `ADMIN_ROLE` through upgrading
the deployed, pre-audit `Stablecoin` proxy to the current audited implementation
on `main`. The critical path uses only `forge`, `cast`, and `anvil` — no Node and
no OpenZeppelin Upgrades plugin (see [why](#appendix-a--optional-oz-plugin-storage-layout-validator)).

> **This procedure has been dry-run against a mainnet fork of the live proxy and
> verified end to end.** See [Fork-test results](#fork-test-results).

---

## TL;DR

The whole upgrade is **one transaction the Safe executes on the proxy**:

```
proxy.upgradeToAndCall(NEW_IMPL, 0x117d61eb)
                                  └─ calldata for reinitializeAdminRole()
```

It atomically (a) repoints the proxy at the new audited implementation and
(b) runs `reinitializeAdminRole()` to repair the audit finding **M-01**. All
balances, roles, minters, allowances, frozen accounts, and pause state are
preserved.

Sequence: **dry-run on an anvil fork → deploy the new implementation → assemble
the Safe tx → execute via the Safe → verify.**

---

## Background

### What changed and why
`main` contains the audit fixes applied on top of the pre-audit baseline (the
`audit` branch). The fixes changed **behavior, not storage** — the contract
declares the same three storage slots (`_minterAllowances`, `frozen`,
`_decimals`) in the same order before and after, and everything inherited from
OpenZeppelin uses ERC-7201 namespaced storage, so there are no layout
collisions. **The upgrade is storage-safe.**

### The one fix that needs a migration step: M-01
The pre-audit `initialize()` set the role-admin for `BURNER_ROLE`, `PAUSER_ROLE`,
and `FREEZER_ROLE`, but **never set it for `ADMIN_ROLE`**. That left
`getRoleAdmin(ADMIN_ROLE) == DEFAULT_ADMIN_ROLE (0x00)`, a role nobody holds — so
on the deployed contract today, **even the legitimate admin cannot grant or
revoke `ADMIN_ROLE`** (`grantRole(ADMIN_ROLE, …)` reverts).

The audited `Stablecoin` exposes a one-time repair:

```solidity
function reinitializeAdminRole() public reinitializer(2) onlyRole(ADMIN_ROLE) {
    _setRoleAdmin(ADMIN_ROLE, ADMIN_ROLE);
}
```

Running it as part of the upgrade makes `ADMIN_ROLE` self-administering. We run it
**in the same transaction** as the implementation flip (via `upgradeToAndCall`)
so there is never a window where the proxy is on new code with an unrepaired slot.

### Why the Safe must perform this upgrade (and a timelock cannot — yet)
Because of M-01, you **cannot** grant `ADMIN_ROLE` to a new `StablecoinTimelock`
*before* the repair — the grant would revert. So the upgrade must be executed by
the entity that holds `ADMIN_ROLE` **today**: your Safe. Handing governance to a
timelock is only possible *after* this upgrade — see
[Phase 2 (optional)](#phase-2-optional--hand-governance-to-a-stablecointimelock).

---

## Addresses & roles

| Item | Value |
|------|-------|
| Network | Ethereum mainnet (chain id `1`) |
| Token | `Sur Token - ARSs` (`ARSs`), 18 decimals |
| Proxy (`PROXY`) | `0x9a1bFb2B9E3d1959Ed11636bc56DB0aB7b4473A9` |
| Admin Safe (`SAFE`) | `0xaD35fF83e38b2dd4dA5623193F2567d1870f6371` |
| Current (pre-audit) impl | `0x2d35740ca60ea0aa818bd9ba41ce15890f5d3755` |
| `ADMIN_ROLE` | `0xa49807205ce4d355092ef5a8a18f56e8913cf4a201fbe287825b095693c21775` |
| New implementation (`NEW_IMPL`) | _produced in [Step 2](#step-2--deploy-the-new-implementation-on-mainnet)_ |
| `reinitializeAdminRole()` calldata | `0x117d61eb` |
| `upgradeToAndCall(address,bytes)` selector | `0x4f1ef286` |

Shell setup used throughout:

```bash
export RPC_URL="http://ts.mainnet.internal.lambdaclass.com:8545"   # live mainnet RPC
export PROXY="0x9a1bFb2B9E3d1959Ed11636bc56DB0aB7b4473A9"
export SAFE="0xaD35fF83e38b2dd4dA5623193F2567d1870f6371"
export ADMIN_ROLE="0xa49807205ce4d355092ef5a8a18f56e8913cf4a201fbe287825b095693c21775"
```

---

## Prerequisites

- **Foundry** (`forge`, `cast`, `anvil`) — `foundryup`. Verified with forge 1.5.1.
- This repository checked out at the `main` commit you intend to deploy, with
  submodules initialized (`forge install` / `git submodule update --init`).
- An **RPC URL** for mainnet.
- A **funded deployer EOA** for the real deployment (its only job is to deploy the
  new implementation; it needs no role on the proxy).
- Access to the **Safe** (Safe{Wallet} UI, Safe CLI, or Transaction Service) with
  enough signers to meet the threshold.

> Node.js is **not** required for this procedure. It is only needed for the
> optional OZ storage-layout validator in [Appendix A](#appendix-a--optional-oz-plugin-storage-layout-validator),
> which currently errors in this repo's Foundry version.

---

## Step 0 — Pre-flight checks (read-only)

Confirm reality matches the assumptions. None of these send a transaction.

```bash
cast implementation $PROXY --rpc-url $RPC_URL
#   → 0x2d35740ca60ea0aa818bd9ba41ce15890f5d3755 (the pre-audit impl)

cast call $PROXY "hasRole(bytes32,address)(bool)" $ADMIN_ROLE $SAFE --rpc-url $RPC_URL
#   → true  (the Safe holds ADMIN_ROLE)

cast call $PROXY "getRoleAdmin(bytes32)(bytes32)" $ADMIN_ROLE --rpc-url $RPC_URL
#   → 0x0000…0000  (M-01 present: role admin is DEFAULT_ADMIN_ROLE)

# Snapshot the state the upgrade must preserve
cast call $PROXY "name()(string)"            --rpc-url $RPC_URL   # "Sur Token - ARSs"
cast call $PROXY "symbol()(string)"          --rpc-url $RPC_URL   # "ARSs"
cast call $PROXY "decimals()(uint8)"         --rpc-url $RPC_URL   # 18
cast call $PROXY "totalSupply()(uint256)"    --rpc-url $RPC_URL   # 1001000000000000000000
cast call $PROXY "paused()(bool)"            --rpc-url $RPC_URL   # false
cast call $PROXY "getMinterCount()(uint256)" --rpc-url $RPC_URL   # 1
```

If `getRoleAdmin(ADMIN_ROLE)` is **not** zero, the proxy has already been
repaired — stop and reassess.

---

## Step 1 — Dry-run on an anvil mainnet fork (rehearsal + go/no-go gate)

This forks mainnet locally and performs the **exact** upgrade the Safe will run,
impersonating the Safe so no signatures are needed. It is both the safety check
and a faithful rehearsal of Steps 2–5.

```bash
# 1. Start an anvil fork of mainnet (pin a block for reproducibility)
anvil --fork-url $RPC_URL --fork-block-number 25396215 --port 8546 &
export ANVIL="http://127.0.0.1:8546"
sleep 3   # wait for the fork to be ready

# 2. Deploy the audited implementation on the fork (anvil dev account #0)
export DEV_KEY="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
forge create src/Stablecoin.sol:Stablecoin --rpc-url $ANVIL --private-key $DEV_KEY --broadcast
#   → copy the "Deployed to:" address:
export NEW_IMPL="0x…"

# 3. Impersonate the Safe and fund it for gas
cast rpc anvil_impersonateAccount $SAFE --rpc-url $ANVIL
cast rpc anvil_setBalance $SAFE 0xde0b6b3a7640000 --rpc-url $ANVIL   # 1 ETH

# 4. Execute the upgrade AS the Safe (the inner 0x117d61eb is reinitializeAdminRole())
cast send $PROXY "upgradeToAndCall(address,bytes)" $NEW_IMPL 0x117d61eb \
    --from $SAFE --unlocked --rpc-url $ANVIL

# 5. Verify the outcome on the fork
cast implementation $PROXY --rpc-url $ANVIL                                   # == $NEW_IMPL
cast call $PROXY "getRoleAdmin(bytes32)(bytes32)" $ADMIN_ROLE --rpc-url $ANVIL # == $ADMIN_ROLE (repaired)
cast call $PROXY "totalSupply()(uint256)" --rpc-url $ANVIL                    # 1001000000000000000000 (unchanged)
cast call $PROXY "name()(string)" --rpc-url $ANVIL                            # "Sur Token - ARSs" (unchanged)

# 6. The repair is one-shot — a second call MUST revert (InvalidInitialization, 0xf92ee8a9)
cast call $PROXY "reinitializeAdminRole()" --from $SAFE --rpc-url $ANVIL

# 7. M-01 fixed — the Safe can now rotate the role (this reverted before the upgrade)
cast call $PROXY "grantRole(bytes32,address)" $ADMIN_ROLE 0x000000000000000000000000000000000000dEaD \
    --from $SAFE --rpc-url $ANVIL    # returns 0x (success), no revert

# Tear down the fork when done
pkill -f "anvil.*8546"
```

You can also confirm the migration logic with the bundled unit test (no fork,
no Node):

```bash
forge test --match-test test_UpgradeFromMain_RepairsRoleAdminAndAllowsRotation -vv
```

Do not proceed to mainnet until the fork dry-run reproduces the expected values.

---

## Step 2 — Deploy the new implementation on mainnet

Deploy the audited `Stablecoin` implementation with your real funded deployer.
The deployer pays gas and gains no privileges. The constructor takes no arguments
and calls `_disableInitializers()`.

```bash
forge create src/Stablecoin.sol:Stablecoin \
    --rpc-url $RPC_URL --private-key $DEPLOYER_KEY --broadcast
#   → copy the "Deployed to:" address
export NEW_IMPL="0x…"

# Sanity: the address has code
cast code $NEW_IMPL --rpc-url $RPC_URL | head -c 12   # non-empty (e.g. 0x60806040…)
```

> Optional: see [Appendix A](#appendix-a--optional-oz-plugin-storage-layout-validator)
> for the OZ-validated deploy script. Storage compatibility is already guaranteed
> (identical layout, verified on the fork), so plain `forge create` is sufficient.

### Verify `NEW_IMPL` is the audited code (do this before anyone signs)

The Safe transaction only encodes an *address*; `upgradeToAndCall` will point the
proxy at whatever contract lives there. So each signer must independently confirm
`NEW_IMPL` holds the **audited** implementation, not a look-alike:

```bash
# 1. Check out and build the exact audited commit (pin it — do not use a moving branch):
git checkout <AUDITED_COMMIT>        # e.g. the tag/commit that was audited on main
forge build

# 2. Compare the on-chain runtime bytecode to the locally compiled one.
#    foundry.toml sets bytecode_hash="none" and cbor_metadata=false, and Stablecoin
#    has no immutables, so the runtime bytecode is deterministic — it should match EXACTLY.
diff <(cast code $NEW_IMPL --rpc-url $RPC_URL) \
     <(jq -r '.deployedBytecode.object' out/Stablecoin.sol/Stablecoin.json) \
  && echo "MATCH — NEW_IMPL is the audited implementation" \
  || echo "MISMATCH — DO NOT SIGN"
```

Alternatively (or additionally), verify `NEW_IMPL`'s source on Etherscan and confirm
it matches the audited commit. **Do not sign until `NEW_IMPL`'s code is confirmed.**

---

## Step 3 — Assemble the Safe transaction

```bash
REINIT_DATA=$(cast calldata "reinitializeAdminRole()")            # 0x117d61eb
CALLDATA=$(cast calldata "upgradeToAndCall(address,bytes)" $NEW_IMPL $REINIT_DATA)

echo "Safe transaction:"
echo "  to:        $PROXY"
echo "  value:     0"
echo "  operation: 0  (CALL — not DELEGATECALL)"
echo "  data:      $CALLDATA"
```

`CALLDATA` starts with `0x4f1ef286` (the `upgradeToAndCall` selector), followed by
`NEW_IMPL` and the encoded `0x117d61eb`. Decode it to prove it is that single call
and nothing else:

```bash
cast calldata-decode "upgradeToAndCall(address,bytes)" $CALLDATA
#   → NEW_IMPL
#   → 0x117d61eb
```

---

## Step 4 — Execute via the Safe

This upgrade is a **single, plain CALL** from the Safe to the proxy. It only
succeeds if the Safe holds `ADMIN_ROLE` at execution time (that authorizes both the
UUPS upgrade and the inner `reinitializeAdminRole()`), so re-run the Step 0
`hasRole(ADMIN_ROLE, SAFE)` check right before signing — if it is `false`, stop.

### Option A — Safe{Wallet} web UI

There are two ways to enter the call. The **ABI-method path is preferred** because
it forces the human-readable decode; the raw-hex path is a fallback.

**(a) Preferred — ABI method (Transaction Builder).** Because the target is a
*proxy*, its published ABI does not include `upgradeToAndCall`, so paste this
minimal ABI fragment to make the method selectable:

```json
[{"inputs":[{"name":"newImplementation","type":"address"},{"name":"data","type":"bytes"}],"name":"upgradeToAndCall","stateMutability":"payable","type":"function"}]
```

1. Safe → **New transaction** → **Transaction Builder**.
2. **Enter address**: `PROXY`. Paste the ABI fragment above when prompted.
3. Select **`upgradeToAndCall`**, then set `newImplementation = NEW_IMPL`,
   `data = 0x117d61eb`, **ETH value = 0**.
4. Add to batch (a single row), review, and create the transaction.

**(b) Fallback — raw hex.** Safe → **New transaction** → (a plain send with the
**raw/custom hex-data** toggle enabled) → **To** = `PROXY`, **value** = `0`,
**Data** = `CALLDATA` from Step 3.

> If Safe shows the data **undecoded** (proxy ABI lacks `upgradeToAndCall`), do not
> sign the bytes blind — use path (a), or independently decode first:
> `cast calldata-decode "upgradeToAndCall(address,bytes)" $CALLDATA` and confirm it
> prints `(NEW_IMPL, 0x117d61eb)`.

### Pre-sign checklist — every signer must confirm ALL of:

1. **To** == `PROXY` (`0x9a1bFb2B9E3d1959Ed11636bc56DB0aB7b4473A9`)
2. **ETH value** == `0`
3. **Operation** == `CALL (0)` — **NOT** `DELEGATECALL (1)`
4. Method decodes to `upgradeToAndCall(address newImplementation, bytes data)`
5. `newImplementation` == `NEW_IMPL` — compare **all 40 hex chars**, not just the ends
6. `data` == `0x117d61eb`
7. **This is the ONLY action** — a single call, not a batch / MultiSend. (A Safe
   MultiSend shows multiple rows or `Operation = DELEGATECALL` to a MultiSend
   contract — if you see that, **reject it**.)
8. `NEW_IMPL` has been [verified as the audited code](#verify-new_impl-is-the-audited-code-do-this-before-anyone-signs).

> **Do NOT bundle** the Phase 2 `grantRole` / `revokeRole`
> ([`timelock-handover.md`](./timelock-handover.md)) into this transaction — those
> are separate, later Safe transactions. This one is standalone.

Then collect signatures to threshold and **Execute**. Confirm the Safe's threshold
and owner set are as expected before signing; if other transactions are queued,
make sure this one executes first and no other tx shares its nonce.

### Option B — Safe CLI
```bash
safe-cli send-custom $SAFE $RPC_URL $PROXY 0 $CALLDATA --private-key <proposer_key>
# other owners confirm, then execute once threshold is met
```
`safe-cli` sends a `CALL` (operation 0) by default — do not pass any delegatecall
flag; verify the argument order against your installed `safe-cli` version. The CLI
shows no decoded method, so run
`cast calldata-decode "upgradeToAndCall(address,bytes)" $CALLDATA` and confirm
`(NEW_IMPL, 0x117d61eb)` before confirming.

---

## Step 5 — Post-upgrade verification (read-only)

```bash
cast implementation $PROXY --rpc-url $RPC_URL          # == $NEW_IMPL

cast call $PROXY "getRoleAdmin(bytes32)(bytes32)" $ADMIN_ROLE --rpc-url $RPC_URL
#   → 0xa49807205ce4d355092ef5a8a18f56e8913cf4a201fbe287825b095693c21775 (repaired)

# State preserved (compare against your Step 0 snapshot)
cast call $PROXY "name()(string)"            --rpc-url $RPC_URL
cast call $PROXY "totalSupply()(uint256)"    --rpc-url $RPC_URL
cast call $PROXY "paused()(bool)"            --rpc-url $RPC_URL
cast call $PROXY "getMinterCount()(uint256)" --rpc-url $RPC_URL

# Repair is one-shot — a second call must revert (InvalidInitialization)
cast call $PROXY "reinitializeAdminRole()" --from $SAFE --rpc-url $RPC_URL
```

Once `getRoleAdmin(ADMIN_ROLE) == ADMIN_ROLE` and the state matches your snapshot,
the migration is complete.

---

## Phase 2 (optional) — hand governance to a `StablecoinTimelock`

Now that `ADMIN_ROLE` is self-administering, you can move governance from the Safe
to a delayed-execution `StablecoinTimelock` (recommended for production: a hostile
admin action then has a `minDelay` window in which it can be cancelled). In
outline:

1. Deploy a `StablecoinTimelock` bound to the proxy (Safe as proposer/canceller).
2. Safe grants `ADMIN_ROLE` to the timelock (now set size 2).
3. **Rehearse one real op through the timelock** (schedule → wait → execute) to
   prove governance works.
4. Safe revokes its own `ADMIN_ROLE`, leaving the timelock as sole admin.

This is a separate, irreversible operation with its own ordering and safety
considerations, so it has a dedicated, fork-tested runbook:

➡️ **[`timelock-handover.md`](./timelock-handover.md)**

After the handover, future upgrades go through
`StablecoinTimelock.scheduleUpgrade(newImpl, data, salt, delay)` → wait
`minDelay` → `execute(...)`.

---

## Appendix A — Optional OZ-plugin storage-layout validator

The repo ships `script/SimulateUpgrade.s.sol` and
`script/DeployNewImplementation.s.sol`, which use the OpenZeppelin Foundry
Upgrades plugin to validate the storage layout automatically (referencing the
pre-audit snapshot `script/integration/OldStablecoin.sol`).

**Known issue in this repo's toolchain:** with the current Foundry version these
error out during validation:

```
ValidateCommandError: Build info file out/build-info/<hash>.json is not from a full compilation.
```

This is the well-known Foundry incremental-compilation vs. OZ-plugin interaction
(`forge script`/`forge test` produce partial build-info; the plugin requires a
full compilation). It affects both `forge test` and `forge script` here.

Because of this, the runbook above relies on the **anvil-fork functional test**
instead, which is more faithful (it executes against the live proxy state as the
real Safe). Storage-layout safety does not depend on the plugin: the pre-audit
and `main` layouts are byte-identical (same explicit slots in the same order;
namespaced ERC-7201 storage everywhere else), and the on-fork upgrade preserved
every value. If you want the plugin path working, resolve the full-compilation
build-info issue first (e.g. align the Foundry version with the OZ plugin's
expectations).

---

## Fork-test results

Dry-run executed against an anvil fork of mainnet at block **25396215** (the live
`Sur Token - ARSs` proxy), impersonating the real Safe:

| Check | Before | After |
|-------|--------|-------|
| Implementation | `0x2d35…3755` | `0x56c0…5a88` (the freshly deployed audited impl) |
| `getRoleAdmin(ADMIN_ROLE)` | `0x00…00` (M-01) | `0xa498…1775` (`ADMIN_ROLE`, repaired) |
| `name` / `symbol` / `decimals` | `Sur Token - ARSs` / `ARSs` / `18` | unchanged |
| `totalSupply` | `1001000000000000000000` | unchanged |
| `paused` / `getMinterCount` | `false` / `1` | unchanged |
| `reinitializeAdminRole()` replay | n/a | reverts `InvalidInitialization()` (`0xf92ee8a9`) |
| `grantRole(ADMIN_ROLE, …)` by Safe | reverts (M-01) | succeeds |

(The `0x56c0…5a88` address is the impl deployed during the fork test; on mainnet
you will get your own `NEW_IMPL` from Step 2.)

---

## Notes & caveats

- **Reinitializer slot is consumed.** `reinitializeAdminRole()` uses
  `reinitializer(2)`. The illustrative `src/upgrades/StablecoinV2.sol` also uses
  `reinitializer(2)` for `initializeV2(...)`. After this migration, a future
  upgrade to a V2 must bump its reinitializer to `reinitializer(3)` (and beyond),
  or its init call will revert with `InvalidInitialization()`.
- **No pause required.** UUPS upgrades are authorized independently of pause state.
- **Minters carry over.** `MINTER_ROLE` membership and per-minter allowances live
  in preserved storage; existing minters keep working with no further action.
- **Rollback.** UUPS upgrades only move forward. Do **not** point the proxy back
  at the pre-audit code — that reintroduces M-01 and the reinitializer version is
  already consumed. Keep `NEW_IMPL` recorded.
- **Don't lose the Safe before Phase 2.** Until governance is handed to a timelock,
  the Safe is the sole controller of upgrades and role management.
