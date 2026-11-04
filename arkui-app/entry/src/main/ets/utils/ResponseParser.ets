/**
 * ResponseParser — 输出解析器
 *
 * 将 shell 命令的文本输出解析为结构化数据。
 * 解析失败时返回空/ null，不抛异常。
 *
 * 【实测格式备忘（2026-11-04 模拟器验证）】
 *
 * bm dump -a 的真实输出（注意是 TAB 开头 + 包名，且行尾是 CRLF）：
 *   ID: 100:
 *   \tcom.huawei.emulatormultiscreen
 *   \tcom.huawei.hmos.arkwebcore
 *   ...
 *   所以不能用 "bundleName:" 匹配，要按"行首 TAB + 合法包名"识别。
 *
 * bm clean -c 输出：clean bundle cache files successfully.
 *
 * aa dump -l 格式（注意是 "bundle name [xxx]" 空格分隔，不是 bundleName）：
 *   Mission ID #29  mission name #[#com.x:entry:EntryAbility]
 *     bundle name [com.octahedron.hmpriv]
 *     state #FOREGROUND
 *   ⚠️ 但该命令输出无法被管道/重定向捕获，daemon 拿不到，见 parseForegroundFromLayout。
 *
 * param get 输出（每个键值带尾部空格，行尾 CRLF）：
 *   const.product.model = emulator
 */

export interface AppInfo {
  bundleName: string;
  abilityName?: string;
  installedPath?: string;
}

export interface BatteryInfo {
  level: number;        // 电量 %，-1 表示未知
  charging: boolean;
  temperature: number;  // °C，-1 表示未知
  voltage: number;      // V，-1 表示未知
}

/** 合法包名：至少一个点分隔的段，只含字母数字下划线 */
const BUNDLE_RE = /^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+$/;

export class ResponseParser {
  /** 去掉行尾 CR（鸿蒙命令输出多为 CRLF） */
  static stripCr(s: string): string {
    return s.replace(/\r$/, '');
  }

  /** 按行切分并清理 CR/LF */
  static splitLines(raw: string): string[] {
    return raw.split('\n').map((l) => ResponseParser.stripCr(l));
  }

  /**
   * 解析 bm dump -a 输出，提取应用列表。
   *
   * 实测格式：
   *   ID: 100:
   *   \tcom.huawei.emulatormultiscreen
   *   \tcom.huawei.hmos.arkwebcore
   *
   * 兼容处理：
   *   - 去掉行首 TAB / 空格
   *   - 跳过 "ID: xxx:" 这类分组头
   *   - 用包名正则校验，避免把杂项当包名
   */
  static parseAppList(raw: string): AppInfo[] {
    const apps: AppInfo[] = [];
    const seen = new Set<string>();

    for (const line of ResponseParser.splitLines(raw)) {
      const trimmed = line.trim();
      if (!trimmed) {
        continue;
      }
      // 跳过分组头 "ID: 100:"
      if (/^ID:\s*\d+:?$/.test(trimmed)) {
        continue;
      }
      // 去掉可能的 "bundleName: xxx" 前缀（某些版本会带）
      let candidate = trimmed;
      const prefixMatch = trimmed.match(/^bundleName[:\s]+(.+)$/);
      if (prefixMatch) {
        candidate = prefixMatch[1].trim();
      }
      if (BUNDLE_RE.test(candidate) && !seen.has(candidate)) {
        seen.add(candidate);
        apps.push({ bundleName: candidate });
      }
    }
    return apps;
  }

  /**
   * 从 bm dump -n <bundle> 的输出判断应用是否已安装。
   * 未安装时输出通常包含 "error" / "not found" / 为空。
   */
  static isAppInstalled(raw: string, bundle: string): boolean {
    if (!raw || raw.trim().length === 0) {
      return false;
    }
    const lower = raw.toLowerCase();
    if (lower.includes('not found') || lower.includes('not exist') ||
        lower.includes('error:') || lower.includes('fail')) {
      return false;
    }
    return raw.includes(bundle);
  }

