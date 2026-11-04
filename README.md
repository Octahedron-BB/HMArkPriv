# HMArkPriv

> 鸿蒙（HarmonyOS NEXT）特权 Shell 执行桥梁 —— 让普通 App 获得 UID 2000 的 shell 能力。

鸿蒙的沙箱机制禁止普通 App spawn shell 进程。本项目通过**文件总线 + 外部 daemon** 绕开这一限制：
一个由 `hdc` 部署的 `daemon.sh`（运行在 UID 2000）监听公共目录，App 把命令写成文件投递过去，
daemon 执行后把结果写回，App 读回来展示。

```
┌─────────────────┐   写 cmd.req     ┌──────────────────┐
│  HMArkPriv App  │ ───────────────► │  daemon.sh       │
│  (ArkUI, 沙箱)  │                  │  (UID 2000 shell)│
│                 │ ◄─────────────── │                  │
└─────────────────┘   读 cmd.res     └──────────────────┘
                            ▲
                    公共目录（文件总线）
```

---

## 本项目包含两套方案

| 方案 | 位置 | 形态 | 适用场景 |
|------|------|------|----------|
| **A. ArkUI 原生 App** | [`arkui-app/`](arkui-app/) | HarmonyOS 原生应用（ArkTS + ArkUI） | 日常使用，有完整 UI，终端 + 快捷面板 |
| **B. 脚本 + Web 控制台** | [`core/`](core/) [`client/`](client/) [`console/`](console/) | Shell 脚本 + HTML 页面 | 快速上手、嵌入式调用、自动化脚本 |

两套方案**共用同一个 daemon 和同样的文件总线协议**，可以自由组合
（例如用 App 的 UI，同时保留 `hmpriv_cli.sh` 给自动化脚本调用）。

### 我该选哪个？

- **想直接装个 App 用** → 方案 A，见 [`arkui-app/README.md`](arkui-app/README.md)
- **只想在手机上跑几条特权命令** → 方案 B，见 [`docs/shell-solution-README.md`](docs/shell-solution-README.md)
- **要在 MacroDroid / Termux / 自动化工具里调用** → 方案 B 的 `client/hmpriv_cli.sh`

---

## 快速开始（3 步）

### 1. 部署 daemon（两种方案都需要）

```bash
# 手机：用文件管理建目录 Download/HMArkPriv

# 电脑：推送并启动 daemon
hdc file send core/daemon.sh /data/local/tmp/hmpriv/daemon.sh
hdc shell "chmod 755 /data/local/tmp/hmpriv/daemon.sh"
hdc shell "sh /data/local/tmp/hmpriv/daemon.sh &"

# 验证
hdc shell "cat /storage/media/100/local/files/Docs/Download/HMArkPriv/status.json"
# 期望：{"framework":"HMArkPriv","status":"ready","pid":1234,"uid":2000}
```

> ⚠️ `daemon.sh` 必须是 **LF 换行**。Windows 上 checkout 的是 CRLF，推送前先
> `tr -d '\r' < core/daemon.sh > daemon_lf.sh`，否则报 `syntax error: unmatched 'if'`。

### 2. 选用一套客户端

**方案 A — 装 App**（模拟器免签名，真机需签名）：

```bash
cd arkui-app && ./build.sh          # 产出 entry-default-unsigned.hap
hdc install -r entry/build/default/outputs/default/entry-default-unsigned.hap
hdc shell "aa start -b com.octahedron.hmpriv -a EntryAbility"
```

打开 App 即自动连通（无需选目录、无需额外授权），终端里输入 `id` 应返回 `uid=2000(shell)`。

**方案 B — 命令行客户端**：

```bash
hdc shell "sh /data/local/tmp/hmpriv/hmpriv_cli.sh id"
# 或把 client/hmpriv_cli.sh 推到手机，在 MT 管理器 / Termux 里调用
```

### 3. 验证

```bash
id      # uid=2000(shell) gid=2000(shell) groups=...,1006(file_manager)...
```

---

## 文件总线协议

目录：`Download/HMArkPriv/`（App 视角：`/storage/Users/currentUser/Download/HMArkPriv`）

| 文件 | 方向 | 格式 |
|------|------|------|
| `cmd.req` | 客户端 → daemon | `reqId\|command\n` |
| `cmd.res` | daemon → 客户端 | `ID:reqId RC:code TIME:timestamp\n<output>` |
| `status.json` | daemon → 客户端 | `{"framework":"HMArkPriv","status":"ready","pid":N,"uid":2000}` |

> **关键**：App 和 daemon 看到的是**同一批文件的两个挂载视图**。
> App 用 `/storage/Users/currentUser/...`（沙箱虚拟路径，无需授权），
> daemon 用 `/storage/media/100/local/files/Docs/Download/...`（真实路径）。
> 详见 [`arkui-app/README.md`](arkui-app/README.md) 的架构章节。

轮询间隔 50 ms，超时 5 s（daemon 内部对单条命令加 `timeout 30` 兜底，防止流式命令拖死总线）。

---

## 文档索引

| 文档 | 内容 |
|------|------|
| [`arkui-app/README.md`](arkui-app/README.md) | ArkUI App 完整说明：架构、编译、模拟器调试、踩坑记录 |
| [`arkui-app/docs/HMArkPriv-App-技术方案.md`](arkui-app/docs/HMArkPriv-App-技术方案.md) | App 技术设计（IPC、页面、6 阶段开发路径） |
| [`docs/Shell指令验证报告.md`](docs/Shell指令验证报告.md) | **Shell 指令实测报告**：逐条 RC + 输出，含输出捕获能力三分类 |
| [`docs/HarmonyOS-Shell-指令全集.md`](docs/HarmonyOS-Shell-指令全集.md) | Shell 指令手册（`[官方]`/`[社区]`/`[实机]`/`[未验证]` 四级来源标注） |
| [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) | 鸿蒙 7.0 安全机制逆向分析 |
| [`docs/DEVLOG.md`](docs/DEVLOG.md) | 5 阶段研发日志（真机 Pura 70 Pro+） |
| [`docs/shell-solution-README.md`](docs/shell-solution-README.md) | 方案 B（脚本 + Web 控制台）详细说明 |

---

## 目录结构

```
HMArkPriv/
├── core/
│   └── daemon.sh              # 特权 shell 服务端（UID 2000）
├── client/
│   ├── hmpriv_cli.sh          # 命令行客户端
│   └── hmshell                # 交互式终端机
├── console/
│   └── HMArkPriv_Console.html # Web 控制台
├── app/
│   └── HMArkPriv_Terminal.apk # 卓易通容器内的独立 APK
├── install_and_start.sh        # hdc 一键部署脚本
├── arkui-app/                  # HarmonyOS 原生 App（方案 A）
│   ├── entry/                  # 主模块（ArkTS 源码）
│   ├── AppScope/
│   ├── build.sh                # 命令行构建脚本
│   └── README.md               # App 详细说明
├── docs/                       # 文档
└── LICENSE
```

---

## 已验证环境

| 项目 | 版本 |
|------|------|
| 目标系统 | HarmonyOS NEXT 7.0.0.107 |
| API Level | 26 |
| 模拟器 | Mate 70 Pro+（x86_64） |
| 开发工具 | DevEco Studio 26.0.0 Release |
| 真机参考 | Pura 70 Pro+ (HBN-AL80) |

**Phase 1 验收已通过**：App 内 `id` → `uid=2000(shell)`，往返 172 ms；
`hidumper -s BatteryService` → 真实电池信息，392 ms（模拟器实测）。

---

## 开源许可

见 [LICENSE](LICENSE)。
