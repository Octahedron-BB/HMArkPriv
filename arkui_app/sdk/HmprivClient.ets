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
 * 模式一：弹窗授权模式（Want + startAbilityForResult）
 *   优点：最标准，不需要文件权限，能同步拿到结果，操作透明
 *   缺点：首次调用弹出授权卡片（用户勾选"信任该应用"加入白名单后，后续免确认）
 *   适合：常规应用、低频调用、敏感系统设置变更
 *
 * 模式二：极速总线模式（共享文件队列 + 令牌鉴权）
 *   优点：完全无感，毫秒级响应，不依赖 HMArkPriv App 存活（daemon 独立运行），支持并发
 *   安全性：通过用户在模式一中授权下发的 Token 鉴权，未经授权无法静默执行
 *   适合：高频调用、自动化工具（Tasker/MacroDroid）、后台服务
 *
 * ============================================================================
 */

import { common, Want } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';

/** HMArkPriv 的包名 */
const HMPRIV_BUNDLE = 'com.octahedron.hmpriv';
const HMPRIV_ABILITY = 'EntryAbility';
/** 自定义 action：执行命令 */
const ACTION_EXECUTE = 'hmpriv.execute';
/** 自定义 action：申请极速总线令牌 */
const ACTION_REQUEST_TOKEN = 'hmpriv.request_token';

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
  /** 极速总线模式当前持有的授权令牌 */
  private static authToken: string = '';

  /** 设置极速总线模式的授权令牌 */
  static setAuthToken(token: string): void {
    HmprivClient.authToken = token;
  }

  /** 获取当前持有的令牌 */
  static getAuthToken(): string {
    return HmprivClient.authToken;
  }

  /**
   * 向 HMArkPriv 申请后台「极速总线模式」授权令牌。
   * 会通过弹窗授权模式唤起一次确认卡片，用户点允许后返回专属令牌。
   */
  static async requestFastBusToken(context: common.UIAbilityContext): Promise<string> {
    const want: Want = {
      bundleName: HMPRIV_BUNDLE,
      abilityName: HMPRIV_ABILITY,
      action: ACTION_REQUEST_TOKEN,
    };
    const result = await context.startAbilityForResult(want);
    if (result.resultCode === 0) {
      const token = (result.want?.parameters?.['token'] as string) ?? '';
      if (token) {
        HmprivClient.setAuthToken(token);
        return token;
      }
    }
    const err = (result.want?.parameters?.['error'] as string) ?? `resultCode=${result.resultCode}`;
    throw new Error(`requestFastBusToken failed: ${err}`);
  }

  // ==========================================================================
  // 模式一：弹窗授权模式（Want + startAbilityForResult）
  // ==========================================================================

  /**
   * 执行一条特权命令（模式一：弹窗授权模式）。
   *
   * 注意：
   *   - 外部调用时会唤起确认卡片，用户点允许后执行并回传
   *   - 用户勾选"信任该应用"加入白名单后，后续调用不再弹窗
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
  // 模式二：极速总线模式（共享文件队列 + 令牌鉴权）
  // ==========================================================================

  /** 记录每个槽位的占用情况（同一 App 内避免自己跟自己抢槽） */
  private static slotBusy: boolean[] = new Array<boolean>(SLOT_COUNT).fill(false);

  /**
   * 执行一条特权命令（模式二：极速总线模式，无感异步）。
   *
   * 工作流程：
   *   1. 找一个空闲槽位 N
   *   2. 清空 res/slotN.res（避免读到上次的结果）
   *   3. 组织请求包（若有 token 则首行附加 TOKEN:<key>）并写入 req/slotN.req
   *   4. 轮询 res/slotN.res，直到出现 "RC:" 开头的内容
   *   5. 解析并返回
   *
   * @param cmd       要执行的命令
   * @param timeoutMs 超时（默认 25 秒，覆盖 daemon 的 20s+5s 两级超时）
   * @param token     可选的授权令牌（缺省使用 setAuthToken 设置的值）
   */
  static async execByQueue(
    cmd: string,
    timeoutMs: number = 25000,
    token?: string,
  ): Promise<HmprivResult> {
    const start = Date.now();
    const effectiveToken = token ?? HmprivClient.authToken;

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

      // 3. 写请求（带令牌校验头）
      try {
        const f = fileIo.openSync(reqPath, 0o2 | 0o1000);
        let payload = '';
        if (effectiveToken) {
          payload = `TOKEN:${effectiveToken}\n${cmd}\n`;
        } else {
          payload = `${cmd}\n`;
        }
        fileIo.writeSync(f.fd, payload);
        fileIo.fsyncSync(f.fd); // 必须 fsync，否则 daemon 可能读到空内容
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
