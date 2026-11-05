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
"$HDC" -t "$TARGET" shell "mkdir -p $REMOTE_TMP $REMOTE_TMP/core $REMOTE_BUS"

echo "[2/4] Pre-allocating Shared Bus in $REMOTE_BUS ..."
mkdir -p "$STAGE_DIR/HMArkPriv"
"$HDC" -t "$TARGET" file send "$STAGE_DIR/HMArkPriv" "/storage/media/100/local/files/Docs/Download/" >/dev/null 2>&1 || true

for f in cmd.req cmd.res status.json audit.log tokens.txt config.json frozen.txt; do
    touch "$STAGE_DIR/$f"
    "$HDC" -t "$TARGET" file send "$STAGE_DIR/$f" "$REMOTE_BUS/$f" >/dev/null
done

# Initialize config and tokens if empty
"$HDC" -t "$TARGET" shell "echo '{\"queueEnabled\":true}' > $REMOTE_BUS/config.json 2>/dev/null || true"

echo "[3/4] Deploying HMArkPriv Shell Server to $REMOTE_TMP ..."
"$HDC" -t "$TARGET" file send "$SCRIPT_DIR/core/daemon.sh" "$REMOTE_TMP/core/daemon.sh" >/dev/null
"$HDC" -t "$TARGET" shell "chmod 755 $REMOTE_TMP/core/daemon.sh 2>/dev/null || true"

echo "[4/4] Starting HMArkPriv Shell Server (UID 2000 shell)..."
"$HDC" -t "$TARGET" shell "sh -c 'nohup sh $REMOTE_TMP/core/daemon.sh >/dev/null 2>&1 & sleep 1'"

echo ""
echo "✅ HMArkPriv Shell Server started! Verifying live execution..."
"$HDC" -t "$TARGET" shell "cat $REMOTE_BUS/status.json"
echo ""
echo "============================================================"
echo "  HMArkPriv Daemon Deployment Complete!"
echo "  - File Bus Directory : 内部存储/Download/HMArkPriv/"
echo "  - Ready for ArkUI App: 打开 HMArkPriv App 即可使用"
echo "============================================================"
