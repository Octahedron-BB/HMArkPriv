# HMArkPriv 待办清单

> 最后更新：2026-11-05
> 状态标记：`[x]` 已完成 · `[~]` 进行中 · `[ ]` 待开始 · `[?]` 待研究

---

## 一、总体进度

| 阶段 | 内容 | 状态 |
|------|------|------|
| Phase 1 | MVP：文件总线 + daemon + 终端 | ✅ 完成（模拟器 + 真机双验证） |
| Phase 2 | 首页快捷面板 | 🟢 完成约 85%（缺截图/电源模式/容器入口） |
| Phase 3 | 应用管理与深度管控 | 🟢 MVP 就绪（列表/启动/强停/**冻结**/权限透视/清数据/卸载） |
| Phase 4 | 触控模拟 | ⬜ 未开始 |
| Phase 5 | 系统信息 | 🟡 Tab 框架已建（电源与屏幕 + 设备信息入口），卡片化未做 |
| Phase 6 | 打磨与引导 | ✅ 终端连接日志优化、HTML模式退役、文档重构整理 |
| 追加 | 跨应用调用（Shizuku 式） | 🟢 双方案可用；令牌已哈希化、防篡改；**但无法验证调用方身份**（见第八章） |

**代码规模**：ArkTS 约 5918 行 / 19 个文件；指令手册收录 292 条（11 个分类）。

---

## 二、待研究（有明确线索）

### [?] 容器内安卓应用的**批量**包名列表

**现状**：11.2 要启动容器内应用必须同时给「包名 + Activity 名」，目前只能**逐个**获取
（`hilog` 抓 `StartAbility 包名/Activity名`，或 `uitest dumpLayout` 读前台 `bundleName`）。
缺一个「一次列出容器内全部已装应用及其包名」的方法。

**已排除的路径**（都实测过，别再试）：

| 路径 | 结果 |
|------|------|
| `bm dump -a` / `bm dump -n <安卓包>` | 容器包不在鸿蒙 bm 里，报 not found |
| `aa dump -a` / `aa dump -l` | 真机上分别是空输出 / 走 pty 抓不到 |
| `/data/virt_service/rgm_hmos/anco_hmos_data` | `ls` 都 Permission denied（shell + hdc 都被拒） |
| `hdc smode` 提权 | `Cannot set root run mode in undebuggable version` |
| `hdc shell -b <bundle>` | `E003001 Invalid bundle name` |
| `/proc/<pid>/cmdline` 遍历 | 容器进程在宿主 PID namespace 里不可见 |
| 容器内应用列表页 / AppInfo 页 | 界面只显示中文名，不打日志、不给包名 |
| 卓易通 App「应用信息」页 | 只有版本号 / 权限，无包名 |
| `aa start -U package:<包名>` | 隐式匹配必然失败（10103101），`-a` 不能省 |

**待验证的线索**（来自老文档 `docs/DEVLOG.md` 第 72 行）：

> 该目录在卓易通 (`com.droi.tong`) / 出境易 (`com.easy.hmos.abroad`) 容器内
> 自动挂载于 `/sdcard/MyHarmonyOSDevice/Download/HShizuku/`

即**容器内 `/sdcard` 与宿主 `Download/` 是同一批文件的双向挂载**。据此有两条思路：

1. **容器内执行 → 写共享目录 → 宿主读回**
   在容器里跑 `pm list packages`（或读 `/data/system/packages.list`），
   结果写到共享目录，宿主侧用 App 直接读文件即可。
   问题：容器内需要一个能执行命令的载体（终端 App / 自动化工具），
   属于「用户自己在容器里跑一次」的方案，不能全自动。
2. **宿主侧找容器管理接口**
   宿主上跑着 `isulad` / `rgm_manager` / `anco_service_broker` / `bms_broker`，
   `bindfs` 也把容器部分数据挂到了宿主路径。可能存在一个能用 uid 2000 调用的
   broker 接口或可读的容器包管理数据库（`/data/virt_service/...` 之外的路径）。

> **用户提示**：「宿主机对卓易通、出境易这种虚拟机是有很高的权限的，所以都能获取的到，
> 当时 KDE、短信转发器的包名就是这样获取的」——说明曾有可行方法，只是记录没留下来。

**下一步**：`ps -ef` 看 `bms_broker` 的挂载与 fd，翻 `/proc/<pid>/maps`、
`mount | grep virt_service`，确认宿主侧到底能读到容器哪些数据。

---

## 三、Phase 2：首页快捷面板（剩余 30%）

- [x] Daemon 状态卡片（在线状态、UID、往返延迟）
- [x] 部署引导（三步说明）
- [x] 屏幕控制：唤醒 / 熄屏
- [x] 按键模拟：Home / Back / Vol+ / Vol- / Power
- [x] 系统信息：电池 / 应用列表 / 前台应用 / 系统参数（各有专用实现）
- [x] 最近执行结果预览
- [x] **充电时不熄屏开关**（2026-11-05 重做，位置已移到「系统」Tab，见下方说明）
- [x] 「系统」Tab 框架（电源与屏幕 / 设备信息 / 最近结果）
- [ ] **屏幕常亮滑块**：拖动选择 5min / 10min / 30min / 1h / 2h / 永久
      → `power-shell timeout -o <ms>`，`-r` 复位
- [ ] **截图预览**：`snapshot_display -f` 落到总线目录 → 读回显示缩略图
      （注意：写 hmdfs 会 `realpath nullptr`，需落到 `/data/local/tmp/` 再搬）
- [ ] **电源模式切换**：`power-shell setmode`（节能/均衡/性能，需标注实际语义未确认）
- [ ] **容器入口卡**：检测到卓易通/出境易时，一键直达通知使用权页

> **Tab 重新分工（2026-11-05）**：电源策略属于系统级设置，不属于高频快捷操作，
> 因此「充电时不熄屏」从首页移到「系统」Tab。首页的「系统信息」区也相应改名
> 「应用信息」（只留应用列表 / 前台应用），电池 / 系统参数 / 内存 / CPU 频率
> 全部归到「系统」Tab，避免同一功能出现在两处。

### 充电时不熄屏：为什么重做（2026-11-05）

**旧实现为什么坏**（现象：一直常亮、关开关也不灭、拔了充电器还亮）：

1. **充电状态取不到**。旧代码用
   `hilog -x -T BatteryInfo | grep pluggedType`，但实测真机 hilog 里
   **根本没有 `pluggedType` 这个字段**（`hilog -x | grep pluggedType` 恒为空），
   `/sys/class/power_supply/` 也被 SELinux 拒绝（Permission denied）。
   于是条件永远不成立，开关开了也不生效。
2. **状态变量存在内存里**。`IS_KEEPING_AWAKE` 是 daemon 的 shell 变量，
   daemon 一重启就归零。如果之前设过 24 小时常亮，重启后再也不会执行 `-r` 恢复。
3. **开关默认 true**。用户没主动开也显示"已开启"。

**现在的设计**：

- 充电状态由 **App 用 `@ohos.batteryInfo` 读取**（实测唯一可靠来源），
  每 3 秒写入 `config.json` 的 `charging` + `heartbeat`
- daemon 只做幂等判断：`stayAwakeWhileCharging && charging && 心跳未过期`
  → 需要常亮就 `-o 86400000`，不需要就 `-r`，不猜任何东西
