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
AUDIT_LOG="${BUS_DIR}/audit.log"
TOKENS_FILE="${BUS_DIR}/tokens.txt"
CONFIG_FILE="${BUS_DIR}/config.json"
# App 沙箱内的 preferences：存令牌哈希（严格模式的唯一数据源）
# 实测 shell(uid 2000) 可读；第三方 App 属 app 域，读不到也写不到。
PREF_FILE="/data/app/el2/100/base/com.octahedron.hmpriv/haps/entry/preferences/hmpriv_trust"
SLOT_COUNT=16
CMD_TIMEOUT_TERM=20
CMD_TIMEOUT_KILL=5

mkdir -p "${WORK_DIR}" 2>/dev/null
mkdir -p "${BUS_DIR}" 2>/dev/null

# 状态恢复与清理
cleanup() {
    power-shell timeout -r >/dev/null 2>&1
    rm -f "${PID_FILE}" 2>/dev/null
    exit 0
}
trap cleanup INT TERM

# 【重要】启动时先无条件恢复一次系统熄屏超时。
# 上一次 daemon 若被 kill -9 杀掉，trap 不会执行，可能残留 24 小时常亮。
# 这里做一次幂等清理，保证从干净状态开始 —— 这是"幽灵常亮"的根治手段。
power-shell timeout -r >/dev/null 2>&1

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
CHARGE_CHECK_COUNTER=55
IS_KEEPING_AWAKE=0

# ------------------------------------------------------------------------------
# 读 config.json 里的值
#
# 设备上没有 jq / awk，用 grep + sed 提取扁平 JSON 的单个字段。
#   $1 = 键名
# 布尔返回 true / false；数字返回数字串；取不到返回空串。
# ------------------------------------------------------------------------------
cfg_bool() {
    grep -o "\"$1\":[a-z]*" "${CONFIG_FILE}" 2>/dev/null | head -n 1 | sed 's/.*://'
}
cfg_num() {
    grep -o "\"$1\":[0-9]*" "${CONFIG_FILE}" 2>/dev/null | head -n 1 | sed 's/.*://'
}

# ------------------------------------------------------------------------------
# 充电防熄屏
#
# 【为什么不用 hilog 判断充电状态】
# 实测真机 `hilog -x -T BatteryInfo | grep pluggedType` 恒为空字符串 ——
# 鸿蒙根本不往 hilog 打 pluggedType 字段，所以旧实现永远判定"未充电"。
# /sys/class/power_supply 也被 SELinux 拒绝（Permission denied）。
#
# 【现在的做法】
# 充电状态由 App 用 @ohos.batteryInfo 读取后写进 config.json：
#   stayAwakeWhileCharging : 用户的开关
#   charging               : 当前是否在充电
#   heartbeat              : App 最后一次更新的时间戳（秒）
# daemon 只负责按这三个值做幂等切换，不做任何猜测。
#
# 心跳超过 60 秒视为 App 已不在前台，不再维持常亮 —— 避免 App 被杀后
# 状态卡死导致"一直亮"。
# ------------------------------------------------------------------------------
check_stay_awake() {
    STAY_CONF=$(cfg_bool "stayAwakeWhileCharging")
    CHARGING=$(cfg_bool "charging")
    HEARTBEAT=$(cfg_num "heartbeat")

    NOW=$(date +%s)
    STALE=1
    if [ -n "${HEARTBEAT}" ] && [ "${HEARTBEAT}" -gt 0 ]; then
        AGE=$((NOW - HEARTBEAT))
        [ "${AGE}" -le 60 ] && STALE=0
    fi

    SHOULD_AWAKE=0
    if [ "${STAY_CONF}" = "true" ] && [ "${CHARGING}" = "true" ] && [ "${STALE}" -eq 0 ]; then
        SHOULD_AWAKE=1
    fi

    if [ "${SHOULD_AWAKE}" -eq 1 ] && [ "${IS_KEEPING_AWAKE}" -eq 0 ]; then
        power-shell timeout -o 86400000 >/dev/null 2>&1
        IS_KEEPING_AWAKE=1
    elif [ "${SHOULD_AWAKE}" -eq 0 ] && [ "${IS_KEEPING_AWAKE}" -eq 1 ]; then
        power-shell timeout -r >/dev/null 2>&1
        IS_KEEPING_AWAKE=0
    fi
}

