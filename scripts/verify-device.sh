#!/bin/bash
# ==============================================================================
# 真机验证脚本 — 通过文件总线（与 App 完全相同的链路）
#
# 与 arkui-app/scripts/verify-all.sh 的区别：
#   - 目标设备是真机 Pura 70 Pro+（toybox 裁剪更严重，无 tr/awk）
#   - 只验证真机能跑的命令，避开已知会卡死 daemon 的 hidumper -c
#   - 每条命令后检查 daemon 存活，异常立即停止
#
# 用法：bash scripts/verify-device.sh [组名]
# ==============================================================================

HDC="/d/DevEco Studio/sdk/default/openharmony/toolchains/hdc.exe"
T="33Z0224430072393"
BUS="/storage/media/100/local/files/Docs/Download/HMArkPriv"
OUT="$(dirname "$0")/../docs/真机指令验证明细.md"
CNT=0; PASS=0; FAIL=0; SKIP=0

# 只有跑 all 时才重置文件；分组跑时累加
if [ "${1:-all}" = "all" ]; then
  : > "$OUT"
  {
    echo "# 真机 Shell 指令验证明细"
    echo ""
    echo "> 设备：Pura 70 Pro+ / HBN-AL80 / 7.0.0.109 / API 26 / arm64-v8a"
    echo "> 时间：$(date '+%Y-%m-%d %H:%M:%S')"
    echo "> 链路：文件总线（cmd.req / cmd.res），与 App 完全相同"
    echo ""
  } >> "$OUT"
fi

# 检查 daemon 是否存活
alive() {
  local pid
  pid=$(MSYS_NO_PATHCONV=1 timeout 15 "$HDC" -t $T shell "ps -ef 2>/dev/null | grep 'hmpriv/daemon.sh' | grep -v grep | head -1" 2>/dev/null)
  [ -n "$pid" ]
}

# 执行一条命令
# $1=命令 $2=说明 $3=分组
run() {
  local cmd="$1" desc="$2" grp="${3:-其他}"
  CNT=$((CNT+1))
  local rid="d${CNT}_$(date +%s)"

  MSYS_NO_PATHCONV=1 timeout 15 "$HDC" -t $T shell "printf '' > $BUS/cmd.res" >/dev/null 2>&1
  MSYS_NO_PATHCONV=1 timeout 15 "$HDC" -t $T shell "printf '%s|%s\n' '$rid' '$cmd' > $BUS/cmd.req" >/dev/null 2>&1

  local i=0 out=""
  # 最多等 28 秒（覆盖 daemon 的 20s + 5s 两级超时）
  while [ $i -lt 280 ]; do
    sleep 0.1
    out=$(MSYS_NO_PATHCONV=1 timeout 12 "$HDC" -t $T shell "cat $BUS/cmd.res 2>/dev/null" 2>/dev/null)
    case "$out" in "ID:${rid} "*) break ;; esac
    i=$((i+1))
  done

  local head body rc summary
  head=$(echo "$out" | head -n 1)
  body=$(echo "$out" | tail -n +2 | sed 's/\r$//')
  rc=$(echo "$head" | sed -n 's/.*RC:\(-\?[0-9]*\).*/\1/p')
  [ -z "$rc" ] && rc="TIMEOUT"

  summary=$(echo "$body" | grep -v '^[[:space:]]*$' | head -n 1 | cut -c1-55)
  [ -z "$summary" ] && summary="(无输出)"

  local icon="❌"
  if [ "$rc" = "0" ]; then
    PASS=$((PASS+1)); icon="✅"
  elif [ "$rc" = "TIMEOUT" ]; then
    SKIP=$((SKIP+1)); icon="⏱"
  else
    FAIL=$((FAIL+1))
  fi

  printf "%s %-24s RC=%-4s %s\n" "$icon" "$desc" "$rc" "$summary"

  if [ "$grp" != "$LAST_GRP" ]; then
    {
      echo ""
      echo "## $grp"
      echo ""
      echo "| | 命令 | RC | 输出摘要 |"
      echo "|---|---|---|---|"
    } >> "$OUT"
    LAST_GRP="$grp"
  fi
  echo "| $icon | \`$cmd\` | $rc | $summary |" >> "$OUT"

  # daemon 挂了就停
  if ! alive; then
    echo ""
    echo "!!! daemon 已停止响应，验证中断 !!!"
    echo "" >> "$OUT"
    echo "> **注意：执行到此命令后 daemon 失去响应，验证中断。**" >> "$OUT"
    return 1
  fi
  return 0
}

