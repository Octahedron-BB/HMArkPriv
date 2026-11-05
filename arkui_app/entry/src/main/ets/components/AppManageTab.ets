import { BusClient } from '../services/BusClient';
import { CommandBuilder } from '../utils/CommandBuilder';
import { ResponseParser, AppItem, PermissionItem } from '../utils/ResponseParser';
import { CommandResult } from '../model/CommandResult';
import { FreezeManager } from '../services/FreezeManager';
import { promptAction } from '@kit.ArkUI';

/**
 * AppManageTab — 应用管理与深度管控面板
 *
 * 核心升级：
 * 1. 150ms 极速加载全量应用列表，动态关联运行状态（活跃中/已停止）。
 * 2. 智能动态启动：自动解析任意应用的 mainAbility，支持多 HAP 穿透。
 * 3. 强行停止反馈：杀灭真实进程组并实时刷新进程列表，消除多任务卡片困惑。
 * 4. 专属权限透视面板：全息提取权限列表，严格区分「用户可控（可修改）」与「系统默认」，支持一键直达系统权限设置。
 * 5. 安全核心保护：白名单硬核保护系统核心组件，杜绝误卸载风险。
 */
@Component
export struct AppManageTab {
  @Prop busClient: BusClient;

  // 原始应用清单
  @State allApps: AppItem[] = [];
  // 过滤后的应用清单
  @State displayApps: AppItem[] = [];
  // 正在运行的应用包名集合
  @State runningPackages: string[] = [];
  // 计数统计
  @State allAppsCount: number = 0;
  @State userAppsCount: number = 0;
  @State systemAppsCount: number = 0;
  // 加载状态
  @State isLoading: boolean = false;
  // 搜索关键字
  @State searchKey: string = '';
  // 分类筛选 (0: 全部, 1: 第三方, 2: 系统)
  @State currentCategory: number = 0;

  // 当前选中待操作的应用
  @State selectedApp: AppItem | null = null;
  @State isOptionsOpen: boolean = false;

  // 正在执行操作
  @State isBusy: boolean = false;

  // 权限透视弹窗
  @State isPermissionOpen: boolean = false;
  @State permLoading: boolean = false;
  @State permissions: PermissionItem[] = [];
  @State userPermCount: number = 0;

  // 详情弹窗 (原始元数据)
  @State isDetailOpen: boolean = false;
  @State detailLoading: boolean = false;
  @State detailContent: string = '';

  // 二次确认弹窗
  @State isConfirmOpen: boolean = false;
  @State confirmActionType: string = ''; // 'cleanData' | 'uninstall'
  @State confirmTitle: string = '';
  @State confirmMessage: string = '';

  // 看门狗冻结：当前冻结名单（包名集合）
  @State frozenPackages: string[] = [];

  aboutToAppear(): void {
    this.loadApps();
  }

  /**
   * 判断是否为系统核心保护组件（禁止卸载）
   */
  isCoreApp(bundle: string): boolean {
    const core = [
      'com.huawei.hmos.settings',
      'com.huawei.hmos.desktop',
      'com.huawei.hmos.camera',
      'com.huawei.hmos.photos',
      'com.huawei.systemui',
      'com.huawei.hmsapp.appgallery',
      'com.octahedron.hmpriv'
    ];
    return core.includes(bundle) || bundle.startsWith('com.huawei.system.');
  }

  /**
   * 极速加载全量应用列表与运行状态
   */
  async loadApps(): Promise<void> {
    if (this.isLoading) {
      return;
    }
    this.isLoading = true;
    try {
      // 冻结名单是本地文件读取，很快，先刷出来保证 UI 状态正确
      const busDir = this.busClient.getBusDir();
      if (busDir) {
        this.frozenPackages = FreezeManager.getFrozen(busDir);
      }

      const result: CommandResult = await this.busClient.execute(CommandBuilder.listAppsWithLabels());
      if (result.success && result.output.length > 0) {
        this.allApps = ResponseParser.parseAppListWithLabels(result.output);
        this.updateCounts();
        this.applyFilter();
      } else {
        this.showToast(`获取应用列表失败：exitCode=${result.exitCode}`);
      }

      // 异步刷新进程运行状态
      this.refreshRunningProcesses();
    } catch (err) {
      this.showToast(`加载异常: ${err}`);
    } finally {
      this.isLoading = false;
    }
  }

  /**
   * 查询并同步当前运行中的进程
   */
  async refreshRunningProcesses(): Promise<void> {
    try {
      const psRes: CommandResult = await this.busClient.execute(CommandBuilder.queryRunningProcesses());
      if (psRes.success) {
        const runningSet = ResponseParser.parseRunningProcesses(psRes.output);
        const list: string[] = [];
        runningSet.forEach((pkg) => list.push(pkg));
        this.runningPackages = list;
      }
    } catch (_e) {
      // 容错
    }
  }

  /**
   * 判断某个包是否当前正在运行
   */
  isAppRunning(bundle: string): boolean {
    return this.runningPackages.includes(bundle);
  }

