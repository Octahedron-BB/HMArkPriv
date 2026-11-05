# HMArkPriv 待办清单

> 最后更新：2026-11-05
> 状态标记：`[x]` 已完成 · `[~]` 进行中 · `[ ]` 待开始 · `[?]` 待研究

---

## 一、总体进度

| 阶段 | 内容 | 状态 |
|------|------|------|
| Phase 1 | MVP：文件总线 + daemon + 终端 | ✅ 完成（模拟器 + 真机双验证） |
| Phase 2 | 首页快捷面板 | 🟢 完成约 85%（缺截图/电源模式/容器入口） |
| Phase 3 | 应用管理与深度管控 | 🟢 MVP 就绪（列表/启动/强停/权限透视/清数据/卸载） |
| Phase 4 | 触控模拟 | ⬜ 未开始 |
| Phase 5 | 系统信息 | 🟡 Tab 框架已建（电源与屏幕 + 设备信息入口），卡片化未做 |
| Phase 6 | 打磨与引导 | ✅ 终端连接日志优化、HTML模式退役、文档重构整理 |
| 追加 | 跨应用调用（Shizuku 式） | 🟡 双方案可用，但**极速总线无法验证调用方身份**（见第八章） |

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
- [x] **全息元数据导出**：
      - 原始代码容器查看 `bm dump -n` 完整数据。

### 4. 极客“真·冻结”与冷宫防唤醒系统（Freeze & Anti-Wakeup · 规划中）
- [ ] **防唤醒核心机制（让其他程序找不到、唤不醒）**：
      - **主方案（EDM 超级管理员模式 · 系统级封印）**：
        1. App 内接入并声明 `EnterpriseAdminExtensionAbility`。
        2. 提权 Daemon 执行 `edm enable-admin -n com.octahedron.hmpriv -a EnterpriseAdminAbility -t super` 激活系统级 Super Admin（Device Owner）。
        3. 调用官方 `@ohos.enterprise.applicationManager.addPackagesToDisallowList` 将目标应用加入禁用名单。
        4. **实测效果**：系统内核与 AbilityManager 底层全局拒绝任何 Want / URL Scheme / 隐式调用，图标隐藏或置灰，其他程序无法探测、无法拉起、无法唤醒，如同彻底从系统中消失！
      - **副方案（Daemon 动态守卫反弹拦截）**：
        1. 针对未开启 EDM 的设备，后台 Daemon 监听 Ability 启动事件或定时扫描。
        2. 一旦冷宫名单中的应用被外部应用或系统服务拉起，100ms 内瞬间触发 `aa force-stop <bundleName>` 掐灭进程，切断对外响应。
- [ ] **冷宫管理界面**：
      - 一键添加/移出冷宫。
      - 冻结状态与解冻状态无缝切换。

### 6. 电池与电源策略深度联动（Battery & Power）
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
- [x] 立即唤醒 / 立即熄屏
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
- [ ] 无 daemon 时优雅降级（当前会等 5 秒超时）

---

## 八、极速总线模式（原方案 C+）：安全现状与令牌方案

> **[2026-11-05 复核]** 昨天实现的「令牌鉴权 + 总开关 + 审计日志」确实堵住了
> 原先「谁写文件谁就能静默执行且无记录」的漏洞，但**令牌机制本身还有一处
> 架构级短板**，下面如实记录，并给出四个方案供决策。

### 已实现的防护（真机实测有效）

```bash
# 无令牌
printf 'id' > req/slot3.req      → RC:403  Unauthorized: valid token required
# 带正确令牌
printf 'TOKEN:xxxx\nid' > ...    → RC:0    uid=2000(shell)
```

| 机制 | 作用 | 状态 |
|------|------|------|
| 令牌鉴权 | `slotN.req` 首行必须 `TOKEN:<key>`，daemon 比对 `tokens.txt` | ✅ 实测 403 拦截生效 |
| 总开关 | `config.json` 的 `queueEnabled:false` 时完全跳过队列 | ✅ |
| 审计日志 | 每条队列命令追加 `时间 \| 槽位 \| RC \| 命令摘要`，128KB 滚动 | ✅ 界面可查看 |

### 短板：令牌与请求在同一文件系统权限模型下

`tokens.txt` 和 `slotN.req` 都在总线目录里，权限同为 `660 20001006:file_manager`。
**任何能写 `slotN.req` 的 App，同样能读写 `tokens.txt`** —— 也就是说：

> 令牌只能挡住「不知道要用令牌」的 App，挡不住「打开文件看一眼」的 App。

这不是实现问题，是文件总线架构决定的：daemon 和调用方共用同一套 POSIX 权限，
没有可信第三方来断言「这个写操作来自哪个 App」。

**附带的两个具体 bug**

