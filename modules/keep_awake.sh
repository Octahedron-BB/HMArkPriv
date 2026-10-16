#!/bin/sh
# ==============================================================================
# HMArkPriv Module: Keep Screen On While Charging (modules/keep_awake.sh)
# ------------------------------------------------------------------------------
# Automatically overrides screen off timeout to 24h when device is plugged in,
# and restores default screen timeout when unplugged.
# Uses native /system/bin/power-shell timeout -o / -r
# ==============================================================================

KEEPAWAKE_LOG="${BUS_DIR}/keepawake.log"
PREV_CHARGE_STATE=""
CHARGE_STATE="discharging"

mod_keepawake_init() {
    [ -w "${KEEPAWAKE_LOG}" ] || printf "=== HMArkPriv KeepAwake Log ===\n" > "${KEEPAWAKE_LOG}" 2>/dev/null
}

mod_keepawake_poll() {
    [ "${MODULE_KEEPAWAKE}" != "1" ] && return 0

    CUR_STATE=""
    # Method 1: Check hardware kernel log (bq2560x_charger / direct_charge)
    KMSG_LINE=$(hilog -x -t kmsg 2>/dev/null | grep 'check_charger_plugged' | tail -n 1)
    if [ -n "${KMSG_LINE}" ]; then
        case "${KMSG_LINE}" in
            *"=0x1"*)
                CUR_STATE="charging"
                ;;
            *"=0x0"*)
                CUR_STATE="discharging"
                ;;
        esac
    fi

    # Method 2: Fallback to FusionSearchCore / SysUI charge notifications
    if [ -z "${CUR_STATE}" ]; then
        CHG_LINE=$(hilog -x -T FusionSearchCore 2>/dev/null | grep -E 'NotifyChargeState: [0-9]' | tail -n 1)
        if [ -n "${CHG_LINE}" ]; then
            STATE_VAL=$(echo "${CHG_LINE}" | sed -n 's/.*NotifyChargeState: *\([0-9]\).*/\1/p')
            case "${STATE_VAL}" in
                "1"|"2"|"3")
                    CUR_STATE="charging"
                    ;;
                "0")
                    CUR_STATE="discharging"
                    ;;
            esac
        fi
    fi

    # Default to previous state if nothing parsed
    [ -z "${CUR_STATE}" ] && CUR_STATE="${CHARGE_STATE}"

    if [ "${CUR_STATE}" != "${PREV_CHARGE_STATE}" ] && [ -n "${CUR_STATE}" ]; then
        PREV_CHARGE_STATE="${CUR_STATE}"
        CHARGE_STATE="${CUR_STATE}"
        TS=$(date '+%Y-%m-%d %H:%M:%S')

        if [ "${CUR_STATE}" = "charging" ]; then
            # Override timeout to 24 hours (86,400,000 ms)
            power-shell timeout -o 86400000 >/dev/null 2>&1
            MSG="[${TS}] [KeepAwake] Charging detected: Screen timeout overridden to 24h (Always On)."
            echo "${MSG}" >> "${KEEPAWAKE_LOG}"
            bus_log "${MSG}"
        else
            # Restore system default screen timeout
            power-shell timeout -r >/dev/null 2>&1
            MSG="[${TS}] [KeepAwake] Unplugged: Screen timeout restored to system default."
            echo "${MSG}" >> "${KEEPAWAKE_LOG}"
            bus_log "${MSG}"
        fi
        bus_update_status
    fi
}

mod_keepawake_set() {
    mode="$1"
    if [ "${mode}" = "on" ] || [ "${mode}" = "1" ]; then
        MODULE_KEEPAWAKE=1
        power-shell timeout -o 86400000 >/dev/null 2>&1
        CHARGE_STATE="manual_on"
        bus_log "[KeepAwake] Manually forced screen always-on (24h timeout)"
        return 0
    else
        MODULE_KEEPAWAKE=0
        power-shell timeout -r >/dev/null 2>&1
        CHARGE_STATE="disabled"
        bus_log "[KeepAwake] Module disabled: Screen timeout restored to default"
        return 0
    fi
}
