# HMArkPriv — HarmonyOS Shell 提权工具

> 用原生 ArkUI 替代原 HTML 控制台，通过文件总线与 UID 2000 的 daemon 通信，执行鸿蒙系统级 Shell 命令。

- **目标设备**：HarmonyOS NEXT (7.0) / API 26
- **当前阶段**：Phase 1 MVP（终端可用，其余 Tab 为占位）
- **验收标准**：终端输入 `id` → 返回 `uid=2000(shell)`

---

## 一、5 分钟上手（DevEco Studio）

### 步骤 1：打开工程

1. 启动 **DevEco Studio**（已装在 `D:\DevEco Studio`）
2. `File > Open` → 选择目录 **`D:\0\harmony`**
3. 弹出「Trust Project?」选 **Trust**
4. 等待右下角 **Sync** 进度条走完（首次约 1-2 分钟，会下载 hvigor 依赖）

> 若 Sync 报错找不到 SDK：`File > Project Structure > SDK`，确认 SDK 路径指向
> `D:\DevEco Studio\sdk`，API 版本为 **26.0.0**。

### 步骤 2：配置自动签名（装真机必须）

1. 右上角点 **登录华为账号**（`File > Settings > 账号` 也可）
2. `File > Project Structure > Project > Signing Configs`
3. 勾选 **Automatically generate signature**
4. 等待自动生成（需要联网 + 已登录 + 已完成实名认证）

签名成功后 `build-profile.json5` 的 `signingConfigs` 会自动填入证书信息。
**没有签名只能编译，不能装到手机。**

### 步骤 3：真机调试

1. 手机：`设置 > 关于本机` → 连点「版本号」7 次开启开发者模式
2. 手机：`设置 > 系统 > 开发者选项` → 打开 **USB 调试**
3. USB 连接电脑，手机弹窗选 **允许调试**
4. DevEco Studio 顶部设备下拉框应出现你的机型
5. 点绿色 ▶ **Run 'entry'**

### 步骤 4：部署 daemon（手机端一次性的准备工作）

App 本身**没有**执行 shell 的能力，必须先在手机上跑起 daemon：

```bash
# 1. 手机文件管理里手动建目录：Download/HMArkPriv
# 2. 电脑上执行（把 daemon.sh 推到手机并启动）
hdc file send ../core/daemon.sh /data/local/tmp/hmpriv/daemon.sh
hdc shell "chmod 755 /data/local/tmp/hmpriv/daemon.sh"
hdc shell "sh /data/local/tmp/hmpriv/daemon.sh &"
```

> daemon 被杀后需要重新执行最后一条命令。可用 `hdc shell "cat /data/local/tmp/hmpriv/daemon.pid"` 检查是否存活。
> **注意**：daemon.sh 必须是 LF 换行，Windows 上 checkout 的是 CRLF 会报 `syntax error`，
> 推送前先 `tr -d '\r' < daemon.sh > daemon_lf.sh`。

### 步骤 5：打开 App，无需任何授权

直接打开 App 即可。它会自动：

1. 探测 `/storage/Users/currentUser/Download/HMArkPriv`（App 沙箱视图路径）
2. 自动创建缺失的总线文件（cmd.req / cmd.res / status.json）
3. 读取 status.json，顶部状态栏显示 **`UID:2000`** + 卡片显示 **「Daemon 在线」**

> **不需要选文件夹、不需要点授权。** 详见「架构」一节的双视角路径说明。

### 步骤 6：验证

切到 **「终端」** Tab，点 `id` 快捷标签（或手动输入后回车）：

```
id
```

期望输出：

```
uid=2000(shell) gid=2000(shell) groups=2000(shell),1006(file_manager),... context=u:r:sh:s0
```

也可以点首页的「电池」按钮，验证另一条命令链路。

---

## 二、命令行构建（不开 IDE）

```bash
./build.sh          # 编译 debug HAP
./build.sh clean    # 清理产物
```

产物：`entry/build/default/outputs/default/entry-default-unsigned.hap`

脚本已自动处理两个必需环境变量：

