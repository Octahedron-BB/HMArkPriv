/**
 * CommandBuilder — 命令构造器
 *
 * 将 UI 操作映射为 shell 命令字符串，集中管理所有命令模板。
 * 所有方法返回纯字符串，由 BusClient.execute() 发送到 daemon。
 *
 * 【2026-11-04 模拟器实测标注】
 *
 * ✅ 输出可捕获（daemon 能拿到结果）
 *    id / echo / date / uname / pwd / param get
 *    bm dump -a / bm dump -n / bm clean -c / bm clean -d
 *    power-shell wakeup|suspend|timeout|setmode（无输出但 RC=0，操作生效）
 *    snapshot_display（有输出）
 *    uinput -T / -K（有输出）
 *    hidumper --mem / --cpufreq（有输出）
 *
 * ⚠️ 静默执行（RC=0 但无输出，操作确实生效，App 需自行校验）
 *    aa start / aa force-stop
 *
 * ❌ 输出无法捕获（走 pty，daemon 的 $(...) 拿不到）
 *    aa dump -l          → 改用 uitest dumpLayout 落盘后读取
 *    hidumper -s XxxService → 只有 header，无实际字段
 *                             （电池改用 @ohos.batteryInfo 原生 API）
 */

export class CommandBuilder {
  /** 前台应用查询用的临时文件（daemon 视角路径） */
  static readonly LAYOUT_TMP = '/data/local/tmp/hmpriv/layout_probe.json';

  // ===== 屏幕控制 ✅ =====
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

  // ===== 按键模拟 ✅ =====
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

  // ===== 应用管理 =====
  /** 已装应用列表 ✅ 输出为「TAB + 包名」格式，见 ResponseParser.parseAppList */
  static listApps(): string { return 'bm dump -a'; }

  /** 已装应用全量列表（含中文名称与包名 JSON 数组） ✅ 150ms 极速返回 */
  static listAppsWithLabels(): string { return 'bm dump -a -l'; }

  /** 查询单个应用详情 ✅ 也用于判断是否已安装 */
  static appDetail(bundle: string): string {
    return `bm dump -n ${bundle}`;
  }

  /** 启动应用：自动动态解析 mainAbility 并支持 entry 模块多 HAP 穿透 */
  static startApp(bundle: string): string {
    return `MAIN=$(bm dump -n ${bundle} 2>/dev/null | grep -E '"mainAbility": "[^"]+"' | head -n 1 | sed 's/.*"mainAbility": "\\([^"]*\\)".*/\\1/'); [ -z "$MAIN" ] && MAIN="EntryAbility"; aa start -b ${bundle} -a "$MAIN" 2>&1 || aa start -b ${bundle} -m entry -a "$MAIN" 2>&1`;
  }

  /** 打开系统设置中该应用的专属设置页（权限/通知/存储） */
  static openAppSystemSettings(bundle: string): string {
    return `aa start -a com.huawei.hmos.settings.MainAbility -b com.huawei.hmos.settings -U 'application_info_entry' --ps bundleName ${bundle}`;
  }

  /** 查询当前所有正在运行的应用进程 */
  static queryRunningProcesses(): string {
    return `ps -ef`;
  }

  /** 强制停止 ⚠️ 无输出但生效 */
  static forceStopApp(bundle: string): string {
    return `aa force-stop ${bundle}`;
  }

  /** 清缓存 ✅ 返回 "clean bundle cache files successfully." */
  static cleanCache(bundle: string): string {
    return `bm clean -c -n ${bundle}`;
  }

  /** 清数据 ✅ */
  static cleanData(bundle: string): string {
    return `bm clean -d -n ${bundle}`;
  }

  /** 免 Root 卸载应用（支持 -k 保留数据） */
  static uninstallApp(bundle: string, keepData: boolean = false): string {
    return keepData ? `bm uninstall -n ${bundle} -k -u 100` : `bm uninstall -n ${bundle} -u 100`;
  }

  /** 一键重置权限（恢复未授权状态） */
  static resetAppPermissions(bundle: string): string {
    return `atm perm -r -b ${bundle}`;
  }

  /**
   * 任务栈 ❌ 输出无法捕获，不要用。
   * 仅保留以标注，实际前台应用请用 foregroundAppProbe()。
   */
  static dumpTasks(): string { return 'aa dump -l'; }

  /**
   * 查询前台应用（可靠方案）。
   *
   * 原理：aa dump -l 的输出走 pty 抓不到，但 uitest dumpLayout 是写文件的，
   * 文件里含 "bundleName":"com.xxx"，可被 shell 读取。
   *
   * 用法：execute 后读 layoutTmpPath() 文件内容，交给
   * ResponseParser.parseForegroundFromLayout()。
   */
  static foregroundAppProbe(): string {
    return `uitest dumpLayout -p ${CommandBuilder.LAYOUT_TMP} >/dev/null 2>&1; ` +
      `cat ${CommandBuilder.LAYOUT_TMP} 2>/dev/null`;
  }

