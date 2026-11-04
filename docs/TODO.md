# HMArkPriv 待办清单

> 最后更新：2026-11-04
> 状态标记：`[x]` 已完成 · `[~]` 进行中 · `[ ]` 待开始 · `[?]` 待研究

---

## 一、总体进度

| 阶段 | 内容 | 状态 |
|------|------|------|
| Phase 1 | MVP：文件总线 + daemon + 终端 | ✅ 完成（模拟器 + 真机双验证） |
| Phase 2 | 首页快捷面板 | 🟡 完成约 70%（缺常亮/截图/电源模式/容器入口） |
| Phase 3 | 应用管理 | ⬜ 未开始（Tab 仍是占位） |
| Phase 4 | 触控模拟 | ⬜ 未开始（Tab 仍是占位） |
| Phase 5 | 系统信息 | ⬜ 未开始（Tab 仍是占位） |
| Phase 6 | 打磨与引导 | 🟡 部分完成（指令手册已完成） |
| 追加 | 跨应用调用（Shizuku 式） | 🟡 方案 A 完整；**方案 C+ 有安全缺口**（见第八章） |

**代码规模**：ArkTS 约 3900 行 / 16 个文件；指令手册收录 292 条（11 个分类）。

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
- [ ] **屏幕常亮滑块**：拖动选择 5min / 10min / 30min / 1h / 2h / 永久
      → `power-shell timeout -o <ms>`，`-r` 复位
- [ ] **截图预览**：`snapshot_display -f` 落到总线目录 → 读回显示缩略图
      （注意：写 hmdfs 会 `realpath nullptr`，需落到 `/data/local/tmp/` 再搬）
- [ ] **电源模式切换**：`power-shell setmode`（节能/均衡/性能，需标注实际语义未确认）
- [ ] **容器入口卡**：检测到卓易通/出境易时，一键直达通知使用权页

---

## 四、Phase 3：应用管理（Tab 占位中）

- [x] `ResponseParser.parseAppList` 已能正确解析 `bm dump -a`（真机 64 个）
- [ ] 应用列表 UI：名称 + 包名 + 图标，支持搜索
- [ ] 点击应用 → 详情面板（`bm dump -n` 解析：版本、UID、权限、Ability）
- [ ] 操作：启动（需从 `bm dump -n` 里解析 mainAbility）/ 强停 / 清缓存 / 清数据
- [ ] 危险操作二次确认（清数据 = 不可逆）
- [ ] 按 UID/权限排序、只看第三方应用

**注意**：`aa start` 和 `aa force-stop` 都是**静默执行**（RC=0 无输出），
UI 必须用「列表刷新 / `bm dump -n` 校验」来确认操作是否生效，不能只看 RC。

---

## 五、Phase 4：触控模拟（Tab 占位中）

- [ ] 可视化触摸板：Canvas 铺满手机屏幕比例，点击/滑动映射成 `uinput -T`
- [ ] 坐标换算：Canvas 像素 → 屏幕实际像素（需读 `hidumper -s RenderService` 或屏幕分辨率）
- [ ] 常用手势预设：返回手势、下拉通知栏、上滑回桌面
- [ ] 文字输入：`uinput -t "<text>"`
- [ ] 连击 / 长按（指定毫秒）

---

## 六、Phase 5：系统信息（Tab 占位中）

- [ ] 电池卡片（`@ohos.batteryInfo` 已可用：电量/温度/电压/充电状态）
- [ ] CPU 频率卡片（`hidumper --cpufreq`）
- [ ] 内存卡片（`hidumper --mem`，表格需解析）
- [ ] 系统参数浏览（`param get` 真机 689 项，可分组+搜索）
- [ ] 网络状态、存储占用

**注意**：`hidumper -s <Service>`（BatteryService / WifiHotspot / WindowManagerService）
在 shell 权限下**只返回两行标题、零字段**，不要用。电池/热点必须走原生 API。

---

## 七、Phase 6：打磨与稳定性

### 已完成
- [x] 指令手册侧边栏（292 条，三级树 + 实时搜索 + 点击填入）
- [x] 终端多行输入（`TextArea` + ⏎ 按钮，长指令自动折行）
- [x] daemon 多行命令支持（`IFS='|' read` 切分，兼容管道符）
- [x] 危险命令黑名单（`hidumper -c` / `hidumper --mem` 无管道会永久阻塞）
- [x] 跨应用调用白名单 / 黑名单 / 调用记录
- [x] 授权持久化（`fileShare.persistPermission` + 启动时 `activatePermission`）

### 待办
- [ ] **daemon 保活**：系统回收后需手动重启，App 内应能一键重新部署
      （思路：App 无法执行 shell，需引导用户连电脑，或做「复制命令到剪贴板」）
- [ ] **离线引导页**：检测到 daemon 离线时，显示分步骤图文引导 + 一键复制命令
- [ ] 设置页：主题、字号、默认轮询间隔、清空历史
- [ ] 命令历史面板（`cmdHistory` 已收集，但没有 UI 展示）
- [ ] 输出区支持长文本分页 / 导出到文件
- [ ] 无 daemon 时优雅降级（当前会等 5 秒超时）

---

## 八、安全问题：方案 C+ 绕过白名单与审计 ⚠️

> **[2026-11-04 代码审查确认]** 这不是推测，是当前实现的确定行为。

### 现象

方案 C+（队列槽位）的调用**完全绕过 App**：

```
方案 A：外部App → Want → HMArkPriv App → 查白名单 → 弹确认卡片 → 写 cmd.req → daemon
方案 C+：外部App ────────────────────── 写 req/slotN.req ─────────────→ daemon
                                          ↑ App 全程不参与
```