| 变量 | 值 | 作用 |
|------|-----|------|
| `PATH` | 追加 `D:\DevEco Studio\jbr\bin` | 打包阶段需要 java |
| `DEVECO_SDK_HOME` | `D:\DevEco Studio\sdk` | hvigor 定位 SDK |

> 命令行构建**不签名**，仅用于验证代码能否编译通过。装机请走 IDE。

---

## 三、架构

```
┌─────────────────────────────────────────┐
│  HMArkPriv App（ArkUI，沙箱 UID）        │
│                                         │
│  pages/Index.ets     主界面 + Tab 容器   │
│  components/         终端控制台、状态卡片 │
│  services/                                      │
│    BusClient         读写 cmd.req/cmd.res│
│    BusDirManager     目录授权 + 持久化    │
│  utils/                                        │
│    CommandBuilder    命令模板             │
│    ResponseParser    输出解析             │
└──────────────┬──────────────────────────┘
               │ 文件总线（经用户授权的目录 URI）
               ▼
    Download/HMArkPriv/
      cmd.req       ← App 写：reqId|command
      cmd.res       → daemon 写：ID:reqId RC:code TIME:ts\n<output>
      status.json   → daemon 心跳
               │
               ▼
┌─────────────────────────────────────────┐
│  daemon.sh（UID 2000，hdc 部署）         │
│  50ms 轮询 cmd.req → sh -c 执行 → 写回   │
└─────────────────────────────────────────┘
```

**为什么必须这样设计**：鸿蒙沙箱禁止普通 App spawn shell 进程。
App 只能当「文件总线客户端」，真正执行命令的 daemon 必须由 hdc 以 shell（UID 2000）身份部署。

**两套路径，同一批文件**（关键，踩过坑）：

| 视角 | 路径 |
|------|------|
| App（沙箱虚拟视图） | `/storage/Users/currentUser/Download/HMArkPriv` |
| daemon / shell | `/storage/media/100/local/files/Docs/Download/HMArkPriv` |

鸿蒙给每个 App 一个 `/storage/Users/currentUser/...` 的虚拟挂载视图，映射到真实用户目录。
配合已声明的 `READ_MEDIA` / `WRITE_MEDIA`，**App 无需任何额外授权即可直接读写**，
而 daemon 走真实路径访问同一批文件，双方天然互通。

> 这也意味着：**不需要 DocumentViewPicker，用户不需要手动选文件夹。**
> 早期版本用 picker 让用户选目录，但手机上的文件夹选择器是「导航器」——
> 点文件夹只会进入下一层，进入目标目录后界面上**没有任何确认按钮**，流程根本走不通。
> 改用双视角路径后，App 启动即自动连通，零操作。

通信延迟：实测 172–392 ms 往返（含 daemon 50ms 轮询 + App 50ms 轮询 + 命令本身耗时）。

---

## 四、工程结构

```
D:\0\harmony\
├── AppScope/
│   ├── app.json5                  应用级配置（bundleName 等）
│   └── resources/base/element/    app_name 等全局资源
├── entry/
│   ├── build-profile.json5        模块构建配置
│   ├── hvigorfile.ts
│   └── src/main/
│       ├── module.json5           模块配置 + 权限声明
│       ├── ets/
│       │   ├── entryability/EntryAbility.ets
│       │   ├── pages/Index.ets    主界面（5 个 Tab）
│       │   ├── components/
│       │   │   ├── TerminalConsole.ets
│       │   │   └── DaemonStatusCard.ets
│       │   ├── services/
│       │   │   ├── BusClient.ets
│       │   │   └── BusDirManager.ets
│       │   ├── utils/
│       │   │   ├── CommandBuilder.ets
│       │   │   ├── ResponseParser.ets
│       │   │   └── Logger.ets
│       │   ├── model/CommandResult.ets
│       │   └── common/Constants.ets
│       └── resources/base/
│           ├── element/{string,color,float}.json
│           ├── media/app_icon.svg
│           └── profile/main_pages.json
├── build-profile.json5            工程级配置（SDK 版本 26.0.0）
├── hvigor/hvigor-config.json5
├── build.sh                       命令行构建脚本
├── docs/                          技术方案 + Shell 指令全集
../                              仓库根（含 core/daemon.sh、docs/ 等）
```

