# HMArkPriv 鸿蒙原生 App 技术方案文档

> **项目目标**：将现有基于 HTML 控制台 + Shell 脚本的 HMArkPriv 工具，升级为 HarmonyOS NEXT 原生 App，提供流畅的 UI 交互体验和丰富的功能面板。

---

## 一、架构设计

### 1.1 现有架构回顾

```
[PC] install_and_start.sh ──hdc──→ [手机] daemon.sh (UID 2000)
                                         │
                                    轮询 cmd.req 文件
                                         │
                                    执行 shell 命令
                                         │
                                    写入 cmd.res 文件
                                         ↑
              [手机] HTML Console / hmpriv_cli.sh (写入 cmd.req)
```

**痛点**：
- HTML 控制台依赖浏览器 File System Access API，操作不流畅
- 无持久化 UI 状态，每次需重新授权目录
- 功能分散在 HTML 标签里，扩展不便
- daemon 需电脑端 hdc 部署

### 1.2 新架构：原生 App + 文件总线

```
[手机] HMArkPriv App (ArkUI, 沙箱 UID)
  │
  ├── 用户交互层 (ArkUI 页面)
  │     ├── 快捷操作面板
  │     ├── 终端控制台
  │     ├── 应用管理
  │     ├── 触控模拟
  │     └── 系统信息
  │
  ├── 业务逻辑层 (ArkTS Service)
  │     ├── CommandBuilder  ── 构造 shell 命令字符串
  │     ├── BusClient        ── 文件总线 IPC 读写
  │     ├── ResponseParser   ── 解析命令输出
  │     └── DaemonManager    ── daemon 状态检测
  │
  └── 文件 I/O 层
        ├── 读 status.json   ── 检测 daemon 存活
        ├── 写 cmd.req        ── 发送命令
        └── 读 cmd.res        ── 轮询读取结果
              │
        [手机] daemon.sh (UID 2000, 由 hdc 部署)
              │
        执行鸿蒙系统 shell 命令
```

### 1.3 核心约束

| 约束 | 说明 | 应对策略 |
|------|------|----------|
| **App 无法执行 shell** | 鸿蒙沙箱不允许普通 App spawn shell 进程 | 保持 daemon 架构，App 只做文件总线客户端 |
| **文件权限** | App 沙箱 UID 与 daemon UID 2000 不同 | 使用公共目录 `Download/HMArkPriv/` 作为总线 |
| **daemon 需预部署** | 仍需 hdc 初始部署 daemon.sh | App 内提供部署引导页 + 一键复制安装命令 |
| **daemon 可能被杀** | 长后台进程可能被系统回收 | App 检测到 daemon 失联时提示重新部署 |
| **文件总线延迟** | 轮询间隔 50ms | App 端轮询同样 50ms 间隔，体感即时 |

---

## 二、IPC 通信方案

### 2.1 文件总线协议（沿用现有）

**总线目录**：`/storage/media/100/local/files/Docs/Download/HMArkPriv/`

| 文件 | 方向 | 格式 | 说明 |
|------|------|------|------|
| `status.json` | daemon → App | `{"framework":"HMArkPriv","status":"ready","pid":1234,"uid":2000}` | daemon 心跳 |
| `cmd.req` | App → daemon | `req_1700000000_1234\|power-shell wakeup\n` | 请求行：ID\|命令 |
| `cmd.res` | daemon → App | `ID:req_1700000000_1234 RC:0 TIME:2025-01-01 12:00:00\n<output...>` | 响应：首行头 + 输出 |

### 2.2 App 端 IPC 客户端设计

