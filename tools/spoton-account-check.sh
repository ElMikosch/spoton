#!/bin/bash
# spoton-account-check.sh — Keymaster 403 Account Diagnostics
#
# Checks whether your Spotify account is affected by the Keymaster sunset.
# Run on your LMS server via SSH:
#
#   bash spoton-account-check.sh
#
# If your LMS uses a non-standard cache path:
#   CACHE_DIR=/path/to/lms/cache bash spoton-account-check.sh

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'
BOLD='\033[1m'

CLIENT_ID="d420a117a32841c2b3474932e49fb54b"

echo ""
echo -e "${BOLD}SpotOn Account Check — Keymaster 403 Diagnostics${NC}"
echo "=================================================="
echo ""

# --- 1. Find LMS cache directory ---

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

if [ -z "${CACHE_DIR:-}" ]; then
    echo -e "${RED}ERROR:${NC} Could not find LMS cache directory."
    echo ""
    echo "Tried: /var/lib/squeezeboxserver/cache"
    echo "       /srv/squeezebox/cache"
    echo "       ~/.squeezebox/cache"
    echo ""
    echo "Set it manually:  CACHE_DIR=/your/path bash spoton-account-check.sh"
    exit 1
fi

echo -e "  LMS cache:  ${BLUE}${CACHE_DIR}${NC}"

# --- 2. Find the spoton binary ---

BINARY=""
ARCH=$(uname -m)
case "$ARCH" in
    x86_64)         BIN_ARCHS="x86_64-linux" ;;
    aarch64|arm64)  BIN_ARCHS="aarch64-linux armhf-linux" ;;
    armv7*|armv6*)  BIN_ARCHS="armhf-linux" ;;
    i686|i386)      BIN_ARCHS="i386-linux" ;;
    *)              BIN_ARCHS="" ;;
esac

PLUGIN_DIRS=(
    "${CACHE_DIR}/InstalledPlugins/Plugins/SpotOn"
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
    echo "  Looked in plugin dirs under Bin/{${BIN_ARCHS// /,}}/spoton"
    echo "  Also checked PATH for 'spoton' or 'spoton-custom'."
    exit 1
fi

# Verify binary works
CHECK_OUTPUT=$("$BINARY" --check 2>&1 || true)
if ! echo "$CHECK_OUTPUT" | grep -q "^ok spoton"; then
    echo -e "${RED}ERROR:${NC} Binary found but --check failed: $BINARY"
    echo "  Output: $CHECK_OUTPUT"
    exit 1
fi

BIN_VERSION=$(echo "$CHECK_OUTPUT" | head -1 | sed 's/ok spoton v//')
echo -e "  Binary:     ${BLUE}${BINARY}${NC} (v${BIN_VERSION})"

# --- 3. Find stored credentials ---

SPOTON_CACHE="${CACHE_DIR}/spoton"
ACCOUNTS=()

if [ ! -d "$SPOTON_CACHE" ]; then
    echo -e "${RED}ERROR:${NC} No SpotOn cache directory at ${SPOTON_CACHE}"
    echo "  Has SpotOn been used with a Spotify account?"
    exit 1
fi

for dir in "${SPOTON_CACHE}"/*/; do
    [ -d "$dir" ] || continue
    accountId=$(basename "$dir")
    [[ "$accountId" == __* ]] && continue
    [[ "$accountId" == "." ]] && continue
    if [ -f "${dir}credentials.json" ]; then
        ACCOUNTS+=("$accountId")
    fi
done

if [ ${#ACCOUNTS[@]} -eq 0 ]; then
    echo -e "${RED}ERROR:${NC} No stored credentials found in ${SPOTON_CACHE}/"
    echo ""
    echo "  This means either:"
    echo "  - No Spotify account has been connected yet"
    echo "  - Credentials were deleted (e.g. after removing and re-adding account)"
    echo ""
    echo "  To fix: Open SpotOn settings in LMS and reconnect your Spotify account"
    echo "  via 'Connect via Spotify app'. Then re-run this script."
    exit 1
fi

echo -e "  Accounts:   ${BLUE}${#ACCOUNTS[@]}${NC} found"
echo ""
echo "--------------------------------------------------"
echo ""

# --- 4. Test each account ---

ANY_AFFECTED=0

for accountId in "${ACCOUNTS[@]}"; do
    echo -e "  Testing account ${BOLD}${accountId}${NC} ..."
    ACCOUNT_CACHE="${SPOTON_CACHE}/${accountId}"

    OUTPUT=$("$BINARY" --get-token --cache "$ACCOUNT_CACHE" --client-id "$CLIENT_ID" 2>&1 || true)

    if echo "$OUTPUT" | grep -q '"accessToken"'; then
        echo -e "  ${GREEN}✓ NOT AFFECTED${NC} — Keymaster token works fine"
        echo ""
    elif echo "$OUTPUT" | grep -q 'status_code: 403'; then
        ANY_AFFECTED=1
        echo -e "  ${RED}✗ AFFECTED — Keymaster returns HTTP 403${NC}"
        echo ""
        echo -e "  Your account has been moved to Spotify's new auth cohort."
        echo -e "  SpotOn cannot retrieve API tokens via Keymaster for this account."
        echo ""
        echo -e "  ${YELLOW}Impact:${NC}"
        echo "    - Browse, Search, and Library will not work"
        echo "    - Spotify Connect playback may still work"
        echo "    - This is a Spotify-side change, not a SpotOn bug"
        echo ""
    elif echo "$OUTPUT" | grep -qi 'no.*credentials\|credentials.*not found\|authenticate first'; then
        echo -e "  ${YELLOW}? NO CREDENTIALS${NC} — stored credentials invalid or expired"
        echo "    Reconnect via Spotify app, then re-run this script."
        echo ""
    else
        echo -e "  ${YELLOW}? UNCLEAR${NC} — unexpected output:"
        echo "$OUTPUT" | tail -5 | sed 's/^/    /'
        echo ""
    fi
done

# --- 5. Summary ---

echo "--------------------------------------------------"
echo ""
if [ $ANY_AFFECTED -eq 1 ]; then
    echo -e "  ${RED}${BOLD}Result: At least one account is affected.${NC}"
    echo ""
    echo "  This is a known issue tracked at:"
    echo "  https://github.com/stiefenm/spoton/issues/91"
    echo ""
    echo "  A fix (PKCE OAuth) is being developed in SpotOn v3.0."
    echo "  There is currently no workaround for affected accounts."
else
    echo -e "  ${GREEN}${BOLD}Result: All accounts OK — not affected by Keymaster sunset.${NC}"
    echo ""
    echo "  If you're still having issues, they are likely unrelated to the"
    echo "  Keymaster 403 problem. Check your LMS logs for other errors."
fi
echo ""