---

## 五、功能说明

### 5.1 终端指令手册侧边栏

终端页右上角有 **「📖 指令手册」** 按钮，点开从右侧滑出面板：

- **全量收录 274 条** shell 指令，来自 `docs/HarmonyOS-Shell-指令全集.md`
- **三级树状结构**：11 个分类 → 30+ 分组 → 指令项，分类和分组都可折叠
- **实时搜索**：输入关键词（如「截图」「aa」「电池」）即时过滤，
  匹配命令文本 / 说明 / 分组名，搜索时自动展开命中项并显示 `匹配 N / 总数 条`
- **点击填入**：点任意指令 → 自动填入终端输入框并关闭面板，可直接回车执行
- **未验证标记**：指令全集里标 `[未验证]` 的条目会带黄色 `?` 角标

数据来源与生成：

```bash
# 从 markdown 重新生成（改了指令全集后执行）
python scripts/gen-commands-json.py
# 输出到 entry/src/main/resources/rawfile/commands.json
```

生成脚本会过滤掉参数碎片（如 `-A <action>` 这类单独的参数说明），
并用命令白名单校验，确保每个条目都是可执行的完整命令。

### 5.2 内置快捷操作

首页提供分组快捷按钮：

| 分组 | 按钮 | 实现 |
|------|------|------|
| 屏幕控制 | 唤醒 / 熄屏 | `power-shell` |
| 按键模拟 | Home / Back / Vol+ / Vol- / Power | `uinput -K` |
| 系统信息 | 电池 | `@ohos.batteryInfo` 原生 API（hidumper 无数据） |
| | 应用列表 | `bm dump -a` + ResponseParser 解析 |
| | 前台应用 | `uitest dumpLayout` 解析 bundleName |
| | 系统参数 | `param get` + 解析 |

---

## 六、开发进度

| Phase | 内容 | 状态 |
|-------|------|------|
| 1 | 工程骨架 + 文件总线 + 终端控制台 | ✅ 已完成，模拟器端到端验证通过 |
| 1.5 | 终端指令手册侧边栏（274 条 + 搜索 + 树状） | ✅ 已完成并实测 |
| 2 | 首页快捷面板（常亮滑块、截图预览、电源模式、卓易通入口） | 待做 |
| 3 | 应用管理（列表 + 操作菜单） | 待做 |
| 4 | 触控模拟（坐标/滑动/可视化触摸板） | 待做 |
| 5 | 系统信息（热点/内存/CPU 卡片化） | 待做 |
| 6 | 打磨（历史管理、离线引导页、设置页） | 待做 |
| 7 | 跨应用调用（Shizuku 式） | 方案文档已完成，待实现 |

---

## 七、Shell 指令可用性（实测，2026-11-04）

完整报告见 `../docs/Shell指令验证报告.md`。以下是关键结论 —— **输出捕获能力分三类**：

| 类别 | 行为 | 涉及命令 |
|------|------|----------|
| **A 正常捕获** | 有输出，daemon 能拿到 | `id` `date` `param get` `bm dump -a` `bm dump -n` `bm clean -c/-d` `uinput` `snapshot_display` `hidumper --mem/--cpufreq` |
| **B 静默执行** | RC=0 但零输出，**操作确实生效** | `aa start` `aa force-stop` |
| **C 输出走 pty** | 直连能看到，daemon 抓到 **0 字节** | `aa dump -l` `hidumper -s XxxService` |

### 几个必须知道的坑

1. **`aa start` 失败也是 RC=0 + 空输出**
   启动不存在的包时直连能看到 `Error Code:10104001`，但 `$(...)` 抓不到。
   → 执行前必须用 `bm dump -n <bundle>` 校验包存在。

