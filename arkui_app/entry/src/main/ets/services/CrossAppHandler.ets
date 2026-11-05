/**
 * CrossAppHandler — 跨应用调用处理（方案 A：Want，带用户确认）
 *
 * 【设计原则】
 * 外部 App 通过 Want 调用时，**不自动执行**，而是：
 *   1. 把 App 拉到前台，展示一张确认卡片
 *   2. 卡片显示：谁在调用（bundleName）、要执行什么命令、可能的影响
 *   3. 用户点「允许执行」→ 执行并回传结果
 *   4. 用户点「拒绝」或按返回 → 回传拒绝，不执行
 *
 * 【为什么改成确认模式】
 * 最初的实现是自动执行完 terminateSelfWithResult，界面只闪一下。
 * 但这条通道等价于 UID 2000 shell 权限（能读其他 App 数据、模拟输入、改系统设置），
 * 自动执行等于让调用方静默获得特权。改成确认模式后：
 *   - 用户每次都能看到具体命令
 *   - 用户可以拒绝
 *   - 敏感操作必须经过人的判断
 *
 * 代价是每次调用都要用户点一次。对于高频自动化场景，建议用方案 C+（队列），
 * 并配合白名单让信任的 App 免确认。
 *
 * 【与白名单的关系】
 * 如果调用方 bundleName 在用户的白名单里，则跳过确认直接执行（方案 C+ 的体验）。
 * 不在白名单 → 展示确认卡片。白名单可在 App 的「跨应用调用」页面管理。
 */

import { common, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusClient } from './BusClient';
import { BusDirManager } from './BusDirManager';
import { TrustManager } from './TrustManager';
import { CommandResult } from '../model/CommandResult';

const DOMAIN = 0x9201;
const TAG = 'CrossAppHandler';

/** 外部调用使用的 action */
export const ACTION_EXECUTE = 'hmpriv.execute';
/** 外部调用申请极速总线令牌使用的 action */
export const ACTION_REQUEST_TOKEN = 'hmpriv.request_token';

/** resultCode 常量 */
export const RESULT_OK = 0;
export const RESULT_CMD_FAILED = 1;
export const RESULT_BAD_PARAM = 2;
export const RESULT_DENIED = 3;
export const RESULT_NEED_CONFIRM = 4;

/**
 * 回传给调用方的参数结构。
 * ArkTS 不允许无类型对象字面量，必须显式声明。
 */
export interface ReplyParams {
  output?: string;
  exitCode?: number;
  durationMs?: number;
  error?: string;
  token?: string;
}

/**
 * 待确认的调用请求。
 * EntryAbility 收到外部调用时构造它，交给 Index 页面渲染确认卡片。
 */
export interface PendingCall {
  /** 调用方 bundleName */
  caller: string;
  /** 请求执行的命令或授权描述 */
  cmd: string;
  /** 是否已在白名单（true 则不需要确认） */
  trusted: boolean;
  /** 时间戳 */
  time: number;
  /** 是否为极速总线令牌申请 */
  isTokenRequest?: boolean;
}

export class CrossAppHandler {
  /** 当前待确认的请求（同一时刻只处理一个） */
  private static pending: PendingCall | null = null;
  /** 待确认请求的 Want（用于回传） */
  private static pendingWant: Want | null = null;
  /**
   * 待确认请求所属的 UIAbilityContext。
   * 【必须保存 EntryAbility 传进来的 this.context】
   * terminateSelfWithResult 必须用拉起这个 Ability 的同一 context，
   * 页面里的 getContext() 拿到的不一定是同一个实例，会导致回传失败。
   */
  private static pendingContext: common.UIAbilityContext | null = null;
  /** 确认卡片变化时的回调（由 Index 页面注册，用于触发 UI 刷新） */
  private static listener: (() => void) | null = null;

  /** 注册 UI 刷新回调 */
  static setListener(fn: () => void): void {
    CrossAppHandler.listener = fn;
  }

  /** 取出当前待确认请求（Index 页面读取） */
  static getPending(): PendingCall | null {
    return CrossAppHandler.pending;
  }

  /**
   * 判断一个 Want 是否是外部命令调用请求或令牌申请。
   */
  static isExternalCall(want: Want): boolean {
    return want.action === ACTION_EXECUTE || want.action === ACTION_REQUEST_TOKEN;
  }

