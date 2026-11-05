/**
 * FreezeManager — 看门狗冻结名单管理
 *
 * 【为什么是"看门狗"而不是真停用】
 * 鸿蒙 7.0 消费者版没有 `bm disable`（实测见 docs/TODO.md §4.1），
 * 无法让应用进入"停用"状态。这里改为持续强杀来模拟冻结效果：
 * daemon 每约 1 秒扫一次进程，发现名单里的应用在跑就 `aa force-stop`。
 *
 * 【实际效果】
 *   ✅ 不能后台常驻
 *   ✅ 用户手动打开也会在约 1 秒内被强停（表现为"打不开"）
 *   ❌ 包仍在，`bm dump` 仍能查到，其他应用仍能检测到已安装
 *   ❌ `aa start` 会成功，只是活不过 1 秒
 *
 * 【存储】
 * 总线目录的 frozen.txt，一行一个包名。
 * 文件由 hdc 预创建（shell/App 在 hmdfs 下无 create 权限），App 只覆写内容。
 */

import { fileIo } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';

const DOMAIN = 0x9201;
const TAG = 'FreezeManager';
const FILE_NAME = 'frozen.txt';

/** 绝对不允许冻结的包 —— 冻结自己会导致 App 被杀，再也没法从界面解冻 */
const SELF_BUNDLE = 'com.octahedron.hmpriv';

export class FreezeManager {
  private static path(busDir: string): string {
    return `${busDir}/${FILE_NAME}`;
  }

  /**
   * 读取冻结名单。
   * 跳过空行与 # 注释行，去重。
   */
  static getFrozen(busDir: string): string[] {
    const p = FreezeManager.path(busDir);
    const out: string[] = [];
    try {
      if (!fileIo.accessSync(p)) {
        return out;
      }
      const text = fileIo.readTextSync(p);
      if (!text || text.length === 0) {
        return out;
      }
      const lines = text.split('\n');
      for (const raw of lines) {
        const line = raw.trim();
        if (line.length === 0 || line.startsWith('#')) {
          continue;
        }
        if (out.indexOf(line) < 0) {
          out.push(line);
        }
      }
    } catch (err) {
      const e = err as BusinessError;
      hilog.warn(DOMAIN, TAG, `getFrozen failed: code=${e.code} msg=${e.message}`);
    }
    return out;
  }

  /** 某包是否在冻结名单里 */
  static isFrozen(busDir: string, bundleName: string): boolean {
    return FreezeManager.getFrozen(busDir).indexOf(bundleName) >= 0;
  }

  /**
   * 加入冻结名单。
   * @returns 失败原因字符串；成功返回空串
   */
  static addFrozen(busDir: string, bundleName: string): string {
    const name = bundleName.trim();
    if (name.length === 0) {
      return '包名为空';
    }
    if (name === SELF_BUNDLE) {
      return '不能冻结 HMArkPriv 自己 —— 冻结后 App 会被杀，界面再也打不开';
    }
    const list = FreezeManager.getFrozen(busDir);
    if (list.indexOf(name) >= 0) {
      return '';   // 已在名单里，视为成功
    }
    list.push(name);
    return FreezeManager.writeList(busDir, list);
  }

  /** 移出冻结名单 */
  static removeFrozen(busDir: string, bundleName: string): string {
    const list = FreezeManager.getFrozen(busDir);
    const idx = list.indexOf(bundleName);
    if (idx < 0) {
      return '';   // 本来就不在，视为成功
    }
    list.splice(idx, 1);
    return FreezeManager.writeList(busDir, list);
  }

  /** 清空全部冻结 */
  static clearAll(busDir: string): string {
    return FreezeManager.writeList(busDir, []);
  }

  /**
   * 全量覆写名单。
   *
   * 用 TRUNC 而不是先删后建 —— hmdfs 下删文件也可能被 SELinux 拦。
   */
  private static writeList(busDir: string, list: string[]): string {
    const p = FreezeManager.path(busDir);
    try {
      if (!fileIo.accessSync(p)) {
        return 'frozen.txt 不存在，请先在电脑上执行 scripts/setup-queue.sh';
      }
      const text = list.length > 0 ? list.join('\n') + '\n' : '';
      const f = fileIo.openSync(p, 0o2 | 0o1000);   // READ_WRITE | TRUNC
      try {
        if (text.length > 0) {
          fileIo.writeSync(f.fd, text);
        }
        fileIo.fsyncSync(f.fd);
      } finally {
        fileIo.closeSync(f);
      }
      hilog.info(DOMAIN, TAG, `wrote ${list.length} frozen bundles`);
      return '';
    } catch (err) {
      const e = err as BusinessError;
      hilog.error(DOMAIN, TAG, `writeList failed: code=${e.code} msg=${e.message}`);
      return `写入失败：${e.code} ${e.message}`;
    }
  }

  /**
   * 统计最近被拦截的次数（近似值）。
   *
   * daemon 每次强制停止都会往 audit.log 写一条 `FREEZE | RC:0 | force-stop <包名>`，
   * 这里数一下匹配行数。注意 audit.log 有 128KB 滚动，所以是"最近"而非"总计"。
   */
  static countIntercepts(busDir: string, bundleName: string): number {
    const p = `${busDir}/audit.log`;
    try {
      if (!fileIo.accessSync(p)) {
        return 0;
      }
      const text = fileIo.readTextSync(p);
      if (!text || text.length === 0) {
        return 0;
      }
      const needle = `force-stop ${bundleName}`;
      let count = 0;
      const lines = text.split('\n');
      for (const line of lines) {
        if (line.indexOf('FREEZE') >= 0 && line.indexOf(needle) >= 0) {
          count++;
        }
      }
      return count;
    } catch (err) {
      return 0;
    }
  }
}
