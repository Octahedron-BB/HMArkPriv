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
# 看门狗冻结名单：一行一个包名，# 开头为注释
FROZEN_FILE="${BUS_DIR}/frozen.txt"
# App 沙箱内的 preferences：存令牌哈希（严格模式的唯一数据源）
# 实测 shell(uid 2000) 可读；第三方 App 属 app 域，读不到也写不到。
PREF_FILE="/data/app/el2/100/base/com.octahedron.hmpriv/haps/entry/preferences/hmpriv_trust"
SLOT_COUNT=16
CMD_TIMEOUT_TERM=20
CMD_TIMEOUT_KILL=5

mkdir -p "${WORK_DIR}" 2>/dev/null
mkdir -p "${BUS_DIR}" 2>/dev/null

# ------------------------------------------------------------------------------
# 屏幕状态记录
#
# 用途：记录「是否有人设过 timeout override」。
# 背景：没有任何接口能读回 override 的值（hidumper 全零字段、param 里也没有），
# 唯一能探测「是否存在」的 `timeout -r` 会顺带清除，不能当纯查询用。
#
# 格式（两行，daemon 用 printf 写，App 读起来也简单）：
#   source=app|system
#   timeout=<毫秒>
#
# 注：充电常亮已改用 App 侧的 runningLock（不改 timeout），
# 所以这里现在只用于记录 daemon 启动/退出时的兜底清理状态。
# ------------------------------------------------------------------------------
SCREEN_STATE="${BUS_DIR}/screen_state.txt"

#   $1 = source（app / system）
#   $2 = timeout 毫秒（system 传 0）
write_screen_state() {
    [ -f "${SCREEN_STATE}" ] || return 0
    printf 'source=%s\ntimeout=%s\n' "$1" "$2" > "${SCREEN_STATE}" 2>/dev/null
}

# 状态恢复与清理
cleanup() {
    power-shell timeout -r >/dev/null 2>&1
    write_screen_state "system" "0"
    rm -f "${PID_FILE}" 2>/dev/null
    exit 0
}
trap cleanup INT TERM

# 【重要】启动时先无条件恢复一次系统熄屏超时。
# 上一次 daemon 若被 kill -9 杀掉，trap 不会执行，可能残留 24 小时常亮。
# 这里做一次幂等清理，保证从干净状态开始 —— 这是"幽灵常亮"的根治手段。
power-shell timeout -r >/dev/null 2>&1
write_screen_state "system" "0"

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
FREEZE_CHECK_COUNTER=39

# ------------------------------------------------------------------------------
# 读 config.json 里的值
#
# 设备上没有 jq / awk，用 grep + sed 提取扁平 JSON 的单个字段。
#   $1 = 键名
# 布尔返回 true / false；数字返回数字串；取不到返回空串。
#
# 注：充电常亮已移到 App 侧用 runningLock 实现，daemon 不再需要读
# charging/heartbeat，但这两个函数保留给将来可能的状态读取用。
# ------------------------------------------------------------------------------
cfg_bool() {
    grep -o "\"$1\":[a-z]*" "${CONFIG_FILE}" 2>/dev/null | head -n 1 | sed 's/.*://'
}
cfg_num() {
    grep -o "\"$1\":[0-9]*" "${CONFIG_FILE}" 2>/dev/null | head -n 1 | sed 's/.*://'
}

