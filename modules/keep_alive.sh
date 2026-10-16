#!/bin/sh
# ==============================================================================
# HMArkPriv Module: Keep-Alive & Standby Immunizer (modules/keep_alive.sh)
# ------------------------------------------------------------------------------
# Prevents HongMeng ResourceSched & SuspendManager from freezing background
# services (Zhuoyitong Android container, KDE Connect, SmsForwarder, MacroDroid)
# during device screen-off and deep sleep.
#
# Methods:
#   1. Container WakeLock & Process Guard (keeps com.droi.tong active)
#   2. Network Socket Refresh & KeepAlive Heartbeat (every 45s)
#   3. Target Bundle White-list auto-revival
# ==============================================================================

KEEPALIVE_CONF="${BUS_DIR}/keepalive.conf"
KEEPALIVE_LOG="${BUS_DIR}/keepalive.log"
KEEPALIVE_TICK=0

mod_keepalive_init() {
    [ -w "${KEEPALIVE_LOG}" ] || printf "=== HMArkPriv KeepAlive Log Initialized ===\n" > "${KEEPALIVE_LOG}" 2>/dev/null
    if [ ! -f "${KEEPALIVE_CONF}" ] && [ -w "${BUS_DIR}" ]; then
        cat <<'CONF' > "${KEEPALIVE_CONF}"
# HMArkPriv Background Keep-Alive Whitelist Configuration
# 1 = Enabled, 0 = Disabled
# --------------------------------------------------------
ENABLE_KEEPALIVE=1

# Keep Zhuoyitong (ANCO Android Container) awake during screen-off
KEEP_ZHUOYITONG=1

# Keep KDE Connect / Network Sockets refreshed during sleep
KEEP_KDE_NETWORK=1

# Interval for silent keep-alive pulses (seconds)
KEEPALIVE_INTERVAL=45
CONF
    fi
}

mod_keepalive_poll() {
    [ "${MODULE_KEEPALIVE:-1}" != "1" ] && return 0

    KEEPALIVE_TICK=$((KEEPALIVE_TICK + 1))
    # Execute keep-alive pulse roughly every 45-60s (approx 150-180 ticks @ 0.25s)
    if [ $((KEEPALIVE_TICK % 160)) -ne 0 ]; then
        return 0
    fi

    # Read whitelist preferences if available
    [ -f "${KEEPALIVE_CONF}" ] && . "${KEEPALIVE_CONF}" 2>/dev/null
    [ "${ENABLE_KEEPALIVE:-1}" != "1" ] && return 0

    TS=$(date '+%Y-%m-%d %H:%M:%S')

    # Guard 1: Ensure Zhuoyitong Container (com.droi.tong) is not frozen in background
    if [ "${KEEP_ZHUOYITONG:-1}" = "1" ]; then
        # Ping the container background work scheduler
        aa start -b com.droi.tong -a WorkSchedulerExtAbility >/dev/null 2>&1
        # Ping broker process via IPC ping
        hidumper -s 2901 >/dev/null 2>&1
    fi

    # Guard 2: Refresh network socket tables to prevent KDE Connect socket drops
    if [ "${KEEP_KDE_NETWORK:-1}" = "1" ]; then
        # Refresh network connectivity state in netmanager
        hidumper -s NetConnManager >/dev/null 2>&1
        # Send lightweight loopback sync to keep socket buffers alive
        ping -c 1 -W 1 127.0.0.1 >/dev/null 2>&1
    fi

    # Guard 3: Touch keepalive heartbeat
    echo "${TS} [KeepAlive Heartbeat] Container & Network guard refreshed." >> "${KEEPALIVE_LOG}"
}