```typescript
// services/BusClient.ets

interface BusConfig {
  busDir: string;          // 总线目录路径
  pollIntervalMs: number;  // 轮询间隔，默认 50ms
  timeoutMs: number;       // 超时时间，默认 5000ms
}

interface CommandResult {
  success: boolean;
  exitCode: number;
  output: string;
  timestamp: string;
  durationMs: number;
}

class BusClient {
  private config: BusConfig;
  private connected: boolean = false;

  // 检测 daemon 是否存活
  async checkDaemonStatus(): Promise<boolean> {
    // 读取 status.json，检查 status 字段
    // 可选：发送 test 命令验证响应
  }

  // 执行命令
  async execute(command: string): Promise<CommandResult> {
    // 1. 生成唯一 req_id: `req_${Date.now()}_${random}`
    // 2. 写入 cmd.req: `${reqId}|${command}\n`
    // 3. 轮询读 cmd.res，匹配首行 ID
    // 4. 解析 RC 和输出内容
    // 5. 超时则返回错误
  }

  // 断开连接
  disconnect() {
    // 停止轮询
  }
}
```

### 2.3 鸿蒙文件 I/O API

鸿蒙提供 `@ohos.file.fs` 模块用于文件读写：

```typescript
import fs from '@ohos.file.fs';

// 写入 cmd.req
function writeRequest(busDir: string, reqId: string, command: string): void {
  const reqPath = `${busDir}/cmd.req`;
  const content = `${reqId}|${command}\n`;
  const file = fs.openSync(reqPath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE);
  fs.writeSync(file.fd, content);
  fs.closeSync(file);
}

// 读取 cmd.res
function readResponse(busDir: string): string {
  const resPath = `${busDir}/cmd.res`;
  const file = fs.openSync(resPath, fs.OpenMode.READ_ONLY);
  const stat = fs.statSync(resPath);
  const buf = new ArrayBuffer(stat.size);
  fs.readSync(file.fd, buf);
  fs.closeSync(file);
  return new TextDecoder('utf-8').decode(new Uint8Array(buf));
}
```

**关键权限**：
- `ohos.permission.READ_MEDIA` / `ohos.permission.WRITE_MEDIA` — 访问 Download 目录
- 或使用 `@ohos.file.picker` 让用户主动授权目录访问

### 2.4 延迟分析

| 环节 | 延迟 |
|------|------|
| App 写 cmd.req | ~1ms (本地文件写) |
| daemon 轮询发现 | 0-50ms (平均 25ms) |
| daemon 执行命令 | 取决于命令本身 |
| daemon 写 cmd.res | ~1ms |
| App 轮询发现 | 0-50ms (平均 25ms) |
| **总通信开销** | **~50ms 平均，与现有 HTML 方案一致** |

---

## 三、页面结构与导航

### 3.1 页面树

```
Tabs (底部导航栏)
├── Tab 1: 首页 (快捷操作)
│   ├── Daemon 状态卡片（连接状态 / UID / PID）
│   ├── 屏幕控制区
│   │   ├── 唤醒 / 熄屏 按钮
│   │   ├── 常亮时长滑块（5分钟 / 30分钟 / 1小时 / 自定义）
│   │   └── 截图按钮（截图后显示预览）
│   ├── 按键模拟区
│   │   ├── Home / Back / 电源键
│   │   └── 音量 + / 音量 -
│   ├── 电源模式
│   │   └── 正常 / 省电 / 超级省电
│   └── 卓易通穿透
│       ├── 打开通知使用权
│       ├── 打开无障碍设置
│       └── 打开特殊应用权限
│
├── Tab 2: 触控模拟
│   ├── 坐标输入区（X / Y 输入框 + 执行按钮）
│   ├── 滑动手势区（起点X/Y → 终点X/Y → 时长 → 执行）
│   ├── 可视化触摸板（Canvas 组件，手指拖动自动生成滑动命令）
│   └── 历史操作记录列表
│
├── Tab 3: 应用管理
│   ├── 已装应用列表（执行 bm dump -a，解析后展示）
│   │   └── 搜索框 + 列表项（图标/包名/操作按钮）
│   ├── 应用操作菜单
│   │   ├── 启动 (aa start)
│   │   ├── 强制停止 (aa force-stop)
│   │   ├── 清理缓存 (bm clean -c)
│   │   └── 清理数据 (bm clean -d)
│   └── 当前前台应用（aa dump -l 解析）
│
├── Tab 4: 系统信息
│   ├── 电池状态卡片（hidumper -s BatteryService 解析）
│   │   └── 电量 / 充电状态 / 温度 / 电压
│   ├── 个人热点状态
│   ├── 系统参数（param get 关键字段）
│   │   └── 设备型号 / 系统版本 / 内核版本
│   ├── 窗口管理信息
│   └── 内存与 CPU 统计
│
└── Tab 5: 终端
    ├── 终端输出区（滚动文本，等宽字体）
    ├── 命令输入框（带历史记录，上/下箭头切换）
    ├── 快捷命令栏（常用命令 chip 列表）
    ├── Ctrl+C / 清屏 按钮
    └── 命令历史侧边面板
```