2. **`hidumper -s BatteryService` 零字段**
   只返回 `-----[ability]-----` 和 `---BatteryService---` 两行标题。
   → 电池改用 `@ohos.batteryInfo` 原生 API（已实现 `BatteryReader`）。

3. **`aa dump -l` 完全抓不到**
   输出绕过 shell 所有重定向（管道、`$()`、`>file`、fd2 全是 0 字节）。
   → 改用 `uitest dumpLayout` 落盘后读 JSON 里的 `bundleName`（已实现，1402 ms）。

4. **`bm dump -a` 格式是 `\t包名`，不是 `bundleName:`**
   原解析正则完全失效，返回空数组。→ 已修复，实测解析出 64 个应用。

5. **`snapshot_display` 无法写 hmdfs 目录**
   `error: fileName ... invalid, realpath nullptr!`（RC=255）。
   → 截图改走 `@ohos.screenshot.capture()`（`CUSTOM_SCREEN_CAPTURE` 权限为 normal+user_grant）。

6. **所有输出都是 CRLF 行尾**
   → 解析前必须 `trim()` / 去 `\r`。

### 卓易通

模拟器**没有安卓容器**（`bm dump -a | grep -ci android` = 0），
相关穿透命令（`aa start -b com.android.settings ...`）无法在此环境验证，需真机。

---

## 六、已知限制

1. **daemon 需手动部署**，且被系统回收后要重新启动（Phase 6 会加离线引导页）
2. **目录授权可能失效**：App 重装或权限被回收后需重新授权
3. **绝对路径不可用**：`BusClient` 默认的 `DEFAULT_BUS_DIR` 只是逻辑默认值，
   实际运行时会被 `BusDirManager` 拿到的 URI 覆盖
4. **未签名的 HAP 装不上真机**，必须在 IDE 里配自动签名
5. **卓易通相关命令未完全验证**，见 `../docs/HarmonyOS-Shell-指令全集.md` 的 `[未验证]` 标注

---

## 七、模拟器调试（实测记录 2026-11-04）

比真机更方便：**模拟器不需要配置签名**，`hdc install` 直接装未签名 HAP 即可。

> 官方原文：「在大多数情况下，模拟器上推包调试不需要签名，但部分 Kit 仍需签名后才能正常运行。」
> 本项目只用到 CoreFileKit / ArkData / AbilityKit 等基础 Kit，实测**未签名安装成功**。

### 7.1 启动模拟器

```bash
# 环境：Mate 70 Pro+ / HarmonyOS 7.0.0 / API 26 / x86_64
"/d/DevEco Studio/tools/emulator/Emulator.exe" \
  -hvd "Mate 70 Pro+" -path "E:/Emulator" -imageRoot "E:/Emulator"
```

**内存要求**：宿主机 8 GB 跑 4 GB RAM 的模拟器会因「提交电荷不足」直接启动失败
（日志 `CheckRuntimeEnv.cpp: "Commit charge is not enough!"`）。

已把模拟器降到 **2 GB**（`E:/Emulator/Mate 70 Pro+/config.ini` 里 `hw.ramSize=2048`），
同时尽量关掉其他占内存程序（IDE、微信等）。启动后宿主机可用内存建议保持 ≥1.5 GB。

### 7.2 连接 hdc（关键：不会自动发现）

模拟器的 hdc 走 TCP，`hdc list targets` 初始返回 `[Empty]`，**必须手动连**：

```bash
HDC="/d/DevEco Studio/sdk/default/openharmony/toolchains/hdc.exe"
"$HDC" tconn 127.0.0.1:5555      # 输出 Connect OK
"$HDC" list targets               # 输出 127.0.0.1:5555
```

> Git Bash 下所有远程路径都要加 `MSYS_NO_PATHCONV=1`，否则 `/data/...`
> 会被 MSYS 改写成 Windows 路径导致 `file send` 失败。

### 7.3 装包 / 起 App / 截图

