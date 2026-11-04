/**
 * HMArkPriv 跨应用调用 SDK
 * ============================================================================
 * 给其他鸿蒙 App 使用，通过两种方式调用 HMArkPriv 执行特权 shell 命令。
 *
 * 使用前请把本文件拷进你的工程（src/main/ets/utils/HmprivClient.ets），
 * 然后 import 即可。
 *
 * 前置条件：
 *   1. 用户手机上已部署 HMArkPriv 的 daemon（hdc 一次性部署）
 *   2. 用户已打开过 HMArkPriv App 并授权过一次文件夹访问
 *   3. 你的 App 需要 READ_MEDIA / WRITE_MEDIA 权限（方案 C 用）
 *      module.json5:
 *        "requestPermissions": [
 *          { "name": "ohos.permission.READ_MEDIA" },
 *          { "name": "ohos.permission.WRITE_MEDIA" }
 *        ]
 *
 * ============================================================================
 * 两种调用方式对比
 * ============================================================================
 *
 * 方式 A：Want + startAbilityForResult（会弹出确认卡片）
 *   优点：最标准，不需要文件权限，能同步拿到结果
 *   缺点：用户需要点一次「允许」（首次调用必然要点；
 *         用户勾了"信任该应用"后加入白名单，之后免确认）
 *   适合：低频调用、需要用户知情同意的操作
 *
 * 方式 C+：共享文件队列（完全后台，不拉起界面）
 *   优点：完全无感，不依赖 HMArkPriv App 存活（daemon 独立运行），支持并发
 *   缺点：需要文件权限；需要 50ms 级别的轮询
 *   适合：高频调用、后台任务、需要隐私的场景
 *
 * ============================================================================
 */

import { common, Want } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';

/** HMArkPriv 的包名 */
const HMPRIV_BUNDLE = 'com.octahedron.hmpriv';
const HMPRIV_ABILITY = 'EntryAbility';
/** 自定义 action，用于区分普通启动 */
const ACTION_EXECUTE = 'hmpriv.execute';

/**
 * 总线目录（方案 C+ 用）。
 *
 * 【为什么是这个路径】
 * 鸿蒙给每个 App 一个沙箱虚拟视图 /storage/Users/currentUser/...，
 * 映射到真实用户目录。配合 READ_MEDIA/WRITE_MEDIA，
 * 以及用户对 HMArkPriv 目录的 picker 授权，即可读写。
 */
const BUS_DIR = '/storage/Users/currentUser/Download/HMArkPriv';
const REQ_DIR = `${BUS_DIR}/req`;
const RES_DIR = `${BUS_DIR}/res`;
/** 队列槽位数，与 HMArkPriv 侧 scripts/setup-queue.sh 保持一致 */
const SLOT_COUNT = 16;

/** 命令执行结果 */
export interface HmprivResult {
  success: boolean;
  exitCode: number;
  output: string;
  /** 执行耗时（毫秒） */
  durationMs: number;
  /** 错误信息（仅失败时） */
  error?: string;
}

/** 失败结果构造 */
function fail(msg: string, dur: number = 0): HmprivResult {
  return { success: false, exitCode: -1, output: '', durationMs: dur, error: msg };
}

export class HmprivClient {
  // ==========================================================================
  // 方式 A：Want + startAbilityForResult（会拉起界面）
  // ==========================================================================

  /**
   * 执行一条特权命令（方式 A）。
   *
   * 注意：
   *   - 会拉起 HMArkPriv 的界面（用户会看到一次闪烁）
   *   - HMArkPriv 执行完会 terminateSelfWithResult 回传并退出
   *   - 如果 HMArkPriv 有未保存状态，会被打断（本项目无状态，可放心）
   *
   * @param context 调用方的 UIAbilityContext
   * @param cmd     要执行的 shell 命令
   */
  static async execByWant(
    context: common.UIAbilityContext,
    cmd: string,
  ): Promise<HmprivResult> {
    const start = Date.now();
    const want: Want = {
      bundleName: HMPRIV_BUNDLE,
      abilityName: HMPRIV_ABILITY,
      action: ACTION_EXECUTE,
      parameters: { cmd: cmd },
    };

    try {
      const result = await context.startAbilityForResult(want);
      const dur = Date.now() - start;

      // resultCode: 0=成功 1=命令失败 2=参数错误
      const params = result.want?.parameters;
      if (result.resultCode === 0) {
        return {
          success: true,
          exitCode: (params?.['exitCode'] as number) ?? 0,
          output: (params?.['output'] as string) ?? '',
          durationMs: (params?.['durationMs'] as number) ?? dur,
        };
      }

      const err = (params?.['error'] as string) ?? `resultCode=${result.resultCode}`;
      return {
        success: false,
        exitCode: (params?.['exitCode'] as number) ?? -1,
        output: (params?.['output'] as string) ?? '',
        durationMs: dur,
        error: err,
      };
    } catch (err) {
      const e = err as BusinessError;
      return fail(`startAbilityForResult failed: code=${e.code} msg=${e.message}`, Date.now() - start);
    }
  }

  // ==========================================================================
  // 方式 C+：共享文件队列（完全后台）
  // ==========================================================================

  /** 记录每个槽位的占用情况（同一 App 内避免自己跟自己抢槽） */
  private static slotBusy: boolean[] = new Array<boolean>(SLOT_COUNT).fill(false);

