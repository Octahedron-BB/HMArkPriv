# HMArkPriv

> 鸿蒙（HarmonyOS NEXT）特权 Shell 执行桥梁 App —— 让原生应用获得 UID 2000 的 shell 能力。

鸿蒙微内核的安全沙箱机制禁止普通 App 直接派生（spawn）系统 shell 进程。本项目通过 **共享文件总线 + 守护进程 (daemon)** 构筑特权通信桥梁：
在电脑端通过 `hdc` 一次性部署轻量级 `daemon.sh`（运行在系统的 UID 2000 shell 上下文中）监听公共总线目录，HMArkPriv 原生 App 将命令封包写入总线，daemon 执行后将结果回写，App 即时读取并展示在终端控制台与快捷面板中。

同时，HMArkPriv 提供了类似 Android Shizuku 的**跨应用特权调用服务**，支持其他第三方鸿蒙应用接入调用特权能力。

```
┌─────────────────────────────────┐   写 slot/cmd.req   ┌──────────────────────────────┐
│        HMArkPriv App            │ ──────────────────► │          daemon.sh           │
│  (ArkUI 原生应用 / 沙箱环境)      │                     │  (UID 2000 shell / 常驻守护)  │
│                                 │ ◄────────────────── │                              │
└─────────────────────────────────┘   读 slot/cmd.res   └──────────────────────────────┘
                                          ▲
                              公共目录（共享文件总线）
```

---

## ✨ 核心特性

- **原生 ArkUI 体验**：基于 ArkTS / ArkUI 构建，提供多 Tab 界面，内置全功能终端控制台、命令手册抽屉、应用管理与开放平台控制中心。
- **免 Root 特权桥梁**：运行于 UID 2000 (`shell`) 权限，可执行应用启动/强制停止/清理、屏幕/电源控制、触控模拟 (`uinput`/`uitest`) 等 290+ 项系统级指令。
- **开放跨应用生态**：
  - **「弹窗授权模式」 (Want IPC)**：严格遵循鸿蒙系统标准 IPC，用户交互式弹窗审批授权，直观安全。
  - **「极速总线模式」 (Queue IPC)**：基于多槽位并发总线，毫秒级响应，内置 **Token 密钥鉴权**、**主开关熔断** 与 **完整安全审计日志**。
- **持久化自愈**：利用系统 `fileShare` 授权持久化技术，用户只需在首次启动时点选一次目录授权，后续冷启动毫秒级自动连通。

---

## 🚀 快速上手（3 步）

### 1. 部署守护进程 (daemon)

电脑通过 USB 连接手机并配置好 `hdc` 工具：

```bash
# 运行一键部署脚本（自动创建总线目录、初始化令牌、启动守护进程）
./install_and_start.sh
```

或手动部署：
```bash
hdc file send core/daemon.sh /data/local/tmp/hmpriv/daemon.sh
hdc shell "chmod 755 /data/local/tmp/hmpriv/daemon.sh"
hdc shell "sh -c 'nohup sh /data/local/tmp/hmpriv/daemon.sh >/dev/null 2>&1 & sleep 1'"

# 验证状态
hdc shell "cat /storage/media/100/local/files/Docs/Download/HMArkPriv/status.json"
# 期望返回：{"framework":"HMArkPriv","status":"ready","pid":35692,"uid":2000}
```

### 2. 编译并安装 App

进入 `arkui_app` 目录，直接跑 `./build.sh`（会自动定位 DevEco Studio 与 JDK）：

```bash
cd arkui_app
./build.sh
# 产物：
#   entry/build/default/outputs/default/entry-default-unsigned.hap
#   entry/build/default/outputs/default/entry-default-signed.hap（配置了本机签名时才有）
```

- **模拟器调试**（免签名直接安装）：
  ```bash
  hdc install -r entry/build/default/outputs/default/entry-default-unsigned.hap
  ```
- **真机安装**（需要签名）：

  仓库里的 `build-profile.json5` **故意不含签名配置** —— 证书路径和加密口令只对
  各自机器有意义，提交进公开仓库既没用又泄露信息。请自行创建
  `arkui_app/build-profile.local.json5`（已被 `.gitignore` 忽略），
  内容模板见该文件内的注释；`build.sh` 检测到它就会临时注入，构建完自动还原。

  最省事的做法：在 DevEco Studio 里打开 `arkui_app`，
  `File → Project Structure → Signing Configs` 勾选
  **Automatically generate signature**（需登录华为账号并连真机），
  然后把生成的 `signingConfigs` 段拷进 `build-profile.local.json5`。

  ```bash
  hdc install -r entry/build/default/outputs/default/entry-default-signed.hap
  ```

### 3. 打开 App 享受特权

