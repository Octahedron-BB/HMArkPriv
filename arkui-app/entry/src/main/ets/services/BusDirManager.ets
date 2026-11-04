/**
 * BusDirManager — 总线目录管理器
 *
 * 【核心问题】
 * 鸿蒙 App 沙箱默认无法用绝对路径访问 Download 目录。
 * 最初的方案是让用户通过 DocumentViewPicker(FOLDER) 授权目录 URI，
 * 但实测发现：手机上的文件夹选择器是"导航器"模式——点文件夹只会进入下一层，
 * 进入目标文件夹后界面上**没有任何"确认/完成"按钮**，用户无法完成选择。
 *
 * 【正确方案】
 * 使用 ohos.permission.READ_WRITE_DOWNLOAD_DIRECTORY（user_grant / normal 级），
 * 运行时弹一次系统授权框，用户点"允许"后即可用绝对路径直接读写 Download。
 * 不需要 picker，不需要每次选，重启后授权依然有效。
 *
 * picker 作为降级兜底保留（万一某些设备/版本不给该权限）。
 */

import { abilityAccessCtrl, bundleManager, common, Permissions } from '@kit.AbilityKit';
import { picker } from '@kit.CoreFileKit';
import { fileIo } from '@kit.CoreFileKit';
import { preferences } from '@kit.ArkData';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN = 0x9201;
const TAG = 'BusDirManager';
const PREF_STORE = 'hmpriv_settings';
const KEY_BUS_URI = 'busDirUri';

/**
 * 需要申请的全部权限。
 *
 * 【真机实测教训（2026-11-04）】
 * 只有 READ_WRITE_DOWNLOAD_DIRECTORY 不够：该权限在真机上 requestPermissions 返回
 * codes=[2]（无效请求），拿不到。真正生效的是 READ_MEDIA / WRITE_MEDIA —— 这两个
 * 是 user_grant + normal 级，普通 App 可申请，用户点"允许"后即可访问 Download 下
 * 本 App 有权访问的文件（媒体库代理，不受 unix 660 权限限制）。
 */
const PERMS: Permissions[] = [
  'ohos.permission.READ_MEDIA',
  'ohos.permission.WRITE_MEDIA',
  'ohos.permission.READ_WRITE_DOWNLOAD_DIRECTORY',
];

/** 主权限（用于状态判断）：媒体读写是真正起作用的那组 */
const PERM_DOWNLOAD: Permissions = 'ohos.permission.READ_WRITE_DOWNLOAD_DIRECTORY';
const PERM_READ_MEDIA: Permissions = 'ohos.permission.READ_MEDIA';

/**
 * 候选的 Download 总线目录绝对路径。
 *
 * 【关键】必须把 App 沙箱视角的虚拟路径放在第一位：
 *   /storage/Users/currentUser/Download/...   ← App 内可见（配合 READ_MEDIA/WRITE_MEDIA）
 *   /storage/media/100/local/files/Docs/Download/...  ← daemon(shell) 视角，App 访问不到
 *
 * 两者是同一物理目录的不同挂载视图。App 走前者，daemon 走后者，文件互通。
 */
const CANDIDATE_DIRS: string[] = [
  '/storage/Users/currentUser/Download/HMArkPriv',
  '/storage/media/100/local/files/Docs/Download/HMArkPriv',
  '/storage/emulated/0/Download/HMArkPriv',
  '/sdcard/Download/HMArkPriv',
];

export class BusDirManager {
  // ===== 权限相关 =====

  /**
   * 检查媒体读写权限是否已授予。
   * 真机上真正起作用的是 READ_MEDIA / WRITE_MEDIA，不是 READ_WRITE_DOWNLOAD_DIRECTORY。
   */
  static async hasDownloadPermission(): Promise<boolean> {
    try {
      const atManager = abilityAccessCtrl.createAtManager();
      const info = await bundleManager.getBundleInfoForSelf(
        bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION
      );
      const tokenId: number = info.appInfo.accessTokenId;
      const readOk = atManager.checkAccessTokenSync(tokenId, PERM_READ_MEDIA) ===
        abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED;
      hilog.info(DOMAIN, TAG, `hasDownloadPermission(READ_MEDIA): ${readOk}`);
      return readOk;
    } catch (err) {
      const e = err as BusinessError;
      hilog.error(DOMAIN, TAG, `check permission failed: code=${e.code} msg=${e.message}`);
      return false;
    }
  }