  /**
   * 执行一条特权命令（方式 C+，无界面）。
   *
   * 工作流程：
   *   1. 找一个空闲槽位 N
   *   2. 清空 res/slotN.res（避免读到上次的结果）
   *   3. 把命令写入 req/slotN.req
   *   4. 轮询 res/slotN.res，直到出现 "RC:" 开头的内容
   *   5. 解析并返回
   *
   * @param cmd       要执行的命令
   * @param timeoutMs 超时（默认 25 秒，覆盖 daemon 的 20s+5s 两级超时）
   */
  static async execByQueue(cmd: string, timeoutMs: number = 25000): Promise<HmprivResult> {
    const start = Date.now();

    // 1. 找空闲槽位
    const slot = HmprivClient.acquireSlot();
    if (slot < 0) {
      return fail('所有队列槽位都被占用，请稍后重试或减少并发');
    }

    const reqPath = `${REQ_DIR}/slot${slot}.req`;
    const resPath = `${RES_DIR}/slot${slot}.res`;

    try {
      // 2. 清空上次结果
      try {
        const f = fileIo.openSync(resPath, 0o2 | 0o1000); // READ_WRITE | TRUNC
        fileIo.closeSync(f);
      } catch (err) {
        // 槽位文件不存在 → 说明没跑过 setup-queue.sh
        HmprivClient.releaseSlot(slot);
        return fail(
          `槽位文件不存在：${resPath}\n` +
          `请先在电脑上运行：bash scripts/setup-queue.sh`,
        );
      }

      // 3. 写请求
      try {
        const f = fileIo.openSync(reqPath, 0o2 | 0o1000);
        fileIo.writeSync(f.fd, `${cmd}\n`);
        fileIo.fsyncSync(f.fd);   // 必须 fsync，否则 daemon 可能读到空内容
        fileIo.closeSync(f);
      } catch (err) {
        const e = err as BusinessError;
        HmprivClient.releaseSlot(slot);
        return fail(`写入请求失败：code=${e.code} msg=${e.message}`);
      }

      // 4. 轮询结果
      const deadline = Date.now() + timeoutMs;
      while (Date.now() < deadline) {
        await HmprivClient.sleep(50);
        let text = '';
        try {
          text = fileIo.readTextSync(resPath);
        } catch (err) {
          continue;   // 还没写，继续等
        }
        if (text && text.startsWith('RC:')) {
          // 5. 解析：RC:<code>\nTIME:<ts>\n<output>
          const lines = text.split('\n');
          const rcLine = lines[0] ?? '';
          const rcMatch = rcLine.match(/RC:(-?\d+)/);
          const exitCode = rcMatch ? parseInt(rcMatch[1]) : -1;
          // 第一行 RC、第二行 TIME，之后是输出
          const output = lines.slice(2).join('\n').trim();

          // 清空结果，避免下次误读
          try {
            const f = fileIo.openSync(resPath, 0o2 | 0o1000);
            fileIo.closeSync(f);
          } catch (err) {
            // 忽略
          }

          HmprivClient.releaseSlot(slot);
          return {
            success: exitCode === 0,
            exitCode: exitCode,
            output: output,
            durationMs: Date.now() - start,
          };
        }
      }

      HmprivClient.releaseSlot(slot);
      return fail('等待结果超时（daemon 可能未运行，或命令被 timeout 终止）', Date.now() - start);
    } catch (err) {
      HmprivClient.releaseSlot(slot);
      const e = err as BusinessError;
      return fail(`execByQueue 异常：code=${e.code} msg=${e.message}`, Date.now() - start);
    }
  }

  /** 占用一个槽位，返回索引；无空闲返回 -1 */
  private static acquireSlot(): number {
    for (let i = 0; i < SLOT_COUNT; i++) {
      if (!HmprivClient.slotBusy[i]) {
        HmprivClient.slotBusy[i] = true;
        return i;
      }
    }
    return -1;
  }

  private static releaseSlot(slot: number): void {
    if (slot >= 0 && slot < SLOT_COUNT) {
      HmprivClient.slotBusy[slot] = false;
    }
  }

  private static sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve) => setTimeout(resolve, ms));
  }

  // ==========================================================================
  // 健康检查
  // ==========================================================================

  /**
   * 检查 daemon 是否在运行（方式 C+）。
   * 读取 status.json，看 status 是否为 "ready"。
   */
  static isDaemonReady(): boolean {
    try {
      const text = fileIo.readTextSync(`${BUS_DIR}/status.json`);
      const json = JSON.parse(text) as Record<string, Object>;
      return json['status'] === 'ready';
    } catch (err) {
      return false;
    }
  }

  // ==========================================================================
  // 常用命令便捷封装
  // ==========================================================================

  /** 唤醒屏幕 */
  static wakeup(): Promise<HmprivResult> {
    return HmprivClient.execByQueue('power-shell wakeup');
  }

  /** 点击坐标 */
  static tap(x: number, y: number): Promise<HmprivResult> {
    return HmprivClient.execByQueue(`uinput -T -c ${x} ${y}`);
  }

  /** 滑动 */
  static swipe(x1: number, y1: number, x2: number, y2: number, ms?: number): Promise<HmprivResult> {
    const base = `uinput -T -m ${x1} ${y1} ${x2} ${y2}`;
    return HmprivClient.execByQueue(ms ? `${base} ${ms}` : base);
  }

  /** 按键（Home=1, Back=2, 音量+=16, 音量-=17, 电源=18） */
  static keyPress(keycode: number): Promise<HmprivResult> {
    return HmprivClient.execByQueue(`uinput -K -d ${keycode} -u ${keycode}`);
  }

  /** 强制停止应用 */
  static forceStop(bundle: string): Promise<HmprivResult> {
    return HmprivClient.execByQueue(`aa force-stop ${bundle}`);
  }

  /** 启动应用 */
  static startApp(bundle: string, ability: string): Promise<HmprivResult> {
    return HmprivClient.execByQueue(`aa start -b ${bundle} -a ${ability}`);
  }
}
