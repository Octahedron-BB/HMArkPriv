#!/bin/bash
# ==============================================================================
# HMArkPriv Shell 指令全集验证脚本
# ------------------------------------------------------------------------------
# 逐条验证 docs/HarmonyOS-Shell-指令全集.md 中的设备端命令。
# 全部通过文件总线执行（与 App 相同链路）。
#
# 用法：bash scripts/verify-all.sh [组名]
#   组名见下方 GROUPS；不传则跑全部。
# 输出：结果汇总到 scripts/verify-result.md
# ==============================================================================

HDC="/d/DevEco Studio/sdk/default/openharmony/toolchains/hdc.exe"
T="127.0.0.1:5555"
BUS="/storage/media/100/local/files/Docs/Download/HMArkPriv"
REQ="$BUS/cmd.req"
RES="$BUS/cmd.res"
OUT_MD="$(dirname "$0")/verify-result.md"
CNT=0
PASS=0
FAIL=0

: > "$OUT_MD"
echo "# 指令全集逐条验证结果" >> "$OUT_MD"
echo "" >> "$OUT_MD"
echo "> 生成时间：$(date '+%Y-%m-%d %H:%M:%S')" >> "$OUT_MD"
echo "> 环境：HarmonyOS 模拟器 / API 26 / x86_64" >> "$OUT_MD"
echo "" >> "$OUT_MD"

# 执行一条命令
# $1 = 命令
# $2 = 说明
# $3 = 分组（用于 markdown 分节）
run() {
  local cmd="$1" desc="$2" grp="${3:-其他}"
  CNT=$((CNT+1))
  local rid="v_$(date +%s%N | tail -c 10)_${CNT}"

  MSYS_NO_PATHCONV=1 timeout 15 "$HDC" -t $T shell "printf '' > $RES" >/dev/null 2>&1
  MSYS_NO_PATHCONV=1 timeout 15 "$HDC" -t $T shell \
    "printf '%s|%s\n' '$rid' '$cmd' > $REQ" >/dev/null 2>&1

  local i=0 out=""
  while [ $i -lt 40 ]; do
    sleep 0.1
    out=$(MSYS_NO_PATHCONV=1 timeout 12 "$HDC" -t $T shell "cat $RES 2>/dev/null" 2>/dev/null)
    case "$out" in "ID:${rid} "*) break ;; esac
    i=$((i+1))
  done

  local head=$(echo "$out" | head -n 1)
  local body=$(echo "$out" | tail -n +2 | tr -d '\r')
  local rc=$(echo "$head" | sed -n 's/.*RC:\(-\?[0-9]*\).*/\1/p')
  [ -z "$rc" ] && rc="TIMEOUT"

  # 取首个非空行作为摘要，截断 60 字符
  local summary=$(echo "$body" | grep -v '^[[:space:]]*$' | head -n 1 | cut -c1-60)
  [ -z "$summary" ] && summary="(无输出)"

  local icon="❌"
  if [ "$rc" = "0" ]; then
    PASS=$((PASS+1)); icon="✅"
  else
    FAIL=$((FAIL+1))
  fi

  printf "%s %-22s RC=%-4s %s\n" "$icon" "$desc" "$rc" "$summary"
  echo "| $icon | \`$cmd\` | $rc | $summary |" >> "$OUT_MD"

  # 分组变化时插入小标题
  if [ "$grp" != "$LAST_GRP" ]; then
    echo "" >> "$OUT_MD"
    echo "## $grp" >> "$OUT_MD"
    echo "" >> "$OUT_MD"
    echo "| | 命令 | RC | 输出摘要 |" >> "$OUT_MD"
    echo "|---|---|---|---|" >> "$OUT_MD"
    LAST_GRP="$grp"
  fi
}

LAST_GRP=""
G="${1:-all}"
want() { [ "$G" = "all" ] || [ "$G" = "$1" ]; }

