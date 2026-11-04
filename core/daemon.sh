#!/bin/sh
# ==============================================================================
# HMArkPriv Shell Server (core/daemon.sh)
# ------------------------------------------------------------------------------
# Privileged Shell executor for HarmonyOS 7.0+.
#
# 支持两种总线协议：
#   【协议 1 - 单文件】兼容旧版
#     cmd.req  : <reqId>|<command>
#     cmd.res  : ID:<reqId> RC:<code> TIME:<ts>\n<output>
#
#   【协议 2 - 队列目录】供跨应用调用（方案 C+）
#     req/slotN.req : <command>            （调用方写，处理完由 daemon 清空）
#     res/slotN.res : RC:<code>\nTIME:<ts>\n<output>  （daemon 写，调用方读完自行清空）
#
# 为什么要槽位（slot）而不是动态创建文件：
#   shell（uid 2000）在 hmdfs 目录下无法创建新文件（SELinux 禁 create），
#   只能写已存在的文件。所以 req/slotN.req 和 res/slotN.res 必须预先创建，
#   daemon 只做"读内容 / 清空内容"，绝不创建或删除文件。
#
# ==============================================================================

WORK_DIR="/data/local/tmp/hmpriv"
BUS_DIR="/storage/media/100/local/files/Docs/Download/HMArkPriv"
PID_FILE="${WORK_DIR}/daemon.pid"
REQ_FILE="${BUS_DIR}/cmd.req"
RES_FILE="${BUS_DIR}/cmd.res"
STATUS_FILE="${BUS_DIR}/status.json"
REQ_DIR="${BUS_DIR}/req"
RES_DIR="${BUS_DIR}/res"
SLOT_COUNT=16
CMD_TIMEOUT_TERM=20
CMD_TIMEOUT_KILL=5

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

# ------------------------------------------------------------------------------
# 执行一条命令并写结果
#   $1 = 命令
#   $2 = 输出目标文件（协议1是 cmd.res，协议2是 res/slotN.res）
#   $3 = 响应头格式（协议1带 ID，协议2不带）
#   $4 = reqId（协议1用；协议2传空）
# ------------------------------------------------------------------------------
run_and_reply() {
    CMD_STR="$1"
    OUT_FILE="$2"
    REQ_ID="$3"

    # 【关键 1】stdin 重定向 /dev/null：防止 sqlite3 等交互式工具读 stdin 阻塞
    # 【关键 2】timeout -k：20s 后 SIGTERM，再 5s 后 SIGKILL
    #   仅 SIGTERM 不够 —— 实测 hidumper --mem | head 这类会忽略 TERM
    #   注意：hidumper -c / hidumper --mem(无管道) 阻塞在内核态 Binder 调用，
    #   连 SIGKILL 都无效，只能靠 App 层黑名单拦截
    OUT=$(timeout -k "${CMD_TIMEOUT_KILL}" "${CMD_TIMEOUT_TERM}" sh -c "${CMD_STR}" 2>&1 < /dev/null)
    RC=$?
    TS=$(date '+%Y-%m-%d %H:%M:%S')

    if [ -n "${REQ_ID}" ]; then
        printf "ID:%s RC:%d TIME:%s\n%s\n" "${REQ_ID}" "${RC}" "${TS}" "${OUT}" > "${OUT_FILE}" 2>/dev/null
    else
        printf "RC:%d\nTIME:%s\n%s\n" "${RC}" "${TS}" "${OUT}" > "${OUT_FILE}" 2>/dev/null
    fi
}

# ------------------------------------------------------------------------------
# 扫描队列目录的槽位，处理已填充的请求
# ------------------------------------------------------------------------------
process_slots() {
    [ -d "${REQ_DIR}" ] || return 0

    i=0
    while [ "${i}" -lt "${SLOT_COUNT}" ]; do
        SLOT_REQ="${REQ_DIR}/slot${i}.req"
        SLOT_RES="${RES_DIR}/slot${i}.res"

        # -s 判断非空。空文件说明没有请求，跳过
        if [ -s "${SLOT_REQ}" ]; then
            # 读取命令（支持多行，用 cat 读全量而不是 head -n 1）
            SLOT_CMD=$(cat "${SLOT_REQ}" 2>/dev/null)

            # 立刻清空请求槽，允许调用方写入下一条
            printf "" > "${SLOT_REQ}" 2>/dev/null

            if [ -n "${SLOT_CMD}" ]; then
                run_and_reply "${SLOT_CMD}" "${SLOT_RES}" ""
            fi
        fi

        i=$((i + 1))
    done
}

# ------------------------------------------------------------------------------
# 主循环
# ------------------------------------------------------------------------------
while true; do
    # ---- 协议 1：单文件（兼容旧客户端）----
    if [ -s "${REQ_FILE}" ]; then
        # 读取整个文件，支持多行指令。
        #
        # 这里不能用 ${RAW%%|*} / ${RAW#*|} 切分 —— 实测本机 sh 会把模式里的 '|'
        # 吞掉（${X%%|*} 直接变成 ${X%%*}，返回空串），导致命令全部丢失。
        # 改用 read 内置命令 + IFS 切分：read 的最后一个变量会原样保留剩余部分，
        # 命令体里的管道符 '\|' 和换行都不会被破坏。
        # 用 fd 3 而不是管道，避免 while 循环落在子 shell 里丢失变量。
        REQ_ID=""
        CMD=""
        LINE=""
        exec 3< "${REQ_FILE}"
        IFS='|' read -r REQ_ID CMD <&3
        while IFS= read -r LINE || [ -n "${LINE}" ]; do
            CMD="${CMD}
${LINE}"
            LINE=""
        done <&3
        exec 3<&-

        if [ -n "${REQ_ID}" ] && [ "${REQ_ID}" != "${LAST_REQ_ID}" ] && [ -n "${CMD}" ]; then
            LAST_REQ_ID="${REQ_ID}"
            printf "" > "${REQ_FILE}" 2>/dev/null
            run_and_reply "${CMD}" "${RES_FILE}" "${REQ_ID}"
        fi
    fi

    # ---- 协议 2：队列槽位（跨应用调用）----
    process_slots

    # Low-power sleep (snappy 50ms interval)
    sleep 0.05
done