  /**
   * 处理外部调用。
   *
   * 白名单内的调用方 → 直接执行并回传（不打扰用户）
   * 白名单外 → 设置 pending，等用户在界面上确认/拒绝
   */
  static async handle(
    context: common.UIAbilityContext,
    want: Want,
  ): Promise<void> {
    const caller = want.bundleName ?? 'unknown';
    hilog.info(DOMAIN, TAG, `external call (${want.action}) from "${caller}"`);

    // 检查黑名单
    const isBlocked = await TrustManager.isBlocked(context, caller);
    if (isBlocked) {
      hilog.warn(DOMAIN, TAG, `blocked caller: "${caller}"`);
      await CrossAppHandler.reply(context, RESULT_DENIED, {
        error: 'caller is in blacklist',
      });
      return;
    }

    // 记录调用（供用户在「开放接口」页审计）
    await TrustManager.recordCall(context, caller);

    // 1. 申请极速总线令牌请求
    if (want.action === ACTION_REQUEST_TOKEN) {
      const trusted = await TrustManager.isTrusted(context, caller);
      if (trusted) {
        // 明文令牌只经 Want result 回传，App 侧只留哈希
        const token = await TrustManager.generateToken(context, caller);
        await CrossAppHandler.reply(context, RESULT_OK, { token: token });
        return;
      }

      // 未在白名单，挂起等待用户授权极速总线
      CrossAppHandler.pending = {
        caller: caller,
        cmd: '申请后台「极速总线模式」授权令牌',
        trusted: false,
        time: Date.now(),
        isTokenRequest: true,
      };
      CrossAppHandler.pendingWant = want;
      CrossAppHandler.pendingContext = context;
      if (CrossAppHandler.listener) {
        CrossAppHandler.listener();
      }
      return;
    }

    // 2. 弹窗授权模式：执行命令请求
    const cmd = CrossAppHandler.extractCmd(want);
    if (!cmd) {
      hilog.warn(DOMAIN, TAG, 'missing or invalid cmd parameter');
      await CrossAppHandler.reply(context, RESULT_BAD_PARAM, {
        error: 'missing parameter "cmd"',
      });
      return;
    }

    hilog.info(DOMAIN, TAG, `cmd: "${cmd}"`);

    // 查白名单
    const trusted = await TrustManager.isTrusted(context, caller);
    hilog.info(DOMAIN, TAG, `caller trusted: ${trusted}`);

    if (trusted) {
      // 白名单内：直接执行
      await CrossAppHandler.executeAndReply(context, cmd);
      return;
    }

    // 白名单外：挂起等用户确认
    CrossAppHandler.pending = {
      caller: caller,
      cmd: cmd,
      trusted: false,
      time: Date.now(),
      isTokenRequest: false,
    };
    CrossAppHandler.pendingWant = want;
    CrossAppHandler.pendingContext = context;

    // 通知 UI 显示确认卡片
    if (CrossAppHandler.listener) {
      CrossAppHandler.listener();
    }
    hilog.info(DOMAIN, TAG, 'waiting for user confirmation');
  }

  /**
   * 用户点了「允许」→ 执行或签发令牌。
   */
  static async approve(): Promise<void> {
    const p = CrossAppHandler.pending;
    const ctx = CrossAppHandler.pendingContext;
    if (!p || !ctx) {
      hilog.warn(DOMAIN, TAG, 'approve called but no pending call');
      return;
    }
    hilog.info(DOMAIN, TAG, `user approved: ${p.cmd} (tokenReq=${p.isTokenRequest})`);
    CrossAppHandler.pending = null;
    CrossAppHandler.pendingWant = null;
    CrossAppHandler.pendingContext = null;
    if (CrossAppHandler.listener) {
      CrossAppHandler.listener();
    }

    if (p.isTokenRequest) {
      const token = await TrustManager.generateToken(ctx, p.caller);
      await CrossAppHandler.reply(ctx, RESULT_OK, { token: token });
    } else {
      await CrossAppHandler.executeAndReply(ctx, p.cmd);
    }
  }

