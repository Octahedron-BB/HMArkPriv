import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN = 0x9201;
const TAG = 'HMArkPriv/EntryAbility';

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, TAG, 'onCreate: HMArkPriv App 启动');
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
    });
  }

  onWindowStageDestroy(): void {
    hilog.info(DOMAIN, TAG, 'onWindowStageDestroy');
  }

  onForeground(): void {
    hilog.info(DOMAIN, TAG, 'onForeground');
  }

  onBackground(): void {
    hilog.info(DOMAIN, TAG, 'onBackground');
  }
}