- **心跳超 60 秒**视为 App 已不在前台，不再维持常亮（防"幽灵常亮"）
- **daemon 启动时无条件执行一次 `power-shell timeout -r`**，
  清理上一次被 kill -9 留下的残留
- 开关默认 **false**

**验证方法与一个坑**

要确认"当前是否真的常亮"，只能靠 `power-shell timeout -r` 的返回值反推：
无 override 时打印 `Restore screen off time failed`，有 override 时打印
`Restore screen off time`。`hidumper -s PowerManagerService` 在 shell 权限下
零字段，`param get` 里也没有屏幕超时项，**没有非破坏性的读法**。

这意味着：**探测本身会清掉 override**，所以测完必须重新施加，
否则 daemon 内的 `IS_KEEPING_AWAKE` 仍是 1，会误以为"已经开着"而不再施加。

另一个坑：**测试时必须先 `aa force-stop` 停掉 App**。App 每 3 秒把真实充电状态
写回 `config.json`，手工注入的测试值（比如 `charging:false`）会在 3 秒内被覆盖，
表现为"所有场景都常亮"的假失败。这也说明 App 是唯一事实来源，设计是对的。

**五个场景已真机实测**（每个场景前重启 daemon，确保 `IS_KEEPING_AWAKE` 从 0 开始）：

| 场景 | 期望 | 实测 |
|------|------|------|
| 开关关 + 充电 | 不常亮 | ✅ 无 override |
| 开关开 + 充电 + 心跳新鲜 | 常亮 | ✅ 有 override |
| 开关开 + 未充电 | 不常亮 | ✅ 无 override |
| 开关开 + 充电 + 心跳过期 300s | 不常亮 | ✅ 无 override |
| 设常亮后 kill -9，重启 | 自动清理 | ✅ 无 override |

**已知限制**：App 切后台后心跳停止，60 秒后不再维持常亮。
要真正做到"后台插电即常亮"，需要长时任务权限，而鸿蒙的长时任务类型里
没有「保持屏幕常亮」这一类，属于系统限制。

---

## 四、Phase 3：应用管理与深度管控（MVP 已完成 · 持续迭代）

> **核心定位**：打破普通系统设置的黑盒限制，利用 UID 2000 提权实现「极速应用透视 + 权限智能透视 + 智能动态启动 + 预装免Root卸载 + 深度清空 + 进程彻底灭杀」。

### 1. 应用概览与极速清单（App List）✅
- [x] **150ms 极速全量应用列表获取**：
      - 调用 `bm dump -a -l`，一次性提取全量应用的 `bundleName` 和中文 `label`。
      - 本地缓存元数据，支持全量搜索（中文名称、拼音、包名模糊匹配）。
- [x] **多维分类筛选器**：
      - `全部 (223)` / `用户应用 (71)` / `系统预装 (152)` 动态计数与响应式切换。
- [x] **运行状态与资源指示**：
      - 对齐 `ps -ef` 进程列表，在应用卡片上实时标明「活跃（绿色小圆点）」与弹窗活跃状态感知。

### 2. 权限透视与系统直达（Permission Inspector）✅
- [x] **权限全景智能分类**：
      - 提取 `reqPermissions` 与 `reqPermissionStates`，精确区分：
        - 🔵 **`[可修改]`（用户动态权限 User_Grant）**：定位、相机、录音、剪贴板、日历、媒体读写等。
        - ⚪ **`[系统默认]`（系统权限 System_Grant）**：网络通信、Wi-Fi、震动等安装即授权能力。
      - 真实状态：高亮呈现 `✅ 已允许` 与 `❌ 未允许`。
- [x] **系统设置直达**：
      - 一键打开系统设置中该应用的专属设置页（权限/通知/存储直达）。
- [x] **权限一键重置**：
      - 调用 `atm perm -r -b <bundleName>`，一键撤销全部动态授权。

### 3. 应用操作与深度控制（Control & Clean）✅
- [x] **智能动态启动应用**：
      - 自动解析目标应用真实的 `mainAbility`（如 Canva 的 `EditorAbility`，梅斯医学的 `MedSciAbility`，WPS 的 `DocumentAbility`），支持多 HAP 穿透。
- [x] **真·杀后台**：
      - 调用 `aa force-stop <bundleName>`，彻底杀灭进程组及附属的 ServiceExtensionAbility，实时刷新活跃状态。
- [x] **彻底清空数据（破除系统设置置灰限制）**：
      - 调用 `bm clean -d -n <bundleName>`，直接擦除 `el1` 与 `el2` 下的私有数据库与键值存储，带二次确认防误触。
- [x] **清理应用缓存**：
      - 调用 `bm clean -c -n <bundleName>`。
- [x] **免 Root 卸载应用**：
      - 调用 `bm uninstall -n <bundleName> -u 100`，带二次确认弹窗。
      - ⚠️ **只对第三方应用有效**，系统应用会失败，详见 §3.1。
- [x] **全息元数据导出**：
      - 原始代码容器查看 `bm dump -n` 完整数据。

#### 3.1 为什么系统应用卸载不了（实测，2026-11-05）

用户实测卸载「未成年人模式」（`com.huawei.hmos.minorsprotection`）失败，排查结论：

```bash
bm uninstall -n com.huawei.hmos.minorsprotection -u 100
→ code:9568380
  error: uninstall system app error.
```

**根因是 `appDistributionType`，不是 `isRemovable`**：

| 字段 | 值 | 说明 |
|------|-----|------|
| `appDistributionType` | **`os_integration`** | **系统镜像集成**，这是拒绝卸载的真正原因 |
| `userInfo.isRemovable` | `true` | 这个字段虽然为 true，但不起决定作用 |
| `appProvisionType` | `release` | 正式发布包 |

对照第三方应用：`nansheng.software.nextzhongduan` 是 `app_gallery`，可正常卸载。

**`os_integration` 的含义**：应用打包在系统镜像里，不是通过安装器装进去的。
BMS 认为这类包属于系统本身，删除它等于破坏系统完整性，因此一律拒绝。

**试过的所有变体都失败**：

| 命令 | 结果 |
|------|------|
| `bm uninstall -n <pkg> -u 100` | 9568380 |
| `bm uninstall -n <pkg> -k -u 100`（保留数据） | 9568380 |
| `bm uninstall -n <pkg>`（不指定用户） | 9568380 |
| `bm uninstall -n <pkg> -u 0` | 304 user does not install the hap |
| `strings /system/bin/bm` 查隐藏参数 | 无强制卸载选项 |

**但系统应用在别的操作上是放行的**（这是重要的能力边界）：

| 操作 | 系统应用 | 结果 |
|------|---------|------|
| `bm clean -d`（清数据） | ✅ | clean bundle data files successfully |
| `bm clean -c`（清缓存） | ✅ | clean bundle cache files successfully |
| `aa force-stop`（强停） | ✅ | force stop process successfully |
| 看门狗冻结 | ✅ | 生效（该应用平时本就不常驻，需先手动启动才能观察到） |
| `bm uninstall`（卸载） | ❌ | 9568380 |

**结论与产品建议**：

- 系统应用**不预先禁用卸载按钮** —— 实测有些系统应用能卸、有些不能，
  一律放行让用户试，失败时给明确原因，比直接禁掉按钮更有用