### 3.2 全局状态管理

```typescript
// stores/AppState.ets

@Entry
@Component
struct AppState {
  // 连接状态
  @StorageLink('isConnected') isConnected: boolean = false;
  @StorageLink('daemonInfo') daemonInfo: DaemonInfo | null = null;

  // 总线配置
  @StorageLink('busDir') busDir: string =
    '/storage/media/100/local/files/Docs/Download/HMArkPriv';

  // 命令历史
  @StorageLink('cmdHistory') cmdHistory: string[] = [];

  // BusClient 实例（单例）
  private busClient: BusClient | null = null;
}
```

---

## 四、核心模块设计

### 4.1 CommandBuilder — 命令构造器

将 UI 操作映射为 shell 命令字符串，集中管理所有命令模板：

```typescript
// utils/CommandBuilder.ets

export class CommandBuilder {
  // 屏幕控制
  static wakeup(): string { return 'power-shell wakeup'; }
  static suspend(): string { return 'power-shell suspend'; }
  static setScreenTimeout(ms: number): string {
    return `power-shell timeout -o ${ms}`;
  }
  static resetScreenTimeout(): string { return 'power-shell timeout -r'; }
  static screenshot(path: string): string {
    return `snapshot_display -f ${path}`;
  }
  static setPowerMode(mode: number): string {
    return `power-shell setmode ${mode}`;
  }

  // 按键模拟
  static keyPress(keycode: number): string {
    return `uinput -K -d ${keycode} -u ${keycode}`;
  }
  static tap(x: number, y: number): string {
    return `uinput -T -c ${x} ${y}`;
  }
  static swipe(x1: number, y1: number, x2: number, y2: number, durationMs?: number): string {
    return durationMs
      ? `uinput -T -m ${x1} ${y1} ${x2} ${y2} ${durationMs}`
      : `uinput -T -m ${x1} ${y1} ${x2} ${y2}`;
  }

  // 应用管理
  static listApps(): string { return 'bm dump -a'; }
  static startApp(bundle: string, ability: string): string {
    return `aa start -b ${bundle} -a ${ability}`;
  }
  static forceStopApp(bundle: string): string {
    return `aa force-stop ${bundle}`;
  }
  static cleanCache(bundle: string): string {
    return `bm clean -c -n ${bundle}`;
  }
  static cleanData(bundle: string): string {
    return `bm clean -d -n ${bundle}`;
  }
  static dumpTasks(): string { return 'aa dump -l'; }

  // 系统信息
  static batteryInfo(): string { return 'hidumper -s BatteryService'; }
  static hotspotInfo(): string { return 'hidumper -s WifiHotspot'; }
  static systemParams(): string {
    return `param get | grep -E 'os|model|brand|version'`;
  }
  static windowInfo(): string { return 'hidumper -s WindowManagerService'; }

  // 卓易通穿透
  static openNotificationAccess(): string {
    return `aa start -b com.android.settings -a com.android.settings.Settings\\$NotificationAccessSettingsActivity`;
  }
  static openAccessibility(): string {
    return `aa start -b com.android.settings -a com.android.settings.Settings\\$AccessibilitySettingsActivity`;
  }

  // 通用
  static raw(command: string): string { return command; }
}
```

