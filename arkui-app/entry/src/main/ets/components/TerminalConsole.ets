/**
 * TerminalConsole — 终端控制台组件
 *
 * 提供终端输出区、命令输入框、快捷命令栏。
 * 通过 BusClient 与 daemon 通信。
 *
 * 注意：BusClient 作为普通属性传递（非 @Prop/@Link），
 * 因为 ArkTS 的 @Prop 不支持自定义类类型。
 */

import { BusClient } from '../services/BusClient';
import { CommandResult } from '../model/CommandResult';
import { QUICK_COMMANDS, MAX_CMD_HISTORY } from '../common/Constants';

@Component
export struct TerminalConsole {
  @State output: string = 'HMArkPriv Terminal v1.0\n等待连接 daemon...\n\n';
  @State inputCmd: string = '';
  @State isExecuting: boolean = false;
  @Link cmdHistory: string[];
  @Prop needAuth: boolean = true;
  busClient: BusClient = new BusClient();
  onRequestAuth: () => void = () => {};
  private scroller: Scroller = new Scroller();

  build() {
    Column() {
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

      // ===== 输入行 =====
      Row() {
        Text('$')
          .fontFamily('JetBrains Mono, Consolas, monospace')
          .fontSize(14)
          .fontColor('#38BDF8')
          .margin({ right: 6 })

        TextInput({ text: this.inputCmd, placeholder: '输入 Shell 指令...' })
          .layoutWeight(1)
          .fontFamily('JetBrains Mono, Consolas, monospace')
          .fontSize(13)
          .backgroundColor('#0F172A')
          .fontColor('#38BDF8')
          .placeholderColor('#475569')
          .placeholderFont({ size: 13 })
          .borderRadius(6)
          .onSubmit(() => {
            this.runCommand();
          })
          .onChange((val: string) => {
            this.inputCmd = val;
          })

        Button(this.isExecuting ? '...' : '执行')
          .backgroundColor('#38BDF8')
          .fontColor('#090D16')
          .fontSize(13)
          .height(36)
          .margin({ left: 6 })
          .enabled(!this.isExecuting && this.inputCmd.length > 0)
          .onClick(() => this.runCommand())
      }
      .width('100%')
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
