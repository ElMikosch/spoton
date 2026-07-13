#!/bin/bash
# spoton-pkce-audiokey-test.sh — PKCE OAuth + Audio Key Diagnostic
#
# Tests whether PKCE-derived credentials can retrieve audio keys.
# This answers the critical question: will v3.0 auth overhaul fix
# playback for accounts affected by Keymaster 403?
#
# CONTEXT: We know Keymaster 403 affects some accounts (token layer).
# We also know PKCE fixes the token layer (Browse/Search/Library).
# What we DON'T know: does the audio key layer (track decryption)
# also work with PKCE-derived credentials for YOUR account?
# This script tests exactly that.
#
# Flow:
#   1. PKCE OAuth flow (browser + copy-paste callback URL)
#   2. Web API sanity check (GET /me, GET /search)
#   3. Credential derivation (spoton --token-login)
#   4. Start Connect receiver daemon with PKCE credentials
#   5. Transfer playback + play a track via Web API
#   6. Monitor daemon logs for audio key success/failure
#
# Requirements:
#   - spoton binary accessible on this machine (installed SpotOn plugin)
#   - A web browser (on any device) to complete OAuth login
#   - Spotify Premium account
#   - curl, openssl, python3
#
# Usage:
#   bash spoton-pkce-audiokey-test.sh
#
# Docker:
#   docker exec -it <container> bash spoton-pkce-audiokey-test.sh
#
# Custom LMS cache path:
#   CACHE_DIR=/config/cache bash spoton-pkce-audiokey-test.sh

set -euo pipefail

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
DIM='\033[2m'
NC='\033[0m'
BOLD='\033[1m'

# --- Configuration ---
# Client ID from YOUR Spotify Developer App (https://developer.spotify.com/dashboard)
# The app must have the redirect URI below registered.
if [ -z "${CLIENT_ID:-}" ]; then
    echo -e "${BOLD}SpotOn PKCE + Audio Key Diagnostic${NC}"
    echo ""
    echo "  This script requires your own Spotify Developer App Client ID."
    echo "  Create one at: https://developer.spotify.com/dashboard"
    echo ""
    echo "  Then add this Redirect URI in your app settings:"
    echo "    http://127.0.0.1:8989/callback"
    echo ""
    echo "  Run with:  CLIENT_ID=your_client_id bash $0"
    echo ""
    read -r -p "  Or enter your Client ID now: " CLIENT_ID
    if [ -z "$CLIENT_ID" ]; then
        echo -e "${RED}ERROR:${NC} No Client ID provided."
        exit 1
    fi
fi
REDIRECT_URI="http://127.0.0.1:8989/callback"
SCOPES="streaming user-read-private user-read-playback-state user-modify-playback-state user-read-currently-playing"
TEST_TRACK_URI="spotify:track:4PTG3Z6ehGkBFwjybzWkR8"  # Rick Astley - Never Gonna Give You Up
TEST_DEVICE_NAME="SpotOn-PKCE-Test-$$"

# Temp directory for this test run
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/spoton-pkce-test.XXXXXX")
LOG_FILE="${TEST_DIR}/daemon.log"
PID_FILE="${TEST_DIR}/daemon.pid"

cleanup() {
    echo ""
    echo -e "${DIM}--- Cleanup ---${NC}"
    if [ -f "$PID_FILE" ]; then
        local pid
        pid=$(cat "$PID_FILE" 2>/dev/null || true)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            echo -e "${DIM}  Stopping test daemon (PID $pid)...${NC}"
            kill "$pid" 2>/dev/null || true
            sleep 1
            kill -9 "$pid" 2>/dev/null || true
        fi
    fi
    echo -e "${DIM}  Test directory: ${TEST_DIR}${NC}"
    echo -e "${DIM}  (not removed — inspect logs with: cat ${LOG_FILE})${NC}"
}
trap cleanup EXIT

log_debug() {
    echo -e "${DIM}  [DEBUG] $*${NC}"
}

log_step() {
    echo ""
    echo -e "${BOLD}$*${NC}"
}

log_result() {
    echo -e "  $*"
}

# ============================================================
# STEP 0: Find the spoton binary
# ============================================================

log_step "STEP 0: Finding spoton binary"

BINARY=""

if [ -z "${CACHE_DIR:-}" ]; then
    for candidate in \
        "/var/lib/squeezeboxserver/cache" \
        "/srv/squeezebox/cache" \
        "$HOME/.squeezebox/cache" \
        "$HOME/Library/Caches/Squeezebox"; do
        if [ -d "$candidate/spoton" ]; then
            CACHE_DIR="$candidate"
            break
        fi
    done
fi