### 4.2 ResponseParser — 输出解析器

将 shell 命令的文本输出解析为结构化数据：

```typescript
// utils/ResponseParser.ets

export interface AppInfo {
  bundleName: string;
  abilityName?: string;
  installedPath?: string;
}

export interface BatteryInfo {
  level: number;        // 电量百分比
  charging: boolean;
  temperature: number;  // 温度 (°C)
  voltage: number;      // 电压 (V)
}

export class ResponseParser {
  // 解析 bm dump -a 输出，提取应用列表
  static parseAppList(raw: string): AppInfo[] {
    const apps: AppInfo[] = [];
    const lines = raw.split('\n');
    for (const line of lines) {
      // 匹配 bundleName 行
      const match = line.match(/bundleName[:\s]+([\w.]+)/);
      if (match) {
        apps.push({ bundleName: match[1] });
      }
    }
    return apps;
  }

  // 解析 hidumper -s BatteryService 输出
  static parseBattery(raw: string): BatteryInfo {
    const levelMatch = raw.match(/capacity[:\s]+(\d+)/i);
    const chargingMatch = raw.match(/chargeState[:\s]+(\w+)/i);
    const tempMatch = raw.match(/temperature[:\s]+(\d+)/i);
    const voltageMatch = raw.match(/voltage[:\s]+(\d+)/i);

    return {
      level: levelMatch ? parseInt(levelMatch[1]) : -1,
      charging: chargingMatch ? chargingMatch[1].toLowerCase().includes('charge') : false,
      temperature: tempMatch ? parseInt(tempMatch[1]) / 10 : -1,
      voltage: voltageMatch ? parseInt(voltageMatch[1]) / 1000 : -1,
    };
  }

  // 解析 aa dump -l 输出，获取前台应用
  static parseForegroundApp(raw: string): string | null {
    const match = raw.match(/bundleName[:\s]+([\w.]+)/);
    return match ? match[1] : null;
  }

  // 解析 param get 输出
  static parseSystemParams(raw: string): Map<string, string> {
    const params = new Map<string, string>();
    const lines = raw.split('\n');
    for (const line of lines) {
      const parts = line.split(/\s*=\s*/);
      if (parts.length === 2) {
        params.set(parts[0].trim(), parts[1].trim());
      }
    }
    return params;
  }
}
```

### 4.3 BusClient — 文件总线客户端

