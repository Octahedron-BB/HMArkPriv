/**
 * HMArkPriv 主页面
 *
 * 底部 Tab 导航（5 个）：
 * - 首页：快捷操作面板 + daemon 状态
 * - 终端：Shell 终端控制台（核心功能）
 * - 应用：应用管理（Phase 3 已实装）
 * - 开放：跨应用调用（白名单 / 极速总线令牌 / 审计日志）
 * - 系统：电源与屏幕（充电时不熄屏）+ 设备信息
 *
 * 验收标准：在终端 Tab 输入 `id`，看到 `uid=2000(shell)` 输出。
 */

import { BusClient } from '../services/BusClient';
import { BusDirManager } from '../services/BusDirManager';
import { BatteryReader } from '../services/BatteryReader';
import { BatteryWatcher } from '../services/BatteryWatcher';
import { TerminalConsole } from '../components/TerminalConsole';
import { DaemonStatusCard } from '../components/DaemonStatusCard';
import { OpenApiTab } from '../components/OpenApiTab';
import { AppManageTab } from '../components/AppManageTab';
import { CrossAppHandler, PendingCall } from '../services/CrossAppHandler';
import { TrustManager } from '../services/TrustManager';
import { CommandBuilder } from '../utils/CommandBuilder';
import { ResponseParser } from '../utils/ResponseParser';
import { CommandResult } from '../model/CommandResult';
import { DEFAULT_BUS_DIR } from '../common/Constants';
import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

@Entry
@Component
struct Index {
  @State currentTab: number = 0;
  @State cmdHistory: string[] = [];
  @State daemonOnline: boolean = false;
  @State daemonPid: number = 0;
  @State daemonUid: number = 0;
  @State lastResult: string = '';
  @State isExecuting: boolean = false;
  @State busDirUri: string = '';
  @State needAuth: boolean = false;
  @State permDenied: boolean = false;
  /** 正在初始化总线（UI 显示"连接中"，避免误显示为离线/未授权） */
  @State connecting: boolean = true;
  /** 是否有待确认的外部调用（用基础类型，ArkTS 对 nullable 对象的状态追踪不可靠） */
  @State hasPending: boolean = false;
  /** 待确认请求的调用方 */
  @State pendingCaller: string = '';
  /** 待确认请求的命令 */
  @State pendingCmd: string = '';
  /** 是否为极速总线模式令牌申请 */
  @State isTokenRequest: boolean = false;
  /** 充电防熄屏开关 */
  @State stayAwakeWhileCharging: boolean = false;
  /** 当前是否在充电（用于开关行的副标题提示） */
  /**
   * 是否已插电（不是"是否正在充电"）。
   *
   * 两者必须区分：本机插着 USB 且电量满时 chargingStatus=3(FULL)、
   * pluggedType=2(USB)。只看 chargingStatus 会显示"未充电"，用户会以为没插电。
   * "充电时不熄屏"关心的是有没有外部供电，所以用 plugged。
   */
  @State isCharging: boolean = false;
  /** daemon 记账：是否处于超时覆盖（常亮）状态 */
  @State screenOverride: boolean = false;
  /** daemon 记账：override 的具体毫秒值 */
  @State screenOverrideMs: number = 0;
  /** daemon 探测到的屏幕亮灭（on / off / unknown） */
  @State screenRealState: string = 'unknown';
  /** daemon 从系统日志读到的充电状态（yes / no / unknown） */
  @State daemonCharging: string = 'unknown';
  /** 上一次已下发的屏幕指令，用于幂等（避免每 3 秒重复发同一条命令） */
  private awakeApplied: string = '';
  /** 充电状态上报定时器 */
  private chargeTimerId: number = -1;
  private busClient: BusClient = new BusClient(DEFAULT_BUS_DIR);

  aboutToAppear(): void {
    // 注册外部调用监听：有外部 App 请求时会拉起确认卡片
    CrossAppHandler.setListener(() => {
      this.syncPending();
    });
    // 兜底：如果监听注册前就已有 pending，主动读一次
    this.syncPending();
    this.initBusDir();
  }

  aboutToDisappear(): void {
    this.stopChargeReporting();
    // 【注意】这里**不**撤销常亮。常亮是 daemon 侧的全局状态，属于"充电时不熄屏"
    // 这个设备级设置：用户关掉 App 后插着电也应该继续常亮（与 Android 语义一致）。
    // 撤销责任归 daemon（退出时 trap + 启动时无条件清理），不归 UI 生命周期。
  }

  /** 页面可见时开始上报充电状态（切后台就停） */
  onPageShow(): void {
    this.startChargeReporting();
    this.refreshScreenState();
  }

  /**
   * 切后台只停止轮询。
   *
   * 之前这里会撤销常亮，是因为当时用的是窗口级 setWindowKeepScreenOn（窗口不可见
   * 就失效）。现在改回 daemon 的 timeout 方案，全局生效，切后台应当继续常亮。
   */
  onPageHide(): void {
    this.stopChargeReporting();
  }

  /**
   * 开始上报充电状态。
   *
   * daemon 读不到充电状态（hilog 里没有 pluggedType，/sys 被 SELinux 拒绝），
   * 只能由 App 用 @ohos.batteryInfo 读出来写进 config.json。
   * 每 3 秒一次，同时刷新 heartbeat，让 daemon 知道 App 还活着。
   */
  startChargeReporting(): void {
    this.stopChargeReporting();
    this.tickCharge();
    this.chargeTimerId = setInterval(() => {
      this.tickCharge();
    }, 3000);
  }