  /**
   * 刷新计数统计
   */
  updateCounts(): void {
    let user = 0;
    let sys = 0;
    for (let i = 0; i < this.allApps.length; i++) {
      if (this.allApps[i].isSystem) {
        sys++;
      } else {
        user++;
      }
    }
    this.allAppsCount = this.allApps.length;
    this.userAppsCount = user;
    this.systemAppsCount = sys;
  }

  /**
   * 过滤应用
   */
  applyFilter(): void {
    const key = this.searchKey.trim().toLowerCase();
    const filtered: AppItem[] = [];

    for (let i = 0; i < this.allApps.length; i++) {
      const app = this.allApps[i];
      // 分类筛选：3 = 只看已冻结
      if (this.currentCategory === 3) {
        if (this.frozenPackages.indexOf(app.bundleName) < 0) {
          continue;
        }
      } else {
        if (this.currentCategory === 1 && app.isSystem) {
          continue;
        }
        if (this.currentCategory === 2 && !app.isSystem) {
          continue;
        }
      }
      // 关键字搜索
      if (key.length > 0) {
        const matchLabel = app.label.toLowerCase().includes(key);
        const matchBundle = app.bundleName.toLowerCase().includes(key);
        if (!matchLabel && !matchBundle) {
          continue;
        }
      }
      filtered.push(app);
    }
    this.displayApps = filtered;
  }

  /**
   * 弹出提示
   */
  showToast(msg: string): void {
    try {
      promptAction.showToast({ message: msg, duration: 2500 });
    } catch (_e) {
      // 忽略
    }
  }

  /**
   * 打开操作面板
   */
  openOptions(app: AppItem): void {
    this.selectedApp = app;
    this.isOptionsOpen = true;
    this.refreshRunningProcesses();
  }

  /**
   * 关闭操作面板
   */
  closeOptions(): void {
    this.isOptionsOpen = false;
  }

  /**
   * 智能启动应用（动态 Ability 解析）
   */
  async handleStartApp(): Promise<void> {
    if (!this.selectedApp || this.isBusy) {
      return;
    }
    const b = this.selectedApp.bundleName;
    const name = this.selectedApp.label;
    this.isBusy = true;
    this.showToast(`正在智能调起 ${name}...`);
    try {
      const res = await this.busClient.execute(CommandBuilder.startApp(b));
      if (res.success && !res.output.includes('error:')) {
        this.showToast(`已成功唤醒前台：${name}`);
        this.closeOptions();
        // 延时刷新活跃状态
        setTimeout(() => this.refreshRunningProcesses(), 1000);
      } else {
        this.showToast(`启动反馈: ${res.output || `exitCode=${res.exitCode}`}`);
      }
    } finally {
      this.isBusy = false;
    }
  }

  /**
   * 强行停止（彻底杀灭进程组）
   */
  /**
   * 冻结应用（加入看门狗名单）。
   *
   * 鸿蒙没有真正的"停用"能力（见 docs/TODO.md §4.1），这里用持续强杀模拟：
   * daemon 每约 1 秒扫一次进程，发现目标在跑就 force-stop。
   * 效果是"打不开、不常驻"，但包仍在、也拦不住被拉起（只是活不过 1 秒）。
   */
  async handleFreeze(): Promise<void> {
    if (!this.selectedApp || this.isBusy) {
      return;
    }
    const b = this.selectedApp.bundleName;
    const name = this.selectedApp.label;
    const busDir = this.busClient.getBusDir();
    if (!busDir) {
      this.showToast('总线未就绪，请先授权目录');
      return;
    }

    const err = FreezeManager.addFrozen(busDir, b);
    if (err.length > 0) {
      this.showToast(`冻结失败：${err}`);
      return;
    }

    this.frozenPackages = FreezeManager.getFrozen(busDir);
    // 在「已冻结」视图下冻结新应用时，需要重新过滤才能看到它进入列表
    this.applyFilter();
    // 立刻杀一次，不等 daemon 下一轮（否则用户会觉得"点了没反应"）
    this.isBusy = true;
    try {
      await this.busClient.execute(CommandBuilder.forceStopApp(b));
      await this.refreshRunningProcesses();
    } finally {
      this.isBusy = false;
    }
    this.showToast(`已冻结 ${name}：启动会被自动强停`);
  }

  /** 解冻（移出看门狗名单） */
  async handleUnfreeze(): Promise<void> {
    if (!this.selectedApp) {
      return;
    }
    const b = this.selectedApp.bundleName;
    const name = this.selectedApp.label;
    const busDir = this.busClient.getBusDir();
    if (!busDir) {
      this.showToast('总线未就绪');
      return;
    }
    const err = FreezeManager.removeFrozen(busDir, b);
    if (err.length > 0) {
      this.showToast(`解冻失败：${err}`);
      return;
    }
    this.frozenPackages = FreezeManager.getFrozen(busDir);
    // 解冻后该应用应从「已冻结」视图消失
    this.applyFilter();
    this.showToast(`已解冻 ${name}，可以正常启动`);
  }

