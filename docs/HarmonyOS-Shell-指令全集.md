# HarmonyOS NEXT Shell 指令全集

> **适用系统**：HarmonyOS NEXT / 5.0+ / 7.0（HongMeng 微内核）
> **执行权限**：UID 2000 (`shell`)，免 Root
> **文档版本**：v2.1 | 更新日期：2026-11-03
> **测试机型**：HUAWEI Pura 70 Pro+（HBN-AL80, HarmonyOS 7.0.0.109, HongMeng Kernel 1.13.0）

---

## 验证来源标注体系

本文档中每条命令均标注验证等级，便于判断可信度：

| 标注 | 含义 | 来源 |
|------|------|------|
| **[官方]** | 华为官方文档有记载 | developer.huawei.com / device.harmonyos.com 官方文档 |
| **[社区]** | 社区整理，非官方文档但有出处 | awesome-hdc GitHub 项目、CSDN、SegmentFault 等 |
| **[实机]** | HMArkPriv 项目在真机上验证通过 | HMAWEI Pura 70 Pro+ 实机测试 |
| **[未验证]** | 未经外部来源验证，可能不准确或因系统版本差异而不同 | 仅来自 HMArkPriv 原始文档或推测 |

> **重要提示**：标注 **[未验证]** 的命令在实际使用中可能失败、参数可能不正确、或因 HarmonyOS 版本不同而有差异。使用前请自行在目标设备上测试验证。

---

## 重要说明：HarmonyOS 7.0 内核安全限制

以下限制已在 HUAWEI Pura 70 Pro+（HarmonyOS 7.0.0.109）上实机验证 **[实机]**：

1. **XPM 执行白名单**：`u:r:sh:s0` SELinux 域仅允许 `execve()` 位于 `/system/bin/` 下具有华为官方签名的约 185 个系统二进制文件。推送到 `/data/local/tmp/` 的自定义 ELF 二进制即使 `chmod 755` 也会返回 `Permission denied`。
2. **禁止 TCP listen**：`u:r:sh:s0` 禁止 `listen()` 绑定本地 TCP 端口（`EACCES, errno=13`）。
3. **禁止 mkfifo**：`u:r:sh:s0` 禁止创建命名管道（`fifo_file`）。
4. **Toybox 裁剪**：HarmonyOS 7.0 的 toybox 裁剪了 `awk` 和 `tr`，需用 `sed` / `cut` 替代。
5. **mksh 管道符转义**：`/bin/sh` 基于 mksh，参数展开 `${VAR%%pattern}` 中的 `|` 需转义为 `\|`。
6. **hidumper 后台 FD 传递限制**：在后台守护进程中通过 `$(hidumper ...)` 或重定向调用时，可能遭遇 Binder FD 传递拦截（`error:29201`）。交互式 hdc shell 中直接执行则正常。
7. **跨沙盒文件 IPC**：`hdc file send` 运行在 `u:r:hdcd:s0` 域下，可创建 `Download/` 下的目录和文件；`u:r:sh:s0` 隶属 `1006(file_manager)` 组，对这些预分配文件拥有读写权限。

---

## 目录