# ------------------------------------------------------------------------------
# 充电防熄屏 —— 已从 daemon 移除
#
# 【为什么移除】
# 旧实现在这里用 `power-shell timeout -o 86400000` 把屏幕超时改成 24 小时。
# 这有三个痼疾：污染用户设置、必须负责还原、还原失败就成"幽灵常亮"。
#
# 现在改用 App 侧的 @ohos.runningLock（临时锁），实测可行：
#   - 持锁静置 90 秒屏幕不熄
#   - 杀掉 App 释放锁后 90 秒内正常熄屏
#   - 全程不改 settings，unhold() 后立即恢复用户原本的超时设置
# 详见 docs/TODO.md 5.0.1。
#
# daemon 这边**保留启动时的 `power-shell timeout -r` 兜底清理**，
# 用于清掉旧版本可能残留的 override —— 那个清理在文件开头，与本段无关。
# ------------------------------------------------------------------------------

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
# 看门狗冻结
#
# 【设计】
# 鸿蒙 7.0 消费者版没有 `bm disable`（见 docs/TODO.md §4.1），无法真正停用应用。
# 这里用"持续强杀"模拟冻结效果：定期扫进程，发现冻结名单里的应用在跑就杀。
#
# 【能达成什么】
#   ✅ 不能后台常驻：任何进程刚起来就被杀
#   ✅ 手动打开也杀：用户在桌面点开，约 1 秒内被强停（体验上就是"打不开"）
#   ❌ 包仍在：bm dump 仍能查到，其他应用仍能检测到已安装
#   ❌ 能被拉起：aa start 会成功，只是活不过 1 秒
#
# 【为什么不放进主循环每次都查】
# ps -ef 单次约 20ms，每次循环（50ms）都跑会占掉 40% CPU。
# 改成每 20 次循环（约 1 秒）查一次，开销降到约 2%。
#
# 【自我保护】
# 拒绝冻结 com.octahedron.hmpriv 自己 —— 否则 App 会被杀，用户再也点不开
# 界面来解冻，只能靠电脑 hdc 改文件，等于把自己锁死。
# ------------------------------------------------------------------------------
FREEZE_SELF="com.octahedron.hmpriv"

check_frozen() {
    [ -f "${FROZEN_FILE}" ] || return 0
    # 【性能】名单为空时零开销 —— 用户不用这个功能就完全不付出代价
    [ -s "${FROZEN_FILE}" ] || return 0

    # 一次进程快照，避免在名单循环里反复 fork ps。
    # 实测 ps -ef 本身约 100ms（300+ 进程），是这里的主要成本，
    # 所以扫描频率定在 2 秒一次（约 5% CPU），而不是 1 秒。
    #
    # 末列是进程名；应用子进程形如 "包名:进程名"，用 cut 取冒号前的主包名。
    # 不做 sort -u：grep -qxF 不要求有序，去重只是浪费一次 fork。
    RUNNING=$(ps -ef 2>/dev/null | sed 's/.* //' | cut -d: -f1)
    [ -z "${RUNNING}" ] && return 0

    HIT=0
    while IFS= read -r PKG; do
        # 跳过空行、注释、以及自己
        case "${PKG}" in
            ''|'#'*) continue ;;
        esac
        [ "${PKG}" = "${FREEZE_SELF}" ] && continue

        # -x 整行匹配 + -F 固定字符串：
        # 保证 com.a 不会误伤 com.a.b（实测 -x 生效）
        if printf '%s\n' "${RUNNING}" | grep -qxF "${PKG}"; then
            aa force-stop "${PKG}" >/dev/null 2>&1
            HIT=$((HIT + 1))
            log_audit "FREEZE" "0" "force-stop ${PKG}"
        fi
    done < "${FROZEN_FILE}"

    return 0
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

    # ---- 看门狗冻结（每约 2 秒检查一次）----
    # 为什么是 2 秒而不是 1 秒：ps -ef 单次实测约 100ms，
    # 1 秒一次要吃掉约 10% CPU，2 秒一次约 5%，对常驻守护进程更合理。
    # 代价是被冻结的应用启动后最长能活 2 秒（用户感知为"打不开"）。
    FREEZE_CHECK_COUNTER=$((FREEZE_CHECK_COUNTER + 1))
    if [ "${FREEZE_CHECK_COUNTER}" -ge 40 ]; then
        FREEZE_CHECK_COUNTER=0
        check_frozen
    fi

    # Low-power sleep (snappy 50ms interval)
    sleep 0.05
done