- 判断依据不是 `isRemovable`（该字段会误导），而是实际执行结果
- 想"废掉"系统应用，**冻结才是可行路径**（本项目的看门狗冻结对系统应用有效）
- 「未成年人模式」这类应用平时不常驻，冻结的实际意义是"防止它被意外拉起"

#### 3.2 ⚠️ 重要坑：bm 命令失败时 RC 仍为 0

这是做卸载反馈时发现的**会导致谎报成功的严重问题**：

```bash
# 卸载系统应用失败
bm uninstall -n com.huawei.hmos.minorsprotection -u 100
→ RC:0                          ← 退出码是 0！
  error: failed to uninstall bundle.
  code:9568380
  error: uninstall system app error.
```

`bm` 系列工具**用输出文本表达失败，不用退出码**。因此
`CommandResult.success`（等于 `exitCode === 0`）对 bm 命令完全不可靠，
直接用会把失败当成功提示给用户 —— 界面显示"已成功卸载"，实际没卸掉。

**已做的修正**（`ResponseParser.isBmFailure` + `explainBmError`）：

- 失败判定：输出含 `error: failed to` 或 `code:数字`
- 错误翻译：
  - `9568380` → 系统镜像集成应用，无法卸载，建议改用冻结
  - `9568386` → 设备上找不到该应用
  - `9568289` → 签名/权限校验未通过
  - 未收录的错误码 → 回显 code 与 error 原文，不猜
- 卸载成功后再用 `bm dump -n` **复核一次**（不再只信命令输出）
- 权限重置（走 `atm`，输出捕获不到）改为提示"已发起，请到「查看权限」确认"，
  不谎报"已重置"

**受影响的命令**（都走 bm，都有这个特性）：
`bm uninstall` / `bm clean -d` / `bm clean -c` / `bm dump -n`

> 判定的 8 个用例已用脚本验证：成功卸载、系统应用失败、应用不存在、
> clean 成功/失败、dump 不存在、空输出、普通输出，全部判断正确。

> 另：`bm dump -n <已安装应用>` 的输出（实测 75KB）里不含 "failed" / "not found"
> 字样，所以这两个词作为失败特征是安全的，不会误判。

### 4. 冻结 / 冷宫（Freeze · 看门狗方案已实装）

> **[2026-11-05 实测]** 鸿蒙 7.0 消费者版没有可用的「停用应用」能力，
> 做不到「和没装一样」（四条路径全封死，见 §4.1）。
> 因此改为「看门狗冻结」：**持续强杀**来模拟冻结效果。

- [x] **强停**：`aa force-stop <bundleName>`，实测杀后 60 秒内不会被系统自动拉起
- [x] **看门狗冻结**（2026-11-05 实装，真机验证通过）：
      - daemon 每约 2 秒扫一次 `ps -ef`，命中冻结名单即 `aa force-stop`
      - 名单存总线目录 `frozen.txt`，一行一个包名，`#` 开头为注释
      - App「应用」页操作面板新增「❄️ 冻结应用 / 🔥 解冻应用」
      - 卡片上显示「❄ 已冻结」徽章
      - 每次拦截写入 `audit.log`（`FREEZE | RC:0 | force-stop <包名>`）
- [ ] 冻结列表独立管理页（当前只能逐个应用操作，没有"冻结了什么"的汇总视图）
- [ ] 拦截次数展示（`audit.log` 有记录，UI 还没读）

#### 4.0 看门狗冻结：实测行为与边界

**效果对照用户期望**：

| 期望 | 看门狗能做到吗 | 实测 |
|------|--------------|------|
| 不能被唤醒 | 🟡 能唤醒，但最长活 2 秒 | ✅ `aa start` 返回成功，4 秒后进程为 0 |
| 不能被其他程序检测到 | ❌ 包仍在，`bm dump` 查得到 | — |
| 不能被拉起 | ❌ 能拉起（只是活不久） | ✅ 同上 |
| 不能后台运行 | ✅ | ✅ 起来即被杀 |

**关键实测记录**：

```
# 冻结后手动拉起
aa start -b <包名> -a EntryAbility   → start ability successfully.
启动后 1 秒进程数: 1                   （确实起来了）
4 秒后进程数: 0                        （被 daemon 杀掉）

# 解冻后
aa start → 5 秒后进程数: 1             （正常存活，不再被杀）
```

**安全边界（都实测过）**：

| 场景 | 结果 |
|------|------|
| 冻结前缀 `com.huawei`（非完整包名） | 33 个 `com.huawei.*` 进程**无一被杀** —— `grep -qxF` 精确匹配生效 |
| 把 `com.octahedron.hmpriv` 自己写进名单 | App **依然存活**，审计日志 0 条 —— daemon 内 `FREEZE_SELF` 判断 + App 侧 `addFrozen` 双重拦截 |
| 名单为空 | 零开销（`[ -s ] \|\| return 0` 直接返回） |

**性能**：

- `ps -ef` 单次实测约 **100ms**（300+ 进程），是主要成本
- 频率定 2 秒（40 次循环）而非 1 秒：1 秒约 10% CPU，2 秒约 5%
- 实测对比：空名单 30 秒 +395 jiffies，1 个冻结包 +379 jiffies —— 差异在噪声内
- daemon 本身有约 13% 基线开销（来自槽位轮询，与冻结无关）

**为什么不用 `pidof`**：单次 60ms 但需逐包调用，名单 5 个包就是 300ms/轮，
不如一次 `ps` 快照（100ms 与包数无关）可扩展。

#### 4.0.1 微信实测：保活策略能不能扛住

微信（`com.tencent.wechat`）是典型的强保活应用，用来压测最合适。
它在鸿蒙上有 **4 个进程**：

```
com.tencent.wechat                        主进程
com.tencent.wechat:Native_libxwebcore0     WebView 内核
com.tencent.wechat:Native_libxwebcore1     WebView 内核
com.tencent.wechat:remoteNotification      推送保活（关键）
```

**结论：完全压制住了，而且比普通应用更快。**

| 场景 | 结果 |
|------|------|
| 写入冻结名单后 10 秒 | 4 个进程全部为 0 |
| 持续观察 60 秒 | 进程数恒为 0，**没有一次复活** |
| 模拟用户点图标（`aa start`） | 返回成功，但 **1 秒内**进程就被清零 |
| 清除名单后重新启动 | 3 个进程正常恢复（首次启动稍慢，约 8 秒） |

对比 NEXT Device（普通应用）需要约 4 秒被杀，微信反而更快 ——
说明它没有特殊到能绕过 `aa force-stop` 的保活手段。

**开销收益对比**：

| 项 | 数据 |
|----|------|
| 微信正常运行 30 秒的 CPU | **604 jiffies**（约 20% 单核，主要来自 `:remoteNotification`） |
| 冻结后 30 秒的 CPU | **0**（进程根本不存在） |
| daemon 冻结微信时 60 秒增量 | +755 jiffies |
| daemon 空名单时 60 秒增量 | +725 jiffies |
| **差值** | +30 jiffies（约 0.5%，在噪声内） |

**这组数据说明两件事**：

1. **冻结的收益远大于成本**。微信静置就要吃掉 20% 单核，
   冻结它省下的算力是 daemon 轮询开销的几十倍。
