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

  /** 查询单个应用详情 ✅ 也用于判断是否已安装 */
  static appDetail(bundle: string): string {
    return `bm dump -n ${bundle}`;
  }

  /** 启动应用 ⚠️ 无输出，需先 appDetail 校验包存在 */
  static startApp(bundle: string, ability: string): string {
    return `aa start -b ${bundle} -a ${ability}`;
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

  // ===== 卓易通穿透 [模拟器无法验证] =====
  // 模拟器无安卓容器（bm dump -a | grep -i android 返回 RC=1），
  // 需在装有卓易通的真机上验证。
  static openNotificationAccess(): string {
    return `aa start -b com.android.settings -a com.android.settings.Settings$NotificationAccessSettingsActivity`;
  }
  static openAccessibility(): string {
    return `aa start -b com.android.settings -a com.android.settings.Settings$AccessibilitySettingsActivity`;
  }
  static openSpecialAccess(): string {
    return `aa start -b com.android.settings -a com.android.settings.Settings$SpecialAccessSettingsActivity`;
  }
  /** 检测设备是否装有卓易通/安卓容器 */
  static hasAndroidContainer(): string {
    return 'bm dump -a | grep -ci android';
  }

  // ===== 通用 =====
  static raw(command: string): string { return command; }
  static id(): string { return 'id'; }
}
