/**
 * NotifyProbeAbility — 通知订阅扩展可行性探针
 *
 * 【目标】验证第三方应用能否通过 NotificationSubscriberExtensionAbility
 * 拿到**其他应用**的通知。这是"通知转发器"类工具的基础能力。
 *
 * 【设计背景】鸿蒙这套 API 的设计目标是把手机通知转发到蓝牙设备
 * （手表/耳机/车机），所以：
 *   - SubscribeType 只有一个值 BLUETOOTH
 *   - subscribe() 必须传一个蓝牙地址 addr
 * 这意味着即使能拿到通知，也必须先有"蓝牙设备地址"这个前提。
 * 本次实验先把"能不能收到通知"这件事验证清楚。
 *
 * 【与无障碍方案的对比】
 * 无障碍扩展的权限 ACCESSIBILITY_EXTENSION_ABILITY 声明后安装直接失败
 * （见 docs/TODO.md §5.0.11）。这里的 SUBSCRIBE_NOTIFICATION 同为
 * system_basic，但 API 没有 @systemapi 标记，所以仍有希望。
 * 本次实验的核心就是：装得上吗？能弹出授权页吗？
 *
 * 【判断结果】
 * 看总线目录的 notifyprobe.log：
 *   - 有 CONNECT + 后续 MSG 行 → 通了，能做通知转发
 *   - 只有 CONNECT         → 扩展被拉起但收不到通知
 *   - 什么都没有            → 扩展没被加载 / 授权没成功
 */

import { NotificationSubscriberExtensionAbility } from '@kit.NotificationKit';
import { notificationExtensionSubscription } from '@kit.NotificationKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { fileIo } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';

// NotificationInfo 不在 kit 的导出列表里，要经命名空间取
type NotificationInfo = notificationExtensionSubscription.NotificationInfo;

const DOMAIN = 0x9202;
const TAG = 'NotifyProbe';

/** 总线目录（App 沙箱视角） */
const BUS_DIR = '/storage/Users/currentUser/Download/HMArkPriv';
const LOG_NAME = 'notifyprobe.log';

export default class NotifyProbeAbility extends NotificationSubscriberExtensionAbility {
  onDestroy(): void {
    hilog.info(DOMAIN, TAG, 'onDestroy');
    NotifyProbeAbility.append('DESTROY', 'extension destroyed');
  }

  /**
   * 收到通知 —— 整个实验的核心。
   *
   * NotificationInfo 能给到的字段：
   *   bundleName  哪个应用发的
   *   appName     应用显示名
   *   content     { title, text } —— 只有标题和正文，没有图标/按钮
   *   deliveryTime 送达时间
   *   hashCode    用于后续取消
   */
  onReceiveMessage(notificationInfo: NotificationInfo): void {
    if (!notificationInfo) {
      NotifyProbeAbility.append('MSG_NULL', 'notificationInfo is null');
      return;
    }
    try {
      const pkg: string = notificationInfo.bundleName ? notificationInfo.bundleName : '-';
      const app: string = notificationInfo.appName ? notificationInfo.appName : '-';
      const title: string = notificationInfo.content ? notificationInfo.content.title : '';
      const text: string = notificationInfo.content ? notificationInfo.content.text : '';
      const line = `pkg=${pkg} app=${app} title=${title} text=${text}`;
      hilog.info(DOMAIN, TAG, line);
      NotifyProbeAbility.append('MSG', line);
    } catch (err) {
      const e = err as BusinessError;
      NotifyProbeAbility.append('MSG_ERR', `${e.code} ${e.message}`);
    }
  }

  /** 通知被撤销 */
  onCancelMessages(hashCodes: Array<string>): void {
    try {
      const n: number = hashCodes ? hashCodes.length : 0;
      hilog.info(DOMAIN, TAG, `onCancelMessages count=${n}`);
      NotifyProbeAbility.append('CANCEL', `count=${n}`);
    } catch (err) {
      const e = err as BusinessError;
      NotifyProbeAbility.append('CANCEL_ERR', `${e.code} ${e.message}`);
    }
  }

  /**
   * 追加一行日志。
   *
   * 只写已存在的文件 —— hmdfs 目录对"新建"有 SELinux 限制，
   * 日志文件由 App 侧预先创建（见 Index.ets 的 ensureNotifyLog）。
   */
  private static append(kind: string, detail: string): void {
    const path = `${BUS_DIR}/${LOG_NAME}`;
    const now = new Date();
    const ts = `${now.getFullYear()}-${NotifyProbeAbility.pad(now.getMonth() + 1)}-` +
      `${NotifyProbeAbility.pad(now.getDate())} ${NotifyProbeAbility.pad(now.getHours())}:` +
      `${NotifyProbeAbility.pad(now.getMinutes())}:${NotifyProbeAbility.pad(now.getSeconds())}`;
    try {
      if (fileIo.accessSync(path) && fileIo.statSync(path).size > 400 * 120) {
        fileIo.unlinkSync(path);
      }
      const file = fileIo.openSync(path, fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE
        | fileIo.OpenMode.APPEND);
      fileIo.writeSync(file.fd, `${ts} ${kind} ${detail}\n`);
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

/** 供 UI 调用的授权/订阅封装 */
export class NotifySubscriber {
  /** 打开系统授权页（用户在那里开启"允许访问本设备通知"并勾选应用） */
  static async openSettings(context: object): Promise<string> {
    try {
      // 参数类型是 UIAbilityContext，这里由调用方保证
      await notificationExtensionSubscription.openSubscriptionSettings(context as never);
      return 'OK: 授权页已打开';
    } catch (err) {
      const e = err as BusinessError;
      return `FAIL ${e.code}: ${e.message}`;
    }
  }

  /** 查询是否已获得用户授权 */
  static async isGranted(): Promise<string> {
    try {
      const ok: boolean = await notificationExtensionSubscription.isUserGranted();
      return `isUserGranted=${ok}`;
    } catch (err) {
      const e = err as BusinessError;
      return `isUserGranted FAIL ${e.code}: ${e.message}`;
    }
  }

  /** 查询用户已授权的应用列表 */
  static async grantedBundles(): Promise<string> {
    try {
      const list = await notificationExtensionSubscription.getUserGrantedEnabledBundles();
      return `已授权应用数=${list.length}`;
    } catch (err) {
      const e = err as BusinessError;
      return `grantedBundles FAIL ${e.code}: ${e.message}`;
    }
  }
}
