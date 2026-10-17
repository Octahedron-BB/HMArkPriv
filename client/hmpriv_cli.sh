#!/bin/sh
# ==============================================================================
# HMArkPriv Shell Client (client/hmpriv_cli.sh)
# ------------------------------------------------------------------------------
# Executes commands on HarmonyOS Host (UID 2000 shell) via shared IPC bus.
# Works from MT Manager, MacroDroid, Termux, or HDC.
# ==============================================================================

find_ipc_dir() {
    for candidate in \
        "/storage/media/100/local/files/Docs/Download/HMArkPriv" \
        "/storage/emulated/0/MyHarmonyOSDevice/Download/HMArkPriv" \
        "/sdcard/MyHarmonyOSDevice/Download/HMArkPriv" \
        "/storage/emulated/0/Download/HMArkPriv" \
        "/sdcard/Download/HMArkPriv"
    do
        if [ -f "${candidate}/cmd.req" ] || [ -f "${candidate}/cmd.res" ]; then
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

send_cmd() {
    cmd_str="$1"
    req_id="req_$(date +%s)_$$"
    
    printf "%s|%s\n" "$req_id" "$cmd_str" > "$REQ_FILE" 2>/dev/null
    if [ $? -ne 0 ]; then
        echo "[!] Error: Failed to write to $REQ_FILE" >&2
        exit 1
    fi

    waited=0
    while [ "$waited" -lt 60 ]; do
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
        sleep 0.1 2>/dev/null || sleep 1
        waited=$((waited + 1))
    done

    echo "[!] Timeout waiting for HMArkPriv Shell Server response." >&2
    return 124
}

if [ $# -eq 0 ]; then
    cat <<EOF
HMArkPriv Shell Client (UID 2000)

Usage:
  sh hmpriv_cli.sh <command...>
  sh hmpriv_cli.sh exec <command...>

Examples:
  sh hmpriv_cli.sh id
  sh hmpriv_cli.sh power-shell wakeup
  sh hmpriv_cli.sh uinput -T -c 500 500
  sh hmpriv_cli.sh bm dump -a
  sh hmpriv_cli.sh aa dump -l
EOF
    exit 0
fi

if [ "$1" = "exec" ]; then
    shift
fi

send_cmd "$*"