2. **daemon 的轮询成本被高估了**。之前测出 daemon 有约 13% 基线开销，
   但那来自槽位轮询（主循环 50ms 一次），**不是冻结功能带来的** ——
   冻结在名单为空时直接 `[ -s ] || return 0`，零成本；
   有名单时每 2 秒一次 `ps`，增量已淹没在测量噪声里。

> **注意**：微信冻结后收不到任何消息（推送进程也死了）。
> 这是设计使然 —— 冻结就是"彻底不让它跑"，与"静默后台"是互斥的。

#### 4.1 为什么真正的「停用」不可行（实测证据）

| 路径 | 实测结果 |
|------|---------|
| `bm disable -n <包名>` | `'disable' is not a valid bm command` |
| `bm enable` | 同上 |
| `strings /system/bin/bm` | **有** `RunAsDisableCommand`、`'bm disable -n'` 等字符串 —— 实现编译进去了，但命令分发表未注册（华为主动关闭入口） |
| 系统设置应用详情页 | 只有「卸载」「强行停止」和各项权限开关，**没有停用按钮** |
| `/sys/fs/cgroup/freezer/` | `Permission denied` |
| `hidumper -s BundleMgr` | 零字段输出 |
| `hidumper -s ApplicationManagerService` | 零字段输出 |
| `param set` | `errNum 1001`（无权限） |

补充观察：
- `bm dump -n` 的 `userInfo.bundleUserInfo` 里确实有 `"enabled": true` 字段 ——
  说明**底层数据模型支持停用**，只是没有对外入口
- 设置应用自身持有 `ohos.permission.CHANGE_ABILITY_ENABLED_STATE`（这就是它能停用的前提），
  但 shell（UID 2000）没有该权限，也没有对应命令

#### 4.2 EDM（企业设备管理）路线 —— 卡点不在资质审核，而在证书与受限权限

原计划让 App 声明 `EnterpriseAdminExtensionAbility`、通过 `edm enable-admin`
激活设备管理员，再调用 `@ohos.enterprise.applicationManager` 的禁用名单 API。

**实测**（2026-11-05）：

```bash
# 只给包名
edm enable-admin -n com.octahedron.hmpriv
→ error: -a <ability-name> is expected.        # 必须指定扩展能力类名

# 给一个不存在的能力类名
edm enable-admin -n com.octahedron.hmpriv -a FakeAbility
→ error: the administrator ability component is invalid.
  errorCode: 9200003                            # 能力组件不存在，直接拒绝
```

即：**没有真的 `EnterpriseAdminExtensionAbility` 组件就激活不了**，
不存在"绕过"的可能。（先前记录写"静默返回"，是因为 shell 里的 `echo RC=$?`
掩盖了错误输出，实际是报错。已更正。）

**官方要求的资质清单**（查 MDM Kit 开发指南确认）：

| 环节 | 要求 |
|------|------|
| 开发者账号 | 必须**注册成为企业开发者**（个人开发者不适用） |
| 证书 | 申请**MDM 专用证书 + Profile**，普通调试证书无效 |
| 权限 | MDM 权限属 `system_basic` 级受限 ACL，需 AGC 审核（约 3 个工作日） |
| 权限声明时机 | 必须在申请证书和 Profile 时一并申请，事后补不了 |
| 安装位置 | 必须装在首用户（账户 ID 100）下 |
| 数量限制 | 同一设备只能激活**一个**超级设备管理应用 |
| 商用 | 还需走「企业 MDM 应用商用申请」 |

**结论**：资质清单看着吓人，但真正致命的是最后一条——
限制性权限必须随 MDM 证书的 Profile 授予，普通调试证书拿不到。
（下一节的实测验证了这一点：激活能过，权限过不了。）

#### 4.2.1 亲自实测：组件能加、能激活，但拿不到能力（2026-11-05）

为了确认「只自己用、不分发」能否绕过资质限制，做了一次完整实验：
临时加上 `EnterpriseAdminExtensionAbility`，构建安装，再尝试激活并调用 API。

**结论：可以激活，但激活是个空壳 —— 没有任何管理能力。**

| 步骤 | 结果 | 证据 |
|------|------|------|
| ① SDK 支持 | ✅ | `sdk/default/openharmony/ets/kits/@kit.MDMKit.d.ts` 存在，`EnterpriseAdminExtensionAbility` 可 import |
| ② 写组件并编译 | ✅ | 继承基类、`module.json5` 加 `"type": "enterpriseAdmin"`，编译通过 |
| ③ 安装 | ✅ | 组件注册成功，`bm dump` 可见 `extensionTypeName: enterpriseAdmin` |
| ④ **激活为超级管理员** | ✅ **成功** | `edm enable-admin -n com.octahedron.hmpriv -a EnterpriseAdminAbility -t super` → `enable-admin success.` |
| ⑤ 回调是否真触发 | ✅ **触发** | 日志：`JsEnterpriseAdminExtension::CallFunction(onAdminEnabled), success` + 自己的 `onAdminEnabled` 日志；进程 `com.octahedron.hmpriv:enterpriseAdmin` 真实存在 |
| ⑥ **调用管理 API** | ❌ **201 拒绝** | `getDisallowedRunningBundlesSync` → `code=201 Permission verification failed`；`isByodAdmin` 同样 201 |
| ⑦ 声明所需权限后重装 | ❌ **装不上** | 加 `ohos.permission.ENTERPRISE_MANAGE_APPLICATION` 后安装直接失败：`code:9568289 install failed due to grant request permissions failed` |

**为什么**：`ENTERPRISE_*` 系列权限属于 `system_basic` 级 + 受限 ACL，
必须在 MDM 专用证书的 Profile 里授权。普通调试证书拿不到，
所以一声明就安装失败（校验发生在安装期，不是运行期）。

**这意味着**：
- 「只自己用、不分发」**不能**绕过资质限制 —— 限制来自证书和权限，与分发无关
- 缺 MDM 证书 → 装不上带权限的包 → 调用 API 必然 201
- 即使激活成功，也只是「挂了个管理员头衔」，一个管理动作都做不了

**副作用与清理**：`edm enable-admin` 会占用「全机唯一超级管理员」名额。
实验后已用 `edm disable-admin` 解除，组件代码与 `module.json5` 改动已全部回滚，
App 功能恢复正常。激活/解除可反复进行，`onAdminDisabled` 回调同样正常触发。

**如果将来想重试**，完整步骤是把上面 ①③④ 重做一遍（约 40 行代码），
但除非拿到企业 MDM 证书，⑦ 依然是死路。

#### 4.2.2 验证「重新自动签名能否补上权限」——不能（2026-11-05）

有一种设想：在 `module.json5` 里声明 `ENTERPRISE_MANAGE_APPLICATION`，
然后让 DevEco 重新自动签名，AGC 或许会把它加进 ACL。**实测否定。**

步骤：临时声明该权限 + 加回扩展能力 → 用户在 DevEco 重新自动签名 → 解析新 `.p7b` → 构建 → 安装。

| 环节 | 结果 |
|------|------|
| 证书重新生成 | ✅ 时间戳从 10:00:27 变为 **10:03:57**，确实是新签的 |
| `allowed-acls` 是否包含目标权限 | ❌ **没有**。仍是 `[FILE_ACCESS_PERSIST, READ_WRITE_DOWNLOAD_DIRECTORY]` |
| `apl` | ❌ 仍是 `normal` |
| `app-feature` | ❌ 仍是 `hos_normal_app` |
| 构建 | ✅ BUILD SUCCESSFUL（签名环节不拦） |
| 安装到设备 | ❌ `code:9568289 grant request permissions failed`，与之前完全一致 |

