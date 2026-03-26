#!/bin/bash
# Integration test: Fly.io cloud workspace provisioning flow
#
# Tests the full lifecycle:
#   1. Get API token from fly CLI
#   2. Create app (with sanitized name)
#   3. Create machine with SSH bootstrap
#   4. Wait for machine to start
#   5. Verify SSH connectivity through fly proxy
#   6. Git clone on remote
#   7. Stop + fast resume
#   8. Clean up
#
# Prerequisites:
#   - fly CLI installed and authenticated (fly auth login)
#   - SSH key at ~/.ssh/id_ed25519.pub or ~/.ssh/id_rsa.pub
#
# Usage:
#   ./tests_v2/test_fly_cloud_provision.sh [--repo owner/repo] [--keep]

set -euo pipefail

REPO_SLUG="${REPO_SLUG:-springdotnew/echoform}"
KEEP_RESOURCES=false
FLY_API_BASE="https://api.machines.dev"

while [[ $# -gt 0 ]]; do
    case $1 in
        --repo) REPO_SLUG="$2"; shift 2 ;;
        --keep) KEEP_RESOURCES=true; shift ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[0;33m'
NC='\033[0m'

pass() { echo -e "${GREEN}PASS${NC} $1"; }
fail() { echo -e "${RED}FAIL${NC} $1"; }
info() { echo -e "${CYAN}INFO${NC} $1"; }
warn() { echo -e "${YELLOW}WARN${NC} $1"; }

TESTS_RUN=0; TESTS_PASSED=0; TESTS_FAILED=0

assert() {
    local desc="$1"; shift
    TESTS_RUN=$((TESTS_RUN + 1))
    if "$@" >/dev/null 2>&1; then
        pass "$desc"; TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        fail "$desc"; TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

MACHINE_ID=""
APP_NAME=""
PROXY_PID=""

cleanup() {
    [ -n "$PROXY_PID" ] && kill "$PROXY_PID" 2>/dev/null; wait "$PROXY_PID" 2>/dev/null || true
    if [ "$KEEP_RESOURCES" = true ]; then
        warn "Keeping resources: app=$APP_NAME machine=$MACHINE_ID"; return
    fi
    if [ -n "$MACHINE_ID" ] && [ -n "$APP_NAME" ]; then
        info "Destroying machine $MACHINE_ID..."
        curl -sf -X DELETE -H "Authorization: Bearer $FLY_TOKEN" \
            "$FLY_API_BASE/v1/apps/$APP_NAME/machines/$MACHINE_ID?force=true" >/dev/null 2>&1 || true
    fi
    if [ -n "$APP_NAME" ]; then
        info "Deleting app $APP_NAME..."
        curl -sf -X DELETE -H "Authorization: Bearer $FLY_TOKEN" \
            "$FLY_API_BASE/v1/apps/$APP_NAME" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

echo "=== Fly.io Cloud Workspace Provisioning Test ==="
echo "Repo: $REPO_SLUG"
echo ""

# ---- 1. API Token ----
info "Getting fly.io API token..."
FLY_TOKEN="${FLY_API_TOKEN:-}"
if [ -z "$FLY_TOKEN" ]; then
    FLY_CMD=$(command -v fly || command -v flyctl || echo "")
    [ -n "$FLY_CMD" ] && FLY_TOKEN=$("$FLY_CMD" auth token 2>/dev/null || true)
fi
assert "API token available" test -n "$FLY_TOKEN"
[ -z "$FLY_TOKEN" ] && { echo "No token. Run: fly auth login"; exit 1; }

# ---- 2. SSH Key ----
info "Finding SSH public key..."
SSH_PUBKEY=""
for f in ~/.ssh/id_ed25519.pub ~/.ssh/id_rsa.pub ~/.ssh/id_ecdsa.pub; do
    [ -f "$f" ] && { SSH_PUBKEY=$(cat "$f"); break; }
done
assert "SSH public key available" test -n "$SSH_PUBKEY"
[ -z "$SSH_PUBKEY" ] && { echo "No key. Run: ssh-keygen -t ed25519"; exit 1; }

# ---- 3. Sanitize app name ----
APP_NAME=$(echo "cmux-test-${REPO_SLUG}" | tr '/' '-' | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g' | sed 's/^-//;s/-$//' | cut -c1-63)
info "App name: $APP_NAME"
assert "app name is valid" test -n "$APP_NAME"

# ---- 4. Create app ----
info "Creating app..."
RESP=$(curl -s -w "\n%{http_code}" -X POST \
    -H "Authorization: Bearer $FLY_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"app_name\": \"$APP_NAME\", \"org_slug\": \"personal\"}" \
    "$FLY_API_BASE/v1/apps")
HTTP_CODE=$(echo "$RESP" | tail -1)
BODY=$(echo "$RESP" | sed '$d')
if [ "$HTTP_CODE" = "201" ] || [ "$HTTP_CODE" = "200" ] || echo "$BODY" | grep -qi "already"; then
    pass "App created or already exists"
    TESTS_RUN=$((TESTS_RUN + 1)); TESTS_PASSED=$((TESTS_PASSED + 1))
else
    fail "Create app (HTTP $HTTP_CODE): $BODY"
    TESTS_RUN=$((TESTS_RUN + 1)); TESTS_FAILED=$((TESTS_FAILED + 1))
    exit 1
fi

# ---- 5. Create machine ----
info "Creating machine (ubuntu:24.04 + sshd)..."

# Build machine create request JSON via python (handles all escaping properly)
PUBKEY_FILE=""
for f in ~/.ssh/id_ed25519.pub ~/.ssh/id_rsa.pub ~/.ssh/id_ecdsa.pub; do
    [ -f "$f" ] && { PUBKEY_FILE="$f"; break; }
done
TMPJSON=$(mktemp /tmp/fly-test-XXXXXX.json)
python3 << PYEOF
import json, pathlib
pubkey = pathlib.Path("${PUBKEY_FILE}").read_text().strip()
import base64
b64key = base64.b64encode(pubkey.encode()).decode()
script = (
    "apt-get update -qq && "
    "DEBIAN_FRONTEND=noninteractive apt-get install -y -qq openssh-server git >/dev/null 2>&1 && "
    "mkdir -p /root/.ssh /run/sshd && "
    f"echo {b64key} | base64 -d > /root/.ssh/authorized_keys && "
    "chmod 700 /root/.ssh && chmod 600 /root/.ssh/authorized_keys && "
    "ssh-keygen -A && "
    "mkdir -p /etc/ssh/sshd_config.d && "
    "printf 'PermitRootLogin yes\\n' > /etc/ssh/sshd_config.d/99-cmux.conf && "
    "/usr/sbin/sshd -D -e"
)
body = {
    "config": {
        "image": "ubuntu:24.04",
        "guest": {"cpu_kind": "shared", "cpus": 1, "memory_mb": 1024},
        "env": {"CMUX_CLOUD": "1"},
        "init": {"exec": ["/bin/bash", "-c", script]},
    }
}
pathlib.Path("${TMPJSON}").write_text(json.dumps(body))
PYEOF

RESP=$(curl -s -X POST \
    -H "Authorization: Bearer $FLY_TOKEN" \
    -H "Content-Type: application/json" \
    -d @"$TMPJSON" \
    "$FLY_API_BASE/v1/apps/$APP_NAME/machines")
rm -f "$TMPJSON"

MACHINE_ID=$(echo "$RESP" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
assert "machine created" test -n "$MACHINE_ID"
[ -z "$MACHINE_ID" ] && { echo "Create failed: $RESP"; exit 1; }
info "Machine ID: $MACHINE_ID"

# ---- 6. Wait for start ----
info "Waiting for machine to start..."
curl -sf -H "Authorization: Bearer $FLY_TOKEN" \
    "$FLY_API_BASE/v1/apps/$APP_NAME/machines/$MACHINE_ID/wait?state=started&timeout=60" >/dev/null 2>&1 || true

STATE=$(curl -sf -H "Authorization: Bearer $FLY_TOKEN" \
    "$FLY_API_BASE/v1/apps/$APP_NAME/machines/$MACHINE_ID" | \
    grep -o '"state":"[^"]*"' | head -1 | cut -d'"' -f4)
assert "machine is started" test "$STATE" = "started"
[ "$STATE" != "started" ] && { echo "State: $STATE"; exit 1; }

# ---- 7. SSH via fly proxy ----
FLY_CMD=$(command -v fly || command -v flyctl || echo "")
if [ -z "$FLY_CMD" ]; then
    warn "fly CLI not found, skipping SSH tests"
else
    # Get the machine's private IPv6 address for non-interactive proxy
    PRIVATE_IP=$(curl -sf -H "Authorization: Bearer $FLY_TOKEN" \
        "$FLY_API_BASE/v1/apps/$APP_NAME/machines/$MACHINE_ID" | \
        grep -o '"private_ip":"[^"]*"' | head -1 | cut -d'"' -f4)
    info "Machine private IP: $PRIVATE_IP"

    LOCAL_PORT=$(python3 -c "import socket; s=socket.socket(); s.bind(('127.0.0.1',0)); print(s.getsockname()[1]); s.close()")
    info "Launching fly proxy on localhost:$LOCAL_PORT -> $PRIVATE_IP:22..."

    FLY_API_TOKEN="$FLY_TOKEN" "$FLY_CMD" proxy "$LOCAL_PORT:22" "$PRIVATE_IP" -a "$APP_NAME" -q &
    PROXY_PID=$!
    sleep 3

    assert "fly proxy running" kill -0 "$PROXY_PID"

    # Wait for SSH
    info "Probing SSH (waiting for sshd install + start, up to 90s)..."
    SSH_OK=false
    for _ in $(seq 1 45); do
        if nc -z -w2 127.0.0.1 "$LOCAL_PORT" 2>/dev/null; then SSH_OK=true; break; fi
        sleep 2
    done
    assert "SSH port reachable" test "$SSH_OK" = true

    if [ "$SSH_OK" = true ]; then
        SSH_CMD="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10 -p $LOCAL_PORT root@127.0.0.1"

        info "Testing SSH command execution (with retry)..."
        RESULT=""
        for attempt in $(seq 1 5); do
            RESULT=$($SSH_CMD "echo CMUX_SSH_OK" 2>/dev/null || true)
            [ "$RESULT" = "CMUX_SSH_OK" ] && break
            if [ "$attempt" = "5" ]; then
                info "SSH debug (last attempt):"
                $SSH_CMD -v "echo CMUX_SSH_OK" 2>&1 | grep -iE "auth|offer|publickey|permission|refused" || true
            fi
            sleep 3
        done
        assert "SSH command works" test "$RESULT" = "CMUX_SSH_OK"

        if [ "$RESULT" = "CMUX_SSH_OK" ]; then
            info "Testing git clone on remote (https://github.com/$REPO_SLUG)..."
            CLONE_OUT=$($SSH_CMD "git clone --depth 1 https://github.com/${REPO_SLUG}.git /tmp/test-repo 2>&1 && echo CLONE_OK" 2>/dev/null || true)
            CLONE_OK=$(echo "$CLONE_OUT" | grep -c "CLONE_OK" || true)
            assert "git clone succeeded" test "$CLONE_OK" -gt 0
        fi
    fi

    kill "$PROXY_PID" 2>/dev/null || true; wait "$PROXY_PID" 2>/dev/null || true; PROXY_PID=""
fi

# ---- 8. Stop ----
info "Stopping machine..."
curl -sf -X POST -H "Authorization: Bearer $FLY_TOKEN" \
    "$FLY_API_BASE/v1/apps/$APP_NAME/machines/$MACHINE_ID/stop" >/dev/null 2>&1 || true

curl -sf -H "Authorization: Bearer $FLY_TOKEN" \
    "$FLY_API_BASE/v1/apps/$APP_NAME/machines/$MACHINE_ID/wait?state=stopped&timeout=30" >/dev/null 2>&1 || true

STATE=$(curl -sf -H "Authorization: Bearer $FLY_TOKEN" \
    "$FLY_API_BASE/v1/apps/$APP_NAME/machines/$MACHINE_ID" | \
    grep -o '"state":"[^"]*"' | head -1 | cut -d'"' -f4)
assert "machine stopped" test "$STATE" = "stopped"

# ---- 9. Fast resume ----
info "Restarting machine (fast resume)..."
T0=$(python3 -c "import time; print(time.time())")

curl -sf -X POST -H "Authorization: Bearer $FLY_TOKEN" \
    "$FLY_API_BASE/v1/apps/$APP_NAME/machines/$MACHINE_ID/start" >/dev/null 2>&1

curl -sf -H "Authorization: Bearer $FLY_TOKEN" \
    "$FLY_API_BASE/v1/apps/$APP_NAME/machines/$MACHINE_ID/wait?state=started&timeout=30" >/dev/null 2>&1 || true

T1=$(python3 -c "import time; print(time.time())")
DT=$(python3 -c "print(f'{$T1 - $T0:.1f}')")
info "Resume took ${DT}s"
assert "resumed in under 10s" python3 -c "exit(0 if $T1 - $T0 < 10 else 1)"

# ---- Summary ----
echo ""
echo "=== Results ==="
echo -e "Total: $TESTS_RUN  ${GREEN}Passed: $TESTS_PASSED${NC}  ${RED}Failed: $TESTS_FAILED${NC}"
echo ""
[ $TESTS_FAILED -gt 0 ] && exit 1
exit 0
