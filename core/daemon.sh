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
# App 切后台后心跳会冻结。此时允许"沿用最后一次已知的插电状态"多久。
# 设为 90 秒（约 3 轮探测周期）：避免切后台瞬间误熄屏，同时确保拔线后最迟 90 秒必定自愈。
CHG_GRACE=90

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
# 从日志读到的最新充电状态（yes/no/unknown）。每 30 秒刷新。
LOG_CHG="unknown"
# 本次判定用了哪个来源：log / app / none（写进状态文件便于排查）
CHG_SRC="none"
LAST_LOGGED=""
LAST_PS_REFRESH=0
LAST_WD_CHECK=0

#   $1 = override（0/1）  $2 = timeout 毫秒
write_screen_state() {
    printf 'override=%s\ntimeout=%s\nscreen=%s\ncharging=%s\nsrc=%s\nts=%s\n' \
        "$1" "$2" "${SCREEN_LAST_ONOFF:-unknown}" "${CHARGING_STATE:-unknown}" \
        "${CHG_SRC:-none}" "$(date +%s)" > "${SCREEN_STATE}" 2>/dev/null
}

# 状态变迁记录：只在 (charging, override) 变化时追加一行。
#
# 【为什么需要】验证"后台拔线能否被发现"时，hdc 会随 USB 一起断掉，
# 没法实时观察。把变迁记进文件，重新插上后回看即可。
# 只记变化而不是每轮都记，是为了让文件在长时间运行后仍然可读。
# 注：文件必须预先存在 —— 本机 SELinux 禁止 shell 在 hmdfs 目录里新建文件。
HISTORY_LOG="${BUS_DIR}/hist.log"

log_transition() {
    [ -f "${HISTORY_LOG}" ] || return 0
    if [ "$1|$2" = "${LAST_LOGGED}" ]; then
        return 0
    fi
    LAST_LOGGED="$1|$2"
    printf '%s charging=%s override=%s src=%s screen=%s\n' \
        "$(date '+%m-%d %H:%M:%S')" "$1" "$2" "${CHG_SRC:-none}" \
        "${SCREEN_LAST_ONOFF:-unknown}" >> "${HISTORY_LOG}" 2>/dev/null
}

# 读回记账值
read_state_val() {
    grep -o "$1=[^ ]*" "${SCREEN_STATE}" 2>/dev/null | head -n 1 | sed "s/$1=//"
}

# ------------------------------------------------------------------------------
# 探测：屏幕亮灭 + 充电状态
#
# 【性能】用 `hilog -x -e <regex>` 让 hilog 自己过滤，不再全量 dump 到临时文件。
# 这不只是省 CPU：全量一次约 1MB（8000 行），30 秒一轮 = 每天往闪存写约 2.9GB，
# 常驻运行几个月就是实打实的磨损。改成正则过滤后写入量降到几乎为零。
#
# 数据源一：屏幕亮灭（sceneboard，约每分钟一行）
#   ClockData: needUpdateLockTime screenOn:true|false
#
# 数据源二：充电状态（powermgr，**每 30 秒一行**，不是只在插拔时打）
#   BatteryInfo: capacity=100, ..., pluggedType=2, ...
#   pluggedType=0 表示未插电。这是 daemon 唯一能拿到充电状态的途径：
#   /sys/class/power_supply 被 SELinux 拒绝，hidumper -s BatteryService 的输出
#   在没有 tty 时只有表头（158 字节）。
#
# 【缓冲区】core 环形缓冲区默认只有 512KB，会被光感/亮度这类高频日志反复冲掉，
# 导致 30 秒一轮的轮询也可能刚好捞不到那行（这就是之前误判"日志不可靠"的原因）。
# 启动时用 `hilog -G 4M -t core` 扩到 4MB 兜住这个窗口。
# ------------------------------------------------------------------------------
probe_system_state() {
    # 【每个 hilog 都必须套 timeout】
    #
    # 实测事故：daemon 启动后一次请求都没处理过，cmd.res 永远是初始化时写的
    # "Server Ready"，wchan 停在 do_rt_sigsuspend。此时设备上同时有 3 个 hilog
    # 客户端在跑（其中一个是没带 -x 的流式订阅），而 hilogd 对并发客户端是串行的
    # —— 我们的 `hilog -x` 就被堵在锁上，主循环再也走不动。
    #
    # 这类外部命令一律不能裸调。超时后保留上一次的值，宁可状态旧一点，
    # 也不能让整个 daemon 停在探测这一步。
    # 正常耗时约 2~3 秒，给 10 秒已经非常宽松。
    PROBE_LINE=$(timeout -k 2 10 hilog -x -e 'screenOn:' 2>/dev/null | tail -n 1)
    case "${PROBE_LINE}" in
        *'screenOn:true'*)  SCREEN_LAST_ONOFF="on" ;;
        *'screenOn:false'*) SCREEN_LAST_ONOFF="off" ;;
    esac

    # ---- 2) 充电状态（powermgr/BatteryInfo，精准正则过滤，避免全量 dump 闪存磨损与缓冲区冲刷）----
    PROBE_PT=$(timeout -k 2 10 hilog -x -e 'capacity' 2>/dev/null \
        | grep 'BatteryInfo: capacity' | grep -o 'pluggedType=[0-9]*' | tail -n 1)
    case "${PROBE_PT}" in
        pluggedType=0) LOG_CHG="no" ;;
        pluggedType=*) LOG_CHG="yes" ;;
        *)             LOG_CHG="unknown" ;;
    esac
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

