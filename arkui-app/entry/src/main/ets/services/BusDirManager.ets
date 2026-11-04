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

/** 直接读写 Download 目录的权限 */
const PERM_DOWNLOAD: Permissions = 'ohos.permission.READ_WRITE_DOWNLOAD_DIRECTORY';

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

  /** 检查是否已授予 Download 目录读写权限 */
  static async hasDownloadPermission(): Promise<boolean> {
    try {
      const atManager = abilityAccessCtrl.createAtManager();
      const info = await bundleManager.getBundleInfoForSelf(
        bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION
      );
      const tokenId: number = info.appInfo.accessTokenId;
      const status = atManager.checkAccessTokenSync(tokenId, PERM_DOWNLOAD);
      const granted = status === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED;
      hilog.info(DOMAIN, TAG, `hasDownloadPermission: ${granted}`);
      return granted;
    } catch (err) {
      const e = err as BusinessError;
      hilog.error(DOMAIN, TAG, `check permission failed: code=${e.code} msg=${e.message}`);
      return false;
    }
  }

  /** 弹出系统授权框请求 Download 目录读写权限 */
  static async requestDownloadPermission(context: common.UIAbilityContext): Promise<boolean> {
    try {
      const atManager = abilityAccessCtrl.createAtManager();
      const result = await atManager.requestPermissionsFromUser(context, [PERM_DOWNLOAD]);
      const codes: number[] = result.authResults;
      const reasons: number[] = result.errorReasons ?? [];
      const shown: boolean[] = result.dialogShownResults ?? [];
      // 0=已授权 -1=未授权 2=无效请求；errorReasons: 2=未声明 5=不支持弹框 6=仅设置页授权
      hilog.info(DOMAIN, TAG,
        `requestDownloadPermission: codes=${JSON.stringify(codes)} ` +
        `reasons=${JSON.stringify(reasons)} dialogShown=${JSON.stringify(shown)}`);
      return codes.length > 0 && codes[0] === 0;
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
   * 确保总线目录和三个总线文件都存在。
   * 目录不存在时尝试创建（App 视角路径通常有写权限）。
   */
  static ensureBusFiles(): boolean {
    const dir = BusDirManager.findAccessibleBusDir();
    if (!dir) {
      hilog.warn(DOMAIN, TAG, 'ensureBusFiles: no accessible dir');
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
    try {
      for (const f of files) {
        const p = `${dir}/${f}`;
        if (!fileIo.accessSync(p)) {
          // 文件不存在则创建空壳，daemon 只需 write 即可
          const file = fileIo.openSync(p, 0o2 | 0o100); // READ_WRITE | CREATE
          fileIo.closeSync(file);
          hilog.info(DOMAIN, TAG, `created bus file: ${p}`);
        }
      }
      return true;
    } catch (err) {
      const e = err as BusinessError;
      hilog.error(DOMAIN, TAG, `ensureBusFiles failed: code=${e.code} msg=${e.message}`);
      return false;
    }
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