```bash
"$HDC" -t 127.0.0.1:5555 install -r entry-default-unsigned.hap   # 未签名直接装
"$HDC" -t 127.0.0.1:5555 shell "power-shell wakeup"              # 锁屏时先唤醒
"$HDC" -t 127.0.0.1:5555 shell "uinput -T -m 658 2400 658 900 400"  # 上滑解锁
"$HDC" -t 127.0.0.1:5555 shell "aa start -b com.octahedron.hmpriv -a EntryAbility"
"$HDC" -t 127.0.0.1:5555 shell "snapshot_display -f /data/local/tmp/hmpriv/s.jpeg"
```

> 屏幕锁定时 `aa start` 会报 `10106102 The device screen is locked`，先唤醒+解锁。

### 7.4 模拟器的 SELinux 硬限制（重要）

**模拟器上 shell (uid 2000) 无法在用户存储目录创建新文件**，虽然它属于 `file_manager` 组、
目录权限看着是 `drwxrws--x`（组可写）：

```
u:object_r:hmdfs:s0 /storage/media/100/local/files/Docs/Download/HMArkPriv/
touch: Permission denied          # create 被 SELinux 拦截
echo x > 已存在的文件              # write 成功
```

| 操作 | 结果 | 说明 |
|------|------|------|
| `touch Download/x` | ❌ Permission denied | SELinux 禁 create |
| `echo > Download/已存在文件` | ✅ 成功 | write 允许 |
| `mkdir Download/X` | ❌ Permission denied | 同 create |
| 写 `/data/local/tmp` 任意文件 | ✅ 成功 | 唯一完全可写区 |

**绕过办法：用 hdc 预创建文件**（hdc 服务权限高于 shell）：

```bash
# 本地准备好目录（含 cmd.req / cmd.res / status.json）
"$HDC" -t 127.0.0.1:5555 file send HMArkPriv /storage/media/100/local/files/Docs/Download/
```

hdc 建的目录属主 `20001006:file_manager`、权限 `drwxrws--x`，
shell 在 `file_manager` 组 → **之后 daemon 就能自由读写这些已存在的文件**。

### 7.5 daemon.sh 必须是 LF 换行

Windows 上 checkout 的脚本是 CRLF，推到鸿蒙执行会报：

```
daemon.sh[44]: syntax error: unmatched 'if'
```

推送前必须转换：

```bash
tr -d '\r' < ../core/daemon.sh > daemon_lf.sh
"$HDC" -t 127.0.0.1:5555 file send daemon_lf.sh /data/local/tmp/hmpriv/daemon.sh
"$HDC" -t 127.0.0.1:5555 shell "nohup sh /data/local/tmp/hmpriv/daemon.sh >/dev/null 2>&1 &"
```

成功标志：

```bash
"$HDC" -t 127.0.0.1:5555 shell \
  "cat /storage/media/100/local/files/Docs/Download/HMArkPriv/status.json"
# {"framework":"HMArkPriv","status":"ready","pid":6706,"uid":2000}
```

### 7.6 自动化点击（无需人工操作模拟器）

`uitest` 比 `uinput` 可靠（`uinput -T -c` 有时不触发 onClick）：

```bash
"$HDC" -t 127.0.0.1:5555 shell "uitest uiInput click 394 2636"   # 点终端 Tab
"$HDC" -t 127.0.0.1:5555 shell "uitest dumpLayout -p /data/local/tmp/hmpriv/l.json"
"$HDC" -t 127.0.0.1:5555 file recv /data/local/tmp/hmpriv/l.json l.json   # 拉回分析
```

`dumpLayout` 导出的 JSON 含每个控件的 `text` / `bounds` / `clickable`，
可用于精确定位坐标（`bounds=[x1,y1][x2,y2]`，中心点即点击坐标）。

### 7.7 模拟器实测结论（2026-11-04 全部通过）