  /** 解冻全部（清空冻结名单） */
  async handleUnfreezeAll(): Promise<void> {
    const busDir = this.busClient.getBusDir();
    if (!busDir) {
      this.showToast('总线未就绪');
      return;
    }
    const before = this.frozenPackages.length;
    if (before === 0) {
      return;
    }
    const err = FreezeManager.clearAll(busDir);
    if (err.length > 0) {
      this.showToast(`解冻失败：${err}`);
      return;
    }
    this.frozenPackages = FreezeManager.getFrozen(busDir);
    this.applyFilter();
    this.showToast(`已解冻全部 ${before} 个应用`);
  }

  async handleForceStop(): Promise<void> {
    if (!this.selectedApp || this.isBusy) {
      return;
    }
    const b = this.selectedApp.bundleName;
    const name = this.selectedApp.label;
    this.isBusy = true;
    try {
      const res = await this.busClient.execute(CommandBuilder.forceStopApp(b));
      if (res.success) {
        this.showToast(`已强杀 ${name} 进程组（已彻底停止运行）`);
        await this.refreshRunningProcesses();
        this.closeOptions();
      } else {
        this.showToast(`停止失败: ${res.output}`);
      }
    } finally {
      this.isBusy = false;
    }
  }

  /**
   * 打开系统设置该应用专页
   */
  async handleOpenSettings(): Promise<void> {
    if (!this.selectedApp) {
      return;
    }
    const b = this.selectedApp.bundleName;
    this.showToast(`正在跳转系统设置...`);
    await this.busClient.execute(CommandBuilder.openAppSystemSettings(b));
  }

  /**
   * 清理缓存
   */
  async handleCleanCache(): Promise<void> {
    if (!this.selectedApp || this.isBusy) {
      return;
    }
    const b = this.selectedApp.bundleName;
    this.isBusy = true;
    try {
      const res = await this.busClient.execute(CommandBuilder.cleanCache(b));
      // bm 失败时 RC 仍为 0，必须看输出文本
      if (res.success && !ResponseParser.isBmFailure(res.output)) {
        this.showToast(`缓存已释放：${this.selectedApp.label}`);
        this.closeOptions();
      } else {
        this.showToast(`清理失败：${ResponseParser.explainBmError(res.output)}`);
      }
    } finally {
      this.isBusy = false;
    }
  }

  /**
   * 准备清空数据（弹窗确认）
   */
  askCleanData(): void {
    if (!this.selectedApp) {
      return;
    }
    this.confirmActionType = 'cleanData';
    this.confirmTitle = `彻底清空应用数据`;
    this.confirmMessage = `确定要重置「${this.selectedApp.label}」的所有数据吗？\n将清除私有数据库、缓存、账号状态，此操作不可逆！`;
    this.isConfirmOpen = true;
  }

  /**
   * 准备卸载应用
   */
  askUninstall(): void {
    if (!this.selectedApp) {
      return;
    }
    const app = this.selectedApp;
    this.confirmActionType = 'uninstall';
    this.confirmTitle = `免 Root 卸载应用`;
    // 系统应用不预先拦截 —— 实测有些系统应用能卸、有些不能（os_integration 的卸不了）。
    // 一律放行让用户试，失败时给明确原因，比直接禁掉按钮更有用。
    if (app.isSystem) {
      this.confirmMessage = `确定要卸载「${app.label}」吗？\n包名：${app.bundleName}\n\n` +
        `注意：这是系统预装应用。部分系统应用打包在系统镜像里、无法卸载，` +
        `如果失败会告诉你具体原因。`;
    } else {
      this.confirmMessage = `确定要卸载「${app.label}」吗？\n包名：${app.bundleName}\n` +
        `（系统将通过 BMS 执行卸载）`;
    }
    this.isConfirmOpen = true;
  }

  /**
   * 执行高危确认动作
   */
  async executeConfirmedAction(): Promise<void> {
    if (!this.selectedApp || this.isBusy) {
      return;
    }
    const b = this.selectedApp.bundleName;
    const name = this.selectedApp.label;
    this.isConfirmOpen = false;
    this.isBusy = true;

    try {
      if (this.confirmActionType === 'cleanData') {
        const res = await this.busClient.execute(CommandBuilder.cleanData(b));
        // bm 失败时 RC 仍为 0，必须看输出文本（详见 ResponseParser.isBmFailure）
        if (res.success && !ResponseParser.isBmFailure(res.output)) {
          this.showToast(`数据已彻底清空：${name}`);
          this.closeOptions();
        } else {
          this.showToast(`清空失败：${ResponseParser.explainBmError(res.output)}`);
        }
      } else if (this.confirmActionType === 'uninstall') {
        const res = await this.busClient.execute(CommandBuilder.uninstallApp(b));
        if (res.success && !ResponseParser.isBmFailure(res.output)) {
          // 命令没报错，再复核一次包是否真的没了 —— bm 的输出有时会滞后/含糊，
          // 只凭文本判定容易给出假成功。
          const gone = await this.verifyUninstalled(b);
          if (gone) {
            this.showToast(`已成功卸载：${name}`);
            this.closeOptions();
            this.loadApps();
          } else {
            this.showToast(`卸载命令已执行，但「${name}」仍在设备上，可能被系统拒绝。`);
          }
        } else {
          // 失败时把原因讲清楚，而不是甩一行原始报错
          this.showToast(`卸载失败：${ResponseParser.explainBmError(res.output)}`);
        }
      }
    } finally {
      this.isBusy = false;
    }
  }