**结论**：AGC 在签发 profile 时会按账号类型和应用类型**静默过滤**掉超出等级的权限，
不会报错，只是不写进 ACL。签名能过、装不上 —— 拦截点在设备端安装校验。

这也解释了为什么之前那份 profile 只带 2 个 ACL 权限：
它们都是 `availableLevel: normal`，与 `apl: normal` 匹配，所以被放行。

**要改变结果只有一条路**：把 AGC 上的应用类型从普通应用改为 MDM 应用，
这需要企业开发者账号 + 资质审核，不是靠重新签名能绕过的。

（实验后已回滚：`module.json5` 与组件代码还原，重新构建安装，App 恢复正常。）

**再退一步：就算拿到证书，API 效果也存疑**

MDM Kit 里对应的接口是 `applicationManager.addDisallowedRunningBundlesSync`
（把应用加入「运行黑名单」）。开发者社区有反馈：
调用返回成功、`getDisallowedRunningBundlesSync` 也能读回名单，
**目标应用却仍然能正常运行**，该问题未见官方结论。

所以资质只是第一道门，后面还有「API 是否真的拦得住」这个未知数。
要验证得先有证书，鸡生蛋问题。

#### 4.3 对照用户期望

| 期望 | 看门狗冻结 | 卸载 |
|------|-----------|------|
| 不能被唤醒 | 🟡 唤醒后 3 秒内被杀 | ✅ |
| 不能被其他程序检测到 | ❌ 包仍在 | ✅ |
| 不能被拉起 | ❌ 能拉起（活不久） | ✅ |
| 不能后台运行 | ✅ | ✅ |
| 可恢复 | ✅ 随时解冻 | ❌ 无法恢复（HAP 备份不出来） |

结论：要「像没装一样」只能卸载；要「可逆地废掉它」只能用看门狗冻结。

### 5. 电池与电源策略深度联动（Battery & Power）

#### 5.0 充电常亮：最终方案（2026-11-05 四次迭代后定稿）

**方案演进**

| 方案 | 结果 | 问题 |
|------|------|------|
| `runningLock` + `RunningLockType.BACKGROUND` | **完全无效** | 语义搞反了 → API 10 起废弃 → 三方无 SCREEN 类型 |
| `window.setWindowKeepScreenOn()` | 生效但范围不对 | 窗口级，切后台即失效 |
| `hidumper -a -t`（PowerMgrKeepOnLock） | 生效、不污染设置 | **能上锁但解不掉**（见 §5.0.4） |
| `power-shell timeout -o` + daemon 执行/记账 | ✅ **采用** | 唯一难点是状态回读，已解决 |

**为什么不用 SCREEN 锁（实测数据）**

- 三方 API 层拿不到：`@ohos.runningLock` 只有 `BACKGROUND` / `PROXIMITY_SCREEN_CONTROL` /
  `BACKGROUND_USER_IDLE`，**没有 SCREEN**。
- 唯一入口是 `hidumper -s PowerManagerService -a -t`，实测：
  - 持锁时 `Timeout=60000ms`（**无 OverrideTimeout**），静置 90 秒仍 AWAKE ✅
  - 持锁时系统设置页「休眠」仍显示「1 分钟后」→ **确实不污染设置**
  - 但**无 tty 时 `-f` 释放不了**（连续 3 次全失败，带 tty 一次成功）
  - daemon 恰恰没有 tty → 「能上不能下」，泄漏即永久
- `timeout` 反而更干净：`-o` **完全不碰锁表**（实测 SCREEN 始终 0）。

**为什么是 10 分钟而不是 24 小时**

实测两条性质，决定了短值 + 续期是更安全的做法：

1. **override 的值是真实的超时上限**
   `-o 120000` → 静置 150 秒 → `SLEEP`（不是"设了就永不熄"）
2. **重复设置会重置空闲计时器**
   `-o 120000` 每 60 秒续一次，连续 4 分钟始终 `AWAKE`

于是：值 10 分钟、每 5 分钟续期 → daemon 活着就永不过期；daemon 一死，**最多多亮
10 分钟自愈**。24 小时的旧值没有这个自愈能力，那正是"幽灵常亮"的来源。

**daemon 自己判断充电（关键改进）**

App 的充电轮询在 `onPageHide` 就停了 —— 实测切后台后 `heartbeat` 立刻冻结
（75 秒纹丝不动）。如果照 App 最后一次上报的"正在充电"一直亮，用户拔线后没人
通知 daemon，屏幕就会亮到 override 过期。

所以 daemon 自己读充电状态。可用数据源只有 hilog：

| 数据源 | 结果 |
|--------|------|
| `/sys/class/power_supply` | Permission denied |
| `hidumper -s BatteryService -a -i > f` | **158 字节，只有表头**（非 tty 截断） |
| `powermgr/BatteryInfo` 日志 | ✅ `capacity=..., pluggedType=2, ...` |

`pluggedType=0` 即未插电。日志是事件驱动（插拔才打），但缓冲区实测跨 20 天不滚动，
足够可靠；读不到时退回 App 上报的 `charging` 字段。

**定时任务的时间基准**

主循环是 `sleep 0.05`，但每轮还要做文件探测、槽位扫描，实测一轮远不止 50ms。
最初用"计数 × 50ms"推算周期，结果换算成 30 秒的探测实际要一分多钟才触发。
**改用 `date +%s` 直接比真实秒数**（每 20 轮取一次时间，三个任务共用），才对齐。

| 任务 | 周期 | 说明 |
|------|------|------|
| 探测 | 30s | 一次 `hilog -x` 同时拿屏幕亮灭 + 充电状态 |
| 决策 | 10s | `开关 && 充电` → 开，否则 → 关 |
| 续期 | 5min | 只在 override=1 时重发 `-o` |

**状态文件 `screen_state.txt`（App 直读）**

```
override=0|1
timeout=<毫秒>
screen=on|off|unknown
charging=yes|no|unknown
ts=<秒>
```

**内部命令（走同一套总线协议）**

- `__hmpriv_screen_on` / `_off` / `_status`
- App 打开开关时用它拿即时反馈，之后由 daemon 的决策循环接管

**实测（真机 33Z0224430072393）**

| 场景 | 结果 |
|------|------|
| 改 config 打开开关 | 14 秒内 `override=1`、`OverrideTimeout=600000ms` ✅ |
| 改 config 关闭开关 | 14 秒内 `override=0`、override 消失 ✅ |
| 界面点击开关 | 立刻 `__hmpriv_screen_on` → `OverrideTimeout=600000ms` ✅ |
| 界面新增「充电」行 | 显示「已插电」（daemon 独立检测）✅ |

**残留限制**：记账只知道"我们设了什么"。用户在终端里手动 `power-shell timeout -o`
不会同步。自用场景可接受。

#### 5.0.1 排查"不熄屏"的两天踩坑记录

用户反馈「关了充电不熄屏，手机还是不熄屏，怀疑卡在 24 小时」。