# ------------------------------------------------------------------------------
# 令牌校验
#
# 【两种模式】
#   严格模式（优先）：读 App 沙箱 preferences 里的 sha256 哈希。
#     preferences 在 app data 域，第三方 App 属 app 域，读不到也写不到，
#     所以篡改总线文件对校验无效 —— 这是真正的防线。
#   宽松模式（降级）：读不到 preferences 时退回总线 tokens.txt（明文或哈希均可）。
#     这是兼容性兜底：若未来 SELinux 收紧禁止 shell 读 app 数据域，
#     功能不会全挂，只是安全性降一档，并会在审计日志留痕。
#
# 【为什么用 case 而不是 grep 比对哈希】
#   哈希是 64 位十六进制，用 shell case 的 *pattern* 匹配即可，零外部依赖、
#   零子进程开销。且 64 位随机 hex 出现子串误匹配的概率可忽略。
# ------------------------------------------------------------------------------

# 从 preferences XML 提取 "bundleName:hash,hash..." 那一行
read_pref_hashes() {
    [ -f "${PREF_FILE}" ] || return 1
    # 只取 fastBusTokenHashes 这个 key；sed 的 <string key="..."> 在同一行内
    sed -n 's/.*<string key="fastBusTokenHashes">\([^<]*\)<\/string>.*/\1/p' "${PREF_FILE}" 2>/dev/null | head -n 1
}

# 读"曾经启用过令牌鉴权"标记（1 = 是）
read_pref_inited() {
    [ -f "${PREF_FILE}" ] || return 1
    sed -n 's/.*<string key="fastBusInited">\([^<]*\)<\/string>.*/\1/p' "${PREF_FILE}" 2>/dev/null | head -n 1
}

# 计算 sha256（设备有 /bin/sha256sum，实测可用）
sha256_of() {
    printf '%s' "$1" | sha256sum 2>/dev/null | cut -d' ' -f1
}

# 校验令牌，输出 OK / FAIL / NONE
#
#   OK   = 令牌有效
#   FAIL = 令牌无效，或"启用过鉴权但已无有效令牌"（完全封锁）
#   NONE = 从未启用过鉴权（向后兼容：老用户没配令牌时总线仍可用）
#
# 【为什么区分 NONE 和 FAIL】
# 如果只看"当前令牌列表是否为空"，用户吊销最后一个令牌就会把总线变成完全不设防，
# 这与"没有令牌 = 更安全"的直觉正好相反。所以用 fastBusInited 标记区分：
#   从没配过   → NONE（不鉴权）
#   配过又清空 → FAIL（一律拒绝，相当于封锁总线）
verify_token() {
    TOKEN="$1"

    # --- 严格模式：preferences ---
    PREF_ENTRIES=$(read_pref_hashes)
    PREF_INITED=$(read_pref_inited)

    if [ -n "${PREF_ENTRIES}" ]; then
        [ -z "${TOKEN}" ] && { echo FAIL; return; }
        REQ_HASH=$(sha256_of "${TOKEN}")
        [ -z "${REQ_HASH}" ] && { echo FAIL; return; }
        case "${PREF_ENTRIES}" in
            *"${REQ_HASH}"*) echo OK; return ;;
            *)               echo FAIL; return ;;
        esac
    fi

    # 启用过但当前没有任何令牌 -> 完全封锁（不是放行）
    if [ "${PREF_INITED}" = "1" ]; then
        echo FAIL
        return
    fi

    # --- 宽松模式：总线 tokens.txt（preferences 读不到时的降级）---
    if [ -f "${TOKENS_FILE}" ] && [ -s "${TOKENS_FILE}" ]; then
        [ -z "${TOKEN}" ] && { echo FAIL; return; }
        # 兼容两种存量格式：明文令牌，或 sha256 哈希
        if grep -q "^${TOKEN}$" "${TOKENS_FILE}" 2>/dev/null; then
            echo OK; return
        fi
        REQ_HASH=$(sha256_of "${TOKEN}")
        if [ -n "${REQ_HASH}" ] && grep -q "^${REQ_HASH}$" "${TOKENS_FILE}" 2>/dev/null; then
            echo OK; return
        fi
        echo FAIL; return
    fi

    # 两边都没有令牌，且从未启用过 -> 不鉴权
    echo NONE
}

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
# 审计日志追加（带滚动保护）
# ------------------------------------------------------------------------------
log_audit() {
    SLOT_LABEL="$1"
    RET_CODE="$2"
    COMMAND_TEXT="$3"
    [ -f "${AUDIT_LOG}" ] || return 0

    # 日志超过 128KB 时滚动截断（保留最新 200 行）
    LOG_SIZE=$(wc -c < "${AUDIT_LOG}" 2>/dev/null || echo 0)
    if [ "${LOG_SIZE}" -gt 131072 ]; then
        tail -n 200 "${AUDIT_LOG}" > "${WORK_DIR}/audit.tmp" 2>/dev/null && cp "${WORK_DIR}/audit.tmp" "${AUDIT_LOG}" 2>/dev/null
    fi

    # 单行日志记录：时间 | 来源槽位 | 返回码 | 命令摘要
    SUMMARY=$(printf "%s" "${COMMAND_TEXT}" | head -n 1 | cut -c 1-120)
    printf "%s | %s | RC:%s | %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "${SLOT_LABEL}" "${RET_CODE}" "${SUMMARY}" >> "${AUDIT_LOG}" 2>/dev/null
}

