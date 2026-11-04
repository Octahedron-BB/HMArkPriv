/**
 * HMArkPriv 主页面 — Phase 1 MVP
 *
 * 底部 Tab 导航：
 * - 首页：快捷操作面板 + daemon 状态
 * - 终端：Shell 终端控制台（核心功能）
 * - 应用：应用管理（Phase 3 占位）
 * - 触控：触控模拟（Phase 4 占位）
 * - 系统：系统信息（Phase 5 占位）
 *
 * 验收标准：在终端 Tab 输入 `id`，看到 `uid=2000(shell)` 输出。
 */

import { BusClient } from '../services/BusClient';
import { BusDirManager } from '../services/BusDirManager';
import { BatteryReader } from '../services/BatteryReader';
import { TerminalConsole } from '../components/TerminalConsole';
import { DaemonStatusCard } from '../components/DaemonStatusCard';
import { CommandBuilder } from '../utils/CommandBuilder';
import { ResponseParser } from '../utils/ResponseParser';
import { CommandResult } from '../model/CommandResult';
import { DEFAULT_BUS_DIR } from '../common/Constants';
import { common } from '@kit.AbilityKit';

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
  private busClient: BusClient = new BusClient(DEFAULT_BUS_DIR);

  aboutToAppear(): void {
    this.initBusDir();
  }

  /**
   * 初始化总线目录。
   *
   * 优先级：
   *   1. 直接探测：App 用沙箱视图路径 /storage/Users/currentUser/Download/HMArkPriv
   *      通常无需额外授权即可读写（配合已声明的 READ_MEDIA / WRITE_MEDIA）
   *   2. 申请 READ_WRITE_DOWNLOAD_DIRECTORY 权限后再探测
   *   3. 以上都不行 → 降级到 picker 让用户选目录
   */
  async initBusDir(): Promise<void> {
    // 1. 直接探测（诊断日志 + 可能的直访）
    BusDirManager.probeAllCandidates();
    const direct = BusDirManager.findAccessibleBusDir();
    if (direct) {
      const ok = BusDirManager.ensureBusFiles();
      this.busDirUri = direct;
      this.busClient.setBusDir(direct);
      this.needAuth = false;
      this.permDenied = false;
      this.refreshDaemonStatus();
      if (!ok) {
        this.lastResult = `总线目录可访问，但初始化总线文件失败：\n${direct}`;
      }
      return;
    }

    // 2. 申请权限后再探测
    const hasPerm = await BusDirManager.hasDownloadPermission();
    if (hasPerm) {
      const dir = BusDirManager.findAccessibleBusDir();
      if (dir) {
        BusDirManager.ensureBusFiles();
        this.busDirUri = dir;
        this.busClient.setBusDir(dir);
        this.needAuth = false;
        this.permDenied = false;
        this.refreshDaemonStatus();
        return;
      }
    }

    // 3. 之前 picker 存下来的 URI
    const ctx = getContext(this) as common.UIAbilityContext;
    const saved = await BusDirManager.loadBusDir(ctx);
    if (saved && BusDirManager.isAccessible(saved)) {
      this.busDirUri = saved;
      this.busClient.setBusDir(saved);
      this.needAuth = false;
      this.refreshDaemonStatus();
      return;
    }

    this.needAuth = true;
    this.daemonOnline = false;
  }

  /**
   * 授权：先请求 DOWNLOAD 目录权限，失败再降级 picker。
   * 正常情况下 initBusDir 已经直接连通，不会走到这里。
   */
  async authBusDir(): Promise<void> {
    const ctx = getContext(this) as common.UIAbilityContext;

    const granted = await BusDirManager.requestDownloadPermission(ctx);
    if (granted) {
      const dir = BusDirManager.findAccessibleBusDir();
      if (dir) {
        const ok = BusDirManager.ensureBusFiles();
        this.busDirUri = dir;
        this.busClient.setBusDir(dir);
        this.needAuth = false;
        this.permDenied = false;
        this.lastResult = ok
          ? `已授权并初始化总线目录：\n${dir}`
          : `已获得权限，但初始化总线文件失败：\n${dir}`;
        this.refreshDaemonStatus();
        return;
      }
    }

    // 权限拿不到 → 再探测一次（某些设备授权后立即可见）
    const probe = BusDirManager.findAccessibleBusDir();
    if (probe) {
      BusDirManager.ensureBusFiles();
      this.busDirUri = probe;
      this.busClient.setBusDir(probe);
      this.needAuth = false;
      this.permDenied = false;
      this.lastResult = `总线目录可用：\n${probe}`;
      this.refreshDaemonStatus();
      return;
    }

    // 最后降级 picker
    this.permDenied = true;
    const uri = await BusDirManager.pickBusDir(ctx);
    if (uri) {
      this.busDirUri = uri;
      this.busClient.setBusDir(uri);
      this.needAuth = !BusDirManager.isAccessible(uri);
      this.lastResult = this.needAuth
        ? `已选择目录但无法访问：\n${uri}`
        : `总线目录已授权：\n${uri}`;
      if (!this.needAuth) {
        this.refreshDaemonStatus();
      }
    } else {
      this.lastResult = '未获得目录访问权限。\n可在「设置 > 应用 > HMArkPriv > 权限」中手动开启「下载目录」。';
    }
  }

  async refreshDaemonStatus(): Promise<void> {
    if (this.needAuth) {
      return;
    }
    const status = await this.busClient.checkDaemonStatus();
    this.daemonOnline = status !== null;
    if (status) {
      this.daemonPid = status.pid;
      this.daemonUid = status.uid;
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
            .fill(this.daemonOnline ? '#4ADE80' : '#F87171')
          Text(this.needAuth ? '未授权' : (this.daemonOnline ? `UID:${this.daemonUid}` : 'OFFLINE'))
            .fontSize(11)
            .fontColor(this.needAuth ? '#FBBF24' : (this.daemonOnline ? '#94A3B8' : '#F87171'))
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

        // Tab 3: 应用管理（Phase 3 占位）
        TabContent() {
          this.PlaceholderTab('应用管理', 'Phase 3 开发中')
        }
        .tabBar(this.TabItem('应用', 2))

        // Tab 4: 触控模拟（Phase 4 占位）
        TabContent() {
          this.PlaceholderTab('触控模拟', 'Phase 4 开发中')
        }
        .tabBar(this.TabItem('触控', 3))

        // Tab 5: 系统信息（Phase 5 占位）
        TabContent() {
          this.PlaceholderTab('系统信息', 'Phase 5 开发中')
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
               '   hdc shell "sh /data/local/tmp/hmpriv/daemon.sh &"\n\n' +
               '② 回到本 App，点顶部「授权」\n' +
               '   允许访问「下载」目录即可，无需手动选文件夹\n' +
               '   App 会自动创建 Download/HMArkPriv 总线文件\n\n' +
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
        this.SectionLabel('屏幕控制')
        Flex({ wrap: FlexWrap.Wrap }) {
          this.QuickBtn('唤醒', CommandBuilder.wakeup())
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

        // 系统信息
        this.SectionLabel('系统信息')
        Flex({ wrap: FlexWrap.Wrap }) {
          this.QuickBtn('电池', '')
          this.QuickBtn('应用列表', '')
          this.QuickBtn('前台应用', '')
          this.QuickBtn('系统参数', '')
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
        onRequestAuth: () => {
          this.authBusDir();
        },
      })
    }
    .width('100%')
    .height('100%')
    .padding(12)
  }

  @Builder
  PlaceholderTab(title: string, subtitle: string) {
    Column() {
      Text(title)
        .fontSize(18)
        .fontColor('#64748B')
        .fontWeight(FontWeight.Bold)

      Text(subtitle)
        .fontSize(13)
        .fontColor('#475569')
        .margin({ top: 8 })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
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
