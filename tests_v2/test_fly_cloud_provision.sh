#!/bin/bash
# Integration test: Fly.io cloud workspace provisioning flow
#
# Tests the full lifecycle:
#   1. Get API token from fly CLI
#   2. Create app (with sanitized name)
#   3. Create machine with SSH bootstrap
#   4. Wait for machine to start
#   5. Verify SSH connectivity through fly proxy
#   6. Clean up (destroy machine, delete app)
#
# Prerequisites:
#   - fly CLI installed and authenticated (fly auth login)
#   - SSH key at ~/.ssh/id_ed25519.pub or ~/.ssh/id_rsa.pub
#
# Usage:
#   ./tests_v2/test_fly_cloud_provision.sh [--repo owner/repo] [--keep]
#
# Options:
#   --repo    GitHub repo slug to test with (default: springdotnew/echoform)
#   --keep    Don't destroy resources after test (for debugging)

set -euo pipefail

REPO_SLUG="${REPO_SLUG:-springdotnew/echoform}"
KEEP_RESOURCES=false
FLY_API_BASE="https://api.machines.dev"

# Parse args
while [[ $# -gt 0 ]]; do
    case $1 in
        --repo) REPO_SLUG="$2"; shift 2 ;;
        --keep) KEEP_RESOURCES=true; shift ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

pass() { echo -e "${GREEN}PASS${NC} $1"; }
fail() { echo -e "${RED}FAIL${NC} $1"; }
info() { echo -e "${CYAN}INFO${NC} $1"; }
warn() { echo -e "${YELLOW}WARN${NC} $1"; }

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