# ------------------------------------------------------------------------------
# 扫描队列目录的槽位，处理已填充的请求（极速总线模式）
# ------------------------------------------------------------------------------
process_slots() {
    [ -d "${REQ_DIR}" ] || return 0

    # 1. 检查总线开关状态
    if [ -f "${CONFIG_FILE}" ]; then
        if grep -q '"queueEnabled":false' "${CONFIG_FILE}" 2>/dev/null; then
            return 0
        fi
    fi

    i=0
    while [ "${i}" -lt "${SLOT_COUNT}" ]; do
        SLOT_REQ="${REQ_DIR}/slot${i}.req"
        SLOT_RES="${RES_DIR}/slot${i}.res"

        # -s 判断非空。空文件说明没有请求，跳过
        if [ -s "${SLOT_REQ}" ]; then
            # 读取命令（支持多行，用 cat 读全量）
            SLOT_RAW=$(cat "${SLOT_REQ}" 2>/dev/null)

            # 立刻清空请求槽，允许调用方写入下一条
            printf "" > "${SLOT_REQ}" 2>/dev/null

            if [ -n "${SLOT_RAW}" ]; then
                # 2. 鉴权解析：检查首行是否带有 TOKEN:<token>
                REQ_TOKEN=""
                REQ_CMD=""
                FIRST_LINE=$(printf "%s" "${SLOT_RAW}" | head -n 1)

                if printf "%s" "${FIRST_LINE}" | grep -q '^TOKEN:'; then
                    REQ_TOKEN="${FIRST_LINE#TOKEN:}"
                    REQ_CMD=$(printf "%s" "${SLOT_RAW}" | sed '1d')
                else
                    REQ_CMD="${SLOT_RAW}"
                fi

                # 3. 令牌有效性校验（严格模式优先读 preferences 哈希，否则降级 tokens.txt）
                AUTH_RESULT=$(verify_token "${REQ_TOKEN}")
                AUTH_OK=1
                case "${AUTH_RESULT}" in
                    OK)   AUTH_OK=1 ;;
                    NONE) AUTH_OK=1 ;;   # 未配置令牌：不启用鉴权（向后兼容）
                    *)    AUTH_OK=0 ;;
                esac

                if [ "${AUTH_OK}" -eq 0 ]; then
                    TS=$(date '+%Y-%m-%d %H:%M:%S')
                    printf "RC:403\nTIME:%s\nERROR:Unauthorized: valid token required in first line (TOKEN:<key>)\n" "${TS}" > "${SLOT_RES}" 2>/dev/null
                    log_audit "slot${i}" "403" "BLOCKED [unauthorized] (cmd: ${REQ_CMD})"
                else
                    # 4. 执行命令并记录审计日志
                    # NONE 表示没配令牌；在日志里标出来，让用户知道当前未强制鉴权
                    if [ "${AUTH_RESULT}" = "NONE" ]; then
                        AUTH_TAG=" [no-token-configured]"
                    else
                        AUTH_TAG=""
                    fi
                    run_and_reply "${REQ_CMD}" "${SLOT_RES}" ""
                    log_audit "slot${i}" "${RC}" "${REQ_CMD}${AUTH_TAG}"
                fi
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

    # ---- 自动维护：充电防熄屏（每约 3 秒检查一次）----
    CHARGE_CHECK_COUNTER=$((CHARGE_CHECK_COUNTER + 1))
    if [ "${CHARGE_CHECK_COUNTER}" -ge 60 ]; then
        CHARGE_CHECK_COUNTER=0
        check_stay_awake
    fi

    # Low-power sleep (snappy 50ms interval)
    sleep 0.05
done
