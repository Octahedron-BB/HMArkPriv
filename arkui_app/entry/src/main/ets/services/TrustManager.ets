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
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { buffer } from '@kit.ArkTS';
import { fileIo } from '@kit.CoreFileKit';
import { APP_BUS_DIR, BUS_FILE_TOKENS, BUS_FILE_AUDIT, BUS_FILE_CONFIG } from '../common/Constants';

const DOMAIN = 0x9201;
const TAG = 'TrustManager';
const PREF_STORE = 'hmpriv_trust';
const KEY_TRUSTED = 'trustedApps';
const KEY_BLOCKED = 'blockedApps';
/** 旧版：存明文令牌 JSON（已废弃，仅用于迁移清理） */
const KEY_TOKENS_LEGACY = 'fastBusTokens';
/** 新版：存 "bundleName:sha256hex,..." 单行纯文本，daemon 直接读该文件比对 */
const KEY_TOKEN_HASHES = 'fastBusTokenHashes';
/**
 * 是否曾经签发过令牌（"1" 表示是）。
 *
 * 这个标记解决一个危险的语义歧义：
 *   - 从没配过令牌   → daemon 不做鉴权（向后兼容老用户）
 *   - 配过但全吊销了 → daemon 必须仍然鉴权，只是此时没人有令牌 = 完全封锁总线
 * 如果只凭"当前令牌列表是否为空"判断，吊销全部令牌反而会把总线变成完全不设防，
 * 与用户的直觉（没有令牌 = 更安全）正好相反。
 */
const KEY_TOKEN_INITED = 'fastBusInited';

/** 一条调用记录（用于页面展示"谁调用过"） */
export interface CallerRecord {
  bundleName: string;
  /** 调用次数 */
  count: number;
  /** 最近一次调用时间戳 */
  lastTime: number;
}

/** 极速总线模式的授权令牌记录（只存哈希，不存明文） */
export interface TokenRecord {
  /** 令牌属于哪个调用方 */
  bundleName: string;
  /** sha256(明文令牌) 的 64 位十六进制，明文签发后即丢弃 */
  hash: string;
  /** 签发时间戳 */
  createdAt: number;
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

  // ===== 极速总线模式：安全令牌（Token）管理 =====
  //
  // 【安全模型】
  //   明文令牌：只在签发那一刻通过 Want result 回传给调用方，之后 App 侧不再保存。
  //   哈希令牌：存进 preferences(KEY_TOKEN_HASHES)，daemon 直接读这个文件比对。
  //
  // 【为什么哈希存 preferences 而不是总线目录】
  //   总线目录（Download/HMArkPriv）里任何能写 slotN.req 的 App 也都能读写
  //   tokens.txt —— 明文或哈希放那里都挡不住主动篡改。
  //   preferences 在 App 沙箱内：App 能写、daemon(uid 2000) 实测能读、
  //   第三方 App 属 app 域读不到 —— 这是唯一同时满足三者的位置。
  //
  // 【存储格式】
  //   一行一个 "bundleName:sha256hex"，逗号分隔，单行无换行。
  //   不用 JSON、不用多行，是为了让 daemon 用一条 sed 就能提取，
  //   也避开 preferences 的 XML 转义（&quot; 之类）和换行带来的解析麻烦。
  //   bundleName 和 hex 都不含 XML 特殊字符，所以这个格式是安全的。

  /** 读取所有已发放的令牌记录（只有哈希） */
  static async getTokens(context: common.UIAbilityContext): Promise<TokenRecord[]> {
    try {
      const store = await preferences.getPreferences(context, PREF_STORE);
      const raw = store.getSync(KEY_TOKEN_HASHES, '') as string;
      return TrustManager.decodeTokenHashes(raw);
    } catch (err) {
      hilog.warn(DOMAIN, TAG, `getTokens failed: ${err}`);
      return [];
    }
  }

  /** "a:hash,b:hash" → TokenRecord[] */
  private static decodeTokenHashes(raw: string): TokenRecord[] {
    const out: TokenRecord[] = [];
    const trimmed = raw.trim();
    if (trimmed.length === 0) {
      return out;
    }
    const parts = trimmed.split(',');
    for (const p of parts) {
      const idx = p.lastIndexOf(':');
      if (idx <= 0) {
        continue;
      }
      const bundleName = p.substring(0, idx).trim();
      const hash = p.substring(idx + 1).trim();
      if (bundleName.length > 0 && hash.length === 64) {
        out.push({ bundleName, hash, createdAt: 0 });
      }
    }
    return out;
  }