# ============ 1. Shell 环境 ============
if want env; then
  echo ""; echo "── 1. Shell 环境 ──"
  # 先写分组头（第一条 run 前不写，靠 LAST_GRP 机制，所以这里先手动初始化）
  run "id" "whoami/身份" "1. Shell 环境"
  run "whoami" "whoami" "1. Shell 环境"
  run "uname -a" "内核版本" "1. Shell 环境"
  run "uname -m" "架构" "1. Shell 环境"
  run "cat /proc/version" "内核编译信息" "1. Shell 环境"
  run "getconf LONG_BIT" "位数" "1. Shell 环境"
  run "echo \$SHELL" "默认 shell" "1. Shell 环境"
  run "env | wc -l" "环境变量数" "1. Shell 环境"
  run "date" "系统时间" "1. Shell 环境"
  run "uptime" "运行时长" "1. Shell 环境"
fi

# ============ 2. aa 应用管理 ============
if want aa; then
  echo ""; echo "── 2. aa 工具 ──"
  run "aa help" "aa 帮助" "2. aa 应用管理"
  run "aa start -b com.octahedron.hmpriv -a EntryAbility" "启动应用" "2. aa 应用管理"
  run "aa force-stop com.octahedron.hmpriv" "强制停止" "2. aa 应用管理"
  run "aa dump -l" "任务栈(抓不到)" "2. aa 应用管理"
  run "aa dump -a" "所有 Ability(抓不到)" "2. aa 应用管理"
  run "aa start -b com.nonexistent.app -a X" "启动不存在(应失败)" "2. aa 应用管理"
  run "aa appdebug -b com.octahedron.hmpriv -p 1" "调试模式开" "2. aa 应用管理"
  run "aa appdebug -b com.octahedron.hmpriv -p 0" "调试模式关" "2. aa 应用管理"
  run "aa process -b com.octahedron.hmpriv" "进程信息" "2. aa 应用管理"
  run "aa dump -e" "扩展组件(抓不到)" "2. aa 应用管理"
fi

# ============ 3. bm 包管理 ============
if want bm; then
  echo ""; echo "── 3. bm 工具 ──"
  run "bm help" "bm 帮助" "3. bm 包管理"
  run "bm dump -a" "已装应用列表" "3. bm 包管理"
  run "bm dump -a | wc -l" "应用行数" "3. bm 包管理"
  run "bm dump -n com.octahedron.hmpriv" "包详情" "3. bm 包管理"
  run "bm dump -n com.octahedron.hmpriv | head -3" "包详情前3行" "3. bm 包管理"
  run "bm dump -n com.nonexistent.app" "不存在包(应失败)" "3. bm 包管理"
  run "bm clean -c -n com.octahedron.hmpriv" "清缓存" "3. bm 包管理"
  run "bm clean -d -n com.octahedron.hmpriv" "清数据" "3. bm 包管理"
  run "bm get -u" "获取udid" "3. bm 包管理"
  run "bm dump-dependencies -n com.octahedron.hmpriv" "依赖列表" "3. bm 包管理"
  run "bm dump-shared -n com.octahedron.hmpriv" "共享库" "3. bm 包管理"
fi

# ============ 4. power-shell ============
if want power; then
  echo ""; echo "── 4. 电源与屏幕 ──"
  run "power-shell help" "power-shell 帮助" "4. 电源与屏幕"
  run "power-shell wakeup" "唤醒" "4. 电源与屏幕"
  run "power-shell timeout -o 600000" "常亮10分钟" "4. 电源与屏幕"
  run "power-shell timeout -r" "恢复熄屏" "4. 电源与屏幕"
  run "power-shell setmode 600" "正常模式" "4. 电源与屏幕"
  run "power-shell setmode 601" "省电模式" "4. 电源与屏幕"
  run "power-shell setmode 602" "超级省电" "4. 电源与屏幕"
  run "power-shell setmode 600" "恢复正常模式" "4. 电源与屏幕"
  run "snapshot_display -h" "截图帮助" "4. 电源与屏幕"
  run "snapshot_display -f /data/local/tmp/hmpriv/v.jpeg" "截图到tmp" "4. 电源与屏幕"
  run "ls -l /data/local/tmp/hmpriv/v.jpeg" "确认截图文件" "4. 电源与屏幕"
fi

