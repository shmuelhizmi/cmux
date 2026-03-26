#!/usr/bin/env bash
# Integration test for Daytona cloud sandbox provisioning.
# Prerequisites:
#   - DAYTONA_API_KEY environment variable set
#   - SSH client available
#
# Usage:
#   DAYTONA_API_KEY=<key> bash tests_v2/test_daytona_cloud_provision.sh

set -euo pipefail

# --- Helpers ---

PASS=0
FAIL=0
CLEANUP_SANDBOX_ID=""

info()  { echo "  [INFO] $*"; }
pass()  { echo "  [PASS] $*"; PASS=$((PASS + 1)); }
fail()  { echo "  [FAIL] $*"; FAIL=$((FAIL + 1)); }

cleanup() {
    if [ -n "$CLEANUP_SANDBOX_ID" ]; then
        info "Cleanup: deleting sandbox $CLEANUP_SANDBOX_ID"
        curl -sS -X DELETE \
            -H "Authorization: Bearer $DAYTONA_API_KEY" \
            "$API_BASE/sandbox/$CLEANUP_SANDBOX_ID" >/dev/null 2>&1 || true
    fi
    echo ""
    echo "Results: $PASS passed, $FAIL failed"
    if [ "$FAIL" -gt 0 ]; then exit 1; fi
}
trap cleanup EXIT

# --- Configuration ---

API_BASE="${DAYTONA_API_URL:-https://app.daytona.io/api}"

if [ -z "${DAYTONA_API_KEY:-}" ]; then
    echo "ERROR: DAYTONA_API_KEY is not set."
    exit 1
fi

info "Using API: $API_BASE"

# --- Test 1: Create sandbox ---

echo ""
echo "=== Test 1: Create sandbox ==="

CREATE_RESPONSE=$(curl -sS -X POST \
    -H "Authorization: Bearer $DAYTONA_API_KEY" \
    -H "Content-Type: application/json" \
    -d '{"snapshot": "daytona-small", "labels": {"cmux_test": "true"}}' \
    "$API_BASE/sandbox")

SANDBOX_ID=$(echo "$CREATE_RESPONSE" | python3 -c "import sys, json; print(json.load(sys.stdin)['id'])" 2>/dev/null || true)

if [ -z "$SANDBOX_ID" ]; then
    fail "Create sandbox - no ID returned"
    echo "Response: $CREATE_RESPONSE"
    exit 1
fi

CLEANUP_SANDBOX_ID="$SANDBOX_ID"
pass "Create sandbox - ID: $SANDBOX_ID"

# --- Test 2: Poll until running ---

echo ""
echo "=== Test 2: Wait for running state ==="

MAX_ATTEMPTS=60
DELAY=2
STATE=""

for i in $(seq 1 $MAX_ATTEMPTS); do
    STATUS_RESPONSE=$(curl -sS \
        -H "Authorization: Bearer $DAYTONA_API_KEY" \
        "$API_BASE/sandbox/$SANDBOX_ID")
    STATE=$(echo "$STATUS_RESPONSE" | python3 -c "import sys, json; print(json.load(sys.stdin).get('state', 'unknown'))" 2>/dev/null || echo "unknown")

    if [ "$STATE" = "running" ] || [ "$STATE" = "started" ]; then
        pass "Sandbox reached running state after $((i * DELAY))s"
        break
    fi
    if [ "$STATE" = "error" ]; then
        fail "Sandbox entered error state"
        echo "Response: $STATUS_RESPONSE"
        exit 1
    fi
    if [ "$i" -eq "$MAX_ATTEMPTS" ]; then
        fail "Sandbox did not reach running state (last: $STATE)"
        exit 1
    fi
    sleep $DELAY
done

# --- Test 3: Create SSH access ---

echo ""
echo "=== Test 3: Create SSH access ==="

SSH_RESPONSE=$(curl -sS -X POST \
    -H "Authorization: Bearer $DAYTONA_API_KEY" \
    "$API_BASE/sandbox/$SANDBOX_ID/ssh-access?expiresInMinutes=60")