  /** TokenRecord[] → "a:hash,b:hash"（单行，供 daemon 解析） */
  private static encodeTokenHashes(list: TokenRecord[]): string {
    return list.map((t: TokenRecord) => `${t.bundleName}:${t.hash}`).join(',');
  }

  /**
   * 为指定 App 生成并签发极速总线令牌。
   *
   * @returns 明文令牌 —— 只返回这一次，App 侧不保存，调用方需自行保管。
   */
  static async generateToken(
    context: common.UIAbilityContext,
    bundleName: string,
  ): Promise<string> {
    const plain = TrustManager.randomToken();
    const hash = await TrustManager.sha256Hex(plain);

    const list = await TrustManager.getTokens(context);
    const idx = list.findIndex((item: TokenRecord) => item.bundleName === bundleName);
    const rec: TokenRecord = { bundleName, hash, createdAt: Date.now() };
    if (idx >= 0) {
      list[idx] = rec;
    } else {
      list.push(rec);
    }

    const store = await preferences.getPreferences(context, PREF_STORE);
    store.putSync(KEY_TOKEN_HASHES, TrustManager.encodeTokenHashes(list));
    // 标记"已启用令牌鉴权"，之后即使吊销到 0 个也不会退回不设防状态
    store.putSync(KEY_TOKEN_INITED, '1');
    await store.flush();

    hilog.info(DOMAIN, TAG, `generated token for ${bundleName} (hash=${hash.substring(0, 8)}...)`);
    return plain;
  }

  /**
   * 是否曾经启用过令牌鉴权（用于界面显示"未设防"还是"已封锁"）。
   *
   * 带懒迁移：老版本签发令牌时不写这个标记，所以如果发现当前有令牌
   * 但标记缺失，就补写一次 —— 否则老用户吊销全部令牌后会退回不设防状态。
   */
  static async isTokenInited(context: common.UIAbilityContext): Promise<boolean> {
    try {
      const store = await preferences.getPreferences(context, PREF_STORE);
      const v = store.getSync(KEY_TOKEN_INITED, '') as string;
      if (v === '1') {
        return true;
      }
      const hashes = store.getSync(KEY_TOKEN_HASHES, '') as string;
      if (hashes.trim().length > 0) {
        store.putSync(KEY_TOKEN_INITED, '1');
        await store.flush();
        hilog.info(DOMAIN, TAG, 'lazy-migrated fastBusInited=1 (legacy tokens detected)');
        return true;
      }
      return false;
    } catch (err) {
      return false;
    }
  }

  /**
   * 完全重置令牌鉴权机制 —— 清空所有令牌与"已启用"标记。
   *
   * 用于用户想彻底放弃令牌机制（回到"不设防"）的场景。
   * 没有这个入口的话，一旦启用过令牌就永远回不去（除非卸载重装），
   * 因为 daemon 会一直认为"配过令牌"而拒绝所有调用。
   */
  static async resetTokenMechanism(context: common.UIAbilityContext): Promise<void> {
    try {
      const store = await preferences.getPreferences(context, PREF_STORE);
      store.deleteSync(KEY_TOKEN_HASHES);
      store.deleteSync(KEY_TOKEN_INITED);
      store.deleteSync(KEY_TOKENS_LEGACY);
      await store.flush();
      hilog.info(DOMAIN, TAG, 'token mechanism reset');
    } catch (err) {
      hilog.warn(DOMAIN, TAG, `resetTokenMechanism failed: ${err}`);
    }
  }

  /** 吊销指定 App 的令牌 */
  static async revokeToken(
    context: common.UIAbilityContext,
    bundleName: string,
  ): Promise<void> {
    const list = await TrustManager.getTokens(context);
    const filtered = list.filter((item: TokenRecord) => item.bundleName !== bundleName);

    const store = await preferences.getPreferences(context, PREF_STORE);
    store.putSync(KEY_TOKEN_HASHES, TrustManager.encodeTokenHashes(filtered));
    await store.flush();

    hilog.info(DOMAIN, TAG, `revoked token for ${bundleName}`);
  }

