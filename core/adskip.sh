#!/bin/sh
# =============================================================================
# 广告跳过原型 —— 独立脚本，验证「检测 + 点击」闭环
#
# 【为什么要独立脚本】先验证逻辑，跑通后再并进 daemon。避免一上来就改动
# 那个已经很脆弱的常驻进程（它已经因为外部命令卡死过四次）。
#
# 【工作方式】
#   循环 dumpLayout → 找「跳过」节点 → 算中心坐标 → 点击 → 记录
#
# 【性能现实】
#   dumpLayout 单次约 1.3 秒。大麦实测广告窗口约 3 秒（+2s 到 +4s），
#   刚好能抓一次。所以这里不做"每秒抓一次"，而是紧凑连续抓，不留额外间隔。
#
# 【安全闸门】宁可漏过，不可误点。以下任一命中就放弃：
#   - 当前前台是桌面（com.ohos.sceneboard）
#   - 「跳过」附近的文字里有危险词（下载/安装/支付/同意/授权/确认/更新）
#   - 「跳过」后面跟着排除词（片头/片尾/教程/剧情/视频）
# 只认「跳过」这个精确文字；不认「关闭」——关闭按钮误伤面太大。
# =============================================================================

BUS="/storage/media/100/local/files/Docs/Download/HMArkPriv"
WORK="/data/local/tmp/hmpriv"
DUMP="${WORK}/.ad_dump.json"
LOG="${BUS}/adskip.log"
STATE="${WORK}/.ad_state"

# 循环控制：由 App 或手动置 1 开启，0 停止
RUN_FLAG="${WORK}/.ad_run"

# 危险词：出现在同一屏就放弃本次点击
DANGER="下载,安装,支付,同意,授权,确认,更新,立即购买,领取"
# 排除词：「跳过」用于这些场景时不是广告
EXCLUDE="片头,片尾,教程,剧情,视频"

log_line() {
    [ -f "${LOG}" ] || return 0
    printf '%s %s %s\n' "$(date '+%m-%d %H:%M:%S')" "$1" "$2" >> "${LOG}" 2>/dev/null
}

# 从 dump 里取「跳过」节点的 bounds
# 【实现说明】设备 sh 的 grep -oE 行为异常（会多出方括号、返回多行），
# 所以用 sed 把每个节点拆成一行，再用普通 grep 过滤。
find_skip_bounds() {
    sed 's/{"attributes":{/\n{"attributes":{/g' "${DUMP}" 2>/dev/null \
        | grep '"text":"跳过"' \
        | head -n 1 \
        | sed 's/.*"bounds":"//;s/".*//'
}

# 判断当前屏是否含危险词（用拆行 + grep，避免误匹配整份 JSON）
screen_has() {
    sed 's/{"attributes":{/\n{"attributes":{/g' "${DUMP}" 2>/dev/null \
        | grep -q "$1"
}

# 取当前前台 bundle（取第一个非空的）
current_bundle() {
    sed 's/{"attributes":{/\n{"attributes":{/g' "${DUMP}" 2>/dev/null \
        | grep -o '"bundleName":"[^"]*"' \
        | grep -v 'bundleName":""' \
        | head -n 1 \
        | sed 's/.*:"//;s/"//'
}

echo "=== adskip 原型 ==="
log_line "START" "adskip prototype"

while true; do
    # 未开启就休眠（避免空转烧 CPU）
    if [ ! -f "${RUN_FLAG}" ] || [ "$(cat "${RUN_FLAG}" 2>/dev/null)" != "1" ]; then
        sleep 2
        continue
    fi

    timeout -k 2 8 uitest dumpLayout -p "${DUMP}" >/dev/null 2>&1

    BOUNDS=$(find_skip_bounds)
    if [ -z "${BOUNDS}" ]; then
        # 没有「跳过」，极短间隔再试（不额外 sleep，紧跟下一轮）
        continue
    fi

    # ---- 到这里说明找到了「跳过」，开始安全校验 ----
    BUNDLE=$(current_bundle)
    case "${BUNDLE}" in
        com.ohos.sceneboard|'')
            log_line "SKIP-DESKTOP" "bundle=${BUNDLE}"
            continue ;;
    esac

    if screen_has "${EXCLUDE}"; then
        log_line "SKIP-EXCLUDE" "bundle=${BUNDLE}"
        continue
    fi

    HIT_DANGER=""
    OLD_IFS=${IFS}
    IFS=','
    for W in ${DANGER}; do
        if screen_has "${W}"; then
            HIT_DANGER="${W}"
            break
        fi
    done
    IFS=${OLD_IFS}
    if [ -n "${HIT_DANGER}" ]; then
        log_line "SKIP-DANGER" "bundle=${BUNDLE} word=${HIT_DANGER}"
        continue
    fi

    # ---- 算中心坐标并点击 ----
    NUMS=$(printf '%s' "${BOUNDS}" | sed 's/[][,]/ /g')
    set -- ${NUMS}
    CX=$(( ($1 + $3) / 2 ))
    CY=$(( ($2 + $4) / 2 ))

    timeout -k 2 5 uitest uiInput click ${CX} ${CY} >/dev/null 2>&1
    log_line "CLICK" "bundle=${BUNDLE} at=(${CX},${CY})"

    # 点完等广告退场，避免同一屏被反复点
    sleep 1
done
