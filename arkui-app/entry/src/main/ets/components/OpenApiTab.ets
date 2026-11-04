/**
 * OpenApiTab — 跨应用调用管理页
 *
 * 提供三块内容：
 *   1. 服务状态：daemon 是否在线、队列槽位是否就绪、协议版本
 *   2. 白名单管理：哪些 App 可以免确认调用。可手动添加 bundleName，也可从调用记录里一键加
 *   3. 调用记录：谁调用过、调了多少次、最近时间
 *
 * 设计意图：让用户对"谁在用我的特权接口"有完全的可见性和控制权。
 */

import { common } from '@kit.AbilityKit';
import { promptAction } from '@kit.ArkUI';
import { fileIo } from '@kit.CoreFileKit';
import { BusClient } from '../services/BusClient';
import { TrustManager, CallerRecord } from '../services/TrustManager';
import { CommandResult } from '../model/CommandResult';

@Component
export struct OpenApiTab {
  busClient: BusClient = new BusClient();

  @State daemonOnline: boolean = false;
  @State daemonPid: number = 0;
  @State queueReady: boolean = false;
  @State trusted: string[] = [];
  @State blocked: string[] = [];
  @State callLog: CallerRecord[] = [];
  @State inputBundle: string = '';
  @State loading: boolean = true;

  aboutToAppear(): void {
    this.refreshAll();
  }

  async refreshAll(): Promise<void> {
    this.loading = true;
    const ctx = getContext(this) as common.UIAbilityContext;

    // 1. daemon 状态
    const status = await this.busClient.checkDaemonStatus();
    this.daemonOnline = status !== null;
    if (status) {
      this.daemonPid = status.pid;
    }

    // 2. 队列是否就绪（检查 req/ 目录下是否有槽位文件）
    this.queueReady = await this.checkQueue();

    // 3. 白/黑名单、调用记录
    this.trusted = await TrustManager.getTrusted(ctx);
    this.blocked = await TrustManager.getBlocked(ctx);
    this.callLog = await TrustManager.getCallLog(ctx);

    this.loading = false;
  }

  /**
   * 检查队列槽位是否已创建。
   * 直接探测 slot0.req 是否存在 —— 比起一条 shell 命令快得多，
   * 也不用担心 req/res 目录和总线的路径视角问题。
   */
  async checkQueue(): Promise<boolean> {
    const dir = this.busClient.getBusDir();
    if (!dir) {
      return false;
    }
    try {
      return fileIo.accessSync(`${dir}/req/slot0.req`);
    } catch (err) {
      return false;
    }
  }

  /** 手动添加白名单 */
  async addTrusted(): Promise<void> {
    const name = this.inputBundle.trim();
    if (!name) {
      this.toast('请输入包名');
      return;
    }
    // 简单校验：包名至少含一个点
    if (name.indexOf('.') < 0) {
      this.toast('包名格式不正确（应形如 com.example.app）');
      return;
    }
    const ctx = getContext(this) as common.UIAbilityContext;
    await TrustManager.addTrusted(ctx, name);
    this.inputBundle = '';
    this.trusted = await TrustManager.getTrusted(ctx);
    this.blocked = await TrustManager.getBlocked(ctx);
    this.toast(`已加入白名单：${name}`);
  }

  async removeTrusted(name: string): Promise<void> {
    const ctx = getContext(this) as common.UIAbilityContext;
    await TrustManager.removeTrusted(ctx, name);
    this.trusted = await TrustManager.getTrusted(ctx);
    this.toast(`已移除：${name}`);
  }

  async blockApp(name: string): Promise<void> {
    const ctx = getContext(this) as common.UIAbilityContext;
    await TrustManager.addBlocked(ctx, name);
    this.trusted = await TrustManager.getTrusted(ctx);
    this.blocked = await TrustManager.getBlocked(ctx);
    this.toast(`已拉黑：${name}`);
  }

  async unblockApp(name: string): Promise<void> {
    const ctx = getContext(this) as common.UIAbilityContext;
    await TrustManager.removeBlocked(ctx, name);
    this.blocked = await TrustManager.getBlocked(ctx);
    this.toast(`已解除拉黑：${name}`);
  }

  async clearLog(): Promise<void> {
    const ctx = getContext(this) as common.UIAbilityContext;
    await TrustManager.clearCallLog(ctx);
    this.callLog = [];
    this.toast('调用记录已清空');
  }

  toast(msg: string): void {
    try {
      promptAction.showToast({ message: msg, duration: 1800 });
    } catch (err) {
      // 忽略
    }
  }

  formatTime(ts: number): string {
    if (!ts) {
      return '-';
    }
    const d = new Date(ts);
    const mm = (d.getMonth() + 1).toString().padStart(2, '0');
    const dd = d.getDate().toString().padStart(2, '0');
    const h = d.getHours().toString().padStart(2, '0');
    const mi = d.getMinutes().toString().padStart(2, '0');
    return `${mm}-${dd} ${h}:${mi}`;
  }

