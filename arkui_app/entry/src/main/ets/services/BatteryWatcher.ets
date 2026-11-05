/**
 * BatteryWatcher — 订阅系统电量广播，用于验证「切后台后能否收到事件」
 *
 * 【要回答的问题】
 * 实测 App 切到后台后，页面的 `setInterval` 心跳会立刻冻结（50 秒纹丝不动）。
 * 这有两种可能，处置方式完全不同：
 *
 *   A. ArkUI 只是暂停了 JS 定时器 —— 那么系统广播的回调**仍会被调用**，
 *      拔电瞬间就能写状态，常亮的"残留窗口"可以压到几秒。
 *   B. 整个进程被挂起 —— 广播也收不到，只能维持现有的 30 分钟宽限期。
 *
 * 判断方法：订阅 `COMMON_EVENT_BATTERY_CHANGED`，每次回调往总线目录追加一行
 * 带时间戳的记录。然后：
 *   1. 打开 App（前台）
 *   2. 按 Home 切后台
 *   3. 拔掉 USB（此时 hdc 会断开，无法实时观察）
 *   4. 重新插上 USB，回连后读文件 —— 看拔线期间有没有记录
 *
 * 写文件而不是只打 hilog，是因为 hilog 环形缓冲区只有约 2 分钟，
 * 而"拔线 → 重新插上 → 回连"这个过程经常超过 2 分钟，日志会被冲掉。
 *
 * 【诊断用途】验证完这个类可以删，或把结论固化进正式逻辑。
 */

import { common } from '@kit.AbilityKit';
import { commonEventManager } from '@kit.BasicServicesKit';
import { fileIo } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';

const DOMAIN = 0x9201;
const TAG = 'BatWatch';
const LOG_NAME = 'batwatch.log';
/** 单文件上限，防止长期运行把总线目录写爆 */
const MAX_LINES = 500;

export class BatteryWatcher {
  private static subscriber: commonEventManager.CommonEventSubscriber | null = null;
  private static busDir: string = '';
  private static started: boolean = false;

  /**
   * 开始订阅。
   * @param busDir App 视角的总线目录（如 /storage/Users/currentUser/Download/HMArkPriv）
   */
  static start(busDir: string): void {
    if (BatteryWatcher.started) {
      // 目录可能变了（用户重新授权），更新一下即可，不重复订阅
      BatteryWatcher.busDir = busDir;
      return;
    }
    BatteryWatcher.busDir = busDir;

    hilog.info(DOMAIN, TAG, `start(): busDir=${busDir}`);
    BatteryWatcher.append('START', busDir);

    try {
      const info: commonEventManager.CommonEventSubscribeInfo = {
        events: ['usual.event.BATTERY_CHANGED'],
      };
      // 用同步版：异步版 createSubscriber 的回调实测在本机没有触发，
      // 连失败日志都打不出来，无法区分"没订阅上"和"订阅上了但没事件"。
      const sub = commonEventManager.createSubscriberSync(info);
      BatteryWatcher.subscriber = sub;
      commonEventManager.subscribe(sub, (e: BusinessError, data: commonEventManager.CommonEventData) => {
        if (e) {
          hilog.error(DOMAIN, TAG, `subscribe callback err: ${e.code}`);
          return;
        }
        // 记时间 + 事件名（当前只关心"回调有没有被调用"）
        hilog.info(DOMAIN, TAG, `event: ${data ? data.event : 'unknown'}`);
        BatteryWatcher.append('EVENT', data ? data.event : 'unknown');
      });
      BatteryWatcher.started = true;
      hilog.info(DOMAIN, TAG, 'subscribed usual.event.BATTERY_CHANGED');
      BatteryWatcher.append('START_OK', 'subscribed');
    } catch (err) {
      const e = err as BusinessError;
      hilog.error(DOMAIN, TAG, `start failed: ${e.code} ${e.message}`);
      BatteryWatcher.append('START_FAIL', `${e.code} ${e.message}`);
    }
  }

  /** 追加一行：时间戳 类型 说明 */
  private static append(kind: string, detail: string): void {
    const dir = BatteryWatcher.busDir;
    if (!dir || dir.length === 0) {
      return;
    }
    const path = `${dir}/${LOG_NAME}`;
    const now = new Date();
    const ts = `${now.getFullYear()}-${BatteryWatcher.pad(now.getMonth() + 1)}-` +
      `${BatteryWatcher.pad(now.getDate())} ${BatteryWatcher.pad(now.getHours())}:` +
      `${BatteryWatcher.pad(now.getMinutes())}:${BatteryWatcher.pad(now.getSeconds())}`;
    const line = `${ts} ${kind} ${detail}\n`;

    try {
      // 简单滚动：超过上限就整体截断重来（诊断用，不追求精确）
      if (fileIo.accessSync(path)) {
        const size = fileIo.statSync(path).size;
        if (size > MAX_LINES * 60) {
          fileIo.unlinkSync(path);
        }
      }
      const file = fileIo.openSync(path, fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE
        | fileIo.OpenMode.APPEND);
      fileIo.writeSync(file.fd, line);
      fileIo.fsyncSync(file.fd);
      fileIo.closeSync(file);
    } catch (err) {
      const e = err as BusinessError;
      hilog.warn(DOMAIN, TAG, `append failed: ${e.code} ${e.message}`);
    }
  }

  private static pad(n: number): string {
    return n < 10 ? `0${n}` : `${n}`;
  }
}
