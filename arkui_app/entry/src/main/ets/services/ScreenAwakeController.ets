/**
 * ScreenAwakeController — 用窗口级「保持屏幕常亮」实现充电不熄屏
 *
 * 【为什么不能用 @ohos.runningLock】
 * 之前的实现用的是 `runningLock.createRunningLock(name, RunningLockType.BACKGROUND)`，
 * 这是**错的**，而且错得很隐蔽（调用成功、不报错、日志也正常）：
 *
 *   1. SDK 对 `RunningLockType.BACKGROUND` 的定义是
 *      "prevents the system from entering **sleep** mode when the screen is off"
 *      —— 它的语义是「屏幕已经灭了，别让 CPU 睡」，跟「别让屏幕灭」正相反。
 *   2. 该枚举自 API 10 起已废弃。
 *   3. @ohos.runningLock 对三方应用**没有** SCREEN 类型（RunningLockType 只有
 *      BACKGROUND / PROXIMITY_SCREEN_CONTROL / BACKGROUND_USER_IDLE 三个）。
 *
 * 真机实测（2026-11-05）：开关打开后 `hidumper -s PowerManagerService -a -r`
 * 里查不到本应用的任何 SCREEN 锁，状态机的 DIM 失败原因里也没有我们 —— 
 * 也就是说这把锁从来没起过作用。
 *
 * 【正确做法】
 * `window.setWindowKeepScreenOn(true)`：系统文档里唯一面向三方应用的常亮 API
 * （@since 9，公开接口，无需申请权限）。它在窗口维度挂一把 SCREEN 运行锁，
 * 解锁/关闭窗口时由系统回收，天然不会留下"幽灵常亮"。
 *
 * 【已知限制（必须诚实告知用户）】
 * - 锁挂在窗口上：App 退到后台后窗口不可见，常亮随之失效。
 * - 系统文档明确写着「系统检测到非规范使用该接口时，可能会恢复自动灭屏」，
 *   即"充电 + 无交互 + 强行常亮"这种非常规场景，系统有权把它打回去。
 *   这是平台策略，App 侧无法绕过。
 */

import { window } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';

const DOMAIN = 0x9201;
const TAG = 'ScreenAwake';

export class ScreenAwakeController {
  /** 缓存主窗口，避免每次开关都异步取一次 */
  private static win: window.Window | null = null;
  /** 是否已置为常亮（仅表示我们最后一次调用的意图） */
  private static held: boolean = false;

  /** 由页面在 aboutToAppear 里注入主窗口（拿到就用，拿不到则懒加载兜底） */
  static bindWindow(w: window.Window): void {
    ScreenAwakeController.win = w;
  }

  static isHeld(): boolean {
    return ScreenAwakeController.held;
  }

  private static async ensureWindow(): Promise<window.Window | null> {
    if (ScreenAwakeController.win !== null) {
      return ScreenAwakeController.win;
    }
    try {
      const ctx = getContext() as common.UIAbilityContext;
      const w = await window.getLastWindow(ctx);
      ScreenAwakeController.win = w;
      return w;
    } catch (err) {
      const e = err as BusinessError;
      hilog.error(DOMAIN, TAG, `getLastWindow failed: code=${e.code} msg=${e.message}`);
      return null;
    }
  }

  /** 申请保持亮屏 */
  static async acquire(): Promise<boolean> {
    if (ScreenAwakeController.held) {
      return true;
    }
    const w = await ScreenAwakeController.ensureWindow();
    if (w === null) {
      return false;
    }
    try {
      await w.setWindowKeepScreenOn(true);
      ScreenAwakeController.held = true;
      hilog.info(DOMAIN, TAG, 'keepScreenOn = true');
      return true;
    } catch (err) {
      const e = err as BusinessError;
      hilog.error(DOMAIN, TAG, `setWindowKeepScreenOn(true) failed: code=${e.code} msg=${e.message}`);
      return false;
    }
  }

  /** 立即恢复系统原本的熄屏策略 */
  static async release(): Promise<boolean> {
    if (!ScreenAwakeController.held) {
      return true;
    }
    const w = await ScreenAwakeController.ensureWindow();
    if (w === null) {
      // 窗口已经没了，锁会随窗口一起被系统回收
      ScreenAwakeController.held = false;
      return true;
    }
    try {
      await w.setWindowKeepScreenOn(false);
      ScreenAwakeController.held = false;
      hilog.info(DOMAIN, TAG, 'keepScreenOn = false');
      return true;
    } catch (err) {
      const e = err as BusinessError;
      hilog.error(DOMAIN, TAG, `setWindowKeepScreenOn(false) failed: code=${e.code} msg=${e.message}`);
      return false;
    }
  }
}