# ============ 5. uinput ============
if want uinput; then
  echo ""; echo "── 5. uinput 输入注入 ──"
  run "uinput -h" "uinput 帮助" "5. uinput 输入注入"
  run "uinput -T -c 658 1400" "单点点击" "5. uinput 输入注入"
  run "uinput -T -m 658 2000 658 1200 300" "滑动" "5. uinput 输入注入"
  run "uinput -T -d 658 1400 658 1500" "拖拽" "5. uinput 输入注入"
  run "uinput -T -g 658 1400 658 1500 500" "拖拽(带时长)" "5. uinput 输入注入"
  run "uinput -K -d 1 -u 1" "Home键" "5. uinput 输入注入"
  run "uinput -K -d 2 -u 2" "Back键" "5. uinput 输入注入"
  run "uinput -K -d 16 -u 16" "音量+" "5. uinput 输入注入"
  run "uinput -K -d 17 -u 17" "音量-" "5. uinput 输入注入"
  run "uinput -K -d 18 -u 18" "电源键" "5. uinput 输入注入"
  run "uinput -K -d 3 -u 3" "Home(备选码)" "5. uinput 输入注入"
fi

# ============ 6. uitest ============
if want uitest; then
  echo ""; echo "── 6. uitest 自动化 ──"
  run "uitest dumpLayout -p /data/local/tmp/hmpriv/ut.json" "导出控件树" "6. uitest 自动化"
  run "ls -l /data/local/tmp/hmpriv/ut.json" "确认控件树文件" "6. uitest 自动化"
  run "uitest uiInput click 658 1400" "UI点击" "6. uitest 自动化"
  run "uitest uiInput swipe 658 2000 658 1200" "UI滑动" "6. uitest 自动化"
  run "uitest uiInput keyEvent 2" "UI按键(Back)" "6. uitest 自动化"
  run "uitest screenCap /data/local/tmp/hmpriv/uc.png" "UI截图" "6. uitest 自动化"
fi

# ============ 7. hidumper ============
if want hidumper; then
  echo ""; echo "── 7. hidumper 探针 ──"
  run "hidumper -h" "hidumper帮助" "7. hidumper 探针"
  run "hidumper -ls" "列出所有服务" "7. hidumper 探针"
  run "hidumper --mem" "内存统计" "7. hidumper 探针"
  run "hidumper --cpufreq" "CPU频率" "7. hidumper 探针"
  run "hidumper --cpuusage" "CPU使用率" "7. hidumper 探针"
  run "hidumper --net" "网络统计" "7. hidumper 探针"
  run "hidumper --storage" "存储统计" "7. hidumper 探针"
  run "hidumper -s BatteryService" "电池服务" "7. hidumper 探针"
  run "hidumper -s WindowManagerService" "窗口服务" "7. hidumper 探针"
  run "hidumper -s RenderService" "渲染服务" "7. hidumper 探针"
  run "hidumper -s WifiDevice" "WiFi设备" "7. hidumper 探针"
  run "hidumper -s PowerManagerService" "电源服务" "7. hidumper 探针"
fi

# ============ 8. param ============
if want param; then
  echo ""; echo "── 8. param 参数 ──"
  run "param get const.product.model" "设备型号" "8. param 参数"
  run "param get const.product.brand" "品牌" "8. param 参数"
  run "param get const.product.software.version" "系统版本" "8. param 参数"
  run "param get const.ohos.apiversion" "API版本" "8. param 参数"
  run "param get const.product.cpu.abilist" "CPU架构" "8. param 参数"
  run "param get const.build.characteristics" "设备类型" "8. param 参数"
  run "param get | wc -l" "参数总数" "8. param 参数"
  run "param get persist.sys.locale" "系统语言" "8. param 参数"
fi

# ============ 9. 日志与性能 ============
if want log; then
  echo ""; echo "── 9. 日志与性能 ──"
  run "hilog -h" "hilog帮助" "9. 日志与性能"
  run "hilog -x | wc -l" "日志行数" "9. 日志与性能"
  run "hilog -x | tail -3" "最近3条日志" "9. 日志与性能"
  run "hilog -T HMArkPriv | tail -3" "按TAG过滤" "9. 日志与性能"
  run "hilog -Q pidoff" "关闭流控" "9. 日志与性能"
  run "hisysevent -l | head -5" "系统事件列表" "9. 日志与性能"
  run "bytrace --help" "bytrace帮助" "9. 日志与性能"
  run "SP_daemon --help" "SmartPerf帮助" "9. 日志与性能"
  run "SP_daemon -screen" "屏幕分辨率" "9. 日志与性能"
