#!/bin/sh
# ==============================================================================
# HMArkPriv Microkernel Daemon & Module Loader (core/daemon.sh)
# ------------------------------------------------------------------------------
# Target OS: HarmonyOS 7.0 (HongMeng Kernel 1.13.0, UID 2000 / shell)
# Framework Architecture:
#   - Core: Cross-Sandbox Bus IPC & Event Dispatcher
#   - Dynamic Modules: AdSkip, KeepAwake, SmsBridge, MacroKdeBridge
# ==============================================================================

WORK_DIR="/data/local/tmp/hmpriv"
PID_FILE="${WORK_DIR}/daemon.pid"
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
PROJECT_DIR=$(cd "${SCRIPT_DIR}/.." && pwd)

mkdir -p "${WORK_DIR}" 2>/dev/null

# Single instance enforcement
if [ -f "${PID_FILE}" ]; then
    OLD_PID=$(cat "${PID_FILE}" 2>/dev/null)
    if [ -n "${OLD_PID}" ] && [ "${OLD_PID}" != "$$" ] && kill -0 "${OLD_PID}" 2>/dev/null; then
        kill -9 "${OLD_PID}" 2>/dev/null
        sleep 0.2
    fi
fi
echo $$ > "${PID_FILE}"

# Load Core Bus Engine
. "${PROJECT_DIR}/core/bus.sh"

# Load Extensible Modules
. "${PROJECT_DIR}/modules/adskip.sh"
. "${PROJECT_DIR}/modules/keep_awake.sh"
. "${PROJECT_DIR}/modules/sms_forwarder.sh"
. "${PROJECT_DIR}/modules/macro_kde_bridge.sh"

# State & Config Defaults
MODULE_ADSKIP=1
MODULE_KEEPAWAKE=1
MODULE_SMS=1
MODULE_MACRO=1
RPC_COUNT=0
BUS_LAST_REQ_ID=""
START_TIME=$(date '+%Y-%m-%d %H:%M:%S')

load_config() {
    if [ -r "${CFG_FILE}" ]; then
        V_AD=$(grep -E '^MODULE_ADSKIP=' "${CFG_FILE}" 2>/dev/null | tail -n 1 | cut -d'=' -f2 | sed 's/[^0-9]//g')
        [ -n "${V_AD}" ] && MODULE_ADSKIP="${V_AD}"
        
        V_KA=$(grep -E '^MODULE_KEEPAWAKE=' "${CFG_FILE}" 2>/dev/null | tail -n 1 | cut -d'=' -f2 | sed 's/[^0-9]//g')
        [ -n "${V_KA}" ] && MODULE_KEEPAWAKE="${V_KA}"

        V_SMS=$(grep -E '^MODULE_SMS=' "${CFG_FILE}" 2>/dev/null | tail -n 1 | cut -d'=' -f2 | sed 's/[^0-9]//g')
        [ -n "${V_SMS}" ] && MODULE_SMS="${V_SMS}"

        V_MAC=$(grep -E '^MODULE_MACRO=' "${CFG_FILE}" 2>/dev/null | tail -n 1 | cut -d'=' -f2 | sed 's/[^0-9]//g')
        [ -n "${V_MAC}" ] && MODULE_MACRO="${V_MAC}"

        V_URL=$(grep -E '^SMS_WEBHOOK_URL=' "${CFG_FILE}" 2>/dev/null | tail -n 1 | cut -d'=' -f2- | sed 's/\r//g')
        [ -n "${V_URL}" ] && SMS_WEBHOOK_URL="${V_URL}"
    fi
}

save_config() {
    if [ -w "${CFG_FILE}" ]; then
        cat <<EOF > "${CFG_FILE}"
# HMArkPriv Runtime Configuration
MODULE_ADSKIP=${MODULE_ADSKIP:-1}
MODULE_KEEPAWAKE=${MODULE_KEEPAWAKE:-1}
MODULE_SMS=${MODULE_SMS:-1}
MODULE_MACRO=${MODULE_MACRO:-1}
SMS_WEBHOOK_URL=${SMS_WEBHOOK_URL:-}
EOF
    fi
}

# Initialize Bus and Modules
bus_init
load_config
mod_adskip_init
mod_keepawake_init
mod_sms_init

bus_log "=========================================================="
bus_log "HMArkPriv Framework Daemon started (PID=$$, UID=$(id -u))"
bus_log "Active Modules: AdSkip=${MODULE_ADSKIP} KeepAwake=${MODULE_KEEPAWAKE} SMS=${MODULE_SMS} Macro=${MODULE_MACRO}"
bus_log "=========================================================="
bus_update_status

LOOP_TICK=0
while true; do
    # 1. Dispatch RPC requests from Shared Bus
    if bus_read_req; then
        RPC_COUNT=$((RPC_COUNT + 1))
        bus_log "[RPC #${RPC_COUNT}] ID=${BUS_REQ_ID} CMD=${BUS_REQ_CMD}"

        case "${BUS_REQ_CMD}" in
            "@PING")
                OUT="PONG from HMArkPriv Host Framework (PID=$$, Kernel=$(uname -r))"
                RC=0
                ;;
            "@ADSKIP_ON")
                MODULE_ADSKIP=1
                save_config
                OUT="OK: Module [AdSkip] ENABLED."
                RC=0
                ;;
            "@ADSKIP_OFF")
                MODULE_ADSKIP=0
                save_config
                OUT="OK: Module [AdSkip] DISABLED."
                RC=0
                ;;
            "@KEEPAWAKE_ON")
                mod_keepawake_set on
                save_config
                OUT="OK: Module [KeepAwake] ENABLED."
                RC=0
                ;;
            "@KEEPAWAKE_OFF")
                mod_keepawake_set off
                save_config
                OUT="OK: Module [KeepAwake] DISABLED."
                RC=0
                ;;
            "@STATUS")
                bus_update_status
                OUT=$(cat "${STATUS_FILE}" 2>/dev/null)
                RC=0
                ;;
            *)
                # Try Macro/KDE module handler first
                if mod_macro_handle "${BUS_REQ_CMD}"; then
                    :
                else
                    # Fallback to direct shell execution
                    OUT=$(sh -c "${BUS_REQ_CMD}" 2>&1)
                    RC=$?
                fi
                ;;
        esac

        bus_write_res "${BUS_REQ_ID}" "${RC}" "${OUT}"
        bus_update_status
    fi

    # 2. Run module pollers
    if [ $((LOOP_TICK % 2)) -eq 0 ]; then
        mod_adskip_poll
    fi

    if [ $((LOOP_TICK % 4)) -eq 0 ]; then
        mod_keepawake_poll
    fi

    if [ $((LOOP_TICK % 8)) -eq 0 ]; then
        mod_sms_poll
    fi

    LOOP_TICK=$((LOOP_TICK + 1))
    if [ $((LOOP_TICK % 25)) -eq 0 ]; then
        load_config
        bus_update_status
    fi

    sleep 0.25
done
