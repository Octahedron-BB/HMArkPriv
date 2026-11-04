import { AbilityConstant, UIAbility, Want, common } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { CrossAppHandler } from '../services/CrossAppHandler';

const DOMAIN = 0x9201;
const TAG = 'HMArkPriv/EntryAbility';

export default class EntryAbility extends UIAbility {
  /** 冷启动时暂存的外部调用请求，等界面加载完再执行 */
  private pendingExternalCall: Want | null = null;

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, TAG, 'onCreate: HMArkPriv App 启动');

    // 外部 App 通过 startAbilityForResult 调用时，会带自定义 action
    if (CrossAppHandler.isExternalCall(want)) {
      hilog.info(DOMAIN, TAG, `onCreate: external call detected, cmd will run after UI ready`);
      this.pendingExternalCall = want;
    }
  }

  onDestroy(): void {
    hilog.info(DOMAIN, TAG, 'onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    hilog.info(DOMAIN, TAG, 'onWindowStageCreate');

    // 设置暗色沉浸式状态栏
    windowStage.getMainWindow().then((mainWindow) => {
      mainWindow.setWindowSystemBarProperties({
        statusBarContentColor: '#E2E8F0',
        navigationBarContentColor: '#E2E8F0',
      }).catch((err: Error) => {
        hilog.warn(DOMAIN, TAG, `setWindowSystemBarProperties failed: ${err.message}`);
      });
    }).catch((err: Error) => {
      hilog.warn(DOMAIN, TAG, `getMainWindow failed: ${err.message}`);
    });

    // 加载主页面
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, TAG, `loadContent failed: ${JSON.stringify(err)}`);
        return;
      }
      hilog.info(DOMAIN, TAG, 'loadContent success');

      // 界面已就绪，执行挂起的外部调用
      // 放在 loadContent 回调里是为了让界面先渲染出来 —— 用户能看到一次闪烁，
      // 这对敏感命令执行是有意义的反馈（用户知道有人在调用特权接口）
      if (this.pendingExternalCall) {
        const want = this.pendingExternalCall;
        this.pendingExternalCall = null;
        CrossAppHandler.handle(this.context, want).catch((e: Error) => {
          hilog.error(DOMAIN, TAG, `handle external call failed: ${e.message}`);
        });
      }
    });
  }

  onWindowStageDestroy(): void {
    hilog.info(DOMAIN, TAG, 'onWindowStageDestroy');
  }

  /**
   * App 已在运行（热启动）时收到新的 external call。
   * 直接处理，处理完会 terminateSelfWithResult 退出。
   */
  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    if (CrossAppHandler.isExternalCall(want)) {
      hilog.info(DOMAIN, TAG, 'onNewWant: external call detected');
      CrossAppHandler.handle(this.context, want).catch((e: Error) => {
        hilog.error(DOMAIN, TAG, `handle external call failed: ${e.message}`);
      });
    }
  }

  onForeground(): void {
    hilog.info(DOMAIN, TAG, 'onForeground');
  }

  onBackground(): void {
    hilog.info(DOMAIN, TAG, 'onBackground');
  }
}