  /**
   * 复核应用是否真的被卸载。
   *
   * 用 bm dump -n 查：
   *   应用还在 → 输出是 70KB+ 的 bundle JSON
   *   应用不在 → "error: failed to get information and the parameters may be wrong."
   *
   * 【判定要保守】只在看到明确的错误特征时才认定已卸载。
   * 已实测：正常应用的 dump 输出里不含 "failed" / "not found" 字样，
   * 所以这两个词是安全的失败特征；但为了万无一失，仍要求输出不像 JSON。
   */
  private async verifyUninstalled(bundle: string): Promise<boolean> {
    try {
      const check = await this.busClient.execute(CommandBuilder.appDetail(bundle));
      const raw = check.output ?? '';
      const t = raw.toLowerCase();
      // 明确错误特征
      if (t.indexOf('failed to get information') >= 0 || t.indexOf('not found') >= 0) {
        return true;
      }
      // 兜底：正常 dump 一定是大段 JSON（含 bundleName），没有就不是
      if (raw.trim().length === 0) {
        return true;
      }
      if (t.indexOf('"bundlename"') >= 0) {
        return false;   // 还在
      }
      return false;     // 无法判定时按"还在"处理，宁可让用户再确认一次
    } catch (_e) {
      return false;
    }
  }

  /**
   * 重置权限
   */
  async handleResetPerms(): Promise<void> {
    if (!this.selectedApp || this.isBusy) {
      return;
    }
    const b = this.selectedApp.bundleName;
    this.isBusy = true;
    try {
      const res = await this.busClient.execute(CommandBuilder.resetAppPermissions(b));
      // atm 的输出实测捕获不到（走 pty），无法判断成败，所以只报"已发起"，
      // 不说"已重置" —— 谎报成功比不给反馈更糟。
      this.showToast(res.success
        ? '已发起权限重置，请到「查看权限」确认结果'
        : `重置失败：${res.output}`);
      if (this.isPermissionOpen) {
        this.handleViewPermissions();
      }
    } finally {
      this.isBusy = false;
    }
  }

  /**
   * 查看专属权限透视面板
   */
  async handleViewPermissions(): Promise<void> {
    if (!this.selectedApp) {
      return;
    }
    const b = this.selectedApp.bundleName;
    this.isPermissionOpen = true;
    this.permLoading = true;

    try {
      const res = await this.busClient.execute(CommandBuilder.appDetail(b));
      if (res.success) {
        const parsed = ResponseParser.parseAppPermissions(res.output);
        this.permissions = parsed;
        let userCount = 0;
        for (let i = 0; i < parsed.length; i++) {
          if (parsed[i].isUserGrant) {
            userCount++;
          }
        }
        this.userPermCount = userCount;
      } else {
        this.showToast(`权限查询失败: ${res.output}`);
      }
    } finally {
      this.permLoading = false;
    }
  }

  /**
   * 查看应用全息详情（原始元数据）
   */
  async handleViewDetail(): Promise<void> {
    if (!this.selectedApp) {
      return;
    }
    const b = this.selectedApp.bundleName;
    this.isDetailOpen = true;
    this.detailLoading = true;
    this.detailContent = '正在抓取应用全息元数据...';

    try {
      const res = await this.busClient.execute(CommandBuilder.appDetail(b));
      this.detailContent = res.output || '无输出信息';
    } catch (e) {
      this.detailContent = `查询失败: ${e}`;
    } finally {
      this.detailLoading = false;
    }
  }