  /**
   * 申请全部所需权限（READ_MEDIA + WRITE_MEDIA + READ_WRITE_DOWNLOAD_DIRECTORY）。
   * 逐个记录结果，只要 READ_MEDIA 授予就算成功。
   */
  static async requestDownloadPermission(context: common.UIAbilityContext): Promise<boolean> {
    try {
      const atManager = abilityAccessCtrl.createAtManager();
      const result = await atManager.requestPermissionsFromUser(context, PERMS);
      const codes: number[] = result.authResults;
      const perms: string[] = result.permissions;
      const reasons: number[] = result.errorReasons ?? [];
      // 0=已授权 -1=未授权 2=无效请求；errorReasons: 2=未声明 5=不支持弹框 6=仅设置页
      for (let i = 0; i < perms.length; i++) {
        hilog.info(DOMAIN, TAG,
          `perm[${i}] ${perms[i]} = ${codes[i]} (reason=${reasons[i] ?? '-'})`);
      }
      // 只要 READ_MEDIA 或 WRITE_MEDIA 有一个授予就算成功
      let readOk = false;
      for (let i = 0; i < perms.length; i++) {
        if ((perms[i] === 'ohos.permission.READ_MEDIA' ||
             perms[i] === 'ohos.permission.WRITE_MEDIA') && codes[i] === 0) {
          readOk = true;
        }
      }
      hilog.info(DOMAIN, TAG, `requestDownloadPermission => ${readOk}`);
      return readOk;
    } catch (err) {
      const e = err as BusinessError;
      hilog.error(DOMAIN, TAG, `request permission failed: code=${e.code} msg=${e.message}`);
      return false;
    }
  }

  // ===== 路径探测 =====

  /** 在候选路径中找出当前可访问的总线目录 */
  static findAccessibleBusDir(): string {
    for (const dir of CANDIDATE_DIRS) {
      try {
        if (fileIo.accessSync(dir)) {
          hilog.info(DOMAIN, TAG, `bus dir found: ${dir}`);
          return dir;
        }
      } catch (err) {
        // 该路径不可用，继续下一个
      }
    }
    hilog.warn(DOMAIN, TAG, 'no accessible bus dir among candidates');
    return '';
  }

  /**
   * 测试能否真正读取总线文件（不只是目录可访问）。
   *
   * 【为什么需要】真机实测发现：目录 accessSync 返回 true（other 有 x 权限可遍历），
   * 但 status.json 是 660 属主 file_manager，App 不在该组 → 读文件失败。
   * 必须实际读一次才能判断总线是否真的可用。
   */
  static canReadBus(dir: string): boolean {
    if (!dir) {
      return false;
    }
    const candidates: string[] = [`${dir}/status.json`, `${dir}/cmd.res`];
    for (const p of candidates) {
      try {
        const text = fileIo.readTextSync(p);
        hilog.info(DOMAIN, TAG, `read ok: ${p} (${text.length} chars)`);
        return true;
      } catch (err) {
        const e = err as BusinessError;
        hilog.warn(DOMAIN, TAG, `read fail: ${p} code=${e.code} msg=${e.message}`);
      }
    }
    return false;
  }

  /** 测试能否写入（写一个探针文件后删除） */
  static canWriteBus(dir: string): boolean {
    if (!dir) {
      return false;
    }
    const probe = `${dir}/.write_probe`;
    try {
      const f = fileIo.openSync(probe, 0o2 | 0o100 | 0o1000);
      fileIo.writeSync(f.fd, 'probe');
      fileIo.closeSync(f);
      fileIo.unlinkSync(probe);
      hilog.info(DOMAIN, TAG, `write probe ok in ${dir}`);
      return true;
    } catch (err) {
      const e = err as BusinessError;
      hilog.warn(DOMAIN, TAG, `write probe fail: code=${e.code} msg=${e.message}`);
      return false;
    }
  }

  /** 诊断用：逐个探测候选路径并打印结果（含父目录） */
  static probeAllCandidates(): void {
    for (const dir of CANDIDATE_DIRS) {
      let dirOk = false;
      let parentOk = false;
      try {
        dirOk = fileIo.accessSync(dir);
      } catch (err) {
        dirOk = false;
      }
      const parent = dir.substring(0, dir.lastIndexOf('/'));
      try {
        parentOk = fileIo.accessSync(parent);
      } catch (err) {
        parentOk = false;
      }
      hilog.info(DOMAIN, TAG, `probe: dir=${dir} dirOk=${dirOk} parentOk=${parentOk}`);
    }
  }