在手机上打开 **HMArkPriv**：
1. 首次打开点击首页提示的「授权」按钮，选择系统的 `Download/HMArkPriv` 文件夹（一次授权，永久免重新选择）。
2. 顶部状态指示灯变绿，显示 `Daemon 在线 (UID:2000)`。
3. 切换到底部「终端」Tab，即刻看到 `已连接 daemon (PID: xxx)`，开始输入指令体验！

---

## 🔌 跨应用特权调用 (OpenAPI)

HMArkPriv 提供了一套类似 Shizuku 的跨应用调用方案，允许第三方 App 轻松获得特权 shell 权限：

- **「弹窗授权模式」 (Want IPC)**：通过 `startAbilityForResult` 向 HMArkPriv 发送执行请求，HMArkPriv 弹出系统确认卡片，经用户许可后返回执行结果。
- **「极速总线模式」 (Queue IPC)**：通过共享目录多槽位请求通道（`slot0.req` ~ `slot15.req`）通信。第三方应用先向 HMArkPriv 申请独立 Token，随后即可在后台以毫秒级时延执行特权命令。令牌只以 sha256 哈希形式存放于 App 沙箱，配合主开关熔断与审计追踪。

第三方项目只需将 [`arkui_app/sdk/HmprivClient.ets`](arkui_app/sdk/HmprivClient.ets) 拷入工程即可使用。详细接口规范请参阅 [跨应用调用协议](docs/跨应用调用协议.md)。

---

## 📂 仓库结构

```
HMArkPriv/
├── core/
│   ├── daemon.sh              # 特权 shell 守护进程（运行在 UID 2000 shell）
│   └── hmprivd.c              # 高性能守护进程 C 源码参考
├── scripts/
│   ├── setup-queue.sh         # 总线队列与安全配置文件初始化脚本
│   └── verify-device.sh       # 真机 60 条指令实测验证脚本
├── install_and_start.sh       # hdc 一键守护进程部署脚本
├── arkui_app/                 # HarmonyOS 原生 ArkUI 应用工程
│   ├── entry/                 # 主模块源码 (ArkTS)
│   │   └── src/main/ets/
│   │       ├── common/        # 常量定义
│   │       ├── components/    # 终端、侧边栏、状态卡片、开放平台等 UI 组件
│   │       ├── model/         # 数据模型与指令定义
│   │       ├── pages/         # 首页 Tab 容器
│   │       ├── services/      # 总线客户端、权限持久化、跨应用调度、令牌管理
│   │       └── utils/         # 命令构造器、日志工具、布局解析
│   ├── sdk/
│   │   └── HmprivClient.ets   # 第三方 App 接入用 SDK
│   └── README.md              # App 工程详细编译与架构说明
├── docs/                      # 核心文档中心
│   ├── README.md              # 文档导航与职责分工说明
│   ├── HarmonyOS-Shell-指令全集.md # 290+ 系统指令大典（四级可信度标注）
│   ├── 跨应用调用协议.md       # 第三方调用 OpenAPI 规范与 SDK 示例
│   ├── 跨应用调用技术方案.md   # 跨应用 IPC 调研与架构背景
│   ├── ARCHITECTURE.md        # 系统底层安全微内核与特权模型解析
│   ├── HMArkPriv-App-技术方案.md # App 内部架构与生命周期设计
│   ├── 真机验证报告.md        # Pura 70 Pro+ 实机落地打通报告
│   ├── 真机vs模拟器差异报告.md # 差异分析与 60 条实测指令明细
│   ├── Shell指令验证报告.md   # 指令级测试与 stdin 挂起避坑报告
│   └── TODO.md                # 演进路线图与待办规划
└── LICENSE
```

---

## 📖 文档导航

所有技术文档均收录在 [`docs/`](docs/) 目录下，各司其职：
- **查看开发进度与已知限制** ➡️ [TODO.md](docs/TODO.md)
- **查阅全部系统可用指令** ➡️ [HarmonyOS-Shell-指令全集.md](docs/HarmonyOS-Shell-指令全集.md)
- **为你的 App 接入特权能力** ➡️ [跨应用调用协议.md](docs/跨应用调用协议.md)
- **了解鸿蒙权限边界与总线架构** ➡️ [ARCHITECTURE.md](docs/ARCHITECTURE.md)
- **阅读真机实测与避坑报告** ➡️ [真机vs模拟器差异报告.md](docs/真机vs模拟器差异报告.md)

---

## 🛠️ 已验证环境

- **真机设备**：HUAWEI Pura 70 Pro+ (HBN-AL80)
- **操作系统**：HarmonyOS NEXT 7.0.0.109 / HongMeng Kernel 1.13.0
- **开发工具**：DevEco Studio 26.0.0 Release (API 26)
- **连通指标**：文件总线单次往返延迟约 50~180ms，冷启动自愈连通延迟 < 1ms。

---

## 开源许可

本项目采用 Apache-2.0 License 授权，详见 [LICENSE](LICENSE)。
