/**
 * Logger — 日志工具
 *
 * 封装 hilog，统一日志格式和域。
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { LOG_DOMAIN, LOG_TAG } from '../common/Constants';

export class Logger {
  static debug(msg: string): void {
    hilog.debug(LOG_DOMAIN, LOG_TAG, `%{public}s`, msg);
  }

  static info(msg: string): void {
    hilog.info(LOG_DOMAIN, LOG_TAG, `%{public}s`, msg);
  }

  static warn(msg: string): void {
    hilog.warn(LOG_DOMAIN, LOG_TAG, `%{public}s`, msg);
  }

  static error(msg: string): void {
    hilog.error(LOG_DOMAIN, LOG_TAG, `%{public}s`, msg);
  }
}
