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

export interface AppItem {
  bundleName: string;
  label: string;
  isSystem: boolean;
  isRunning?: boolean;
}

export interface PermissionItem {
  name: string;
  friendlyName: string;
  isUserGrant: boolean;
  isGranted: boolean;
  rawState: number;
}

interface RawDumpItem {
  bundleName?: string;
  label?: string;
}

export interface BatteryInfo {
  level: number;        // 电量 %，-1 表示未知
  charging: boolean;
  temperature: number;  // °C，-1 表示未知
  voltage: number;      // V，-1 表示未知
}

/** 合法包名：至少一个点分隔的段，只含字母数字下划线 */
const BUNDLE_RE = /^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+$/;

interface RawBundleDump {
  reqPermissions?: string[];
  reqPermissionStates?: number[];
}

const FRIENDLY_PERMISSION_MAP: Record<string, string> = {
  'ohos.permission.LOCATION': '精确定位',
  'ohos.permission.APPROXIMATELY_LOCATION': '模糊定位',
  'ohos.permission.LOCATION_IN_BACKGROUND': '后台定位',
  'ohos.permission.CAMERA': '相机拍摄',
  'ohos.permission.MICROPHONE': '麦克风录音',
  'ohos.permission.READ_PASTEBOARD': '读取剪贴板',
  'ohos.permission.READ_CALENDAR': '读取日历',
  'ohos.permission.WRITE_CALENDAR': '写入日历',
  'ohos.permission.READ_MEDIA': '读取多媒体',
  'ohos.permission.READ_IMAGEVIDEO': '读取图片与视频',
  'ohos.permission.READ_AUDIO': '读取音频',
  'ohos.permission.READ_DOCUMENT': '读取文档',
  'ohos.permission.WRITE_MEDIA': '写入多媒体',
  'ohos.permission.WRITE_IMAGEVIDEO': '保存图片与视频',
  'ohos.permission.WRITE_AUDIO': '写入音频',
  'ohos.permission.WRITE_DOCUMENT': '写入文档',
  'ohos.permission.APP_TRACKING_CONSENT': '应用追踪与广告',
  'ohos.permission.DISTRIBUTED_DATASYNC': '跨设备协同',
  'ohos.permission.ACTIVITY_MOTION': '运动健康与计步',
  'ohos.permission.READ_HEALTH_DATA': '读取健康数据',
  'ohos.permission.INTERNET': '互联网访问',
  'ohos.permission.GET_NETWORK_INFO': '获取网络信息',
  'ohos.permission.GET_WIFI_INFO': '获取Wi-Fi信息',
  'ohos.permission.GET_BUNDLE_INFO': '读取应用列表',
  'ohos.permission.VIBRATE': '振动控制',
  'ohos.permission.STORE_PERSISTENT_DATA': '持久化数据存储',
  'ohos.permission.PRIVACY_WINDOW': '防录屏隐私保护',
  'ohos.permission.KEEP_BACKGROUND_RUNNING': '后台长任务运行'
};

