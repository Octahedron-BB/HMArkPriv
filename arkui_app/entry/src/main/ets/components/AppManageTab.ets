import { BusClient } from '../services/BusClient';
import { CommandBuilder } from '../utils/CommandBuilder';
import { ResponseParser, AppItem } from '../utils/ResponseParser';
import { CommandResult } from '../model/CommandResult';
import { promptAction } from '@kit.ArkUI';

/**
 * AppManageTab — 应用管理主面板
 *
 * 核心功能：
 * 1. 150ms 极速加载已安装应用全量清单（中文名 + 包名）。
 * 2. 搜索（支持名称与包名匹配）与多维分类（全部 / 第三方 / 系统预装）。
 * 3. 点击任一应用弹出专属操作选项面板：
 *    - 启动应用 (aa start)
 *    - 强行停止 (aa force-stop)
 *    - 清理缓存 (bm clean -c)
 *    - 彻底清空数据 (bm clean -d，带二次确认)
 *    - 一键重置权限 (atm perm -r -b)
 *    - 免 Root 卸载 (bm uninstall -u 100，带二次确认)
 *    - 全息详情 / 权限透视 (bm dump -n)
 */
@Component
export struct AppManageTab {
  @Prop busClient: BusClient;

  // 原始应用清单
  @State allApps: AppItem[] = [];
  // 过滤后的应用清单
  @State displayApps: AppItem[] = [];
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

  // 详情弹窗
  @State isDetailOpen: boolean = false;
  @State detailLoading: boolean = false;
  @State detailContent: string = '';

  // 二次确认弹窗
  @State isConfirmOpen: boolean = false;
  @State confirmActionType: string = ''; // 'cleanData' | 'uninstall'
  @State confirmTitle: string = '';
  @State confirmMessage: string = '';

  aboutToAppear(): void {
    this.loadApps();
  }

  /**
   * 极速加载全量应用列表
   */
  async loadApps(): Promise<void> {
    if (this.isLoading) {
      return;
    }
    this.isLoading = true;
    try {
      const result: CommandResult = await this.busClient.execute(CommandBuilder.listAppsWithLabels());
      if (result.success && result.output.length > 0) {
        this.allApps = ResponseParser.parseAppListWithLabels(result.output);
        this.updateCounts();
        this.applyFilter();
      } else {
        this.showToast(`获取应用列表失败：exitCode=${result.exitCode}`);
      }
    } catch (err) {
      this.showToast(`加载异常: ${err}`);
    } finally {
      this.isLoading = false;
    }
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
      // 分类筛选
      if (this.currentCategory === 1 && app.isSystem) {
        continue;
      }
      if (this.currentCategory === 2 && !app.isSystem) {
        continue;
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
      promptAction.showToast({ message: msg, duration: 2200 });
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
  }

  /**
   * 关闭操作面板
   */
  closeOptions(): void {
    this.isOptionsOpen = false;
  }

  /**
   * 启动应用
   */
  async handleStartApp(): Promise<void> {
    if (!this.selectedApp || this.isBusy) {
      return;
    }
    const b = this.selectedApp.bundleName;
    this.isBusy = true;
    this.showToast(`正在启动 ${this.selectedApp.label}...`);
    try {
      const res = await this.busClient.execute(CommandBuilder.startApp(b, 'EntryAbility'));
      if (res.success) {
        this.showToast(`已请求启动：${this.selectedApp.label}`);
        this.closeOptions();
      } else {
        this.showToast(`启动返回: ${res.output || `exitCode=${res.exitCode}`}`);
      }
    } finally {
      this.isBusy = false;
    }
  }

  /**
   * 强行停止
   */
  async handleForceStop(): Promise<void> {
    if (!this.selectedApp || this.isBusy) {
      return;
    }
    const b = this.selectedApp.bundleName;
    this.isBusy = true;
    try {
      const res = await this.busClient.execute(CommandBuilder.forceStopApp(b));
      if (res.success) {
        this.showToast(`已强制停止进程：${this.selectedApp.label}`);
        this.closeOptions();
      } else {
        this.showToast(`停止失败: ${res.output}`);
      }
    } finally {
      this.isBusy = false;
    }
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
      if (res.success) {
        this.showToast(`缓存已清理：${this.selectedApp.label}`);
        this.closeOptions();
      } else {
        this.showToast(`清理缓存结果: ${res.output}`);
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
    this.confirmTitle = `清空应用数据`;
    this.confirmMessage = `确定要彻底清空「${this.selectedApp.label}」的所有数据吗？\n包括内部数据库、缓存、账号状态，此操作不可逆！`;
    this.isConfirmOpen = true;
  }

  /**
   * 准备卸载应用（弹窗确认）
   */
  askUninstall(): void {
    if (!this.selectedApp) {
      return;
    }
    this.confirmActionType = 'uninstall';
    this.confirmTitle = `免 Root 卸载应用`;
    this.confirmMessage = `确定要卸载「${this.selectedApp.label}」吗？\n包名：${this.selectedApp.bundleName}`;
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
        this.showToast(res.success ? `数据已彻底清空：${name}` : `清空失败: ${res.output}`);
        this.closeOptions();
      } else if (this.confirmActionType === 'uninstall') {
        const res = await this.busClient.execute(CommandBuilder.uninstallApp(b));
        if (res.success) {
          this.showToast(`已成功卸载：${name}`);
          this.closeOptions();
          this.loadApps(); // 刷新列表
        } else {
          this.showToast(`卸载结果: ${res.output}`);
        }
      }
    } finally {
      this.isBusy = false;
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
      this.showToast(res.success ? `权限已重置为初始状态` : `重置结果: ${res.output}`);
      this.closeOptions();
    } finally {
      this.isBusy = false;
    }
  }

