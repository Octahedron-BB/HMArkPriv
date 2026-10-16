# HMArkPriv (鸿蒙方舟特权中继与跨沙盒插件框架)

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform: HarmonyOS](https://img.shields.io/badge/Platform-HarmonyOS%20NEXT%20%2F%207.0-red.svg)](https://developer.huawei.com/consumer/cn/harmonyos/)
[![Privilege: UID 2000](https://img.shields.io/badge/Privilege-UID%202000%20(shell)-green.svg)]()

> **致谢与声明**：  
> 本项目**参照 Android 平台的 Shizuku 理念**，针对纯血鸿蒙（HarmonyOS NEXT / 7.0 及 HongMeng Kernel）的安全机制与沙盒边界进行了深度逆向与架构重构，**由 Gemini 开发完成**。  
> 旨在为纯血鸿蒙设备（如 HUAWEI Pura 70 系列等）提供一个无需 Root、无需企业开发者证书签名（零签名/免 HAP）、可自由扩展特权插件的跨沙盒通信与自动化框架。

---

## 🌟 核心特性

- ⚡ **零签名 / 零证书 / 免安装 HAP 分发**：完全绕开鸿蒙 7.0 的 `.hap` 开发者证书 UDID 强校验与 XPM 二进制执行白名单，即插即用。
- 🌉 **`hmdfs` 跨沙盒双向通信总线**：利用附加组 `1006(file_manager)` 打通 **鸿蒙 7.0 宿主 (`UID 2000`) ⇄ 鸿蒙原生文件管理 / 浏览器 ⇄ 卓易通 / 出境易 Android 容器**。
- 🧩 **模块化插件框架 (Microkernel Architecture)**：核心仅做指令调度与总线中继，所有具体能力均为独立脚本模块，可自由扩展与热插拔。
- 🎛️ **手机端可视化控制中心 (Web App)**：直接在手机浏览器中打开 `HMArkPriv_Console.html`，具备滑动开关、实时状态卡片、快捷动作与交互式特权命令控制台。

---

## 📦 内置官方模块

| 模块名称 | 标识 | 说明 | 底层调用 |
| :--- | :--- | :--- | :--- |
| **开屏广告跳过** | `adskip` | 应用冷/热启动瞬间自动定位并点击“跳过”（免无障碍） | `uitest dumpLayout` + `uinput` |
| **充电时屏幕常亮** | `keep_awake` | 插入充电器自动保持常亮（24h），拔电自动恢复默认息屏 | `power-shell timeout -o/-r` |
| **短信中继桥** | `sms_forwarder` | 捕获宿主新短信事件并写入共享总线，支持容器应用与 Webhook | `hilog` 遥测 + `curl` Webhook |
| **自动化联动桥** | `macro_kde` | 为 MacroDroid、KDE Connect 等提供全局触摸、按键与宿主调度 | `uinput -T/-K` + `power-shell` |

---

## 📂 项目架构

```text
HMArkPriv/
├── install_and_start.sh        # Mac / PC / Linux 一键安装部署与激活脚本
├── README.md                   # 项目说明与快速上手手册
├── core/
│   ├── daemon.sh              # 框架微内核（模块加载、总线轮询、指令分发）
│   └── bus.sh                 # 跨沙盒 hmdfs 文件总线引擎 (cmd.req / cmd.res / status.json)
├── modules/                   # 独立功能插件目录（可任意扩展）
│   ├── adskip.sh              # 模块 1：开屏广告跳过
│   ├── keep_awake.sh          # 模块 2：充电时屏幕常亮
│   ├── sms_forwarder.sh       # 模块 3：短信转发与中继桥
│   └── macro_kde_bridge.sh    # 模块 4：MacroDroid & KDE Connect 跨沙盒控制桥
├── client/
│   └── hmpriv_cli.sh          # 跨沙盒客户端 CLI（支持卓易通 MT/MacroDroid/终端调用）
├── console/
│   └── HMArkPriv_Console.html # 手机端可视化控制中心（可直接“添加到主屏幕”）
└── docs/
    ├── ARCHITECTURE.md         # 系统架构设计、SELinux 边界与通信原理解析
    └── DEVLOG.md               # 完整逆向与实机排障日志（记录 Binder FD、XPM 等踩坑突破）
```

---

## 🚀 快速上手

### 1. 电脑端一键部署与激活（Mac / Linux / Windows）
手机开启 **开发者选项 -> USB 调试（或无线调试）**，连接电脑后执行：
```bash
./install_and_start.sh
```
若使用 Wi-Fi 无线调试：
```bash
# 连接手机开发者选项显示的无线调试端口
./toolchains/hdc tconn 192.168.1.9:45463
./install_and_start.sh 192.168.1.9:45463
```

---

### 2. 手机端可视化控制（免终端）
1. 打开手机自带的 **「文件管理」** -> **浏览 -> 我的手机 -> `Download` -> `HMArkPriv`**。
2. 点击 **`HMArkPriv_Console.html`**，用系统浏览器打开。
3. （推荐）点击浏览器菜单 -> **「添加到主屏幕」**，桌面上即可直接生成独立 App 图标！
4. 页面提供：
   - 各模块独立开关（开屏广告跳过、充电常亮、短信中继等）；
   - 实时状态监控（PID、充电状态、当前前台应用）；
   - 快捷动作（唤醒屏幕、居中点击、测试延迟）；
   - 网页特权命令行终端。

---

### 3. 在卓易通（MacroDroid / MT 管理器 / KDE Connect）中调用特权

#### 方式 A：MacroDroid 自动化（推荐，免终端）
- 在 MacroDroid 添加动作 -> **文件 -> 写入文本到文件 (Write to File)**；
- 目标路径选择 `/sdcard/MyHarmonyOSDevice/Download/HMArkPriv/cmd.req`（勾选“覆盖现有内容”）；
- 写入文本内容：`{timems}|@TAP 630 1400` 或 `{timems}|power-shell wakeup`；
- 触发动作时，HMArkPriv 守护进程将在 0.25 秒内自动在鸿蒙宿主层完成特权操作。

#### 方式 B：MT 管理器 / 脚本直接调用
```sh
# 查看框架状态与模块开关
sh /sdcard/MyHarmonyOSDevice/Download/HMArkPriv/hmpriv_cli.sh status

# 在鸿蒙宿主执行任意特权指令
sh /sdcard/MyHarmonyOSDevice/Download/HMArkPriv/hmpriv_cli.sh exec "id && uname -a"

# 动态开关指定模块
sh /sdcard/MyHarmonyOSDevice/Download/HMArkPriv/hmpriv_cli.sh adskip on
sh /sdcard/MyHarmonyOSDevice/Download/HMArkPriv/hmpriv_cli.sh keepawake on
```

---

## 🛠️ 如何开发一个自定义插件模块？

在 `modules/` 目录下创建一个新的 Shell 脚本（如 `my_plugin.sh`），实现两个函数：
```sh
mod_myplugin_init() {
    # 模块初始化代码
}

mod_myplugin_poll() {
    # 事件轮询代码（每循环调用）
}
```
并在 `core/daemon.sh` 中引用它，即可无缝获得全套宿主特权能力与总线支持！

---

## 📄 开源许可证

本项目基于 [MIT License](LICENSE) 开源。