# ------------------------------------------------------------------------------
# 看门狗：主循环卡死时自动重启自己
#
# 【为什么需要】这个 daemon 已经两次被"杀不掉的外部命令"卡死：
#   - hidumper --mem（卡在内核 Binder，SIGKILL 无效）
#   - ps -ef（设备深睡眠时卡进 D 状态，timeout 的 SIGKILL 同样无效）
# 每次都只能靠电脑 hdc 手动重启。代码层面能修的已经修了，但 sh 里没法
# 保证"任何情况下都不卡" —— 所以加一个外部守护兜底。
#
# 机制：主循环每约 1~2 秒刷新心跳文件；watchdog 每 20 秒检查一次，
# 超过 90 秒没更新就认定卡死，kill -9 后重新拉起 daemon。
# 90 秒这个阈值远大于正常轮询间隔（<2 秒）和探测耗时（约 3 秒），
# 不会误杀；又足够短，用户基本感知不到异常。
# ------------------------------------------------------------------------------
HEARTBEAT_FILE="${WORK_DIR}/.heartbeat"
WD_HB_FILE="${WORK_DIR}/.wd.heartbeat"
WD_PID_FILE="${WORK_DIR}/.wd.pid"
PHASE_FILE="${WORK_DIR}/.phase"
WATCHDOG_LOG="${WORK_DIR}/watchdog.log"
# 记录本 daemon 的真实 PID（watchdog 用它判断主进程是否还活着）
DAEMON_MAIN_PID="$$"
# 用 $0 拿脚本自身路径（最可靠）。若是相对路径则用 WORK_DIR 补全，
# 这样不论部署在 ${WORK_DIR}/daemon.sh 还是 ${WORK_DIR}/core/daemon.sh 都能重启自己。
DAEMON_SELF="$0"
case "${DAEMON_SELF}" in
    /*) : ;;
    *)  DAEMON_SELF="${WORK_DIR}/${DAEMON_SELF}" ;;
esac

# ------------------------------------------------------------------------------
# 执行位置追踪
#
# 【为什么需要】这个 daemon 已经卡死四次，每次都要靠 ps/fd/wchan 反推停在哪，
# 而且结论都只能"大概"。加一个阶段标记后，看门狗重启时会把它写进日志，
# 下次打开 watchdog.log 就能直接看到 phase=[xxx]。
#
# 【开销】只在阶段变化时写一次小文件，正常循环里阶段在 7~8 个值之间轮转，
# 每秒最多几次小写入，可忽略。
# ------------------------------------------------------------------------------
set_phase() {
    [ "$1" = "${PHASE}" ] && return 0
    PHASE="$1"
    printf '%s' "${PHASE}" > "${PHASE_FILE}" 2>/dev/null
}

start_watchdog() {
    # 【判断依据必须是 watchdog 自己的心跳，不能是 PID 文件】
    # 旧实现把 `$$` 写进 .wd.pid —— 那是 daemon 的 PID（子 shell 里 $$ 仍是父 shell 的），
    # 于是 `kill -0 <daemon pid>` 永远成功，start_watchdog 每次都直接 return。
    # 结果：watchdog 一旦死掉就再也不会被拉起，daemon 卡死 27 小时无人管。
    NOW=$(date +%s 2>/dev/null)
    [ -z "${NOW}" ] && return 0
    if [ -f "${WD_HB_FILE}" ]; then
        WD_LAST=$(timeout 2 cat "${WD_HB_FILE}" 2>/dev/null)
        [ -z "${WD_LAST}" ] && WD_LAST=0
        # 心跳在 60 秒内 → watchdog 活着，不重复启动
        if [ $((NOW - WD_LAST)) -le 60 ]; then
            return 0
        fi
    fi

    (
        # 先写一次心跳，让主循环立刻知道 watchdog 已就位
        printf '%s' "$(date +%s 2>/dev/null)" > "${WD_HB_FILE}" 2>/dev/null
        WD_DAEMON_PID="${DAEMON_MAIN_PID}"
        while true; do
            sleep 15
            printf '%s' "$(date +%s 2>/dev/null)" > "${WD_HB_FILE}" 2>/dev/null

            # 主进程已退出 → watchdog 也退出，让新 daemon 启动自己的 watchdog
            kill -0 "${WD_DAEMON_PID}" 2>/dev/null || exit 0

            HB=$(timeout 2 cat "${HEARTBEAT_FILE}" 2>/dev/null)
            NOW_WD=$(date +%s 2>/dev/null)
            [ -z "${NOW_WD}" ] && continue
            [ -z "${HB}" ] && continue

            AGE=$((NOW_WD - HB))
            if [ "${AGE}" -gt 90 ]; then
                # 记下卡死时的阶段，便于事后定位
                STUCK_PHASE=$(timeout 2 cat "${PHASE_FILE}" 2>/dev/null)
                printf '%s heartbeat stale %ss phase=[%s], restarting\n' \
                    "$(date '+%Y-%m-%d %H:%M:%S')" "${AGE}" "${STUCK_PHASE}" >> "${WATCHDOG_LOG}" 2>/dev/null
                kill -9 "${WD_DAEMON_PID}" 2>/dev/null
                sleep 2
                # 清掉单实例锁，否则新进程会拒绝启动
                rm -f "${PID_FILE}" 2>/dev/null
                nohup sh "${DAEMON_SELF}" >> "${WORK_DIR}/daemon.log" 2>&1 &
                printf '%s restarted pid=%s\n' \
                    "$(date '+%Y-%m-%d %H:%M:%S')" "$!" >> "${WATCHDOG_LOG}" 2>/dev/null
                exit 0
            fi
        done
    ) &
    # 在父 shell 里 $! 才是子 shell 的真实 PID（用于日志/排查，判断存活靠心跳）
    printf '%s' "$!" > "${WD_PID_FILE}" 2>/dev/null
}

# daemon 侧检查 watchdog 是否还活着（双向自愈）
check_watchdog() {
    NOW_WDCHK=$(date +%s 2>/dev/null)
    [ -z "${NOW_WDCHK}" ] && return 0
    WD_LAST=$(timeout 2 cat "${WD_HB_FILE}" 2>/dev/null)
    [ -z "${WD_LAST}" ] && WD_LAST=0
    if [ $((NOW_WDCHK - WD_LAST)) -gt 60 ]; then
        start_watchdog
    fi
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
# 扩大 core 日志缓冲区到 4MB，防止环境光/传感器日志冲刷 powermgr 的 BatteryInfo 行。
#
# 【注意这是设备级设置】`hilog -G` 改的是 hilogd 的全局缓冲区，不只影响本进程，
# 且 daemon 退出后**不会自动恢复**（重启后回默认）。代价是常驻多占约 3.5MB 内存，
# 换来的是插拔电检测不再被日志冲刷影响。若将来想彻底不碰系统状态，
# 可改为只在探测失败时临时扩大、用完还原。
timeout 10 hilog -G 4M -t core >/dev/null 2>&1 || true
# 【不继承充电状态】只继承"屏幕亮灭"这种无副作用的显示用值。
# 充电状态一律由决策循环从 App 心跳重新判断：
# 继承一个旧值（哪怕是 5 分钟前的 charging=yes）都可能让 daemon 误以为在充电，
# 于是不断续期 → 屏幕永不熄。屏幕不熄比功能慢一拍严重得多。
PREV_SCR=$(read_state_val screen)
[ -n "${PREV_SCR}" ] && SCREEN_LAST_ONOFF="${PREV_SCR}"
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

# 写一次心跳，然后启动看门狗
printf '%s' "$(date +%s 2>/dev/null)" > "${HEARTBEAT_FILE}" 2>/dev/null
HEARTBEAT_LAST=""
PHASE=""
set_phase "init"
start_watchdog

LAST_REQ_ID=""
FREEZE_CHECK_COUNTER=39
TICK_GATE=0
LAST_CHG_TS=""
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

    # ---- 执行命令，且**绝不无限等待** ----
    #
    # 【为什么不能直接用 $(timeout ...)】
    # 实测 `hidumper --mem` 阻塞在内核态 Binder 调用里，连 SIGKILL 都杀不死
    # （PID 一直停在 R/D 状态，父进程变成 1）。此时 `$(...)` 会永远等下去，
    # daemon 主循环就死在那一行 —— 用户看到的现象是：点了"内存"，
    # 之后所有命令全部超时，整个 App 像卡死一样。
    #
    # 所以改成：后台跑 + 自己轮询 + 到点就放弃等待。
    # 放弃时不 wait（避免被僵死子进程拖住），直接把超时结果返回给调用方。
    # 被放弃的进程由系统回收（它的父进程会变成 1）。
    OUT_TMP="${WORK_DIR}/.cmdout.tmp"
    : > "${OUT_TMP}" 2>/dev/null

    # 【必须用管道】鸿蒙 `bm dump` 会检查 stdout 的 fstat，若为普通文件直接返回 0 字节，
    # 只有管道才能正常捕获（应用列表为空、报"未找到匹配的应用"就是这个问题）。
    #
    # 【但管道会吞掉退出码】POSIX 里 `(cmd) | cat` 的状态是**最后一个命令**（cat）的，
    # 也就是恒为 0。实测：`sh -c "(exit 3) | cat"` 返回 0。
    # 这会让所有失败命令都显示成功（TerminalConsole 不打印 [exit: N]、
    # BusClient.success 恒为 true、外部调用方拿到的 exitCode 恒为 0）。
    #
    # 解法：在子 shell 里紧跟命令把真实 `$?` 打成一行标记，让它随管道一起流进
    # 输出文件，父进程读完再抠出来并从正文里删掉。这样既保留管道，又保住退出码，
    # 且不依赖 pipefail / PIPESTATUS（设备 sh 都不支持）。
    # 注意必须用**子 shell** `( ... )` 而不是 `{ ... }`：
    # 命令里若有 `exit N`，用 `{ }` 会把整个 sh 直接结束，标记来不及打印，
    # 退出码就丢了（实测 `{ exit 3; }` 拿不到 3）。子 shell 里 exit 只退子 shell。
    RC_MARK="__HM_RC__"
    # 【`< /dev/null` 必须在 sh 这一侧，不能写在 cat 后面】
    # 写成 `sh -c "..." 2>&1 | cat > f < /dev/null` 时，那个重定向作用于 cat，
    # 会把 cat 的 stdin 从管道换成 /dev/null，于是读到空 → 输出全丢。
    # 正确写法：sh 吃 /dev/null（防交互命令阻塞读 stdin），输出走管道给 cat。
    timeout -k "${CMD_TIMEOUT_KILL}" "${CMD_TIMEOUT_TERM}" \
        sh -c "( ${CMD_STR}
); __hm_rc=\$?; printf '%s%s\\n' ${RC_MARK} \"\$__hm_rc\"" \
        < /dev/null 2>&1 | cat > "${OUT_TMP}" &
    CMD_PID=$!

    # 轮询粒度 100ms，上限 CMD_WAIT_SECS（比 timeout 的 20+5 再宽 5 秒，
    # 让 timeout 自己先出手；只有 timeout 也失效时我们才兜底放弃）
    CMD_WAIT_SECS=30
    WAITED=0
    while [ "${WAITED}" -lt $((CMD_WAIT_SECS * 10)) ]; do
        if ! kill -0 "${CMD_PID}" 2>/dev/null; then
            break
        fi
        sleep 0.1
        WAITED=$((WAITED + 1))
    done

    set_phase "cmd-wait"
    TIMED_OUT=0
    if kill -0 "${CMD_PID}" 2>/dev/null; then
        # 到点还活着 —— 这是个杀不死的进程，放弃等待。
        # 再用 -9 试一次（对多数情况有效，对 Binder 阻塞无效但无害）
        kill -9 "${CMD_PID}" 2>/dev/null
        TIMED_OUT=1
    else
        wait "${CMD_PID}" 2>/dev/null
    fi

    # 【读输出必须带超时】这里曾经是第二次死锁点：
    # 命令卡在 D 状态时，管道写入端（cat > OUT_TMP）不会关闭，
    # 裸 `cat` 会一直等 EOF，daemon 随之永久阻塞。
    # 加 timeout 后，最坏情况只是这一条命令的输出丢掉，主循环照常前进。
    OUT=$(timeout 3 cat "${OUT_TMP}" 2>/dev/null)
    rm -f "${OUT_TMP}" 2>/dev/null

    # 从正文尾部抠出真实退出码；抠不到（被超时杀掉）就退回超时语义
    RC_LINE=$(printf '%s\n' "${OUT}" | grep -o "${RC_MARK}[0-9]*" | tail -n 1)
    if [ -n "${RC_LINE}" ]; then
        RC=${RC_LINE#${RC_MARK}}
        OUT=$(printf '%s\n' "${OUT}" | sed "s/${RC_MARK}[0-9]*//")
        # 去掉标记被删后可能残留的空行尾（不影响语义，仅清爽）
        OUT=$(printf '%s' "${OUT}")
    else
        # 没有标记 = 进程被我们放弃等待（或 sh 自己异常退出）→ 按超时处理
        if [ "${TIMED_OUT}" = "1" ]; then
            RC=124
        else
            RC=0
        fi
    fi

    if [ "${TIMED_OUT}" = "1" ]; then
        OUT="${OUT}
