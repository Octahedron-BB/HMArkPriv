/**
 * HMArkPriv 常量定义
 */

/** 文件总线默认目录（daemon.sh 监听的路径） */
export const DEFAULT_BUS_DIR = '/storage/media/100/local/files/Docs/Download/HMArkPriv';
export const APP_BUS_DIR = '/storage/Users/currentUser/Download/HMArkPriv';

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
export const BUS_FILE_AUDIT = 'audit.log';
export const BUS_FILE_TOKENS = 'tokens.txt';
export const BUS_FILE_CONFIG = 'config.json';

/** 轮询间隔（毫秒） */
export const POLL_INTERVAL_MS = 50;

/**
 * 响应超时（毫秒）
 *
 * 【为什么是 30 秒而不是 5 秒】
 * daemon 侧对单条命令的超时是 `timeout -k 5 20`：20 秒后 SIGTERM，
 * 再 5 秒 SIGKILL，即最长 25 秒才会返回。如果 App 只等 5 秒，
 * 任何耗时超过 5 秒的命令（bm dump -a -l 要约 2-3 秒，
 * 复杂管道、hidumper 表格解析更久）都会在这 5 秒内"超时"，
 * 但 daemon 其实还在正常执行 —— 这就是"偶尔好用偶尔超时"的根因。
 *
 * 30 秒 = daemon 的 25 秒上限 + 5 秒网络/文件系统余量。
 */
export const TIMEOUT_MS = 30000;

/** 最大轮询次数 */
export const MAX_POLL_ATTEMPTS = TIMEOUT_MS / POLL_INTERVAL_MS; // 600

/**
 * 「疑似无响应」阈值（毫秒）
 * 超过这个时间还没结果，UI 提示用户"命令仍在执行中"，
 * 避免用户以为卡死而反复点击（会加剧排队）。
 */
export const SLOW_HINT_MS = 3000;

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