```typescript
// services/BusClient.ets

import fs from '@ohos.file.fs';

export interface CommandResult {
  success: boolean;
  exitCode: number;
  output: string;
  timestamp: string;
  durationMs: number;
}

const DEFAULT_BUS_DIR = '/storage/media/100/local/files/Docs/Download/HMArkPriv';
const POLL_INTERVAL = 50;   // ms
const TIMEOUT = 5000;       // ms

export class BusClient {
  private busDir: string;
  private reqCounter: number = 0;

  constructor(busDir: string = DEFAULT_BUS_DIR) {
    this.busDir = busDir;
  }

  /**
   * 检测 daemon 是否存活
   */
  async checkDaemonStatus(): Promise<boolean> {
    try {
      const statusPath = `${this.busDir}/status.json`;
      const file = fs.openSync(statusPath, fs.OpenMode.READ_ONLY);
      const stat = fs.statSync(statusPath);
      const buf = new ArrayBuffer(stat.size);
      fs.readSync(file.fd, buf);
      fs.closeSync(file);
      const text = new TextDecoder('utf-8').decode(new Uint8Array(buf));
      const json = JSON.parse(text);
      return json.status === 'ready';
    } catch (e) {
      return false;
    }
  }

  /**
   * 执行 shell 命令
   */
  async execute(command: string): Promise<CommandResult> {
    const startTime = Date.now();
    const reqId = `req_${Date.now()}_${this.reqCounter++}`;

    // 写入请求
    const reqPath = `${this.busDir}/cmd.req`;
    const reqContent = `${reqId}|${command}\n`;
    try {
      const reqFile = fs.openSync(reqPath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE);
      fs.writeSync(reqFile.fd, reqContent);
      fs.closeSync(reqFile);
    } catch (e) {
      return {
        success: false,
        exitCode: -1,
        output: `[错误] 写入 cmd.req 失败: ${e}`,
        timestamp: '',
        durationMs: 0,
      };
    }

    // 轮询读取响应
    const resPath = `${this.busDir}/cmd.res`;
    const maxAttempts = TIMEOUT / POLL_INTERVAL;

    for (let i = 0; i < maxAttempts; i++) {
      await this.sleep(POLL_INTERVAL);
      try {
        const resFile = fs.openSync(resPath, fs.OpenMode.READ_ONLY);
        const stat = fs.statSync(resPath);
        const buf = new ArrayBuffer(stat.size);
        fs.readSync(resFile.fd, buf);
        fs.closeSync(resFile);
        const text = new TextDecoder('utf-8').decode(new Uint8Array(buf));
        const lines = text.split('\n');
        const firstLine = lines[0];

        if (firstLine && firstLine.startsWith(`ID:${reqId} `)) {
          const rcMatch = firstLine.match(/RC:(-?\d+)/);
          const timeMatch = firstLine.match(/TIME:(.+)$/);
          const output = lines.slice(1).join('\n').trim();
          return {
            success: parseInt(rcMatch?.[1] ?? '-1') === 0,
            exitCode: parseInt(rcMatch?.[1] ?? '-1'),
            output,
            timestamp: timeMatch?.[1]?.trim() ?? '',
            durationMs: Date.now() - startTime,
          };
        }
      } catch (e) {
        // 文件可能暂时不存在，继续重试
      }
    }

    return {
      success: false,
      exitCode: -1,
      output: '[错误] 响应超时，daemon 可能未运行',
      timestamp: '',
      durationMs: Date.now() - startTime,
    };
  }

  private sleep(ms: number): Promise<void> {
    return new Promise(resolve => setTimeout(resolve, ms));
  }
}
```

### 4.4 终端控制台组件

```typescript
// components/TerminalConsole.ets

@Component
export struct TerminalConsole {
  @State output: string = '终端就绪，等待连接...\n';
  @State inputCmd: string = '';
  @State isExecuting: boolean = false;
  @State historyIndex: number = -1;
  @Link history: string[];
  private busClient: BusClient;

  build() {
    Column() {
      // 输出区域
      Scroll() {
        Text(this.output)
          .fontFamily('JetBrains Mono, Consolas, monospace')
          .fontSize(13)
          .fontColor('#c3e88d')
          .textAlign(TextAlign.Start)
          .padding(12)
      }
      .backgroundColor('#0d1527')
      .borderRadius(8)
      .layoutWeight(1)
      .width('100%')

      // 快捷命令栏
      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(this.quickCommands, (cmd: string) => {
          Text(cmd)
            .fontSize(12)
            .fontColor('#82b1ff')
            .backgroundColor('#1e293b')
            .borderRadius(8)
            .padding({ left: 8, right: 8, top: 4, bottom: 4 })
            .margin({ right: 4, bottom: 4 })
            .onClick(() => {
              this.inputCmd = cmd;
              this.runCommand();
            })
        })
      }
      .width('100%')
      .padding(8)

      // 输入行
      Row() {
        TextInput({ text: this.inputCmd, placeholder: '输入 Shell 指令...' })
          .layoutWeight(1)
          .fontFamily('JetBrains Mono, Consolas, monospace')
          .fontSize(13)
          .backgroundColor('#0f172a')
          .fontColor('#38bdf8')
          .onKeySubmit(() => this.runCommand())
          .onChange((val: string) => {
            this.inputCmd = val;
          })

        Button(this.isExecuting ? '...' : '执行')
          .backgroundColor('#38bdf8')
          .fontColor('#090d16')
          .enabled(!this.isExecuting)
          .onClick(() => this.runCommand())
      }
      .width('100%')
    }
    .width('100%')
    .height('100%')
  }

  private quickCommands: string[] = [
    'id', 'aa dump -l', 'bm dump -a',
    'power-shell wakeup', 'power-shell suspend',
    'hidumper -s BatteryService', 'param get',
  ];

  private async runCommand(): Promise<void> {
    if (!this.inputCmd || this.isExecuting) return;
    const cmd = this.inputCmd.trim();
    this.history.push(cmd);
    this.historyIndex = this.history.length;
    this.isExecuting = true;
    this.output += `\n$ ${cmd}\n`;

    const result = await this.busClient.execute(cmd);
    this.output += result.output + '\n';
    this.isExecuting = false;
    this.inputCmd = '';
  }
}
```

