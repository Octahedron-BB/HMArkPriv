/**
 * AdProbeAbility — 无障碍扩展可行性探针
 *
 * 【这个文件只做一件事】验证普通三方应用（apl = normal）声明 accessibility
 * 类型的 ExtensionAbility 后，系统是否真的把无障碍事件分发过来。
 *
 * 【背景】广告跳过需要"应用启动瞬间"的感知。shell 路线实测下限约 200ms
 * 且要常驻跑 hilog 轮询；AccessibilityExtensionAbility 提供 onAccessibilityEvent
 * 事件回调 + 直接读节点树 + 注入手势，是唯一的毫秒级方案。
 *
 * 【但能不能用未知】ACCESSIBILITY_EXTENSION_ABILITY 是 system_basic、
 * QUERY_ACCESSIBILITY_ELEMENT 是 system_core，本项目 apl = normal。
 * 结构上 module.json5 允许 type: "accessibility"，但系统是否分发事件必须实测。
 *
 * 【怎么判断结果】
 * 看总线目录的 adprobe.log：
 *   - 有 EVENT 行            → 通了，可做真正的广告跳过
 *   - 只有 CONNECT 行        → 扩展被拉起但收不到事件，需 system_basic
 *   - 连 CONNECT 都没有      → 系统根本没加载这个扩展
 *
 * 【关于事件字段】@ohos.application.AccessibilityExtensionAbility 导出的
 * AccessibilityEvent 只有 eventType / target / timeStamp 三个字段，
 * 拿 bundleName 之类的信息要走 target.attributeValue()（异步 Promise，
 * 在回调里不好用），所以这里只记录"事件到达 + 类型 + 有无 target"，
 * 足以判定可行性。
 */

import { AccessibilityExtensionAbility, AccessibilityEvent } from '@kit.AccessibilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { fileIo } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';

const DOMAIN = 0x9201;
const TAG = 'AdProbe';

/**
 * 总线目录 —— App 沙箱视角的虚拟路径。
 * /storage/Users/currentUser/... 与 shell 视角的
 * /storage/media/100/local/files/Docs/... 是同一物理目录的两个挂载视图。
 * 无障碍扩展与本 App 同 bundle，沙箱视图一致。
 */
const BUS_DIR = '/storage/Users/currentUser/Download/HMArkPriv';
const LOG_NAME = 'adprobe.log';

export default class AdProbeAbility extends AccessibilityExtensionAbility {
  onConnect(): void {
    hilog.info(DOMAIN, TAG, 'onConnect: 无障碍扩展已连接');
    AdProbeAbility.append('CONNECT', 'service connected');
  }

  onDisconnect(): void {
    hilog.info(DOMAIN, TAG, 'onDisconnect: 无障碍扩展断开');
    AdProbeAbility.append('DISCONNECT', 'service disconnected');
  }

  /**
   * 事件回调 —— 实验核心。
   *
   * 只记录 eventType 和"有没有 target 元素"，不做任何点击。
   * 目的纯粹是确认事件有没有来、来得多密。
   */
  onAccessibilityEvent(event: AccessibilityEvent): void {
    if (!event) {
      AdProbeAbility.append('EVENT_NULL', 'event is null');
      return;
    }
    try {
      const type: string = `${event.eventType}`;
      const hasTarget: string = event.target ? 'yes' : 'no';
      const ts: string = event.timeStamp !== undefined ? `${event.timeStamp}` : '-';
      hilog.info(DOMAIN, TAG, `event type=${type} target=${hasTarget} ts=${ts}`);
      AdProbeAbility.append('EVENT', `type=${type} target=${hasTarget} ts=${ts}`);
    } catch (err) {
      const e = err as BusinessError;
      AdProbeAbility.append('EVENT_ERR', `${e.code} ${e.message}`);
    }
  }

  /**
   * 追加一行日志。
   *
   * 只写已存在的文件：hmdfs 目录对"新建文件"有 SELinux 限制，
   * 日志文件由 App 侧先创建（见 Index.ets 的 ensureProbeLog）。
   * 写不进去时 hilog 仍留有记录，可兜底观察。
   */
  private static append(kind: string, detail: string): void {
    const path = `${BUS_DIR}/${LOG_NAME}`;
    const now = new Date();
    const ts = `${now.getFullYear()}-${AdProbeAbility.pad(now.getMonth() + 1)}-` +
      `${AdProbeAbility.pad(now.getDate())} ${AdProbeAbility.pad(now.getHours())}:` +
      `${AdProbeAbility.pad(now.getMinutes())}:${AdProbeAbility.pad(now.getSeconds())}`;
    const line = `${ts} ${kind} ${detail}\n`;

    try {
      if (fileIo.accessSync(path)) {
        if (fileIo.statSync(path).size > 500 * 80) {
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
