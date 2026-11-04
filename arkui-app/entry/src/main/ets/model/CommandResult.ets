/**
 * 命令执行结果模型
 */
export interface CommandResult {
  /** 是否成功（exitCode === 0） */
  success: boolean;
  /** 退出码 */
  exitCode: number;
  /** 命令输出 */
  output: string;
  /** daemon 返回的时间戳 */
  timestamp: string;
  /** 执行耗时（毫秒） */
  durationMs: number;
}

/**
 * Daemon 状态信息
 */
export interface DaemonStatus {
  /** 框架标识 */
  framework: string;
  /** 状态：ready / stopped */
  status: string;
  /** daemon 进程 PID */
  pid: number;
  /** daemon 运行 UID（应为 2000） */
  uid: number;
}

/**
 * 创建失败结果
 */
export function createFailedResult(output: string, durationMs: number = 0): CommandResult {
  return {
    success: false,
    exitCode: -1,
    output,
    timestamp: '',
    durationMs,
  };
}