  /**
   * 生成 32 字节的密码学安全随机令牌，转成 64 位十六进制。
   *
   * 旧实现用 Math.random()，是可预测的 PRNG，不能用于凭据。
   * @ohos.cryptoFramework 的 createRandom 走系统 CSPRNG。
   */
  private static randomToken(): string {
    const gen = cryptoFramework.createRandom();
    const blob = gen.generateRandomSync(32);
    const bytes = blob.data as Uint8Array;
    let hex = '';
    for (let i = 0; i < bytes.length; i++) {
      const b = bytes[i];
      hex += (b < 16 ? '0' : '') + b.toString(16);
    }
    return hex;
  }

  /** 计算字符串的 sha256，返回 64 位小写十六进制 */
  private static async sha256Hex(text: string): Promise<string> {
    const md = cryptoFramework.createMd('SHA256');
    await md.update({ data: new Uint8Array(buffer.from(text, 'utf-8').buffer) });
    const digest = await md.digest();
    const bytes = digest.data as Uint8Array;
    let hex = '';
    for (let i = 0; i < bytes.length; i++) {
      const b = bytes[i];
      hex += (b < 16 ? '0' : '') + b.toString(16);
    }
    return hex;
  }

  /**
   * 一次性迁移：清掉旧版的明文令牌残留。
   *
   * 旧实现把明文令牌同时写到两处：preferences 的 fastBusTokens(JSON)、
   * 以及总线目录的 tokens.txt。升级后这两处都还有效（明文），
   * 而 daemon 已改为只认 preferences 里的哈希，明文留着纯属泄露风险。
   *
   * 由 Index 页在总线就绪后调用一次。幂等：没有残留时什么都不做。
   */
  static async purgeLegacyTokens(
    context: common.UIAbilityContext,
    busDir: string = APP_BUS_DIR,
  ): Promise<void> {
    // 1. 清 preferences 里的旧明文 key
    try {
      const store = await preferences.getPreferences(context, PREF_STORE);
      const legacy = store.getSync(KEY_TOKENS_LEGACY, '') as string;
      if (legacy.length > 0) {
        store.deleteSync(KEY_TOKENS_LEGACY);
        await store.flush();
        hilog.info(DOMAIN, TAG, 'purged legacy plaintext tokens from preferences');
      }
    } catch (err) {
      hilog.warn(DOMAIN, TAG, `purge legacy prefs failed: ${err}`);
    }

    // 2. 清空总线目录的 tokens.txt（App 有写权限，不需要 create）
    const path = `${busDir}/${BUS_FILE_TOKENS}`;
    try {
      if (fileIo.accessSync(path)) {
        const f = fileIo.openSync(path, 0o2 | 0o1000);  // READ_WRITE | TRUNC
        fileIo.writeSync(f.fd, '');
        fileIo.fsyncSync(f.fd);
        fileIo.closeSync(f);
        hilog.info(DOMAIN, TAG, 'cleared legacy tokens.txt in bus dir');
      }
    } catch (err) {
      hilog.warn(DOMAIN, TAG, `clear tokens.txt failed: ${err}`);
    }
  }

  // ===== 极速总线模式：总开关与审计日志 =====

  /** 检查极速总线模式是否开启 */
  static isQueueEnabled(busDir: string = APP_BUS_DIR): boolean {
    const path = `${busDir}/${BUS_FILE_CONFIG}`;
    try {
      if (fileIo.accessSync(path)) {
        const text = fileIo.readTextSync(path);
        const cfg = JSON.parse(text) as Record<string, Object>;
        return cfg['queueEnabled'] !== false;
      }
    } catch (err) {
      // 默认开启
    }
    return true;
  }