  /**
   * 查看应用全息详情
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
   * 生成头像背景色
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

        // ===== 分类芯片：全部 / 第三方 / 系统预装 =====
        Row() {
          this.FilterChip('全部', 0)
          this.FilterChip('用户应用', 1)
          this.FilterChip('系统预装', 2)
        }
        .width('100%')
        .padding({ left: 16, right: 16, bottom: 8 })

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
            Text('未找到匹配的应用')
              .fontSize(14)
              .fontColor('#64748B')
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

  getUserAppCount(): number {
    let count = 0;
    for (let i = 0; i < this.allApps.length; i++) {
      if (!this.allApps[i].isSystem) {
        count++;
      }
    }
    return count;
  }

  getSystemAppCount(): number {
    let count = 0;
    for (let i = 0; i < this.allApps.length; i++) {
      if (this.allApps[i].isSystem) {
        count++;
      }
    }
    return count;
  }

  /**
   * 分类芯片组件
   */
  @Builder
  FilterChip(title: string, catIndex: number) {
    Row() {
      Text(catIndex === 0 ? `全部 (${this.allAppsCount})`
        : (catIndex === 1 ? `用户应用 (${this.userAppsCount})` : `系统预装 (${this.systemAppsCount})`))
        .fontSize(12)
        .fontColor(this.currentCategory === catIndex ? '#090D16' : '#94A3B8')
        .fontWeight(this.currentCategory === catIndex ? FontWeight.Bold : FontWeight.Normal)
    }
    .height(28)
    .padding({ left: 10, right: 10 })
    .margin({ right: 8 })
    .borderRadius(14)
    .backgroundColor(this.currentCategory === catIndex ? '#38BDF8' : '#1E293B')
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
      // 头像
      Stack() {
        Circle({ width: 40, height: 40 })
          .fill(this.getAvatarColor(app.label))
        Text(app.label.substring(0, 1).toUpperCase())
          .fontSize(16)
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
      Text('操作 >')
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
            Text(this.selectedApp!.label)
              .fontSize(16)
              .fontWeight(FontWeight.Bold)
              .fontColor('#F1F5F9')
            Text(this.selectedApp!.bundleName)
              .fontSize(12)
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
        .padding({ bottom: 16 })

        Divider().color('#334155').margin({ bottom: 12 })

        // 操作动作清单
        Grid() {
          GridItem() {
            this.ActionButton('🚀', '启动应用', '拉起前台', '#0284C7', () => this.handleStartApp())
          }
          GridItem() {
            this.ActionButton('🛑', '强行停止', '击毙进程', '#DC2626', () => this.handleForceStop())
          }
          GridItem() {
            this.ActionButton('🧹', '清理缓存', '释放临时空间', '#D97706', () => this.handleCleanCache())
          }
          GridItem() {
            this.ActionButton('🗑️', '彻底清空数据', '重置应用存储', '#B91C1C', () => this.askCleanData())
          }
          GridItem() {
            this.ActionButton('🔄', '重置权限', '恢复初始授权', '#4F46E5', () => this.handleResetPerms())
          }
          GridItem() {
            this.ActionButton('❌', '免Root卸载', '移除该应用', '#991B1B', () => this.askUninstall())
          }
          GridItem() {
            this.ActionButton('ℹ️', '全息透视', '权限与元数据', '#059669', () => this.handleViewDetail())
          }
        }
        .columnsTemplate('1fr 1fr')
        .columnsGap(10)
        .rowsGap(10)
        .width('100%')
        .margin({ bottom: 20 })
      }
      .width('100%')
      .padding(20)
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
   * 应用全息详情弹窗
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
          Text('📊 应用全息元数据')
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