| 项目 | 结果 |
|------|------|
| 未签名 HAP 安装 | ✅ `hdc install` 直接成功 |
| App 启动 + UI 渲染 | ✅ 5 个 Tab、12 按钮、状态卡片全部正常 |
| Tab 切换 / 快捷命令 chip | ✅ 正常 |
| daemon 以 uid 2000 运行 | ✅ `status: ready, pid: 6706, uid: 2000` |
| **App 零授权直连总线** | ✅ 启动即通，无需 picker、无需权限弹窗 |
| **App → daemon → App 端到端** | ✅ `id` → `uid=2000(shell)`，**172 ms** |
| **第二条命令验证** | ✅ `hidumper -s BatteryService` → 真实电池信息，**392 ms** |
| shell 能力（power-shell/uinput/aa/uitest/snapshot） | ✅ 全部可用 |

**Phase 1 验收标准已达成**：终端输入 `id` 返回 `uid=2000(shell)`。

> 过程中的重要发现：`ohos.permission.READ_WRITE_DOWNLOAD_DIRECTORY` 虽然存在且是
> `normal` + `user_grant`，但在模拟器上 `requestPermissionsFromUser` 返回
> `codes=[2] reasons=[0] dialogShown=[true]`（弹框显示了但授予失败），
> 所以最终没有依赖该权限，而是用 App 沙箱视图路径直接访问 —— 更简单也更稳。

---

## 八、常见问题

| 现象 | 原因 | 解决 |
|------|------|------|
| Sync 失败：找不到 SDK | SDK 路径未配 | `File > Project Structure > SDK` 指向 `D:\DevEco Studio\sdk` |
| 编译报 `compatibleSdkVersion` 格式非法 | API 26 要求 `"26.0.0"` 三段式 | 已修正，勿改回 `"5.0.0(26)"` |
| 命令行 `spawn java ENOENT` | PATH 里的 JDK 路径格式不对 | 用 `./build.sh`（内部用 node 直接跑 hvigorw.js） |
| 终端一直超时 | daemon 没跑 | `hdc shell "sh /data/local/tmp/hmpriv/daemon.sh &"` |
| App 显示 Daemon 离线但 status.json 正常 | App 读的是别的挂载点 | 确认候选路径顺序，`/storage/Users/currentUser/...` 必须排第一 |
| Run 按钮灰色 | 无签名配置 | 真机需要；模拟器可直接 `hdc install` 未签名包 |
| 装不上真机 `install failed` | HAP 未签名 / 手机未授权调试 | 检查签名 + USB 调试授权弹窗 |
| 模拟器启动报「No enough space」 | 磁盘不足（需约 9 GB） | 清理模拟器所在盘 |
| 模拟器启动报「Commit charge is not enough」 | 宿主机内存不足 | 降 `hw.ramSize`，关其他程序 |
| `hdc list targets` 为 `[Empty]` | 模拟器走 TCP 不自动发现 | `hdc tconn 127.0.0.1:5555` |
| `aa start` 报 `10106102 screen is locked` | 模拟器锁屏 | 先 `power-shell wakeup` + 上滑 |
| daemon 报 `syntax error: unmatched 'if'` | 脚本是 CRLF | `tr -d '\r'` 转 LF 后重推 |
| 模拟器 shell 无法在 Download 建文件 | SELinux 禁 create | 用 hdc 预创建目录（见 7.4）；真机无此限制 |

---

## 九、参考文档

- `../docs/HMArkPriv-App-技术方案.md` — 完整技术设计（架构、IPC、页面、6 阶段路径）
- `../docs/Shell指令验证报告.md` — **本次实测的逐条验证结果**（含三类输出捕获能力分析）
- `../docs/HarmonyOS-Shell-指令全集.md` — Shell 指令手册（含 `[官方]`/`[社区]`/`[实机]`/`[未验证]` 四级来源标注）
- `scripts/test-cmds.sh` — 指令验证脚本（通过文件总线批量测试）
- `../docs/ARCHITECTURE.md` — 鸿蒙 7.0 安全机制逆向分析
- `../docs/DEVLOG.md` — 原方案 5 阶段调试日志
- `../docs/screenshots/` — 模拟器实机截图（首页 / 终端页 / 验证通过）

---

_版本 v1.3 | 2026-11-04 | Phase 1 验证通过 + Shell 指令全量实测 | 原仓库：https://github.com/Octahedron-BB/HMArkPriv_