[!] 命令在 ${CMD_WAIT_SECS} 秒内未能结束，已放弃等待（进程可能阻塞在内核里，无法杀死）。
[!] daemon 已恢复正常，可以继续执行其它命令。建议改用不依赖 hidumper 的查询方式。"
    fi

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

    # 【绝不在这里同步等 ps】实测事故（2026-11-06）：
    # 一次 `ps -ef` 在设备深睡眠时卡进 D 状态（读 /proc 阻塞），
    # timeout 的 SIGKILL 对 D 状态进程无效，于是整条 `$(...)` 永久等下去，
    # daemon 卡死 5.5 小时，所有命令无响应。
    #
    # 改成后台刷新 + 读上一份快照：
    #   - ps 永远在后台跑，主循环绝不阻塞
    #   - 读文件也套 timeout，万一写入端没关也只是丢一份快照
    # 代价是快照最多滞后一个刷新周期（这里定 5 秒，冻结本就是"1 秒内杀掉"的弱保证）。
    RUNNING_SNAP="${WORK_DIR}/.running.tmp"
    NOW_PS=$(date +%s 2>/dev/null)
    [ -z "${NOW_PS}" ] && NOW_PS=0

    if [ $((NOW_PS - LAST_PS_REFRESH)) -ge 5 ]; then
        LAST_PS_REFRESH="${NOW_PS}"
        # 已有刷新在跑就不叠加（避免卡死时不断堆积 ps 进程）
        if [ ! -f "${WORK_DIR}/.ps.busy" ]; then
            : > "${WORK_DIR}/.ps.busy" 2>/dev/null
            (
                timeout -k 2 10 ps -ef 2>/dev/null \
                    | sed 's/.* //' | cut -d: -f1 > "${RUNNING_SNAP}.new" 2>/dev/null
                if [ -s "${RUNNING_SNAP}.new" ]; then
                    mv -f "${RUNNING_SNAP}.new" "${RUNNING_SNAP}" 2>/dev/null
                fi
                rm -f "${WORK_DIR}/.ps.busy" 2>/dev/null
            ) &
        fi
    fi

    # 用上一份快照做判断；读也套 timeout，防止写入端未关闭。
    # 末列是进程名；应用子进程形如 "包名:进程名"，cut 取冒号前的主包名。
    [ -f "${RUNNING_SNAP}" ] || return 0
    RUNNING=$(timeout 2 cat "${RUNNING_SNAP}" 2>/dev/null)
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
    set_phase "loop"

    # ---- 协议 1：单文件（兼容旧客户端）----
    if [ -s "${REQ_FILE}" ]; then
        set_phase "req-read"
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
    set_phase "slots"
    process_slots

    # ---- 看门狗冻结（每约 2 秒检查一次）----
    # 为什么是 2 秒而不是 1 秒：ps -ef 单次实测约 100ms，
    # 1 秒一次要吃掉约 10% CPU，2 秒一次约 5%，对常驻守护进程更合理。
    # 代价是被冻结的应用启动后最长能活 2 秒（用户感知为"打不开"）。
    FREEZE_CHECK_COUNTER=$((FREEZE_CHECK_COUNTER + 1))
    if [ "${FREEZE_CHECK_COUNTER}" -ge 40 ]; then
        FREEZE_CHECK_COUNTER=0
        set_phase "frozen"
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

        # 刷新心跳（秒变化时才写，避免频繁 IO）。
        # 看门狗靠它判断主循环是否还活着。
        if [ "${NOW}" != "${HEARTBEAT_LAST}" ]; then
            HEARTBEAT_LAST="${NOW}"
            printf '%s' "${NOW}" > "${HEARTBEAT_FILE}" 2>/dev/null
        fi

        # 反向保护：watchdog 也可能死掉，主循环定期确认它还活着
        if [ $((NOW - LAST_WD_CHECK)) -ge 60 ]; then
            LAST_WD_CHECK="${NOW}"
            check_watchdog
        fi

        # 探测：屏幕亮灭 + 充电状态（一次 hilog dump 拿两个信息）
        if [ $((NOW - LAST_PROBE)) -ge "${PROBE_INTERVAL}" ]; then
            LAST_PROBE="${NOW}"
            set_phase "probe"
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

            # 【唯一可信来源：App 的充电心跳】
            # 实测 daemon 侧拿不到充电状态：
            #   /sys/class/power_supply/*      -> Permission denied
            #   /proc/loadavg、/proc/cpuinfo   -> Permission denied
            #   hidumper -s BatteryService     -> 无 tty 只有表头
            #   powermgr 的 BatteryInfo 日志   -> 环形缓冲区仅约 2 分钟，事件早就滚掉了
            # 而 App 用 @ohos.batteryInfo 读 pluggedType 是可靠的，每 3 秒写一次心跳。
            #
            # 代价：App 切后台后心跳立刻冻结（实测 50 秒纹丝不动），此时 daemon
            # 无从判断是否还插着电。所以心跳不新鲜就**判定为不应常亮**，
            # 让 override 在 10 分钟内自然过期 —— 宁可功能暂时不生效，
            # 也不能在拔线后让屏幕一直亮着（那正是之前被用户抓到的 bug）。
            # 【优先级 1：系统日志】每 30 秒一行、轮询 30 秒一次，几乎必然能捞到。
            # 这条不依赖 App，App 在后台/被杀都不影响，是真正的设备级判断。
            HB=$(cfg_num heartbeat)
            NOW_HB=$(date +%s)
            if [ "${LOG_CHG}" = "yes" ] || [ "${LOG_CHG}" = "no" ]; then
                CHARGING_STATE="${LOG_CHG}"
                CHG_SRC="log"
                LAST_CHG_TS="${NOW_HB}"
            elif [ -n "${HB}" ] && [ $((NOW_HB - HB)) -le 120 ]; then
                CHG_SRC="app"
            else
                CHG_SRC="none"
            fi

            # 【优先级 2：App 心跳】仅在日志取不到时作为补充
            if [ "${CHG_SRC}" = "app" ]; then
                if [ "$(cfg_bool charging)" = "true" ]; then
                    CHARGING_STATE="yes"
                else
                    CHARGING_STATE="no"
                fi
                LAST_CHG_TS="${NOW_HB}"
            elif [ "${CHG_SRC}" != "log" ]; then
                # 心跳过期：App 已切后台，无从得知当前是否还插着电。
                #
                # 【为什么沿用旧值而不是立刻判 unknown】
                # 用户的诉求是"拔线后短暂残留可以，但不能一直残留"。
                # 立刻判 unknown 会让常亮在 App 一切后台就失效，等于功能只在
                # 前台可用；而无限沿用又会出现"拔线后屏幕永不熄"。
                # 折中：沿用最后一次已知状态，但设一个硬上限 CHG_GRACE。
                # 超过上限就判 unknown，override 随之停止续期并自然过期。
                if [ -n "${LAST_CHG_TS}" ] \
                    && [ $((NOW_HB - LAST_CHG_TS)) -le "${CHG_GRACE}" ]; then
                    : # 保留 CHARGING_STATE 上一次的值（宽限期内）
                else
                    CHARGING_STATE="unknown"
                fi
            fi
            CHG="${CHARGING_STATE}"

            set_phase "decide"
            SHOULD="no"
            if [ "${TOGGLE}" = "true" ] && [ "${CHG}" = "yes" ]; then
                SHOULD="yes"
            fi

            OV=$(read_state_val override)
            [ -z "${OV}" ] && OV=0

            WROTE=0
            if [ "${SHOULD}" = "yes" ]; then
                if [ "${OV}" != "1" ]; then
                    stay_awake_on
                    WROTE=1
                else
                    # 关键修复：当处于插电常亮状态时，系统在息屏后唤醒（按电源键/敲击/插拔）时，
                    # 锁屏服务（sceneboard/powermgr）会强制写入 OverrideTimeout=10000ms（10秒锁屏短超时）。
                    # 如果 daemon 仅在 OV!=1 时才设置，就会误以为 override 依然有效，
                    # 导致唤醒 10 秒后依然被系统强制熄屏。
                    # 因此在 SHOULD=yes 期间，每轮决策都补一次 stay_awake_renew，
                    # 压制锁屏服务的 10 秒短超时，确保唤醒后永不熄屏。
                    stay_awake_renew
                    WROTE=1
                fi
            else
                if [ "${OV}" = "1" ]; then
                    # 拔线 / 关开关 → 立刻撤销，不等 override 自己过期
                    stay_awake_off
                    WROTE=1
                fi
            fi

            # 【即使动作没变也刷新状态文件】
            # 界面上"充电"这一栏读的是状态文件。以前只有真正切换 override 时才写，
            # 于是开关处于关闭状态时，拔线后要等到 30 秒一次的探测周期才刷新 ——
            # 用户实测能明显感知到这段滞后（"过一段时间变为未插电"）。
            # 决策循环是 10 秒一轮，在这里补写一次，把感知延迟压到 10 秒内。
            if [ "${WROTE}" != "1" ]; then
                if [ "${OV}" = "1" ]; then
                    write_screen_state "1" "${STAY_AWAKE_MS}"
                else
                    write_screen_state "0" "0"
                fi
            fi

            # 记录变迁（只在变化时写一行，用于事后回溯）
            log_transition "${CHARGING_STATE}" "$(read_state_val override)"
        fi

        # 【兜底续期】决策循环在 SHOULD=yes 时已每 10 秒续一次，这里只是双保险：
        # 万一某轮决策因异常没跑到，5 分钟内还会补一次，不至于让 override 过期。
        # 保留它不影响性能（5 分钟一次），删掉也行。
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
