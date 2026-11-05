#!/bin/bash
# ==============================================================================
# 预创建跨应用调用的队列槽位（方案 C+）
# ------------------------------------------------------------------------------
# 【为什么要预创建】
# daemon 以 shell(uid 2000) 身份运行，在 hmdfs 目录下**无法创建新文件**
# （SELinux 限制：可读写已存在文件，禁止 create）。
# 所以请求/结果槽位必须由权限更高的 hdc 预先创建好，daemon 只做读写不创建。
#
# 【创建什么】
#   Download/HMArkPriv/req/slot0.req ... slot15.req   （调用方写命令）
#   Download/HMArkPriv/res/slot0.res ... slot15.res   （daemon 写结果）
#
# 【权限说明】
# hdc 创建的文件属主 20001006:file_manager、权限 660。
# - daemon（shell，在 file_manager 组）→ 可读写 ✓
# - App（picker 授权后）→ 可读写 ✓
#
# 用法：
#   bash scripts/setup-queue.sh                # 默认 16 个槽位
#   bash scripts/setup-queue.sh 32             # 自定义槽位数
#   bash scripts/setup-queue.sh 16 <设备ID>    # 指定设备
# ==============================================================================

set -e

HDC="${HDC:-/d/DevEco Studio/sdk/default/openharmony/toolchains/hdc.exe}"
SLOTS="${1:-16}"
DEVICE="${2:-}"
BUS="/storage/media/100/local/files/Docs/Download/HMArkPriv"

if [ ! -f "$HDC" ]; then
  echo "[!] 找不到 hdc：$HDC"
  echo "    可用 HDC 环境变量指定路径"
  exit 1
fi

# 统一的 hdc 调用（处理设备选择与路径转换）
h() {
  if [ -n "$DEVICE" ]; then
    MSYS_NO_PATHCONV=1 "$HDC" -t "$DEVICE" "$@"
  else
    MSYS_NO_PATHCONV=1 "$HDC" "$@"
  fi
}

echo "[*] 目标设备：${DEVICE:-默认}"
echo "[*] 槽位数量：$SLOTS"
echo "[*] 总线目录：$BUS"

# 1. 创建目录（hdc 权限高于 shell，可以 mkdir）
echo "[*] 创建 req/ res/ 目录..."
h shell "mkdir -p $BUS/req $BUS/res" >/dev/null 2>&1

# 2. 准备一个本地空文件
# 【坑】hdc file send 对含 ".." 的相对源路径解析会错乱，
# 会把目标当成目录创建。所以先 cd 到临时目录、用纯文件名作源。
TMPD="$(cd "$(dirname "$0")/.." && pwd)/.tmp"
mkdir -p "$TMPD"
: > "$TMPD/empty.bin"
cd "$TMPD"

# 3. 逐槽创建（hdc file send 到已存在目录下的新文件名，hdc 有权创建）
echo "[*] 预创建槽位文件与安全配置文件..."
i=0
while [ "$i" -lt "$SLOTS" ]; do
  h file send empty.bin "$BUS/req/slot$i.req" >/dev/null 2>&1 || true
  h file send empty.bin "$BUS/res/slot$i.res" >/dev/null 2>&1 || true
  i=$((i + 1))
done

# 创建安全管控与审计文件
h file send empty.bin "$BUS/audit.log" >/dev/null 2>&1 || true
h file send empty.bin "$BUS/tokens.txt" >/dev/null 2>&1 || true
# 看门狗冻结名单（一行一个包名，# 开头为注释）
h file send empty.bin "$BUS/frozen.txt" >/dev/null 2>&1 || true
h file send empty.bin "$BUS/screen_state.txt" >/dev/null 2>&1 || true
echo '{"queueEnabled":true}' > "$TMPD/config.json"
h file send "$TMPD/config.json" "$BUS/config.json" >/dev/null 2>&1 || true

# 4. 验证
echo ""
echo "[*] 验证结果："
COUNT_REQ=$(h shell "ls $BUS/req 2>/dev/null | wc -l" 2>/dev/null | tr -d '\r\n ')
COUNT_RES=$(h shell "ls $BUS/res 2>/dev/null | wc -l" 2>/dev/null | tr -d '\r\n ')
echo "    req/ : ${COUNT_REQ} 个文件"
echo "    res/ : ${COUNT_RES} 个文件"

if [ "${COUNT_REQ}" = "$SLOTS" ] && [ "${COUNT_RES}" = "$SLOTS" ]; then
  echo ""
  echo "[✓] 队列槽位就绪，外部 App 可通过以下协议调用："
  echo ""
  echo "    1) 往 $BUS/req/slotN.req 写入命令（N = 0..$((SLOTS-1))）"
  echo "    2) 轮询 $BUS/res/slotN.res 读取结果"
  echo "    3) 结果格式：RC:<退出码> / TIME:<时间> / <命令输出>"
  echo "    4) 读完清空 res/slotN.res（避免误读上次结果）"
else
  echo ""
  echo "[!] 槽位不完整，请检查设备连接和目录权限"
  exit 1
fi
