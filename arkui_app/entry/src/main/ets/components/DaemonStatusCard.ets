/**
 * DaemonStatusCard — Daemon 状态卡片组件
 *
 * 显示 daemon 连接状态、PID、UID。
 * 定时检测 daemon 是否存活。
 */

import { BusClient } from '../services/BusClient';
import { DaemonStatus } from '../model/CommandResult';

@Component
export struct DaemonStatusCard {
  busClient: BusClient = new BusClient();
  @State daemonStatus: DaemonStatus | null = null;
  @State isChecking: boolean = false;
  @State lastCheckTime: string = '';
  private timerId: number = -1;

  aboutToAppear(): void {
    this.checkStatus();
    this.timerId = setInterval(() => {
      this.checkStatus();
    }, 5000);
  }

  aboutToDisappear(): void {
    if (this.timerId !== -1) {
      clearInterval(this.timerId);
      this.timerId = -1;
    }
  }

  async checkStatus(): Promise<void> {
    this.isChecking = true;
    this.daemonStatus = await this.busClient.checkDaemonStatus();
    this.lastCheckTime = this.formatTime(new Date());
    this.isChecking = false;
  }

  formatTime(d: Date): string {
    const h = d.getHours().toString().padStart(2, '0');
    const m = d.getMinutes().toString().padStart(2, '0');
    const s = d.getSeconds().toString().padStart(2, '0');
    return `${h}:${m}:${s}`;
  }

  build() {
    Row() {
      // 状态指示灯
      Circle({ width: 12, height: 12 })
        .fill(this.daemonStatus ? '#4ADE80' : '#F87171')
        .margin({ right: 12 })

      // 状态信息
      Column() {
        Text(this.daemonStatus ? 'Daemon 在线' : 'Daemon 离线')
          .fontSize(16)
          .fontColor('#E2E8F0')
          .fontWeight(FontWeight.Bold)

        if (this.daemonStatus) {
          Text(`PID: ${this.daemonStatus.pid}  UID: ${this.daemonStatus.uid}`)
            .fontSize(12)
            .fontColor('#94A3B8')
            .margin({ top: 2 })
        } else {
          Text('请通过 hdc 部署 daemon.sh')
            .fontSize(12)
            .fontColor('#F87171')
            .margin({ top: 2 })
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      // 刷新按钮
      Column() {
        Text(this.isChecking ? '...' : '↻')
          .fontSize(18)
          .fontColor('#38BDF8')
          .onClick(() => this.checkStatus())

        Text(this.lastCheckTime)
          .fontSize(10)
          .fontColor('#475569')
          .margin({ top: 2 })
      }
      .width(48)
      .alignItems(HorizontalAlign.Center)
    }
    .width('100%')
    .padding(16)
    .backgroundColor('#1A2332')
    .borderRadius(12)
  }
}
