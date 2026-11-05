/**
 * BatteryReader — 电池信息读取（原生 API 优先）
 *
 * 【为什么不用 hidumper -s BatteryService】
 * 实测（2026-11-04 模拟器）该命令只返回 header，一个字段都没有：
 *   ----------------------------------BatteryService----------------------------------
 * 原因是 service dump 走 pty，且模拟器无真实电池硬件。真机也可能因权限/
 * 版本差异拿不到稳定输出。
 *
 * 鸿蒙提供了 @ohos.batteryInfo 原生 API，App 直接读即可，无需 shell：
 *   batterySOC            电量百分比
 *   batteryTemperature    温度（单位 0.1°C）
 *   voltage               电压（单位微伏）
 *   chargingStatus        充电状态枚举
 *   pluggedType           充电器类型
 *   healthStatus          健康状态
 *
 * 这条路径既稳定又快（无 IPC 开销），Phase 5 的电池卡片应优先用它。
 */

import { batteryInfo } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN = 0x9201;
const TAG = 'BatteryReader';

export interface BatterySnapshot {
  /** 电量百分比 0-100，-1 未知 */
  level: number;
  /** 是否正在充电（chargingStatus=1 充电中 / 3 已充满） */
  charging: boolean;
  /**
   * 是否已插电（pluggedType ≠ 0）。
   *
   * 【为什么必须和 charging 分开】实测这台机器插着 USB 且电量满时，
   * chargingStatus=3(FULL) 而 pluggedType=2(USB)。若只看 chargingStatus，
   * 界面会显示"未充电"，看着像没插电 —— 用户就会以为是 bug。
   * 而"充电时不熄屏"这个功能真正关心的是**有没有外部供电**，即 plugged。
   */
  plugged: boolean;
  /** 温度 °C，-1 未知 */
  temperature: number;
  /** 电压 V，-1 未知 */
  voltage: number;
  /** 是否有电池（模拟器可能为 false） */
  present: boolean;
  /** 充电器类型描述 */
  plugType: string;
  /** 健康状态描述 */
  health: string;
}

export class BatteryReader {
  static read(): BatterySnapshot {
    try {
      const soc: number = batteryInfo.batterySOC;
      const status: number = batteryInfo.chargingStatus as number;
      const tempRaw: number = batteryInfo.batteryTemperature;
      const voltRaw: number = batteryInfo.voltage;
      const present: boolean = batteryInfo.isBatteryPresent;

      // BatteryChargeState: 0=NONE 1=ENABLE(充电中) 2=DISABLE(未充电) 3=FULL(充满)
      const charging = status === 1 || status === 3;
      // BatteryPluggedType: 0=NONE 1=AC 2=USB 3=WIRELESS
      const plugged = (batteryInfo.pluggedType as number) !== 0;
      const statusText = BatteryReader.chargeStateText(status);

      const snap: BatterySnapshot = {
        level: typeof soc === 'number' ? soc : -1,
        charging,
        plugged,
        temperature: typeof tempRaw === 'number' && tempRaw !== 0 ? tempRaw / 10 : -1,
        voltage: typeof voltRaw === 'number' && voltRaw !== 0 ? voltRaw / 1000000 : -1,
        present,
        plugType: BatteryReader.plugTypeText(batteryInfo.pluggedType as number),
        health: BatteryReader.healthText(batteryInfo.healthStatus as number),
      };

      hilog.info(DOMAIN, TAG,
        `battery: ${snap.level}% ${statusText} ${snap.temperature}°C ${snap.voltage}V ` +
        `present=${present} plug=${snap.plugType}`);
      return snap;
    } catch (err) {
      hilog.error(DOMAIN, TAG, `read battery failed: ${err}`);
      return {
        level: -1, charging: false, plugged: false, temperature: -1, voltage: -1,
        present: false, plugType: '未知', health: '未知',
      };
    }
  }

  private static chargeStateText(s: number): string {
    switch (s) {
      case 1: return '充电中';
      case 2: return '未充电';
      case 3: return '已充满';
      default: return '未知';
    }
  }

  private static plugTypeText(t: number): string {
    // BatteryPluggedType: 0=NONE 1=AC 2=USB 3=WIRELESS
    switch (t) {
      case 1: return 'AC 充电器';
      case 2: return 'USB';
      case 3: return '无线充电';
      default: return '未连接';
    }
  }

  private static healthText(h: number): string {
    // BatteryHealthState: 0=UNKNOWN 1=GOOD 2=OVERVOLTAGE 3=COLD 4=OVERTEMP ...
    switch (h) {
      case 1: return '良好';
      case 2: return '过压';
      case 3: return '温度过低';
      case 4: return '温度过高';
      case 5: return '过放';
      default: return '未知';
    }
  }
}