  build() {
    Scroll() {
      Column() {
        // ============ 服务状态 ============
        this.SectionTitle('服务状态')

        Column() {
          this.StatusRow('Daemon', this.daemonOnline,
            this.daemonOnline ? `运行中 (PID ${this.daemonPid})` : '未运行')
          Divider().color('#1E293B').margin({ top: 8, bottom: 8 })
          this.StatusRow('调用队列', this.queueReady,
            this.queueReady ? '就绪（16 个槽位）' : '未创建，需运行 setup-queue.sh')
          Divider().color('#1E293B').margin({ top: 8, bottom: 8 })
          this.StatusRow('协议', true, '方案 A（Want）+ 方案 C+（队列）')
        }
        .width('100%')
        .padding(12)
        .backgroundColor('#1A2332')
        .borderRadius(12)
        .margin({ bottom: 12 })

        // ============ 安全提示 ============
        Column() {
          Text('⚠️ 安全提示')
            .fontSize(12)
            .fontColor('#FBBF24')
            .fontWeight(FontWeight.Bold)
            .margin({ bottom: 4 })
          Text('这条通道等价于给调用方 shell（UID 2000）权限：可读取其他应用数据、' +
               '模拟点击输入、强制停止应用、修改系统设置。\n\n' +
               '白名单内的应用调用时不会询问你，请只添加你完全信任的应用。')
            .fontSize(11)
            .fontColor('#94A3B8')
            .lineHeight(16)
        }
        .width('100%')
        .padding(12)
        .backgroundColor('#2A2415')
        .borderRadius(12)
        .margin({ bottom: 12 })
        .alignItems(HorizontalAlign.Start)

        // ============ 白名单 ============
        this.SectionTitle(`白名单（${this.trusted.length}）`)

        // 添加输入框
        Row() {
          TextInput({ text: this.inputBundle, placeholder: '输入包名，如 com.example.app' })
            .layoutWeight(1)
            .fontSize(12)
            .backgroundColor('#0F172A')
            .fontColor('#38BDF8')
            .placeholderColor('#475569')
            .placeholderFont({ size: 12 })
            .borderRadius(6)
            .onChange((v: string) => {
              this.inputBundle = v;
            })
          Button('添加')
            .fontSize(12)
            .height(32)
            .margin({ left: 6 })
            .backgroundColor('#38BDF8')
            .fontColor('#090D16')
            .onClick(() => this.addTrusted())
        }
        .width('100%')
        .margin({ bottom: 8 })

        // 白名单列表
        if (this.trusted.length === 0) {
          Row() {
            Text('暂无白名单。白名单外的应用调用时会先询问你。')
              .fontSize(11)
              .fontColor('#64748B')
          }
          .width('100%')
          .padding(12)
          .backgroundColor('#1A2332')
          .borderRadius(8)
          .margin({ bottom: 12 })
        } else {
          Column() {
            ForEach(this.trusted, (name: string, idx: number) => {
              Row() {
                Text('✓')
                  .fontSize(12)
                  .fontColor('#4ADE80')
                  .width(20)
                Text(name)
                  .fontSize(12)
                  .fontColor('#C3E88D')
                  .fontFamily('JetBrains Mono, Consolas, monospace')
                  .layoutWeight(1)
                Text('移除')
                  .fontSize(11)
                  .fontColor('#F87171')
                  .padding({ left: 8, right: 8, top: 4, bottom: 4 })
                  .onClick(() => this.removeTrusted(name))
              }
              .width('100%')
              .padding({ top: 8, bottom: 8 })
              if (idx < this.trusted.length - 1) {
                Divider().color('#0D1527')
              }
            }, (name: string) => name)
          }
          .width('100%')
          .padding({ left: 12, right: 12 })
          .backgroundColor('#1A2332')
          .borderRadius(12)
          .margin({ bottom: 12 })
        }

        // ============ 黑名单 ============
        if (this.blocked.length > 0) {
          this.SectionTitle(`已拉黑（${this.blocked.length}）`)
          Column() {
            ForEach(this.blocked, (name: string, idx: number) => {
              Row() {
                Text('✕')
                  .fontSize(12)
                  .fontColor('#F87171')
                  .width(20)
                Text(name)
                  .fontSize(12)
                  .fontColor('#94A3B8')
                  .fontFamily('JetBrains Mono, Consolas, monospace')
                  .layoutWeight(1)
                Text('解除')
                  .fontSize(11)
                  .fontColor('#82B1FF')
                  .padding({ left: 8, right: 8, top: 4, bottom: 4 })
                  .onClick(() => this.unblockApp(name))
              }
              .width('100%')
              .padding({ top: 8, bottom: 8 })
              if (idx < this.blocked.length - 1) {
                Divider().color('#0D1527')
              }
            }, (name: string) => name)
          }
          .width('100%')
          .padding({ left: 12, right: 12 })
          .backgroundColor('#1A2332')
          .borderRadius(12)
          .margin({ bottom: 12 })
        }

        // ============ 调用记录 ============
        Row() {
          Text(`调用记录（${this.callLog.length}）`)
            .fontSize(13)
            .fontColor('#94A3B8')
            .fontWeight(FontWeight.Bold)
            .layoutWeight(1)
          if (this.callLog.length > 0) {
            Text('清空')
              .fontSize(11)
              .fontColor('#F87171')
              .padding({ left: 8, right: 8, top: 4, bottom: 4 })
              .onClick(() => this.clearLog())
          }
        }
        .width('100%')
        .margin({ bottom: 8 })

        if (this.callLog.length === 0) {
          Row() {
            Text('还没有应用调用过。')
              .fontSize(11)
              .fontColor('#64748B')
          }
          .width('100%')
          .padding(12)
          .backgroundColor('#1A2332')
          .borderRadius(8)
          .margin({ bottom: 12 })
        } else {
          Column() {
            ForEach(this.callLog, (rec: CallerRecord, idx: number) => {
              Column() {
                Row() {
                  Text(rec.bundleName)
                    .fontSize(12)
                    .fontColor('#C3E88D')
                    .fontFamily('JetBrains Mono, Consolas, monospace')
                    .layoutWeight(1)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text(`${rec.count} 次`)
                    .fontSize(10)
                    .fontColor('#64748B')
                }
                .width('100%')

                Row() {
                  Text(`最近 ${this.formatTime(rec.lastTime)}`)
                    .fontSize(10)
                    .fontColor('#475569')
                    .layoutWeight(1)
                  // 快捷操作：加入白名单 / 拉黑
                  if (this.trusted.indexOf(rec.bundleName) < 0) {
                    Text('信任')
                      .fontSize(10)
                      .fontColor('#4ADE80')
                      .padding({ left: 8, right: 8, top: 2, bottom: 2 })
                      .backgroundColor('#142018')
                      .borderRadius(4)
                      .margin({ right: 6 })
                      .onClick(async () => {
                        const ctx = getContext(this) as common.UIAbilityContext;
                        await TrustManager.addTrusted(ctx, rec.bundleName);
                        this.trusted = await TrustManager.getTrusted(ctx);
                        this.blocked = await TrustManager.getBlocked(ctx);
                        this.toast(`已信任：${rec.bundleName}`);
                      })
                  }
                  Text('拉黑')
                    .fontSize(10)
                    .fontColor('#F87171')
                    .padding({ left: 8, right: 8, top: 2, bottom: 2 })
                    .backgroundColor('#2A1515')
                    .borderRadius(4)
                    .onClick(() => this.blockApp(rec.bundleName))
                }
                .width('100%')
                .margin({ top: 4 })
              }
              .width('100%')
              .padding({ top: 8, bottom: 8 })
              if (idx < this.callLog.length - 1) {
                Divider().color('#0D1527')
              }
            }, (rec: CallerRecord) => rec.bundleName)
          }
          .width('100%')
          .padding({ left: 12, right: 12 })
          .backgroundColor('#1A2332')
          .borderRadius(12)
          .margin({ bottom: 12 })
        }

        // ============ 协议说明 ============
        this.SectionTitle('给其他 App 的接入方式')
        Column() {
          Text('方式 A（会弹出确认，用户可拒绝）\n' +
               '  action: hmpriv.execute\n' +
               '  parameters: { cmd: "id" }\n\n' +
               '方式 C+（后台队列，白名单内免确认）\n' +
               '  写 req/slotN.req，读 res/slotN.res\n' +
               '  结果格式：RC:<code> / TIME:<ts> / <output>\n\n' +
               '完整协议见项目 docs/跨应用调用协议.md')
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

        Button('刷新状态')
          .width('100%')
          .fontSize(12)
          .height(36)
          .backgroundColor('#1E293B')
          .fontColor('#94A3B8')
          .margin({ bottom: 24 })
          .onClick(() => this.refreshAll())
      }
      .width('100%')
      .padding(12)
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Auto)
  }

  @Builder
  SectionTitle(label: string) {
    Text(label)
      .fontSize(13)
      .fontColor('#94A3B8')
      .fontWeight(FontWeight.Bold)
      .margin({ bottom: 8 })
      .width('100%')
  }

  @Builder
  StatusRow(label: string, ok: boolean, detail: string) {
    Row() {
      Circle({ width: 8, height: 8 })
        .fill(ok ? '#4ADE80' : '#F87171')
        .margin({ right: 10 })
      Text(label)
        .fontSize(12)
        .fontColor('#E2E8F0')
        .width(80)
      Text(detail)
        .fontSize(11)
        .fontColor(ok ? '#94A3B8' : '#FBBF24')
        .layoutWeight(1)
        .maxLines(2)
    }
    .width('100%')
  }
}