ARCH=$(uname -m)
case "$ARCH" in
    x86_64)         BIN_ARCHS="x86_64-linux" ;;
    aarch64|arm64)  BIN_ARCHS="aarch64-linux armhf-linux" ;;
    armv7*|armv6*)  BIN_ARCHS="armhf-linux" ;;
    i686|i386)      BIN_ARCHS="i386-linux" ;;
    *)              BIN_ARCHS="" ;;
esac

PLUGIN_DIRS=(
    "${CACHE_DIR:-/nonexistent}/InstalledPlugins/Plugins/SpotOn"
    "/var/lib/squeezeboxserver/Plugins/SpotOn"
    "/usr/share/squeezeboxserver/Plugins/SpotOn"
)

for pdir in "${PLUGIN_DIRS[@]}"; do
    [ -d "$pdir/Bin" ] || continue
    for arch in $BIN_ARCHS; do
        candidate="${pdir}/Bin/${arch}/spoton"
        if [ -x "$candidate" ]; then
            BINARY="$candidate"
            break 2
        fi
    done
done

if [ -z "$BINARY" ]; then
    for name in spoton spoton-custom; do
        if command -v "$name" >/dev/null 2>&1; then
            BINARY=$(command -v "$name")
            break
        fi
    done
fi

if [ -z "$BINARY" ]; then
    echo -e "${RED}ERROR:${NC} Could not find the spoton binary."
    echo "  Searched plugin dirs and PATH."
    exit 1
fi

CHECK_OUTPUT=$("$BINARY" --check 2>&1 || true)
if ! echo "$CHECK_OUTPUT" | grep -q "^ok spoton"; then
    echo -e "${RED}ERROR:${NC} Binary --check failed: $BINARY"
    echo "  Output: $CHECK_OUTPUT"
    exit 1
fi

BIN_VERSION=$(echo "$CHECK_OUTPUT" | head -1 | sed 's/ok spoton v//')
log_debug "Binary: $BINARY (v${BIN_VERSION})"
log_debug "Capabilities: $(echo "$CHECK_OUTPUT" | tail -1)"

if ! echo "$CHECK_OUTPUT" | grep -q '"token-login":true'; then
    echo -e "${RED}ERROR:${NC} Binary does not support --token-login. Need v2.0.0+."
    exit 1
fi

log_debug "Test directory: $TEST_DIR"
log_debug "Device name: $TEST_DEVICE_NAME"
echo -e "  ${GREEN}✓${NC} Binary OK — v${BIN_VERSION} with token-login support"

# ============================================================
# STEP 1: PKCE OAuth Flow
# ============================================================

log_step "STEP 1: PKCE OAuth Flow"

# Generate code_verifier (43-128 chars, unreserved URI characters)
# NOTE: openssl base64 wraps at 76 chars — must strip \n too!
CODE_VERIFIER=$(openssl rand -base64 96 | tr -d '=+/\n' | head -c 128)
log_debug "code_verifier length: ${#CODE_VERIFIER}"

# Generate code_challenge = BASE64URL(SHA256(code_verifier))
CODE_CHALLENGE=$(printf '%s' "$CODE_VERIFIER" | openssl dgst -sha256 -binary | openssl base64 -A | tr '+/' '-_' | tr -d '=')
log_debug "code_challenge: ${CODE_CHALLENGE:0:20}..."

# Generate state parameter for CSRF protection
STATE=$(openssl rand -hex 16)
log_debug "state: $STATE"

# Build authorization URL
AUTH_URL="https://accounts.spotify.com/authorize"
AUTH_URL+="?client_id=${CLIENT_ID}"
AUTH_URL+="&response_type=code"
# URL-encode the redirect URI (hardcoded since it's a known value)
REDIRECT_URI_ENCODED="http%3A%2F%2F127.0.0.1%3A8989%2Fcallback"
AUTH_URL+="&redirect_uri=${REDIRECT_URI_ENCODED}"
AUTH_URL+="&scope=$(echo "$SCOPES" | tr ' ' '+')"
AUTH_URL+="&code_challenge_method=S256"
AUTH_URL+="&code_challenge=${CODE_CHALLENGE}"
AUTH_URL+="&state=${STATE}"

echo ""
echo -e "  ${CYAN}═══════════════════════════════════════════════════════════${NC}"
echo -e "  ${CYAN}Open this URL in your browser (any device):${NC}"
echo -e "  ${CYAN}═══════════════════════════════════════════════════════════${NC}"
echo ""
echo "  $AUTH_URL"
echo ""
echo -e "  ${CYAN}After authorizing in Spotify:${NC}"
echo -e "  ${CYAN}  1. Your browser will try to redirect to 127.0.0.1:8989${NC}"
echo -e "  ${CYAN}  2. The page will NOT load — this is expected!${NC}"
echo -e "  ${CYAN}  3. Copy the FULL URL from your browser's address bar${NC}"
echo -e "  ${CYAN}     It looks like: http://127.0.0.1:8989/callback?code=AQD...&state=...${NC}"
echo -e "  ${CYAN}  4. Paste that URL here:${NC}"
echo ""
read -r -p "  Callback URL: " CALLBACK_URL

