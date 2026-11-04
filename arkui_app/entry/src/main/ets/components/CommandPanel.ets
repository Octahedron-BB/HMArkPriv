/**
 * CommandPanel — 指令手册侧边栏
 *
 * 从右侧滑出，树状展示全部 shell 指令：
 *   分类（可折叠）→ 分组（可折叠）→ 指令项（点击填入终端）
 *
 * 顶部有搜索框，输入关键词实时过滤（匹配命令/说明/分组名）。
 * 搜索结果自动全部展开，方便直接看到命中项。
 */

import { CommandIndex } from '../services/CommandIndex';
import { CommandCategory, CommandGroup, CommandItem } from '../model/CommandDoc';
import { common } from '@kit.AbilityKit';

@Component
export struct CommandPanel {
  /** 点击某条指令时回调，把命令文本交给终端 */
  onPick: (cmd: string) => void = () => {};
  /** 关闭面板 */
  onClose: () => void = () => {};

  @State keyword: string = '';
  @State cats: CommandCategory[] = [];
  @State expandedCats: string[] = [];
  @State expandedGroups: string[] = [];
  @State totalCount: number = 0;
  @State hitCount: number = 0;
  @State isSearching: boolean = false;

  aboutToAppear(): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    const doc = CommandIndex.load(ctx);
    this.totalCount = CommandIndex.totalCount();
    this.hitCount = this.totalCount;
    this.cats = doc.categories;
    // 默认展开第一个分类，给用户一个"能点"的暗示
    if (doc.categories.length > 0) {
      this.expandedCats = [doc.categories[0].name];
    }
  }

  /** 执行搜索 */
  doSearch(kw: string): void {
    this.keyword = kw;
    const trimmed = kw.trim();
    this.isSearching = trimmed.length > 0;
    this.cats = CommandIndex.search(kw);
    this.hitCount = CommandIndex.countOf(this.cats);

    if (this.isSearching) {
      // 搜索时全部展开，直接看到命中项
      const allCats: string[] = [];
      const allGroups: string[] = [];
      for (const c of this.cats) {
        allCats.push(c.name);
        for (const g of c.groups) {
          allGroups.push(`${c.name}::${g.name}`);
        }
      }
      this.expandedCats = allCats;
      this.expandedGroups = allGroups;
    }
  }

  isCatExpanded(name: string): boolean {
    return this.expandedCats.indexOf(name) >= 0;
  }

  isGroupExpanded(cat: string, grp: string): boolean {
    return this.expandedGroups.indexOf(`${cat}::${grp}`) >= 0;
  }

  toggleCat(name: string): void {
    const idx = this.expandedCats.indexOf(name);
    if (idx >= 0) {
      this.expandedCats.splice(idx, 1);
    } else {
      this.expandedCats.push(name);
    }
    // 触发刷新
    this.expandedCats = this.expandedCats.slice();
  }

  toggleGroup(cat: string, grp: string): void {
    const key = `${cat}::${grp}`;
    const idx = this.expandedGroups.indexOf(key);
    if (idx >= 0) {
      this.expandedGroups.splice(idx, 1);
    } else {
      this.expandedGroups.push(key);
    }
    this.expandedGroups = this.expandedGroups.slice();
  }

  build() {
    Column() {
      // ===== 标题栏 =====
      Row() {
        Column() {
          Text('指令手册')
            .fontSize(16)
            .fontColor('#E2E8F0')
            .fontWeight(FontWeight.Bold)
          Text(this.isSearching
            ? `匹配 ${this.hitCount} / ${this.totalCount} 条`
            : `共 ${this.totalCount} 条`)
            .fontSize(10)
            .fontColor('#64748B')
            .margin({ top: 2 })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Text('✕')
          .fontSize(18)
          .fontColor('#94A3B8')
          .padding(8)
          .onClick(() => this.onClose())
      }
      .width('100%')
      .padding({ left: 16, right: 8, top: 12, bottom: 8 })

      // ===== 搜索框 =====
      Row() {
        Text('🔍')
          .fontSize(13)
          .margin({ right: 6 })
        TextInput({ text: this.keyword, placeholder: '搜索命令 / 说明...' })
          .layoutWeight(1)
          .fontSize(12)
          .backgroundColor('#0F172A')
          .fontColor('#38BDF8')
          .placeholderColor('#475569')
          .placeholderFont({ size: 12 })
          .borderRadius(6)
          .onChange((val: string) => this.doSearch(val))
        if (this.keyword.length > 0) {
          Text('✕')
            .fontSize(12)
            .fontColor('#64748B')
            .padding(6)
            .onClick(() => this.doSearch(''))
        }
      }
      .width('100%')
      .padding({ left: 12, right: 12, bottom: 8 })

      Divider().color('#1E293B')

      // ===== 指令树 =====
      if (this.cats.length === 0) {
        Column() {
          Text('未找到匹配的指令')
            .fontSize(13)
            .fontColor('#64748B')
          Text('试试搜索 "aa" / "电池" / "截图"')
            .fontSize(11)
            .fontColor('#475569')
            .margin({ top: 6 })
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        List() {
          ForEach(this.cats, (cat: CommandCategory) => {
            ListItemGroup({ header: this.CatHeader(cat) }) {
              ForEach(cat.groups, (grp: CommandGroup) => {
                if (this.isGroupExpanded(cat.name, grp.name)) {
                  ListItem() {
                    this.GroupHeader(cat.name, grp)
                  }
                  ForEach(grp.items, (it: CommandItem) => {
                    ListItem() {
                      this.CommandRow(it)
                    }
                  }, (it: CommandItem) => `${cat.name}::${grp.name}::${it.cmd}`)
                } else {
                  ListItem() {
                    this.GroupHeader(cat.name, grp)
                  }
                }
              }, (grp: CommandGroup) => `${cat.name}::${grp.name}`)
            }
          }, (cat: CommandCategory) => cat.name)
        }
        .layoutWeight(1)
        .width('100%')
        .scrollBar(BarState.Auto)
        .cachedCount(3)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#141C2B')
    .borderRadius({ topLeft: 16, bottomLeft: 16 })
    .shadow({ radius: 20, color: '#000000CC', offsetX: -4, offsetY: 0 })
  }

  /** 分类头（一级，可折叠） */
  @Builder
  CatHeader(cat: CommandCategory) {
    Row() {
      Text(this.isCatExpanded(cat.name) ? '▾' : '▸')
        .fontSize(12)
        .fontColor('#38BDF8')
        .width(16)
      Text(cat.name)
        .fontSize(13)
        .fontColor('#38BDF8')
        .fontWeight(FontWeight.Bold)
        .layoutWeight(1)
      Text(`${cat.groups.length}`)
        .fontSize(10)
        .fontColor('#475569')
    }
    .width('100%')
    .padding({ left: 12, right: 16, top: 10, bottom: 10 })
    .backgroundColor('#0D1527')
    .onClick(() => this.toggleCat(cat.name))
  }

  /** 分组头（二级，可折叠） */
  @Builder
  GroupHeader(catName: string, grp: CommandGroup) {
    Row() {
      Text(this.isGroupExpanded(catName, grp.name) ? '▾' : '▸')
        .fontSize(11)
        .fontColor('#82B1FF')
        .width(14)
      Text(grp.name)
        .fontSize(12)
        .fontColor('#82B1FF')
        .layoutWeight(1)
      Text(`${grp.items.length}`)
        .fontSize(10)
        .fontColor('#475569')
    }
    .width('100%')
    .padding({ left: 20, right: 16, top: 8, bottom: 8 })
    .backgroundColor('#101827')
    .onClick(() => this.toggleGroup(catName, grp.name))
  }

  /** 指令行（点击填入终端） */
  @Builder
  CommandRow(it: CommandItem) {
    Column() {
      Row() {
        Text(it.cmd)
          .fontSize(12)
          .fontColor('#C3E88D')
          .fontFamily('JetBrains Mono, Consolas, monospace')
          .layoutWeight(1)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        // 未验证标记
        if (it.tags && it.tags.indexOf('未验证') >= 0) {
          Text('?')
            .fontSize(9)
            .fontColor('#FBBF24')
            .backgroundColor('#2A2415')
            .borderRadius(3)
            .padding({ left: 4, right: 4, top: 1, bottom: 1 })
            .margin({ left: 4 })
        }
      }
      .width('100%')

      if (it.desc) {
        Text(it.desc)
          .fontSize(10)
          .fontColor('#64748B')
          .margin({ top: 2 })
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .padding({ left: 36, right: 16, top: 8, bottom: 8 })
    .onClick(() => {
      this.onPick(it.cmd);
    })
  }
}