  stopChargeReporting(): void {
    if (this.chargeTimerId >= 0) {
      clearInterval(this.chargeTimerId);
      this.chargeTimerId = -1;
    }
  }

  tickCharge(): void {
    const dir = this.busClient.getBusDir();
    if (!dir || this.needAuth) {
      return;
    }
    const snap = BatteryReader.read();
    this.isCharging = snap.plugged;
    TrustManager.reportCharging(snap.plugged, dir);
    // 【诊断】订阅系统电量广播，验证切后台后回调是否仍触发（幂等，只订阅一次）
    BatteryWatcher.start(dir);
    // 顺带维护「充电常亮」状态；并刷新 daemon 记录的真实状态。
    // 放在这里而不是只放在 onPageShow，是因为 onPageShow 可能早于 initBusDir
    // 完成（实测早 33ms），那时 busDir 还是空，读不到 screen_state.txt。
    this.syncAwakeLock();
    this.refreshScreenState();
  }

  /**
   * 同步「充电常亮」。
   *
   * 【实现演进（三次，前两次都不对，记下来免得再走回头路）】
   * 1) `power-shell timeout -o 86400000`：把屏幕超时覆盖成 24 小时。
   *    方法本身没问题（用户认可），但必须负责还原，还原失败就成"幽灵常亮"。
   * 2) `runningLock` + `RunningLockType.BACKGROUND`：**完全无效**。
   *    该类型是"屏幕灭了别让系统睡"，不是"别让屏幕灭"，API 10 起已废弃，
   *    三方应用也拿不到 SCREEN 类型。调用不报错，所以看着像生效。
   * 3) `window.setWindowKeepScreenOn()`：能生效（实测 SCREEN 锁 +1），
   *    但**仅前台窗口有效**，切后台就没了，不是用户要的"充电时不熄屏"。
   *
   * 【现在】回到 1) 的 timeout 方案，但把「谁来做、谁来回读」交给了 daemon：
   *   - daemon 常驻，App 被杀了它还在，还原责任不会丢给 UI 生命周期
   *   - 状态记账也由 daemon 做（`screen_state.txt`），App 侧不再猜
   *   - 同时规避了一个致命坑：`hidumper -a -t` 会挂一把 POWermgr 内的永久
   *     常亮锁，只有 `-a -f` 能解，`timeout -r` 解不掉（见 docs/TODO.md 5.0.4）
   *
   * App 只负责表达意图：充电 且 开关开 → 发 on，否则发 off。幂等，可重复发。
   */
  syncAwakeLock(): void {
    const shouldHold = this.stayAwakeWhileCharging && this.isCharging;
    const cmd = shouldHold ? '__hmpriv_screen_on' : '__hmpriv_screen_off';
    if (this.awakeApplied === cmd) {
      return; // 已经是这个意图，不重复打扰 daemon
    }
    if (this.needAuth || !this.busClient.getBusDir()) {
      return; // 还没连通总线，等 initBusDir 完成后再同步
    }
    this.awakeApplied = cmd;
    this.busClient.execute(cmd).then((r: CommandResult) => {
      hilog.info(0x9201, 'Index', `screen ${cmd} -> rc=${r.exitCode} ${r.output.trim()}`);
      this.refreshScreenState();
    }).catch((e: Error) => {
      // 失败了要允许下次重试，否则会一直卡在"以为已应用"
      this.awakeApplied = '';
      hilog.error(0x9201, 'Index', `screen ${cmd} failed: ${e.message}`);
    });
  }

  /**
   * 读取 daemon 写的真实屏幕状态，显示在开关下方。
   *
   * 为什么不像以前那样自己读 settings：settings 里只有用户设的基准值，
   * override 不落到数据库（是 powermgr 的内存态），所以以前那栏"当前熄屏时间"
   * 永远是系统设置值，没有意义。现在由 daemon 记账 + 探测真实亮灭。
   */
  refreshScreenState(): void {
    const dir = this.busClient.getBusDir();
    if (!dir) {
      return;
    }
    try {
      const path = `${dir}/screen_state.txt`;
      if (!fileIo.accessSync(path)) {
        return;
      }
      const txt = fileIo.readTextSync(path);
      const get = (key: string): string => {
        const m = txt.match(new RegExp(`${key}=([^\\n]*)`));
        return m ? m[1].trim() : '';
      };
      const ov = get('override');
      const to = get('timeout');
      const sc = get('screen');
      this.screenOverride = ov === '1';
      this.screenOverrideMs = to ? Number.parseInt(to, 10) : 0;
      this.screenRealState = sc;
      const ch = get('charging');
      this.daemonCharging = ch.length > 0 ? ch : 'unknown';
    } catch (e) {
      hilog.warn(0x9201, 'Index', `refreshScreenState: ${(e as Error).message}`);
    }
  }

