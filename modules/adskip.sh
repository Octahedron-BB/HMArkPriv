#!/bin/sh
# ==============================================================================
# HMArkPriv Module: Native Splash Ad-Skip Engine (modules/adskip.sh)
# ------------------------------------------------------------------------------
# Autonomous splash ad skipping for HarmonyOS NEXT / 7.0 without accessibility service.
# Uses dual-trigger (AppSpawn + SceneBoard loseFocus) + uitest + uinput.
# ==============================================================================

ADSKIP_LOG="${BUS_DIR}/adskip.log"
ADSKIP_COUNT=0
LAST_APP_PROC=""
LAST_HILOG_SIG=""
SCAN_REMAINING=0

mod_adskip_init() {
    [ -w "${ADSKIP_LOG}" ] || printf "=== HMArkPriv AdSkip Log Initialized ===\n" > "${ADSKIP_LOG}" 2>/dev/null
}

mod_adskip_poll() {
    [ "${MODULE_ADSKIP}" != "1" ] && return 0

    # Trigger A: Check newly spawned user app process (UID 2002xxxx)
    CUR_APP_PROC=$(ps -Ao pid,uid,args 2>/dev/null | grep ' 2002' | tail -n 1 | sed 's/^ *//;s/\r//g')
    if [ -n "${CUR_APP_PROC}" ] && [ "${CUR_APP_PROC}" != "${LAST_APP_PROC}" ]; then
        if [ -n "${LAST_APP_PROC}" ]; then
            bus_log "[AdSkip] New app process: ${CUR_APP_PROC}"
            SCAN_REMAINING=4
        fi
        LAST_APP_PROC="${CUR_APP_PROC}"
        bus_update_status
    fi

    # Trigger B: Check SceneBoard desktop focus loss in hilog
    CUR_HILOG_SIG=$(hilog -x -T ICON,HOME 2>/dev/null | grep -E 'loseFocus|ExposureManager' | tail -n 1)
    if [ -n "${CUR_HILOG_SIG}" ] && [ "${CUR_HILOG_SIG}" != "${LAST_HILOG_SIG}" ]; then
        if [ -n "${LAST_HILOG_SIG}" ]; then
            bus_log "[AdSkip] Desktop focus lost, starting splash scan..."
            SCAN_REMAINING=4
        fi
        LAST_HILOG_SIG="${CUR_HILOG_SIG}"
    fi

    if [ "${SCAN_REMAINING}" -le 0 ]; then
        return 0
    fi

    SCAN_REMAINING=$((SCAN_REMAINING - 1))
    LAYOUT_FILE="/data/local/tmp/hmpriv/focus_layout.json"
    rm -f "${LAYOUT_FILE}" 2>/dev/null

    uitest dumpLayout -p "${LAYOUT_FILE}" >/dev/null 2>&1
    [ ! -f "${LAYOUT_FILE}" ] && return 0

    # Extract skip button node ("跳过", "跳过广告", "3s 跳过", etc.)
    MATCH_NODE=$(grep -o '"bounds":"\[[0-9]*,[0-9]*\]\[[0-9]*,[0-9]*\]"[^}]*"text":"[^"]*跳过[^"]*"' "${LAYOUT_FILE}" 2>/dev/null | head -n 1)

    if [ -n "${MATCH_NODE}" ]; then
        BTN_TEXT=$(echo "${MATCH_NODE}" | sed -n 's/.*"text":"\([^"]*\)".*/\1/p')
        TEXT_LEN=${#BTN_TEXT}

        if [ "${TEXT_LEN}" -le 18 ]; then
            BOUNDS=$(echo "${MATCH_NODE}" | sed -n 's/.*"bounds":"\([^"]*\)".*/\1/p')
            X1=$(echo "${BOUNDS}" | sed 's/\[\([0-9]*\),\([0-9]*\)\]\[\([0-9]*\),\([0-9]*\)\]/\1/')
            Y1=$(echo "${BOUNDS}" | sed 's/\[\([0-9]*\),\([0-9]*\)\]\[\([0-9]*\),\([0-9]*\)\]/\2/')
            X2=$(echo "${BOUNDS}" | sed 's/\[\([0-9]*\),\([0-9]*\)\]\[\([0-9]*\),\([0-9]*\)\]/\3/')
            Y2=$(echo "${BOUNDS}" | sed 's/\[\([0-9]*\),\([0-9]*\)\]\[\([0-9]*\),\([0-9]*\)\]/\4/')

            if [ -n "${X1}" ] && [ -n "${X2}" ] && [ "${X2}" -gt "${X1}" ]; then
                W=$((X2 - X1))
                H=$((Y2 - Y1))
                # Validate button size
                if [ "${W}" -ge 30 ] && [ "${W}" -le 480 ] && [ "${H}" -ge 20 ] && [ "${H}" -le 220 ]; then
                    CX=$(( (X1 + X2) / 2 ))
                    CY=$(( (Y1 + Y2) / 2 ))
                    uinput -T -c "${CX}" "${CY}" >/dev/null 2>&1
                    ADSKIP_COUNT=$((ADSKIP_COUNT + 1))
                    SCAN_REMAINING=0
                    TS=$(date '+%Y-%m-%d %H:%M:%S')
                    MSG="[${TS}] [AdSkipped #${ADSKIP_COUNT}] App='${LAST_APP_PROC}' Text='${BTN_TEXT}' Bounds=${BOUNDS} Tap=(${CX},${CY})"
                    echo "${MSG}" >> "${ADSKIP_LOG}"
                    bus_log "${MSG}"
                    bus_update_status
                fi
            fi
        fi
    fi
}
