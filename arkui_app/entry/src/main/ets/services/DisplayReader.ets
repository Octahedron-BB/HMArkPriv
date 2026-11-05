/**
 * DisplayReader — 读取系统屏幕相关设置
 *
 * 【为什么需要它】
 * 「系统」Tab 里原来有个「立即唤醒」按钮，但锁屏状态下用户根本点不到它，
 * 实际没用。改成显示当前熄屏时间设定，让用户知道系统当前是什么状态。
 *
 * 【数据来源】@ohos.settings.display.SCREEN_OFF_TIMEOUT
 * 这是系统设置的「休眠」项，单位毫秒。读取不需要特殊权限。
 *
 * 【重要：这只是「用户设定值」，不是「当前实际生效值」】
 * 实测发现 power-shell timeout -o 设置的 override 是独立的另一层，
 * 不会写回这个设置值：
 *   - shell 设 override 150000 后，系统设置页面仍显示「1 分钟后」
 *   - power-shell timeout -r 的返回值能反映 override 是否存在
 * 所以本类读到的是「设置里的值」，生效值可能被 override 覆盖。
 * 界面上必须如实区分这两者，不能让用户误以为读到的是实际生效值。
 */

import { settings } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';

const DOMAIN = 0x9201;
const TAG = 'DisplayReader';

/** 熄屏时间读取结果 */
export interface ScreenTimeoutInfo {
  /** 原始毫秒值，-1 表示读取失败 */
  rawMs: number;
  /** 人类可读描述，如「1 分钟」 */
  text: string;
  /** 是否读取成功 */
  ok: boolean;
}

/** 常见的熄屏时间档位（毫秒），用于把数值说得更像系统设置的口径 */
const COMMON_STEPS: number[] = [
  15000, 30000, 60000, 120000, 300000,
  600000, 1800000, 3600000, 6000000,
];

export class DisplayReader {
  /**
   * 读取系统设置的熄屏时间。
   *
   * @param context UIAbilityContext
   */
  static readScreenTimeout(context: common.UIAbilityContext): ScreenTimeoutInfo {
    try {
      // 默认值给 '-1' 以便区分「读到 0」和「读失败」
      // 注意：getValueSync 在 settings 顶层，不在 settings.display 下；
      // SCREEN_OFF_TIMEOUT 这个 key 常量才属于 display 命名空间。
      const v: string = settings.getValueSync(
        context,
        settings.display.SCREEN_OFF_TIMEOUT,
        '-1'
      );
      const ms = parseInt(v, 10);
      if (isNaN(ms) || ms < 0) {
        hilog.warn(DOMAIN, TAG, `readScreenTimeout got invalid value: "${v}"`);
        return { rawMs: -1, text: '读取失败', ok: false };
      }
      if (ms === 0) {
        // 部分 ROM 用 0 或超大值表示「永不」
        return { rawMs: 0, text: '永不熄屏', ok: true };
      }
      return { rawMs: ms, text: DisplayReader.formatMs(ms), ok: true };
    } catch (err) {
      const e = err as BusinessError;
      hilog.error(DOMAIN, TAG, `readScreenTimeout failed: code=${e.code} msg=${e.message}`);
      return { rawMs: -1, text: `读取失败（${e.code}）`, ok: false };
    }
  }

  /**
   * 毫秒 → 人类可读。
   *
   * 换算规则尽量贴近系统设置的口径：
   *   60000  → 1 分钟
   *   150000 → 2 分 30 秒
   *   3600000→ 1 小时
   * 不能整除时保留秒，避免把 2 分 30 秒显示成「2 分钟」而误导用户。
   */
  static formatMs(ms: number): string {
    if (ms <= 0) {
      return '永不熄屏';
    }
    const totalSec = Math.round(ms / 1000);
    const h = Math.floor(totalSec / 3600);
    const m = Math.floor((totalSec % 3600) / 60);
    const s = totalSec % 60;

    const parts: string[] = [];
    if (h > 0) {
      parts.push(`${h} 小时`);
    }
    if (m > 0) {
      parts.push(`${m} 分`);
    }
    if (s > 0) {
      parts.push(`${s} 秒`);
    }
    if (parts.length === 0) {
      return `${totalSec} 秒`;
    }
    return parts.join(' ');
  }

  /** 该值是否正好是系统常见档位之一（用于提示「这是标准档位」） */
  static isCommonStep(ms: number): boolean {
    return COMMON_STEPS.indexOf(ms) >= 0;
  }
}