  /** 设置极速总线模式开关 */
  static setQueueEnabled(enabled: boolean, busDir: string = APP_BUS_DIR): void {
    const path = `${busDir}/${BUS_FILE_CONFIG}`;
    try {
      let cfg: Record<string, Object> = {};
      if (fileIo.accessSync(path)) {
        try {
          cfg = JSON.parse(fileIo.readTextSync(path)) as Record<string, Object>;
        } catch (_) {}
      }
      cfg['queueEnabled'] = enabled;
      const json = JSON.stringify(cfg);
      const f = fileIo.openSync(path, 0o2 | 0o1000);
      fileIo.writeSync(f.fd, json);
      fileIo.fsyncSync(f.fd);
      fileIo.closeSync(f);
      hilog.info(DOMAIN, TAG, `setQueueEnabled: ${enabled}`);
    } catch (err) {
      hilog.warn(DOMAIN, TAG, `setQueueEnabled failed: ${err}`);
    }
  }

  /** 读取充电防熄屏开关（默认关闭 —— 用户不主动开就不该常亮） */
  static isStayAwakeWhileCharging(busDir: string = APP_BUS_DIR): boolean {
    const path = `${busDir}/${BUS_FILE_CONFIG}`;
    try {
      if (fileIo.accessSync(path)) {
        const text = fileIo.readTextSync(path);
        const cfg = JSON.parse(text) as Record<string, Object>;
        return cfg['stayAwakeWhileCharging'] === true;
      }
    } catch (err) {
      // 默认关闭
    }
    return false;
  }

  /** 设置充电防熄屏开关 */
  static setStayAwakeWhileCharging(enabled: boolean, busDir: string = APP_BUS_DIR): void {
    TrustManager.patchConfig({ 'stayAwakeWhileCharging': enabled }, busDir);
  }

  /**
   * 上报当前充电状态与心跳时间戳。
   *
   * daemon 是 shell 脚本，拿不到 @ohos.batteryInfo，只能用 hilog，
   * 而实测 hilog 里根本没有 pluggedType 字段（恒为空）。
   * 所以充电状态必须由 App 写入 config.json，daemon 只读不算。
   *
   * heartbeat 用于让 daemon 判断 App 是否还活着：超过 60 秒没更新
   * 就不再维持常亮，避免 App 被杀后状态卡死成"一直亮"。
   */
  static reportCharging(charging: boolean, busDir: string = APP_BUS_DIR): void {
    TrustManager.patchConfig({
      'charging': charging,
      'heartbeat': Math.floor(Date.now() / 1000),
    }, busDir);
  }

  /** 合并写 config.json（保留其它键），读-改-写 带 fsync */
  private static patchConfig(patch: Record<string, Object>, busDir: string = APP_BUS_DIR): void {
    const path = `${busDir}/${BUS_FILE_CONFIG}`;
    try {
      let cfg: Record<string, Object> = {};
      if (fileIo.accessSync(path)) {
        try {
          const text = fileIo.readTextSync(path);
          if (text.trim().length > 0) {
            cfg = JSON.parse(text) as Record<string, Object>;
          }
        } catch (_) {
          // 文件损坏就重建
        }
      }
      const keys = Object.keys(patch);
      for (const k of keys) {
        cfg[k] = patch[k];
      }
      const f = fileIo.openSync(path, 0o2 | 0o1000);
      try {
        fileIo.writeSync(f.fd, JSON.stringify(cfg));
        fileIo.fsyncSync(f.fd);
      } finally {
        fileIo.closeSync(f);
      }
    } catch (err) {
      hilog.warn(DOMAIN, TAG, `patchConfig failed: ${err}`);
    }
  }

  /** 读取极速总线审计日志（倒序，最新在前） */
  static getAuditLog(busDir: string = APP_BUS_DIR): string[] {
    const path = `${busDir}/${BUS_FILE_AUDIT}`;
    try {
      if (fileIo.accessSync(path)) {
        const text = fileIo.readTextSync(path);
        if (!text.trim()) {
          return [];
        }
        const lines = text.trim().split('\n');
        lines.reverse();
        return lines.slice(0, 100);
      }
    } catch (err) {
      // 忽略读取失败
    }
    return [];
  }

  /** 清空审计日志 */
  static clearAuditLog(busDir: string = APP_BUS_DIR): void {
    const path = `${busDir}/${BUS_FILE_AUDIT}`;
    try {
      const f = fileIo.openSync(path, 0o2 | 0o1000);
      fileIo.closeSync(f);
      hilog.info(DOMAIN, TAG, 'cleared audit.log');
    } catch (err) {
      hilog.warn(DOMAIN, TAG, `clearAuditLog failed: ${err}`);
    }
  }
}
