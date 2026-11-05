/**
 * BusClient — 文件总线 IPC 客户端
 *
 * 通过文件系统与 daemon.sh (UID 2000) 通信：
 * - 写 cmd.req 发送命令
 * - 读 cmd.res 轮询获取结果
 * - 读 status.json 检测 daemon 存活
 *
 * 鸿蒙沙箱限制：普通 App 无法直接访问 /storage/media/100/... 路径。
 * 实际使用时需要通过 @ohos.file.picker 让用户授权目录访问权限，
 * 或使用 App 沙箱内的 Download 目录作为中转。
 */

import { fileIo } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { DEFAULT_BUS_DIR, BUS_FILE_REQ, BUS_FILE_RES, BUS_FILE_STATUS,
  POLL_INTERVAL_MS, MAX_POLL_ATTEMPTS, TIMEOUT_MS } from '../common/Constants';
import { CommandResult, DaemonStatus, createFailedResult } from '../model/CommandResult';

const DOMAIN = 0x9201;
const TAG = 'BusClient';

export class BusClient {
  private busDir: string;
  private reqCounter: number = 0;
  /**
   * 全局串行锁。
   *
   * 【为什么需要】
   * 总线只有一组 cmd.req / cmd.res 文件，且 daemon 是单线程串行执行命令。
   * 如果两个页面同时发命令（比如终端页和首页的快捷按钮），
   * 后写的 reqId 会覆盖前一个，导致先发的命令永远收不到匹配的响应 → 超时。
   *
   * 这里用一条 Promise 链把请求排队，保证同一时刻只有一条在飞。
   * 排队期间不占用轮询，所以不会互相干扰。
   */
  private lockChain: Promise<void> = Promise.resolve();

  constructor(busDir: string = DEFAULT_BUS_DIR) {
    this.busDir = busDir;
  }

  /** 设置总线目录 */
  setBusDir(dir: string): void {
    this.busDir = dir;
    hilog.info(DOMAIN, TAG, `busDir set to: ${dir}`);
  }

  /** 获取当前总线目录 */
  getBusDir(): string {
    return this.busDir;
  }

  /**
   * 检测 daemon 是否存活
   * 读取 status.json，检查 status 字段是否为 "ready"
   */
  async checkDaemonStatus(): Promise<DaemonStatus | null> {
    const statusPath = `${this.busDir}/${BUS_FILE_STATUS}`;
    try {
      const text = this.readTextFile(statusPath);
      if (!text) {
        return null;
      }
      const json: DaemonStatus = JSON.parse(text) as DaemonStatus;
      if (json.status === 'ready') {
        hilog.info(DOMAIN, TAG, `daemon alive: pid=${json.pid} uid=${json.uid}`);
        return json;
      }
      hilog.warn(DOMAIN, TAG, `daemon status not ready: ${json.status}`);
      return null;
    } catch (e) {
      // 文件不存在或解析失败
      hilog.debug(DOMAIN, TAG, `checkDaemonStatus: ${e}`);
      return null;
    }
  }

  /**
   * 执行 shell 命令
   *
   * 流程：
   * 1. 生成唯一 req_id
   * 2. 写入 cmd.req: "${reqId}|${command}\n"
   * 3. 轮询读 cmd.res，匹配首行 "ID:${reqId}"
   * 4. 解析 RC 和输出
   * 5. 超时返回错误
   */
  /**
   * 执行一条 shell 命令（对外入口）。
   *
   * 用锁链保证串行：总线只有一组 cmd.req/cmd.res，且 daemon 单线程，
   * 并发写入会互相覆盖导致先发的请求永远等不到响应。
   */
  async execute(command: string): Promise<CommandResult> {
    // 把本次任务接到锁链尾部，等前面所有请求做完再执行
    const prev = this.lockChain;
    let release: () => void = () => {};
    this.lockChain = new Promise<void>((resolve) => {
      release = resolve;
    });

    try {
      await prev;
      return await this.executeOnce(command);
    } finally {
      release();
    }
  }

