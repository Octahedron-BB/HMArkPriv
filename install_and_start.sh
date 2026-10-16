#!/bin/bash
# ==============================================================================
# HMArkPriv One-Click Installer & Daemon Starter for HarmonyOS 7.0 (Next)
# ------------------------------------------------------------------------------
# Deploys HMArkPriv modular framework to device without signature or HAP.
# Pre-allocates shared hmdfs bus files in Download/HMArkPriv via hdcd (u:r:hdcd:s0).
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
echo "  HMArkPriv Framework Installer & Starter"
echo "  Target Device : $TARGET"
echo "  HDC Binary    : $HDC"
echo "============================================================"

REMOTE_TMP="/data/local/tmp/hmpriv"
REMOTE_BUS="/storage/media/100/local/files/Docs/Download/HMArkPriv"
STAGE_DIR="$(mktemp -d)"
trap 'rm -rf "$STAGE_DIR"' EXIT

# Prepare pre-allocated shared files locally
printf "" > "$STAGE_DIR/cmd.req"
printf "ID:init RC:0 TIME:0\nHMArkPriv Framework Ready\n" > "$STAGE_DIR/cmd.res"
cat << 'EOF' > "$STAGE_DIR/config.conf"
# HMArkPriv Runtime Configuration
MODULE_ADSKIP=1
MODULE_KEEPAWAKE=1
MODULE_SMS=1
MODULE_MACRO=1
SMS_WEBHOOK_URL=
EOF
printf '{"framework":"HMArkPriv","status":"starting"}\n' > "$STAGE_DIR/status.json"
printf "=== HMArkPriv Framework Log Initialized ===\n" > "$STAGE_DIR/hmpriv.log"
printf "=== HMArkPriv AdSkip Log Initialized ===\n" > "$STAGE_DIR/adskip.log"
printf "=== HMArkPriv KeepAwake Log Initialized ===\n" > "$STAGE_DIR/keepawake.log"
printf "=== HMArkPriv KeepAlive Log Initialized ===\n" > "$STAGE_DIR/keepalive.log"
cat << 'EOF' > "$STAGE_DIR/keepalive_apps.txt"
com.droi.tong
org.kde.kdeconnect_tp
cn.ppps.forwarder
com.arlosoft.macrodroid
EOF
printf "=== HMArkPriv SMS Log Initialized ===\n" > "$STAGE_DIR/sms.log"
printf '{"status":"idle","last_event":null}\n' > "$STAGE_DIR/sms_latest.json"

echo "[1/4] Preparing remote directories..."
"$HDC" -t "$TARGET" shell "mkdir -p $REMOTE_TMP $REMOTE_TMP/core $REMOTE_TMP/modules $REMOTE_TMP/client $REMOTE_TMP/console"

echo "[2/4] Pre-allocating Cross-Sandbox Shared Bus in $REMOTE_BUS ..."
# Create bus directory via directory push
mkdir -p "$STAGE_DIR/HMArkPriv"
"$HDC" -t "$TARGET" file send "$STAGE_DIR/HMArkPriv" "/storage/media/100/local/files/Docs/Download/" >/dev/null 2>&1 || true

for f in cmd.req cmd.res config.conf status.json hmpriv.log adskip.log keepawake.log keepalive.log keepalive_apps.txt sms.log sms_latest.json; do
    "$HDC" -t "$TARGET" file send "$STAGE_DIR/$f" "$REMOTE_BUS/$f" >/dev/null
done

# Send CLI and HTML Console to Download/HMArkPriv for direct access
"$HDC" -t "$TARGET" file send "$SCRIPT_DIR/client/hmpriv_cli.sh" "$REMOTE_BUS/hmpriv_cli.sh" >/dev/null
"$HDC" -t "$TARGET" file send "$SCRIPT_DIR/console/HMArkPriv_Console.html" "$REMOTE_BUS/HMArkPriv_Console.html" >/dev/null

echo "[3/4] Deploying HMArkPriv Microkernel & Modules to $REMOTE_TMP ..."
"$HDC" -t "$TARGET" file send "$SCRIPT_DIR/core/bus.sh" "$REMOTE_TMP/core/bus.sh" >/dev/null
"$HDC" -t "$TARGET" file send "$SCRIPT_DIR/core/daemon.sh" "$REMOTE_TMP/core/daemon.sh" >/dev/null
"$HDC" -t "$TARGET" file send "$SCRIPT_DIR/modules/adskip.sh" "$REMOTE_TMP/modules/adskip.sh" >/dev/null
"$HDC" -t "$TARGET" file send "$SCRIPT_DIR/modules/keep_awake.sh" "$REMOTE_TMP/modules/keep_awake.sh" >/dev/null
"$HDC" -t "$TARGET" file send "$SCRIPT_DIR/modules/keep_alive.sh" "$REMOTE_TMP/modules/keep_alive.sh" >/dev/null
"$HDC" -t "$TARGET" file send "$SCRIPT_DIR/modules/sms_forwarder.sh" "$REMOTE_TMP/modules/sms_forwarder.sh" >/dev/null
"$HDC" -t "$TARGET" file send "$SCRIPT_DIR/modules/macro_kde_bridge.sh" "$REMOTE_TMP/modules/macro_kde_bridge.sh" >/dev/null
"$HDC" -t "$TARGET" file send "$SCRIPT_DIR/client/hmpriv_cli.sh" "$REMOTE_TMP/client/hmpriv_cli.sh" >/dev/null

echo "[4/4] Starting HMArkPriv Framework Daemon (UID 2000 shell)..."
"$HDC" -t "$TARGET" shell "sh -c 'nohup sh $REMOTE_TMP/core/daemon.sh >/dev/null 2>&1 & sleep 1'"

echo ""
echo "✅ HMArkPriv Daemon started! Verifying live status..."
"$HDC" -t "$TARGET" shell "sh $REMOTE_TMP/client/hmpriv_cli.sh status"
echo ""
echo "============================================================"
echo "  HMArkPriv Deployment Complete!"
echo "  - File Manager Bus : 内部存储/Download/HMArkPriv/"
echo "  - Web Console      : 内部存储/Download/HMArkPriv/HMArkPriv_Console.html"
echo "  - Android Bus      : /sdcard/MyHarmonyOSDevice/Download/HMArkPriv/"
echo "============================================================"
