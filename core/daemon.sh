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
# 屏幕状态：常亮控制 + 真实状态探测
#
# 【为什么状态要由 daemon 记账】
# 实测（uid 2000，非 tty），三个读接口全部失效：
#   hidumper -s PowerManagerService -a -s > f   -> f 是 0 字节（正文只在 tty 输出）
#   power-shell timeout -r            > f   -> f 是 0 字节
#   settings 数据库                          -> Permission denied
# 写操作却照常生效，所以只能"盲写"。唯一能落盘的旁证是 hilog：
#   override 时会打 "I C02902/powermgr/PowerSvc: Try to override screenOffTime,
#                      timeout=%, pid: %, uid: %"
#   而 restore（-r）不打日志 —— 所以"当前是否有 override"仍然只能靠记账，
#   但"是否有别人设过 override"可以靠扫 hilog 发现。
#
# 【状态文件格式】App 直接读它显示，所以键名保持扁平：
#   override=0|1        我们是否设置了屏幕超时覆盖
#   timeout=<毫秒>      override 的值（override=0 时为 0）
#   screen=on|off|unknown   屏幕真实亮灭（来自 hilog 的 screenOn: 行）
#   ts=<秒级时间戳>
# ------------------------------------------------------------------------------
SCREEN_STATE="${BUS_DIR}/screen_state.txt"

# 【为什么是 10 分钟而不是 24 小时】
# override 的值是**真实的超时上限**（实测：设 2 分钟 → 静置 150 秒后确实 SLEEP），
# 而且重复设置会重置空闲计时器（实测：2 分钟的值每 60 秒续一次，连续 4 分钟仍 AWAKE）。
# 所以只要 daemon 活着，短值 + 定期续期 就能一直保持亮屏；
# 而一旦 daemon 意外死亡（kill -9、系统回收），屏幕最多多亮这么久就会自愈。
# 24 小时的值没有这个自愈能力 —— 那正是"幽灵常亮"的来源。
STAY_AWAKE_MS=600000          # 10 分钟：override 单次上限
PROBE_INTERVAL=30             # 每 30 秒探测屏幕与充电
DECIDE_INTERVAL=10            # 每 10 秒决策一次（要不要开/关）
RENEW_INTERVAL=300            # 每 5 分钟续期一次

# 【为什么用秒数而不是循环计数】
# 主循环写的是 `sleep 0.05`，但每次迭代还要做文件探测、槽位扫描，
# 实测一轮远不止 50ms。之前用"计数 × 50ms"推算周期，结果 600 次
# 换算成 30 秒的探测实际要一分多钟才触发一次。
# 改用 date +%s 直接比时间，才和真实时间对齐。
# 为了不给每轮都 fork 一个 date，只在 TICK_GATE 轮里取一次。

# 屏幕亮灭 / 充电状态 的"最近已知值"。必须在启动清理前初始化 ——
# 那时就会调用 probe_system_state 并写状态文件，空值会写进去。
SCREEN_LAST_ONOFF="unknown"
CHARGING_STATE="unknown"

#   $1 = override（0/1）  $2 = timeout 毫秒
write_screen_state() {
    printf 'override=%s\ntimeout=%s\nscreen=%s\ncharging=%s\nts=%s\n' \
        "$1" "$2" "${SCREEN_LAST_ONOFF:-unknown}" "${CHARGING_STATE:-unknown}" \
        "$(date +%s)" > "${SCREEN_STATE}" 2>/dev/null
}

# 读回记账值
read_state_val() {
    grep -o "$1=[^ ]*" "${SCREEN_STATE}" 2>/dev/null | head -n 1 | sed "s/$1=//"
}