if [ -z "$CALLBACK_URL" ]; then
    echo -e "${RED}ERROR:${NC} No callback URL provided."
    exit 1
fi

# Extract authorization code and state from callback URL
# Using python3 for reliable URL parsing (grep -oP not available on all systems)
AUTH_CODE=$(python3 -c "
from urllib.parse import urlparse, parse_qs
import sys
q = parse_qs(urlparse(sys.argv[1]).query)
print(q.get('code',[''])[0])
" "$CALLBACK_URL" 2>/dev/null || true)
RETURN_STATE=$(python3 -c "
from urllib.parse import urlparse, parse_qs
import sys
q = parse_qs(urlparse(sys.argv[1]).query)
print(q.get('state',[''])[0])
" "$CALLBACK_URL" 2>/dev/null || true)
ERROR_PARAM=$(python3 -c "
from urllib.parse import urlparse, parse_qs
import sys
q = parse_qs(urlparse(sys.argv[1]).query)
print(q.get('error',[''])[0])
" "$CALLBACK_URL" 2>/dev/null || true)

log_debug "Extracted code: ${AUTH_CODE:0:20}... (${#AUTH_CODE} chars)"
log_debug "Extracted state: $RETURN_STATE"

if [ -n "$ERROR_PARAM" ]; then
    echo -e "${RED}ERROR:${NC} OAuth error: $ERROR_PARAM"
    ERROR_DESC=$(python3 -c "
from urllib.parse import urlparse, parse_qs
import sys
q = parse_qs(urlparse(sys.argv[1]).query)
print(q.get('error_description',[''])[0])
" "$CALLBACK_URL" 2>/dev/null || true)
    [ -n "$ERROR_DESC" ] && echo "  Description: $ERROR_DESC"
    exit 1
fi

if [ -z "$AUTH_CODE" ]; then
    echo -e "${RED}ERROR:${NC} Could not extract authorization code from URL."
    echo "  URL was: $CALLBACK_URL"
    exit 1
fi

if [ "$RETURN_STATE" != "$STATE" ]; then
    echo -e "${YELLOW}WARNING:${NC} State mismatch (CSRF check failed)."
    echo "  Expected: $STATE"
    echo "  Got:      $RETURN_STATE"
    echo "  Continuing anyway (diagnostic mode)..."
fi

echo -e "  ${GREEN}✓${NC} Authorization code received"

# Exchange code for tokens
log_debug "Exchanging code for tokens..."
log_debug "POST https://accounts.spotify.com/api/token"
log_debug "  grant_type=authorization_code"
log_debug "  client_id=$CLIENT_ID"
log_debug "  redirect_uri=$REDIRECT_URI"
log_debug "  code_verifier length=${#CODE_VERIFIER}"

TOKEN_RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "https://accounts.spotify.com/api/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "grant_type=authorization_code" \
    -d "code=${AUTH_CODE}" \
    -d "redirect_uri=${REDIRECT_URI}" \
    -d "client_id=${CLIENT_ID}" \
    -d "code_verifier=${CODE_VERIFIER}")

TOKEN_HTTP_CODE=$(echo "$TOKEN_RESPONSE" | tail -1)
TOKEN_BODY=$(echo "$TOKEN_RESPONSE" | sed '$d')

log_debug "Token exchange HTTP status: $TOKEN_HTTP_CODE"
log_debug "Token response (sanitized): $(echo "$TOKEN_BODY" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    if 'access_token' in d:
        d['access_token'] = d['access_token'][:20] + '...[REDACTED]'
    if 'refresh_token' in d:
        d['refresh_token'] = d['refresh_token'][:10] + '...[REDACTED]'
    print(json.dumps(d, indent=2))
except:
    print(sys.stdin.read())
" 2>/dev/null <<< "$TOKEN_BODY" || echo "$TOKEN_BODY")"

if [ "$TOKEN_HTTP_CODE" != "200" ]; then
    echo -e "${RED}ERROR:${NC} Token exchange failed (HTTP $TOKEN_HTTP_CODE)"
    echo "  Response: $TOKEN_BODY"
    exit 1
fi

ACCESS_TOKEN=$(echo "$TOKEN_BODY" | python3 -c "import sys,json; print(json.load(sys.stdin).get('access_token',''))" 2>/dev/null || true)
REFRESH_TOKEN=$(echo "$TOKEN_BODY" | python3 -c "import sys,json; print(json.load(sys.stdin).get('refresh_token',''))" 2>/dev/null || true)
TOKEN_TYPE=$(echo "$TOKEN_BODY" | python3 -c "import sys,json; print(json.load(sys.stdin).get('token_type',''))" 2>/dev/null || true)
EXPIRES_IN=$(echo "$TOKEN_BODY" | python3 -c "import sys,json; print(json.load(sys.stdin).get('expires_in',''))" 2>/dev/null || true)
TOKEN_SCOPE=$(echo "$TOKEN_BODY" | python3 -c "import sys,json; print(json.load(sys.stdin).get('scope',''))" 2>/dev/null || true)

if [ -z "$ACCESS_TOKEN" ]; then
    echo -e "${RED}ERROR:${NC} No access_token in response"
    echo "  Response: $TOKEN_BODY"
    exit 1
fi

log_debug "Token type: $TOKEN_TYPE"
log_debug "Expires in: ${EXPIRES_IN}s"
log_debug "Scopes granted: $TOKEN_SCOPE"
echo -e "  ${GREEN}✓${NC} PKCE token exchange successful (expires in ${EXPIRES_IN}s)"

# ============================================================
# STEP 2: Web API Sanity Check
# ============================================================

log_step "STEP 2: Web API Sanity Check"

# Test GET /me
log_debug "GET https://api.spotify.com/v1/me"
ME_RESPONSE=$(curl -s -w "\n%{http_code}" -H "Authorization: Bearer $ACCESS_TOKEN" \
    "https://api.spotify.com/v1/me")
ME_HTTP=$(echo "$ME_RESPONSE" | tail -1)
ME_BODY=$(echo "$ME_RESPONSE" | sed '$d')

log_debug "/me HTTP status: $ME_HTTP"
if [ "$ME_HTTP" = "200" ]; then
    ME_DISPLAY=$(echo "$ME_BODY" | python3 -c "import sys,json; d=json.load(sys.stdin); print(f\"id={d.get('id','?')}, display_name={d.get('display_name','?')}, product={d.get('product','?')}\")" 2>/dev/null || echo "parse error")
    log_debug "/me: $ME_DISPLAY"
    SPOTIFY_USER_ID=$(echo "$ME_BODY" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || true)
    SPOTIFY_PRODUCT=$(echo "$ME_BODY" | python3 -c "import sys,json; print(json.load(sys.stdin).get('product','unknown'))" 2>/dev/null || true)
    log_result "${GREEN}✓${NC} GET /me OK — user=$SPOTIFY_USER_ID, product=$SPOTIFY_PRODUCT"
else
    log_result "${RED}✗${NC} GET /me FAILED (HTTP $ME_HTTP)"
    log_debug "Response: $ME_BODY"
fi

# Test GET /search
log_debug "GET https://api.spotify.com/v1/search?q=test&type=track&limit=1"
SEARCH_RESPONSE=$(curl -s -w "\n%{http_code}" -H "Authorization: Bearer $ACCESS_TOKEN" \
    "https://api.spotify.com/v1/search?q=test&type=track&limit=1")
SEARCH_HTTP=$(echo "$SEARCH_RESPONSE" | tail -1)
SEARCH_BODY=$(echo "$SEARCH_RESPONSE" | sed '$d')

log_debug "/search HTTP status: $SEARCH_HTTP"
if [ "$SEARCH_HTTP" = "200" ]; then
    SEARCH_TOTAL=$(echo "$SEARCH_BODY" | python3 -c "import sys,json; print(json.load(sys.stdin)['tracks']['total'])" 2>/dev/null || echo "?")
    SEARCH_FIRST=$(echo "$SEARCH_BODY" | python3 -c "
import sys,json
d=json.load(sys.stdin)
t=d['tracks']['items'][0]
print(f\"{t['name']} — {t['artists'][0]['name']}\")
" 2>/dev/null || echo "?")
    log_debug "Search found $SEARCH_TOTAL results, first: $SEARCH_FIRST"
    log_result "${GREEN}✓${NC} GET /search OK — $SEARCH_TOTAL results"
else
    log_result "${RED}✗${NC} GET /search FAILED (HTTP $SEARCH_HTTP)"
    log_debug "Response: $SEARCH_BODY"
fi

# Test GET /me/player/devices (important for later)
log_debug "GET https://api.spotify.com/v1/me/player/devices"
DEVICES_RESPONSE=$(curl -s -w "\n%{http_code}" -H "Authorization: Bearer $ACCESS_TOKEN" \
    "https://api.spotify.com/v1/me/player/devices")
DEVICES_HTTP=$(echo "$DEVICES_RESPONSE" | tail -1)
DEVICES_BODY=$(echo "$DEVICES_RESPONSE" | sed '$d')

log_debug "/me/player/devices HTTP status: $DEVICES_HTTP"
if [ "$DEVICES_HTTP" = "200" ]; then
    DEVICE_COUNT=$(echo "$DEVICES_BODY" | python3 -c "import sys,json; print(len(json.load(sys.stdin).get('devices',[])))" 2>/dev/null || echo "?")
    DEVICE_LIST=$(echo "$DEVICES_BODY" | python3 -c "
import sys,json
for d in json.load(sys.stdin).get('devices',[]):
    print(f\"    {d['name']} ({d['type']}, id={d['id'][:12]}..., active={d['is_active']})\")" 2>/dev/null || echo "    (parse error)")
    log_debug "Devices before test:"
    echo "$DEVICE_LIST" | while read -r line; do log_debug "$line"; done
    log_result "${GREEN}✓${NC} GET /me/player/devices OK — $DEVICE_COUNT device(s) visible"
else
    log_result "${RED}✗${NC} GET /me/player/devices FAILED (HTTP $DEVICES_HTTP)"
    log_debug "Response: $DEVICES_BODY"
fi

# ============================================================
# STEP 3: Credential Derivation (--token-login)
# ============================================================

log_step "STEP 3: Credential Derivation (--token-login)"

CRED_DIR="${TEST_DIR}/credentials"
mkdir -p "$CRED_DIR"

log_debug "Command: $BINARY -n '$TEST_DEVICE_NAME' --token-login --token <REDACTED> --cache $CRED_DIR"
log_debug "This connects to Spotify AP, exchanges OAuth token for reusable credentials..."

TOKEN_LOGIN_OUTPUT=$( RUST_LOG=debug "$BINARY" -n "$TEST_DEVICE_NAME" --token-login --token "$ACCESS_TOKEN" --cache "$CRED_DIR" 2>&1 || true)

# Separate stdout/stderr for analysis
TOKEN_LOGIN_STDOUT=$(echo "$TOKEN_LOGIN_OUTPUT" | grep -v '^\[' | grep -v '^[0-9]\{4\}-' || true)
TOKEN_LOGIN_STDERR=$(echo "$TOKEN_LOGIN_OUTPUT" | grep -E '^\[|^[0-9]{4}-' || true)

log_debug "token-login stdout: $TOKEN_LOGIN_STDOUT"
if [ -n "$TOKEN_LOGIN_STDERR" ]; then
    log_debug "token-login debug log:"
    echo "$TOKEN_LOGIN_STDERR" | head -30 | while IFS= read -r line; do log_debug "  $line"; done
fi

if echo "$TOKEN_LOGIN_STDOUT" | grep -q "credentials_saved"; then
    log_result "${GREEN}✓${NC} Credential derivation successful"
    if [ -f "${CRED_DIR}/credentials.json" ]; then
        CRED_USER=$(python3 -c "import json; print(json.load(open('${CRED_DIR}/credentials.json')).get('username','?'))" 2>/dev/null || echo "?")
        CRED_TYPE=$(python3 -c "import json; print(json.load(open('${CRED_DIR}/credentials.json')).get('auth_type',0))" 2>/dev/null || echo "?")
        log_debug "credentials.json: username=$CRED_USER, auth_type=$CRED_TYPE"
        log_result "  Stored credentials for user: ${BOLD}$CRED_USER${NC}"
    else
        log_debug "WARNING: credentials_saved reported but no credentials.json found in $CRED_DIR"
    fi
else
    log_result "${RED}✗${NC} Credential derivation FAILED"
    echo "  Full output:"
    echo "$TOKEN_LOGIN_OUTPUT" | sed 's/^/    /'
    echo ""
    echo -e "  ${YELLOW}This means the OAuth token could not be converted to${NC}"
    echo -e "  ${YELLOW}reusable Spotify credentials. Audio key test cannot proceed.${NC}"
    exit 1
fi

# ============================================================
# STEP 4: Audio Key Test — Start Connect Daemon + Play Track
# ============================================================

log_step "STEP 4: Audio Key Test"

echo -e "  Starting test daemon as Connect receiver..."
log_debug "Command: RUST_LOG=debug $BINARY -n '$TEST_DEVICE_NAME' --unified --enable-connect --disable-discovery --cache $CRED_DIR"
log_debug "Logs: $LOG_FILE"

# Start daemon in background with debug logging
# --disable-discovery: No mDNS/ZeroConf announcement. We don't want ZeroConf
# credentials overwriting our PKCE-derived ones. The device still registers
# with Spotify's cloud via Spirc (part of the Shannon session), so it appears
# in GET /me/player/devices and can be controlled via Web API.
RUST_LOG=debug "$BINARY" \
    -n "$TEST_DEVICE_NAME" \
    --unified \
    --enable-connect \
    --disable-discovery \
    --cache "$CRED_DIR" \
    > /dev/null 2> "$LOG_FILE" &
DAEMON_PID=$!
echo "$DAEMON_PID" > "$PID_FILE"

log_debug "Daemon PID: $DAEMON_PID"

# Wait for daemon to start (check for Spirc or session ready)
echo -e "  Waiting for daemon to initialize..."
READY=0
for i in $(seq 1 15); do
    if ! kill -0 "$DAEMON_PID" 2>/dev/null; then
        echo -e "  ${RED}✗${NC} Daemon exited prematurely"
        log_debug "Daemon exit — last 30 lines of log:"
        tail -30 "$LOG_FILE" | while IFS= read -r line; do log_debug "  $line"; done
        exit 1
    fi
    if grep -qi "authenticated\|spirc\|session\|spotify_id\|connected" "$LOG_FILE" 2>/dev/null; then
        READY=1
        break
    fi
    log_debug "  Waiting... (attempt $i/15)"
    sleep 2
done

if [ "$READY" -eq 0 ]; then
    echo -e "  ${YELLOW}WARNING:${NC} Daemon may not be fully ready (no session marker in logs after 30s)"
    log_debug "Log so far:"
    cat "$LOG_FILE" | while IFS= read -r line; do log_debug "  $line"; done
fi

# Wait a bit more for Spirc to register with Spotify
sleep 3
log_debug "Daemon running for ~$(( (i * 2) + 3 ))s"

# Check if our test device is visible via Web API
log_debug "Checking if test device is visible..."
DEVICES_RESPONSE=$(curl -s -w "\n%{http_code}" -H "Authorization: Bearer $ACCESS_TOKEN" \
    "https://api.spotify.com/v1/me/player/devices")
DEVICES_HTTP=$(echo "$DEVICES_RESPONSE" | tail -1)
DEVICES_BODY=$(echo "$DEVICES_RESPONSE" | sed '$d')

log_debug "/me/player/devices HTTP $DEVICES_HTTP"
TEST_DEVICE_ID=""
if [ "$DEVICES_HTTP" = "200" ]; then
    TEST_DEVICE_ID=$(echo "$DEVICES_BODY" | python3 -c "
import sys,json
for d in json.load(sys.stdin).get('devices',[]):
    if '$TEST_DEVICE_NAME' in d['name']:
        print(d['id'])
        break
" 2>/dev/null || true)

    ALL_DEVICES=$(echo "$DEVICES_BODY" | python3 -c "
import sys,json
for d in json.load(sys.stdin).get('devices',[]):
    print(f\"  {d['name']} (type={d['type']}, id={d['id'][:12]}..., active={d['is_active']})\")" 2>/dev/null || true)
    log_debug "All devices now visible:"
    echo "$ALL_DEVICES" | while IFS= read -r line; do log_debug "  $line"; done
fi

if [ -z "$TEST_DEVICE_ID" ]; then
    echo -e "  ${YELLOW}WARNING:${NC} Test device not yet visible via Web API."
    log_debug "Device not found — Spirc cloud registration may take a few seconds..."
    log_debug "Waiting 10s and retrying..."
    sleep 10

    DEVICES_RESPONSE=$(curl -s -w "\n%{http_code}" -H "Authorization: Bearer $ACCESS_TOKEN" \
        "https://api.spotify.com/v1/me/player/devices")
    DEVICES_HTTP=$(echo "$DEVICES_RESPONSE" | tail -1)
    DEVICES_BODY=$(echo "$DEVICES_RESPONSE" | sed '$d')

    TEST_DEVICE_ID=$(echo "$DEVICES_BODY" | python3 -c "
import sys,json
for d in json.load(sys.stdin).get('devices',[]):
    if '$TEST_DEVICE_NAME' in d['name']:
        print(d['id'])
        break
" 2>/dev/null || true)

    if [ -z "$TEST_DEVICE_ID" ]; then
        log_debug "Still not visible. Listing all devices:"
        echo "$DEVICES_BODY" | python3 -c "
import sys,json
for d in json.load(sys.stdin).get('devices',[]):
    print(f\"  {d['name']} ({d['type']}, id={d['id'][:12]}...)\")" 2>/dev/null || true
    fi
fi

if [ -z "$TEST_DEVICE_ID" ]; then
    echo -e "  ${YELLOW}NOTE:${NC} No devices visible. The Connect daemon is running but not visible via API."
    echo -e "  Testing audio key retrieval from daemon logs instead..."
    echo ""
    echo -e "  ${CYAN}Alternative: Open the Spotify app on your phone/desktop,${NC}"
    echo -e "  ${CYAN}look for '${TEST_DEVICE_NAME}' in the device list, and play a track.${NC}"
    echo -e "  ${CYAN}Press Enter when you've started playback (or just Enter to skip):${NC}"
    read -r -p "  " _DUMMY
else
    log_debug "Test device ID: $TEST_DEVICE_ID"
    log_result "Test device visible: ${BOLD}$TEST_DEVICE_NAME${NC}"

    # Transfer playback to our test device
    log_debug "Transferring playback to test device..."
    log_debug "PUT https://api.spotify.com/v1/me/player"
    TRANSFER_RESPONSE=$(curl -s -w "\n%{http_code}" -X PUT \
        "https://api.spotify.com/v1/me/player" \
        -H "Authorization: Bearer $ACCESS_TOKEN" \
        -H "Content-Type: application/json" \
        -d "{\"device_ids\":[\"$TEST_DEVICE_ID\"],\"play\":false}")
    TRANSFER_HTTP=$(echo "$TRANSFER_RESPONSE" | tail -1)
    log_debug "Transfer HTTP status: $TRANSFER_HTTP"

    sleep 2

    # Play a track
    log_debug "Starting playback: $TEST_TRACK_URI"
    log_debug "PUT https://api.spotify.com/v1/me/player/play?device_id=$TEST_DEVICE_ID"
    PLAY_RESPONSE=$(curl -s -w "\n%{http_code}" -X PUT \
        "https://api.spotify.com/v1/me/player/play?device_id=$TEST_DEVICE_ID" \
        -H "Authorization: Bearer $ACCESS_TOKEN" \
        -H "Content-Type: application/json" \
        -d "{\"uris\":[\"$TEST_TRACK_URI\"]}")
    PLAY_HTTP=$(echo "$PLAY_RESPONSE" | tail -1)
    PLAY_BODY=$(echo "$PLAY_RESPONSE" | sed '$d')
    log_debug "Play HTTP status: $PLAY_HTTP"
    [ -n "$PLAY_BODY" ] && log_debug "Play response: $PLAY_BODY"

    if [ "$PLAY_HTTP" = "204" ] || [ "$PLAY_HTTP" = "202" ]; then
        log_result "${GREEN}✓${NC} Play command accepted (HTTP $PLAY_HTTP)"
    else
        log_result "${YELLOW}⚠${NC} Play command returned HTTP $PLAY_HTTP"
        log_debug "Response body: $PLAY_BODY"
    fi
fi

# Wait for audio key request/response in logs
echo -e "  Waiting for audio key negotiation (10s)..."
sleep 10

# ============================================================
# STEP 5: Log Analysis
# ============================================================

log_step "STEP 5: Log Analysis — Audio Key Result"

LOG_LINES=$(wc -l < "$LOG_FILE" 2>/dev/null || echo "0")
log_debug "Daemon log: $LOG_LINES lines"

# Check for various outcomes
HAS_AUDIO_KEY_ERROR=$(grep -ci "audio.key.*error\|error.*audio.key\|audio key.*fail\|key error\|AudioKeyError\|audio_key.*0.*1\|channel error" "$LOG_FILE" 2>/dev/null || true)
HAS_AUDIO_KEY_OK=$(grep -ci "audio.key.*ok\|audio.key.*received\|audio key response\|key loaded\|audio.*key.*success" "$LOG_FILE" 2>/dev/null || true)
HAS_SESSION_ERROR=$(grep -ci "session.*error\|connection.*error\|mercury.*error\|authentication.*fail\|AP.*error" "$LOG_FILE" 2>/dev/null || true)
HAS_TRACK_LOADING=$(grep -ci "loading.*track\|track.*loading\|fetching.*track\|player.*load" "$LOG_FILE" 2>/dev/null || true)
HAS_PLAYING=$(grep -ci "playing\|PlayerEvent.*Started\|kSinkRunning\|sink.*start" "$LOG_FILE" 2>/dev/null || true)
HAS_403=$(grep -ci "403\|forbidden" "$LOG_FILE" 2>/dev/null || true)
HAS_SPIRC=$(grep -ci "spirc\|SpircTask\|remote.*control" "$LOG_FILE" 2>/dev/null || true)

echo ""
echo -e "  ${BOLD}Log Signals:${NC}"
echo -e "    Spirc/Connect active:     $([ "$HAS_SPIRC" -gt 0 ] && echo -e "${GREEN}YES${NC} ($HAS_SPIRC hits)" || echo -e "${DIM}no${NC}")"
echo -e "    Track loading:            $([ "$HAS_TRACK_LOADING" -gt 0 ] && echo -e "${GREEN}YES${NC} ($HAS_TRACK_LOADING hits)" || echo -e "${DIM}no${NC}")"
echo -e "    Audio key OK:             $([ "$HAS_AUDIO_KEY_OK" -gt 0 ] && echo -e "${GREEN}YES${NC} ($HAS_AUDIO_KEY_OK hits)" || echo -e "${DIM}no${NC}")"
echo -e "    Playing:                  $([ "$HAS_PLAYING" -gt 0 ] && echo -e "${GREEN}YES${NC} ($HAS_PLAYING hits)" || echo -e "${DIM}no${NC}")"
echo -e "    Audio key ERROR:          $([ "$HAS_AUDIO_KEY_ERROR" -gt 0 ] && echo -e "${RED}YES${NC} ($HAS_AUDIO_KEY_ERROR hits)" || echo -e "${DIM}no${NC}")"
echo -e "    Session/mercury error:    $([ "$HAS_SESSION_ERROR" -gt 0 ] && echo -e "${RED}YES${NC} ($HAS_SESSION_ERROR hits)" || echo -e "${DIM}no${NC}")"
echo -e "    HTTP 403 / Forbidden:     $([ "$HAS_403" -gt 0 ] && echo -e "${RED}YES${NC} ($HAS_403 hits)" || echo -e "${DIM}no${NC}")"

echo ""

# Show relevant log excerpts
echo -e "  ${BOLD}Relevant log lines:${NC}"
grep -iE "audio.key|key.*error|track.*load|playing|error|403|forbidden|spirc|session.*established|connected|credential" "$LOG_FILE" 2>/dev/null | tail -40 | while IFS= read -r line; do
    if echo "$line" | grep -qi "error\|fail\|403"; then
        echo -e "    ${RED}$line${NC}"
    elif echo "$line" | grep -qi "playing\|success\|ok\|loaded\|established\|connected"; then
        echo -e "    ${GREEN}$line${NC}"
    else
        echo -e "    ${DIM}$line${NC}"
    fi
done

# ============================================================
# VERDICT
# ============================================================

echo ""
echo "=========================================================="
echo ""

if [ "$HAS_AUDIO_KEY_ERROR" -gt 0 ]; then
    echo -e "  ${RED}${BOLD}VERDICT: AUDIO KEY FAILURE${NC}"
    echo ""
    echo -e "  PKCE credentials connected successfully but audio keys"
    echo -e "  were denied by Spotify. This means v3.0 PKCE auth alone"
    echo -e "  will NOT fix playback for this account."
    echo ""
    echo -e "  The audio key block appears to be at the Shannon session"
    echo -e "  level, independent of the authentication method."
elif [ "$HAS_PLAYING" -gt 0 ] || [ "$HAS_AUDIO_KEY_OK" -gt 0 ]; then
    echo -e "  ${GREEN}${BOLD}VERDICT: AUDIO KEYS WORK WITH PKCE${NC}"
    echo ""
    echo -e "  PKCE-derived credentials successfully obtained audio keys"
    echo -e "  and started playback. v3.0 auth overhaul will fix this"
    echo -e "  account's playback."
elif [ "$HAS_TRACK_LOADING" -gt 0 ]; then
    echo -e "  ${YELLOW}${BOLD}VERDICT: INCONCLUSIVE — Track loading but no clear result${NC}"
    echo ""
    echo -e "  The daemon attempted to load a track but the outcome is unclear."
    echo -e "  Check the full log: cat $LOG_FILE"
elif [ "$HAS_SPIRC" -gt 0 ]; then
    echo -e "  ${YELLOW}${BOLD}VERDICT: INCONCLUSIVE — Connect active but no playback attempted${NC}"
    echo ""
    echo -e "  The daemon registered as a Connect device but no track was played."
    echo -e "  Try playing a track manually from the Spotify app to device '${TEST_DEVICE_NAME}'."
    echo -e "  Then check: grep -i 'audio.key\\|error' $LOG_FILE"
else
    echo -e "  ${YELLOW}${BOLD}VERDICT: INCONCLUSIVE — No playback signals in logs${NC}"
    echo ""
    echo -e "  The daemon may not have connected or no playback was triggered."
    echo -e "  Check the full log: cat $LOG_FILE"
fi

echo ""
echo -e "  ${DIM}Full daemon log: $LOG_FILE${NC}"
echo -e "  ${DIM}Test credentials: $CRED_DIR${NC}"
echo ""