fi

# ============ 10. 服务控制 ============
if want service; then
  echo ""; echo "── 10. 服务控制 ──"
  run "service_control --help" "服务控制帮助" "10. 服务控制"
  run "service_control list" "服务列表" "10. 服务控制"
fi

# ============ 11. Linux/Toybox 工具 ============
if want linux; then
  echo ""; echo "── 11. Linux/Toybox ──"
  run "ps -ef | head -5" "进程列表" "11. Linux/Toybox"
  run "ps -ef | wc -l" "进程数" "11. Linux/Toybox"
  run "pidof com.octahedron.hmpriv" "按包名查PID" "11. Linux/Toybox"
  run "ls /data/local/tmp/hmpriv" "列目录" "11. Linux/Toybox"
  run "df -h /data" "磁盘使用" "11. Linux/Toybox"
  run "du -sh /data/local/tmp/hmpriv" "目录大小" "11. Linux/Toybox"
  run "free -m" "内存" "11. Linux/Toybox"
  run "cat /proc/meminfo | head -3" "内存详情" "11. Linux/Toybox"
  run "grep -c . /data/local/tmp/hmpriv/daemon.sh" "grep计数" "11. Linux/Toybox"
  run "wc -l /data/local/tmp/hmpriv/daemon.sh" "wc统计" "11. Linux/Toybox"
  run "head -3 /data/local/tmp/hmpriv/daemon.sh" "head" "11. Linux/Toybox"
  run "tail -3 /data/local/tmp/hmpriv/daemon.sh" "tail" "11. Linux/Toybox"
  run "awk 'NR==1' /data/local/tmp/hmpriv/daemon.sh" "awk" "11. Linux/Toybox"
  run "sed -n '1p' /data/local/tmp/hmpriv/daemon.sh" "sed" "11. Linux/Toybox"
  run "find /data/local/tmp/hmpriv -name '*.sh'" "find" "11. Linux/Toybox"
  run "md5sum /data/local/tmp/hmpriv/daemon.sh" "md5校验" "11. Linux/Toybox"
  run "netstat -an | head -3" "网络连接" "11. Linux/Toybox"
  run "ifconfig | head -5" "网卡信息" "11. Linux/Toybox"
  run "ping -c 1 -W 1 127.0.0.1" "ping" "11. Linux/Toybox"
  run "which sh" "which" "11. Linux/Toybox"
  run "echo test > /data/local/tmp/hmpriv/t.txt && cat /data/local/tmp/hmpriv/t.txt" "写读文件" "11. Linux/Toybox"
  run "sqlite3 --version" "sqlite3" "11. Linux/Toybox"
fi

# ============ 12. 卓易通 ============
if want zyt; then
  echo ""; echo "── 12. 卓易通(预期失败) ──"
  run "bm dump -a | grep -ci android" "安卓容器数量" "12. 卓易通(模拟器不支持)"
  run "aa start -b com.android.settings -a com.android.settings.Settings\$NotificationAccessSettingsActivity" "通知使用权" "12. 卓易通(模拟器不支持)"
  run "aa start -b com.android.settings -a com.android.settings.Settings\$AccessibilitySettingsActivity" "无障碍设置" "12. 卓易通(模拟器不支持)"
fi

# ============ 汇总 ============
{
  echo ""
  echo "---"
  echo ""
  echo "## 汇总"
  echo ""
  echo "- 总计 **$CNT** 条"
  echo "- 通过 **$PASS** 条"
  echo "- 失败 **$FAIL** 条"
} >> "$OUT_MD"

echo ""
echo "════════════════════════════════"
echo "  总计 $CNT 条 / 通过 $PASS / 失败 $FAIL"
echo "  明细已写入 $OUT_MD"
echo "════════════════════════════════"