因此：

| 项目 | 方案 A | 方案 C+ |
|------|--------|---------|
| 用户看到确认卡片 | ✅ 白名单外必弹 | ❌ **完全不弹** |
| 写入「调用记录」 | ✅ 每次调用都记 | ❌ **完全不记** |
| 白名单 / 黑名单生效 | ✅ 生效 | ❌ **不生效**（拦不到） |
| daemon 审计日志 | 无 | 无（`daemon.sh` 全文无任何日志写入） |

### 根因（三处代码可确认）

1. `core/daemon.sh` 的 `process_slots()`：发现 `slotN.req` 非空就直接 `run_and_reply`，
   没有任何校验、没有回调、没有日志
2. `core/daemon.sh` 全文搜 `log` / `audit` / `>>` —— **零命中**，daemon 不写任何审计记录
3. `TrustManager.recordCall()` 只有一个调用点：`CrossAppHandler.ets:131`，即仅方案 A 会记

`TrustManager` 和确认卡片都活在 ArkTS 侧，daemon 是独立 shell 进程，
读不到 App 的 preferences，也无法回调 UI —— 所以白名单天生管不住 C+。

### 实际风险边界

不是「任何 App 都能用」，C+ 的门槛是**能写总线目录**（`Download/HMArkPriv`）。
外部 App 要靠用户在 picker 里明确授权才能拿到这个能力
（`READ_WRITE_DOWNLOAD_DIRECTORY` 在真机返回 `2 invalid request`，走不通）。

所以真正的弱点是这个场景：

> **用户一旦把总线目录授权给某个第三方 App，那个 App 就永久获得了静默执行任意 shell
> 的能力，而且在界面上看不出任何痕迹。**

这与「由用户决定给谁权限」的设计初衷相反 —— 用户以为白名单在把关，实际 C+ 通道不受它管。

### 已知限制：即使加日志也查不到「谁」

槽位文件是 `hdc` 预创建的（属主 `20001006:file_manager`，权限 660），
外部 App 写入只是覆盖内容，**文件属主不变**。文件系统层面无法区分写入者。

### 修复方向（三选一或组合）

| 方案 | 做法 | 效果 | 代价 |
|------|------|------|------|
| **A. 审计日志**（推荐先做） | daemon 每条槽位命令追加一行 `时间 \| 来源=queue \| 命令` 到总线目录，App 读出来展示在调用记录 | 用户能看到「被执行过什么」 | 看不到「谁」，日志本身也可能被写目录的 App 篡改 |
| **B. 直接关掉 C+** | 不预创建槽位（`setup-queue.sh` 默认 0 槽），文档降级为实验特性 | 最安全 | 牺牲并发与高频自动化场景 |
| **C. 密钥校验** | App 生成密钥写进总线，daemon 校验 `slotN.req` 首行；无密钥不放行 | 能真正控权 | 密钥要发给调用方，等于把「白名单」换成「密钥分发」 |

**倾向 A + C 组合**：日常靠审计日志保证可追溯，需要严格控权时开密钥校验。

### 待办

- [ ] **决定采用哪个修复方向**（需产品决策：安全 vs 易用）
- [ ] 若选 A：`daemon.sh` 增加 `AUDIT_LOG` 追加写入（注意并发与日志膨胀，需滚动）
- [ ] 若选 A：App「开放」页读取并展示队列调用记录，与 Want 调用分区显示
- [ ] 若选 C：设计密钥生成/下发/轮换机制，SDK `HmprivClient.ets` 同步更新
- [ ] 若选 B：`scripts/setup-queue.sh` 默认不建槽位，`docs/跨应用调用协议.md` 加显著警告
- [x] ~~`docs/跨应用调用协议.md` 第四章对比表需如实标注 C+ 不走白名单~~
      → 已补「用户确认 / 调用记录 / 白名单生效」三行 + 五章加警告

---

## 九、已知技术债

- [x] ~~`utils/CommandBuilder.ets` 里 `openSpecialAccess()` / `openManageApplications()`
      的注释标着「❌ Activity 不存在」~~ → 已纠正（真机实测两者都可用，
      早前是等待 3-4 秒太短导致误判，实际冷启动需 8-10 秒）
- [ ] 仅 `openAccessibility()` 确认不可用（页面能启动会渲染，但被系统安全策略立刻关闭）
- [ ] 设备 shell 的 `${VAR%%|*}` 失效（`|` 被吞掉），daemon 已绕开，
      但其他脚本（`client/` 下的）若用同样写法需要检查
- [ ] `docs/HARMONYOS_SHELL_GUIDE.md` 是早期 Gemini 版手册，与现行
      `docs/HarmonyOS-Shell-指令全集.md` 有重复和冲突（如无障碍仍标为可用）
      → 应合并或标注为历史文档

---

## 十、验证状态

| 环境 | 状态 | 备注 |
|------|------|------|
| 模拟器 Mate 70 Pro+ | ✅ 全流程通过 | 免签名安装；pick 授权；uid 2000 验证通过 |
| 真机 Pura 70 Pro+ | ✅ 全流程通过 | 自动签名；`fileShare` 授权持久化；60 条指令实测 |
| 真机容器穿透 | 🟡 部分 | 通知使用权 / 特殊访问权限 / 应用列表 ✅；无障碍 ❌ |
| 出境易 | ✅ | 与卓易通共用同一套命令 |
| 跨应用调用 方案 A | 🟡 代码完成 | 需第二个 App 实测端到端（目前只有 SDK 和文档） |
| 跨应用调用 方案 C+ | ⚠️ 功能可用但**不审计** | 绕过白名单与调用记录，见第八章 |