LAST_GRP=""
G="${1:-all}"
want() { [ "$G" = "all" ] || [ "$G" = "$1" ]; }

echo "════════ 真机 Shell 指令验证 ════════"

# ---- 环境 ----
if want env; then
  run "id" "用户身份" "1. 环境" || exit 1
  run "uname -a" "内核信息" "1. 环境" || exit 1
  run "uname -m" "CPU 架构" "1. 环境" || exit 1
  run "date" "系统时间" "1. 环境" || exit 1
  run "uptime" "运行时长" "1. 环境" || exit 1
  run "toybox | wc -w" "toybox 命令数" "1. 环境" || exit 1
fi

# ---- bm ----
if want bm; then
  run "bm dump -a | wc -l" "应用行数" "2. bm 包管理" || exit 1
  run "bm dump -n com.octahedron.hmpriv | head -3" "包详情" "2. bm 包管理" || exit 1
  run "bm dump -n com.nonexistent.app" "不存在包" "2. bm 包管理" || exit 1
  run "bm get -u" "设备UDID" "2. bm 包管理" || exit 1
  run "bm clean -c -n com.octahedron.hmpriv" "清缓存" "2. bm 包管理" || exit 1
fi

# ---- param ----
if want param; then
  run "param get const.product.model" "设备型号" "3. param 参数" || exit 1
  run "param get const.product.brand" "品牌" "3. param 参数" || exit 1
  run "param get const.ohos.apiversion" "API版本" "3. param 参数" || exit 1
  run "param get const.product.cpu.abilist" "CPU架构" "3. param 参数" || exit 1
  run "param get | wc -l" "参数总数" "3. param 参数" || exit 1
fi

# ---- 电源 ----
if want power; then
  run "power-shell timeout -o 600000" "常亮10分钟" "4. 电源屏幕" || exit 1
  run "power-shell timeout -r" "恢复默认熄屏" "4. 电源屏幕" || exit 1
  run "power-shell setmode 600" "正常模式" "4. 电源屏幕" || exit 1
  run "power-shell setmode 601" "省电模式" "4. 电源屏幕" || exit 1
  run "power-shell setmode 602" "超级省电" "4. 电源屏幕" || exit 1
  run "power-shell setmode 600" "恢复正常" "4. 电源屏幕" || exit 1
  run "snapshot_display -f /data/local/tmp/hmpriv/vd.jpeg" "截图到tmp" "4. 电源屏幕" || exit 1
  run "ls -l /data/local/tmp/hmpriv/vd.jpeg" "确认截图" "4. 电源屏幕" || exit 1
fi

# ---- uinput ----
if want input; then
  run "uinput -T -c 658 1400" "点击" "5. 输入注入" || exit 1
  run "uinput -T -m 658 2000 658 1200 300" "滑动" "5. 输入注入" || exit 1
  run "uinput -K -d 16 -u 16" "音量+" "5. 输入注入" || exit 1
  run "uinput -K -d 17 -u 17" "音量-" "5. 输入注入" || exit 1
fi

# ---- uitest ----
if want uitest; then
  run "uitest dumpLayout -p /data/local/tmp/hmpriv/vd.json" "导出控件树" "6. uitest" || exit 1
  run "ls -l /data/local/tmp/hmpriv/vd.json" "确认控件树" "6. uitest" || exit 1
  run "uitest uiInput click 658 1400" "UI点击" "6. uitest" || exit 1
