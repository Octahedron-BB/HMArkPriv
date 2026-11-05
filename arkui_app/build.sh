#!/usr/bin/env bash
# ==============================================================================
# HMArkPriv 命令行构建脚本
# ------------------------------------------------------------------------------
# 用法：
#   ./build.sh           # 编译 debug HAP
#   ./build.sh clean     # 清理构建产物
#
# 【为什么不用 hvigorw.bat】
# PackageHap 阶段会 spawn 一个 java 进程按 PATH 查找 java.exe。
# 从 Git Bash 调用 hvigorw.bat 时，PATH 里的 POSIX 路径（/d/DevEco Studio/jbr/bin）
# 不会被转换成 Windows 格式传进 cmd.exe，导致 `spawn java ENOENT`。
# 改为直接用 node 执行 hvigorw.js —— 此时 PATH 是 bash 的 POSIX 环境，
# Node 能正常解析并找到 java（已实测通过）。
# ==============================================================================
set -e

if [ -d "/Applications/DevEco-Studio.app/Contents" ]; then
  DEVECO_HOME="/Applications/DevEco-Studio.app/Contents"
  JBR_BIN="$DEVECO_HOME/jbr/Contents/Home/bin"
  NODE_EXE="$DEVECO_HOME/tools/node/bin/node"
  HVIGOR_JS="$DEVECO_HOME/tools/hvigor/bin/hvigorw.js"
  SDK_DIR="$DEVECO_HOME/sdk"
  export PATH="$JBR_BIN:$DEVECO_HOME/tools/node/bin:$PATH"
  export DEVECO_SDK_HOME="$SDK_DIR"
else
  DEVECO_HOME="D:/DevEco Studio"
  JBR_BIN="/d/DevEco Studio/jbr/bin"
  NODE_EXE="$DEVECO_HOME/tools/node/node.exe"
  HVIGOR_JS="$DEVECO_HOME/tools/hvigor/bin/hvigorw.js"
  SDK_WIN="D:\\DevEco Studio\\sdk"
  export PATH="$JBR_BIN:$PATH"
  export DEVECO_SDK_HOME="$SDK_WIN"
fi

if [ ! -f "$HVIGOR_JS" ]; then
  echo "[!] 找不到 hvigorw.js，请确认 DevEco Studio 安装路径"
  exit 1
fi

cd "$(dirname "$0")"

# ------------------------------------------------------------------------------
# 本机签名配置注入
#
# 仓库里的 build-profile.json5 故意不含 signingConfigs（证书路径和口令只对
# 本机有意义，提交进公开仓库没有价值还泄露信息）。
# 需要真机签名时，把配置写进 build-profile.local.json5（已被 gitignore），
# 这里临时覆盖后构建，退出时还原。
# ------------------------------------------------------------------------------
LOCAL_PROFILE="build-profile.local.json5"
RESTORE_NEEDED=0

restore_profile() {
  if [ "$RESTORE_NEEDED" = "1" ] && [ -f build-profile.json5.bak ]; then
    mv -f build-profile.json5.bak build-profile.json5 2>/dev/null
    RESTORE_NEEDED=0
  fi
}
trap restore_profile EXIT INT TERM

if [ -f "$LOCAL_PROFILE" ]; then
  echo "[*] 检测到本机签名配置，临时注入..."
  cp build-profile.json5 build-profile.json5.bak
  RESTORE_NEEDED=1
  cp "$LOCAL_PROFILE" build-profile.json5
else
  echo "[*] 未找到 $LOCAL_PROFILE，按无签名配置构建（真机需自行签名）"
fi

if [ "$1" = "clean" ]; then
  echo "[*] 清理构建产物..."
  "$NODE_EXE" "$HVIGOR_JS" --mode module -p product=default --no-daemon clean
  restore_profile
  echo "[*] 清理完成"
  exit 0
fi

echo "[*] 开始构建 HMArkPriv..."
"$NODE_EXE" "$HVIGOR_JS" --mode module -p product=default --no-daemon assembleHap -p driverMode=NONE

echo ""
echo "[*] 构建完成，产物："
find entry/build -name "*.hap" -exec ls -lh {} \;
echo ""
if [ "$RESTORE_NEEDED" = "1" ]; then
  echo "[✓] 已使用 $LOCAL_PROFILE 签名，构建后已还原仓库版配置。"
else
  echo "[!] 未配置本机签名，产物中是 unsigned HAP。"
  echo "    模拟器可直接 hdc install；真机请配置 $LOCAL_PROFILE（见文件内说明）。"
fi