SSH_TOKEN=$(echo "$SSH_RESPONSE" | python3 -c "import sys, json; print(json.load(sys.stdin)['token'])" 2>/dev/null || true)

if [ -z "$SSH_TOKEN" ]; then
    fail "Create SSH access - no token returned"
    echo "Response: $SSH_RESPONSE"
else
    pass "Create SSH access - token obtained"
fi

# --- Test 4: Test SSH connectivity ---

echo ""
echo "=== Test 4: SSH connectivity ==="

if [ -n "$SSH_TOKEN" ]; then
    SSH_OUTPUT=$(ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
        -o ConnectTimeout=10 \
        "${SSH_TOKEN}@ssh.app.daytona.io" \
        "echo CMUX_SSH_OK" 2>/dev/null || true)

    if echo "$SSH_OUTPUT" | grep -q "CMUX_SSH_OK"; then
        pass "SSH connection successful"
    else
        fail "SSH connection failed"
        info "Output: $SSH_OUTPUT"
    fi
else
    fail "SSH connectivity - skipped (no token)"
fi

# --- Test 5: Test git on remote ---

echo ""
echo "=== Test 5: Git availability ==="

if [ -n "$SSH_TOKEN" ]; then
    GIT_OUTPUT=$(ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
        -o ConnectTimeout=10 \
        "${SSH_TOKEN}@ssh.app.daytona.io" \
        "git --version" 2>/dev/null || true)

    if echo "$GIT_OUTPUT" | grep -q "git version"; then
        pass "Git available on remote: $GIT_OUTPUT"
    else
        fail "Git not available on remote"
        info "Output: $GIT_OUTPUT"
    fi
else
    fail "Git check - skipped (no token)"
fi

# --- Test 6: Stop sandbox ---

echo ""
echo "=== Test 6: Stop sandbox ==="

curl -sS -X POST \
    -H "Authorization: Bearer $DAYTONA_API_KEY" \
    "$API_BASE/sandbox/$SANDBOX_ID/stop" >/dev/null

# Poll until stopped
for i in $(seq 1 30); do
    STATUS_RESPONSE=$(curl -sS \
        -H "Authorization: Bearer $DAYTONA_API_KEY" \
        "$API_BASE/sandbox/$SANDBOX_ID")
    STATE=$(echo "$STATUS_RESPONSE" | python3 -c "import sys, json; print(json.load(sys.stdin).get('state', 'unknown'))" 2>/dev/null || echo "unknown")

    if [ "$STATE" = "stopped" ]; then
        pass "Sandbox stopped"
        break
    fi
    if [ "$i" -eq 30 ]; then
        fail "Sandbox did not stop (last: $STATE)"
    fi
    sleep 2
done

# --- Test 7: Resume (fast start) ---

echo ""
echo "=== Test 7: Resume sandbox ==="

START_TIME=$(date +%s)

curl -sS -X POST \
    -H "Authorization: Bearer $DAYTONA_API_KEY" \
    "$API_BASE/sandbox/$SANDBOX_ID/start" >/dev/null

for i in $(seq 1 30); do
    STATUS_RESPONSE=$(curl -sS \
        -H "Authorization: Bearer $DAYTONA_API_KEY" \
        "$API_BASE/sandbox/$SANDBOX_ID")
    STATE=$(echo "$STATUS_RESPONSE" | python3 -c "import sys, json; print(json.load(sys.stdin).get('state', 'unknown'))" 2>/dev/null || echo "unknown")

    if [ "$STATE" = "running" ] || [ "$STATE" = "started" ]; then
        END_TIME=$(date +%s)
        ELAPSED=$((END_TIME - START_TIME))
        pass "Sandbox resumed in ${ELAPSED}s"
        break
    fi
    if [ "$i" -eq 30 ]; then
        fail "Sandbox did not resume (last: $STATE)"
    fi
    sleep 2
done

# --- Cleanup handled by trap ---

echo ""
echo "=== All tests complete ==="