---

## 五、权限声明

### 5.1 module.json5 权限配置

```json
{
  "module": {
    "name": "entry",
    "type": "entry",
    "requestPermissions": [
      {
        "name": "ohos.permission.READ_MEDIA",
        "reason": "$string:perm_media_reason",
        "usedScene": {
          "abilities": ["MainAbility"],
          "when": "always"
        }
      },
      {
        "name": "ohos.permission.WRITE_MEDIA",
        "reason": "$string:perm_media_reason",
        "usedScene": {
          "abilities": ["MainAbility"],
          "when": "always"
        }
      }
    ]
  }
}
```

### 5.2 权限说明

| 权限 | 用途 | 等级 |
|------|------|------|
| `READ_MEDIA` | 读取 Download/HMArkPriv 下的 cmd.res / status.json | normal |
| `WRITE_MEDIA` | 写入 cmd.req 到 Download/HMArkPriv | normal |

> **注意**：鸿蒙的媒体权限可能不足以直接访问任意路径。如果 `@ohos.file.fs` 无法直接访问 `/storage/media/100/...`，需要改用 `@ohos.file.picker`（目录选择器）让用户授权访问特定目录，或使用 App 的沙箱目录作为总线中转（daemon 端做路径适配）。

### 5.3 备选方案：File Picker 授权

如果直接路径访问受限，使用 `@ohos.file.picker`:

```typescript
import picker from '@ohos.file.picker';

async function selectBusDir(): Promise<string> {
  const options = new picker.FolderPickerOptions();
  options.title = '选择 HMArkPriv 总线目录';
  const pickerObj = new picker.FolderViewPicker();
  const result = await pickerObj.show(options);
  return result[0]; // 返回授权的目录 URI
}
```

授权后通过 `@ohos.file.fs` 的 URI 方式访问文件。

---

## 六、工程结构

```
HMArkPriv/
├── AppScope/
│   └── resources/
│       └── base/
│           └── element/
│               └── string.json          # 全局字符串
├── entry/
│   └── src/
│       └── main/
│           ├── ets/
│           │   ├── entryability/
│           │   │   └── EntryAbility.ets   # 应用入口
│           │   ├── pages/
│           │   │   ├── Index.ets           # 主页面 (Tabs 容器)
│           │   │   ├── Home.ets            # Tab1: 快捷操作
│           │   │   ├── Touch.ets           # Tab2: 触控模拟
│           │   │   ├── Apps.ets            # Tab3: 应用管理
│           │   │   ├── SystemInfo.ets      # Tab4: 系统信息
│           │   │   └── Terminal.ets        # Tab5: 终端
│           │   ├── components/
│           │   │   ├── DaemonStatusCard.ets # daemon 状态卡片
│           │   │   ├── TerminalConsole.ets  # 终端控制台组件
│           │   │   ├── CommandChip.ets      # 快捷命令标签
│           │   │   ├── AppListItem.ets      # 应用列表项
│           │   │   ├── BatteryCard.ets      # 电池信息卡片
│           │   │   ├── TouchPad.ets         # 可视化触摸板
│           │   │   └── SliderControl.ets    # 滑块控制器
│           │   ├── services/
│           │   │   └── BusClient.ets        # 文件总线 IPC 客户端
│           │   ├── utils/
│           │   │   ├── CommandBuilder.ets   # 命令构造器
│           │   │   ├── ResponseParser.ets   # 输出解析器
│           │   │   └── Logger.ets           # 日志工具
│           │   ├── model/
│           │   │   ├── AppInfo.ets          # 应用信息模型
│           │   │   ├── BatteryInfo.ets      # 电池信息模型
│           │   │   └── CommandResult.ets    # 命令结果模型
│           │   └── common/
│           │       └── Constants.ets        # 常量定义
│           ├── resources/
│           │   └── base/
│           │       ├── element/
│           │       │   ├── string.json      # 字符串资源
│           │       │   ├── color.json       # 颜色资源
│           │       │   └── float.json       # 尺寸资源
│           │       └── media/               # 图标资源
│           └── module.json5                 # 模块配置
├── build-profile.json5                      # 构建配置
├── oh-package.json5                         # 依赖配置
└── hvigorfile.ts                            # 构建脚本
```

