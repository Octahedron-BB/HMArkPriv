# HMArkPriv 待办清单

> 最后更新：2026-11-04
> 状态标记：`[x]` 已完成 · `[~]` 进行中 · `[ ]` 待开始 · `[?]` 待研究

---

## 一、总体进度

| 阶段 | 内容 | 状态 |
|------|------|------|
| Phase 1 | MVP：文件总线 + daemon + 终端 | ✅ 完成（模拟器 + 真机双验证） |
| Phase 2 | 首页快捷面板 | 🟡 完成约 70%（缺常亮/截图/电源模式/容器入口） |
| Phase 3 | 应用管理与深度管控 | 🟡 设计就绪（功能规格与防唤醒方案确立） |
| Phase 4 | 触控模拟 | ⬜ 未开始（Tab 仍是占位） |
| Phase 5 | 系统信息 | ⬜ 未开始（Tab 仍是占位） |
| Phase 6 | 打磨与引导 | ✅ 终端连接日志优化、HTML模式退役、文档重构整理 |
| 追加 | 跨应用调用（Shizuku 式） | ✅ 「弹窗授权模式」与「极速总线模式」双方案均已就绪（含 Token 鉴权与审计） |

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

## 四、Phase 3：应用管理与深度管控（设计就绪 · 待实现）

> **核心定位**：打破普通系统设置的黑盒限制，利用 UID 2000 提权实现「极速应用透视 + 极客真冻结（防唤醒）+ 预装免Root瘦身 + 深度清空 + 进程彻底灭杀」。

### 1. 应用概览与极速清单（App List）
- [ ] **150ms 极速全量应用列表获取**：
      - 调用 `bm dump -a -l`，一次性提取全量应用的 `bundleName` 和中文 `label`。
      - 本地缓存元数据，支持全量搜索（中文名称、拼音、包名模糊匹配）。
- [ ] **多维分类筛选器**：
      - `全部应用` / `用户已安装` / `可卸载系统预装` / `正在运行` / `冷宫冻结`。
- [ ] **运行状态与资源指示**：
      - 对齐 `ps -ef` 进程列表，在应用卡片上实时标明「运行中（绿色小圆点 + PID）」与内存估算。

### 2. 极客“真·冻结”与冷宫防唤醒系统（Freeze & Anti-Wakeup）
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

### 3. 应用全息透视（上帝视角 Inspector）
- [ ] **元数据全息提取**：
      - 解析 `bm dump -n <bundleName>`：版本名、VersionCode、目标 API 级别（API 11/12/26）、签名类型（Debug/Release）、安装时间与数据目录。
- [ ] **权限全景透视（杀手级特性）**：
      - 突破系统限制，全量罗列该应用申请的所有权限（`reqPermissions`）与授权状态（`reqPermissionStates`）。
      - 敏感权限高亮归类标签：位置信息、相机/录音、常驻后台、网络通信、剪贴板、文件访问等。
- [ ] **Ability 清单与隐式启动**：
      - 列出其声明的 UIAbility / ExtensionAbility，支持一键穿透启动特定 Ability。

### 4. 深度控制与数据治理（Control & Clean）
- [ ] **真·杀后台**：
      - 调用 `aa force-stop <bundleName>`，彻底杀灭进程组及附属的 ServiceExtensionAbility，避免多任务上滑后的暗中自启。
- [ ] **彻底清空数据（破除系统设置置灰限制）**：
      - 调用 `bm clean -d -n <bundleName>`，直接擦除 `el1` 与 `el2` 下的私有数据库与键值存储，带二次确认防误触。
- [ ] **清理应用缓存**：
      - 调用 `bm clean -c -n <bundleName>`。
- [ ] **一键重置权限**：
      - 调用 `atm perm -r -b <bundleName>`，将应用的所有动态权限一键恢复到初始未授权状态。
- [ ] **内存压力释放（TrimMemory）**：
      - 调用 `aa send-memory-level <pid> 2`，模拟高内存压力强制应用回收非活跃缓存。

### 5. 系统预装瘦身助手（Debloat Assistant）
- [ ] **免 Root 识别与卸载预装应用**：
      - 自动过滤出 `isRemovable: true` 的系统预装推广应用与运营商应用。
      - 调用 `bm uninstall -n <bundleName> -u 100` 进行免 Root 卸载，释放存储空间。
      - 支持 `-k` 参数（保留数据卸载）。
