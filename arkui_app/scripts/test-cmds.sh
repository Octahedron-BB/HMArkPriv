#!/bin/bash
# ==============================================================================
# HMArkPriv Shell 指令验证脚本
# ------------------------------------------------------------------------------
# 通过文件总线（cmd.req/cmd.res）测试所有命令，与 App 走完全相同的链路。
# 用法：bash test-cmds.sh [组名]
#   组名：info | power | input | app | system | all（默认 all）
# ==============================================================================

HDC="/d/DevEco Studio/sdk/default/openharmony/toolchains/hdc.exe"
T="127.0.0.1:5555"
BUS="/storage/media/100/local/files/Docs/Download/HMArkPriv"

REQ="$BUS/cmd.req"
RES="$BUS/cmd.res"

# 唯一请求 ID 计数器
CNT=0

# 执行一条命令并打印结果
# $1 = 命令字符串
# $2 = 说明（可选）
run() {
  local cmd="$1"
  local desc="${2:-$1}"
  CNT=$((CNT+1))
  local rid="test_$(date +%s)_${CNT}"

  # 清空上次响应，避免误读
  MSYS_NO_PATHCONV=1 timeout 20 "$HDC" -t $T shell "printf '' > $RES" >/dev/null 2>&1

  # 写请求
  MSYS_NO_PATHCONV=1 timeout 20 "$HDC" -t $T shell \
    "printf '%s|%s\n' '$rid' '$cmd' > $REQ" >/dev/null 2>&1

  # 轮询响应（最多 3 秒）
  local i=0 out=""
  while [ $i -lt 30 ]; do
    sleep 0.1
    out=$(MSYS_NO_PATHCONV=1 timeout 15 "$HDC" -t $T shell "cat $RES 2>/dev/null" 2>/dev/null)
    case "$out" in
      "ID:${rid} "*) break ;;
    esac
    i=$((i+1))
  done

  # 解析
  local head=$(echo "$out" | head -n 1)
  local body=$(echo "$out" | tail -n +2)
  local rc=$(echo "$head" | sed -n 's/.*RC:\(-\?[0-9]*\).*/\1/p')

  echo "──────────────────────────────────────────────"
  echo "▸ $desc"
  echo "  \$ $cmd"
  echo "  RC=$rc"

  # 输出体（截断到 12 行，避免刷屏）
  local lines=$(echo "$body" | wc -l)
  if [ "$lines" -le 12 ]; then
    echo "$body" | sed 's/^/  │ /'
  else
    echo "$body" | head -12 | sed 's/^/  │ /'
    echo "  │ ... (共 $lines 行，已截断)"
  fi
  echo ""

  if [ "$rc" = "0" ]; then
    PASS=$((PASS+1))
    RESULT_LIST="${RESULT_LIST}✅ $desc\n"
  else
    FAIL=$((FAIL+1))
    RESULT_LIST="${RESULT_LIST}❌ $desc (RC=$rc)\n"
  fi
}

PASS=0
FAIL=0
RESULT_LIST=""

GROUP="${1:-all}"

# ===== 基础 =====
if [ "$GROUP" = "all" ] || [ "$GROUP" = "info" ]; then
  echo ""
  echo "════════ 基础信息 ════════"
  run "id" "当前用户身份"
  run "echo hello" "基本输出"
  run "date" "系统时间"
  run "uname -a" "内核信息"
  run "pwd" "工作目录"
fi

# ===== 设备参数 =====
if [ "$GROUP" = "all" ] || [ "$GROUP" = "info" ]; then
  echo ""
  echo "════════ 设备参数 ════════"
  run "param get const.product.model" "设备型号"
  run "param get const.product.software.version" "系统版本"
  run "param get const.product.brand" "品牌"
  run "param get | wc -l" "参数总数"
fi

# ===== 电源与屏幕 =====
if [ "$GROUP" = "all" ] || [ "$GROUP" = "power" ]; then
  echo ""
  echo "════════ 电源与屏幕 ════════"
  run "power-shell wakeup" "唤醒屏幕"
  run "power-shell timeout -o 300000" "常亮 5 分钟"
  run "power-shell timeout -r" "恢复默认熄屏"
  run "snapshot_display -f /data/local/tmp/hmpriv/snap_test.jpeg" "截图"
  run "ls -l /data/local/tmp/hmpriv/snap_test.jpeg" "确认截图文件"
fi

# ===== 触控与按键 =====
if [ "$GROUP" = "all" ] || [ "$GROUP" = "input" ]; then
  echo ""
  echo "════════ 触控与按键 ════════"
  run "uinput -T -c 658 1400" "点击屏幕中心"
  run "uinput -T -m 658 2000 658 1200 300" "上滑手势"
  run "uinput -K -d 16 -u 16" "音量+"
  run "uinput -K -d 17 -u 17" "音量-"
fi

# ===== 应用管理 =====
if [ "$GROUP" = "all" ] || [ "$GROUP" = "app" ]; then
  echo ""
  echo "════════ 应用管理 ════════"
  run "bm dump -a | head -20" "已装应用列表(前20)"
  run "bm dump -a | wc -l" "应用总数"
  run "aa dump -l 2>/dev/null | head -15" "任务栈"
  run "bm dump -n com.octahedron.hmpriv 2>/dev/null | head -5" "自家App详情"
fi

# ===== 系统信息 =====
if [ "$GROUP" = "all" ] || [ "$GROUP" = "system" ]; then
  echo ""
  echo "════════ 系统信息 ════════"
  run "hidumper -s BatteryService 2>&1 | head -20" "电池服务"
  run "hidumper -s WifiHotspot 2>&1 | head -10" "热点服务"
  run "hidumper -s WindowManagerService 2>&1 | head -10" "窗口管理"
  run "hidumper --mem 2>&1 | head -10" "内存统计"
  run "hidumper --cpufreq 2>&1 | head -8" "CPU 频率"
fi

# ===== 卓易通（预期失败）=====
if [ "$GROUP" = "all" ] || [ "$GROUP" = "zhuoyitong" ]; then
  echo ""
  echo "════════ 卓易通穿透（模拟器预期失败）════════"
  run "bm dump -a | grep -i android" "是否存在安卓容器"
  run "aa start -b com.android.settings -a com.android.settings.Settings\$NotificationAccessSettingsActivity" "打开通知使用权"
fi

# ===== 汇总 =====
echo ""
echo "══════════════════════════════════════════════"
echo "  汇总：通过 $PASS / 失败 $FAIL"
echo "══════════════════════════════════════════════"
echo -e "$RESULT_LIST"