fi

# ---- hidumper（可捕获的）----
if want hidumper; then
  run "hidumper -ls | wc -l" "服务数量" "7. hidumper" || exit 1
  run "hidumper --cpufreq | head -3" "CPU频率" "7. hidumper" || exit 1
  run "hidumper --cpuusage | head -3" "CPU使用率" "7. hidumper" || exit 1
  run "hidumper -s BatteryService" "电池服务" "7. hidumper" || exit 1
  run "hidumper -s WindowManagerService" "窗口服务" "7. hidumper" || exit 1
  # 注意：hidumper --mem 在真机上输出极大会卡死 daemon，不在主流程测试
  # 详见报告「危险命令」章节
fi

# ---- 日志 ----
if want log; then
  run "hilog -h | head -3" "hilog帮助" "8. 日志性能" || exit 1
  run "hilog -x | wc -l" "日志行数" "8. 日志性能" || exit 1
  run "hisysevent -l | wc -l" "系统事件行数" "8. 日志性能" || exit 1
  run "SP_daemon -screen" "屏幕分辨率" "8. 日志性能" || exit 1
fi

# ---- Linux 工具（真机裁剪版）----
if want linux; then
  run "ps -ef | wc -l" "进程数" "9. Linux工具" || exit 1
  run "pidof com.octahedron.hmpriv" "按包名查PID" "9. Linux工具" || exit 1
  run "ls /data/local/tmp/hmpriv" "列目录" "9. Linux工具" || exit 1
  run "df -h /data" "磁盘使用" "9. Linux工具" || exit 1
  run "du -sh /data/local/tmp/hmpriv" "目录大小" "9. Linux工具" || exit 1
  run "free -m" "内存" "9. Linux工具" || exit 1
  run "grep -c . /data/local/tmp/hmpriv/daemon.sh" "grep计数" "9. Linux工具" || exit 1
  run "wc -l /data/local/tmp/hmpriv/daemon.sh" "wc统计" "9. Linux工具" || exit 1
  run "sed -n 1p /data/local/tmp/hmpriv/daemon.sh" "sed取行" "9. Linux工具" || exit 1
  run "cut -c1-20 /data/local/tmp/hmpriv/daemon.sh | head -1" "cut截取" "9. Linux工具" || exit 1
  run "find /data/local/tmp/hmpriv -name daemon.sh" "find" "9. Linux工具" || exit 1
  run "md5sum /data/local/tmp/hmpriv/daemon.sh" "md5校验" "9. Linux工具" || exit 1
  run "netstat -an | wc -l" "网络连接数" "9. Linux工具" || exit 1
  run "ifconfig | grep -c inet" "网卡地址数" "9. Linux工具" || exit 1
  run "ping -c 1 -W 1 127.0.0.1" "ping本地" "9. Linux工具" || exit 1
  run "sqlite3 --version" "sqlite3版本" "9. Linux工具" || exit 1
  run "toybox | grep -c tr" "tr是否存在" "9. Linux工具" || exit 1
  run "toybox | grep -c awk" "awk是否存在" "9. Linux工具" || exit 1
fi

# ---- 卓易通 ----
if want zyt; then
  run "bm dump -a | grep -ci android" "安卓容器数量" "10. 卓易通" || exit 1
  run "bm dump -a | grep -ci anco" "ANCO数量" "10. 卓易通" || exit 1
fi

{
  echo ""
  echo "---"
  echo ""
  echo "## 汇总"
  echo ""
  echo "- 总计 **$CNT** 条"
  echo "- 通过 **$PASS**"
  echo "- 失败 **$FAIL**"
  echo "- 超时 **$SKIP**"
} >> "$OUT"

echo ""
echo "════════════════════════════════"
echo "  总计 $CNT / 通过 $PASS / 失败 $FAIL / 超时 $SKIP"
echo "  明细：$OUT"
echo "════════════════════════════════"
