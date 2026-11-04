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
- **免 Root 特权桥梁**：运行于 UID 2000 (`shell`) 权限，可执行应用启动/冻结、屏幕/电源控制、触控模拟 (`uinput`/`uitest`) 等 290+ 项系统级指令。
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

进入 `arkui_app` 目录：

- **模拟器调试**（免签名直接安装）：
  ```bash
  cd arkui_app
  export DEVECO_SDK_HOME="/Applications/DevEco-Studio.app/Contents/sdk" # Mac 路径，按实际配置
  /Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw --mode module -p product=default assembleHap --no-daemon
  hdc install -r entry/build/default/outputs/default/entry-default-unsigned.hap
  ```
- **真机安装**：
  在 DevEco Studio 中打开 `arkui_app` 目录，进入 `File -> Project Structure -> Signing Configs` 勾选 **Automatically generate signature**（自动签名），然后点击 Run 或使用命令行打包安装签名的 `entry-default-signed.hap`：
  ```bash
  hdc install -r entry/build/default/outputs/default/entry-default-signed.hap
  ```

### 3. 打开 App 享受特权

在手机上打开 **HMArkPriv**：
1. 首次打开点击首页提示的「授权」按钮，选择系统的 `Download/HMArkPriv` 文件夹（一次授权，永久免重新选择）。
2. 顶部状态指示灯变绿，显示 `Daemon 在线 (UID:2000)`。
3. 切换到底部「终端」Tab，即刻看到 `已连接 daemon (PID: xxx)`，开始输入指令体验！

---

## 📦 应用分发方案指南

很多开发者关心：**“为什么 DevEco 自动生成的签名别人无法直接安装？如何分发给其他用户？”**

### 为什么无法直接将当前的 Signed HAP 发给别人？
DevEco Studio 的“自动签名”（Auto-generated Debug Signature）会在华为开发者中心自动为当前电脑和当前设备生成一个**调试证书（Debug Profile）**。该 Profile 的核心特征是**强绑定当前设备的 UDID**（例如测试机的 `33Z0224430072393`）。若其他用户尝试安装此 HAP，系统包管理器会报 `9568289: The profile does not match the device's UDID`。

由于 HMArkPriv 本身就需要通过电脑 `hdc` 部署一次后台 `daemon.sh`，分发通常有以下最佳实践：

| 分发方式 | 适合场景 | 操作流程 | 优缺点 |
|---------|----------|----------|--------|
| **1. 源码 + DevEco Studio 导入（开源主流）** | 极客玩家、开源社区贡献者 | 用户 clone 仓库后，在自己的 DevEco Studio 打开，插上手机勾选自己的“自动签名”，一键点击 Run | **最推荐**。完全免费，无需收集 UDID，自动适配任意设备 |
| **2. AGC 内部测试分发 (Internal Testing)** | 朋友内测、小范围种子用户（≤100人） | 开发者在 AGC 控制台添加测试用户的华为账号或 UDID，生成包含该批设备的 Release/Debug Profile 打包 HAP 分发 | 官方机制，用户可以通过 AGC 测试邀请直接安装，但有名额限制（最多100台测试设备） |
| **3. 一键 HDC 部署脚本包 (One-Click Installer)** | 电脑辅助一键安装 | 将 daemon 部署与自编译 HAP 整合进脚本：`deploy.sh`。若采用此方式，若用户有证书则脚本自动签，若无则指导用户一键签名 | 流程标准化，一条命令同时搞定 `daemon.sh` 注入与 HAP 安装 |
| **4. 华为企业级证书 (Enterprise Certificate)** | 商业化团队、无限制免审安装 | 企业开发者账号申请企业私有证书，Wildcard 签名 HAP | 不限制 UDID，任意设备均可安装，但需要企业资质年审 |

---

## 🔌 跨应用特权调用 (OpenAPI)

HMArkPriv 提供了一套类似 Shizuku 的跨应用调用方案，允许第三方 App 轻松获得特权 shell 权限：

- **「弹窗授权模式」 (Want IPC)**：通过 `startAbilityForResult` 向 HMArkPriv 发送执行请求，HMArkPriv 弹出系统确认卡片，经用户许可后返回执行结果。
- **「极速总线模式」 (Queue IPC)**：通过共享目录多槽位请求通道 (`slot1.req` ~ `slot4.req`) 通信。第三方应用先向 HMArkPriv 申请独立 Token，随后即可在后台以毫秒级时延执行特权命令，支持主开关熔断与审计追踪。

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
