/**
 * HMArkPriv 常量定义
 */

/** 文件总线默认目录（daemon.sh 监听的路径） */
export const DEFAULT_BUS_DIR = '/storage/media/100/local/files/Docs/Download/HMArkPriv';

/** 卓易通容器映射路径（备选） */
export const ALT_BUS_DIRS: string[] = [
  '/storage/emulated/0/MyHarmonyOSDevice/Download/HMArkPriv',
  '/sdcard/MyHarmonyOSDevice/Download/HMArkPriv',
  '/storage/emulated/0/Download/HMArkPriv',
  '/sdcard/Download/HMArkPriv',
];

/** 总线文件名 */
export const BUS_FILE_REQ = 'cmd.req';
export const BUS_FILE_RES = 'cmd.res';
export const BUS_FILE_STATUS = 'status.json';

/** 轮询间隔（毫秒） */
export const POLL_INTERVAL_MS = 50;

/** 响应超时（毫秒） */
export const TIMEOUT_MS = 5000;

/** 最大轮询次数 */
export const MAX_POLL_ATTEMPTS = TIMEOUT_MS / POLL_INTERVAL_MS; // 100

/** 命令历史最大保存数 */
export const MAX_CMD_HISTORY = 100;

/** 快捷命令列表 */
export const QUICK_COMMANDS: string[] = [
  'id',
  'aa dump -l',
  'bm dump -a',
  'power-shell wakeup',
  'power-shell suspend',
  'hidumper -s BatteryService',
  'param get',
  'hilog -T 0x9201 | head -20',
];

/** 日志域 */
export const LOG_DOMAIN = 0x9201;
export const LOG_TAG = 'HMArkPriv';
