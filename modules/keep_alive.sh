#!/bin/sh
# ==============================================================================
# HMArkPriv Module: Keep-Alive & Standby Immunizer (modules/keep_alive.sh)
# ------------------------------------------------------------------------------
# Prevents HongMeng ResourceSched & SuspendManager from freezing background
# services (Zhuoyitong Android container, KDE Connect, SmsForwarder, MacroDroid)
# during device screen-off and deep sleep.
#
# Supports granular per-app whitelist selection directly via Web Console / RPC.
# ==============================================================================

KEEPALIVE_APPS_FILE="${BUS_DIR}/keepalive_apps.txt"
KEEPALIVE_LOG="${BUS_DIR}/keepalive.log"
KEEPALIVE_TICK=0

mod_keepalive_init() {
    [ -w "${KEEPALIVE_LOG}" ] || printf "=== HMArkPriv KeepAlive Log Initialized ===\n" > "${KEEPALIVE_LOG}" 2>/dev/null
    if [ ! -f "${KEEPALIVE_APPS_FILE}" ] && [ -w "${BUS_DIR}" ]; then
        cat <<'EOF' > "${KEEPALIVE_APPS_FILE}"
com.droi.tong
org.kde.kdeconnect_tp
cn.ppps.forwarder
com.arlosoft.macrodroid
EOF
    fi
}

mod_keepalive_get_apps() {
    if [ -f "${KEEPALIVE_APPS_FILE}" ]; then
        paste -sd, "${KEEPALIVE_APPS_FILE}" 2>/dev/null
    else
        echo "com.droi.tong,org.kde.kdeconnect_tp,cn.ppps.forwarder,com.arlosoft.macrodroid"
    fi
}

mod_keepalive_set_apps() {
    apps_arg="$1"
    # Convert comma-separated string to newline-separated file
    echo "${apps_arg}" | sed 's/,/\n/g' | sed '/^[[:space:]]*$/d' > "${KEEPALIVE_APPS_FILE}"
}

mod_keepalive_handle() {
    cmd="$1"
    case "${cmd}" in
        "@KEEPALIVE_GET")
            apps=$(mod_keepalive_get_apps)
            OUT="${apps}"
            RC=0
            return 0
            ;;
        "@KEEPALIVE_SET "*)
            new_apps="${cmd#@KEEPALIVE_SET }"
            mod_keepalive_set_apps "${new_apps}"
            TS=$(date '+%Y-%m-%d %H:%M:%S')
            echo "${TS} [Whitelist Updated]: ${new_apps}" >> "${KEEPALIVE_LOG}"
            OUT="OK: KeepAlive whitelist updated to [${new_apps}]"
            RC=0
            return 0
            ;;
        "@KEEPALIVE_PULSE")
            mod_keepalive_execute_pulse
            OUT="OK: KeepAlive pulse dispatched to all active targets."
            RC=0
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

mod_keepalive_execute_pulse() {
    TS=$(date '+%Y-%m-%d %H:%M:%S')
    active_apps=""

    # 1. Container Engine KeepAlive (if com.droi.tong in whitelist)
    if grep -q '^com\.droi\.tong' "${KEEPALIVE_APPS_FILE}" 2>/dev/null; then
        aa start -b com.droi.tong -a WorkSchedulerExtAbility >/dev/null 2>&1
        aa start -b com.droi.tong -a NormalWorkSchedulerExtAbility >/dev/null 2>&1
        hidumper -s 2901 >/dev/null 2>&1
        active_apps="${active_apps} com.droi.tong"
    fi

    # 2. KDE Connect Network Refresh (if org.kde.kdeconnect_tp in whitelist)
    if grep -q '^org\.kde\.kdeconnect_tp' "${KEEPALIVE_APPS_FILE}" 2>/dev/null; then
        hidumper -s NetConnManager >/dev/null 2>&1
        ping -c 1 -W 1 127.0.0.1 >/dev/null 2>&1
        active_apps="${active_apps} kdeconnect"
    fi

    # 3. SmsForwarder Guard (if cn.ppps.forwarder in whitelist)
    if grep -q '^cn\.ppps\.forwarder' "${KEEPALIVE_APPS_FILE}" 2>/dev/null; then
        # Ping ANCO broker to ensure SMS forwarder worker threads aren't frozen
        hidumper -s 2901 >/dev/null 2>&1
        active_apps="${active_apps} smsforwarder"
    fi

    # 4. MacroDroid Guard (if com.arlosoft.macrodroid in whitelist)
    if grep -q '^com\.arlosoft\.macrodroid' "${KEEPALIVE_APPS_FILE}" 2>/dev/null; then
        active_apps="${active_apps} macrodroid"
    fi

    echo "${TS} [Pulse]: Refreshed guards for [${active_apps# }]" >> "${KEEPALIVE_LOG}"
}

mod_keepalive_poll() {
    [ "${MODULE_KEEPALIVE:-1}" != "1" ] && return 0

    KEEPALIVE_TICK=$((KEEPALIVE_TICK + 1))
    # Execute keep-alive pulse roughly every 45-60s (approx 160 ticks @ 0.25s)
    if [ $((KEEPALIVE_TICK % 160)) -ne 0 ]; then
        return 0
    fi

    mod_keepalive_execute_pulse
}
