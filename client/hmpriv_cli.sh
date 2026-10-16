#!/bin/sh
# ==============================================================================
# HMArkPriv Client CLI Helper (client/hmpriv_cli.sh)
# ------------------------------------------------------------------------------
# Auto-detects shared hmdfs IPC bus across HarmonyOS Host & Android containers.
# Can be called from MT Manager, MacroDroid (Shell Action), Termux, or HDC Shell.
# ==============================================================================

find_ipc_dir() {
    for candidate in \
        "/storage/media/100/local/files/Docs/Download/HMArkPriv" \
        "/storage/emulated/0/MyHarmonyOSDevice/Download/HMArkPriv" \
        "/sdcard/MyHarmonyOSDevice/Download/HMArkPriv" \
        "/storage/emulated/0/Download/HMArkPriv" \
        "/sdcard/Download/HMArkPriv"
    do
        if [ -f "${candidate}/status.json" ] || [ -f "${candidate}/cmd.req" ]; then
            echo "$candidate"
            return 0
        fi
    done
    return 1
}

IPC_DIR="$(find_ipc_dir)"
if [ -z "$IPC_DIR" ]; then
    echo "[!] Error: Cannot find HMArkPriv bus directory (Download/HMArkPriv)." >&2
    exit 1
fi

REQ_FILE="${IPC_DIR}/cmd.req"
RES_FILE="${IPC_DIR}/cmd.res"
STATUS_FILE="${IPC_DIR}/status.json"

usage() {
    cat <<EOF
HMArkPriv CLI - Privileged Relay Client for HarmonyOS 7.0

Usage: sh hmpriv_cli.sh <subcommand> [args...]

Subcommands:
  status               Show framework live status and active modules
  exec <command...>    Execute raw shell command on HarmonyOS Host (UID 2000)
  adskip <on|off>      Toggle native splash ad skipping module
  keepawake <on|off>   Toggle charging screen keep-awake module
  tap <x> <y>          Inject global touch tap on screen
  swipe <x1> <y1> <x2> <y2> [ms]
                       Inject global swipe gesture
  wakeup               Wake screen display
  suspend              Turn screen off
  topwin               Show current focused window and app
  sms                  View latest captured SMS events
  log [ad|sms|main]    View recent framework logs
EOF
}

send_rpc() {
    rpc_cmd="$1"
    req_id="req_$(date +%s)_$$"
    
    printf "%s|%s\n" "$req_id" "$rpc_cmd" > "$REQ_FILE" 2>/dev/null
    if [ $? -ne 0 ]; then
        echo "[!] Error: Failed to write to $REQ_FILE" >&2
        exit 1
    fi

    waited=0
    while [ "$waited" -lt 80 ]; do
        if [ -f "$RES_FILE" ]; then
            first_line="$(head -n 1 "$RES_FILE" 2>/dev/null)"
            case "$first_line" in
                "ID:${req_id} "*)
                    tail -n +2 "$RES_FILE"
                    rc="$(echo "$first_line" | sed -n 's/.*RC:\([0-9-]*\).*/\1/p')"
                    return "${rc:-0}"
                    ;;
            esac
        fi
        sleep 0.15 2>/dev/null || sleep 1
        waited=$((waited + 1))
    done

    echo "[!] Timeout waiting for HMArkPriv daemon response." >&2
    return 124
}

SUBCMD="$1"
shift 2>/dev/null || true

case "$SUBCMD" in
    status)
        echo "=== HMArkPriv Bus: ${IPC_DIR} ==="
        [ -f "$STATUS_FILE" ] && cat "$STATUS_FILE"
        echo "=== Live Host Ping ==="
        send_rpc "@PING"
        ;;
    exec)
        [ $# -eq 0 ] && { echo "Usage: sh hmpriv_cli.sh exec <command>"; exit 1; }
        send_rpc "$*"
        ;;
    adskip)
        case "$1" in
            on|1|true)  send_rpc "@ADSKIP_ON" ;;
            off|0|false) send_rpc "@ADSKIP_OFF" ;;
            *) echo "Usage: sh hmpriv_cli.sh adskip <on|off>"; exit 1 ;;
        esac
        ;;
    keepawake)
        case "$1" in
            on|1|true)  send_rpc "@KEEPAWAKE_ON" ;;
            off|0|false) send_rpc "@KEEPAWAKE_OFF" ;;
            *) echo "Usage: sh hmpriv_cli.sh keepawake <on|off>"; exit 1 ;;
        esac
        ;;
    tap)
        [ $# -lt 2 ] && { echo "Usage: sh hmpriv_cli.sh tap <x> <y>"; exit 1; }
        send_rpc "@TAP $1 $2"
        ;;
    swipe)
        [ $# -lt 4 ] && { echo "Usage: sh hmpriv_cli.sh swipe <x1> <y1> <x2> <y2> [ms]"; exit 1; }
        send_rpc "@SWIPE $1 $2 $3 $4 ${5:-300}"
        ;;
    wakeup)
        send_rpc "@WAKEUP"
        ;;
    suspend)
        send_rpc "@SUSPEND"
        ;;
    topwin)
        send_rpc "@TOPWIN"
        ;;
    sms)
        if [ -f "${IPC_DIR}/sms_latest.json" ]; then
            cat "${IPC_DIR}/sms_latest.json"
        else
            echo "(No incoming SMS events captured yet)"
        fi
        ;;
    log)
        case "$1" in
            ad*)   [ -f "${IPC_DIR}/adskip.log" ] && tail -n 25 "${IPC_DIR}/adskip.log" ;;
            sms*)  [ -f "${IPC_DIR}/sms.log" ] && tail -n 25 "${IPC_DIR}/sms.log" ;;
            *)     [ -f "${IPC_DIR}/hmpriv.log" ] && tail -n 25 "${IPC_DIR}/hmpriv.log" ;;
        esac
        ;;
    *)
        usage
        exit 1
        ;;
esac