  /**
   * 初始化总线目录。
   *
   * 真机上的实际行为（已实测）：
   *   - 未授权时读总线文件报 13900001 Operation not permitted
   *   - picker 授权后立即可读写，但**授权只对当前进程有效**
   *   - 因此启动时必须先用 fileShare.activatePermission 重新激活持久化授权
   *
   * 流程：
   *   1. 有持久化 URI → 激活它 → 验证可读 → 完成
   *   2. 直接探测绝对路径（模拟器 / 某些设备可能本来就通）
   *   3. 都不行 → 显示授权提示条，等用户点 picker
   */
  /** 同步待确认状态到 UI（用基础类型，确保 ArkUI 能感知变化） */
  syncPending(): void {
    const p = CrossAppHandler.getPending();
    if (p) {
      hilog.info(0x9201, 'Index', `syncPending: ${p.caller} -> ${p.cmd} (tokenReq=${p.isTokenRequest})`);
      this.pendingCaller = p.caller;
      this.pendingCmd = p.cmd;
      this.isTokenRequest = p.isTokenRequest ?? false;
      this.hasPending = true;
    } else {
      this.hasPending = false;
      this.pendingCaller = '';
      this.pendingCmd = '';
      this.isTokenRequest = false;
    }
  }

  async initBusDir(): Promise<void> {
    const ctx = getContext(this) as common.UIAbilityContext;
    this.connecting = true;

    // 1. 先尝试激活已持久化的 URI 授权（真机必需，否则重启后失效）
    const saved = await BusDirManager.loadBusDir(ctx);
    if (saved) {
      const activated = await BusDirManager.activateBusUri(saved);
      hilog.info(0x9201, 'Index', `activate saved uri: ${activated}`);
    }

    BusDirManager.probeAllCandidates();

    // 2. 探测绝对路径是否可读。
    // 【重要】activatePermission 之后权限生效可能有毫秒级延迟，
    // 直接读一次容易失败。这里重试若干次，避免误判为"未授权"。
    let dir = BusDirManager.findAccessibleBusDir();
    let readable = false;
    for (let i = 0; i < 5 && dir; i++) {
      if (BusDirManager.canReadBus(dir)) {
        readable = true;
        break;
      }
      await new Promise<void>((r) => setTimeout(r, 120));
    }

    if (dir && readable) {
      const ok = BusDirManager.ensureBusFilesIn(dir);
      this.busDirUri = dir;
      this.busClient.setBusDir(dir);
      this.needAuth = false;
      this.permDenied = false;
      this.connecting = false;
      this.stayAwakeWhileCharging = TrustManager.isStayAwakeWhileCharging(dir);
      this.refreshDaemonStatus();
      // 总线通了才读得到 screen_state.txt，且要顺带把「开关意图」推给 daemon：
      // 用户上次开着开关、但期间 daemon 重启过（启动时无条件清理），
      // 这时 daemon 侧是"无覆盖"，必须由 App 主动重新下发一次。
      this.refreshScreenState();
      this.syncAwakeLock();
      // 清理旧版明文令牌残留（幂等，没有残留时不做任何事）
      TrustManager.purgeLegacyTokens(ctx, dir);
      if (!ok) {
        this.lastResult = `总线可读，但部分文件初始化失败：\n${dir}`;
      }
      return;
    }

    // 3. 绝对路径不行，试持久化的 URI 本身
    if (saved && BusDirManager.canReadBus(saved)) {
      this.busDirUri = saved;
      this.busClient.setBusDir(saved);
      this.needAuth = false;
      this.permDenied = false;
      this.connecting = false;
      this.refreshDaemonStatus();
      return;
    }

    // 4. 需要用户授权
    if (dir) {
      this.busDirUri = dir;
      this.busClient.setBusDir(dir);
    }

    this.needAuth = true;
    this.daemonOnline = false;
    this.connecting = false;
  }

  /**
   * 授权：先请求 DOWNLOAD 目录权限，失败再降级 picker。
   * 正常情况下 initBusDir 已经直接连通，不会走到这里。
   */
  async authBusDir(): Promise<void> {
    const ctx = getContext(this) as common.UIAbilityContext;

    // 第一步：申请媒体权限
    const granted = await BusDirManager.requestDownloadPermission(ctx);

    // 第二步：验证权限是否已让总线可用
    let dir = BusDirManager.findAccessibleBusDir();
    if (dir && BusDirManager.canReadBus(dir)) {
      const ok = BusDirManager.ensureBusFilesIn(dir);
      this.busDirUri = dir;
      this.busClient.setBusDir(dir);
      this.needAuth = false;
      this.permDenied = false;
      this.lastResult = ok ? `总线可用：\n${dir}` : `可读但初始化失败：\n${dir}`;
      this.refreshDaemonStatus();
      return;
    }

    // 第三步：降级到系统目录选择器。
    // 【重要】picker 返回的是 URI（file://docs/...），不能拿它直接拼子文件路径
    // （实测报 13900002 No such file or directory）。picker 的作用是给 App 授予
    // 该目录的"访问许可"，授权后应当重新探测**绝对路径**来使用。
    this.lastResult = `媒体权限${granted ? '已授予' : '未授予'}，需要选择总线目录。\n` +
      `请在文件选择器中依次进入「我的手机 > Download」，选中 HMArkPriv 后确认。`;
    const uri = await BusDirManager.pickBusDir(ctx);
    if (!uri) {
      this.permDenied = true;
      this.needAuth = true;
      this.lastResult = '未选择目录。可重试，或在系统设置中授予「文件」访问权限。';
      return;
    }

    // 第四步：授权已生效，重新探测绝对路径（关键：不用 URI）
    dir = BusDirManager.findAccessibleBusDir();
    const readable = dir ? BusDirManager.canReadBus(dir) : false;

    if (dir && readable) {
      const ensured = BusDirManager.ensureBusFilesIn(dir);
      this.busDirUri = dir;
      this.busClient.setBusDir(dir);
      this.needAuth = false;
      this.permDenied = false;
      this.lastResult = `授权成功，总线可用：\n${dir}` +
        (ensured ? '' : '\n（注意：部分总线文件创建失败）');
      this.refreshDaemonStatus();
      return;
    }

    // 第五步：绝对路径仍不可用，最后尝试直接用 URI 访问
    const uriReadable = BusDirManager.canReadBus(uri);
    if (uriReadable) {
      this.busDirUri = uri;
      this.busClient.setBusDir(uri);
      this.needAuth = false;
      this.permDenied = false;
      this.lastResult = `授权成功（URI 模式）：\n${uri}`;
      this.refreshDaemonStatus();
      return;
    }

    this.needAuth = true;
    this.permDenied = false;
    this.lastResult =
      `已选择：\n${uri}\n\n但总线文件仍不可读。\n` +
      `请确认选中的是 HMArkPriv 文件夹本身（不是 Download），并确保 daemon 已部署。`;
  }