> **[2026-11-05 更正]** 本章当时的结论「不是我们 App 的问题」**不完整**。
> 真正的主因是排查过程中执行了 `hidumper -a -t`，它给 powermgr 挂了一把
> 永不释放的常亮锁（详见 §5.0.4）。下面三个因素确实存在，但都只是干扰项。
> 保留原文是因为"怎么被误导"的过程本身有价值。

**因素一：「注视屏幕不熄屏」开着**

系统设置 → 显示和亮度 → 屏幕，这个开关默认**开启**（实测 `checked=true`）。
它靠前置摄像头检测你是否在看屏幕，一看就不让熄屏。
既然人在测试、一直在看屏幕，就永远不会熄。

**因素二：`uitest dumpLayout` 会阻止熄屏**

这个命令本身是一次 UI 操作，等于持续"打扰"设备。
之前反复用它查询状态，导致「静置 75 秒屏幕还亮」的假象，
一度误以为 override 没生效。**正确做法：静置期间不发任何命令，到点只查一次。**

**因素三：判断"是否熄屏"没有直接接口**

- `hidumper -s PowerManagerService` 零字段
- `hidumper --power` 参数不存在
- `/sys/power/` 被 SELinux 拒绝
- `param get` 没有这个键

**最终可用的判据**：查 hilog 里 `screenOn:true` 的出现次数。
sceneboard 的 `ClockData: needUpdateLockTime screenOn:true` 每分钟打一次，
所以：
- 静置 N 分钟内出现 ≥2 次 → 屏幕持续亮着
- 只有 1 次（唤醒瞬间）或 0 次 → 已熄屏

**另一个坑**：`power-shell timeout -r` 的返回值只能判断"有无 override"，
**不能判断屏幕是否真的会熄**。我一度因为 `-r` 返回 failed（无 override）
就认定"没有东西在阻止熄屏"，这个推论是错的 —— 还有别的机制能阻止熄屏。

#### 5.0.2 已移除「当前熄屏时间」显示

做过一版：显示系统设置里的 `SCREEN_OFF_TIMEOUT`，后来改成显示"实际生效值"
（读 `screen_state.txt` 判断是否有 override）。**最终按用户要求删掉**：

> 「这个当前熄屏时间我看写的是系统设置里的值，这个没意义，我自己去系统设置里就能看啊」

确实如此。字段保留的价值不足，反而占用界面空间。
如果要看真实生效值，更可靠的方式是看「充电时不熄屏」开关本身的状态。

删除涉及：`DisplayReader.ets` 整文件、Index 页的显示卡片与刷新逻辑。

- [ ] **硬件级电池状态透视**：
      - 结合系统底层原生接口与 `hidumper`，读取电池真实循环次数、真实健康度、实时充放电毫安电流、电池温度与电压。
- [ ] **电源模式瞬切卡片**：
      - 整合 `power-shell setmode 600`（正常）、`601`（省电）、`602`（超级省电），无需进设置多层菜单，一键瞬切。
- [ ] **自动化省电联动**：
      - 可选配置：锁屏自动切省电模式，亮屏或插电自动切正常模式。

---

## 五、Phase 4：触控模拟（Tab 占位中）

- [ ] 可视化触摸板：Canvas 铺满手机屏幕比例，点击/滑动映射成 `uinput -T`
- [ ] 坐标换算：Canvas 像素 → 屏幕实际像素（需读 `hidumper -s RenderService` 或屏幕分辨率）
- [ ] 常用手势预设：返回手势、下拉通知栏、上滑回桌面
- [ ] 文字输入：`uinput -t "<text>"`
- [ ] 连击 / 长按（指定毫秒）

---

## 六、Phase 5：系统信息（Tab 框架已建）

「系统」Tab 已落地，含「电源与屏幕」和「设备信息」两区：

- [x] 充电时不熄屏开关
- [x] ~~显示当前熄屏时间~~ → 已按用户要求删除（用户自己能在系统设置看到，界面重复无意义）
- [x] 立即熄屏
- [x] 电池 / 系统参数 / 内存 / CPU 频率 的查询入口（输出到「最近结果」区）
- [ ] 电池卡片（把 `@ohos.batteryInfo` 的电量/温度/电压画成卡片，而不是纯文本）
- [ ] CPU 频率卡片（`hidumper --cpufreq` 输出解析成表格）
- [ ] 内存卡片（`hidumper --mem`，表格需解析）
- [ ] 系统参数浏览（`param get` 真机 689 项，可分组 + 搜索）
- [ ] 网络状态、存储占用

**注意**：`hidumper -s <Service>`（BatteryService / WifiHotspot / WindowManagerService /
PowerManagerService）在 shell 权限下**只返回两行标题、零字段**，不要用。
电池/热点必须走原生 API；屏幕超时状态也无法读取（见第三章说明）。

---

## 七、Phase 6：打磨与稳定性

### 已完成
- [x] 指令手册侧边栏（292 条，三级树 + 实时搜索 + 点击填入）
- [x] 终端多行输入（`TextArea` + ⏎ 按钮，长指令自动折行）
- [x] daemon 多行命令支持（`IFS='|' read` 切分，兼容管道符）
- [x] 危险命令黑名单（`hidumper -c` / `hidumper --mem` 无管道会永久阻塞）
- [x] 跨应用调用白名单 / 黑名单 / 调用记录
- [x] 授权持久化（`fileShare.persistPermission` + 启动时 `activatePermission`）
- [x] 退役 HTML 控制台，代码与文档全部聚焦 ArkUI 原生 App
- [x] 签名配置移出仓库（`build-profile.local.json5` + build.sh 自动注入/还原）
- [x] 工程目录统一为 `arkui_app`（下划线命名，Windows/macOS 通用）
- [x] 修复 daemon 幽灵常亮、多行命令截断、`.gitattributes` 强制 LF
- [x] **修复「偶发响应超时」**（2026-11-05，详见下方说明）
- [x] **充电常亮定稿**：`power-shell timeout -o` 由 daemon 执行、记账、续期（见 §5.0）。
      `runningLock.BACKGROUND` / `setWindowKeepScreenOn` / `hidumper -a -t` 三条路都已实测排除
- [x] **`PowerMgrKeepOnLock` 的真凶查明**：是 `hidumper -a -t` 挂的；`-t` 无 tty 也能上锁，
      但 `-f` 无 tty 解不掉（见 §5.0.4）。daemon 纪律：永不调用 `-t`
- [x] **daemon 自治读充电状态**：从 `powermgr/BatteryInfo` 日志解析 `pluggedType`，
      不再依赖 App 前台心跳（切后台即冻结）
- [x] **常亮泄漏窗口从 24 小时压到 10 分钟**：override 设 10 分钟 + 每 5 分钟续期，
      daemon 意外退出后自愈
- [ ] **屏幕超时的精确回读**：目前只能记账（不依赖 tty 的读接口全被封）。
      若将来需要，可考虑扫 hilog 的 override 事件做外部变更检测

### 5.0.3 修复「指令偶尔提示响应超时」（2026-11-05）

用户反馈「试了几个指令，偶尔好用，偶尔就提示响应超时」。

**根因**：App 侧超时 5 秒，daemon 侧允许单条命令跑 25 秒
（`timeout -k 5 20`）。任何耗时超过 5 秒的命令都会在 App 侧"超时"，
但 daemon 其实还在正常执行 —— 这就是"偶尔好用偶尔超时"的来源。

