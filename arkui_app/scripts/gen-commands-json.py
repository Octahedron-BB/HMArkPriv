#!/usr/bin/env python3
"""
从 docs/HarmonyOS-Shell-指令全集.md 提取结构化指令数据，
生成 arkui-app/entry/src/main/resources/rawfile/commands.json 供 App 侧边栏使用。

提取规则：
  1. 按 ## 分大分类，### 分子分组
  2. 表格行 `| \`cmd\` | desc | tag |` → 指令项
  3. bash 代码块内 `cmd   # desc` → 指令项
  4. 过滤 hdc 开头的（那是电脑端，手机端执行不了）
  5. 标注 [未验证] 的单独打标

用法：python scripts/gen-commands-json.py
"""

import json
import os
import re

SRC = 'docs/HarmonyOS-Shell-指令全集.md'
OUT = 'arkui-app/entry/src/main/resources/rawfile/commands.json'

# 手机端不可用的前缀（这些是电脑端 hdc 命令）
SKIP_PREFIX = ('hdc ', 'adb ', 'hdc.exe')

# 命令白名单：命令的第一个词必须在此列表内，否则视为参数碎片丢弃
# （指令全集的详细参数小节里有大量 `-A <action>`、`-e <entity>` 这类片段，
#   单独展开到终端没有意义，必须在提取阶段滤掉）
KNOWN_CMDS = {
    # 鸿蒙专有工具
    'aa', 'bm', 'hidumper', 'uinput', 'uitest', 'power-shell', 'snapshot_display',
    'param', 'hilog', 'hisysevent', 'bytrace', 'SP_daemon', 'service_control',
    # Toybox / Linux 常用
    'ps', 'kill', 'killall', 'ls', 'cat', 'grep', 'chmod', 'chown', 'mkdir', 'rmdir',
    'rm', 'cp', 'mv', 'find', 'tar', 'gzip', 'gunzip', 'sqlite3', 'df', 'du', 'free',
    'head', 'tail', 'sed', 'awk', 'wc', 'sort', 'uniq', 'cut', 'tr', 'xargs',
    'netstat', 'ifconfig', 'ping', 'curl', 'wget', 'ip', 'iptables',
    'date', 'uptime', 'id', 'whoami', 'uname', 'echo', 'env', 'which', 'pidof',
    'md5sum', 'sha256sum', 'sh', 'timeout', 'sleep', 'top', 'mount', 'umount',
    'dmesg', 'touch', 'ln', 'stat', 'file', 'diff', 'tee', 'readlink', 'realpath',
    'nohup', 'pwd', 'clear', 'logout', 'setenforce', 'getenforce',
}

# 章节标题里出现这些词的，整节跳过（不是命令手册内容）
SKIP_SECTIONS = ('验证来源标注体系', '重要说明', '目录', '附录')


def clean(s):
    """清理 markdown 标记，保留纯文本"""
    s = re.sub(r'\*\*(.+?)\*\*', r'\1', s)      # 去粗体
    s = re.sub(r'`([^`]+)`', r'\1', s)          # 去反引号
    s = re.sub(r'\[([^\]]+)\]\([^)]*\)', r'\1', s)  # 去链接
    return s.strip()


def make_summary(lines):
    """
    把框式注释块的多行内容压成一句摘要。
    优先取「作用：」那行，否则取第一行有意义的文字。
    长度限制在 60 字符内，适配侧边栏显示。
    """
    # 优先找 "作用：" 开头
    for ln in lines:
        if ln.startswith('作用'):
            # 去掉 "作用：" 或 "作用（理论）："
            v = re.sub(r'^作用（?[^）]*）?[：:]\s*', '', ln)
            return v[:70]
    # 其次找第一行非标题行
    for ln in lines:
        if ln and not ln.startswith('✅') and not ln.startswith('❌') and \
           not ln.startswith('⚠️') and not ln.startswith('❓') and \
           not ln.startswith('├') and not ln.startswith('└'):
            return ln[:70]
    return ''


def extract_tags(text):
    """提取验证来源标注，返回 (纯净文本, tags)"""
    tags = []
    for t in ('官方', '社区', '实机', '未验证'):
        if f'[{t}]' in text:
            tags.append(t)
            text = text.replace(f'[{t}]', '')
    return text.strip(), tags