  /**
   * 确保指定目录下的总线文件都存在。
   * @param dir 目标目录（绝对路径或 picker 返回的 URI）
   */
  static ensureBusFilesIn(dir: string): boolean {
    if (!dir) {
      return false;
    }
    // 目录可能还不存在，先尝试创建
    try {
      if (!fileIo.accessSync(dir)) {
        fileIo.mkdirSync(dir);
        hilog.info(DOMAIN, TAG, `created bus dir: ${dir}`);
      }
    } catch (err) {
      const e = err as BusinessError;
      hilog.warn(DOMAIN, TAG, `mkdir bus dir failed: code=${e.code} msg=${e.message}`);
    }

    const files: string[] = ['cmd.req', 'cmd.res', 'status.json'];
    for (const f of files) {
      const p = `${dir}/${f}`;
      try {
        if (!fileIo.accessSync(p)) {
          const file = fileIo.openSync(p, 0o2 | 0o100); // READ_WRITE | CREATE
          fileIo.closeSync(file);
          hilog.info(DOMAIN, TAG, `created bus file: ${p}`);
        }
      } catch (err) {
        const e = err as BusinessError;
        hilog.error(DOMAIN, TAG, `create ${f} failed: code=${e.code} msg=${e.message}`);
        return false;
      }
    }
    return true;
  }

  /**
   * 自动探测并初始化（沿用候选路径列表）。
   */
  static ensureBusFiles(): boolean {
    const dir = BusDirManager.findAccessibleBusDir();
    if (!dir) {
      hilog.warn(DOMAIN, TAG, 'ensureBusFiles: no accessible dir');
      return false;
    }
    return BusDirManager.ensureBusFilesIn(dir);
  }

  // ===== picker 降级方案 =====

  /**
   * 拉起系统目录选择器（降级用）。
   * 注意：手机上 FOLDER 模式是"导航"交互，进入目标文件夹后无确认按钮，
   * 体验不佳，仅在无法获得 DOWNLOAD 权限时兜底。
   */
  static async pickBusDir(context: common.UIAbilityContext): Promise<string> {
    try {
      const options = new picker.DocumentSelectOptions();
      options.selectMode = picker.DocumentSelectMode.FOLDER;
      options.maxSelectNumber = 1;

      const documentPicker = new picker.DocumentViewPicker(context);
      const uris: string[] = await documentPicker.select(options);

      if (uris.length === 0) {
        hilog.info(DOMAIN, TAG, 'user cancelled folder picking');
        return '';
      }

      const uri = uris[0];
      hilog.info(DOMAIN, TAG, `picked bus dir: ${uri}`);
      await BusDirManager.saveBusDir(context, uri);
      return uri;
    } catch (err) {
      const e = err as BusinessError;
      hilog.error(DOMAIN, TAG, `pickBusDir failed: code=${e.code} msg=${e.message}`);
      return '';
    }
  }

  // ===== 持久化（picker 兜底路径用） =====

  static async loadBusDir(context: common.UIAbilityContext): Promise<string> {
    try {
      const store = await preferences.getPreferences(context, PREF_STORE);
      return store.getSync(KEY_BUS_URI, '') as string;
    } catch (err) {
      hilog.warn(DOMAIN, TAG, `loadBusDir failed: ${err}`);
      return '';
    }
  }

  static async saveBusDir(context: common.UIAbilityContext, uri: string): Promise<void> {
    try {
      const store = await preferences.getPreferences(context, PREF_STORE);
      store.putSync(KEY_BUS_URI, uri);
      await store.flush();
      hilog.info(DOMAIN, TAG, `bus dir saved: ${uri}`);
    } catch (err) {
      hilog.error(DOMAIN, TAG, `saveBusDir failed: ${err}`);
    }
  }

  /** 某个路径当前是否可访问 */
  static isAccessible(pathOrUri: string): boolean {
    if (!pathOrUri) {
      return false;
    }
    try {
      return fileIo.accessSync(pathOrUri);
    } catch (err) {
      return false;
    }
  }
}