assert() {
    local desc="$1"
    shift
    TESTS_RUN=$((TESTS_RUN + 1))
    if "$@"; then
        pass "$desc"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        fail "$desc"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

# Cleanup function
MACHINE_ID=""
APP_NAME=""
PROXY_PID=""

cleanup() {
    if [ -n "$PROXY_PID" ] && kill -0 "$PROXY_PID" 2>/dev/null; then
        kill "$PROXY_PID" 2>/dev/null || true
        wait "$PROXY_PID" 2>/dev/null || true
    fi
    if [ "$KEEP_RESOURCES" = true ]; then
        warn "Keeping resources (--keep): app=$APP_NAME machine=$MACHINE_ID"
        return
    fi
    if [ -n "$MACHINE_ID" ] && [ -n "$APP_NAME" ]; then
        info "Destroying machine $MACHINE_ID..."
        curl -sf -X DELETE \
            -H "Authorization: Bearer $FLY_TOKEN" \
            "$FLY_API_BASE/v1/apps/$APP_NAME/machines/$MACHINE_ID?force=true" >/dev/null 2>&1 || true
    fi
    if [ -n "$APP_NAME" ]; then
        info "Deleting app $APP_NAME..."
        curl -sf -X DELETE \
            -H "Authorization: Bearer $FLY_TOKEN" \
            "$FLY_API_BASE/v1/apps/$APP_NAME" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

echo "=== Fly.io Cloud Workspace Provisioning Test ==="
echo "Repo: $REPO_SLUG"
echo ""

# ---- Step 1: Get API token ----
info "Getting fly.io API token..."
FLY_TOKEN=""
if [ -n "${FLY_API_TOKEN:-}" ]; then
    FLY_TOKEN="$FLY_API_TOKEN"
elif command -v fly >/dev/null 2>&1; then
    FLY_TOKEN=$(fly auth token 2>/dev/null || true)
elif command -v flyctl >/dev/null 2>&1; then
    FLY_TOKEN=$(flyctl auth token 2>/dev/null || true)
fi

assert "fly.io API token available" [ -n "$FLY_TOKEN" ]
if [ -z "$FLY_TOKEN" ]; then
    echo "Cannot proceed without API token. Run: fly auth login"
    exit 1
fi

# ---- Step 2: Get SSH public key ----
info "Finding SSH public key..."
SSH_PUBKEY=""
for keyfile in ~/.ssh/id_ed25519.pub ~/.ssh/id_rsa.pub ~/.ssh/id_ecdsa.pub; do
    if [ -f "$keyfile" ]; then
        SSH_PUBKEY=$(cat "$keyfile")
        break
    fi
done

assert "SSH public key available" [ -n "$SSH_PUBKEY" ]
if [ -z "$SSH_PUBKEY" ]; then
    echo "No SSH public key found. Run: ssh-keygen -t ed25519"
    exit 1
fi

# ---- Step 3: Sanitize app name ----
info "Sanitizing app name from repo slug..."
# Replicate the Swift sanitizeFlyAppName logic
RAW_NAME=$(echo "$REPO_SLUG" | tr '/' '_' | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_]/_/g' | sed 's/^_//;s/_$//' | cut -c1-30)
APP_NAME="cmux_test_${RAW_NAME}"
APP_NAME=$(echo "$APP_NAME" | cut -c1-30)
info "App name: $APP_NAME"

assert "sanitized app name is valid" echo "$APP_NAME" | grep -qE '^[a-z0-9_]{1,30}$'

# ---- Step 4: Create app ----
info "Creating fly.io app: $APP_NAME"
CREATE_APP_RESP=$(curl -sf -X POST \
    -H "Authorization: Bearer $FLY_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"app_name\": \"$APP_NAME\", \"org_slug\": \"personal\"}" \
    "$FLY_API_BASE/v1/apps" 2>&1 || true)

# 422 = already exists, that's OK
if echo "$CREATE_APP_RESP" | grep -q '"error"' && ! echo "$CREATE_APP_RESP" | grep -q "already exists"; then
    fail "Create app: $CREATE_APP_RESP"
else
    pass "App created or already exists"
fi

# ---- Step 5: Build SSH init script ----
info "Building machine init script..."
INIT_SCRIPT=$(cat <<'INITEOF'
#!/bin/sh
set -e
if ! command -v sshd >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq && apt-get install -y -qq openssh-server >/dev/null
fi
mkdir -p /root/.ssh
chmod 700 /root/.ssh
ssh-keygen -A 2>/dev/null || true
mkdir -p /run/sshd
exec /usr/sbin/sshd -D -e
INITEOF
)

# Write pubkey separately since it contains special chars
INIT_SCRIPT_WITH_KEY="#!/bin/sh
set -e
if ! command -v sshd >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq && apt-get install -y -qq openssh-server >/dev/null
fi
mkdir -p /root/.ssh
echo '${SSH_PUBKEY}' >> /root/.ssh/authorized_keys
chmod 700 /root/.ssh
chmod 600 /root/.ssh/authorized_keys
ssh-keygen -A 2>/dev/null || true
mkdir -p /run/sshd
exec /usr/sbin/sshd -D -e"

# ---- Step 6: Create machine ----
info "Creating machine with ubuntu:24.04..."
# Escape the init script for JSON
ESCAPED_SCRIPT=$(echo "$INIT_SCRIPT_WITH_KEY" | python3 -c "import sys,json; print(json.dumps(sys.stdin.read()))")

CREATE_MACHINE_BODY=$(cat <<MACHEOF
{
  "config": {
    "image": "ubuntu:24.04",
    "guest": {"cpu_kind": "shared", "cpus": 1, "memory_mb": 1024},
    "env": {"CMUX_CLOUD": "1"},
    "init": {"exec": ["/bin/sh", "-c", $ESCAPED_SCRIPT]}
  }
}
MACHEOF
)

CREATE_RESP=$(curl -sf -X POST \
    -H "Authorization: Bearer $FLY_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$CREATE_MACHINE_BODY" \
    "$FLY_API_BASE/v1/apps/$APP_NAME/machines")

MACHINE_ID=$(echo "$CREATE_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])" 2>/dev/null || true)
MACHINE_STATE=$(echo "$CREATE_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin)['state'])" 2>/dev/null || true)

assert "machine created (got ID)" [ -n "$MACHINE_ID" ]
info "Machine ID: $MACHINE_ID, state: $MACHINE_STATE"

# ---- Step 7: Wait for machine to start ----
info "Waiting for machine to start (60s timeout)..."
WAIT_RESP=$(curl -sf \
    -H "Authorization: Bearer $FLY_TOKEN" \
    "$FLY_API_BASE/v1/apps/$APP_NAME/machines/$MACHINE_ID/wait?state=started&timeout=60" 2>&1 || true)

# Check state
STATE_RESP=$(curl -sf \
    -H "Authorization: Bearer $FLY_TOKEN" \
    "$FLY_API_BASE/v1/apps/$APP_NAME/machines/$MACHINE_ID")

FINAL_STATE=$(echo "$STATE_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin)['state'])" 2>/dev/null || true)
assert "machine is started" [ "$FINAL_STATE" = "started" ]

# ---- Step 8: Test SSH via fly proxy ----
info "Launching fly proxy for SSH..."
FLY_CMD=$(command -v fly || command -v flyctl || echo "")
if [ -z "$FLY_CMD" ]; then
    warn "fly CLI not found, skipping SSH test"
else
    # Find a free port
    LOCAL_PORT=$(python3 -c "import socket; s=socket.socket(); s.bind(('127.0.0.1',0)); print(s.getsockname()[1]); s.close()")

    FLY_API_TOKEN="$FLY_TOKEN" FLY_MACHINE="$MACHINE_ID" \
        "$FLY_CMD" proxy "$LOCAL_PORT:22" -a "$APP_NAME" &
    PROXY_PID=$!

    sleep 2

    assert "fly proxy is running" kill -0 "$PROXY_PID" 2>/dev/null

    # Wait for SSH to become available (sshd may still be installing)
    info "Probing SSH on localhost:$LOCAL_PORT..."
    SSH_OK=false
    for i in $(seq 1 30); do
        if nc -z -w2 127.0.0.1 "$LOCAL_PORT" 2>/dev/null; then
            SSH_OK=true
            break
        fi
        sleep 2
    done

    assert "SSH port reachable via fly proxy" [ "$SSH_OK" = true ]

    if [ "$SSH_OK" = true ]; then
        info "Testing SSH connection..."
        SSH_RESULT=$(ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -o LogLevel=ERROR -o ConnectTimeout=10 \
            -p "$LOCAL_PORT" root@127.0.0.1 "echo CMUX_SSH_OK" 2>/dev/null || true)
        assert "SSH command executed successfully" [ "$SSH_RESULT" = "CMUX_SSH_OK" ]

        if [ "$SSH_RESULT" = "CMUX_SSH_OK" ]; then
            info "Testing git clone on remote..."
            CLONE_RESULT=$(ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
                -o LogLevel=ERROR -o ConnectTimeout=30 -o ForwardAgent=yes \
                -p "$LOCAL_PORT" root@127.0.0.1 \
                "apt-get update -qq && apt-get install -y -qq git >/dev/null 2>&1; git clone --depth 1 https://github.com/${REPO_SLUG}.git /tmp/test-repo && echo CLONE_OK" 2>/dev/null || true)
            assert "git clone succeeded on remote" echo "$CLONE_RESULT" | grep -q "CLONE_OK"
        fi
    fi

    # Stop proxy
    kill "$PROXY_PID" 2>/dev/null || true
    wait "$PROXY_PID" 2>/dev/null || true
    PROXY_PID=""
fi

# ---- Step 9: Stop machine ----
info "Stopping machine..."
curl -sf -X POST \
    -H "Authorization: Bearer $FLY_TOKEN" \
    "$FLY_API_BASE/v1/apps/$APP_NAME/machines/$MACHINE_ID/stop" >/dev/null 2>&1 || true

sleep 2

STOP_RESP=$(curl -sf \
    -H "Authorization: Bearer $FLY_TOKEN" \
    "$FLY_API_BASE/v1/apps/$APP_NAME/machines/$MACHINE_ID")
STOP_STATE=$(echo "$STOP_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin)['state'])" 2>/dev/null || true)
assert "machine stopped or stopping" echo "$STOP_STATE" | grep -qE "stop|suspend"

# ---- Step 10: Restart machine (fast resume) ----
info "Restarting machine (fast resume test)..."
START_TIME=$(python3 -c "import time; print(time.time())")

curl -sf -X POST \
    -H "Authorization: Bearer $FLY_TOKEN" \
    "$FLY_API_BASE/v1/apps/$APP_NAME/machines/$MACHINE_ID/start" >/dev/null 2>&1

curl -sf \
    -H "Authorization: Bearer $FLY_TOKEN" \
    "$FLY_API_BASE/v1/apps/$APP_NAME/machines/$MACHINE_ID/wait?state=started&timeout=30" >/dev/null 2>&1 || true

END_TIME=$(python3 -c "import time; print(time.time())")
RESUME_SECONDS=$(python3 -c "print(f'{$END_TIME - $START_TIME:.1f}')")
info "Resume took ${RESUME_SECONDS}s"
assert "machine resumed in under 10s" python3 -c "exit(0 if $END_TIME - $START_TIME < 10 else 1)"

# ---- Summary ----
echo ""
echo "=== Results ==="
echo -e "Total: $TESTS_RUN  ${GREEN}Passed: $TESTS_PASSED${NC}  ${RED}Failed: $TESTS_FAILED${NC}"
echo ""

if [ $TESTS_FAILED -gt 0 ]; then
    exit 1
fi
