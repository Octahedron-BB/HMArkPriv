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
import { fileIo } from '@kit.CoreFileKit';

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
  /** 这个值来自哪里 */
  source: 'system' | 'app' | 'charging';
  /** 来源的中文说明，直接给界面用 */
  sourceLabel: string;
}

/** 常见的熄屏时间档位（毫秒），用于把数值说得更像系统设置的口径 */
const COMMON_STEPS: number[] = [
  15000, 30000, 60000, 120000, 300000,
  600000, 1800000, 3600000, 6000000,
];

/** override 记录的读取结果 */
interface OverrideRecord {
  rawMs: number;
  source: 'app' | 'charging' | 'system';
}

/** 状态文件名（与 daemon 共用） */
const STATE_FILE = 'screen_state.txt';

export class DisplayReader {
  /**
   * 读取「当前实际生效」的熄屏时间。
   *
   * 【两层来源】
   *   1. 总线目录的 screen_state.txt —— 记录当前是否有 override 及其值
   *      （daemon 的充电常亮、App 手动设置，都会写这个文件）
   *   2. 系统设置的 SCREEN_OFF_TIMEOUT —— 用户设的静态值
   *
   * 优先级：有 override 记录 → 用 override 值；否则用系统设置值。
   * 这样界面显示的就是「现在到底多久熄屏」，而不是一个静态设置。
   *
   * @param context UIAbilityContext
   * @param busDir  总线目录（读 override 记录用），为空则只看系统设置
   */
  static readEffectiveTimeout(
    context: common.UIAbilityContext,
    busDir: string,
  ): ScreenTimeoutInfo {
    // 1. 先看有没有 override 记录
    if (busDir && busDir.length > 0) {
      const ov = DisplayReader.readOverride(busDir);
      if (ov !== null && ov.rawMs > 0 && ov.source !== 'system') {
        return {
          rawMs: ov.rawMs,
          text: DisplayReader.formatMs(ov.rawMs),
          ok: true,
          source: ov.source,
          sourceLabel: ov.source === 'charging' ? '充电常亮（本 App 维持）' : '本 App 临时设置',
        };
      }
    }

    // 2. 没有 override，用系统设置值
    const sys = DisplayReader.readSystemTimeout(context);
    return {
      rawMs: sys.rawMs,
      text: sys.text,
      ok: sys.ok,
      source: 'system',
      sourceLabel: '系统设置',
    };
  }

  /**
   * 读 override 记录。
   * @returns null 表示没有记录或记录显示无 override
   */
  private static readOverride(busDir: string): OverrideRecord | null {
    try {
      const p = `${busDir}/${STATE_FILE}`;
      if (!fileIo.accessSync(p)) {
        return null;
      }
      const text = fileIo.readTextSync(p);
      if (!text || text.length === 0) {
        return null;
      }
      let source = 'system';
      let ms = 0;
      const lines = text.split('\n');
      for (const raw of lines) {
        const line = raw.trim();
        if (line.startsWith('source=')) {
          source = line.substring(7).trim();
        } else if (line.startsWith('timeout=')) {
          ms = parseInt(line.substring(8).trim(), 10);
        }
      }
      if (isNaN(ms)) {
        ms = 0;
      }
      const src = (source === 'charging' || source === 'app') ? source : 'system';
      const rec: OverrideRecord = {
        rawMs: ms,
        source: src as 'app' | 'charging' | 'system',
      };
      return rec;
    } catch (err) {
      return null;
    }
  }

  /**
   * 写入 override 记录（App 手动设置超时后调用）。
   * daemon 也会在充电常亮时写这个文件。
   */
  static writeOverride(busDir: string, source: 'app' | 'system', ms: number): boolean {
    try {
      const p = `${busDir}/${STATE_FILE}`;
      if (!fileIo.accessSync(p)) {
        hilog.warn(DOMAIN, TAG, `${STATE_FILE} missing, cannot record override`);
        return false;
      }
      const content = `source=${source}\ntimeout=${ms}\n`;
      const f = fileIo.openSync(p, 0o2 | 0o1000);
      try {
        fileIo.writeSync(f.fd, content);
        fileIo.fsyncSync(f.fd);
      } finally {
        fileIo.closeSync(f);
      }
      return true;
    } catch (err) {
      const e = err as BusinessError;
      hilog.warn(DOMAIN, TAG, `writeOverride failed: ${e.code}`);
      return false;
    }
  }

  /** 只读系统设置值（原有逻辑） */
  static readSystemTimeout(context: common.UIAbilityContext): ScreenTimeoutInfo {
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
        return { rawMs: -1, text: '读取失败', ok: false, source: 'system', sourceLabel: '系统设置' };
      }
      if (ms === 0) {
        return { rawMs: 0, text: '永不熄屏', ok: true, source: 'system', sourceLabel: '系统设置' };
      }
      return { rawMs: ms, text: DisplayReader.formatMs(ms), ok: true, source: 'system', sourceLabel: '系统设置' };
    } catch (err) {
      const e = err as BusinessError;
      hilog.error(DOMAIN, TAG, `readScreenTimeout failed: code=${e.code} msg=${e.message}`);
      return { rawMs: -1, text: `读取失败（${e.code}）`, ok: false, source: 'system', sourceLabel: '系统设置' };
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