1. [Shell 环境概述](#1-shell-环境概述)
2. [应用与任务管理（aa / bm）](#2-应用与任务管理aa--bm)
3. [屏幕与电源管理（power-shell / snapshot_display）](#3-屏幕与电源管理power-shell--snapshot_display)
4. [触控模拟与硬件输入（uinput / uitest）](#4-触控模拟与硬件输入uinput--uitest)
5. [系统状态与硬件探针（hidumper）](#5-系统状态与硬件探针hidumper)
6. [系统参数与服务控制（param / service_control）](#6-系统参数与服务控制param--service_control)
7. [日志与性能跟踪（hilog / hisysevent / bytrace / SP_daemon）](#7-日志与性能跟踪hilog--hisysevent--bytrace--sp_daemon)
8. [UI 测试与页面分析（uitest）](#8-ui-测试与页面分析uitest)
9. [文件系统与进程管理（Linux / Toybox）](#9-文件系统与进程管理linux--toybox)
10. [网络诊断与端口转发](#10-网络诊断与端口转发)
11. [卓易通（ANCO）安卓沙盒穿透实战](#11-卓易通anco安卓沙盒穿透实战)
12. [HDC 工具命令（电脑端）](#12-hdc-工具命令电脑端)
13. [常用 KeyCode 对照表](#13-常用-keycode-对照表)
14. [常用系统参数速查](#14-常用系统参数速查)

---

## 1. Shell 环境概述

### 1.1 基本信息 **[实机]**

| 项目 | 说明 |
|------|------|
| 执行权限 | UID 2000 (`shell`)，拥有大部分系统管理能力（免 Root） |
| 完整凭证 | `uid=2000(shell) gid=2000(shell) groups=2000(shell),1006(file_manager),1007(log),1097(netsys_socket),3009(readproc) context=u:r:sh:s0` |
| 二进制路径 | `/bin`, `/system/bin`, `/vendor/bin` |
| 基础工具链 | 鸿蒙内置 `toybox`（已裁剪 `awk`/`tr`） |
| Shell 解释器 | `/bin/sh` 基于 `mksh` |
| 进入方式 | `hdc shell`（交互式）或 `hdc shell "<command>"`（单条执行） |

### 1.2 环境信息命令 **[实机]**

```bash
id                 # 当前用户身份
uname -a           # 内核与系统信息
echo $PATH         # 查看可执行文件搜索路径
whoami             # shell
```

### 1.3 hdc 执行方式 **[官方]**

```bash
# 交互式 shell
hdc shell

# 单条命令执行
hdc shell "bm dump -a"

# 带引号的复杂命令（注意转义）
hdc shell "aa start -b com.android.settings -a com.android.settings.Settings\$NotificationAccessSettingsActivity"
```

---

## 2. 应用与任务管理（aa / bm）

### 2.1 Ability Assistant（aa）**[官方]**

> 来源：https://device.harmonyos.com/cn/docs/apiref/harmonyos-guides/aa-tool

#### 命令总览

| 命令 | 描述 | 验证 |
|------|------|------|
| `aa help` | 帮助 | [官方] |
| `aa start` | 启动应用组件 | [官方] [实机] |
| `aa stop-service` | 停止 Service 组件 | [官方] |
| `aa force-stop` | 强制停止进程 | [官方] [实机] |
| `aa dump` | 打印应用组件信息（已废弃） | [官方] |
| `aa test` | 启动测试框架 | [官方] |
| `aa attach` | 使应用进入调试模式 | [官方] |
| `aa detach` | 使应用退出调试模式 | [官方] |
| `aa appdebug` | 设置/取消/获取等待调试状态 | [官方] |
| `aa process` | 应用调试/调优 | [官方] |
| `aa send-memory-level` | 触发内存级别回调 | [官方] |
| `aa pre-start` | 应用预启动（API 26+） | [官方] |

#### 2.1.1 启动应用（aa start）**[官方]**

**显式启动**（推荐，需要 bundleName + abilityName）：

```bash
aa start -b <bundleName> -a <abilityName> [-m <moduleName>]
```

```bash
# 示例：启动系统设置 [实机]
aa start -b com.huawei.hmos.settings -a com.huawei.hmos.settings.MainAbility

# 示例：启动计算器 [实机]
aa start -b com.huawei.hmos.calculator -a MainAbility

# 示例：带 moduleName [官方]
aa start -b com.example.app -a EntryAbility -m entry
```

**隐式启动**（通过 URI / Action）**[官方]**：

```bash
aa start -U <URI> [-A <action>] [-t <type>] [-e <entity>]
```

```bash
# 打开网页 [官方]
aa start -A ohos.want.action.viewData -U https://www.example.com

# 打开 Scheme [社区]
aa start -U kwai://home

# 带参数启动 [官方]
aa start -U myscheme://www.test.com:8080/path --pi paramNumber 1 --pb paramBoolean true --ps paramString teststring
```

**启动参数完整列表** **[官方]**：

| 参数 | 说明 |
|------|------|
| `-d <deviceId>` | 设备 ID（跨设备启动） |
| `-a <abilityName>` | 组件名称 |
| `-b <bundleName>` | 应用包名 |
| `-m <moduleName>` | 模块名 |
| `-U <URI>` | URI |
| `-A <action>` | Action |
| `-e <entity>` | Entity |
| `-t <type>` | Type |
| `-u <userId>` | 用户 ID |
| `--pi <key> <value>` | 整型参数 |
| `--pb <key> <value>` | 布尔参数 |
| `--ps <key> <value>` | 字符串参数 |
| `--psn <key>` | 空字符串参数 |
| `-D` | 调试模式 |
| `-S` | 进入应用沙箱 |
| `-E` | 显示详细异常信息 |
| `-W` | 测量启动耗时（API 20+） |
| `--wl/--wt/--wh/--ww` | 窗口位置和尺寸（2in1 设备） |

#### 2.1.2 停止应用 **[官方]**

```bash
# 强制停止整个进程 [官方] [实机]
aa force-stop <bundleName>

# 停止 Service 组件 [官方]
aa stop-service -a <abilityName> -b <bundleName> [-m <moduleName>]
```

#### 2.1.3 打印任务信息（aa dump）**[官方]**

> **注意**：`aa dump` 已废弃，推荐使用 `hidumper -s AbilityManagerService` **[官方]**

```bash
# 查看当前所有最近任务与前台页面栈 [实机]
aa dump -l

# 查看系统当前所有运行中的 Ability 进程列表 [实机]
aa dump -r

# 查看所有已注册的能力记录 [官方]
aa dump -a

# 查看指定 Ability 详细信息 [官方]
aa dump -i <abilityRecordId>

# 查看扩展组件信息 [官方]
aa dump -e <elementName>

# 查看应用进程信息 [官方]
aa dump -p
```

#### 2.1.4 调试相关 **[官方]**

```bash
aa attach -b <bundleName>              # 进入调试模式
aa detach -b <bundleName>              # 退出调试模式
aa appdebug -b <bundleName> [-p]       # 设置等待调试（-p 持久化）
aa appdebug -c                         # 取消等待调试
aa appdebug -g                         # 获取等待调试状态
aa process -b <bundleName> -a <abilityName> [-D <debug-cmd>] [-p <perf-cmd>] [-S]  # 调试/调优
```

#### 2.1.5 测试框架 **[官方]**

```bash
aa test -b <bundleName> [-m <moduleName>] -s unittest <testRunner> [options]
```

#### 2.1.6 其他 **[官方]**

```bash
aa send-memory-level -p <pid> -l <memoryLevel>   # 触发内存级别回调
aa pre-start -m 1 -b <bundleName> -u <userId>     # 应用预启动（API 26+）
```

---

### 2.2 Bundle Manager（bm）**[官方]**

> 来源：https://developer.huawei.com/consumer/cn/doc/bm-tool

#### 命令总览

| 命令 | 描述 | 验证 |
|------|------|------|
| `bm help` | 帮助 | [官方] |
| `bm install` | 安装应用 | [官方] [实机] |
| `bm uninstall` | 卸载应用 | [官方] [实机] |
| `bm dump` | 查询应用信息 | [官方] [实机] |
| `bm clean` | 清理缓存/数据 | [官方] [实机] |
| `bm get --udid` | 获取设备 UDID | [官方] [社区] |
| `bm compile` | 编译 AOT | [官方] |
| `bm quickfix` | 快速修复补丁 | [官方] |
| `bm dump-shared` | 查询共享库信息 | [官方] |
| `bm dump-dependencies` | 查询依赖关系 | [官方] |
| `bm dump-overlay` | 查询 Overlay 信息 | [官方] |
| `bm dump-target-overlay` | 查询目标 Overlay 信息 | [官方] |
| `bm copy-ap` | 拷贝 AP 文件 | [官方] |
| `bm install-plugin` | 安装插件 | [官方] |
| `bm uninstall-plugin` | 卸载插件 | [官方] |

#### 2.2.1 查询应用 **[官方]**

```bash
bm dump -a                              # 列出所有已安装应用包名 [实机]
bm dump -a -l                           # 包名 + 应用名称（label）[官方]
bm dump -n <bundleName>                 # 单个应用详情（JSON）[实机]
bm dump -g                              # 调试类型应用 [官方]
bm dump -s -n <bundleName>              # 快捷方式信息 [官方]
bm dump-shared -a                       # 所有共享库 [官方]
bm dump-shared -n <bundleName>          # 指定共享库详情 [官方]
bm dump-dependencies -n <bundleName> -m <moduleName>  # 依赖关系 [官方]
bm dump-overlay -b <bundleName> [-m <moduleName>]     # Overlay 信息 [官方]
bm dump-target-overlay -b <bundleName> [-m <moduleName>]  # 目标 Overlay [官方]
```

#### 2.2.2 安装/卸载 **[官方]**

```bash
bm install -p /data/local/tmp/app.hap           # 安装 [实机]
bm install -p /data/local/tmp/app.hap -r        # 覆盖安装 [官方]
bm install -p /data/local/tmp/app.hap -d        # 降级安装 [官方]
bm install -p /data/local/tmp/app.hap -g        # 自动授权（debug）[官方]
bm install -p /data/local/tmp/app.app           # 安装 APP 包（API 22+）[官方]

bm uninstall -n <bundleName>                     # 卸载 [实机]
bm uninstall -n <bundleName> -k                  # 卸载保留数据 [官方]
bm uninstall -n <bundleName> -m <moduleName>     # 卸载指定模块 [官方]
bm uninstall -n <bundleName> -s [-v <versionCode>]  # 卸载共享库 [官方]
```

#### 2.2.3 清理 **[官方] [实机]**

```bash
bm clean -c -n <bundleName>    # 清理缓存
bm clean -d -n <bundleName>    # 清理用户数据
```

#### 2.2.4 编译 AOT **[官方]**

```bash
bm compile -m partial <bundleName>   # 编译指定应用
bm compile -m full <bundleName>      # 完整编译
bm compile -a -m partial             # 编译所有应用
bm compile -r <bundleName>           # 移除编译结果
```

#### 2.2.5 获取 UDID **[官方] [社区]**

```bash
bm get --udid
```

---

## 3. 屏幕与电源管理（power-shell / snapshot_display）

### 3.1 电源管理（power-shell）

```bash
power-shell wakeup                    # 唤醒设备 [实机]
power-shell suspend                   # 熄灭屏幕 [实机]
power-shell timeout -o 3600000        # 常亮 1 小时 [实机]
power-shell timeout -o 86400000       # 常亮 24 小时 [实机]
power-shell timeout -r                # 恢复默认熄屏 [实机]
power-shell setmode 600               # 正常模式 [实机]
power-shell setmode 601               # 省电模式 [实机]
power-shell setmode 602               # 超级省电模式 [实机]
```

> **[实机验证 2026-11-04]** `power-shell setmode` 在 Pura 70 Pro+ (HBN-AL80 / 7.0.0.109) 上实测**真实生效**。
> 用 hilog 抓到了系统 PowerMode 服务的确认日志：
> ```
> power-shell setmode 601 → powermgr/PowerMode: GetDeviceMode: mode: 601
> power-shell setmode 600 → powermgr/PowerMode: GetDeviceMode: mode: 600
> ```
> 注意：命令本身无任何输出（RC=0），必须靠系统日志或行为变化才能确认。
> 另有一条告警 `StandbyService: policy 600 not found in policy cache`，但不影响设置生效。

### 3.2 屏幕截图（snapshot_display）**[实机] [社区]**

```bash
snapshot_display -f /data/local/tmp/screen.jpeg       # 截图保存 [实机]
snapshot_display -d 0 -f /data/local/tmp/screen.png   # 指定屏幕编号 [社区]
```

### 3.3 通过 hidumper 查看屏幕/电源状态 **[社区]**

```bash
hidumper -s PowerManagerService -a -s          # 屏幕状态 AWAKE/SLEEP [社区]
hidumper -s RenderService -a screen            # 分辨率、刷新率 [社区]
hidumper -s DisplayManagerService -a -a        # 屏幕信息 [社区]
hidumper -s DisplayManagerService -a -f        # 折叠状态 [社区]
hidumper -s RenderService -a "composer fps"    # 帧率 [社区]
```

> **[注意]** 后台守护进程中通过 `$()` 或重定向调用 `hidumper` 可能遭遇 Binder FD 传递拦截（`error:29201`）。交互式 hdc shell 中直接执行则正常 **[实机]**。

---

## 4. 触控模拟与硬件输入（uinput / uitest）

### 4.1 uinput — 硬件级输入注入 **[官方]**

> 来源：https://developer.huawei.com/consumer/cn/doc/doccenter-capabilities/uinput

#### 设备类型 **[官方]**

| 参数 | 全写 | 说明 |
|------|------|------|
| `-T` | `--touch` | 触摸事件 |
| `-K` | `--keyboard` | 键盘事件 |
| `-M` | `--mouse` | 鼠标事件 |
| `-S` | `--stylus` | 触控笔事件 |
| `-P` | `--touchpad` | 触控板事件 |

#### 4.1.1 触摸事件（-T）**[官方]**

```bash
# 单击 [官方] [实机]
uinput -T -c <x> <y>
uinput -T -c 630 1422

# 按下 / 抬起 [官方]
uinput -T -d <x> <y>
uinput -T -u <x> <y>

# 滑动 [官方] [实机]
uinput -T -m <x1> <y1> <x2> <y2> [smooth_time_ms]
uinput -T -m 1100 50 1100 900 250

# 滑动（带保持时间）[官方]
uinput -T -m <x1> <y1> <x2> <y2> -k <keep_time_ms> [smooth_time_ms]

# 三指滑动 [官方]
uinput -T -m 300 900 300 2000 600 900 600 2000 900 900 900 2000 -k 1000 200

# 拖拽 [官方]
uinput -T -g <x1> <y1> <x2> <y2> [press_time_ms] [total_time_ms]

# 设置事件间隔 [官方]
uinput -T -i <time_ms>
```

#### 4.1.2 键盘事件（-K）**[官方]**

```bash
# 按下 / 抬起 [官方] [实机]
uinput -K -d <keyCode>
uinput -K -u <keyCode>

# 按键单击 [实机]
uinput -K -d 2 -u 2                # 返回键

# 长按 [官方]
uinput -K -l <keyCode> [duration_ms]

# 持续重复输入 [官方]
uinput -K -r <keyCode> [duration_ms]

# 文本输入（仅 ASCII，最大 2000 字符）[官方]
uinput -K -t "Hello,World!"

# 组合键 [官方]
uinput -K -d 2072 2038             # Ctrl+V

# 设置事件间隔 [官方]
uinput -K -i <time_ms>
```

#### 4.1.3 鼠标事件（-M）**[官方]**

```bash
uinput -M -m <dx> <dy>                                      # 移动
uinput -M -m <x1> <y1> <x2> <y2> [smooth_time_ms] --trace  # 带轨迹移动
uinput -M -d <buttonId>                                     # 按下 (0=左 1=右 2=中)
uinput -M -u <buttonId>                                     # 抬起
uinput -M -c <buttonId>                                     # 单击
uinput -M -b <x> <y> <buttonId> [press_time] [interval]    # 双击
uinput -M -m <x> <y> -s <number>                            # 滚轮 (正数向后)
uinput -M -g <x1> <y1> <x2> <y2> [total_time_ms]            # 拖拽
uinput -M -q                                                 # 查询光标信息
uinput -M -i <time_ms>                                      # 设置事件间隔
```

#### 4.1.4 触控笔事件（-S）**[官方]**

```bash
uinput -S -d <x> <y>                                        # 按下
uinput -S -u <x> <y>                                        # 抬起
uinput -S -c <x> <y> [click_interval]                       # 单击
uinput -S -m <x1> <y1> <x2> <y2> [smooth_time] [-k keep]   # 移动
uinput -S -g <x1> <y1> <x2> <y2> [press_time] [total_time] # 拖拽
```

#### 4.1.5 触控板事件（-P）**[官方]**

```bash
uinput -P -p <x> <y> <scalePercent>     # 捏合 (<100 缩小, >100 放大)
uinput -P -s <startX> <startY> <endX> <endY>  # 三指滑动
uinput -P -r <degrees>                  # 旋转（官方注明当前版本可能无效）
```

#### 4.1.6 指关节事件 **[官方]**

```bash
uinput -T -k -s <x1> <y1> <x2> <y2> [interval_ms]   # 单指关节双击
uinput -T -k -d <x1> <y1> <x2> <y2> [interval_ms]   # 双指关节双击
```

#### 4.1.7 修饰键状态控制（API 22+）**[官方]**

```bash
uinput enable_key_status 1 [duration_seconds]   # 启用（默认 10 秒）
uinput enable_key_status 0                       # 禁用
```

### 4.2 uitest — UI 自动化工具 **[社区]**

> 来源：awesome-hdc 项目整理

#### 4.2.1 UI 输入操作 **[社区]**

```bash
uitest uiInput click <x> <y>                              # 点击
uitest uiInput doubleClick <x> <y>                        # 双击
uitest uiInput longClick <x> <y>                          # 长按
uitest uiInput fling <x1> <y1> <x2> <y2> [velocity] [step] # 快滑
uitest uiInput swipe <x1> <y1> <x2> <y2> [velocity]       # 慢滑
uitest uiInput drag <x1> <y1> <x2> <y2> [velocity]        # 拖拽
uitest uiInput dircFling <direction>                      # 方向滑动 (0=左 1=右 2=上 3=下)
uitest uiInput inputText <x> <y> <text>                   # 输入文本
uitest uiInput keyEvent <keyName>                         # 按键 (Home/Back)
uitest uiInput keyEvent <keyID> [keyID2]                  # 组合键
```

#### 4.2.2 截图 **[社区]**

```bash
uitest screenCap                           # 默认 /data/local/tmp
uitest screenCap -p /data/local/tmp/1.png  # 指定路径
```

#### 4.2.3 页面布局分析 **[社区] [实机]**

```bash
# 导出控件树 JSON
uitest dumpLayout -p /data/local/tmp/
# 输出: layout_<timestamp>.json
# 包含: accessibilityId, bounds, clickable, text, type, children

# 导出指定窗口的控件树 [实机]
uitest dumpLayout -w <FocusWinId> -p /data/local/tmp/focus_layout.json
```

> **[实机]** `uitest dumpLayout -w <windowId>` 可仅导出当前焦点窗口的控件树，避免全屏遍历。在 HMArkPriv 跳广告引擎中已验证。

#### 4.2.4 操作录制 **[社区]**

```bash
uitest uiRecord record    # 录制UI操作
uitest uiRecord read      # 读取录制
```

---

## 5. 系统状态与硬件探针（hidumper）

### 5.1 基本用法 **[官方] [社区]**

```bash
hidumper -h                    # 帮助 [官方]
hidumper -lc                   # 系统信息集群列表 [官方]
hidumper -ls                   # 系统能力（SA）列表 [官方] [实机]
hidumper -s                    # 转储所有 SA [官方]
hidumper -s <SA_name>          # 查询指定 SA [官方]
hidumper -s <SA_name> -a "<args>"  # 带 arguments [官方]
```

### 5.2 核心硬件与服务查询

```bash
# 电池与充电状态 [实机]
hidumper -s BatteryService           # 电池与充电状态 [实机]
hidumper -s BatteryService -a -i       # 详细信息 [社区]

# WiFi 信息 [社区]
hidumper -s WifiDevice                # WiFi 设备信息 [社区]

# 个人热点 [实机]
hidumper -s WifiHotspot               # 个人热点状态 [实机]

# 窗口管理器 [实机]
hidumper -s WindowManagerService      # 窗口管理器 [实机]

# 网络连接 [社区]
hidumper -s NetConnManager            # 网络连接 [社区]

# 渲染服务 [社区]
hidumper -s RenderService -a screen    # 分辨率、刷新率
hidumper -s RenderService -a "composer fps"  # 帧率

# 电源管理 [社区]
hidumper -s PowerManagerService -a -s  # 屏幕状态
hidumper -s PowerManagerService -a -r  # RunningLock

# 显示管理 [社区]
hidumper -s DisplayManagerService -a -a  # 屏幕信息
hidumper -s DisplayManagerService -a -f  # 折叠状态

# 内存管理 [官方]
hidumper -s MemoryManagerService -a -a  # 内存管理 [社区]
hidumper -s MemoryManagerService -a -r

# Ability 管理器（替代 aa dump）[官方]
hidumper -s AbilityManagerService
```

### 5.3 进程与性能 **[官方]**

```bash
hidumper -p                    # 所有进程 [官方]
hidumper -p <pid>              # 指定进程线程 [官方]
hidumper --cpuusage            # CPU 使用率 [官方]
hidumper --cpuusage <pid>      # 指定进程 CPU [官方]
hidumper --cpufreq             # CPU 频率 [官方] [实机]
hidumper --mem                 # 内存 [官方] [实机]
hidumper --mem <pid>           # 指定进程内存 [官方]
hidumper --mem-smaps <pid> [-v]       # smaps 详情 [官方]
hidumper --mem-jsheap <pid> [-T <tid>] [--gc]  # JS Heap [官方]
hidumper --net                 # 网络 [官方]
hidumper --net <pid>           # 指定进程网络 [官方]
hidumper --storage             # 存储 [官方]
hidumper --storage <pid>       # 指定进程存储 [官方]
hidumper -e                    # 崩溃历史 [官方]
hidumper --zip                 # 压缩输出 [官方]
```

> **[实机]** `hidumper -s BatteryService` 在交互式 hdc shell 中直接执行正常；在后台守护进程中通过 `$(hidumper ...)` 调用可能遭遇 Binder FD 传递拦截。

---

## 6. 系统参数与服务控制（param / service_control）

### 6.1 参数系统（param）**[官方]**

> 来源：https://gitee.com/openharmony/docs/blob/master/zh-cn/application-dev/tools/param-tool.md

```bash
param get                               # 获取所有参数 [实机]
param get const.product.model           # 获取指定参数 [实机]
param get | grep -E 'os|model|brand'    # 模糊查询 [实机]
param set const.product.developmentmode 1  # 设置参数 [社区]
param ls                                # 列出所有参数 [官方]
param wait <name> [value] [timeout]     # 等待参数 [官方]
param dump [verbose]                    # dump 参数 [官方]
param save                              # 保存参数 [官方]
```

### 6.2 系统服务控制 **[未验证]**

```bash
service_control start <service_name>   # 启动系统服务
service_control stop <service_name>    # 停止系统服务
```

> **[未验证]** `service_control` 命令来自 HMArkPriv 原始文档，未在华为官方文档中找到记载。该命令可能存在但参数和行为未经外部验证。

---

## 7. 日志与性能跟踪（hilog / hisysevent / bytrace / SP_daemon）

### 7.1 系统日志（hilog）**[官方] [社区]**

> 来源：awesome-hdc 项目整理 + 官方文档

```bash
hilog                    # 实时日志 [实机]
hilog -x                 # 非阻塞读取 [社区]
hilog -T <tag>           # 按 Tag 过滤 [实机]
hilog -L <level>         # 按级别过滤 (D/I/W/E/F) [社区]
hilog -D <domain>        # 按域过滤 [社区]
hilog -P <pid>           # 按 PID 过滤 [社区]
hilog -e "<regex>"       # 正则过滤 [社区]
hilog -a <n>             # 头部 N 行 [社区]
hilog -z <n>             # 尾部 N 行 [社区]
hilog -r                 # 清空缓冲 [实机]
hilog -G <size>          # 设置缓冲大小 [社区]
hilog -g                 # 查询缓冲大小 [社区]
hilog -v color           # 彩色输出 [社区]
hilog -v msec            # 毫秒级 [社区]
hilog -w start           # 持久化开始 [社区]
hilog -w stop            # 持久化停止 [社区]
hilog -p on/off          # 隐私格式化 [社区]
hilog -b <level>         # 全局日志级别 [社区]
hilog -s                 # 统计信息 [社区]
hilog -S                 # 清除统计 [社区]
```

### 7.2 导出日志文件 **[社区]**

```bash
hdc file recv data/log/hilog/ ./
hdc file recv data/log/faultlog/faultlogger/ ./
```

### 7.3 系统事件（hisysevent）**[未验证]**

```bash
hisysevent -l                          # 列出系统事件
```

> **[未验证]** 来自 HMArkPriv 原始文档，未在官方文档中找到 `-l` 参数的说明。

### 7.4 性能追踪（bytrace）**[未验证]**

```bash
bytrace -t 5 -b 4096 --overwrite ability app > /data/local/tmp/trace   # 抓性能trace.ftrace
```

> **[未验证]** 来自 HMArkPriv 原始文档。`bytrace` 工具存在于系统中，但具体参数语法未经外部验证。

### 7.5 SmartPerf（SP_daemon）**[社区]**

> 来源：awesome-hdc 项目 + OpenHarmony 官方文档

```bash
SP_daemon --help                                              # 帮助
SP_daemon -N 20 -c -g -t -p -r -m -net -snapshot -d          # 采集 20 次
SP_daemon -N 20 -PKG com.example.app -c -g -t -p -f -r -m -net -snapshot -d  # 指定包名
SP_daemon -start -c                                           # 开始采集
SP_daemon -stop                                               # 停止采集
SP_daemon -screen                                             # 屏幕分辨率
```

| 选项 | 指标 |
|------|------|
| `-c` | CPU 频率和使用率 |
| `-g` | GPU 频率和负载 |
| `-f` | 应用 FPS |
| `-t` | 电池温度 |
| `-p` | 电流和电压 |
| `-r` | 进程内存 |
| `-m` | 其他内存 |
| `-net` | 上下行流量 |
| `-snapshot` | 屏幕截图 |
| `-d` | DDR 信息 |

---

## 8. UI 测试与页面分析（uitest）

> 详见 [4.2 uitest](#42-uitest--ui-自动化工具) 章节 **[社区] [实机]**

---

## 9. 文件系统与进程管理（Linux / Toybox）

### 9.1 进程管理 **[实机]**

```bash
ps -ef                  # 查看所有进程
ps -ef | grep <name>    # 搜索进程
kill -9 <pid>           # 强制结束
pidof <name>            # 获取 PID
pgrep -f <pattern>      # 模式匹配
top -n 1                # CPU 使用率快照
```

### 9.2 文件操作 **[实机]**

```bash
ls -la <path>           # 列出文件
cat <file>              # 查看内容
cp <src> <dst>          # 复制
mv <src> <dst>          # 移动/重命名
rm <file>               # 删除文件
rm -rf <dir>            # 递归删除目录
mkdir -p <dir>          # 递归创建目录
chmod 755 <file>        # 修改权限
df -h                   # 磁盘使用
du -sh <path>           # 目录大小
find / -name <pattern>  # 查找文件
```

### 9.3 文本处理

```bash
grep -E 'pattern' <file>           # 正则过滤 [实机]
grep -i 'pattern' <file>           # 忽略大小写 [实机]
sed 's/find/replace/g' <file>     # 替换 [实机]
cut -d' ' -f1 <file>              # 字段截取 [实机]
head -n 20 <file>                 # 前 20 行 [实机]
tail -n 20 <file>                 # 后 20 行 [实机]
sort <file>                       # 排序 [实机]
uniq                              # 去重 [实机]
```

> **[实机]** HarmonyOS 7.0 的 toybox **已裁剪 `awk` 和 `tr`**，需用 `sed` / `cut` 替代。

### 9.4 数据库 **[未验证]**

```bash
sqlite3 <db_file>                      # 打开数据库交互式 shell
```

> **[未验证]** `sqlite3` 是否预装在 HarmonyOS 7.0 中未经确认。

### 9.5 其他常用 **[实机]**

```bash
date                          # 当前时间
sleep 1                       # 延迟
echo "text" > <file>          # 写入文件
echo "text" >> <file>         # 追加
which <command>               # 查找命令路径
```

---

## 10. 网络诊断与端口转发

### 10.1 设备端网络命令 **[社区]**

```bash
ifconfig                      # 查看网卡 [实机]
ifconfig -a                   # 所有接口 [社区]
ip addr                       # IP 地址 [社区]
netstat -tlpn                 # 监听端口 [社区]
ping -c 3 127.0.0.1           # 连通性 [实机]
```

> **[社区]** Beta3 之前版本的 `ifconfig` 可能提示 `Cannot open netlink socket: Permission denied`，需升级系统。

### 10.2 HDC 端口转发 **[官方] [社区]**

```bash
hdc fport ls                                          # 查看列表 [社区]
hdc fport tcp:<local_port> tcp:<device_port>          # 本地→设备 [社区]
hdc fport rm tcp:<local_port> tcp:<device_port>       # 删除 [社区]
hdc rport tcp:<device_port> tcp:<local_port>          # 设备→主机 [社区]
hdc rport ls                                          # 查看反向列表 [社区]
hdc rport rm tcp:<device_port> tcp:<local_port>       # 删除反向 [社区]
```

### 10.3 无线调试 **[社区]**

```bash
# 方式一：直接 IP 连接
hdc -t <serial> tmode port <port>
hdc tconn <wlan_ip>:<port>
hdc -t <serial> tmode port close

# 方式二：PC 中转
hdc -t <serial> tmode port 5555
hdc -t <serial> fport tcp:5556 tcp:5555
hdc tconn 127.0.0.1:5556
```

---

## 11. 安卓容器穿透（卓易通 / 出境易）

> **[实机]** 以下命令在 HUAWEI Pura 70 Pro+（HarmonyOS 7.0）+ 卓易通环境上验证。
>
> **重要架构说明**：卓易通 / 出境易运行在由 `rgm_hmos` / `isulad` 管理的轻量级容器虚拟机
> （ANCO 架构）中，拥有独立的网络命名空间与进程树。通过 `hmdfs` 共享文件系统实现
> 鸿蒙宿主 ⇄ 容器的跨沙盒通信。
>
> **包名对照（实测确认，容易搞混）**：
>
> | 包名 | 是什么 | 用途 |
> |------|--------|------|
> | `com.zhuoyi.appstore.lite` | 卓易通 App 本体（鸿蒙侧） | 用户点开的应用，有「发现/应用/我的」三个 Tab |
> | `com.droi.tong` | 卓易通的安装包名 | 用 `aa start -b com.droi.tong -a EntryAbility` 拉起它 |
> | `com.easy.hmos.abroad` | 出境易的安装包名 | 用 `aa start -b com.easy.hmos.abroad -a EntryAbility` 拉起 |
> | `com.easy.abroad` | 出境易运行时的 UI 进程名 | `uitest dumpLayout` 显示的是这个，两个名字指同一个 App |
> | `com.android.settings` | 容器内的安卓设置 | 靠 `aa start` 穿透进去，本文重点 |
>
> 检测设备是否装了卓易通，用 `bm dump -a | grep -c com.zhuoyi.appstore` 或
> `grep -c com.droi.tong` 都可以，**不能**用 `grep -i android` / `grep -i anco`
> —— 这些包名里都没有那两个词。
>
> **容器挂载点**（shell 无法访问，仅作了解）：
> - `/data/virt_service/rgm_hmos/anco_hmos`（只读，容器系统镜像）
> - `/data/virt_service/rgm_hmos/anco_hmos_data`（可写，容器 /data 分区）
> 两者都被 SELinux 完全隔离，`ls` 和 `hdc file recv` 都被 `Permission denied`。
>
> **容器侧进程**（`ps -ef` 可见）：
> `isulad`（容器运行时）/ `rgm_engine_plugin` / `rgm_manager` /
> `anco_service_broker`（容器服务代理）/ `bms_broker`（包管理代理）/ `anco_audio`

### 11.1 打开容器内的安卓系统设置（卓易通/出境易通用）

> **[实机验证 2026-11-04]** 在 Pura 70 Pro+ (HBN-AL80 / 7.0.0.109) + 卓易通环境上逐条实测。
>
> **架构原理**：卓易通 `com.droi.tong` / 出境易 `com.easy.hmos.abroad` 运行在
> `rgm_hmos` / `isulad` 管理的轻量级容器（ANCO 架构）中，有独立网络命名空间与进程树。
> 鸿蒙宿主的 `aa start -b com.android.settings` 能把启动请求路由到容器内的安卓 Settings。
>
> **验证技巧**：`aa start` 的 RC 永远是 0，不能作为成功依据。
> 正确做法是启动后等 **5-6 秒**（容器内 Activity 启动较慢），
> 再 `uitest dumpLayout` 看 `bundleName` 是否为 `com.android.settings`。
>
> **关键：`$` 转义（不转义必定失败）**
>
> Activity 名是内部类（含 `$`），必须写成 `"....Settings\$XxxActivity"`：
> - 外层**双引号**包住整个 activity 名，防止被拆词
> - **`\$`** 防止 daemon 的 `sh -c` 把 `$NotificationAccessSettingsActivity` 当变量展开成空
>
> 实测：不转义时 sh 会把它展开成 `com.android.settings.Settings`，
> 启动"成功"（RC=0）但界面退回桌面。
>
> **能力检测**：判断设备是否装了卓易通要看 `com.droi.tong` 是否在应用列表，
> **不能**用 `grep -i android` 或 `grep -i anco` —— 容器包的 bundleName 里没有这两个词。

```bash
aa start -b com.android.settings -a "com.android.settings.Settings\$NotificationAccessSettingsActivity"   # 通知使用权页
aa start -b com.android.settings -a "com.android.settings.Settings\$SpecialAccessSettingsActivity"        # 特殊访问权限页
aa start -b com.android.settings -a "com.android.settings.Settings\$ManageApplicationsActivity"          # 已装应用列表（约10秒）
```

**逐条说明**：

| 命令 | 界面能看到什么 | 典型用途 | 实测 |
|------|--------------|---------|------|
| 通知使用权 | 容器内安卓应用列表，可逐个授予"读取通知"权限 | 给需要读取通知的工具类 App 授权 | ✅ 可重复打开 |
| 特殊访问权限 | 悬浮窗 / 媒体管理应用 / 修改系统设置 / 通知使用权 / 闹钟和提醒 / 使用情况访问权限 / WLAN 控制 | 给投屏、自动化工具授予悬浮窗或改设置权限 | ✅ 7 个条目完整列出 |
| 已装应用列表 | 容器内应用清单（名称+大小），点进去可卸载/强停/看权限 | 管理容器内应用 | ✅ 需等约 10 秒渲染 |

**出境易同样适用（命令完全不用改）**

出境易是另一款安卓容器 App，和卓易通共用同一个 ANCO 运行时，
所以 11.1 / 11.2 / 11.3 的命令对它一模一样，只需要先把它切到前台：

```bash
aa start -b com.easy.hmos.abroad -a EntryAbility   # 打开出境易
```

实测对比（先打开出境易，再执行上面的穿透命令）：

| 命令 | 结果 |
|------|------|
| 通知使用权 | ✅ 正常打开，标题「通知使用权」，列出容器内应用 |
| 特殊访问权限 | ✅ 正常打开，7 个条目完整 |
| 应用列表 | ✅ 正常打开，列出应用名和大小 |

> **为什么两个 App 能共用同一套命令**：它们都是 ANCO 容器架构的宿主，底层都依赖
> `rgm_hmos` / `isulad` 提供的容器运行时。宿主侧的 `aa start -b com.android.settings`
> 由系统按**当前活动的那个容器**路由进去，所以命令里不需要区分是哪个宿主，
> 只要保证目标容器在前台就行。

> **无障碍（AccessibilitySettingsActivity）已从手册移除** —— 2026-11-04 穷举验证确认
> 这条路完全不可达：
> - 4 个 Activity 变体全部被系统拦截（页面能启动、会渲染，但渲染完立刻被关闭）
> - 容器数据目录 `/data/virt_service/rgm_hmos/anco_hmos_data` 被 SELinux 完全隔离
>   （shell 和 hdc 都进不去）
> - 卓易通 App 里也没有安卓设置入口（「我的 ▸ 权限管理」显示的是宿主 App 在鸿蒙侧的权限，
>   「我的 ▸ 设置」只有流量提醒/自动更新/隐私声明）
>
> 无障碍的替代方案见 **11.1.1** 节 —— `uinput` + `uitest` 能覆盖它的绝大多数用途且更强。

### 11.1.1 无障碍的替代方案（重要）

既然无障碍拿不到，那它原本能做的事怎么实现？**我们这套特权 shell 通道本身就是无障碍的替代品**，
而且能力更强。

| 无障碍的典型用途 | 我们的替代方案 | 能力对比 |
|-----------------|---------------|---------|
| 模拟点击 / 长按 / 滑动 | `uinput -T -c x y` / `-m` | ✅ 完全等价，甚至更精确（可指定毫秒级时长） |
| 模拟按键（Home/Back/音量） | `uinput -K -d N -u N` | ✅ 完全等价 |
| 读取屏幕内容（控件树） | `uitest dumpLayout -p file.json` | ✅ **更强** —— 能拿到每个控件的 text/bounds/clickable/type |
| 按文字找控件再点击 | `uitest dumpLayout` + 解析 JSON 取坐标 + `uinput -T -c` | ✅ 可实现，约 1.4 秒一轮 |
| 监听界面变化 | 轮询 `uitest dumpLayout`（50ms 一次不现实，1-2 秒一次可行） | ⚠️ 不如无障碍实时，但够用 |
| 后台自动操作（不占前台） | `uinput` + `uitest` 都是 shell 层，不需要 App 前台 | ✅ 比无障碍更适合 |
| 跨应用读取界面 | 同上，shell 权限能读任意界面的控件树 | ✅ 无障碍需要逐个应用授权，我们不需要 |

**具体示例**：

```bash
uitest dumpLayout -p /data/local/tmp/ui.json    # 导出界面控件树（找按钮坐标）
uinput -T -c 540 1200                          # 点击坐标
uinput -t "要输入的文字"                          # 向当前焦点输入框输入文字
uinput -T -m 540 2000 540 800 300              # 滑动，耗时300ms
uinput -K -d 2 -u 2                            # 按返回键
uinput -K -d 1 -u 1                            # 按 Home 键
```

> **为什么这套方案比无障碍更好**：不受"仅对当前应用生效"限制、能跨应用操作、
> 不需要用户逐个 App 授权，还能做无障碍做不了的事（改系统设置、强停应用、截图）。

---

### 11.2 启动容器内的安卓应用

> **[实机验证 2026-11-04]** 原理和 11.1 相同，`aa start` 把启动请求路由进容器。
> 区别是这里的 `-b` 写容器内**安卓应用的包名**，不是 `com.android.settings`。

```bash
aa start -b com.aistra.hail -a com.aistra.hail.ui.main.MainActivity   # 实测可用的完整例子
aa start -b com.easy.hmos.abroad -a EntryAbility                      # 拉起出境易本体
```

**参数说明**：

| 参数 | 含义 |
|------|------|
| `-b <android_package_name>` | 容器内安卓应用的包名，形如 `com.example.app` |
| `-a <main_activity_name>` | 该应用的主 Activity，形如 `com.example.app.MainActivity` |

> **两个参数都必填**。只给 `-b`（或改用 `-U package:xxx`）会直接报
> `10103101 Failed to find a matching application for implicit launch` ——
> 因为容器包不在鸿蒙 `bm` 里，隐式匹配必然落空。包名和 Activity 怎么拿见 **11.3**。
>
> **这类命令不需要 `$` 转义**（普通应用的主 Activity 名不含 `$`），
> 只有 `com.android.settings` 那种内部类 Activity 才需要（见 11.1）。
>
> **怎么确认真的启动了**：`aa start` 返回的 RC 不能当依据（参数不全时会报错，
> 但 Activity 名写错时可能仍返回成功）。正确做法是启动后等 4-6 秒，
> `uitest dumpLayout` 导出控件树，看 `bundleName` 是否变成目标包名
> （若仍是 `com.ohos.sceneboard` 说明失败）：
> ```bash
> uitest dumpLayout -p /data/local/tmp/ui.json >/dev/null 2>&1; grep -o '"bundleName":"[^"]*"' /data/local/tmp/ui.json | sort -u
> ```

---

### 11.3 获取容器内应用的包名 + Activity 名

> **[实机验证 2026-11-04]** 这是 11.2 的**前置步骤** —— `aa start -b <包名> -a <Activity>` 两个参数**必须成对提供**。
>
> 容器内的安卓应用没有在宿主鸿蒙系统的包管理系统（`bm`）中注册，因此无法使用隐式启动，也不支持只传 `-b`（会报 `10103101 Failed to find a matching application for implicit launch`）。
>
> 以下提供经过实机压测的最佳获取方案：

#### 方法 A：一键列出所有近期运行的容器应用（⭐ 最推荐：免切前台、0.2秒秒出）

**原理**：鸿蒙桌面与多任务管理器（SceneBoard）在内存日志中完整记录了多任务栈中的应用标识。直接读取实时内存缓冲并格式化，**无需把应用切到前台**，在 HMArkPriv 内直接点击即可：

```bash
# 直接生成标准的 aa start 启动指令列表
hilog -x 2>/dev/null | grep -oE '[A-Za-z0-9_.$]+/[A-Za-z0-9_.]+/entry/0' | sort -u | sed 's|/entry/0||' | sed 's|\(.*\)/\(.*\)|aa start -b \2 -a \1|'
```

**实测输出（毫秒级返回，直接复制可用）**：

```
aa start -b com.aistra.hail -a com.aistra.hail.ui.main.MainActivity
aa start -b com.android.settings -a com.android.settings.Settings$ManageApplicationsActivity
aa start -b com.android.settings -a com.android.settings.Settings$NotificationAccessSettingsActivity
aa start -b com.easy.abroad -a com.easy.abroad.activities.MainActivity
aa start -b org.kde.kdeconnect_tp -a org.kde.kdeconnect.UserInterface.MainActivity
```

如果只想看清晰的 `包名 : Activity` 映射表：

```bash
hilog -x 2>/dev/null | grep -oE '[A-Za-z0-9_.$]+/[A-Za-z0-9_.]+/entry/0' | sort -u | sed 's|/entry/0||' | sed 's|\(.*\)/\(.*\)|\2 : \1|'
```

---

#### 方法 B：延时 3 秒精准抓取当前屏幕应用（解决前台切换问题）

如果刚打开了一个新应用，想直接抓取当前屏幕前台窗口的参数：
在 HMArkPriv 中点击执行后，**有 3 秒倒计时**供你从容切到底部的目标应用，3 秒后脚本自动读取屏幕控件树中的 `bundleName` 与 `abilityName`：

```bash
sleep 3 && uitest dumpLayout -p /data/local/tmp/d.json >/dev/null 2>&1 && grep -oE '"bundleName":"[^"]+"|"abilityName":"[^"]+"' /data/local/tmp/d.json | grep -v 'sceneboard' | sort -u
```

**实测输出示例**：

```
"abilityName":"org.kde.kdeconnect.UserInterface.MainActivity"
"bundleName":"org.kde.kdeconnect_tp"
```

---

#### 方法 C：直达容器内设置与权限界面（零命令排查应用）

如果只是想看容器内安装了哪些应用，或者要给某个应用（如短信转发器、KDE Connect）授予**通知使用权**、悬浮窗或后台权限，无需记忆包名，直接拉起容器内置的 Android 原生管理页：

```bash
# 1. 打开容器内应用管理列表（查看所有已装应用、存储占用、版本、强停与卸载）
aa start -b com.android.settings -a "com.android.settings.Settings\$ManageApplicationsActivity"

# 2. 打开容器内“通知使用权”授权页（直接在列表勾选短信转发器/KDE Connect）
aa start -b com.android.settings -a "com.android.settings.Settings\$NotificationAccessSettingsActivity"

# 3. 打开容器内特殊访问权限设置总览
aa start -b com.android.settings -a "com.android.settings.Settings\$SpecialAccessSettingsActivity"
```

---

#### 方法 D：电脑端 HDC 查任务栈（完整列表）

手机连接电脑时，电脑终端直接执行 `aa dump -l` 即可查看所有近期任务栈：

```bash
hdc shell "aa dump -l"
```

**输出中的 mission name 片段**：
```
Mission ID #954  mission name #[#org.kde.kdeconnect_tp:entry:org.kde.kdeconnect.UserInterface.MainActivity]
Mission ID #979  mission name #[#com.aistra.hail:entry:com.aistra.hail.ui.main.MainActivity]
```

> **踩坑记录：为什么全量搜 gzip 日志会超时？**
> 系统日志目录 `/data/log/hilog/` 中累积了 600 多个 gz 压缩包（近 500MB），`gzip -dc /data/log/hilog/hilog.*.gz` 尝试全部解压并正则扫描数 GB 的文本，手机 CPU 耗时超过了后台守护进程的 20 秒安全超时限制，因此会被自动终止。使用方法 A 读取内存中的实时缓冲（`hilog -x`）仅需 0.2 秒且覆盖所有近期多任务，完全无需解压历史文件。

---

## 12. HDC 工具命令（电脑端）**[官方] [社区]**

> 来源：awesome-hdc 项目 + 华为官方文档

### 12.1 设备管理 **[社区]**

```bash
hdc list targets                 # 查看设备
hdc list targets -v              # 详细信息
hdc -t <connectKey> <command>    # 指定设备
hdc target boot                  # 重启设备
hdc target mount                 # 挂载文件系统
hdc -v                           # HDC 版本
hdc kill                         # 停止 Server
hdc start -r                     # 重启 Server
hdc kill -r                      # 杀掉并重启
```

### 12.2 应用管理 **[社区]**

```bash
hdc install <hap_path>           # 安装
hdc install -r <hap_path>        # 覆盖安装
hdc uninstall <bundleName>       # 卸载
hdc jpid                         # 可调试应用列表
hdc track-jpid                   # 动态显示
```

### 12.3 文件传输 **[社区]**

```bash
hdc file send <local> <remote>   # 推送
hdc file recv <remote> <local>   # 拉取
```

### 12.4 其他 **[社区]**

```bash
hdc shell "<command>"            # 执行 shell
hdc hilog                        # 日志
hdc hilog -T <tag>               # Tag 过滤
hdc hilog -L <level>             # 级别过滤
hdc hilog -c                     # 清空（注意是 -c 不是 -r）
hdc reboot                       # 重启
hdc bm get --udid                # UDID
```

---

## 13. 常用 KeyCode 对照表

### 13.1 uinput -K 基础按键码 **[实机]**

| KeyCode | 按键 | 说明 |
|---------|------|------|
| 1 | Home | 主页键 |
| 2 | Back | 返回键 |
| 3 | Call | 拨号键 |
| 4 | EndCall | 挂断键 |
| 16 | Volume Up | 音量增加 |
| 17 | Volume Down | 音量减少 |
| 18 | Power | 电源键 |

### 13.2 完整 KeyCode **[官方]**

> 来源：@ohos.multimodalInput.keyCode（OpenHarmony 官方 API 文档）

| KeyCode | 按键 | KeyCode | 按键 |
|---------|------|---------|------|
| 2017 | A | 2047 | Shift Left |
| 2018 | B | 2048 | Shift Right |
| 2041 | S | 2049 | Ctrl Left |
| 2042 | Alt Left | 2050 | Ctrl Right |
| 2043 | Alt Right | 2051 | Meta Left |
| 2044 | Space | 2052 | Meta Right |
| 2045 | Enter | 2055 | Escape |
| 2056 | Delete | 2057 | Tab |
| 2069 | Arrow Up | 2070 | Arrow Down |
| 2071 | Arrow Left | 2072 | V |
| 2073 | Arrow Right | | |

> 完整列表参见：https://docs.openharmony.cn/pages/v4.1/en/application-dev/reference/apis-input-kit/js-apis-keycode.md

---

## 14. 常用系统参数速查

> 这些参数用 `param get <key>` 查询。下面每条都已改成可直接执行的命令，
> 点击即可在终端运行（示例值仅供参考，实际以你的设备为准）。

```bash
param get const.product.name                # 设备名称
param get const.product.brand               # 品牌
param get const.product.model               # 型号
param get const.product.software.version    # 软件版本
param get const.ohos.apiversion             # API 版本
param get const.product.cpu.abilist         # CPU 架构
param get const.product.devicetype          # 设备类型
param get const.product.developmentmode     # 开发者模式 1/0
param get const.build.version.release       # 系统发行版本 [未验证]
param get hw_sc.build.platform.version      # 鸿蒙核心版本 [未验证]
param get const.bms.allowenterprisebundle   # 允许企业应用
```

**模糊查询**（不知道确切参数名时用）：

```bash
param get | grep -E 'os.name|model|brand|version'   # 模糊查型号/版本
param get | grep -E 'development|debug'             # 模糊查调试相关
param get                                           # 列出全部参数
```

> **关于 [未验证] 的两条**：`const.build.version.release` 和
> `hw_sc.build.platform.version` 来自原始文档，参数名未经官方确认。
> 建议用上面的模糊查询自己确认实际名称。

---

## 附录 A：命令权限等级说明 **[官方] [实机]**

| 等级 | 说明 | 可用命令范围 |
|------|------|-------------|
| **UID 2000 (shell)** | hdc shell 默认权限 | aa, bm, uinput, power-shell, snapshot_display, hidumper, param get, hilog, bytrace, uitest, SP_daemon, 标准Linux命令 |
| **system_basic** | 系统基础应用 | 部分 hidumper 设置类命令 |
| **system_core** | 系统核心应用 | param set 部分参数 |
| **normal (App)** | 普通应用沙箱 | executeShellCommand 仅支持：aa, bm, cp, mkdir, rm, uinput, hilog, echo, uitest, acm, hidumper, wukong, pkill, ps, pidof |

> **[官方]** 普通鸿蒙 App 通过 `AbilityDelegator.executeShellCommand` 仅能执行上述受限命令子集，且需要调试签名。HMArkPriv 的 daemon 方案在 UID 2000 下可执行全部命令。

---

## 附录 B：安全限制详情 **[实机]**

> 以下限制在 HUAWEI Pura 70 Pro+（HarmonyOS 7.0.0.109, HongMeng Kernel 1.13.0）上实机验证。

### B.1 XPM 执行白名单

- `u:r:sh:s0` 仅允许 `execve()` `/system/bin/` 下约 185 个华为签名二进制
- 推送到 `/data/local/tmp/` 的自定义二进制即使 `chmod 755` 也返回 `Permission denied`
- 即使复制 `/system/bin/sh` 到 `/data/local/tmp/` 也无法执行

### B.2 网络与 IPC 限制

- 禁止 `listen()` 绑定 TCP 端口（`EACCES, errno=13`）
- 禁止 `mkfifo` 创建命名管道

### B.3 跨沙盒文件 IPC 突破

- `hdc file send` 运行在 `u:r:hdcd:s0` 域，可创建 `Download/` 下目录和文件
- 预创建文件属组为 `1006(file_manager)`，权限 `0660`
- `u:r:sh:s0` 隶属 `1006` 组，对预分配文件有完整读写权限
- 该目录通过 `hmdfs` 自动映射到卓易通容器 `/sdcard/MyHarmonyOSDevice/Download/`

### B.4 hidumper 后台 FD 传递拦截

- 交互式 shell 中直接执行 `hidumper` 正常
- 后台守护进程中通过 `$(hidumper ...)` 或重定向调用时，遭遇 `error:29201 operation not permitted`
- 原因：`fd 1` 创建者变为 `u:r:sh:s0`，被 SELinux `security_file_receive` 拦截
- 解决方案：`uitest dumpLayout` 不受此限制（内部通过共享内存/IPC 写入文件）

### B.5 Toybox 裁剪

- 已裁剪：`awk`, `tr`
- 替代方案：使用 `sed`, `cut`

### B.6 mksh 转义

- `/bin/sh` 基于 mksh
- 参数展开 `${VAR%%pattern}` 中的 `|` 需转义为 `\|`
- `${FIRST_LINE%%\|*}` 而非 `${FIRST_LINE%%|*}`

---

_文档版本：v2.1 | 更新日期：2026-11-03
_数据来源：华为官方文档 + awesome-hdc 社区项目 + HMArkPriv 项目实机验证
_测试机型：HUAWEI Pura 70 Pro+ (HBN-AL80, HarmonyOS 7.0.0.109, HongMeng Kernel 1.13.0)
