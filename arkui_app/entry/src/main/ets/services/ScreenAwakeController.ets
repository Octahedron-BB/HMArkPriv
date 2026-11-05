/**
 * ScreenAwakeController — 用 runningLock 实现「条件性保持亮屏」
 *
 * 【现状与动机】
 * 当前的充电常亮是靠 `power-shell timeout -o 86400000` 实现的 —— 本质是把
 * 用户设置的屏幕超时临时改成 24 小时。这有三个痼疾：
 *   1. 污染用户设置，必须负责还原，还原失败就成"幽灵常亮"
 *   2. 改的是绝对超时值，不是"条件性保持"，精度差
 *   3. 和用户手动改设置会互相覆盖，状态容易错乱
 *
 * Android 的 STAY_ON_WHILE_PLUGGED_IN 之所以干净，是因为它加的是 wakelock
 * （临时标志），不动超时设置。鸿蒙侧对应能力是 @ohos.runningLock。
 *
 * 【实测结论】
 * - `ohos.permission.RUNNING_LOCK` 是 availableLevel=normal + system_grant，
 *   不是 MDM 那种受限 ACL，普通应用可以声明（声明后能正常安装）
 * - `RunningLockType.BACKGROUND` 在本机 isSupported() = true
 * - `RunningLockType.BACKGROUND_USER_IDLE`（语义更贴切）本机不支持
 *
 * 用它的好处：hold() 期间不熄屏，unhold() 后立刻恢复用户原本的超时设置，
 * 全程不改 settings，也就没有"还不回去"的残留问题。
 */

import { runningLock } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';

const DOMAIN = 0x9201;
const TAG = 'ScreenAwake';
const LOCK_NAME = 'hmpriv_stay_awake';

export class ScreenAwakeController {
  private static held: boolean = false;

  /** 设备是否支持该类型的锁 */
  static isSupported(): boolean {
    try {
      return runningLock.isSupported(runningLock.RunningLockType.BACKGROUND);
    } catch (err) {
      const e = err as BusinessError;
      hilog.warn(DOMAIN, TAG, `isSupported failed: code=${e.code} msg=${e.message}`);
      return false;
    }
  }

  /** 当前是否持有锁 */
  static isHeld(): boolean {
    return ScreenAwakeController.held;
  }

  /**
   * 申请保持亮屏。
   *
   * @param timeoutMs 自动释放的超时（毫秒）。传 -1 表示不超时。
   *                  建议传一个较长值兜底，防止 App 异常退出导致锁泄漏。
   * @returns 是否成功
   */
  static async acquire(timeoutMs: number = -1): Promise<boolean> {
    if (ScreenAwakeController.held) {
      return true;
    }
    try {
      const lock = await runningLock.createRunningLock(
        LOCK_NAME,
        runningLock.RunningLockType.BACKGROUND
      );
      lock.hold(timeoutMs);
      ScreenAwakeController.held = true;
      hilog.info(DOMAIN, TAG, `acquired (timeout=${timeoutMs})`);
      return true;
    } catch (err) {
      const e = err as BusinessError;
      hilog.error(DOMAIN, TAG, `acquire failed: code=${e.code} msg=${e.message}`);
      return false;
    }
  }

  /** 释放保持亮屏，立即恢复系统原本的熄屏策略 */
  static async release(): Promise<boolean> {
    if (!ScreenAwakeController.held) {
      return true;
    }
    try {
      const lock = await runningLock.createRunningLock(
        LOCK_NAME,
        runningLock.RunningLockType.BACKGROUND
      );
      lock.unhold();
      ScreenAwakeController.held = false;
      hilog.info(DOMAIN, TAG, 'released');
      return true;
    } catch (err) {
      const e = err as BusinessError;
      hilog.error(DOMAIN, TAG, `release failed: code=${e.code} msg=${e.message}`);
      return false;
    }
  }
}