- [ ] **核心组件防呆安全白名单**：
      - 强制保护 `system_core` 级关键系统应用（设置、桌面、系统服务等），防止小白误操作导致设备故障。

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

## 八、安全问题：极速总线模式（原方案 C+）安全机制闭环 ✅

> **[2026-11-04 已解决]** 已实现「令牌鉴权 + 总开关 + 审计日志」三层防护闭环，消除了原 C+ 通道绕过白名单与审计的漏洞。

### 解决实现

1. **命名规范**：
   - 方案 A $\rightarrow$ **「弹窗授权模式」**（Want 交互协议，每次弹窗确认，可信任免弹窗）
   - 方案 C+ $\rightarrow$ **「极速总线模式」**（Queue 共享总线，带 TOKEN:xxx 凭证异步调用）

2. **令牌安全鉴权（Token Auth）**：
   - 外部 App 想使用极速总线模式，需先通过 `action: 'hmpriv.request_token'` 请求令牌，由用户在弹窗卡片中明确授权同意后签发。
   - 外部 App 向 `slotN.req` 写入命令时必须在首行携带 `TOKEN:<key>`。
   - `daemon.sh` 在读取槽位时严格比对 `tokens.txt`；若无有效令牌，直接拒绝并返回 `RC:403 ERROR:Unauthorized`，阻断未授权调用。

3. **总线总开关（Master Switch）**：
   - App「开放」页提供「极速总线开关」，通过 `config.json` 动态管控。关闭时 `daemon.sh` 完全跳过队列处理，杜绝静默后门。

4. **审计日志追踪（Audit Logging）**：
   - `daemon.sh` 每执行一条队列命令均追加记录到 `audit.log`（时间、槽位、退出码 RC、命令摘要），带 128KB 滚动截断。
   - App「开放」页实时读取并展示总线审计日志，支持一键清空与一键吊销已发放令牌。

### 待办追踪状态

- [x] **采用 A + C 组合拳**（令牌鉴权 + 审计日志 + 总开关）
- [x] `daemon.sh` 增加 `AUDIT_LOG` 追加写入与 128KB 滚动保护
- [x] `daemon.sh` 增加 `tokens.txt` 校验与 `config.json` 总开关检测
- [x] App「开放」页增加极速总线开关、令牌签发/吊销管理、总线审计日志展示
- [x] SDK `HmprivClient.ets` 升级支持 `requestFastBusToken` 与 `TOKEN:<key>` 协议格式
- [x] App 确认卡片支持 `hmpriv.request_token` 令牌申请审批弹窗

---

## 九、已知技术债

- [x] ~~`utils/CommandBuilder.ets` 里 `openSpecialAccess()` / `openManageApplications()`
      的注释标着「❌ Activity 不存在」~~ → 已纠正（真机实测两者都可用，
      早前是等待 3-4 秒太短导致误判，实际冷启动需 8-10 秒）
- [ ] 仅 `openAccessibility()` 确认不可用（页面能启动会渲染，但被系统安全策略立刻关闭）
- [ ] 设备 shell 的 `${VAR%%|*}` 失效（`|` 被吞掉），daemon 已绕开，
      但其他脚本（`client/` 下的）若用同样写法需要检查
- [x] `docs/HARMONYOS_SHELL_GUIDE.md` 与 `docs/shell-solution-README.md` 等历史过时文档已清理，统一为 `docs/HarmonyOS-Shell-指令全集.md`
- [x] 退役 HTML 控制台模式，文档与代码 100% 聚焦 ArkUI 原生 App
- [x] 极速总线模式补齐 Token 鉴权、主开关控制与审计日志（真机实测 403 拦截生效）

---

## 十、验证状态

| 环境 | 状态 | 备注 |
|------|------|------|
| 模拟器 Mate 70 Pro+ | ✅ 全流程通过 | 免签名安装；pick 授权；uid 2000 验证通过 |
| 真机 Pura 70 Pro+ | ✅ 全流程通过 | 自动签名；`fileShare` 授权持久化；60 条指令实测 |
| 真机容器穿透 | 🟡 部分 | 通知使用权 / 特殊访问权限 / 应用列表 ✅；无障碍 ❌ |
| 出境易 | ✅ | 与卓易通共用同一套命令 |
| 跨应用调用「弹窗授权模式」 | ✅ 代码完成 | 遵循系统 Want IPC，弹窗审批保障安全 |
| 跨应用调用「极速总线模式」 | ✅ 真机实测打通 | 毫秒级总线 IPC + Token 鉴权 + 独立审计日志 |