---

## 七、开发路径与里程碑

### Phase 1: MVP — 跑通文件总线 (预计 2-3 天)

**目标**：App 能连接 daemon，执行命令，显示输出

- [ ] 安装 DevEco Studio
- [ ] 创建 Empty Ability 项目
- [ ] 实现 BusClient（写 cmd.req / 读 cmd.res）
- [ ] 实现终端控制台页面（输入命令 → 执行 → 显示输出）
- [ ] 实现 daemon 状态检测
- [ ] 真机调试：验证文件总线通信正常

**验收标准**：在 App 终端输入 `id`，能看到 `uid=2000(shell)` 输出

### Phase 2: 快捷操作面板 (预计 2-3 天)

- [ ] 首页布局：daemon 状态卡片 + 功能分区
- [ ] 屏幕控制：唤醒 / 熄屏 / 常亮滑块
- [ ] 按键模拟：Home / Back / 音量
- [ ] 截图功能：截图 + 预览
- [ ] 电源模式切换
- [ ] 卓易通穿透快捷入口

### Phase 3: 应用管理 (预计 2-3 天)

- [ ] 执行 `bm dump -a` 并解析应用列表
- [ ] 搜索 + 列表展示
- [ ] 应用操作菜单（启动 / 停止 / 清理）
- [ ] 当前前台应用显示

### Phase 4: 触控模拟 (预计 2 天)

- [ ] 坐标点击（输入 X/Y）
- [ ] 滑动手势参数输入
- [ ] 可视化触摸板（Canvas 拖动 → 自动生成滑动命令）
- [ ] 操作历史记录

### Phase 5: 系统信息 (预计 1-2 天)

- [ ] 电池状态卡片（解析 hidumper）
- [ ] 热点状态
- [ ] 系统参数展示
- [ ] 内存/CPU 信息

### Phase 6: 打磨 (预计 2-3 天)

- [ ] 暗色主题完善
- [ ] 命令历史管理
- [ ] 错误处理与重试
- [ ] daemon 离线引导页（显示部署命令）
- [ ] 设置页面（总线目录配置等）

---

## 八、风险与应对

| 风险 | 影响 | 应对 |
|------|------|------|
| **文件路径不可访问** | App 无法读写总线文件 | 用 File Picker 授权目录；或让 daemon 写到 App 沙箱可访问的路径 |
| **daemon 被系统杀死** | 功能不可用 | App 检测到失联时显示引导页，提示用 hdc 重启 daemon |
| **权限被拒** | 无法读写文件 | 引导用户在设置中手动授予媒体权限 |
| **命令输出格式变化** | 解析失败 | ResponseParser 做容错，解析失败时 fallback 到原始文本展示 |
| **ArkTS 语法限制** | 与 TypeScript 有差异 | 参考 ArkTS 语法规范，注意不支持 `any`、动态类型等 |

---

## 九、Shell 指令速查（App 内置）

### 9.1 屏幕与电源

