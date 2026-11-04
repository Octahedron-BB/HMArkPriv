#!/bin/sh
# ==============================================================================
# HMArkPriv Shell Server (core/daemon.sh)
# ------------------------------------------------------------------------------
# Minimalist, zero-overhead privileged Shell executor for HarmonyOS 7.0.
# Executes incoming commands from shared bus (cmd.req) and returns output (cmd.res).
# No background polling loops, no battery drain, pure on-demand execution.
# ==============================================================================

WORK_DIR="/data/local/tmp/hmpriv"
BUS_DIR="/storage/media/100/local/files/Docs/Download/HMArkPriv"
PID_FILE="${WORK_DIR}/daemon.pid"
REQ_FILE="${BUS_DIR}/cmd.req"
RES_FILE="${BUS_DIR}/cmd.res"
STATUS_FILE="${BUS_DIR}/status.json"

mkdir -p "${WORK_DIR}" 2>/dev/null
mkdir -p "${BUS_DIR}" 2>/dev/null

# Single instance enforcement
if [ -f "${PID_FILE}" ]; then
    OLD_PID=$(cat "${PID_FILE}" 2>/dev/null)
    if [ -n "${OLD_PID}" ] && [ "${OLD_PID}" != "$$" ] && kill -0 "${OLD_PID}" 2>/dev/null; then
        kill -9 "${OLD_PID}" 2>/dev/null
        sleep 0.1
    fi
fi
echo $$ > "${PID_FILE}"

# Initialize bus files
printf "" > "${REQ_FILE}" 2>/dev/null
printf "ID:init RC:0 TIME:0\nHMArkPriv Shell Server Ready\n" > "${RES_FILE}" 2>/dev/null
printf '{"framework":"HMArkPriv","status":"ready","pid":%d,"uid":%d}\n' "$$" "$(id -u)" > "${STATUS_FILE}" 2>/dev/null

LAST_REQ_ID=""

while true; do
    if [ -s "${REQ_FILE}" ]; then
        RAW_LINE=$(head -n 1 "${REQ_FILE}" 2>/dev/null)
        if [ -n "${RAW_LINE}" ]; then
            REQ_ID=$(echo "${RAW_LINE}" | cut -d'|' -f1)
            CMD=$(echo "${RAW_LINE}" | cut -d'|' -f2-)

            if [ -n "${REQ_ID}" ] && [ "${REQ_ID}" != "${LAST_REQ_ID}" ] && [ -n "${CMD}" ]; then
                LAST_REQ_ID="${REQ_ID}"
                # Clear request immediately
                printf "" > "${REQ_FILE}" 2>/dev/null

                # Execute command with UID 2000 shell privileges.
                #
                # 【关键 1】重定向 stdin (< /dev/null)：
                # sqlite3、某些交互式 toybox 工具会尝试读 stdin，
                # 而 $( ) 里的进程继承了 daemon 的 stdin（终端/管道），
                # 导致永久阻塞，整个总线卡死（实测：sqlite3 --version 卡住 daemon）。
                #
                # 【关键 2】timeout -k 5 20：两级超时
                #   - 20 秒后先发 SIGTERM（给命令优雅退出的机会）
                #   - 再等 5 秒仍在运行则发 SIGKILL（强制终止）
                # 只用 SIGTERM 不够！实测 hidumper -c 阻塞在 Binder 调用时
                # 完全忽略 SIGTERM，timeout 30 形同虚设，daemon 永久卡死。
                # SIGKILL 无法被忽略，必须用 -k 兜底。
                OUT=$(timeout -k 5 20 sh -c "${CMD}" 2>&1 < /dev/null)
                RC=$?
                TS=$(date '+%Y-%m-%d %H:%M:%S')

                # Write response
                printf "ID:%s RC:%d TIME:%s\n%s\n" "${REQ_ID}" "${RC}" "${TS}" "${OUT}" > "${RES_FILE}" 2>/dev/null
            fi
        fi
    fi

    # Low-power sleep (snappy 50ms interval)
    sleep 0.05
done
