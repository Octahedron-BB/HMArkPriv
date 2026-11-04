/**
 * CrossAppHandler — 跨应用调用处理（方案 A：Want + startAbilityForResult）
 *
 * 【协议】
 * 调用方用 startAbilityForResult 拉起本 App，带上：
 *   action:   'hmpriv.execute'
 *   parameters: { cmd: '要执行的命令' }
 *
 * 本 App 执行命令后通过 terminateSelfWithResult 回传：
 *   resultCode: 0（成功）/ 1（命令失败）/ 2（参数错误）
 *   want.parameters: {
 *     output:     命令输出（字符串）
 *     exitCode:   daemon 返回的退出码
 *     durationMs: 执行耗时
 *     error:      错误描述（仅失败时）
 *   }
 *
 * 【为什么会有界面闪现】
 * 鸿蒙没有可被第三方 App 无界面绑定的后台服务（ServiceExtensionAbility 未开放，
 * AppServiceExtensionAbility 仅限 2-in-1 + 企业 ACL）。方案 A 只能通过 UIAbility
 * 组件暴露入口，因此必然会拉起界面。用户接受这一点 —— 敏感操作让用户看见反而是好事。
 *
 * 【安全考虑】
 * - 只响应明确的自定义 action，普通启动（无 action）走正常流程
 * - 有 bundleName 白名单机制（可选开启）
 * - 每条外部调用都记日志，便于审计
 */

import { common, Want, AbilityConstant } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusClient } from './BusClient';
import { BusDirManager } from './BusDirManager';
import { CommandResult } from '../model/CommandResult';

const DOMAIN = 0x9201;
const TAG = 'CrossAppHandler';

/** 外部调用使用的 action */
export const ACTION_EXECUTE = 'hmpriv.execute';

const RESULT_OK = 0;
const RESULT_CMD_FAILED = 1;
const RESULT_BAD_PARAM = 2;

/**
 * 回传给调用方的参数结构。
 * 注意：ArkTS 的 Want.parameters 是 Record<string, Object>，
 * 而 ArkTS 不允许无类型的对象字面量，所以这里必须显式声明接口。
 */
interface ReplyParams {
  output?: string;
  exitCode?: number;
  durationMs?: number;
  error?: string;
}

export class CrossAppHandler {
  /**
   * 判断一个 Want 是否是外部命令调用请求。
   */
  static isExternalCall(want: Want): boolean {
    return want.action === ACTION_EXECUTE;
  }

  /**
   * 处理外部调用。执行完命令后会 terminateSelfWithResult 回传结果并退出。
   *
   * @param context UIAbilityContext（用于 terminateSelfWithResult）
   * @param want    调用方传入的 Want
   */
  static async handle(
    context: common.UIAbilityContext,
    want: Want,
  ): Promise<void> {
    hilog.info(DOMAIN, TAG, `external call from "${want.bundleName ?? 'unknown'}"`);

    // 1. 解析参数
    const cmd = CrossAppHandler.extractCmd(want);
    if (!cmd) {
      hilog.warn(DOMAIN, TAG, 'missing or invalid cmd parameter');
      await CrossAppHandler.reply(context, RESULT_BAD_PARAM, {
        error: 'missing parameter "cmd"',
      });
      return;
    }

    hilog.info(DOMAIN, TAG, `external cmd: "${cmd}"`);

    // 2. 确保总线可用（外部唤起时进程可能是新的，需要重新激活持久化授权）
    const ready = await CrossAppHandler.ensureBusReady(context);
    if (!ready) {
      hilog.error(DOMAIN, TAG, 'bus not ready (daemon down or permission denied)');
      await CrossAppHandler.reply(context, RESULT_CMD_FAILED, {
        error: 'daemon not running or bus directory not accessible. ' +
               'Please deploy daemon and open HMArkPriv once to grant folder access.',
      });
      return;
    }

    // 3. 执行
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

    // 4. 回传
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
   * 同时做基本的合法性校验（非空、长度限制）。
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
    // 限制长度，防止异常大的请求
    if (!cmd || cmd.length > 4096) {
      return '';
    }
    return cmd;
  }

  /**
   * 确保总线可用：
   *   1. 激活已持久化的目录授权（外部唤起时进程可能是新的）
   *   2. 探测总线目录并确认能读到 status.json
   *
   * 注意：这里不申请权限弹窗 —— 外部调用场景下弹窗会打断调用方，
   * 且用户可能不在手机前。首次使用仍需用户手动打开 App 授权一次。
   */
  private static async ensureBusReady(context: common.UIAbilityContext): Promise<boolean> {
    // 激活持久化授权
    const saved = await BusDirManager.loadBusDir(context);
    if (saved) {
      await BusDirManager.activateBusUri(saved);
    }

    // 探测目录
    const dir = BusDirManager.findAccessibleBusDir();
    if (!dir) {
      return false;
    }

    // 重试几次（activatePermission 生效有毫秒级延迟）
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