  /**
   * 用户点了「拒绝」→ 回传拒绝，不执行。
   */
  static async deny(remember: boolean = false): Promise<void> {
    const p = CrossAppHandler.pending;
    const ctx = CrossAppHandler.pendingContext;
    if (!p || !ctx) {
      return;
    }
    hilog.info(DOMAIN, TAG, `user denied: ${p.cmd} (remember=${remember})`);

    if (remember) {
      await TrustManager.addBlocked(ctx, p.caller);
    }

    CrossAppHandler.pending = null;
    CrossAppHandler.pendingWant = null;
    CrossAppHandler.pendingContext = null;
    if (CrossAppHandler.listener) {
      CrossAppHandler.listener();
    }

    await CrossAppHandler.reply(ctx, RESULT_DENIED, {
      error: 'user denied the request',
    });
  }

  /**
   * 实际执行命令并回传结果。
   */
  private static async executeAndReply(
    context: common.UIAbilityContext,
    cmd: string,
  ): Promise<void> {
    // 确保总线可用
    const ready = await CrossAppHandler.ensureBusReady(context);
    if (!ready) {
      hilog.error(DOMAIN, TAG, 'bus not ready');
      await CrossAppHandler.reply(context, RESULT_CMD_FAILED, {
        error: 'daemon not running or bus directory not accessible. ' +
               'Please deploy daemon and open HMArkPriv once to grant folder access.',
      });
      return;
    }

    const busDir = BusDirManager.findAccessibleBusDir();
    const client = new BusClient(busDir);
    let result: CommandResult;
    try {
      result = await client.execute(cmd);
    } catch (err) {
      hilog.error(DOMAIN, TAG, `execute failed: ${err}`);
      await CrossAppHandler.reply(context, RESULT_CMD_FAILED, {
        error: `execute failed: ${err}`,
      });
      return;
    }

    hilog.info(DOMAIN, TAG,
      `done: rc=${result.exitCode} dur=${result.durationMs}ms outLen=${result.output.length}`);
    await CrossAppHandler.reply(
      context,
      result.success ? RESULT_OK : RESULT_CMD_FAILED,
      {
        output: result.output,
        exitCode: result.exitCode,
        durationMs: result.durationMs,
      },
    );
  }

  /**
   * 从 Want.parameters 里取出命令行。
   */
  private static extractCmd(want: Want): string {
    if (!want.parameters) {
      return '';
    }
    const raw = want.parameters['cmd'];
    if (typeof raw !== 'string') {
      return '';
    }
    const cmd = raw.trim();
    if (!cmd || cmd.length > 4096) {
      return '';
    }
    return cmd;
  }

  /**
   * 确保总线可用：激活持久化授权 + 探测目录。
   */
  private static async ensureBusReady(context: common.UIAbilityContext): Promise<boolean> {
    const saved = await BusDirManager.loadBusDir(context);
    if (saved) {
      await BusDirManager.activateBusUri(saved);
    }

    const dir = BusDirManager.findAccessibleBusDir();
    if (!dir) {
      return false;
    }

    for (let i = 0; i < 5; i++) {
      if (BusDirManager.canReadBus(dir)) {
        return true;
      }
      await new Promise<void>((r) => setTimeout(r, 100));
    }
    return false;
  }

  /**
   * 回传结果并结束自身。
   */
  private static async reply(
    context: common.UIAbilityContext,
    resultCode: number,
    params: ReplyParams,
  ): Promise<void> {
    try {
      const parameters: Record<string, Object> = {};
      if (params.output !== undefined) {
        parameters['output'] = params.output;
      }
      if (params.exitCode !== undefined) {
        parameters['exitCode'] = params.exitCode;
      }
      if (params.durationMs !== undefined) {
        parameters['durationMs'] = params.durationMs;
      }
      if (params.error !== undefined) {
        parameters['error'] = params.error;
      }
      if (params.token !== undefined) {
        parameters['token'] = params.token;
      }
      await context.terminateSelfWithResult({
        resultCode: resultCode,
        want: { parameters: parameters },
      });
      hilog.info(DOMAIN, TAG, `replied rc=${resultCode} and terminated`);
    } catch (err) {
      hilog.error(DOMAIN, TAG, `terminateSelfWithResult failed: ${err}`);
    }
  }
}
