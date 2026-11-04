/**
 * TrustManager — 跨应用调用的白名单 / 黑名单管理
 *
 * 【为什么要白名单】
 * 跨应用调用通道等价于 UID 2000 shell 权限：能读其他 App 数据、模拟输入、
 * 强制停止应用、改系统设置。不加控制意味着任何 App 都能静默获得这些能力。
 *
 * 【三种状态】
 *   - 白名单（trusted）：用户明确授权，调用时**免确认**直接执行
 *   - 黑名单（blocked）：用户明确拒绝过且勾了"不再询问"，调用直接回 RESULT_DENIED
 *   - 未记录：每次调用都弹确认卡片，由用户决定
 *
 * 【存储】
 * 用 preferences 持久化（app 卸载才会清）。键：
 *   trusted  → string[]  bundleName 列表
 *   blocked  → string[]  bundleName 列表
 */

import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN = 0x9201;
const TAG = 'TrustManager';
const PREF_STORE = 'hmpriv_trust';
const KEY_TRUSTED = 'trustedApps';
const KEY_BLOCKED = 'blockedApps';

/** 一条调用记录（用于页面展示"谁调用过"） */
export interface CallerRecord {
  bundleName: string;
  /** 调用次数 */
  count: number;
  /** 最近一次调用时间戳 */
  lastTime: number;
}

export class TrustManager {
  // ===== 白名单 =====

  /** 读取白名单 */
  static async getTrusted(context: common.UIAbilityContext): Promise<string[]> {
    try {
      const store = await preferences.getPreferences(context, PREF_STORE);
      const raw = store.getSync(KEY_TRUSTED, '[]') as string;
      return JSON.parse(raw) as string[];
    } catch (err) {
      hilog.warn(DOMAIN, TAG, `getTrusted failed: ${err}`);
      return [];
    }
  }

  /** 判断某 App 是否在白名单 */
  static async isTrusted(context: common.UIAbilityContext, bundleName: string): Promise<boolean> {
    const list = await TrustManager.getTrusted(context);
    return list.indexOf(bundleName) >= 0;
  }

  /** 加入白名单（同时从黑名单移除） */
  static async addTrusted(context: common.UIAbilityContext, bundleName: string): Promise<void> {
    try {
      const store = await preferences.getPreferences(context, PREF_STORE);
      const list = await TrustManager.getTrusted(context);
      if (list.indexOf(bundleName) < 0) {
        list.push(bundleName);
        store.putSync(KEY_TRUSTED, JSON.stringify(list));
      }
      // 从黑名单移除
      const blocked = await TrustManager.getBlocked(context);
      const idx = blocked.indexOf(bundleName);
      if (idx >= 0) {
        blocked.splice(idx, 1);
        store.putSync(KEY_BLOCKED, JSON.stringify(blocked));
      }
      await store.flush();
      hilog.info(DOMAIN, TAG, `added to trusted: ${bundleName}`);
    } catch (err) {
      hilog.error(DOMAIN, TAG, `addTrusted failed: ${err}`);
    }
  }

  /** 从白名单移除 */
  static async removeTrusted(context: common.UIAbilityContext, bundleName: string): Promise<void> {
    try {
      const store = await preferences.getPreferences(context, PREF_STORE);
      const list = await TrustManager.getTrusted(context);
      const idx = list.indexOf(bundleName);
      if (idx >= 0) {
        list.splice(idx, 1);
        store.putSync(KEY_TRUSTED, JSON.stringify(list));
        await store.flush();
        hilog.info(DOMAIN, TAG, `removed from trusted: ${bundleName}`);
      }
    } catch (err) {
      hilog.error(DOMAIN, TAG, `removeTrusted failed: ${err}`);
    }
  }

  // ===== 黑名单 =====

  static async getBlocked(context: common.UIAbilityContext): Promise<string[]> {
    try {
      const store = await preferences.getPreferences(context, PREF_STORE);
      const raw = store.getSync(KEY_BLOCKED, '[]') as string;
      return JSON.parse(raw) as string[];
    } catch (err) {
      return [];
    }
  }

  static async isBlocked(context: common.UIAbilityContext, bundleName: string): Promise<boolean> {
    const list = await TrustManager.getBlocked(context);
    return list.indexOf(bundleName) >= 0;
  }

  static async addBlocked(context: common.UIAbilityContext, bundleName: string): Promise<void> {
    try {
      const store = await preferences.getPreferences(context, PREF_STORE);
      const list = await TrustManager.getBlocked(context);
      if (list.indexOf(bundleName) < 0) {
        list.push(bundleName);
        store.putSync(KEY_BLOCKED, JSON.stringify(list));
      }
      // 从白名单移除
      const trusted = await TrustManager.getTrusted(context);
      const idx = trusted.indexOf(bundleName);
      if (idx >= 0) {
        trusted.splice(idx, 1);
        store.putSync(KEY_TRUSTED, JSON.stringify(trusted));
      }
      await store.flush();
      hilog.info(DOMAIN, TAG, `added to blocked: ${bundleName}`);
    } catch (err) {
      hilog.error(DOMAIN, TAG, `addBlocked failed: ${err}`);
    }
  }

  static async removeBlocked(context: common.UIAbilityContext, bundleName: string): Promise<void> {
    try {
      const store = await preferences.getPreferences(context, PREF_STORE);
      const list = await TrustManager.getBlocked(context);
      const idx = list.indexOf(bundleName);
      if (idx >= 0) {
        list.splice(idx, 1);
        store.putSync(KEY_BLOCKED, JSON.stringify(list));
        await store.flush();
      }
    } catch (err) {
      hilog.error(DOMAIN, TAG, `removeBlocked failed: ${err}`);
    }
  }

  // ===== 调用记录（便于用户审计） =====

  /**
   * 记录一次调用。
   * 存成 { bundleName: count } 的简单映射，外加最近时间。
   */
  static async recordCall(context: common.UIAbilityContext, bundleName: string): Promise<void> {
    try {
      const store = await preferences.getPreferences(context, PREF_STORE);
      const raw = store.getSync('callLog', '{}') as string;
      const log = JSON.parse(raw) as Record<string, number[]>;

      const entry = log[bundleName] ?? [0, 0];
      entry[0] = (entry[0] ?? 0) + 1;      // count
      entry[1] = Date.now();                // lastTime
      log[bundleName] = entry;

      store.putSync('callLog', JSON.stringify(log));
      await store.flush();
    } catch (err) {
      hilog.warn(DOMAIN, TAG, `recordCall failed: ${err}`);
    }
  }

  /** 读取调用记录，按最近调用时间倒序 */
  static async getCallLog(context: common.UIAbilityContext): Promise<CallerRecord[]> {
    try {
      const store = await preferences.getPreferences(context, PREF_STORE);
      const raw = store.getSync('callLog', '{}') as string;
      const log = JSON.parse(raw) as Record<string, number[]>;

      const out: CallerRecord[] = [];
      const keys = Object.keys(log);
      for (const k of keys) {
        const v = log[k];
        out.push({ bundleName: k, count: v[0] ?? 0, lastTime: v[1] ?? 0 });
      }
      out.sort((a, b) => b.lastTime - a.lastTime);
      return out;
    } catch (err) {
      return [];
    }
  }

  /** 清空调用记录 */
  static async clearCallLog(context: common.UIAbilityContext): Promise<void> {
    try {
      const store = await preferences.getPreferences(context, PREF_STORE);
      store.putSync('callLog', '{}');
      await store.flush();
    } catch (err) {
      hilog.warn(DOMAIN, TAG, `clearCallLog failed: ${err}`);
    }
  }
}