  /**
   * 解析 aa dump -l 输出获取前台应用。
   *
   * ⚠️ 保留此方法仅用于「能拿到文本」的场景（如通过其他手段落盘）。
   * 实测 `aa dump -l` 的输出无法被 shell 管道/重定向捕获，
   * daemon 的 OUT=$(...) 拿不到内容，因此主用方案是
   * parseForegroundFromLayout()（读 uitest dumpLayout 的 JSON）。
   *
   * 实测格式：bundle name [com.xxx] / state #FOREGROUND
   */
  static parseForegroundApp(raw: string): string | null {
    const lines = ResponseParser.splitLines(raw);
    let lastBundle = '';
    for (const line of lines) {
      const bundleMatch = line.match(/bundle name\s*\[([\w.]+)\]/);
      if (bundleMatch) {
        lastBundle = bundleMatch[1];
      }
      // 找到 FOREGROUND 状态，返回它所属的 bundle
      if (line.includes('#FOREGROUND') && lastBundle) {
        return lastBundle;
      }
    }
    return lastBundle || null;
  }

  /**
   * 从 uitest dumpLayout 导出的 JSON 文本里提取前台应用包名。
   *
   * 实测该 JSON 里含 "bundleName":"com.octahedron.hmpriv" 与
   * "bundleName":"com.ohos.sceneboard"（桌面）。第一个通常就是当前前台 App。
   * 若只有 sceneboard 说明当前在桌面。
   */
  static parseForegroundFromLayout(layoutJson: string): string | null {
    if (!layoutJson) {
      return null;
    }
    const found: string[] = [];
    const re = /"bundleName"\s*:\s*"([\w.]+)"/g;
    let m: RegExpExecArray | null = re.exec(layoutJson);
    while (m !== null) {
      const name = m[1];
      if (!found.includes(name)) {
        found.push(name);
      }
      m = re.exec(layoutJson);
    }
    if (found.length === 0) {
      return null;
    }
    // 优先返回非桌面的那个
    for (const name of found) {
      if (!name.includes('sceneboard')) {
        return name;
      }
    }
    return found[0];
  }

  /**
   * 解析 hidumper -s BatteryService 输出。
   *
   * ⚠️ 实测：在模拟器上该命令只返回 header，没有任何字段
   * （BatteryService dump 走 pty，且模拟器无真实电池硬件）。
   * 真机可能有数据，所以保留解析逻辑作为兜底；
   * App 侧应优先用 @ohos.batteryInfo 原生 API（见 BatteryReader）。
   */
  static parseBattery(raw: string): BatteryInfo | null {
    const levelMatch = raw.match(/capacity[:\s]+(\d+)/i);
    const chargingMatch = raw.match(/chargeState[:\s]+(\w+)/i);
    const tempMatch = raw.match(/temperature[:\s]+(\d+)/i);
    const voltageMatch = raw.match(/voltage[:\s]+(\d+)/i);

    if (!levelMatch && !tempMatch && !voltageMatch) {
      return null;
    }

    return {
      level: levelMatch ? parseInt(levelMatch[1]) : -1,
      charging: chargingMatch ? chargingMatch[1].toLowerCase().includes('charge') : false,
      temperature: tempMatch ? parseInt(tempMatch[1]) / 10 : -1,
      voltage: voltageMatch ? parseInt(voltageMatch[1]) / 1000 : -1,
    };
  }

  /**
   * 解析 param get 输出（键 = 值，尾部可能带空格）
   */
  static parseSystemParams(raw: string): Map<string, string> {
    const params = new Map<string, string>();
    for (const line of ResponseParser.splitLines(raw)) {
      const trimmed = line.trim();
      if (!trimmed) {
        continue;
      }
      const eqIdx = trimmed.indexOf('=');
      if (eqIdx > 0) {
        const key = trimmed.substring(0, eqIdx).trim();
        const val = trimmed.substring(eqIdx + 1).trim();
        if (key) {
          params.set(key, val);
        }
      }
    }
    return params;
  }

  /**
   * 解析 hidumper --mem 输出，取总内存与进程数。
   * 输出是表格，行格式：
   *   PID        Total Pss(xxx in SwapPss)    Total Vss ...
   */
  static parseMemSummary(raw: string): string {
    const lines = ResponseParser.splitLines(raw);
    let count = 0;
    let totalPss = 0;
    for (const line of lines) {
      const m = line.match(/^\s*\d+\s+(\d+)\(/);
      if (m) {
        count++;
        totalPss += parseInt(m[1]);
      }
    }
    if (count === 0) {
      return '';
    }
    const mb = (totalPss / 1024).toFixed(0);
    return `进程数 ${count}，PSS 合计约 ${mb} MB`;
  }
}
