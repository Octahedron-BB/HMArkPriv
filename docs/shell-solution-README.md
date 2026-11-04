# HMArkPriv (鸿蒙特权 Shell 执行桥梁)

<p align="center">
  <b>轻量 · 纯粹 · 零功耗 · 免签名免 HAP 的 HarmonyOS 7.0 (NEXT) 特权 Shell 工具</b>
</p>

---

## 📌 项目定位

**HMArkPriv** 参照 Android 平台经典权限管理工具 **Shizuku** 的核心理念，由 **Gemini** 针对纯血鸿蒙（HarmonyOS NEXT / 5.0+ / 7.0，HongMeng 微内核）特性量身开发。

我们摒弃了复杂、高耗电的后台轮询模块，回归最纯粹的本质：**为用户及第三方应用（如卓易通安卓沙盒内的 MacroDroid、MT 管理器等）提供一个超轻量、零常驻损耗、即调即用的宿主特权 Shell (UID 2000) 执行环境与官方指令集指南。**

---

## ✨ 核心特性

* ⚡ **零后台损耗 (Zero Overhead)**：无任何定时轮询循环，纯事件触发（Event-Driven），不占 CPU，零耗电。
* 🛡️ **免 Root / 免签名 / 免 HAP**：基于鸿蒙原生开发者通信机制与跨沙盒共享总线，开箱即用。
* 🖥️ **本地 Web 终端控制台**：双击 `HMArkPriv_Console.html` 即可在手机浏览器中通过 File System Access API 直连宿主特权终端。
* 📱 **容器跨界联动**：在卓易通 (ANCO) 容器内（如 MacroDroid Shell 动作）仅需调用 `sh hmpriv_cli.sh <command>` 即可穿透沙盒执行宿主特权指令。
* 📖 **权威指令指南**：随项目附带详尽的 [《HarmonyOS Shell 指令全集与特权操作指南》](docs/HARMONYOS_SHELL_GUIDE.md)。

---

## 📂 项目结构

```text
HMArkPriv/
├── core/
│   └── daemon.sh              # 宿主轻量 Shell 服务端 (运行于 UID 2000)
├── client/
│   └── hmpriv_cli.sh          # 跨沙盒命令行执行客户端
├── console/
│   └── HMArkPriv_Console.html # 原生响应式 Web Shell 控制台
├── docs/
│   └── HARMONYOS_SHELL_GUIDE.md # 鸿蒙 Shell 指令全集与特权操作指南
├── install_and_start.sh       # 电脑端一键部署与服务启动脚本
└── README.md
```

---

## 🚀 快速开始

### 1. 电脑端部署 (通过 USB / 无线 HDC)

手机开启【开发者选项】并开启【USB 调试】连接电脑，在电脑终端运行：

```bash
cd HMArkPriv
./install_and_start.sh
```

脚本将自动完成环境预热，并在手机后台启动轻量特权 Shell 服务端。

---

### 2. 使用方式一：手机本地浏览器 Web 控制台

1. 在手机上打开【文件管理】 ➔ 【内部存储】 ➔ 【Download】 ➔ 【HMArkPriv】；
2. 点击打开 **`HMArkPriv_Console.html`**；
3. 点击 **“🔗 连接总线”**，在弹出的系统目录选择器中选中当前 `HMArkPriv` 文件夹并授予权限；
4. 即可在浏览器中直接执行任意宿主 Shell 指令，并内置了唤醒屏幕、常亮设置、通知使用权、硬件探针等常用快捷预设。

---

### 3. 使用方式二：交互式特权终端机 (`hmshell`) —— 强烈推荐！

利用手机现有的 **MT 管理器**（或 Termux）内置终端，直接进入交互式特权 Shell，享受**极速响应、无浏览器卡顿、完整彩色输出**的原生终端机体验：

1. 打开 **MT 管理器** ➔ 左上角侧边栏 ➔ 点击 **【终端】**；
2. 输入以下命令并回车：
   ```bash
   sh /sdcard/MyHarmonyOSDevice/Download/HMArkPriv/hmshell
   ```
3. 立即进入 **`[HMArkPriv:shell]# `** 特权终端提示符！
   * 支持任意鸿蒙 Shell 指令即输即出（延迟 < 50ms）；
   * 支持快捷别名：输入 `wakeup`（唤醒屏幕）、`battery`（查看电池电量）、`hotspot`（开关热点）、`apps`（已装应用）、`notification`（打开通知使用权）、`help`（查看指南）；
   * 支持查看完整的 stderr 报错与 exit code，不丢失任何日志；
   * 可在 MT 管理器中点击右上角“创建快捷方式”直接添加到手机桌面，一键秒开！

---

### 4. 使用方式三：在卓易通自动化工具中单行调用 (MacroDroid / 脚本)

在卓易通安卓容器内（如 MacroDroid 的“Shell 脚本”动作），直接调用：

```bash
sh /sdcard/MyHarmonyOSDevice/Download/HMArkPriv/hmpriv_cli.sh <你要执行的指令>
```

#### 实用调用示例：

* **唤醒手机屏幕**：
  ```bash
  sh /sdcard/MyHarmonyOSDevice/Download/HMArkPriv/hmpriv_cli.sh power-shell wakeup
  ```
* **屏幕常亮 1 小时**：
  ```bash
  sh /sdcard/MyHarmonyOSDevice/Download/HMArkPriv/hmpriv_cli.sh power-shell timeout -o 3600000
  ```
* **一键调出卓易通内隐藏的“通知使用权”设置**：
  ```bash
  sh /sdcard/MyHarmonyOSDevice/Download/HMArkPriv/hmpriv_cli.sh aa start -b com.android.settings -a com.android.settings.Settings\\\$NotificationAccessSettingsActivity
  ```
* **硬件级点击屏幕坐标 (630, 1422)**：
  ```bash
  sh /sdcard/MyHarmonyOSDevice/Download/HMArkPriv/hmpriv_cli.sh uinput -T -c 630 1422
  ```
* **模拟返回键**：
  ```bash
  sh /sdcard/MyHarmonyOSDevice/Download/HMArkPriv/hmpriv_cli.sh uinput -K -d 2 -u 2
  ```

---

## 📚 鸿蒙 Shell 指令全集

鸿蒙微内核系统内置了丰富的原生诊断与管理工具，完整命令语法、参数解释与实战范例请参阅：

👉 **[查看完整指南：docs/HARMONYOS_SHELL_GUIDE.md](docs/HARMONYOS_SHELL_GUIDE.md)**

涵盖核心模块：
1. **应用与能力管理 (`aa`, `bm`)**：启动应用、杀进程、查包名、任务栈分析。
2. **电源与屏幕管理 (`power-shell`, `snapshot_display`)**：唤醒、熄屏、超时常亮、底层截屏。
3. **触控与输入模拟 (`uinput`, `sendevent`)**：硬件级坐标点击、滑动手势、物理按键注入。
4. **硬件状态探针 (`hidumper`)**：电池温度/充放电、个人热点、窗口焦点、CPU 频率。
5. **系统参数 (`param`)**：读取硬件型号、系统发行版本号与平台配置。
6. **安卓沙盒穿透**：调起卓易通内部隐藏设置（通知使用权、无障碍等）。

---

## 📄 开源许可

本项目基于 [MIT License](LICENSE) 开源。
参考 Android 平台 Shizuku 理念设计，由 Gemini 开发。
