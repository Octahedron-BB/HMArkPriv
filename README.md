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

### 2. 手机端可视化控制中心
1. 打开手机自带的 **「文件管理」** -> **浏览 -> 我的手机 -> `Download` -> `HMArkPriv`**。
2. 点击 **`HMArkPriv_Console.html`** 用自带浏览器打开。
3. 点击顶部的 **「🔗 连接总线」** 按钮，选择当前的 `Download/HMArkPriv` 文件夹授权。
4. （推荐）点击浏览器菜单 -> **「添加到主屏幕」**，桌面上即可直接生成独立 App 图标！
5. 在控制中心内可以自由勾选：
   - **开屏广告跳过 (AdSkip)**：自动识别纯血应用开屏广告并毫秒级跳过；
   - **充电屏幕常亮 (KeepAwake)**：硬件供电接入时保持 24h 屏幕常亮，拔出后自动恢复系统默认息屏；
   - **后台保活守卫 (KeepAlive Guardian)**：保护卓易通容器、KDE Connect、短信转发器在锁屏与休眠时不掉线、不被挂起；
   - **短信转发中继 (SmsForwarder Bridge)**：捕获系统短信事件并中继推送；
   - **快捷动作**：极速切换热点、唤醒屏幕、特权指令控制台。

---

### 3. HMArkPriv 如何辅助后台软件（KDE Connect / 短信转发器 / MacroDroid）

HMArkPriv 运行在鸿蒙 7.0 宿主系统的 **UID 2000 (Shell)** 特权层，作为底层的**常驻守护神**为沙盒容器内的软件提供深度辅助：

1. **为 KDE Connect 提供网络唤醒与防休眠保障**：
   - 鸿蒙系统在锁屏后几分钟通常会冻结后台 Socket 连接，导致 KDE Connect 与电脑断连。
   - HMArkPriv 的 `KeepAlive` 模块定期进行微内核活跃度脉冲与 Socket 刷新，让 KDE Connect 在息屏状态下也能持续稳定接收通知和传输文件。

2. **为短信转发器 (SmsForwarder) 提供通知中继**：
   - 卓易通沙盒内的应用因权限隔离，无法直接读取纯血鸿蒙系统的短信广播与状态栏通知。
   - HMArkPriv 监听宿主系统的来电与短信事件，并将事件实时写入共享总线 `sms_latest.json`，同时支持直接配置 Webhook 外部推送。

3. **为 MacroDroid 提供底层原生特权动作**：
   - 在鸿蒙 7.0 上，Android 宏无法直接开关热点或调用原生无障碍。
   - MacroDroid 可以通过调用 HMArkPriv，在无需 Root 和 Android Shizuku 的情况下，间接获得鸿蒙原生热点切换、息屏唤醒等系统级执行力。

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