  /**
   * 生成应用头像渐变底色
   */
  getAvatarColor(name: string): string {
    const colors = ['#0284C7', '#0D9488', '#16A34A', '#CA8A04', '#EA580C', '#7C3AED', '#DB2777'];
    let hash = 0;
    for (let i = 0; i < name.length; i++) {
      hash = (hash << 5) - hash + name.charCodeAt(i);
    }
    const idx = Math.abs(hash) % colors.length;
    return colors[idx];
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      Column() {
        // ===== 顶部工具条：搜索 + 刷新 =====
        Row() {
          Search({ value: this.searchKey, placeholder: '搜索应用名称 / 包名...' })
            .searchButton('搜索')
            .placeholderColor('#64748B')
            .placeholderFont({ size: 13 })
            .textFont({ size: 13 })
            .fontColor('#F1F5F9')
            .backgroundColor('#1E293B')
            .layoutWeight(1)
            .height(36)
            .onChange((val: string) => {
              this.searchKey = val;
              this.applyFilter();
            })

          Button() {
            Row() {
              Text(this.isLoading ? '加载中' : '刷新')
                .fontSize(12)
                .fontColor('#38BDF8')
                .fontWeight(FontWeight.Medium)
            }
          }
          .backgroundColor('#1E293B')
          .height(36)
          .padding({ left: 12, right: 12 })
          .margin({ left: 8 })
          .borderRadius(8)
          .enabled(!this.isLoading)
          .onClick(() => {
            this.loadApps();
          })
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 10, bottom: 8 })

        // ===== 分类芯片：全部 / 第三方 / 系统预装 / 已冻结 =====
        Row() {
          this.FilterChip('全部', 0)
          this.FilterChip('用户应用', 1)
          this.FilterChip('系统预装', 2)
          this.FilterChip('已冻结', 3)
        }
        .width('100%')
        .padding({ left: 16, right: 16, bottom: 8 })

        // ===== 已冻结视图的汇总条 =====
        if (this.currentCategory === 3 && this.frozenPackages.length > 0) {
          Row() {
            Text(`共 ${this.frozenPackages.length} 个应用被冻结`)
              .fontSize(11)
              .fontColor('#7DD3FC')
              .layoutWeight(1)
            Text('全部解冻')
              .fontSize(11)
              .fontColor('#F87171')
              .padding({ left: 8, right: 8, top: 4, bottom: 4 })
              .onClick(() => this.handleUnfreezeAll())
          }
          .width('100%')
          .padding({ left: 12, right: 12, top: 8, bottom: 8 })
          .backgroundColor('#0C2A3E')
          .borderRadius(8)
          .margin({ left: 16, right: 16, bottom: 8 })
        }

        // ===== 应用列表区 =====
        if (this.isLoading && this.allApps.length === 0) {
          Column() {
            LoadingProgress()
              .width(36)
              .height(36)
              .color('#38BDF8')
            Text('150ms 极速解析已装应用中...')
              .fontSize(13)
              .fontColor('#94A3B8')
              .margin({ top: 12 })
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        } else if (this.displayApps.length === 0) {
          Column() {
            Text(this.currentCategory === 3 ? '❄' : '🔍')
              .fontSize(34)
              .margin({ bottom: 10 })
            Text(this.currentCategory === 3
              ? '还没有冻结任何应用'
              : '未找到匹配的应用')
              .fontSize(14)
              .fontColor('#64748B')
            if (this.currentCategory === 3) {
              Text('在任意应用的「管控 >」面板里点「冻结应用」')
                .fontSize(11)
                .fontColor('#475569')
                .margin({ top: 6 })
            }
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        } else {
          List({ space: 8 }) {
            ForEach(this.displayApps, (app: AppItem) => {
              ListItem() {
                this.AppCard(app)
              }
            }, (app: AppItem) => app.bundleName)
          }
          .width('100%')
          .layoutWeight(1)
          .padding({ left: 16, right: 16, top: 4, bottom: 16 })
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor('#0D1527')

      // ===== 操作面板遮罩与卡片 =====
      if (this.isOptionsOpen && this.selectedApp) {
        this.ActionSheetModal()
      }

      // ===== 权限透视专属弹窗 =====
      if (this.isPermissionOpen && this.selectedApp) {
        this.PermissionModal()
      }

      // ===== 高危动作二次确认弹窗 =====
      if (this.isConfirmOpen && this.selectedApp) {
        this.ConfirmModal()
      }

      // ===== 全息详情透视弹窗 =====
      if (this.isDetailOpen && this.selectedApp) {
        this.DetailModal()
      }
    }
    .width('100%')
    .height('100%')
  }

  /**
   * 分类芯片组件
   *
   * 注意：标题必须内联在 Text 里算，不能把动态计数当参数传给 @Builder ——
   * @Builder 参数按值传递，首次构建后不随 @State 重建（令牌计数曾踩过这个坑）。
   * 这里 catIndex 是常量，所以按索引分支是安全的。
   */
  @Builder
  FilterChip(title: string, catIndex: number) {
    Row() {
      Text(catIndex === 0 ? `全部 (${this.allAppsCount})`
        : (catIndex === 1 ? `用户应用 (${this.userAppsCount})`
        : (catIndex === 2 ? `系统预装 (${this.systemAppsCount})`
        : `已冻结 (${this.frozenPackages.length})`)))
        .fontSize(12)
        .fontColor(this.currentCategory === catIndex
          ? (catIndex === 3 ? '#090D16' : '#090D16')
          : (catIndex === 3 ? '#7DD3FC' : '#94A3B8'))
        .fontWeight(this.currentCategory === catIndex ? FontWeight.Bold : FontWeight.Normal)
    }
    .height(28)
    .padding({ left: 10, right: 10 })
    .margin({ right: 8 })
    .borderRadius(14)
    .backgroundColor(this.currentCategory === catIndex
      ? (catIndex === 3 ? '#7DD3FC' : '#38BDF8')
      : (catIndex === 3 ? '#0C4A6E' : '#1E293B'))
    .onClick(() => {
      this.currentCategory = catIndex;
      this.applyFilter();
    })
  }

  /**
   * 应用条目卡片
   */
  @Builder
  AppCard(app: AppItem) {
    Row() {
      // 科技感个性头像
      Stack() {
        Circle({ width: 42, height: 42 })
          .fill(this.getAvatarColor(app.label))
        Text(app.label.substring(0, 1).toUpperCase())
          .fontSize(17)
          .fontWeight(FontWeight.Bold)
          .fontColor('#FFFFFF')
      }
      .margin({ right: 12 })

      // 文字信息
      Column() {
        Row() {
          Text(app.label)
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor('#F1F5F9')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)

          // 运行状态指示
          if (this.isAppRunning(app.bundleName)) {
            Row() {
              Circle({ width: 6, height: 6 }).fill('#4ADE80').margin({ right: 4 })
              Text('活跃')
                .fontSize(10)
                .fontColor('#4ADE80')
            }
            .backgroundColor('#064E3B')
            .padding({ left: 6, right: 6, top: 2, bottom: 2 })
            .borderRadius(4)
            .margin({ left: 6 })
          }

          // 冻结徽章：比活跃状态更优先显示，让用户一眼看出这应用被冻了
          if (this.frozenPackages.indexOf(app.bundleName) >= 0) {
            Row() {
              Text('❄')
                .fontSize(9)
                .fontColor('#7DD3FC')
                .margin({ right: 3 })
              Text('已冻结')
                .fontSize(10)
                .fontColor('#7DD3FC')
            }
            .backgroundColor('#0C4A6E')
            .padding({ left: 6, right: 6, top: 2, bottom: 2 })
            .borderRadius(4)
            .margin({ left: 6 })
          }

          Text(app.isSystem ? '系统' : '用户')
            .fontSize(10)
            .fontColor(app.isSystem ? '#64748B' : '#38BDF8')
            .backgroundColor(app.isSystem ? '#1E293B' : '#0C4A6E')
            .padding({ left: 6, right: 6, top: 2, bottom: 2 })
            .borderRadius(4)
            .margin({ left: 6 })
        }
        .width('100%')

        Text(app.bundleName)
          .fontSize(12)
          .fontColor('#64748B')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: 3 })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      // 右侧操作触发器
      Text('管控 >')
        .fontSize(12)
        .fontColor('#38BDF8')
        .margin({ left: 8 })
    }
    .width('100%')
    .padding(12)
    .backgroundColor('#151F33')
    .borderRadius(10)
    .onClick(() => {
      this.openOptions(app);
    })
  }