const USER_GRANT_SET = new Set<string>([
  'ohos.permission.LOCATION',
  'ohos.permission.APPROXIMATELY_LOCATION',
  'ohos.permission.LOCATION_IN_BACKGROUND',
  'ohos.permission.CAMERA',
  'ohos.permission.MICROPHONE',
  'ohos.permission.READ_PASTEBOARD',
  'ohos.permission.READ_CALENDAR',
  'ohos.permission.WRITE_CALENDAR',
  'ohos.permission.READ_MEDIA',
  'ohos.permission.READ_IMAGEVIDEO',
  'ohos.permission.READ_AUDIO',
  'ohos.permission.READ_DOCUMENT',
  'ohos.permission.WRITE_MEDIA',
  'ohos.permission.WRITE_IMAGEVIDEO',
  'ohos.permission.WRITE_AUDIO',
  'ohos.permission.WRITE_DOCUMENT',
  'ohos.permission.APP_TRACKING_CONSENT',
  'ohos.permission.DISTRIBUTED_DATASYNC',
  'ohos.permission.ACTIVITY_MOTION',
  'ohos.permission.READ_HEALTH_DATA'
]);

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
   * 判断包名是否偏向系统应用
   */
  static isSystemApp(bundle: string): boolean {
    if (bundle.startsWith('com.huawei.hmos.') ||
        bundle.startsWith('com.ohos.') ||
        bundle.startsWith('com.huawei.system') ||
        bundle.startsWith('com.huawei.hmsapp.') ||
        bundle === 'com.huawei.appgallery') {
      return true;
    }
    return false;
  }

  /**
   * 解析 bm dump -a -l 输出（带 Label 与 BundleName 的 JSON 格式）。
   * 150ms 极速解析。若遇到旧格式则自动回退兼容。
   */
  static parseAppListWithLabels(raw: string): AppItem[] {
    const list: AppItem[] = [];
    const trimmed = raw.trim();
    if (trimmed.startsWith('[')) {
      try {
        const parsed = JSON.parse(trimmed) as RawDumpItem[];
        for (let i = 0; i < parsed.length; i++) {
          const item = parsed[i];
          if (item && item.bundleName) {
            const b = item.bundleName.trim();
            const l = (item.label && item.label.trim()) ? item.label.trim() : b;
            const isSys = ResponseParser.isSystemApp(b);
            list.push({ bundleName: b, label: l, isSystem: isSys });
          }
        }
        return list;
      } catch (_e) {
        // 解析异常时回退
      }
    }

    // 回退旧文本解析
    const legacy = ResponseParser.parseAppList(raw);
    for (let i = 0; i < legacy.length; i++) {
      const item = legacy[i];
      const isSys = ResponseParser.isSystemApp(item.bundleName);
      list.push({
        bundleName: item.bundleName,
        label: item.bundleName,
        isSystem: isSys
      });
    }
    return list;
  }

  /**
   * 解析应用的权限列表，区分可修改的动态权限与系统默认权限
   */
  static parseAppPermissions(raw: string): PermissionItem[] {
    const result: PermissionItem[] = [];
    const idx = raw.indexOf('{');
    if (idx < 0) {
      return result;
    }
    const jsonStr = raw.substring(idx);
    try {
      const data = JSON.parse(jsonStr) as RawBundleDump;
      const perms = data.reqPermissions || [];
      const states = data.reqPermissionStates || [];
      for (let i = 0; i < perms.length; i++) {
        const p = perms[i];
        const st = i < states.length ? states[i] : -1;
        const isUser = USER_GRANT_SET.has(p);
        const friendly = FRIENDLY_PERMISSION_MAP[p] || p.replace('ohos.permission.', '');
        const granted = (st === 0);
        result.push({
          name: p,
          friendlyName: friendly,
          isUserGrant: isUser,
          isGranted: granted,
          rawState: st
        });
      }
    } catch (_e) {
      // 容错
    }
    return result;
  }

  /**
   * 解析 ps -ef 结果提取正在运行的应用包名集合
   */
  static parseRunningProcesses(raw: string): Set<string> {
    const set = new Set<string>();
    const lines = ResponseParser.splitLines(raw);
    for (let i = 0; i < lines.length; i++) {
      const line = lines[i].trim();
      const parts = line.split(/\s+/);
      if (parts.length >= 8) {
        const cmd = parts[parts.length - 1];
        if (cmd && cmd.includes('.') && !cmd.includes('/') && !cmd.startsWith('[')) {
          set.add(cmd);
        }
      }
    }
    return set;
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

  // ==========================================================================
  // bm 命令的成败判定
  //
  // 【为什么不能只看 exitCode】
  // 实测鸿蒙的 bm 工具**失败时退出码仍是 0**，错误信息只写在 stdout 里：
  //
  //   bm uninstall -n com.huawei.hmos.minorsprotection -u 100
  //   → RC:0
  //     error: failed to uninstall bundle.
  //     code:9568380
  //     error: uninstall system app error.
  //
  // 所以 CommandResult.success（等于 exitCode === 0）对 bm 系列命令**不可靠**，
  // 直接用会把失败当成功提示给用户。这里补一层文本判定。
  // ==========================================================================

  /** bm 输出是否代表失败 */
  static isBmFailure(raw: string): boolean {
    if (!raw) {
      return false;
    }
    const t = raw.toLowerCase();
    // bm 的失败文本特征："error: failed to ..." 或 "code:xxxxx"
    return t.indexOf('error: failed to') >= 0 || /\n?\s*code:\s*\d{4,}/.test(t);
  }

  /**
   * 把 bm 的错误码翻译成能看懂的话。
   * 错误码来自实测；未收录的直接回显原文，不猜。
   */
  static explainBmError(raw: string): string {
    if (!raw) {
      return '';
    }
    if (raw.indexOf('9568380') >= 0) {
      return '这是系统镜像集成的应用（appDistributionType = os_integration），' +
        '鸿蒙不允许卸载。如果不想让它运行，可以用「冻结应用」代替。';
    }
    if (raw.indexOf('9568386') >= 0) {
      return '设备上找不到这个应用，可能已经被卸载了。';
    }
    if (raw.indexOf('9568289') >= 0) {
      return '签名或权限校验未通过，安装/卸载请求被系统拒绝。';
    }
    if (raw.indexOf('9568332') >= 0) {
      return '签名校验失败。';
    }
    // 未收录的错误：截取 code 与 error 行回显
    const codeMatch = raw.match(/code:\s*(\d+)/);
    const errMatch = raw.match(/error:\s*([^\n]+)/);
    const parts: string[] = [];
    if (codeMatch) {
      parts.push(`错误码 ${codeMatch[1]}`);
    }
    if (errMatch) {
      parts.push(errMatch[1].trim());
    }
    return parts.length > 0 ? parts.join('，') : raw.trim();
  }
}
