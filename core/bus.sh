#!/bin/sh
# ==============================================================================
# HMArkPriv IPC Bus Engine (core/bus.sh)
# ------------------------------------------------------------------------------
# Manages cross-sandbox communication between HarmonyOS 7.0 Host and
# Zhuoyitong (卓易通) / EasyAbroad (出境易) Android containers via hmdfs.
# ==============================================================================

BUS_DIR="/storage/media/100/local/files/Docs/Download/HMArkPriv"
REQ_FILE="${BUS_DIR}/cmd.req"
RES_FILE="${BUS_DIR}/cmd.res"
CFG_FILE="${BUS_DIR}/config.conf"
STATUS_FILE="${BUS_DIR}/status.json"
MAIN_LOG="${BUS_DIR}/hmpriv.log"

bus_init() {
    mkdir -p "${BUS_DIR}" 2>/dev/null
}

bus_log() {
    TS=$(date '+%Y-%m-%d %H:%M:%S')
    LINE="[${TS}] $1"
    [ -w "${MAIN_LOG}" ] && echo "${LINE}" >> "${MAIN_LOG}"
}

bus_read_req() {
    [ ! -r "${REQ_FILE}" ] && return 1
    FIRST=$(head -n 1 "${REQ_FILE}" 2>/dev/null | sed 's/\r//g')
    [ -z "${FIRST}" ] && return 1
    [ "${FIRST}" = "init" ] && return 1

    case "${FIRST}" in
        *"|"*)
            BUS_REQ_ID="${FIRST%%\|*}"
            BUS_REQ_CMD="${FIRST#*\|}"
            ;;
        *)
            BUS_REQ_ID="${FIRST}"
            BUS_REQ_CMD=$(tail -n +2 "${REQ_FILE}" 2>/dev/null | sed 's/\r//g')
            ;;
    esac

    [ -z "${BUS_REQ_ID}" ] && return 1
    [ "${BUS_REQ_ID}" = "${BUS_LAST_REQ_ID}" ] && return 1
    [ -z "${BUS_REQ_CMD}" ] && return 1

    BUS_LAST_REQ_ID="${BUS_REQ_ID}"
    return 0
}

bus_write_res() {
    req_id="$1"
    code="$2"
    output="$3"
    if [ -w "${RES_FILE}" ]; then
        cat <<EOF > "${RES_FILE}"
ID:${req_id} RC:${code} TIME:$(date '+%Y-%m-%d_%H:%M:%S')
${output}
EOF
    fi
}

bus_update_status() {
    if [ -w "${STATUS_FILE}" ]; then
        UPTIME_SEC=$(cut -d' ' -f1 /proc/uptime 2>/dev/null)
        cat <<EOF > "${STATUS_FILE}"
{
  "framework": "HMArkPriv",
  "version": "1.0.0",
  "pid": $$,
  "uid": $(id -u),
  "user": "$(id -un)",
  "started_at": "${START_TIME}",
  "updated_at": "$(date '+%Y-%m-%d %H:%M:%S')",
  "system_uptime_sec": "${UPTIME_SEC}",
  "module_adskip": ${MODULE_ADSKIP:-1},
  "module_keepawake": ${MODULE_KEEPAWAKE:-1},
  "module_sms": ${MODULE_SMS:-1},
  "module_macro": ${MODULE_MACRO:-1},
  "adskip_count": ${ADSKIP_COUNT:-0},
  "rpc_count": ${RPC_COUNT:-0},
  "charging_state": "${CHARGE_STATE:-unknown}",
  "last_active_app": "${LAST_APP_PROC:-none}"
}
EOF
    fi
}