def main():
    with open(SRC, 'r', encoding='utf-8') as f:
        lines = f.read().split('\n')

    categories = []          # [{name, groups:[{name, items:[{cmd,desc,tags}]}]}]
    cur_cat = None           # 当前大分类
    cur_grp = None           # 当前子分组
    in_code = False
    cur_h2 = ''

    def ensure_group(name=''):
        nonlocal cur_cat, cur_grp
        if cur_cat is None:
            cur_cat = {'name': cur_h2 or '其他', 'groups': []}
            categories.append(cur_cat)
        if cur_grp is None:
            # 组名为空时用分类名兜底，避免侧边栏出现空白分组标题
            display = name or cur_cat['name'] or '其他'
            cur_grp = {'name': display, 'items': []}
            cur_cat['groups'].append(cur_grp)
        return cur_grp

    # 框式注释缓冲区：收集 `# ┌───┐ ... # └───┘` 块里的说明文字
    box_desc = []

    def add_item(cmd, desc, tags):
        cmd = cmd.strip()
        if not cmd or cmd.startswith(SKIP_PREFIX):
            return
        # 过滤纯占位符
        if cmd in ('...', '…') or len(cmd) < 2:
            return
        # 白名单校验：首个词必须是已知命令，否则是参数碎片
        first = cmd.split()[0]
        # 允许带路径前缀的（如 /system/bin/aa）
        if '/' in first:
            first = first.rsplit('/', 1)[-1]
        if first not in KNOWN_CMDS:
            return
        g = ensure_group()
        # 去重（同一分组内）
        for it in g['items']:
            if it['cmd'] == cmd:
                return
        item = {'cmd': cmd, 'desc': clean(desc)}
        if tags:
            item['tags'] = tags
        g['items'].append(item)

    for raw in lines:
        line = raw.rstrip()

        # 代码块开关
        if line.startswith('```'):
            in_code = not in_code
            continue

        # 大分类 ##
        if line.startswith('## ') and not line.startswith('### '):
            title = clean(line[3:])
            if any(k in title for k in SKIP_SECTIONS):
                cur_cat = None
                cur_grp = None
                cur_h2 = ''
                continue
            cur_h2 = title
            cur_cat = None
            cur_grp = None
            continue

        # 子分组 ###
        if line.startswith('### '):
            title = clean(line[4:])
            if any(k in title for k in SKIP_SECTIONS):
                cur_grp = None
                continue
            if cur_cat is None:
                if not cur_h2:
                    continue
                cur_cat = {'name': cur_h2, 'groups': []}
                categories.append(cur_cat)
            # 去掉标题里的 [实机] 等标注
            pure, tags = extract_tags(title)
            cur_grp = {'name': pure}
            if tags:
                cur_grp['tags'] = tags
            cur_grp['items'] = []
            cur_cat['groups'].append(cur_grp)
            continue

        # 代码块内：`cmd  # desc`
        if in_code:
            stripped = line.strip()

            # ---- 框式注释块：收集 ┌ ... └ 之间的文字 ----
            if stripped.startswith('#') and ('┌' in stripped or '├' in stripped or
                                             '│' in stripped or '└' in stripped):
                # 提取 │ 后面的内容
                m_box = re.match(r'^#\s*│\s*(.*?)\s*│?\s*$', stripped)
                if m_box:
                    content = m_box.group(1).strip()
                    # 去掉纯分隔线
                    if content and not re.match(r'^[─-]+$', content):
                        box_desc.append(content)
                continue

            # ---- 命令行 ----
            m = re.match(r'^\s*([a-zA-Z_][\w\.-]*(?:\s+[^#]*?)?)\s*#\s*(.+)$', line)
            if m:
                cmd = m.group(1).strip()
                desc_raw = m.group(2).strip()
                desc, tags = extract_tags(desc_raw)
                # 若有框式注释，优先用它（更详细）
                if box_desc:
                    desc = make_summary(box_desc)
                    box_desc = []
                add_item(cmd, desc, tags)
                continue
            else:
                # 没有行内注释的纯命令行
                if stripped and not stripped.startswith('#'):
                    first = stripped.split()[0] if stripped.split() else ''
                    if re.match(r'^[a-z_][\w\./-]*$', first) and first not in (
                            'if', 'then', 'else', 'fi', 'for', 'do', 'done', 'echo', 'export'):
                        desc = make_summary(box_desc) if box_desc else ''
                        box_desc = []
                        add_item(stripped, desc, [])
            continue

        # 表格行：| `cmd` | desc | tag |
        if line.startswith('|') and '`' in line:
            cells = [c.strip() for c in line.strip('|').split('|')]
            if len(cells) >= 2:
                cmd_cell = cells[0]
                m = re.search(r'`([^`]+)`', cmd_cell)
                if m:
                    cmd = m.group(1)
                    desc = cells[1]
                    tagcell = cells[2] if len(cells) > 2 else ''
                    _, tags = extract_tags(desc + ' ' + tagcell)
                    desc_pure, _ = extract_tags(desc)
                    add_item(cmd, desc_pure, tags)
            continue

    # 清理空分组
    result = []
    for cat in categories:
        groups = [g for g in cat['groups'] if g.get('items')]
        if groups:
            result.append({'name': cat['name'], 'groups': groups})

    total = sum(len(g['items']) for c in result for g in c['groups'])
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, 'w', encoding='utf-8') as f:
        json.dump({'categories': result}, f, ensure_ascii=False, indent=2)

    print(f'分类数: {len(result)}')
    for c in result:
        n = sum(len(g['items']) for g in c['groups'])
        print(f'  {c["name"]}: {len(c["groups"])} 组 / {n} 条')
    print(f'总计: {total} 条指令')
    print(f'输出: {OUT}')


if __name__ == '__main__':
    main()