# ------------------------------------------------------------------------------
# 一次性探测：屏幕亮灭 + 充电状态
#
# 只 dump 一次 hilog 到临时文件，再分别 grep —— 比调两次省一半开销
# （hilog -x 单次约 310ms，全量 9000 行）。
#
# 数据源一：屏幕亮灭（sceneboard，约每分钟一行）
#   ClockData: needUpdateLockTime screenOn:true|false
#
# 数据源二：充电状态（powermgr，事件驱动，插拔时才打）
#   BatteryInfo: capacity=100, ..., pluggedType=2, ...
#   pluggedType=0 表示未插电。这是 daemon **唯一**能拿到充电状态的途径：
#   /sys/class/power_supply 被 SELinux 拒绝，hidumper -s BatteryService 的输出
#   在没有 tty 时只有表头（158 字节）。日志缓冲区实测跨 20 天不滚动，足够可靠。
# ------------------------------------------------------------------------------
probe_system_state() {
    # 不用 local：本机 sh 是精简实现，POSIX 不保证 local 可用
    PROBE_TMP="${WORK_DIR}/.probe.tmp"
    hilog -x > "${PROBE_TMP}" 2>/dev/null

    # 【关键：查不到不等于状态变了】
    # 环形缓冲区实测只保留约 25 分钟（8000 行上下）。BatteryInfo 是事件驱动
    # （插拔才打），插上电 25 分钟后那条日志就被挤掉了。如果这时把状态写成
    # unknown，就会丢掉"已知在充电"这个有效信息 —— 所以只在**真的读到新行**
    # 时才更新，读不到就沿用上一次的值。
    PROBE_LINE=$(grep 'screenOn:' "${PROBE_TMP}" 2>/dev/null | tail -n 1)
    case "${PROBE_LINE}" in
        *'screenOn:true'*)  SCREEN_LAST_ONOFF="on" ;;
        *'screenOn:false'*) SCREEN_LAST_ONOFF="off" ;;
    esac

    # 只取最后一条带 capacity 的 BatteryInfo 行，避免误抓 power_host 的同名日志
    PROBE_PT=$(grep 'BatteryInfo: capacity' "${PROBE_TMP}" 2>/dev/null \
        | grep -o 'pluggedType=[0-9]*' | tail -n 1)
    case "${PROBE_PT}" in
        pluggedType=0) CHARGING_STATE="no" ;;
        pluggedType=*) CHARGING_STATE="yes" ;;
    esac

    rm -f "${PROBE_TMP}" 2>/dev/null
}

# 兼容旧名字（启动清理阶段用）
probe_screen() {
    probe_system_state
}

# 开启常亮。
#
# 【关于 -f】`hidumper -s PowerManagerService -a -t`（帮助里写 keep screen on）
# 会给 powermgr 挂一把 PowerMgrKeepOnLock。实测它无 tty 也能上锁，但**释放需要
# tty**（无 tty 下 -f 连续 3 次都失败）。所以这把锁一旦被误挂，daemon 大概率解不掉。
# 这里只做 best-effort 清理，真正的保证是"我们从不调用 -t"。
stay_awake_on() {
    hidumper -s PowerManagerService -a -f >/dev/null 2>&1
    power-shell timeout -o "${STAY_AWAKE_MS}" >/dev/null 2>&1
    write_screen_state "1" "${STAY_AWAKE_MS}"
}

# 只续期，不做 -f（避免每次续期都去碰锁表）
stay_awake_renew() {
    power-shell timeout -o "${STAY_AWAKE_MS}" >/dev/null 2>&1
    write_screen_state "1" "${STAY_AWAKE_MS}"
}

# 关闭常亮
stay_awake_off() {
    power-shell timeout -r >/dev/null 2>&1
    write_screen_state "0" "0"
}

# 状态恢复与清理
cleanup() {
    power-shell timeout -r >/dev/null 2>&1
    write_screen_state "0" "0"
    rm -f "${PID_FILE}" 2>/dev/null
    exit 0
}
trap cleanup INT TERM