  /**
   * 刷新 daemon 状态。
   *
   * 自愈逻辑：即使当前标记为 needAuth，也尝试检测一次 ——
   * 若这次读通了（说明授权在后台已生效），自动清除 needAuth。
   * 这样可以避免"授权后仍卡在未授权"的状态。
   */
  async refreshDaemonStatus(): Promise<void> {
    const status = await this.busClient.checkDaemonStatus();
    this.daemonOnline = status !== null;
    if (status) {
      this.daemonPid = status.pid;
      this.daemonUid = status.uid;
      // 检测成功说明总线通了，清掉未授权标记
      if (this.needAuth) {
        hilog.info(0x9201, 'Index', 'daemon reachable, clearing needAuth');
        this.needAuth = false;
        this.permDenied = false;
      }
    }
  }

  async execQuickCmd(cmd: string): Promise<void> {
    if (this.isExecuting) {
      return;
    }
    if (this.needAuth) {
      this.lastResult = '请先授权总线目录后再执行命令。';
      return;
    }
    this.isExecuting = true;
    const result: CommandResult = await this.busClient.execute(cmd);
    this.lastResult = `[CMD] ${cmd}\n${result.output}`;
    this.isExecuting = false;
  }

  /**
   * 切换「充电时不熄屏」。
   *
   * 开关只表达意图（写 preferences），真正的动作由 daemon 执行：
   *   on  → `hidumper -a -f` 清残锁，再 `power-shell timeout -o 86400000`
   *   off → `power-shell timeout -r` + `hidumper -a -f` 双清理
   * 这样即使 App 被杀，还原责任仍在常驻的 daemon 身上。
   */
  toggleStayAwakeWhileCharging(isOn: boolean): void {
    this.stayAwakeWhileCharging = isOn;
    const busDir = this.busClient.getBusDir();
    TrustManager.setStayAwakeWhileCharging(isOn, busDir);

    // 清掉幂等标记，强制 syncAwakeLock 重新评估并下发一次。
    // 不在这里额外 execute 一遍：否则"关掉"会在同一时刻发两条 off（实测复现过）。
    this.awakeApplied = '';
    this.syncAwakeLock();
    this.refreshScreenState();

    if (!isOn) {
      this.lastResult = '已关闭「充电时不熄屏」：已恢复系统熄屏设置。';
      return;
    }

    this.lastResult = this.isCharging
      ? '已开启「充电时不熄屏」：已插电，屏幕将不再自动熄灭。'
      : '已开启「充电时不熄屏」：当前未插电，插上后生效。';
  }

  /** 电池：走原生 API（hidumper -s BatteryService 实测拿不到数据） */
  readBattery(): void {
    const b = BatteryReader.read();
    if (!b.present && b.level < 0) {
      this.lastResult = '电池：设备未上报电池信息\n' +
        '（模拟器无真实电池硬件；真机应可读到）';
      return;
    }
    const lines: string[] = [];
    lines.push('电池信息（原生 API）');
    lines.push(`电量    : ${b.level >= 0 ? b.level + '%' : '未知'}`);
    lines.push(`状态    : ${b.charging ? '充电中' : '未充电'}`);
    lines.push(`温度    : ${b.temperature >= 0 ? b.temperature.toFixed(1) + '°C' : '未知'}`);
    lines.push(`电压    : ${b.voltage >= 0 ? b.voltage.toFixed(3) + 'V' : '未知'}`);
    lines.push(`充电器  : ${b.plugType}`);
    lines.push(`健康    : ${b.health}`);
    this.lastResult = lines.join('\n');
  }

  /** 前台应用：用 uitest dumpLayout 落盘后解析（aa dump -l 输出抓不到） */
  async queryForegroundApp(): Promise<void> {
    if (this.isExecuting || this.needAuth) {
      return;
    }
    this.isExecuting = true;
    const result: CommandResult = await this.busClient.execute(CommandBuilder.foregroundAppProbe());
    const fg = ResponseParser.parseForegroundFromLayout(result.output);
    if (fg) {
      const isDesktop = fg.includes('sceneboard');
      this.lastResult = `前台应用：${fg}\n` +
        (isDesktop ? '（当前在桌面）' : '') +
        `\n[说明] aa dump -l 的输出无法被 shell 捕获，故改用 uitest dumpLayout 解析。`;
    } else {
      this.lastResult = `未能识别前台应用。\n原始输出长度：${result.output.length}`;
    }
    this.isExecuting = false;
  }

