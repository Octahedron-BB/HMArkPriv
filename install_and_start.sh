#!/bin/bash
# ==============================================================================
# HMArkPriv Shell Server Installer & Starter (HarmonyOS 7.0)
# ------------------------------------------------------------------------------
# Deploys a lightweight, zero-overhead privileged Shell executor to the device.
# ==============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Locate hdc binary
if [ -x "$PROJECT_ROOT/toolchains/hdc" ]; then
    HDC="$PROJECT_ROOT/toolchains/hdc"
elif command -v hdc >/dev/null 2>&1; then
    HDC="$(command -v hdc)"
else
    echo "[!] Error: 'hdc' binary not found in $PROJECT_ROOT/toolchains/hdc or PATH."
    exit 1
fi

TARGET="$1"
if [ -z "$TARGET" ]; then
    TARGET="$("$HDC" list targets | head -n 1 | tr -d '\r')"
fi

if [ -z "$TARGET" ] || [ "$TARGET" = "[Empty]" ]; then
    echo "[!] No HarmonyOS device connected via HDC."
    exit 1
fi

echo "============================================================"
echo "  HMArkPriv Shell Server Installer"
echo "  Target Device : $TARGET"
echo "  HDC Binary    : $HDC"
echo "============================================================"

REMOTE_TMP="/data/local/tmp/hmpriv"
REMOTE_BUS="/storage/media/100/local/files/Docs/Download/HMArkPriv"
STAGE_DIR="$(mktemp -d)"
trap 'rm -rf "$STAGE_DIR"' EXIT

# Prepare pre-allocated shared files locally
printf "" > "$STAGE_DIR/cmd.req"
printf "ID:init RC:0 TIME:0\nHMArkPriv Shell Server Ready\n" > "$STAGE_DIR/cmd.res"
printf '{"framework":"HMArkPriv","status":"ready"}\n' > "$STAGE_DIR/status.json"

echo "[1/4] Preparing remote directories..."
"$HDC" -t "$TARGET" shell "mkdir -p $REMOTE_TMP $REMOTE_TMP/core $REMOTE_TMP/client $REMOTE_TMP/console"

echo "[2/4] Pre-allocating Shared Bus in $REMOTE_BUS ..."
mkdir -p "$STAGE_DIR/HMArkPriv"
"$HDC" -t "$TARGET" file send "$STAGE_DIR/HMArkPriv" "/storage/media/100/local/files/Docs/Download/" >/dev/null 2>&1 || true

for f in cmd.req cmd.res status.json; do
    "$HDC" -t "$TARGET" file send "$STAGE_DIR/$f" "$REMOTE_BUS/$f" >/dev/null
done

# Send CLI and Web Shell Console to Download/HMArkPriv for direct access
"$HDC" -t "$TARGET" file send "$SCRIPT_DIR/client/hmpriv_cli.sh" "$REMOTE_BUS/hmpriv_cli.sh" >/dev/null
"$HDC" -t "$TARGET" file send "$SCRIPT_DIR/console/HMArkPriv_Console.html" "$REMOTE_BUS/HMArkPriv_Console.html" >/dev/null

echo "[3/4] Deploying HMArkPriv Shell Server & CLI to $REMOTE_TMP ..."
"$HDC" -t "$TARGET" file send "$SCRIPT_DIR/core/daemon.sh" "$REMOTE_TMP/core/daemon.sh" >/dev/null
"$HDC" -t "$TARGET" file send "$SCRIPT_DIR/client/hmpriv_cli.sh" "$REMOTE_TMP/client/hmpriv_cli.sh" >/dev/null

echo "[4/4] Starting HMArkPriv Shell Server (UID 2000 shell)..."
"$HDC" -t "$TARGET" shell "sh -c 'nohup sh $REMOTE_TMP/core/daemon.sh >/dev/null 2>&1 & sleep 1'"

echo ""
echo "✅ HMArkPriv Shell Server started! Verifying live execution..."
"$HDC" -t "$TARGET" shell "sh $REMOTE_TMP/client/hmpriv_cli.sh id"
echo ""
echo "============================================================"
echo "  HMArkPriv Deployment Complete!"
echo "  - File Manager Bus : 内部存储/Download/HMArkPriv/"
echo "  - Web Console      : 内部存储/Download/HMArkPriv/HMArkPriv_Console.html"
echo "  - Android Bus      : /sdcard/MyHarmonyOSDevice/Download/HMArkPriv/"
echo "============================================================"