- [ ] App「开放」页显示「令牌（0）/ 暂无令牌」，但 `tokens.txt` 里实际有 1 个令牌且
      daemon 正在校验它 —— App 只读 preferences，从不核对 `tokens.txt`，
      导致「界面上没有令牌，实际却存在有效令牌」
- [ ] 令牌用 `Math.random()` 生成（`TrustManager.generateToken`），不是密码学安全随机数

### 四个候选方案

#### 方案 1：令牌哈希化 + Want 下发（推荐，性价比最高）

把令牌从「明文文件」改成「只在 Want 里流转」：

1. 调用方通过 `action: 'hmpriv.request_token'` 发起 Want 请求
2. 用户在确认卡片上批准 → App 生成令牌，**通过 Want 的 result 参数回传**
   （Want 走 Binder，不经过文件系统，第三方读不到）
3. `tokens.txt` 里**只存 `sha256(token)`**，不存明文
4. daemon 收到 `TOKEN:<token>` 时，用 `sha256sum` 算哈希再比对

设备实测有 `sha256sum` / `md5sum` / `openssl`，daemon 侧可直接算。

| 能挡住 | 挡不住 |
|--------|--------|
| 被动窃取：读 `tokens.txt` 只看到哈希，无法反推出可用令牌 | 主动篡改：能写目录的 App 可以把自己的令牌哈希塞进 `tokens.txt` |

价值：把攻击门槛从「读一个文件」抬到「主动篡改文件」，且篡改会留下痕迹。

#### 方案 2：HMAC + 时间戳防重放（在方案 1 之上加固）

调用方每次请求写 `TOKEN:<token> TS:<unix秒> SIG:<hmac-sha256(token+cmd+ts)>`，
daemon 校验签名与时间窗（±30 秒），超窗或重放拒绝。

- 挡住：录下别人的请求原样重放
- 挡不住：仍然要靠 `tokens.txt` 里的校验材料，篡改问题依旧

设备有 `openssl`，可实现（`openssl dgst -sha256 -hmac`），但 daemon 每个请求多一次
子进程调用，延迟从 ~60ms 增加到 ~120ms。

#### 方案 3：收紧文件权限（**不可行，已排除**）

想让 `tokens.txt` 只对 App 可读，需要 `chmod 600` 或改成专属 uid。实测两个方向都堵死：

- `chmod 600` → owner 是 `20001006:file_manager`，App 的 uid 是 `20020256`，
  **App 自己也读不到**了
- 改 owner → App 无 `chown` 权限
- App 自己新建一个 `tokens.txt` → hmdfs 下 shell/App 都没有 create 权限（SELinux），
  只能由 hdc 预创建

#### 方案 4：放弃 C+，只保留 Want 模式（架构级，最安全）

Want 模式能从 `want.bundleName` 拿到**系统保证的调用方身份**，是唯一能做真正
基于身份的鉴权（白名单）的通道。C+ 天生拿不到这个信息。

| | Want 模式 | 极速总线 C+ |
|---|---|---|
| 能验证调用方身份 | ✅ 系统给出 bundleName | ❌ 完全不知道是谁 |
| 白名单可控 | ✅ | ❌ |
| 用户知情 | ✅ 弹窗 | ❌ 静默 |
| 延迟 | ~300-500ms | ~60-100ms |
| 依赖 App 存活 | 是 | 否 |

如果「安全」优先于「快」，C+ 就不该存在。

### 建议

1. **短期（低风险，先做）**
   - 修「界面显示 0 令牌但实际有令牌」的不一致：改为直接读 `tokens.txt` 计数
   - `Math.random()` → `cryptoFramework.createRandom()`（鸿蒙原生 CSPRNG）
   - 在「开放」页如实标注：**极速总线无法验证调用方身份，仅防误用不防恶意**

2. **中期（若仍要保留 C+）**：实施方案 1（哈希 + Want 下发），
   把「读文件就能拿令牌」堵上

3. **长期**：需要严格控权的场景统一走 Want 模式；C+ 定位为「本机自动化脚本的快速通道」，
   不承诺安全边界

### 待办

- [ ] 决策：C+ 保留 / 仅哈希化 / 直接下线（方案 1 / 2 / 4 三选一）
- [ ] 修 App 令牌显示与 `tokens.txt` 不一致
- [ ] 令牌生成改用 `cryptoFramework`
- [ ] 「开放」页补充「无法验证调用方身份」的明确提示
- [ ] 若采纳方案 1：`daemon.sh` 改用 `sha256sum` 比对，`tokens.txt` 只存哈希
- [ ] 若采纳方案 1：`HmprivClient.ets` 的 `requestFastBusToken` 改为从 Want result 取令牌

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
| 跨应用调用「极速总线模式」 | 🟡 功能可用 | Token 鉴权 + 审计日志实测生效，但**无法验证调用方身份**（见第八章） |
| 充电时不熄屏 | ✅ 五场景实测 | 常亮/关闭/未充电/心跳过期/daemon 重启自愈，全部符合预期 |
