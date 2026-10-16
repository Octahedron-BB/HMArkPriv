#!/bin/sh
# ==============================================================================
# HMArkPriv Module: SMS Forwarder & Event Bridge (modules/sms_forwarder.sh)
# ------------------------------------------------------------------------------
# Bridges incoming SMS/MMS notifications from HarmonyOS 7.0 Host into
# the shared IPC bus (sms_latest.json & sms.log), enabling Zhuoyitong
# container apps (SmsForwarder, MacroDroid, Tasker) to forward SMS seamlessly.
# ==============================================================================

SMS_LOG="${BUS_DIR}/sms.log"
SMS_LATEST="${BUS_DIR}/sms_latest.json"
LAST_SMS_SIG=""

mod_sms_init() {
    [ -w "${SMS_LOG}" ] || printf "=== HMArkPriv SMS Forwarder Bridge Initialized ===\n" > "${SMS_LOG}" 2>/dev/null
    if [ ! -f "${SMS_LATEST}" ] && [ -w "${BUS_DIR}" ]; then
        echo '{"status":"idle","last_event":null}' > "${SMS_LATEST}" 2>/dev/null
    fi
}

mod_sms_poll() {
    [ "${MODULE_SMS}" != "1" ] && return 0

    # Scan hilog for incoming SMS/MMS notification events
    SMS_SIG=$(hilog -x -T mms,smartmmsservice,Telephony 2>/dev/null | grep -iE 'NewSms|ReceiveSms|incoming_sms|sms_receive|A2pRpcSrvStub' | tail -n 1)

    if [ -n "${SMS_SIG}" ] && [ "${SMS_SIG}" != "${LAST_SMS_SIG}" ]; then
        LAST_SMS_SIG="${SMS_SIG}"
        TS=$(date '+%Y-%m-%d %H:%M:%S')

        # Clean string for JSON
        SAFE_TEXT=$(echo "${SMS_SIG}" | sed 's/"/\\"/g; s/\r//g')

        # Write structured latest SMS event
        if [ -w "${SMS_LATEST}" ]; then
            cat <<EOF > "${SMS_LATEST}"
{
  "timestamp": "${TS}",
  "event_type": "INCOMING_SMS",
  "raw_signature": "${SAFE_TEXT}"
}
EOF
        fi

        MSG="[${TS}] [SMS Bridge] New SMS notification event captured."
        [ -w "${SMS_LOG}" ] && echo "${MSG}: ${SMS_SIG}" >> "${SMS_LOG}"
        bus_log "${MSG}"

        # If optional Webhook is configured in config.conf, push immediately
        if [ -n "${SMS_WEBHOOK_URL}" ]; then
            curl -s -X POST -H "Content-Type: application/json" -d "{\"text\":\"[HMArkPriv 鸿蒙短信提醒] ${TS}\"}" "${SMS_WEBHOOK_URL}" >/dev/null 2>&1 &
        fi
    fi
}