实测：一条 `sleep 8` 的命令实际耗 9 秒，必然触发 5 秒超时。

**修复**：

| 项目 | 改前 | 改后 |
|------|------|------|
| App 超时 | 5000 ms | **30000 ms**（覆盖 daemon 25 秒上限 + 5 秒余量）|
| 轮询次数 | 100 | 600 |
| 超时提示 | 一律说"daemon 可能未运行" | 先查 daemon 是否存活，再区分两种原因 |

超时提示现在的逻辑：
- daemon 在线 → 提示"命令执行超过 30 秒仍未返回，可能是命令本身耗时过长"
- daemon 不在 → 提示重新部署，给出完整命令

**同时修掉一个并发隐患**：总线只有一组 `cmd.req`/`cmd.res`，且 daemon 单线程。
如果两个页面同时发命令（终端页 + 首页快捷按钮），后写的 reqId 会覆盖前一个，
导致先发的请求永远等不到响应 —— 表现也是超时。
给 `BusClient` 加了一条 Promise 锁链，保证同一时刻只有一条命令在飞。

**实测验证**：App 终端里执行 `sleep 8; echo SLOWOK`，12 秒后正常返回 `SLOWOK`，
不再误报超时。


#### 5.0.4 `PowerMgrKeepOnLock` 的真凶：`hidumper -a -t`（我自己踩的坑）

现象：开关关掉后屏幕**仍然**不熄，一度以为是我们没释放锁。

```
$ hidumper -s PowerManagerService -a -r
  SCREEN: 1
  index=1 type=SCREEN name=PowerMgrKeepOnLock uid=5528 pid=1502 state=1
$ aa force-stop com.octahedron.hmpriv        # 把我们 App 彻底杀掉
$ hidumper -s PowerManagerService -a -r       # 锁仍在，纹丝不动
```

- `uid=5528 pid=1502` = **powermgr 自己**，不是任何第三方 App，`force-stop` 杀不掉
- 状态机里 DIM 的失败原因写着 `Blocked by running lock`
- 系统超时本身是好的：`ScreenOffTime: Timeout=60000ms`

**真凶查明了，是我自己**。我在排查时执行过一次
`hidumper -s PowerManagerService -a -t`（help 里写着 "keep screen on"，
我以为是只读查询），结果它**真的给 powermgr 挂了一把永不释放的 SCREEN 锁**：

```
$ hidumper -s PowerManagerService -a -r      # 执行 -t 前
  SCREEN: 0
$ hidumper -s PowerManagerService -a -t      # 执行
$ hidumper -s PowerManagerService -a -r      # 执行后
  SCREEN: 1
  index=1 type=SCREEN name=PowerMgrKeepOnLock uid=5528 pid=1502 state=1
$ hidumper -s PowerManagerService -a -f      # 唯一的解法
  SCREEN: 0
```

这完全解释了用户说的「**开始研究充电不熄屏之后才变得不能熄屏**」——
不是功能写错，是排查过程本身污染了系统状态。

**关键结论**

| 命令 | 副作用 | 是否需要 tty |
|------|--------|-------------|
| `hidumper -s PowerManagerService -a -t` | **加**一把 `PowerMgrKeepOnLock` | 否（同步执行即可，重定向也生效）|
| `hidumper -s PowerManagerService -a -f` | **释放**它，并 restore screen off time | **是**（无 tty 连续 3 次全失败）|
| `power-shell timeout -r` | **只**恢复超时值，**解不掉** `-t` 的那把锁 | 否 |

**这个不对称才是致命的**：`-t` 能在 daemon 里上锁，`-f` 在 daemon 里解不掉。
也就是说，一旦有代码路径调用了 `-t`，手机上就多了一把 daemon 自己清不掉的锁，
只能靠 hdc（有 tty）手动救或重启。

所以 daemon 的纪律是：**永不调用 `-t`**，只在启动时 best-effort 跑一次 `-f`。

**排查顺序（下次别再怀疑自己）**

1. `hidumper -s PowerManagerService -a -r` 看 SCREEN 锁列表：
   - `name=PowerMgrKeepOnLock uid=<powermgr>` → 是 `-t` 留下的，`-f` 清
   - `name=windowLock_* uid=<某应用>` → 某个 App 的 `setWindowKeepScreenOn`
   - 没有 → 看第 2 步
2. `hidumper -s PowerManagerService -a -s` 看 `ScreenOffTime`：
   - 有 `OverrideTimeout` → 有人在 override，记账查是谁
   - 只有 `Timeout` 且状态 = `AWAKE` 很久 → 检查「注视屏幕不熄屏」
3. `aa force-stop <本应用>` 再 dump 一次，确认不是自己

**教训**：`hidumper -a <x>` 里带短选项的不一定是查询。`-t` 是**动作**，
`-f` 是它的逆操作。动手前先看 `hidumper -s <SA> -a -h`。

### 待办
- [ ] **daemon 保活**：系统回收后需手动重启，App 内应能一键重新部署
      （思路：App 无法执行 shell，需引导用户连电脑，或做「复制命令到剪贴板」）
- [ ] **daemon 启动参数规范化**：线上曾出现 `sh -x` + 重定向到已删除文件
      导致进程卡在 `do_rt_sigsuspend`、空转 11 分钟 CPU 的情况。
      建议在 App 的部署引导里给出标准命令，并在 status.json 里记录启动方式
- [ ] **离线引导页**：检测到 daemon 离线时，显示分步骤图文引导 + 一键复制命令
- [ ] 设置页：主题、字号、默认轮询间隔、清空历史
- [ ] 命令历史面板（`cmdHistory` 已收集，但没有 UI 展示）
- [ ] 输出区支持长文本分页 / 导出到文件
- [x] ~~无 daemon 时优雅降级~~ → 已改为 30 秒超时 + 存活检测（见 §5.0.3）

---

## 八、极速总线模式（原方案 C+）：令牌哈希化 ✅

> **[2026-11-05 已实施]** 令牌机制完成哈希化改造，篡改总线文件不再可行。
> 下面记录设计决策与实测结论。

### 改造前的问题

1. `tokens.txt` 和 `slotN.req` 同在总线目录、同权限 `660 20001006:file_manager`，
   **能写槽位的 App 也能读写令牌文件** —— 令牌只能挡"不知道要用令牌"的 App
2. 令牌明文存储（preferences + 总线各一份）
3. 用 `Math.random()` 生成，是可预测的 PRNG，不能当凭据
4. App 界面读 preferences、daemon 读 `tokens.txt`，两个数据源会不一致
5. 吊销全部令牌会让总线退回"不设防"，与"没有令牌=更安全"的直觉相反

### 改造后的设计

| 项目 | 方案 |
|------|------|
| 明文令牌 | 只经 Want result 回传，签发后立即丢弃，**只此一次可见** |
| 哈希令牌 | 存 App 沙箱 `preferences` 的 `fastBusTokenHashes` |
| 生成方式 | `cryptoFramework.createRandom().generateRandomSync(32)` → 64 位 hex |
| daemon 校验 | `sha256sum` 算哈希，用 shell `case` 模式匹配，零外部依赖 |
| 存储格式 | 单行 `bundleName:sha256hex,bundleName:sha256hex`（避开 XML 转义与换行） |