# 【重要】启动时先无条件恢复一次系统熄屏超时，并解掉可能残留的 keepScreenOn 锁。
# 上一次 daemon 若被 kill -9 杀掉，trap 不会执行，可能残留 24 小时常亮。
# 这里做一次幂等清理，保证从干净状态开始 —— 这是"幽灵常亮"的根治手段。
# 注意 -f 不能省：`hidumper -a -t` 挂的 PowerMgrKeepOnLock 只有 -f 能解，
# `timeout -r` 对它无效（详见 docs/TODO.md 5.0.4）。
power-shell timeout -r >/dev/null 2>&1
hidumper -s PowerManagerService -a -f >/dev/null 2>&1
# 只在"上一次记录足够新"时才继承充电状态（≤10 分钟）。
#
# 为什么必须校验新鲜度：开机时状态文件里可能写着几小时前的 charging=yes，
# 而用户早已拔线。若直接继承，daemon 会误以为在充电 → 一直续期 → 屏幕永不熄。
# 宁可在这种拿不到证据的情况下认定为"未知"（决策层会退回 off），
# 也不要赌一个过期的值 —— 屏幕不熄比功能暂时不生效严重得多。
PREV_TS=$(read_state_val ts)
NOW_TS=$(date +%s)
if [ -n "${PREV_TS}" ] && [ $((NOW_TS - PREV_TS)) -le 600 ]; then
    PREV_CHG=$(read_state_val charging)
    [ -n "${PREV_CHG}" ] && CHARGING_STATE="${PREV_CHG}"
    PREV_SCR=$(read_state_val screen)
    [ -n "${PREV_SCR}" ] && SCREEN_LAST_ONOFF="${PREV_SCR}"