  /** 单次执行（不含排队逻辑），由 execute() 串行调用 */
  private async executeOnce(command: string): Promise<CommandResult> {
    // 【危险命令拦截】真机实测：以下命令会阻塞在内核态（Binder 调用挂起），
    // 连 SIGKILL 都无法终止，导致 daemon 永久失联。
    // 详见 docs/真机vs模拟器差异报告.md 第四章。
    const danger = BusClient.checkDangerous(command);
    if (danger) {
      hilog.warn(DOMAIN, TAG, `blocked dangerous command: ${command}`);
      return createFailedResult(
        `[已拦截] 该命令会导致 daemon 永久挂起：\n${command}\n\n原因：${danger}\n\n` +
        `这些命令阻塞在内核态 Binder 调用中，连 SIGKILL 都无法终止。\n` +
        `如需内存信息，请使用 hidumper --mem | head -20（带管道会自动退出）。`,
        0,
      );
    }

    const startTime = Date.now();
    const reqId = `req_${Date.now()}_${this.reqCounter++}`;

    hilog.info(DOMAIN, TAG, `execute: reqId=${reqId} cmd="${command}"`);

    // 写入请求
    const reqPath = `${this.busDir}/${BUS_FILE_REQ}`;
    const reqContent = `${reqId}|${command}\n`;
    try {
      this.writeTextFile(reqPath, reqContent);
    } catch (e) {
      hilog.error(DOMAIN, TAG, `write cmd.req failed: ${e}`);
      return createFailedResult(`[错误] 写入 cmd.req 失败: ${e}`, Date.now() - startTime);
    }

    // 轮询读取响应
    const resPath = `${this.busDir}/${BUS_FILE_RES}`;

    for (let i = 0; i < MAX_POLL_ATTEMPTS; i++) {
      await this.sleep(POLL_INTERVAL_MS);
      try {
        const text = this.readTextFile(resPath);
        if (!text) {
          continue;
        }

        const lines = text.split('\n');
        const firstLine = lines[0];

        // 匹配 "ID:req_xxx RC:N TIME:..."
        if (firstLine && firstLine.startsWith(`ID:${reqId} `)) {
          const rcMatch = firstLine.match(/RC:(-?\d+)/);
          const timeMatch = firstLine.match(/TIME:(.+)$/);
          const output = lines.slice(1).join('\n').trim();
          const exitCode = rcMatch ? parseInt(rcMatch[1]) : -1;
          const durationMs = Date.now() - startTime;

          hilog.info(DOMAIN, TAG, `response: rc=${exitCode} time=${timeMatch?.[1]} dur=${durationMs}ms`);

          return {
            success: exitCode === 0,
            exitCode,
            output,
            timestamp: timeMatch?.[1]?.trim() ?? '',
            durationMs,
          };
        }
      } catch (e) {
        // 文件可能暂时不存在，继续重试
      }
    }

    // 超时：先确认 daemon 是否还活着，再决定给什么提示。
    // 只剩一种"真超时"就是命令本身太长（daemon 上限 25 秒），
    // 如果连 status.json 都不响应，那才是 daemon 挂了。
    hilog.warn(DOMAIN, TAG, `timeout waiting for response: ${reqId}`);
    const alive = await this.checkDaemonStatus();
    if (alive !== null) {
      return createFailedResult(
        `[超时] 命令执行超过 ${Math.round(TIMEOUT_MS / 1000)} 秒仍未返回。\n` +
        'daemon 在线，可能是命令本身耗时过长（如 hidumper 大表格、流式输出）。\n' +
        '建议加管道限制输出量，例如 `hidumper --mem | head -20`。',
        Date.now() - startTime,
      );
    }
    return createFailedResult(
      '[错误] 响应超时，且 daemon 无响应。\n' +
      '请通过 hdc 重新部署 daemon.sh:\n' +
      '  hdc file send core/daemon.sh /data/local/tmp/hmpriv/daemon.sh\n' +
      '  hdc shell "sh -c \'nohup sh /data/local/tmp/hmpriv/daemon.sh >/dev/null 2>&1 & sleep 2\'"',
      Date.now() - startTime,
    );
  }

  // ===== 内部文件 I/O 方法 =====

  /**
   * 读取文本文件内容
   * 使用 fileIo.readTextSync 简化读取
   */
  private readTextFile(path: string): string {
    try {
      return fileIo.readTextSync(path);
    } catch (e) {
      return '';
    }
  }

  /**
   * 写入文本文件（覆盖写）
   * 使用 openSync + writeSync + fsync + closeSync
   *
   * fsync 保证内容真正落盘，避免 daemon 在另一个进程读到空/旧内容。
   */
  private writeTextFile(path: string, content: string): void {
    // OpenMode.READ_WRITE(0o2) | CREATE(0o100) | TRUNC(0o1000)
    const mode = 0o2 | 0o100 | 0o1000;
    const file = fileIo.openSync(path, mode);
    try {
      fileIo.writeSync(file.fd, content);
      fileIo.fsyncSync(file.fd);
    } finally {
      fileIo.closeSync(file);
    }
  }

  /**
   * 检查是否是会卡死 daemon 的危险命令。
   * 返回原因字符串（非空表示危险），空字符串表示安全。
   *
   * 【真机实测依据 2026-11-04】
   * - hidumper -c            → 永久卡死（Binder 阻塞，SIGKILL 无效）
   * - hidumper --mem（无管道）→ 输出巨大，$() 捕获压力过大导致阻塞
   * 这两个命令阻塞在不可中断状态，daemon 与 App 都无法恢复，只能重启 daemon。
   */
  static checkDangerous(command: string): string {
    const c = command.trim();
    const lower = c.toLowerCase();

    // hidumper -c / --clusters：dump 全部系统信息，必卡
    if (/^hidumper\s+(-c|--clusters)(\s|$)/.test(c) ||
        /^hidumper\s+-c(\s|$)/.test(c)) {
      return 'hidumper -c 会 dump 全部系统信息，阻塞在内核态 Binder 调用';
    }

    // hidumper --mem 不带管道：输出量极大
    if (/^hidumper\s+--mem(\s|$)/.test(c) && !c.includes('|')) {
      return 'hidumper --mem 输出量极大（真机 200+ 进程），不加管道会导致阻塞';
    }

    // 其他已知会阻塞的：直接写 console 的、无限流式的
    if (/^tail\s+-f/.test(c)) {
      return 'tail -f 是流式输出，永不退出（daemon 虽有 20s 超时但会拖慢）';
    }

    return '';
  }

  /**
   * 延时
   */
  private sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve) => setTimeout(resolve, ms));
  }
}