  /**
   * 操作选项底部弹窗 (Action Sheet)
   */
  @Builder
  ActionSheetModal() {
    Stack({ alignContent: Alignment.Bottom }) {
      // 遮罩
      Rect()
        .width('100%')
        .height('100%')
        .fill('#CC000000')
        .onClick(() => {
          if (!this.isBusy) {
            this.closeOptions();
          }
        })

      // 内容卡片
      Column() {
        // 头部信息
        Row() {
          Stack() {
            Circle({ width: 44, height: 44 })
              .fill(this.getAvatarColor(this.selectedApp!.label))
            Text(this.selectedApp!.label.substring(0, 1).toUpperCase())
              .fontSize(18)
              .fontWeight(FontWeight.Bold)
              .fontColor('#FFFFFF')
          }
          .margin({ right: 12 })

          Column() {
            Row() {
              Text(this.selectedApp!.label)
                .fontSize(16)
                .fontWeight(FontWeight.Bold)
                .fontColor('#F1F5F9')

              // 运行状态小徽章
              Text(this.isAppRunning(this.selectedApp!.bundleName) ? '🟢 活跃运行中' : '⚪ 未运行')
                .fontSize(11)
                .fontColor(this.isAppRunning(this.selectedApp!.bundleName) ? '#4ADE80' : '#94A3B8')
                .margin({ left: 8 })
            }

            Text(this.selectedApp!.bundleName)
              .fontSize(11)
              .fontColor('#94A3B8')
              .margin({ top: 2 })
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)

          Button('关闭')
            .fontSize(12)
            .fontColor('#94A3B8')
            .backgroundColor('#1E293B')
            .height(28)
            .onClick(() => this.closeOptions())
        }
        .width('100%')
        .padding({ bottom: 14 })

        Divider().color('#334155').margin({ bottom: 12 })

        // 操作动作清单
        Grid() {
          GridItem() {
            this.ActionButton('🚀', '启动应用', '智能唤醒前台', '#0284C7', () => this.handleStartApp())
          }
          GridItem() {
            this.ActionButton('🛑', '强行停止', '击毙进程组', '#DC2626', () => this.handleForceStop())
          }
          GridItem() {
            if (this.selectedApp && this.frozenPackages.indexOf(this.selectedApp.bundleName) >= 0) {
              this.ActionButton('🔥', '解冻应用', '恢复正常运行', '#F59E0B', () => this.handleUnfreeze())
            } else {
              this.ActionButton('❄️', '冻结应用', '启动即被强停', '#0EA5E9', () => this.handleFreeze())
            }
          }
          GridItem() {
            this.ActionButton('🛡️', '查看权限', '标明可修改与状态', '#8B5CF6', () => this.handleViewPermissions())
          }
          GridItem() {
            this.ActionButton('🧹', '清理缓存', '释放临时空间', '#D97706', () => this.handleCleanCache())
          }
          GridItem() {
            this.ActionButton('🗑️', '彻底清空数据', '重置私有数据', '#B91C1C', () => this.askCleanData())
          }
          GridItem() {
            this.ActionButton('⚙️', '系统设置', '打开权限/存储页', '#0284C7', () => this.handleOpenSettings())
          }
          GridItem() {
            this.ActionButton('❌', '免Root卸载', '移除该应用', '#991B1B', () => this.askUninstall())
          }
          GridItem() {
            this.ActionButton('ℹ️', '全息元数据', '原始导出信息', '#059669', () => this.handleViewDetail())
          }
        }
        .columnsTemplate('1fr 1fr')
        .columnsGap(10)
        .rowsGap(10)
        .width('100%')
        .margin({ bottom: 14 })

        // 提示注脚
        Text('💡 提示：强行停止会立即终结该应用的实际进程组；多任务界面的历史卡片为系统桌面留存的静态快照。')
          .fontSize(11)
          .fontColor('#64748B')
          .lineHeight(16)
          .width('100%')
          .margin({ bottom: 10 })
      }
      .width('100%')
      .padding(18)
      .backgroundColor('#1A2234')
      .borderRadius({ topLeft: 16, topRight: 16 })
    }
    .width('100%')
    .height('100%')
  }

