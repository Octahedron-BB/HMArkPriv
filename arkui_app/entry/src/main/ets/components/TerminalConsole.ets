/**
 * TerminalConsole — 终端控制台组件
 *
 * 提供终端输出区、命令输入框、快捷命令栏，以及指令手册侧边栏。
 * 通过 BusClient 与 daemon 通信。
 *
 * 注意：BusClient 作为普通属性传递（非 @Prop/@Link），
 * 因为 ArkTS 的 @Prop 不支持自定义类类型。
 */

import { BusClient } from '../services/BusClient';
import { CommandResult } from '../model/CommandResult';
import { QUICK_COMMANDS, MAX_CMD_HISTORY } from '../common/Constants';
import { CommandPanel } from './CommandPanel';

@Component
export struct TerminalConsole {
  @State output: string = 'HMArkPriv Terminal v1.0\n等待连接 daemon...\n';
  @State inputCmd: string = '';
  @State isExecuting: boolean = false;
  /** 指令手册侧边栏是否展开 */
  @State showPanel: boolean = false;
  @Link cmdHistory: string[];
  @Prop needAuth: boolean = true;
  @Prop @Watch('onDaemonStatusChanged') daemonOnline: boolean = false;
  @Prop @Watch('onDaemonStatusChanged') daemonPid: number = 0;
  private hasReportedConnected: boolean = false;
  busClient: BusClient = new BusClient();
  onRequestAuth: () => void = () => {};
  private scroller: Scroller = new Scroller();

  aboutToAppear() {
    this.checkInitialDaemon();
  }

  async checkInitialDaemon(): Promise<void> {
    if (this.daemonOnline && !this.hasReportedConnected) {
      this.hasReportedConnected = true;
      this.appendConnectedLog(this.daemonPid);
      return;
    }
    const status = await this.busClient.checkDaemonStatus();
    if (status && !this.hasReportedConnected) {
      this.hasReportedConnected = true;
      this.appendConnectedLog(status.pid);
    }
  }

  onDaemonStatusChanged(): void {
    if (this.daemonOnline && !this.hasReportedConnected) {
      this.hasReportedConnected = true;
      this.appendConnectedLog(this.daemonPid);
    }
  }

  private appendConnectedLog(pid: number): void {
    const pidInfo = pid > 0 ? ` (PID: ${pid})` : '';
    this.output += `已连接 daemon${pidInfo}\n\n`;
  }

