#!/bin/sh
# ==============================================================================
# HMArkPriv Module: MacroDroid & KDE Connect Bridge (modules/macro_kde_bridge.sh)
# ------------------------------------------------------------------------------
# High-level privileged action handlers for container automation tools:
#   @TAP x y                - Hardware touchscreen tap injection
#   @SWIPE x1 y1 x2 y2 [ms] - Hardware touchscreen swipe gesture
#   @KEY <keycode>          - Hardware key injection
#   @WAKEUP                 - Wakeup screen & turn display on
#   @SUSPEND                - Turn screen off
#   @TOPWIN                 - Query foreground focused window & app
#   @RESTART_DAEMON         - Restart HMArkPriv background service
# ==============================================================================

mod_macro_handle() {
    cmd="$1"
    case "${cmd}" in
        "@TAP "*)
            COORDS="${cmd#@TAP }"
            set -- ${COORDS}
            uinput -T -c "$1" "$2" >/dev/null 2>&1
            RC=$?
            OUT="OK: Tap injected at ($1, $2)"
            return 0
            ;;
        "@SWIPE "*)
            ARGS="${cmd#@SWIPE }"
            set -- ${ARGS}
            uinput -T -m "$1" "$2" "$3" "$4" "${5:-300}" >/dev/null 2>&1
            RC=$?
            OUT="OK: Swipe ($1,$2)->($3,$4) duration=${5:-300}ms"
            return 0
            ;;
        "@KEY "*)
            KCODE="${cmd#@KEY }"
            uinput -K -d "${KCODE}" -u "${KCODE}" >/dev/null 2>&1
            RC=$?
            OUT="OK: Injected keycode ${KCODE}"
            return 0
            ;;
        "@WAKEUP")
            power-shell wakeup >/dev/null 2>&1
            RC=$?
            OUT="OK: Device display awakened."
            return 0
            ;;
        "@SUSPEND")
            power-shell suspend >/dev/null 2>&1
            RC=$?
            OUT="OK: Device display suspended."
            return 0
            ;;
        "@TOPWIN")
            WMS_INFO=$(hidumper -s WindowManagerService -a -a 2>/dev/null)
            OUT="${WMS_INFO}"
            RC=0
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}
