/**
 * CommandDoc — 指令手册数据模型
 *
 * 数据源：resources/rawfile/commands.json
 * 生成方式：scripts/gen-commands-json.py 从 docs/HarmonyOS-Shell-指令全集.md 提取
 *
 * 结构：分类(Category) → 分组(Group) → 指令项(Item)
 * 例如：应用与任务管理 → 2.1 Ability Assistant（aa） → [aa help, aa start, ...]
 */

export interface CommandItem {
  /** 命令文本，点击后填入终端输入框 */
  cmd: string;
  /** 说明 */
  desc: string;
  /** 验证来源标注：官方 / 社区 / 实机 / 未验证 */
  tags?: string[];
}

export interface CommandGroup {
  /** 分组名，如 "2.1 Ability Assistant（aa）" */
  name: string;
  items: CommandItem[];
  tags?: string[];
}

export interface CommandCategory {
  /** 分类名，如 "应用与任务管理（aa / bm）" */
  name: string;
  groups: CommandGroup[];
}

export interface CommandDoc {
  categories: CommandCategory[];
}

/** 展开状态：分组名的集合 */
export type ExpandedSet = Set<string>;