fi
probe_system_state
write_screen_state "0" "0"

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
TICK_GATE=0
LAST_PROBE=0
LAST_DECIDE=0
LAST_RENEW=0

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

    # ---- 内部命令：屏幕常亮控制 ----
    #
    # 这三条不是 shell 命令，而是 daemon 自己处理的状态机操作。
    # 放在这里拦截，是为了让 App 用同一套总线协议（reqId + res）调用，
    # 不用为它们另开一套接口。
    #
    # 前缀用 '__hmpriv_' 是为了不和真实 shell 命令冲突；同时审计日志里
    # 也能一眼看出这是内部命令而非用户输入。
    case "${CMD_STR}" in
        __hmpriv_screen_on)
            # 立刻生效，不等 10 秒决策周期（用户点了开关就该马上有反馈）。
            # 之后由主循环的决策逻辑接管：拔线或关开关时会自动撤销。
            stay_awake_on
            probe_system_state
            write_screen_state "1" "${STAY_AWAKE_MS}"
            TS=$(date '+%Y-%m-%d %H:%M:%S')
            printf "ID:%s RC:0 TIME:%s\nOK override=%s screen=%s charging=%s\n" \
                "${REQ_ID}" "${TS}" "${STAY_AWAKE_MS}" "${SCREEN_LAST_ONOFF}" \
                "${CHARGING_STATE}" > "${OUT_FILE}" 2>/dev/null
            return
            ;;
        __hmpriv_screen_off)
            stay_awake_off
            probe_system_state
            write_screen_state "0" "0"
            TS=$(date '+%Y-%m-%d %H:%M:%S')
            printf "ID:%s RC:0 TIME:%s\nOK override=0 screen=%s charging=%s\n" \
                "${REQ_ID}" "${TS}" "${SCREEN_LAST_ONOFF}" "${CHARGING_STATE}" > "${OUT_FILE}" 2>/dev/null
            return
            ;;
        __hmpriv_screen_status)
            probe_system_state
            TS=$(date '+%Y-%m-%d %H:%M:%S')
            # 读回记账值（App 可能刚重启，状态以文件为准）
            OV=$(read_state_val override)
            TO=$(read_state_val timeout)
            [ -z "${OV}" ] && OV=0
            [ -z "${TO}" ] && TO=0
            printf "ID:%s RC:0 TIME:%s\nOK override=%s timeout=%s screen=%s charging=%s\n" \
                "${REQ_ID}" "${TS}" "${OV}" "${TO}" "${SCREEN_LAST_ONOFF}" \
                "${CHARGING_STATE}" > "${OUT_FILE}" 2>/dev/null
            return
            ;;
    esac

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

    # ---- 定时任务：探测 / 决策 / 续期 ----
    #
    # 每 TICK_GATE 轮取一次当前时间，三个定时任务共用这个时间戳。
    # 这样既保证按真实秒数触发，又不必每轮都 fork date。
    TICK_GATE=$((TICK_GATE + 1))
    if [ "${TICK_GATE}" -ge 20 ]; then
        TICK_GATE=0
        NOW=$(date +%s)

        # 探测：屏幕亮灭 + 充电状态（一次 hilog dump 拿两个信息）
        if [ $((NOW - LAST_PROBE)) -ge "${PROBE_INTERVAL}" ]; then
            LAST_PROBE="${NOW}"
            probe_system_state
            OV=$(read_state_val override)
            TO=$(read_state_val timeout)
            [ -z "${OV}" ] && OV=0
            [ -z "${TO}" ] && TO=0
            write_screen_state "${OV}" "${TO}"
        fi

        # 决策：开关意图 && 正在充电 → 开；否则 → 关
        #
        # 【为什么 daemon 自己决策，而不是听 App 的】
        # App 的充电轮询在 onPageHide 就停了（实测：切后台后 heartbeat 立刻冻结）。
        # 如果照着 App 最后一次上报的"正在充电"一直亮，用户拔线后没人通知 daemon，
        # 屏幕就会一直亮到 override 过期 —— 这正是"幽灵常亮"。
        # daemon 自己从 BatteryInfo 日志读 pluggedType，就不依赖 App 是否在前台。
        #
        # 开关意图仍然来自 App（写进 config.json），这是用户的显式选择。
        if [ $((NOW - LAST_DECIDE)) -ge "${DECIDE_INTERVAL}" ]; then
            LAST_DECIDE="${NOW}"
            TOGGLE=$(cfg_bool stayAwakeWhileCharging)
            CHG="${CHARGING_STATE}"
            # 日志里读不到插拔事件时（缓冲区只有约 25 分钟），退回 App 上报值。
            # 但必须校验心跳是否新鲜：App 切后台后心跳立刻冻结，一个几小时前的
            # "charging:true" 若被当真，会导致拔线后仍然常亮。
            if [ "${CHG}" = "unknown" ]; then
                HB=$(cfg_num heartbeat)
                NOW_HB=$(date +%s)
                if [ -n "${HB}" ] && [ $((NOW_HB - HB)) -le 90 ]; then
                    APP_CHG=$(cfg_bool charging)
                    if [ "${APP_CHG}" = "true" ]; then
                        CHG="yes"
                    else
                        CHG="no"
                    fi
                    # 把有效值记下来：状态文件要反映"实际依据"，也能跨重启继承
                    CHARGING_STATE="${CHG}"
                fi
            fi

            SHOULD="no"
            if [ "${TOGGLE}" = "true" ] && [ "${CHG}" = "yes" ]; then
                SHOULD="yes"
            fi

            OV=$(read_state_val override)
            [ -z "${OV}" ] && OV=0

            if [ "${SHOULD}" = "yes" ]; then
                if [ "${OV}" != "1" ]; then
                    stay_awake_on
                fi
            else
                if [ "${OV}" = "1" ]; then
                    # 拔线 / 关开关 → 立刻撤销，不等 override 自己过期
                    stay_awake_off
                fi
            fi
        fi

        # 续期：值 10 分钟、每 5 分钟续一次，只要 daemon 活着就永不过期；
        # daemon 一死，最多 10 分钟自愈。
        if [ $((NOW - LAST_RENEW)) -ge "${RENEW_INTERVAL}" ]; then
            LAST_RENEW="${NOW}"
            if [ "$(read_state_val override)" = "1" ]; then
                stay_awake_renew
            fi
        fi
    fi

    # Low-power sleep (snappy 50ms interval)
    sleep 0.05
done
