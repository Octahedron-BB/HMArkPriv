#!/usr/bin/env python3
"""
从 docs/HarmonyOS-Shell-指令全集.md 提取结构化指令数据，
生成 arkui_app/entry/src/main/resources/rawfile/commands.json 供 App 侧边栏使用。

提取规则：
  1. 按 ## 分大分类，### 分子分组
  2. 表格行 `| \`cmd\` | desc | tag |` → 指令项
  3. bash 代码块内 `cmd   # desc` 或上方独立注释 `# desc` → 指令项
  4. 过滤 hdc 开头的（那是电脑端，手机端执行不了）
  5. 标注 [未验证] 的单独打标

用法：python3 arkui_app/scripts/gen-commands-json.py
"""

import json
import os
import re

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.abspath(os.path.join(SCRIPT_DIR, '..', '..'))

SRC = os.path.join(PROJECT_ROOT, 'docs', 'HarmonyOS-Shell-指令全集.md')
OUT = os.path.join(PROJECT_ROOT, 'arkui_app', 'entry', 'src', 'main', 'resources', 'rawfile', 'commands.json')

# 手机端不可用的前缀（这些是电脑端 hdc 命令）
SKIP_PREFIX = ('hdc ', 'adb ', 'hdc.exe')

# 命令白名单：命令的第一个词必须在此列表内，否则视为参数碎片丢弃
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
    长度限制在 70 字符内，适配侧边栏显示。
    """
    for ln in lines:
        if ln.startswith('作用'):
            v = re.sub(r'^作用（?[^）]*）?[：:]\s*', '', ln)
            return v[:70]
    for ln in lines:
        if ln and not ln.startswith(('✅', '❌', '⚠️', '❓', '├', '└')):
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


CUSTOM_CLEAN = {
    '显式启动（推荐，需要 bundleName + abilityName）：': '显式启动应用组件',
    '隐式启动（通过 URI / Action）[官方]：': 'URI/Action 隐式启动',
    '查看系统当前所有运行中的 Ability 进程列表': '查看运行中 Ability 列表',
    '查看当前所有最近任务与前台页面栈': '查看最近任务与前台栈',
    '查看指定 Ability 详细信息': '查看指定 Ability 详情',
    '2.1.5 测试框架 [官方]': '启动单元测试框架',
    '文本输入（仅 ASCII，最大 2000 字符）': '模拟输入文本',
    '捏合 (<100 缩小, >100 放大)': '双指捏合缩放',
    '方向滑动 (0=左 1=右 2=上 3=下)': '按指定方向滑动',
    'Ability 管理器（替代 aa dump）': '查询 Ability 管理器',
    '直接生成标准的 aa start 启动指令列表': '提取前台启动指令',
    '方法 B：延时 3 秒精准抓取当前屏幕应用（解决前台切换问题）': '延时 3 秒抓取前台',
    '1. 打开容器内应用管理列表（查看所有已装应用、存储占用、版本、强停与卸载）': '打开容器应用管理',
    '2. 打开容器内“通知使用权”授权页（直接在列表勾选短信转发器/KDE Connect）': '打开容器通知使用权',
    '3. 打开容器内特殊访问权限设置总览': '打开容器特殊权限',
    '实测输出（毫秒级返回，直接复制可用）：': '启动应用组件',
    '包名 + 应用名称（label）': '包名与应用名称',
    '按级别过滤 (D/I/W/E/F)': '按级别过滤日志',
    '抓性能trace.ftrace': '抓取性能 Trace',
    '示例：带 moduleName': '指定模块启动',
    '屏幕状态 AWAKE/SLEEP': '查询屏幕电源状态',
}


def polish_desc(cmd, desc):
    """精简注释，言简意赅表达核心动作（控制在 16 字内）"""
    desc = clean(desc)
    if desc in CUSTOM_CLEAN:
        return CUSTOM_CLEAN[desc]

    # 命令特征匹配（最准确简明）
    if 'com.aistra.hail' in cmd:
        return '启动小黑屋 (Hail)'
    if 'NotificationAccessSettings' in cmd:
        return '打开容器通知使用权'
    if 'SpecialAccessSettings' in cmd:
        return '打开容器特殊权限'
    if 'ManageApplications' in cmd:
        return '打开容器应用管理'
    if 'com.easy.abroad' in cmd:
        return '启动出境易'
    if 'kdeconnect' in cmd:
        return '启动 KDE Connect'
    if 'grep -oE' in cmd and 'aa start' in cmd:
        return '提取前台启动指令'
    if 'dumpLayout' in cmd and 'sleep 3' in cmd:
        return '延时抓取前台包名'
    if 'dumpLayout' in cmd and '-w' in cmd:
        return '转储焦点窗口布局'
    if 'dumpLayout' in cmd:
        return '转储屏幕布局'
    if 'MemoryManagerService' in cmd:
        return '查询内存服务状态'
    if 'AbilityManagerService' in cmd:
        return '查询 Ability 服务'
    if 'uinput -T -c 630 1422' in cmd:
        return '单击指定屏幕坐标'
    if 'uinput -T -m 1100 50' in cmd:
        return '下拉控制中心示例'
    if 'uinput -T -m 300 900' in cmd:
        return '多指连续滑动长按'
    if 'uinput -K -l' in cmd:
        return '长按物理按键'
    if 'uinput -K -r' in cmd:
        return '连击物理按键'
    if 'uinput -K -i' in cmd:
        return '设置按键事件间隔'
    if 'uinput -T -i' in cmd:
        return '设置触控事件间隔'
    if 'uinput -T -g' in cmd:
        return '双点拖拽手势'
    if 'aa test' in cmd:
        return '启动单元测试框架'
    if 'aa dump -p' in cmd:
        return '查看待挂起任务'
    if 'aa dump -e' in cmd:
        return '查看指定元素信息'
    if 'aa dump -a' in cmd:
        return '查看所有组件状态'
    if 'aa start -b com.example.app' in cmd:
        return '指定模块启动应用'
    if 'aa start -b com.huawei.hmos.calculator' in cmd:
        return '启动系统计算器'
    if 'aa start -b com.huawei.hmos.settings' in cmd:
        return '启动系统设置'
    if 'aa start -A ohos.want.action.viewData' in cmd:
        return '浏览器打开网页'
    if 'aa start -U kwai://home' in cmd:
        return 'Schema 唤起快手'
    if 'aa start -U myscheme' in cmd:
        return '带参数启动应用'
    if 'aa force-stop' in cmd:
        return '强制停止应用进程'
    if 'aa stop-service' in cmd:
        return '停止 Service 组件'

    # 去掉冗余前缀和括号说明
    desc = re.sub(r'^(示例|方法\s*[A-Z]|步骤\s*\d|[0-9]+[\.、])\s*[：:]?\s*', '', desc)
    desc = re.sub(r'（[^）]*）', '', desc)
    desc = re.sub(r'\([^)]*\)', '', desc)
    desc = desc.strip(' ：:，,。')

    if len(desc) > 16:
        desc = desc[:16]
    return desc


def main():
    if not os.path.exists(SRC):
        print(f'[!] 找不到源文件: {SRC}')
        return

    with open(SRC, 'r', encoding='utf-8') as f:
        lines = f.read().split('\n')

    categories = []          # [{name, groups:[{name, items:[{cmd,desc,tags}]}]}]
    cur_cat = None           # 当前大分类
    cur_grp = None           # 当前子分组
    in_code = False
    cur_h2 = ''
    last_subheading = ''
    box_desc = []
    preceding_comment = ''
    preceding_tags = []

    def ensure_group(name=''):
        nonlocal cur_cat, cur_grp
        if cur_cat is None:
            cur_cat = {'name': cur_h2 or '其他', 'groups': []}
            categories.append(cur_cat)
        if cur_grp is None:
            display = name or cur_cat['name'] or '其他'
            cur_grp = {'name': display, 'items': []}
            cur_cat['groups'].append(cur_grp)
        return cur_grp

    def add_item(cmd, desc, tags):
        cmd = cmd.strip()
        if not cmd or cmd.startswith(SKIP_PREFIX) or cmd in ('...', '…') or len(cmd) < 2:
            return
        first = cmd.split()[0]
        if '/' in first:
            first = first.rsplit('/', 1)[-1]
        if first not in KNOWN_CMDS:
            return
        g = ensure_group()
        for it in g['items']:
            if it['cmd'] == cmd:
                # 若旧项没有 desc 但新传入有 desc，则补充
                if not it.get('desc') and desc:
                    it['desc'] = polish_desc(cmd, desc)
                    if tags:
                        it['tags'] = tags
                return
        item = {'cmd': cmd, 'desc': polish_desc(cmd, desc)}
        if tags:
            item['tags'] = tags
        g['items'].append(item)

    for raw in lines:
        line = raw.rstrip()

        # 代码块开关
        if line.startswith('```'):
            in_code = not in_code
            if not in_code:
                box_desc = []
                preceding_comment = ''
                preceding_tags = []
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
            last_subheading = ''
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
            pure, tags = extract_tags(title)
            cur_grp = {'name': pure}
            if tags:
                cur_grp['tags'] = tags
            cur_grp['items'] = []
            cur_cat['groups'].append(cur_grp)
            last_subheading = pure
            continue

        # 4 级小节 ####
        if line.startswith('#### '):
            last_subheading = clean(line[5:])
            continue

        # 段落加粗标题 **显式启动**
        if line.startswith('**') and ('：' in line or line.endswith('**')):
            last_subheading = clean(line)
            continue

        # 代码块内
        if in_code:
            stripped = line.strip()

            # ---- 框式注释块 ----
            if stripped.startswith('#') and any(c in stripped for c in ('┌', '├', '│', '└')):
                m_box = re.match(r'^#\s*│\s*(.*?)\s*│?\s*$', stripped)
                if m_box:
                    content = m_box.group(1).strip()
                    if content and not re.match(r'^[─-]+$', content):
                        box_desc.append(content)
                continue

            # ---- 普通独立注释行 ----
            if stripped.startswith('#'):
                c_text = stripped.lstrip('#').strip()
                if c_text and not re.match(r'^[─=-]+$', c_text):
                    pure_c, c_tags = extract_tags(c_text)
                    preceding_comment = pure_c
                    preceding_tags = c_tags
                continue

            # ---- 命令行（带行内 # 注释）----
            m = re.match(r'^\s*([a-zA-Z_][\w\.-]*(?:\s+[^#]*?)?)\s*#\s*(.+)$', line)
            if m:
                cmd = m.group(1).strip()
                desc_raw = m.group(2).strip()
                desc, tags = extract_tags(desc_raw)
                if box_desc:
                    desc = make_summary(box_desc)
                    box_desc = []
                add_item(cmd, desc, tags)
                preceding_comment = ''
                preceding_tags = []
                continue
            else:
                # ---- 没有行内注释的命令行 ----
                if stripped:
                    first = stripped.split()[0] if stripped.split() else ''
                    if re.match(r'^[a-z_][\w\./-]*$', first) and first not in (
                            'if', 'then', 'else', 'fi', 'for', 'do', 'done', 'echo', 'export'):
                        if box_desc:
                            desc = make_summary(box_desc)
                            tags = []
                            box_desc = []
                        elif preceding_comment:
                            desc = preceding_comment
                            tags = preceding_tags
                        elif last_subheading:
                            desc = last_subheading
                            tags = []
                        else:
                            desc = cur_grp['name'] if cur_grp else ''
                            tags = []
                        add_item(stripped, desc, tags)
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