  /**
   * 已装应用：执行 bm dump -a 并用 ResponseParser 解析。
   * 实测输出是「TAB + 包名」格式（非 bundleName:），解析逻辑已适配。
   */
  async queryAppList(): Promise<void> {
    if (this.isExecuting || this.needAuth) {
      return;
    }
    this.isExecuting = true;
    const result: CommandResult = await this.busClient.execute(CommandBuilder.listApps());
    const apps = ResponseParser.parseAppList(result.output);
    if (apps.length === 0) {
      this.lastResult = `解析失败：未识别到包名。\n原始输出前 300 字符：\n${result.output.substring(0, 300)}`;
    } else {
      const preview = apps.slice(0, 15).map((a) => a.bundleName).join('\n');
      this.lastResult = `已装应用：共 ${apps.length} 个（解析成功）\n\n` +
        `前 15 个：\n${preview}` +
        (apps.length > 15 ? `\n... 还有 ${apps.length - 15} 个` : '');
    }
    this.isExecuting = false;
  }

  /** 系统参数：解析后用结构化展示 */
  async querySystemParams(): Promise<void> {
    if (this.isExecuting || this.needAuth) {
      return;
    }
    this.isExecuting = true;
    const result: CommandResult = await this.busClient.execute(CommandBuilder.systemParams());
    const params = ResponseParser.parseSystemParams(result.output);
    const keys: string[] = ['const.product.model', 'const.product.brand',
      'const.product.software.version', 'const.ohos.apiversion',
      'const.product.cpu.abilist'];
    const lines: string[] = [`系统参数：共 ${params.size} 项`, ''];
    for (const k of keys) {
      const v = params.get(k);
      if (v !== undefined) {
        lines.push(`${k}\n  = ${v}`);
      }
    }
    this.lastResult = lines.join('\n');
    this.isExecuting = false;
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      this.MainContent()

      // ===== 外部调用确认卡片（覆盖层）=====
      if (this.hasPending) {
        this.ConfirmCard()
      }
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  MainContent() {
    Column() {
      // 顶部标题栏
      Row() {
        Text('HMArkPriv')
          .fontSize(18)
          .fontColor('#38BDF8')
          .fontWeight(FontWeight.Bold)

        Blank()

        // Daemon 状态指示
        Row() {
          Circle({ width: 8, height: 8 })
            .fill(this.connecting ? '#FBBF24'
              : (this.daemonOnline ? '#4ADE80' : (this.needAuth ? '#FBBF24' : '#F87171')))
          Text(this.connecting ? '连接中'
            : (this.daemonOnline ? `UID:${this.daemonUid}` : (this.needAuth ? '未授权' : 'OFFLINE')))
            .fontSize(11)
            .fontColor(this.connecting ? '#FBBF24'
              : (this.daemonOnline ? '#94A3B8' : (this.needAuth ? '#FBBF24' : '#F87171')))
            .margin({ left: 4 })
        }
        .onClick(() => this.refreshDaemonStatus())
      }
      .width('100%')
      .height(44)
      .padding({ left: 16, right: 16 })
      .backgroundColor('#0D1527')

      // 授权提示条
      if (this.needAuth) {
        Row() {
          Column() {
            Text(this.permDenied ? '需要下载目录权限' : '需要授权下载目录')
              .fontSize(13)
              .fontColor('#FBBF24')
              .fontWeight(FontWeight.Bold)
            Text(this.permDenied
              ? '权限被拒绝，请在系统设置中手动开启'
              : '点「授权」允许访问下载目录，App 将自动创建总线文件')
              .fontSize(11)
              .fontColor('#94A3B8')
              .margin({ top: 2 })
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)

          Button('授权')
            .fontSize(12)
            .height(30)
            .backgroundColor('#FBBF24')
            .fontColor('#090D16')
            .onClick(() => this.authBusDir())
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 10, bottom: 10 })
        .backgroundColor('#2A2415')
      }

      // Tab 内容区
      Tabs({ barPosition: BarPosition.End, index: this.currentTab }) {
        // Tab 1: 首页
        TabContent() {
          this.HomeTab()
        }
        .tabBar(this.TabItem('首页', 0))

        // Tab 2: 终端（Phase 1 核心）
        TabContent() {
          this.TerminalTab()
        }
        .tabBar(this.TabItem('终端', 1))

        // Tab 3: 应用管理（Phase 3 实装）
        TabContent() {
          AppManageTab({ busClient: this.busClient })
        }
        .tabBar(this.TabItem('应用', 2))

        // Tab 4: 开放接口（跨应用调用白名单管理）
        TabContent() {
          OpenApiTab({ busClient: this.busClient })
        }
        .tabBar(this.TabItem('开放', 3))

        // Tab 5: 系统
        TabContent() {
          this.SystemTab()
        }
        .tabBar(this.TabItem('系统', 4))
      }
      .layoutWeight(1)
      .barMode(BarMode.Fixed)
      .onChange((index: number) => {
        this.currentTab = index;
      })
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#0D1527')
  }

  @Builder
  TabItem(label: string, index: number) {
    Column() {
      Text(label)
        .fontSize(this.currentTab === index ? 13 : 12)
        .fontColor(this.currentTab === index ? '#38BDF8' : '#64748B')
        .fontWeight(this.currentTab === index ? FontWeight.Bold : FontWeight.Normal)
    }
    .width('100%')
    .height(48)
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  HomeTab() {
    Scroll() {
      Column() {
        // Daemon 状态卡片
        DaemonStatusCard({ busClient: this.busClient })
          .margin({ bottom: 12 })

        // 部署引导
        Column() {
          Text('使用步骤')
            .fontSize(13)
            .fontColor('#94A3B8')
            .fontWeight(FontWeight.Bold)
            .margin({ bottom: 6 })

          Text('① 电脑部署 daemon（一次性）\n' +
               '   hdc file send core/daemon.sh /data/local/tmp/hmpriv/daemon.sh\n' +
               '   hdc shell "nohup sh /data/local/tmp/hmpriv/daemon.sh >/dev/null 2>&1 &"\n\n' +
               '② 首次使用：点顶部「授权」\n' +
               '   在文件选择器里进入「我的手机 > Download」，\n' +
               '   选中 HMArkPriv 文件夹并确认\n' +
               '   （授权会被记住，之后启动自动连接，无需再选）\n\n' +
               '③ 切到「终端」Tab，输入 id 验证\n' +
               '   应返回 uid=2000(shell)')
            .fontSize(11)
            .fontColor('#64748B')
            .fontFamily('JetBrains Mono, Consolas, monospace')
            .lineHeight(17)
        }
        .width('100%')
        .padding(12)
        .backgroundColor('#1A2332')
        .borderRadius(12)
        .margin({ bottom: 12 })
        .alignItems(HorizontalAlign.Start)

        // 快捷操作
        Text('快捷操作')
          .fontSize(13)
          .fontColor('#94A3B8')
          .fontWeight(FontWeight.Bold)
          .margin({ bottom: 8 })
          .width('100%')

        // 屏幕控制
        // 只保留「熄屏」。「唤醒」已移除 —— 锁屏时用户点不到这个按钮，
        // 而且系统本身有音量键/电源键可以唤醒，这个入口没有实际价值。
        this.SectionLabel('屏幕控制')
        Flex({ wrap: FlexWrap.Wrap }) {
          this.QuickBtn('熄屏', CommandBuilder.suspend())
        }
        .width('100%')
        .margin({ bottom: 8 })

        // 按键模拟
        this.SectionLabel('按键模拟')
        Flex({ wrap: FlexWrap.Wrap }) {
          this.QuickBtn('Home', CommandBuilder.keyPress(1))
          this.QuickBtn('Back', CommandBuilder.keyPress(2))
          this.QuickBtn('Vol+', CommandBuilder.keyPress(16))
          this.QuickBtn('Vol-', CommandBuilder.keyPress(17))
          this.QuickBtn('Power', CommandBuilder.keyPress(18))
        }
        .width('100%')
        .margin({ bottom: 8 })

        // 应用信息（电池/系统参数等已移到「系统」Tab，避免重复）
        this.SectionLabel('应用信息')
        Flex({ wrap: FlexWrap.Wrap }) {
          this.QuickBtn('应用列表', '')
          this.QuickBtn('前台应用', '')
        }
        .width('100%')
        .margin({ bottom: 8 })

        // 最后执行结果
        if (this.lastResult) {
          Column() {
            Text('最近执行结果')
              .fontSize(11)
              .fontColor('#94A3B8')
              .margin({ bottom: 4 })

            Text(this.lastResult)
              .fontSize(11)
              .fontColor('#C3E88D')
              .fontFamily('JetBrains Mono, Consolas, monospace')
              .maxLines(15)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .width('100%')
          .padding(10)
          .backgroundColor('#1A2332')
          .borderRadius(8)
          .margin({ top: 8 })
          .alignItems(HorizontalAlign.Start)
        }
      }
      .width('100%')
      .padding(12)
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Auto)
  }

  @Builder
  TerminalTab() {
    Column() {
      // 终端控制台组件
      TerminalConsole({
        busClient: this.busClient,
        cmdHistory: $cmdHistory,
        needAuth: this.needAuth,
        daemonOnline: this.daemonOnline,
        daemonPid: this.daemonPid,
        onRequestAuth: () => {
          this.authBusDir();
        },
      })
    }
    .width('100%')
    .height('100%')
    .padding(12)
  }


  /**
   * 外部调用确认卡片。
   *
   * 设计要点：
   *   - 遮罩层挡住整个界面，防止用户误点其他地方
   *   - 明确显示「谁」在调用、「要执行什么命令」
   *   - 三个选项：仅本次允许 / 加入白名单并允许 / 拒绝
   *   - 拒绝时可选「不再询问」= 加入黑名单
   */
  @Builder
  ConfirmCard() {
    // 半透明遮罩
    Column()
      .width('100%')
      .height('100%')
      .backgroundColor('#CC000000')

    Column() {
      // 标题
      Row() {
        Text(this.isTokenRequest ? '🔑' : '🔐')
          .fontSize(20)
          .margin({ right: 8 })
        Text(this.isTokenRequest ? '申请「极速总线模式」授权令牌' : '外部应用请求执行命令')
          .fontSize(15)
          .fontColor('#E2E8F0')
          .fontWeight(FontWeight.Bold)
          .layoutWeight(1)
      }
      .width('100%')
      .margin({ bottom: 12 })

      // 调用方
      Text('调用方应用')
        .fontSize(11)
        .fontColor('#64748B')
        .width('100%')
      Text(this.pendingCaller)
        .fontSize(13)
        .fontColor('#82B1FF')
        .fontFamily('JetBrains Mono, Consolas, monospace')
        .width('100%')
        .margin({ top: 2, bottom: 12 })

      // 内容说明
      Text(this.isTokenRequest ? '申请权限' : '要执行的命令')
        .fontSize(11)
        .fontColor('#64748B')
        .width('100%')
      Text(this.pendingCmd)
        .fontSize(13)
        .fontColor('#C3E88D')
        .fontFamily('JetBrains Mono, Consolas, monospace')
        .width('100%')
        .padding(10)
        .backgroundColor('#0D1527')
        .borderRadius(6)
        .margin({ top: 4, bottom: 12 })

      // 风险提示
      Text(this.isTokenRequest
        ? '⚠️ 极速总线令牌允许该应用在后台通过队列槽位静默执行特权 shell 指令，无需每次弹窗确认。请确保你完全信任此应用。'
        : '该命令将以 shell（UID 2000）权限执行，可能读写文件、模拟输入或修改系统设置。')
        .fontSize(11)
        .fontColor('#FBBF24')
        .lineHeight(16)
        .width('100%')
        .margin({ bottom: 16 })

      // 按钮组
      Column() {
        if (this.isTokenRequest) {
          // 令牌申请确认
          Button('同意并签发令牌')
            .width('100%')
            .fontSize(13)
            .height(40)
            .backgroundColor('#38BDF8')
            .fontColor('#090D16')
            .margin({ bottom: 8 })
            .onClick(async () => {
              const ctx = getContext(this) as common.UIAbilityContext;
              const caller = this.pendingCaller;
              this.hasPending = false;
              // 自动将该应用加入白名单，并签发令牌
              await TrustManager.addTrusted(ctx, caller);
              await CrossAppHandler.approve();
            })
        } else {
          // 主要操作：本次允许
          Button('允许执行（仅本次）')
            .width('100%')
            .fontSize(13)
            .height(40)
            .backgroundColor('#38BDF8')
            .fontColor('#090D16')
            .margin({ bottom: 8 })
            .onClick(async () => {
              this.hasPending = false;
              await CrossAppHandler.approve();
            })

          // 加入白名单并允许
          Button('信任该应用，以后免确认')
            .width('100%')
            .fontSize(13)
            .height(40)
            .backgroundColor('#1E293B')
            .fontColor('#4ADE80')
            .margin({ bottom: 8 })
            .onClick(async () => {
              const ctx = getContext(this) as common.UIAbilityContext;
              const caller = this.pendingCaller;
              this.hasPending = false;
              // 先加白名单，再执行
              await TrustManager.addTrusted(ctx, caller);
              await CrossAppHandler.approve();
            })
        }

        // 拒绝
        Button('拒绝')
          .width('100%')
          .fontSize(13)
          .height(40)
          .backgroundColor('#2A1515')
          .fontColor('#F87171')
          .onClick(async () => {
            this.hasPending = false;
            await CrossAppHandler.deny(false);
          })
      }
      .width('100%')
    }
    .width('88%')
    .padding(20)
    .backgroundColor('#1A2332')
    .borderRadius(16)
    .shadow({ radius: 24, color: '#000000DD', offsetX: 0, offsetY: 8 })
  }

  /**
   * 系统 Tab：电源与屏幕、设备信息。
   *
   * 「充电时不熄屏」放在这里而不是首页 —— 它属于系统级电源策略，
   * 不是高频快捷操作。
   */
  @Builder
  SystemTab() {
    Scroll() {
      Column() {
        // ===== 电源与屏幕 =====
        this.SectionLabel('电源与屏幕')

        Row() {
          Row() {
            Text('⚡')
              .fontSize(16)
              .margin({ right: 8 })
            Column() {
              Text('充电时不熄屏')
                .fontSize(13)
                .fontColor('#E2E8F0')
                .fontWeight(FontWeight.Medium)
              Text(this.stayAwakeWhileCharging
                ? (this.isCharging ? '已开启 · 已插电，屏幕不会自动熄灭' : '已开启 · 未插电，插上后生效')
                : '已关闭（遵循系统熄屏设置）')
                .fontSize(10)
                .fontColor(this.stayAwakeWhileCharging
                  ? (this.isCharging ? '#4ADE80' : '#38BDF8')
                  : '#64748B')
                .margin({ top: 2 })
            }
            .alignItems(HorizontalAlign.Start)
          }
          .layoutWeight(1)

          Toggle({ type: ToggleType.Switch, isOn: this.stayAwakeWhileCharging })
            .selectedColor('#38BDF8')
            .onChange((isOn: boolean) => {
              this.toggleStayAwakeWhileCharging(isOn);
            })
        }
        .width('100%')
        .padding({ left: 12, right: 12, top: 10, bottom: 10 })
        .backgroundColor('#1A2332')
        .borderRadius(10)
        .margin({ bottom: 8 })

        // ===== 真实状态（来自 daemon 记账 + 屏幕亮灭探测）=====
        Row() {
          Text('当前状态')
            .fontSize(11)
            .fontColor('#94A3B8')
          Blank()
          Text(this.screenOverride
            ? `常亮覆盖中 · 每 5 分钟续期（单次上限 ${Math.round(this.screenOverrideMs / 60000)} 分钟）`
            : '无覆盖 · 使用系统超时')
            .fontSize(11)
            .fontColor(this.screenOverride ? '#F59E0B' : '#64748B')
        }
        .width('100%')
        .padding({ left: 12, right: 12, top: 8, bottom: 8 })
        .backgroundColor('#141C28')
        .borderRadius(10)
        .margin({ bottom: 8 })

        Row() {
          Text('屏幕')
            .fontSize(11)
            .fontColor('#94A3B8')
          Blank()
          Text(this.screenRealState === 'on'
            ? '亮'
            : (this.screenRealState === 'off' ? '灭' : '未知'))
            .fontSize(11)
            .fontColor(this.screenRealState === 'on'
              ? '#4ADE80'
              : (this.screenRealState === 'off' ? '#64748B' : '#475569'))
          Text(' · 来自系统日志，最多滞后 1 分钟')
            .fontSize(10)
            .fontColor('#475569')
        }
        .width('100%')
        .padding({ left: 12, right: 12, top: 8, bottom: 8 })
        .backgroundColor('#141C28')
        .borderRadius(10)
        .margin({ bottom: 8 })

        Row() {
          Text('充电')
            .fontSize(11)
            .fontColor('#94A3B8')
          Blank()
          Text(this.daemonCharging === 'yes'
            ? '已插电'
            : (this.daemonCharging === 'no' ? '未插电' : '未知'))
            .fontSize(11)
            .fontColor(this.daemonCharging === 'yes'
              ? '#4ADE80'
              : (this.daemonCharging === 'no' ? '#64748B' : '#475569'))
          Text(' · 依据 App 原生 API；切后台后沿用最后状态，最多 30 分钟')
            .fontSize(10)
            .fontColor('#475569')
        }
        .width('100%')
        .padding({ left: 12, right: 12, top: 8, bottom: 8 })
        .backgroundColor('#141C28')
        .borderRadius(10)
        .margin({ bottom: 8 })

        Text(this.stayAwakeWhileCharging
          ? '在前台时实时跟随插拔（拔线约 10 秒内撤销）。切到后台后沿用最后状态最多 30 分钟，之后自动撤销，不会一直残留。'
          : '开关打开后，插着充电器时屏幕不再自动熄灭。超时覆盖设为 10 分钟并每 5 分钟续期：daemon 万一退出，最多多亮 10 分钟就自行恢复。')
          .fontSize(10)
          .fontColor('#475569')
          .lineHeight(15)
          .width('100%')
          .padding({ left: 4, right: 4 })
          .margin({ bottom: 4 })

        // ===== 屏幕 =====
        this.SectionLabel('屏幕')

        Flex({ wrap: FlexWrap.Wrap }) {
          this.QuickBtn('立即熄屏', CommandBuilder.suspend())
        }
        .width('100%')
        .margin({ bottom: 12 })

        // ===== 设备信息 =====
        this.SectionLabel('设备信息')
        Flex({ wrap: FlexWrap.Wrap }) {
          this.QuickBtn('电池', '')
          this.QuickBtn('系统参数', '')
          this.QuickBtn('内存', CommandBuilder.memInfo())
          this.QuickBtn('CPU 负载', CommandBuilder.cpuLoad())
        }
        .width('100%')
        .margin({ bottom: 12 })

        // 最近一次读取结果
        if (this.lastResult) {
          Column() {
            Row() {
              Text('最近结果')
                .fontSize(11)
                .fontColor('#94A3B8')
                .layoutWeight(1)
              Text('清空')
                .fontSize(11)
                .fontColor('#64748B')
                .onClick(() => {
                  this.lastResult = '';
                })
            }
            .width('100%')
            .margin({ bottom: 6 })

            Text(this.lastResult)
              .fontSize(11)
              .fontColor('#C3E88D')
              .fontFamily('JetBrains Mono, Consolas, monospace')
              .lineHeight(17)
              .width('100%')
          }
          .width('100%')
          .padding(10)
          .backgroundColor('#1A2332')
          .borderRadius(8)
          .alignItems(HorizontalAlign.Start)
        }
      }
      .width('100%')
      .padding(12)
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Auto)
  }

  @Builder
  SectionLabel(label: string) {
    Text(label)
      .fontSize(11)
      .fontColor('#64748B')
      .margin({ bottom: 4 })
      .width('100%')
  }

  @Builder
  QuickBtn(label: string, cmd: string) {
    Button(label)
      .fontSize(12)
      .fontColor('#E2E8F0')
      .backgroundColor('#1E293B')
      .borderRadius(8)
      .height(32)
      .margin({ right: 6, bottom: 6 })
      .enabled(!this.isExecuting)
      .onClick(() => {
        // 特殊按钮走专用实现（原生 API / 落盘解析），其余走通用总线执行
        if (label === '电池') {
          this.readBattery();
        } else if (label === '前台应用') {
          this.queryForegroundApp();
        } else if (label === '应用列表') {
          this.queryAppList();
        } else if (label === '系统参数') {
          this.querySystemParams();
        } else {
          this.execQuickCmd(cmd);
        }
      })
  }
}