  /** 前台探测产生的临时文件路径 */
  static layoutTmpPath(): string {
    return CommandBuilder.LAYOUT_TMP;
  }

  // ===== 系统信息 =====
  // 【真机实测 2026-11-04】hidumper -s <Service> 在 shell 权限下拿不到 dump 内容，
  // 只返回两行标题（LEN=163）。不是参数问题，是权限限制。
  // 电池/热点/窗口信息必须走 @ohos.* 原生 API，见 BatteryReader。

  /** 电池 ❌ 真机零数据，仅保留以标注；用 BatteryReader（@ohos.batteryInfo） */
  static batteryInfo(): string { return 'hidumper -s BatteryService'; }
  /** 热点 ❌ 真机零数据 */
  static hotspotInfo(): string { return 'hidumper -s WifiHotspot'; }
  /** 系统参数 ✅ 真机 689 项，格式 "key = value" */
  static systemParams(): string { return `param get`; }
  /** 单个参数 ✅ */
  static param(key: string): string { return `param get ${key}`; }
  /** 窗口信息 ❌ 真机零数据 */
  static windowInfo(): string { return 'hidumper -s WindowManagerService'; }
  /** 内存统计 ✅ 有表格数据 */
  static memInfo(): string { return 'hidumper --mem'; }
  /** CPU 频率 ✅ */
  static cpuFreq(): string { return 'hidumper --cpufreq'; }

  // ===== 卓易通（ANCO）穿透 =====
  //
  // 【架构】卓易通 com.droi.tong / 出境易 com.easy.hmos.abroad 运行在
  // rgm_hmos / isulad 管理的轻量级容器中（ANCO 架构），有独立网络命名空间和进程树。
  // 鸿蒙宿主的 aa start 能把 -b com.android.settings 路由到容器内的安卓 Settings。
  //
  // 【真机实测 2026-11-04，Pura 70 Pro+】
  //   ✅ 通知使用权 —— 可用，可重复，界面确实跳到容器内的
  //      「通知使用权」页（列出容器内已装应用）
  //   ✅ 特殊访问权限 —— 可用，7 个条目完整（悬浮窗/媒体管理/修改系统设置/
  //      通知使用权/闹钟和提醒/使用情况访问/ WLAN 控制）
  //   ✅ 应用管理 —— 可用，列出容器内应用名 + 占用空间（冷启动约 10 秒）
  //   ❌ 无障碍 —— 页面能启动会渲染，但渲染完立刻被系统安全策略关闭
  //      （WMS 日志：enableShow change from true to false → aboutToDisappear）
  //
  // 【重要：等待时间】容器内 Activity 冷启动需 8-10 秒。只等 3-4 秒就 dumpLayout
  // 会把「可用」误判成「Activity 不存在」—— 早期报告的错误就是这么来的。
  //
  // 【关键：$ 转义】
  // Activity 名含 `$`（内部类），必须写成 "....Settings\$XxxActivity"：
  //   - 外层双引号保护整个 activity 名（避免被拆词）
  //   - \$ 防止 daemon 的 sh -c 把 $NotificationAccessSettingsActivity 当变量展开为空
  // 实测不转义时 sh 会展开成 com.android.settings.Settings，启动失败退回桌面。
  //
  // 【能力检测】宿主机上判断是否装了卓易通，看 com.droi.tong 是否在应用列表，
  // 不能用 grep android/anco —— 容器包的 bundleName 里没有这两个词。

  /** 通知使用权页 ✅ 真机验证可用（卓易通内应用的隐藏权限页） */
  static openNotificationAccess(): string {
    return `aa start -b com.android.settings -a "com.android.settings.Settings\\$NotificationAccessSettingsActivity"`;
  }

  /** 无障碍设置 ❌ 真机验证：Activity 不存在，界面退回桌面 */
  static openAccessibility(): string {
    return `aa start -b com.android.settings -a "com.android.settings.Settings\\$AccessibilitySettingsActivity"`;
  }

  /** 特殊应用权限 ✅ 真机验证可用（7 个条目完整列出，冷启动约 8-10 秒） */
  static openSpecialAccess(): string {
    return `aa start -b com.android.settings -a "com.android.settings.Settings\\$SpecialAccessSettingsActivity"`;
  }

  /** 容器内应用管理 ✅ 真机验证可用（列出应用名+大小，冷启动约 10 秒） */
  static openManageApplications(): string {
    return `aa start -b com.android.settings -a "com.android.settings.Settings\\$ManageApplicationsActivity"`;
  }

  /** 检测是否装了卓易通（容器宿主）✅ */
  static hasZhuoyitong(): string {
    return 'bm dump -a | grep -c com.droi.tong';
  }

  /** 检测是否装了出境易 ✅ */
  static hasChujingyi(): string {
    return 'bm dump -a | grep -c com.easy.hmos.abroad';
  }

  // ===== 通用 =====
  static raw(command: string): string { return command; }
  static id(): string { return 'id'; }
}
