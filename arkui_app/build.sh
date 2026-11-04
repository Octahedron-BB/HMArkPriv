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

DEVECO_HOME="D:/DevEco Studio"
# PATH 里必须用 POSIX 风格路径：Windows 风格路径带冒号(D:)，拼进 PATH
# 后会被 MSYS 错误切分，导致 Node 找不到 java（spawn java ENOENT）
JBR_BIN="/d/DevEco Studio/jbr/bin"
NODE_EXE="$DEVECO_HOME/tools/node/node.exe"
HVIGOR_JS="$DEVECO_HOME/tools/hvigor/bin/hvigorw.js"
# 这个要给 hvigor 用，保持 Windows 反斜杠风格
SDK_WIN="D:\\DevEco Studio\\sdk"

if [ ! -f "$HVIGOR_JS" ]; then
  echo "[!] 找不到 hvigorw.js，请确认 DevEco Studio 安装路径并修改 DEVECO_HOME"
  exit 1
fi

export PATH="$JBR_BIN:$PATH"
export DEVECO_SDK_HOME="$SDK_WIN"

cd "$(dirname "$0")"

if [ "$1" = "clean" ]; then
  echo "[*] 清理构建产物..."
  "$NODE_EXE" "$HVIGOR_JS" --mode module -p product=default --no-daemon clean
  echo "[*] 清理完成"
  exit 0
fi

echo "[*] 开始构建 HMArkPriv..."
"$NODE_EXE" "$HVIGOR_JS" --mode module -p product=default --no-daemon assembleHap -p driverMode=NONE

echo ""
echo "[*] 构建完成，产物："
find entry/build -name "*.hap" -exec ls -lh {} \;
echo ""
echo "[!] 注意：命令行构建产出的是 unsigned HAP。"
echo "    模拟器可直接 hdc install；真机需在 DevEco Studio 里配置自动签名。"