**为什么哈希放 preferences**（本次关键发现）：

| 位置 | App 能写 | daemon 能读 | 第三方能读/改 | 结论 |
|------|---------|------------|--------------|------|
| 总线 `tokens.txt` | ✅ | ✅ | ❌ **能读也能改** | 防不住篡改 |
| `/data/local/tmp/hmpriv/` | ❌ 771 shell:shell | ✅ | ❌ | App 写不进去 |
| **App preferences** | ✅ | ✅ 实测可行 | ❌ 完全进不去 | **唯一满足三条** |

补充实测：shell 对 preferences 是**只读**（`mv` 报 `Permission denied`），
连 daemon 自己都改不了校验数据。

### 鉴权级别（四档）

| 情况 | 行为 |
|------|------|
| preferences 有哈希 | 严格：只认哈希，忽略总线 `tokens.txt` |
| 有 `fastBusInited=1` 但哈希为空 | 完全封锁：一律 403 |
| preferences 读不到 | 降级：退回 `tokens.txt`（明文/哈希均可） |
| 从未配置过 | 不鉴权（向后兼容），审计日志标 `[no-token-configured]` |

**为什么需要 `fastBusInited` 标记**：只凭"令牌列表是否为空"判断的话，
吊销全部令牌会让总线变成完全不设防 —— 与用户直觉正好相反。
有了标记就能区分"从没配过"（放行）和"配过又清空"（封锁）。
带懒迁移：老版本签的令牌没有标记，`isTokenInited()` 发现"有令牌但没标记"会补写。

### 实测验证（真机 Pura 70 Pro+）

**哈希算法一致性**（最容易出错的地方）：
```
App 签发明文 de7c4b10... → preferences 存 b8fb56087dc86bd1...
设备 sha256sum 计算同串   → b8fb56087dc86bd1...   ✅ 完全一致
```

**功能矩阵**：

| 场景 | 期望 | 实测 |
|------|------|------|
| 无令牌 | 403 | ✅ |
| 错误令牌 | 403 | ✅ |
| 正确令牌 | RC:0 | ✅ |
| 正确令牌 + 多行命令 | RC:0 两行输出 | ✅ |
| 往 `tokens.txt` 塞明文假令牌 | 403 | ✅ 严格模式忽略总线 |
| 往 `tokens.txt` 塞假哈希 | 403 | ✅ |
| 吊销全部令牌后用旧令牌 | 403 | ✅ 封锁生效 |
| 吊销全部令牌后无令牌 | 403 | ✅ |
| 点「彻底停用令牌机制」 | RC:0 | ✅ 回到不设防 |

**降级分支验证**：用一个独立脚本在设备上跑 `verify_token` 的三种分支，
覆盖 preferences 存在/不存在/两边都空，全部符合预期（含"严格模式忽略总线假令牌"）。

**旧数据迁移**：升级后首次打开 App，`purgeLegacyTokens` 自动清空总线
`tokens.txt` 的明文残留（实测 7 字节 → 0 字节）。

### 附带修复

- [x] 令牌计数显示 0 但实际有令牌 —— 根因是 `@Builder` 参数按值传递，
      首次构建后不随 `@State` 重建。改为内联 `Text` 后正常
- [x] 「彻底停用令牌机制」入口，避免用户启用后永久锁死（除非卸载重装）

### 残余风险（已知，不打算修）

1. **无法验证调用方身份**：`slotN.req` 是普通文件，写入者身份在文件系统层面不可得
   （槽位 hdc 预创建、属主固定，外部 App 写入只覆盖内容）。令牌只能证明
   "持有有效令牌"，不能证明"是哪个 App"。要按 App 授权只能走模式一
2. **降级模式安全性下降**：若将来 SELinux 禁止 shell 读 app 数据域，
   退回读总线 `tokens.txt`，篡改重新可行
3. **DoS 管不了**：恶意 App 仍可写满 16 个槽位
4. **社会工程防不住**：骗用户在确认卡片上点头永远无解

---

## 九、已知技术债

- [x] ~~`utils/CommandBuilder.ets` 里 `openSpecialAccess()` / `openManageApplications()`
      的注释标着「❌ Activity 不存在」~~ → 已纠正（真机实测两者都可用，
      早前是等待 3-4 秒太短导致误判，实际冷启动需 8-10 秒）
- [ ] 仅 `openAccessibility()` 确认不可用（页面能启动会渲染，但被系统安全策略立刻关闭）
- [ ] 设备 shell 的 `${VAR%%|*}` 失效（`|` 被吞掉），daemon 已绕开，
      但其他脚本（`client/` 下的）若用同样写法需要检查
      （注：`client/hmshell` 与 `hmpriv_cli.sh` 尚未逐行核查）
- [x] `docs/HARMONYOS_SHELL_GUIDE.md` 与 `docs/shell-solution-README.md` 等历史过时文档已清理，统一为 `docs/HarmonyOS-Shell-指令全集.md`
- [x] 退役 HTML 控制台模式，文档与代码 100% 聚焦 ArkUI 原生 App
- [x] 极速总线模式补齐 Token 鉴权、主开关控制与审计日志（真机实测 403 拦截生效）
- [x] 目录改名 `arkui-app` → `arkui_app`，删除残留旧目录
      （横线在 macOS 下的 DevEco Studio 里有兼容问题，统一用下划线）
- [x] 文档内 5 条断链全部修复（3 条 macOS 绝对路径 `file:///Users/...`、
      1 条指向已删除文件、1 条改名后未更新）
- [x] 签名配置移出仓库：`build-profile.json5` 只保留无签名版本，
      本机签名放 `build-profile.local.json5`（已 gitignore），
      `build.sh` 构建时临时注入、结束后还原
- [ ] **`isCoreApp()` 已成为死代码**（`a8b963e` 移除了调用但保留函数）。
      当前卸载操作没有核心应用保护，App 可以把自己（`com.octahedron.hmpriv`）卸载掉。
      按用户要求暂不恢复，但函数留着会引起误解，要么恢复调用要么删掉
- [ ] `build-profile.local.json5` 里的密钥口令虽为 IDE 加密态，
      但仍建议定期在 DevEco 里重新生成证书，降低泄露影响

---

## 十、验证状态

| 环境 | 状态 | 备注 |
|------|------|------|
| 模拟器 Mate 70 Pro+ | ✅ 全流程通过 | 免签名安装；pick 授权；uid 2000 验证通过 |
| 真机 Pura 70 Pro+ | ✅ 全流程通过 | 自动签名；`fileShare` 授权持久化；60 条指令实测 |
| 真机容器穿透 | 🟡 部分 | 通知使用权 / 特殊访问权限 / 应用列表 ✅；无障碍 ❌ |
| 出境易 | ✅ | 与卓易通共用同一套命令 |
| 跨应用调用「弹窗授权模式」 | ✅ 代码完成 | 遵循系统 Want IPC，弹窗审批保障安全 |
| 跨应用调用「极速总线模式」 | ✅ 令牌哈希化完成 | 严格模式忽略总线篡改；封锁语义；降级兜底；9 个场景实测通过（见第八章）。**仍无法验证调用方身份** |
| 充电时不熄屏 | ✅ 五场景实测 | 常亮/关闭/未充电/心跳过期/daemon 重启自愈，全部符合预期 |
