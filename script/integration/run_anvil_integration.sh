#!/usr/bin/env bash
# Integration test: deploy main's Stablecoin, upgrade to this branch's
# version, hand admin to StablecoinTimelock, and execute a scheduled
# addMinter through the timelock. Runs against a freshly-spawned anvil.
#
# Usage: ./script/integration/run_anvil_integration.sh
#
# Exits non-zero on any step failure. Requires `anvil`, `cast`, and `forge`
# on PATH (all part of a standard foundry install).

set -euo pipefail

# Anvil's well-known dev account #0 — never use this on a public network.
DEPLOYER_KEY="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
RPC_URL="http://127.0.0.1:8545"
STATE_FILE="./integration-state.json"
MIN_DELAY=60
TIME_ADVANCE=$((MIN_DELAY + 10))
EXPECTED_CHAIN_ID=31337  # anvil default — refuse to run against anything else

# Project root is two levels up from this script.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/../.."

ANVIL_PID=""
cleanup() {
    if [[ -n "$ANVIL_PID" ]] && kill -0 "$ANVIL_PID" 2>/dev/null; then
        kill "$ANVIL_PID" 2>/dev/null || true
        wait "$ANVIL_PID" 2>/dev/null || true
    fi
    rm -f "$STATE_FILE"
}
trap cleanup EXIT

# Refuse to start if port 8545 already has something listening — otherwise we'd
# silently piggy-back on someone else's anvil (or worse) and produce misleading
# results.
if cast block-number --rpc-url "$RPC_URL" >/dev/null 2>&1; then
    echo "ERROR: something is already listening on $RPC_URL — refusing to start anvil." >&2
    echo "       Stop the existing process (or use a different RPC_URL) and re-run." >&2
    exit 1
fi

# The OZ Upgrades library validates storage layout via @openzeppelin/upgrades-core,
# which insists on a *full* compilation (no incremental build-info). Without
# this, step 1's `Upgrades.upgradeProxy(...)` aborts at the validator with:
#   "Build info file out/build-info/<hash>.json is not from a full compilation."
echo "==> forge clean + build (required by OZ Upgrades validator)..."
forge clean
forge build >/dev/null

echo "==> Starting anvil (silent)..."
anvil --silent >/dev/null 2>&1 &
ANVIL_PID=$!

# Wait for anvil's JSON-RPC to be ready. cast block-number is the cheapest probe.
# Bail out early if the anvil process itself died — otherwise we'd loop on a
# dead PID and then fail with a confusing connection error.
for i in {1..50}; do
    if ! kill -0 "$ANVIL_PID" 2>/dev/null; then
        echo "ERROR: anvil process exited before becoming ready (pid $ANVIL_PID)" >&2
        exit 1
    fi
    if cast block-number --rpc-url "$RPC_URL" >/dev/null 2>&1; then
        break
    fi
    sleep 0.1
done
if ! cast block-number --rpc-url "$RPC_URL" >/dev/null 2>&1; then
    echo "ERROR: anvil did not become ready within 5s" >&2
    exit 1
fi

# Belt-and-braces: if anvil happened to start but somehow we're talking to a
# different process (e.g. a stale node we missed on the pre-flight check),
# `cast chain-id` will tell us. Refuse anything other than anvil's default.
ACTUAL_CHAIN_ID="$(cast chain-id --rpc-url "$RPC_URL")"
if [[ "$ACTUAL_CHAIN_ID" != "$EXPECTED_CHAIN_ID" ]]; then
    echo "ERROR: connected RPC reports chain id $ACTUAL_CHAIN_ID, expected $EXPECTED_CHAIN_ID." >&2
    echo "       This script uses a hardcoded dev key and must only run against anvil." >&2
    exit 1
fi
echo "==> anvil ready (pid $ANVIL_PID, chain id $ACTUAL_CHAIN_ID)"

echo
echo "==> Step 1/3: deploy old impl, upgrade to new, set up timelock, schedule addMinter"
PRIVATE_KEY="$DEPLOYER_KEY" forge script \
    script/integration/IntegrationDeployAndSchedule.s.sol:IntegrationDeployAndSchedule \
    --rpc-url "$RPC_URL" \
    --broadcast \
    --slow \
    -vv

echo
echo "==> Step 2/3: advance anvil time by ${TIME_ADVANCE}s (min delay = ${MIN_DELAY}s)"
cast rpc evm_increaseTime "$TIME_ADVANCE" --rpc-url "$RPC_URL" >/dev/null
cast rpc evm_mine --rpc-url "$RPC_URL" >/dev/null

echo
echo "==> Step 3/3: execute matured operation through timelock and verify"
PRIVATE_KEY="$DEPLOYER_KEY" forge script \
    script/integration/IntegrationExecuteAndVerify.s.sol:IntegrationExecuteAndVerify \
    --rpc-url "$RPC_URL" \
    --broadcast \
    --slow \
    -vv

echo
echo "==> Integration test PASSED"