| 操作 | 命令 |
|------|------|
| 唤醒屏幕 | `power-shell wakeup` |
| 熄屏休眠 | `power-shell suspend` |
| 常亮 N 毫秒 | `power-shell timeout -o <ms>` |
| 恢复默认熄屏 | `power-shell timeout -r` |
| 正常模式 | `power-shell setmode 600` |
| 省电模式 | `power-shell setmode 601` |
| 超级省电 | `power-shell setmode 602` |
| 截屏 | `snapshot_display -f <path>` |

### 9.2 触控与按键

| 操作 | 命令 |
|------|------|
| 点击坐标 | `uinput -T -c <x> <y>` |
| 滑动手势 | `uinput -T -m <x1> <y1> <x2> <y2> [ms]` |
| Home 键 | `uinput -K -d 1 -u 1` |
| Back 键 | `uinput -K -d 2 -u 2` |
| 音量+ | `uinput -K -d 16 -u 16` |
| 音量- | `uinput -K -d 17 -u 17` |
| 电源键 | `uinput -K -d 18 -u 18` |

### 9.3 应用管理

| 操作 | 命令 |
|------|------|
| 已装应用列表 | `bm dump -a` |
| 应用详情 | `bm dump -n <bundle>` |
| 启动应用 | `aa start -b <bundle> -a <ability>` |
| 强制停止 | `aa force-stop <bundle>` |
| 清理缓存 | `bm clean -c -n <bundle>` |
| 清理数据 | `bm clean -d -n <bundle>` |
| 当前任务栈 | `aa dump -l` |

### 9.4 系统信息

| 操作 | 命令 |
|------|------|
| 电池状态 | `hidumper -s BatteryService` |
| 热点状态 | `hidumper -s WifiHotspot` |
| 窗口信息 | `hidumper -s WindowManagerService` |
| 系统参数 | `param get` |
| CPU 频率 | `hidumper --cpufreq` |
| 内存统计 | `hidumper --mem` |

### 9.5 卓易通穿透

| 操作 | 命令 |
|------|------|
| 通知使用权 | `aa start -b com.android.settings -a com.android.settings.Settings$NotificationAccessSettingsActivity` |
| 无障碍设置 | `aa start -b com.android.settings -a com.android.settings.Settings$AccessibilitySettingsActivity` |
| 特殊权限 | `aa start -b com.android.settings -a com.android.settings.Settings$SpecialAccessSettingsActivity` |
| 应用管理 | `aa start -b com.android.settings -a com.android.settings.Settings$ManageApplicationsActivity` |

---

## 十、DevEco Studio 安装指引

### 10.1 下载安装

1. 访问 https://developer.huawei.com/consumer/cn/develop/deveco-studio
2. 下载最新版 DevEco Studio（Windows 版）
3. 安装路径**必须纯英文**，不能有中文和空格（如 `D:\DevEcoStudio`）
4. 安装时勾选"鸿蒙开发套件"

### 10.2 首次配置

1. 启动 DevEco Studio，等待自动下载 HarmonyOS SDK（约 2GB）
2. 选择"全量安装"，包含工具链、模拟器、示例代码
3. Node.js 环境会自动安装

### 10.3 创建项目

1. `File > New > Create Project`
2. 选择 `Empty Ability` 模板
3. 填写：
   - Project Name: `HMArkPriv`
   - Project Location: `D:\0\harmony`
   - Compatible SDK: 选择最新版本（API 15+）
   - Language: ArkTS
4. 点击 Finish，等待初始化

### 10.4 真机调试

1. 手机开启【开发者选项】→【USB调试】
2. USB 连接电脑
3. 在 DevEco Studio 中选择真机设备
4. 点击 Run 按钮

### 10.5 常见问题

| 问题 | 解决方案 |
|------|----------|
| 模拟器启动失败 | 进 BIOS 开启虚拟化（VT-x） |
| SDK 下载慢 | 配置国内镜像源 |
| 真机识别不到 | 检查 USB 驱动，换数据线/USB口 |
| 项目创建失败 | 检查网络，确保 SDK 完整 |

---

_文档版本：v1.0 | 更新日期：2026-11-03