  build() {
    Stack({ alignContent: Alignment.TopEnd }) {
      this.TerminalMain()

      // ===== 指令手册侧边栏（覆盖层）=====
      if (this.showPanel) {
        // 半透明遮罩：点击关闭
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor('#00000099')
          .onClick(() => {
            this.showPanel = false;
          })

        // 面板本体
        Column() {
          CommandPanel({
            onPick: (cmd: string) => {
              this.inputCmd = cmd;
              this.showPanel = false;
            },
            onClose: () => {
              this.showPanel = false;
            },
          })
        }
        .width('86%')
        .height('100%')
      }
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  TerminalMain() {
    Column() {
      // ===== 工具条 =====
      Row() {
        Text('$ 终端')
          .fontSize(12)
          .fontColor('#64748B')
          .fontFamily('JetBrains Mono, Consolas, monospace')
          .layoutWeight(1)

        // 指令手册入口
        Row() {
          Text('📖')
            .fontSize(12)
          Text(' 指令手册')
            .fontSize(11)
            .fontColor('#82B1FF')
        }
        .padding({ left: 10, right: 10, top: 5, bottom: 5 })
        .backgroundColor('#1E293B')
        .borderRadius(12)
        .margin({ right: 6 })
        .onClick(() => {
          this.showPanel = true;
        })

        // 清屏
        Text('清屏')
          .fontSize(11)
          .fontColor('#64748B')
          .padding({ left: 10, right: 10, top: 5, bottom: 5 })
          .backgroundColor('#1E293B')
          .borderRadius(12)
          .onClick(() => {
            this.output = '';
          })
      }
      .width('100%')
      .padding({ left: 4, right: 4, bottom: 6 })

      // ===== 终端输出区 =====
      Scroll(this.scroller) {
        Text(this.output)
          .fontFamily('JetBrains Mono, Consolas, Courier New, monospace')
          .fontSize(13)
          .fontColor('#C3E88D')
          .textAlign(TextAlign.Start)
          .padding(12)
          .width('100%')
          .copyOption(CopyOptions.LocalDevice)
      }
      .backgroundColor('#0D1527')
      .borderRadius(8)
      .layoutWeight(1)
      .width('100%')
      .scrollBar(BarState.Auto)

      // ===== 快捷命令栏 =====
      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(QUICK_COMMANDS, (cmd: string) => {
          Text(cmd)
            .fontSize(12)
            .fontColor('#82B1FF')
            .backgroundColor('#1E293B')
            .borderRadius(8)
            .padding({ left: 8, right: 8, top: 4, bottom: 4 })
            .margin({ right: 4, bottom: 4 })
            .onClick(() => {
              this.inputCmd = cmd;
              this.runCommand();
            })
        }, (cmd: string, index: number) => `${cmd}_${index}`)
      }
      .width('100%')
      .padding({ left: 8, right: 8, top: 4, bottom: 4 })

      // ===== 输入区（多行，长指令自动换行）=====
      Row() {
        Text('$')
          .fontFamily('JetBrains Mono, Consolas, monospace')
          .fontSize(14)
          .fontColor('#38BDF8')
          .margin({ right: 6, top: 10 })
          .alignSelf(ItemAlign.Start)

        TextArea({ text: this.inputCmd, placeholder: '输入 Shell 指令，长指令会自动换行...' })
          .layoutWeight(1)
          .constraintSize({ minHeight: 40, maxHeight: 132 })
          .fontFamily('JetBrains Mono, Consolas, monospace')
          .fontSize(13)
          .backgroundColor('#0F172A')
          .fontColor('#38BDF8')
          .placeholderColor('#475569')
          .placeholderFont({ size: 13 })
          .borderRadius(6)
          .padding({ left: 8, right: 8, top: 8, bottom: 8 })
          .enterKeyType(EnterKeyType.Send)
          .onSubmit(() => {
            this.runCommand();
          })
          .onChange((val: string) => {
            this.inputCmd = val;
          })

        // 按钮列：执行 + 換行，横排才不会被输入框的最小高度压扁
        Row() {
          Button(this.isExecuting ? '...' : '执行')
            .backgroundColor('#38BDF8')
            .fontColor('#090D16')
            .fontSize(13)
            .layoutWeight(1)
            .height(38)
            .padding({ left: 4, right: 4 })
            .enabled(!this.isExecuting && this.inputCmd.length > 0)
            .onClick(() => this.runCommand())

          // 长指令需要多行编辑时用：追加一个换行
          Button('⏎')
            .backgroundColor('#1E293B')
            .fontColor('#94A3B8')
            .fontSize(14)
            .width(34)
            .height(38)
            .margin({ left: 4 })
            .onClick(() => {
              this.inputCmd = this.inputCmd + '\n';
            })
        }
        .width(104)
        .margin({ left: 6 })
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)
      .padding({ left: 8, right: 8, top: 4, bottom: 8 })
    }
    .width('100%')
    .height('100%')
  }

  /**
   * 执行命令
   */
  async runCommand(): Promise<void> {
    if (!this.inputCmd || this.isExecuting) {
      return;
    }

    const cmd = this.inputCmd.trim();
    if (!cmd) {
      return;
    }

    // 未授权总线目录时直接拦截
    if (this.needAuth) {
      this.inputCmd = '';
      this.output += `\n$ ${cmd}\n[未授权] 请先点击顶部「授权」按钮选择 Download/HMArkPriv 目录\n`;
      this.onRequestAuth();
      return;
    }

    // 添加到历史
    if (this.cmdHistory.length === 0 || this.cmdHistory[this.cmdHistory.length - 1] !== cmd) {
      this.cmdHistory.push(cmd);
      if (this.cmdHistory.length > MAX_CMD_HISTORY) {
        this.cmdHistory.shift();
      }
    }

    this.isExecuting = true;
    this.inputCmd = '';
    this.output += `\n$ ${cmd}\n`;

    const result: CommandResult = await this.busClient.execute(cmd);

    if (result.success) {
      this.output += result.output + '\n';
    } else if (result.exitCode !== 0 && result.output) {
      this.output += result.output + '\n';
      this.output += `[exit: ${result.exitCode}]\n`;
    } else {
      this.output += result.output + '\n';
    }

    this.isExecuting = false;
  }
}