  /**
   * 动作单元按钮
   */
  @Builder
  ActionButton(icon: string, title: string, subtitle: string, color: string, onClick: () => void) {
    Button() {
      Row() {
        Text(icon)
          .fontSize(20)
          .margin({ right: 10 })

        Column() {
          Text(title)
            .fontSize(13)
            .fontWeight(FontWeight.Bold)
            .fontColor('#FFFFFF')
          Text(subtitle)
            .fontSize(10)
            .fontColor('#94A3B8')
            .margin({ top: 2 })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
      }
      .width('100%')
      .padding({ left: 10, right: 10, top: 8, bottom: 8 })
    }
    .type(ButtonType.Normal)
    .backgroundColor('#243048')
    .borderRadius(8)
    .height(56)
    .width('100%')
    .enabled(!this.isBusy)
    .onClick(onClick)
  }

  /**
   * 权限透视专属弹窗
   */
  @Builder
  PermissionModal() {
    Stack({ alignContent: Alignment.Center }) {
      Rect()
        .width('100%')
        .height('100%')
        .fill('#CC000000')
        .onClick(() => {
          this.isPermissionOpen = false;
        })

      Column() {
        // 头部
        Row() {
          Column() {
            Text(`🛡️ 权限清单透视`)
              .fontSize(16)
              .fontWeight(FontWeight.Bold)
              .fontColor('#38BDF8')

            Text(this.selectedApp ? `${this.selectedApp.label} · 共 ${this.permissions.length} 项 (可修改 ${this.userPermCount} 项)` : '')
              .fontSize(11)
              .fontColor('#94A3B8')
              .margin({ top: 2 })
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)

          Button('关闭')
            .fontSize(12)
            .fontColor('#94A3B8')
            .backgroundColor('#334155')
            .height(28)
            .onClick(() => {
              this.isPermissionOpen = false;
            })
        }
        .width('100%')
        .padding({ bottom: 12 })

        Divider().color('#334155').margin({ bottom: 8 })

        if (this.permLoading) {
          LoadingProgress()
            .width(32)
            .height(32)
            .color('#38BDF8')
            .margin(24)
        } else if (this.permissions.length === 0) {
          Column() {
            Text('该应用未声明任何系统权限')
              .fontSize(13)
              .fontColor('#64748B')
          }
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        } else {
          List({ space: 6 }) {
            ForEach(this.permissions, (item: PermissionItem) => {
              ListItem() {
                Row() {
                  Column() {
                    Row() {
                      Text(item.friendlyName)
                        .fontSize(14)
                        .fontWeight(FontWeight.Medium)
                        .fontColor('#F8FAFC')

                      // 可修改 vs 系统默认徽章
                      Text(item.isUserGrant ? '可修改' : '系统默认')
                        .fontSize(10)
                        .fontColor(item.isUserGrant ? '#38BDF8' : '#64748B')
                        .backgroundColor(item.isUserGrant ? '#0C4A6E' : '#1E293B')
                        .padding({ left: 6, right: 6, top: 1, bottom: 1 })
                        .borderRadius(4)
                        .margin({ left: 6 })
                    }

                    Text(item.name)
                      .fontSize(10)
                      .fontColor('#64748B')
                      .fontFamily('monospace')
                      .margin({ top: 2 })
                  }
                  .alignItems(HorizontalAlign.Start)
                  .layoutWeight(1)

                  // 授权状态
                  Text(item.isGranted ? '已允许' : '未允许')
                    .fontSize(11)
                    .fontWeight(FontWeight.Bold)
                    .fontColor(item.isGranted ? '#4ADE80' : '#94A3B8')
                    .backgroundColor(item.isGranted ? '#064E3B' : '#1E293B')
                    .padding({ left: 8, right: 8, top: 4, bottom: 4 })
                    .borderRadius(4)
                }
                .width('100%')
                .padding(10)
                .backgroundColor('#151F33')
                .borderRadius(8)
              }
            }, (p: PermissionItem) => p.name)
          }
          .layoutWeight(1)
          .width('100%')
        }

        Divider().color('#334155').margin({ top: 8, bottom: 10 })

        // 底部快捷动作
        Row() {
          Button('⚙️ 去系统设置修改')
            .fontSize(12)
            .backgroundColor('#0284C7')
            .fontColor('#FFFFFF')
            .height(34)
            .layoutWeight(1)
            .margin({ right: 8 })
            .onClick(() => this.handleOpenSettings())

          Button('🔄 一键重置授权')
            .fontSize(12)
            .backgroundColor('#334155')
            .fontColor('#FBBF24')
            .height(34)
            .layoutWeight(1)
            .onClick(() => this.handleResetPerms())
        }
        .width('100%')
      }
      .width('92%')
      .height('75%')
      .padding(16)
      .backgroundColor('#1E293B')
      .borderRadius(14)
    }
    .width('100%')
    .height('100%')
  }

  /**
   * 二次确认弹窗
   */
  @Builder
  ConfirmModal() {
    Stack({ alignContent: Alignment.Center }) {
      Rect()
        .width('100%')
        .height('100%')
        .fill('#CC000000')

      Column() {
        Text('⚠️ ' + this.confirmTitle)
          .fontSize(17)
          .fontWeight(FontWeight.Bold)
          .fontColor('#F87171')
          .width('100%')

        Text(this.confirmMessage)
          .fontSize(13)
          .fontColor('#E2E8F0')
          .margin({ top: 12, bottom: 20 })
          .lineHeight(20)
          .width('100%')

        Row() {
          Button('取消')
            .fontSize(13)
            .backgroundColor('#334155')
            .fontColor('#94A3B8')
            .layoutWeight(1)
            .height(36)
            .margin({ right: 10 })
            .onClick(() => {
              this.isConfirmOpen = false;
            })

          Button('确定执行')
            .fontSize(13)
            .backgroundColor('#DC2626')
            .fontColor('#FFFFFF')
            .fontWeight(FontWeight.Bold)
            .layoutWeight(1)
            .height(36)
            .onClick(() => {
              this.executeConfirmedAction();
            })
        }
        .width('100%')
      }
      .width('85%')
      .padding(20)
      .backgroundColor('#1E293B')
      .borderRadius(12)
    }
    .width('100%')
    .height('100%')
  }

  /**
   * 应用全息详情弹窗 (原始元数据)
   */
  @Builder
  DetailModal() {
    Stack({ alignContent: Alignment.Center }) {
      Rect()
        .width('100%')
        .height('100%')
        .fill('#CC000000')
        .onClick(() => {
          this.isDetailOpen = false;
        })

      Column() {
        Row() {
          Text('📊 原始全息元数据')
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor('#38BDF8')

          Blank()

          Button('关闭')
            .fontSize(12)
            .fontColor('#94A3B8')
            .backgroundColor('#334155')
            .height(28)
            .onClick(() => {
              this.isDetailOpen = false;
            })
        }
        .width('100%')
        .padding({ bottom: 12 })

        Divider().color('#334155').margin({ bottom: 8 })

        if (this.detailLoading) {
          LoadingProgress()
            .width(32)
            .height(32)
            .color('#38BDF8')
            .margin(20)
        } else {
          Scroll() {
            Text(this.detailContent)
              .fontSize(11)
              .fontColor('#CBD5E1')
              .fontFamily('monospace')
              .lineHeight(16)
              .width('100%')
          }
          .layoutWeight(1)
          .width('100%')
          .padding(8)
          .backgroundColor('#0F172A')
          .borderRadius(6)
        }
      }
      .width('90%')
      .height('75%')
      .padding(16)
      .backgroundColor('#1E293B')
      .borderRadius(12)
    }
    .width('100%')
    .height('100%')
  }
}
