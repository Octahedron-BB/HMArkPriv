/**
 * CommandIndex — 指令手册索引服务
 *
 * 从 resources/rawfile/commands.json 加载全部 shell 指令，
 * 提供加载、搜索、统计能力。结果在内存中缓存，只解析一次。
 */

import { util } from '@kit.ArkTS';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { CommandDoc, CommandCategory, CommandGroup, CommandItem } from '../model/CommandDoc';

const DOMAIN = 0x9201;
const TAG = 'CommandIndex';
const RAW_FILE = 'commands.json';

export class CommandIndex {
  private static doc: CommandDoc | null = null;
  private static loading: boolean = false;

  /** 同步加载（首次调用解析 JSON，之后走缓存） */
  static load(context: common.UIAbilityContext): CommandDoc {
    if (CommandIndex.doc) {
      return CommandIndex.doc;
    }
    try {
      const bytes: Uint8Array = context.resourceManager.getRawFileContentSync(RAW_FILE);
      const text: string = util.TextDecoder.create('utf-8').decodeToString(bytes);
      const parsed = JSON.parse(text) as CommandDoc;
      CommandIndex.doc = parsed;
      hilog.info(DOMAIN, TAG, `loaded ${CommandIndex.totalCount()} commands in ${CommandIndex.categoryCount()} categories`);
      return parsed;
    } catch (err) {
      hilog.error(DOMAIN, TAG, `load rawfile failed: ${err}`);
      CommandIndex.doc = { categories: [] };
      return CommandIndex.doc;
    }
  }

  /** 总指令数 */
  static totalCount(): number {
    if (!CommandIndex.doc) {
      return 0;
    }
    let n = 0;
    for (const c of CommandIndex.doc.categories) {
      for (const g of c.groups) {
        n += g.items.length;
      }
    }
    return n;
  }

  /** 分类数 */
  static categoryCount(): number {
    return CommandIndex.doc ? CommandIndex.doc.categories.length : 0;
  }

  /**
   * 按关键词过滤，返回裁剪后的分类树。
   * 匹配范围：命令文本 / 说明 / 分组名。
   * 空关键词返回完整数据。
   */
  static search(keyword: string): CommandCategory[] {
    if (!CommandIndex.doc) {
      return [];
    }
    const kw = keyword.trim().toLowerCase();
    if (!kw) {
      return CommandIndex.doc.categories;
    }

    const result: CommandCategory[] = [];
    for (const cat of CommandIndex.doc.categories) {
      // 分类名命中时，整分类的所有条目都算命中
      const catHit = cat.name.toLowerCase().includes(kw);
      const groups: CommandGroup[] = [];
      for (const g of cat.groups) {
        const groupHit = catHit || g.name.toLowerCase().includes(kw);
        const items: CommandItem[] = [];
        for (const it of g.items) {
          if (groupHit ||
              it.cmd.toLowerCase().includes(kw) ||
              it.desc.toLowerCase().includes(kw)) {
            items.push(it);
          }
        }
        if (items.length > 0) {
          const ng: CommandGroup = { name: g.name, items: items };
          if (g.tags) {
            ng.tags = g.tags;
          }
          groups.push(ng);
        }
      }
      if (groups.length > 0) {
        result.push({ name: cat.name, groups: groups });
      }
    }
    return result;
  }

  /** 搜索结果里的指令总数 */
  static countOf(cats: CommandCategory[]): number {
    let n = 0;
    for (const c of cats) {
      for (const g of c.groups) {
        n += g.items.length;
      }
    }
    return n;
  }
}
