# Phase 2 runbook: hand `Stablecoin` governance to a `StablecoinTimelock`

This runbook moves `ADMIN_ROLE` on the deployed `Stablecoin` proxy from the
**Safe multisig** to a delayed-execution **`StablecoinTimelock`**. After it,
privileged actions (minter management, role changes, upgrades) no longer take
effect instantly — they must be **scheduled, wait out a `minDelay`, then
executed**, giving the team a window to cancel a hostile or mistaken operation.

> **Prerequisite:** the audit upgrade in
> [`upgrade-pre-audit-to-main.md`](./upgrade-pre-audit-to-main.md) must already be
> done. Before the M-01 repair, `grantRole(ADMIN_ROLE, …)` reverts, so the
> handover is impossible. Confirm `getRoleAdmin(ADMIN_ROLE) == ADMIN_ROLE` first.

> **This procedure has been dry-run against a mainnet fork of the live proxy and
> verified end to end.** See [Fork-test results](#fork-test-results).

---

## End-state governance model

```
        proposes / cancels                 enforces delay              executes
 Safe ───────────────────────▶ StablecoinTimelock ──────(minDelay)─────▶ Stablecoin proxy
 (PROPOSER + CANCELLER)          (sole ADMIN_ROLE holder)                 (admin-gated ops)
```

- **Safe** keeps `PROPOSER_ROLE` + `CANCELLER_ROLE` on the timelock: it queues
  operations and can cancel pending ones. It no longer holds `ADMIN_ROLE` on the
  token.
- **Timelock** is the **sole `ADMIN_ROLE` holder** and self-administers (its own
  `admin` is `address(0)`, the standard OZ pattern).
- **Executors**: with `executors = [address(0)]` ("open execution") **anyone** can
  execute a matured operation — no privileged executor key to manage. Choose
  `[SAFE]` instead for closed execution if you want only the Safe to execute.

---

## Topology & parameters to decide first

| Parameter | Recommendation | Notes |
|-----------|----------------|-------|
| `MIN_DELAY` | e.g. `172800` (48h) | Becomes `deploymentMinDelay`, a **permanent floor** — governance can raise the delay later but can never lower it below this value. |
| `proposers` | `[SAFE]` | OZ grants each proposer **both** `PROPOSER_ROLE` and `CANCELLER_ROLE`. |
| `executors` | `[address(0)]` (open) | Or `[SAFE]` for closed execution. |
| `admin` (ctor) | `address(0)` | Timelock self-administers via timelocked ops. |

```bash
export RPC_URL="http://ts.mainnet.internal.lambdaclass.com:8545"
export PROXY="0x9a1bFb2B9E3d1959Ed11636bc56DB0aB7b4473A9"
export SAFE="0xaD35fF83e38b2dd4dA5623193F2567d1870f6371"
export ADMIN_ROLE="0xa49807205ce4d355092ef5a8a18f56e8913cf4a201fbe287825b095693c21775"
export DEPLOYER_KEY="0x…"          # funded EOA, deploys the timelock only
export MIN_DELAY=172800            # 48h
```

---

## Step 1 — Deploy the timelock

`DeployTimelock.s.sol` constructs a `StablecoinTimelock` bound to the proxy.

```bash
forge script script/DeployTimelock.s.sol \
    --rpc-url $RPC_URL --broadcast --private-key $DEPLOYER_KEY \
    --sig 'run(address,uint256,address[],address[])' \
    $PROXY $MIN_DELAY "[$SAFE]" "[0x0000000000000000000000000000000000000000]"
#   → "StablecoinTimelock deployed at: 0x…"
export TIMELOCK="0x…"
```

<details>
<summary>Alternative: <code>forge create</code> (no script)</summary>

```bash
forge create src/StablecoinTimelock.sol:StablecoinTimelock \
    --rpc-url $RPC_URL --private-key $DEPLOYER_KEY --broadcast \
    --constructor-args $PROXY $MIN_DELAY "[$SAFE]" \
      "[0x0000000000000000000000000000000000000000]" \
      0x0000000000000000000000000000000000000000
```
</details>

Verify the wiring (read-only):

```bash
cast call $TIMELOCK "stablecoin()(address)"        --rpc-url $RPC_URL   # == $PROXY
cast call $TIMELOCK "deploymentMinDelay()(uint256)" --rpc-url $RPC_URL  # == $MIN_DELAY
PROP=$(cast call $TIMELOCK "PROPOSER_ROLE()(bytes32)"  --rpc-url $RPC_URL)
CANC=$(cast call $TIMELOCK "CANCELLER_ROLE()(bytes32)" --rpc-url $RPC_URL)
cast call $TIMELOCK "hasRole(bytes32,address)(bool)" $PROP $SAFE --rpc-url $RPC_URL  # true
cast call $TIMELOCK "hasRole(bytes32,address)(bool)" $CANC $SAFE --rpc-url $RPC_URL  # true
```

---

## Step 2 — Safe grants `ADMIN_ROLE` to the timelock

A Safe transaction on the proxy. After this, **both** the Safe and the timelock
hold `ADMIN_ROLE` (set size 2) — a deliberate overlap so you can prove the
timelock works (Step 3) before dropping the Safe (Step 4).

```bash
cast calldata "grantRole(bytes32,address)" $ADMIN_ROLE $TIMELOCK
#   → execute from the Safe:  to=$PROXY  value=0  operation=CALL  data=<output>
```

Verify:

```bash
cast call $PROXY "hasRole(bytes32,address)(bool)" $ADMIN_ROLE $TIMELOCK --rpc-url $RPC_URL  # true
cast call $PROXY "getRoleMemberCount(bytes32)(uint256)" $ADMIN_ROLE --rpc-url $RPC_URL      # 2
```

---

## Step 3 — Prove a full timelock cycle (BEFORE revoking the Safe)

Do **not** skip this. Rehearse one real admin op end-to-end through the timelock
so you know governance still functions before the Safe gives up direct control.
This example schedules `addMinter`; any admin op works the same way via the typed
`schedule*` helpers (see [reference](#typed-schedule-helpers)).

```bash
# Params for the demo op — RECORD THESE; you need the exact salt + args to execute.
MINTER=0x…                  # address to grant MINTER_ROLE
CAP=1000000000000000000000  # allowance (1000e18)
SALT=0x0000000000000000000000000000000000000000000000000000000000000001

# 3a. Safe SCHEDULES via the typed helper (Safe tx, to=$TIMELOCK):
cast calldata "scheduleAddMinter(address,uint256,bytes32,uint256)" $MINTER $CAP $SALT $MIN_DELAY
#   → execute from the Safe:  to=$TIMELOCK  value=0  data=<output>

# 3b. Compute the operation id and confirm it is pending but not yet ready:
DATA=$(cast calldata "addMinter(address,uint256)" $MINTER $CAP)
PRED=0x0000000000000000000000000000000000000000000000000000000000000000
OPID=$(cast call $TIMELOCK "hashOperation(address,uint256,bytes,bytes32,bytes32)(bytes32)" \
        $PROXY 0 $DATA $PRED $SALT --rpc-url $RPC_URL)
cast call $TIMELOCK "isOperationPending(bytes32)(bool)" $OPID --rpc-url $RPC_URL   # true
cast call $TIMELOCK "getTimestamp(bytes32)(uint256)"   $OPID --rpc-url $RPC_URL   # ready-at unix time

# 3c. Wait for real time to pass minDelay (mainnet: just wait; no time-warp).

# 3d. EXECUTE (open executor → anyone; e.g. a keeper EOA):
cast send $TIMELOCK "execute(address,uint256,bytes,bytes32,bytes32)" \
    $PROXY 0 $DATA $PRED $SALT --private-key $ANY_KEY --rpc-url $RPC_URL

# 3e. Verify the op landed:
MINTER_ROLE=$(cast keccak "MINTER_ROLE")
cast call $PROXY "hasRole(bytes32,address)(bool)" $MINTER_ROLE $MINTER --rpc-url $RPC_URL  # true
cast call $PROXY "minterAllowance(address)(uint256)" $MINTER --rpc-url $RPC_URL            # == $CAP
```

**Cancel path** (the reason the delay exists): a canceller (the Safe holds
`CANCELLER_ROLE`) can kill a pending op before it matures:

```bash
cast calldata "cancel(bytes32)" $OPID     # → execute from the Safe (to=$TIMELOCK)
```

---

## Step 4 — Safe revokes its own `ADMIN_ROLE`

Once Step 3 proves the timelock works, the Safe drops its direct admin power,
leaving the timelock as the **sole** admin. A Safe transaction on the proxy.

```bash
cast calldata "revokeRole(bytes32,address)" $ADMIN_ROLE $SAFE
#   → execute from the Safe:  to=$PROXY  value=0  data=<output>
```

Verify:

```bash
cast call $PROXY "getRoleMemberCount(bytes32)(uint256)" $ADMIN_ROLE --rpc-url $RPC_URL       # 1
cast call $PROXY "hasRole(bytes32,address)(bool)" $ADMIN_ROLE $SAFE     --rpc-url $RPC_URL    # false
cast call $PROXY "hasRole(bytes32,address)(bool)" $ADMIN_ROLE $TIMELOCK --rpc-url $RPC_URL    # true
```

> ⚠️ **This is the point of no return for instant admin actions.** From here, every
> admin op goes through schedule → wait → execute. The Safe stays in control as
> the proposer/canceller, but can no longer act instantly. The contract refuses to
> remove the last admin (`AdminRoleCannotBeEmpty`), so you cannot orphan the role —
> but still verify the timelock holds `ADMIN_ROLE` before submitting this tx.

---

## Operating the timelock afterward

Every admin op is now a three-move dance the Safe drives:

1. **Schedule** — Safe tx to `TIMELOCK` calling a typed `schedule*` helper.
2. **Wait** — `minDelay` seconds.
3. **Execute** — `timelock.execute(target, 0, data, predecessor, salt)` by an
   executor (anyone, under open execution). Reconstruct `data` from the same
   arguments the helper used, and reuse the same `salt`.

### Typed schedule helpers
All take a trailing `(bytes32 salt, uint256 delay)`; `delay >= getMinDelay()`.

| Helper | Effect on the token |
|--------|---------------------|
| `scheduleAddMinter(minter, cap, …)` | `addMinter(minter, cap)` |
| `scheduleRemoveMinter(minter, …)` | `removeMinter(minter)` |
| `scheduleModifyMinterAllowance(minter, delta, …)` | `modifyMinterAllowance(minter, delta)` (signed delta) |
| `scheduleGrantAdmin(newAdmin, …)` / `scheduleRevokeAdmin(oldAdmin, …)` | rotate `ADMIN_ROLE` |
| `scheduleGrantBurner` / `scheduleRevokeBurner` | `BURNER_ROLE` |
| `scheduleGrantPauser` / `scheduleRevokePauser` | `PAUSER_ROLE` |
| `scheduleGrantFreezer` / `scheduleRevokeFreezer` | `FREEZER_ROLE` |
| `scheduleUpgrade(newImpl, data, …)` | `upgradeToAndCall(newImpl, data)` — **future implementation upgrades** |

The `scheduleRevoke*` and `scheduleUpgrade` helpers validate their target at
**schedule** time (e.g. reject a non-holder or a non-contract impl) so a typo
fails immediately instead of after burning the `minDelay` window.

> **Pause is not timelocked.** `pause()` / `unpause()` are gated by `PAUSER_ROLE`,
> not `ADMIN_ROLE`, so the pauser can still act instantly in an emergency — the
> timelock does not slow down incident response.

### Future upgrades go through the timelock
After the handover, a V2/V3 upgrade is:
`scheduleUpgrade(newImpl, reinitData, salt, delay)` → wait → `execute(...)`.
Remember the [reinitializer-slot note](./upgrade-pre-audit-to-main.md#notes--caveats):
`reinitializer(2)` is already consumed by the M-01 repair, so a later version must
use `reinitializer(3)` or higher.

---

## Fork-test results

Executed against an anvil fork of mainnet at block **25396215** (the live
`Sur Token - ARSs` proxy), after the M-01 upgrade, impersonating the real Safe.
**18/19 assertions passed; the one miss was a cosmetic string-compare on
`cast`'s `1000000000000000000000 [1e21]` annotation — the value was correct.**

| Step | Result |
|------|--------|
| Timelock deployed, `stablecoin()==proxy`, floor == `MIN_DELAY` | ✅ |
| Safe holds `PROPOSER_ROLE` + `CANCELLER_ROLE` | ✅ |
| Safe grants `ADMIN_ROLE` → admin set size 2 | ✅ |
| `scheduleAddMinter` → op pending, **not ready before delay** | ✅ |
| after `minDelay` → op ready → `execute` → minter role + allowance applied → op done | ✅ |
| Safe `revokeRole(ADMIN_ROLE, Safe)` → admin set size 1, timelock sole admin | ✅ |
| Safe direct `addMinter` now reverts (no `ADMIN_ROLE`) | ✅ |
| revoking the last (timelock) admin reverts (`AdminRoleCannotBeEmpty`) | ✅ |

---

## Appendix — replicate the fork test locally

The [results table](#fork-test-results) above was produced by the sequence below.
It runs the whole path — M-01 upgrade **and** timelock handover — against a local
anvil fork of mainnet, impersonating the real Safe (no signatures needed). Copy
it verbatim to reproduce the verification.

```bash
# ── 0. Fork mainnet locally (pin the block for reproducibility) ──────────────
anvil --fork-url http://ts.mainnet.internal.lambdaclass.com:8545 \
      --fork-block-number 25396215 --port 8546 &
sleep 3
export L=http://127.0.0.1:8546
export PROXY=0x9a1bFb2B9E3d1959Ed11636bc56DB0aB7b4473A9
export SAFE=0xaD35fF83e38b2dd4dA5623193F2567d1870f6371
export ADMIN_ROLE=0xa49807205ce4d355092ef5a8a18f56e8913cf4a201fbe287825b095693c21775
export DEV_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80  # anvil acct #0
export ZERO=0x0000000000000000000000000000000000000000
export ZB32=0x0000000000000000000000000000000000000000000000000000000000000000

# ── 1. Prereq: M-01 upgrade (deploy impl, impersonate Safe, upgrade) ─────────
NEW_IMPL=$(forge create src/Stablecoin.sol:Stablecoin --rpc-url $L \
  --private-key $DEV_KEY --broadcast 2>/dev/null | awk '/Deployed to:/{print $3}')
cast rpc anvil_impersonateAccount $SAFE --rpc-url $L >/dev/null
cast rpc anvil_setBalance $SAFE 0xde0b6b3a7640000 --rpc-url $L >/dev/null
cast send $PROXY "upgradeToAndCall(address,bytes)" $NEW_IMPL 0x117d61eb \
  --from $SAFE --unlocked --rpc-url $L >/dev/null
cast call $PROXY "getRoleAdmin(bytes32)(bytes32)" $ADMIN_ROLE --rpc-url $L  # == ADMIN_ROLE

# ── 2. Deploy the timelock (minDelay 60s for a fast test) ────────────────────
MIN_DELAY=60
TIMELOCK=$(forge create src/StablecoinTimelock.sol:StablecoinTimelock --rpc-url $L \
  --private-key $DEV_KEY --broadcast \
  --constructor-args $PROXY $MIN_DELAY "[$SAFE]" "[$ZERO]" $ZERO 2>/dev/null \
  | awk '/Deployed to:/{print $3}')
cast call $TIMELOCK "stablecoin()(address)" --rpc-url $L                    # == $PROXY
cast call $TIMELOCK "deploymentMinDelay()(uint256)" --rpc-url $L            # 60

# ── 3. Safe grants ADMIN_ROLE to the timelock ───────────────────────────────
cast send $PROXY "grantRole(bytes32,address)" $ADMIN_ROLE $TIMELOCK \
  --from $SAFE --unlocked --rpc-url $L >/dev/null
cast call $PROXY "getRoleMemberCount(bytes32)(uint256)" $ADMIN_ROLE --rpc-url $L  # 2

# ── 4. Full timelock cycle: Safe schedules → wait → anyone executes ──────────
MINTER=0x00000000000000000000000000000000DeaDBeef
CAP=1000000000000000000000        # 1000e18  (cast prints this as "… [1e21]")
SALT=0x0000000000000000000000000000000000000000000000000000000000000001
cast send $TIMELOCK "scheduleAddMinter(address,uint256,bytes32,uint256)" \
  $MINTER $CAP $SALT $MIN_DELAY --from $SAFE --unlocked --rpc-url $L >/dev/null
DATA=$(cast calldata "addMinter(address,uint256)" $MINTER $CAP)
OPID=$(cast call $TIMELOCK "hashOperation(address,uint256,bytes,bytes32,bytes32)(bytes32)" \
        $PROXY 0 $DATA $ZB32 $SALT --rpc-url $L)
cast call $TIMELOCK "isOperationReady(bytes32)(bool)" $OPID --rpc-url $L     # false (pre-delay)
cast rpc evm_increaseTime $((MIN_DELAY + 10)) --rpc-url $L >/dev/null        # warp past minDelay
cast rpc evm_mine --rpc-url $L >/dev/null
cast call $TIMELOCK "isOperationReady(bytes32)(bool)" $OPID --rpc-url $L     # true
cast send $TIMELOCK "execute(address,uint256,bytes,bytes32,bytes32)" \
  $PROXY 0 $DATA $ZB32 $SALT --private-key $DEV_KEY --rpc-url $L >/dev/null
# verify (awk '{print $1}' drops cast's "[1e21]" display annotation):
cast call $PROXY "hasRole(bytes32,address)(bool)" $(cast keccak "MINTER_ROLE") $MINTER --rpc-url $L   # true
cast call $PROXY "minterAllowance(address)(uint256)" $MINTER --rpc-url $L | awk '{print $1}'          # 1000000000000000000000

# ── 5. Safe revokes its own ADMIN_ROLE → timelock is sole admin ─────────────
cast send $PROXY "revokeRole(bytes32,address)" $ADMIN_ROLE $SAFE \
  --from $SAFE --unlocked --rpc-url $L >/dev/null
cast call $PROXY "getRoleMemberCount(bytes32)(uint256)" $ADMIN_ROLE --rpc-url $L          # 1
cast call $PROXY "hasRole(bytes32,address)(bool)" $ADMIN_ROLE $TIMELOCK --rpc-url $L      # true

# ── 6. Negative checks (both must revert) ───────────────────────────────────
cast call $PROXY "addMinter(address,uint256)" 0x00000000000000000000000000000000000bEEF1 1 \
  --from $SAFE --rpc-url $L          # reverts: Safe no longer has ADMIN_ROLE
cast call $PROXY "revokeRole(bytes32,address)" $ADMIN_ROLE $TIMELOCK \
  --from $TIMELOCK --rpc-url $L      # reverts: AdminRoleCannotBeEmpty

# ── teardown ────────────────────────────────────────────────────────────────
pkill -f "anvil.*8546"
```

> **Comparing `uint256` outputs:** `cast call …(uint256)` annotates large numbers,
> e.g. `1000000000000000000000 [1e21]`. The `[1e21]` is a display hint, not part of
> the value, and it is a *second token* — so `cast to-dec "$(cast call …)"` errors on
> the `[1e21]` arg. Take the first token instead: `… | awk '{print $1}'` (as above)
> when diffing programmatically.

---

## Caveats

- **`minDelay` floor is permanent.** `deploymentMinDelay` is fixed at construction;
  `updateDelay` cannot go below it. Pick your floor deliberately.
- **Open vs. closed execution.** `[address(0)]` executors = anyone can execute
  matured ops (convenient, no executor key). Use `[SAFE]` if you require the Safe
  to execute too.
- **Record salts and arguments.** Execution reconstructs the call from the exact
  `target/value/data/predecessor/salt`; lose the salt and you must recompute it
  from the original parameters.
- **Predecessor ordering.** The typed helpers use `predecessor = 0x0` (independent
  ops). Use raw `schedule`/`scheduleBatch` if you need to chain ordered ops.
- **Self-administration.** Changing the timelock's own delay or roles is itself a
  timelocked op targeting `address(this)`.
