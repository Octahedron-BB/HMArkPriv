# HarmonyOS (鸿蒙) Shell 指令全集与特权操作指南

> 本指南针对 **HarmonyOS NEXT / HarmonyOS 5.0+ / 7.0 (HongMeng Microkernel)** 真实设备环境编写，涵盖 UID 2000 (`shell`) 权限下可直接调用的全部系统工具与实用场景。

---

## 目录
1. [鸿蒙 Shell 环境概述](#1-鸿蒙-shell-环境概述)
2. [应用与任务管理 (`aa` / `bm`)](#2-应用与任务管理-aa--bm)
3. [屏幕与电源管理 (`power-shell` / `snapshot_display`)](#3-屏幕与电源管理-power-shell--snapshot_display)
4. [触控模拟与硬件输入 (`uinput` / `sendevent`)](#4-触控模拟与硬件输入-uinput--sendevent)
5. [系统状态与硬件探针 (`hidumper`)](#5-系统状态与硬件探针-hidumper)
6. [系统参数与服务控制 (`param` / `service_control`)](#6-系统参数与服务控制-param--service_control)
7. [日志与性能跟踪 (`hilog` / `hisysevent` / `bytrace`)](#7-日志与性能跟踪-hilog--hisysevent--bytrace)
8. [卓易通 (ANCO 安卓沙盒) 特权穿透实战](#8-卓易通-anco-安卓沙盒-特权穿透实战)
9. [常用 Linux / Toybox 基础命令速查](#9-常用-linux--toybox-基础命令速查)

---

## 1. 鸿蒙 Shell 环境概述

* **执行权限**：UID 2000 (`shell`)，拥有大部分系统管理能力（免 Root）。
* **二进制路径**：`/bin`, `/system/bin`, `/vendor/bin`。
* **基础工具链**：鸿蒙内置经过强化的 `toybox`，提供标准 Linux 命令集。
* **查看基本信息**：
  ```bash
  id                 # 查看当前用户 (uid=2000(shell) gid=2000(shell))
  uname -a           # 查看微内核版本 (HongMeng Kernel x.xx.x)
  echo $PATH         # 查看可执行文件搜索路径
  ```

---

## 2. 应用与任务管理 (`aa` / `bm`)

鸿蒙应用以 **Bundle**（应用包）和 **Ability**（组件能力）为基础单位，对应工具为 `aa` (Ability Assistant) 和 `bm` (Bundle Manager)。

### 2.1 Ability Assistant (`aa`)

#### 启动应用或组件
```bash
# 启动指定应用的入口 Ability
aa start -b <bundle_name> -a <ability_name>

# 示例：启动系统计算器
aa start -b com.huawei.hmos.calculator -a MainAbility

# 示例：启动系统设置
aa start -b com.huawei.hmos.settings -a com.huawei.hmos.settings.MainAbility
```

#### 强制停止应用
```bash
# 强制终止指定包名的所有进程与 Ability
aa force-stop <bundle_name>

# 示例：终止微信
aa force-stop com.tencent.wechat
```

#### 转储运行状态与任务栈
```bash
# 查看当前所有最近任务与前台页面栈（非常实用，可获取正在前台的应用包名）
aa dump -l

# 查看系统当前所有运行中的 Ability 进程列表
aa dump -r

# 查看所有已注册的能力记录
aa dump -a
```

### 2.2 Bundle Manager (`bm`)

#### 查询已安装应用
```bash
# 列出系统已安装的所有应用详细信息
bm dump -a

# 快速提取所有已安装应用的 Bundle Name（包名）
bm dump -a | grep -E 'bundleName|name' | head -n 40

# 查询单个应用的安装路径、权限列表、UID 与 Ability 定义
bm dump -n com.huawei.hmos.settings
```

#### 清理应用数据与缓存
```bash
# 清空指定应用的数据与缓存（相当于设置里的“清除数据”）
bm clean -c -n <bundle_name>    # 清理缓存
bm clean -d -n <bundle_name>    # 清理用户数据
```

#### 应用安装与卸载
```bash
# 安装本地 HAP 包
bm install -p /data/local/tmp/app.hap

# 卸载指定应用
bm uninstall -n <bundle_name>
```

---

## 3. 屏幕与电源管理 (`power-shell` / `snapshot_display`)

### 3.1 电源与常亮管理 (`power-shell`)

鸿蒙原生提供了 `power-shell`，可免无障碍、免开发者选项控制屏幕供电与休眠策略。

```bash
# 1. 唤醒设备（点亮屏幕）
power-shell wakeup

# 2. 熄灭屏幕（使设备进入休眠挂起）
power-shell suspend

# 3. 临时覆盖熄屏时长（实现屏幕常亮，单位：毫秒）
power-shell timeout -o 3600000   # 保持常亮 1 小时 (3600000ms)
power-shell timeout -o 86400000  # 保持常亮 24 小时

# 4. 恢复系统设置中的默认熄屏时长
power-shell timeout -r

# 5. 切换系统电源省电模式
power-shell setmode 600          # 正常模式
power-shell setmode 601          # 省电模式
power-shell setmode 602          # 超级省电模式
```

### 3.2 屏幕截图 (`snapshot_display`)

直接绕过应用层的截屏限制，将当前显示缓冲导出为高质量图片。

```bash
# 截取全屏并保存为 JPEG 图片
snapshot_display -f /storage/media/100/local/files/Docs/Download/screen.jpeg

# 指定屏幕编号（多屏/外接屏场景，默认 0 为主屏）
snapshot_display -d 0 -f /data/local/tmp/screen.png
```

---

## 4. 触控模拟与硬件输入 (`uinput` / `sendevent`)

`uinput` 是鸿蒙 Shell 下最强大的自动化与触控模拟工具，直接向微内核输入子系统注入硬件级事件。

### 4.1 点击模拟 (`-T -c`)
```bash
# 在指定屏幕坐标 (X, Y) 模拟单指轻触
uinput -T -c <x> <y>

# 示例：点击屏幕中心 (以 1260x2844 分辨率为例)
uinput -T -c 630 1422
```

### 4.2 滑动与手势 (`-T -m`)
```bash
# 从坐标 (x1, y1) 平滑滑动到 (x2, y2)，末尾可指定持续时间 (毫秒)
uinput -T -m <x1> <y1> <x2> <y2> [duration_ms]

# 示例 1：右上角下拉呼出控制中心 (从 (1100, 50) 滑动到 (1100, 900)，耗时 250ms)
uinput -T -m 1100 50 1100 900 250

# 示例 2：屏幕向上滑动翻页
uinput -T -m 630 2000 630 600 300

# 示例 3：屏幕底部上滑返回主桌面
uinput -T -m 630 2800 630 2000 200
```

### 4.3 物理按键模拟 (`-K`)
```bash
# 注入物理按键（-d 按下，-u 抬起）
uinput -K -d <keycode> -u <keycode>

# 常用 Keycode 对照表：
#   1  : Home 键
#   2  : Back 返回键
#   3  : Call 拨号键
#   4  : EndCall 挂断键
#   16 : 音量增加 (Volume Up)
#   17 : 音量减少 (Volume Down)
#   18 : 电源键 (Power)

# 示例：模拟点击系统“返回”键
uinput -K -d 2 -u 2

# 示例：音量加 1 格
uinput -K -d 16 -u 16
```

---

## 5. 系统状态与硬件探针 (`hidumper`)

`hidumper` 是鸿蒙系统的全能信息转储器，可用于监控硬件传感器、服务状态及深层参数。

### 5.1 查看支持的系统能力 (System Abilities)
```bash
# 列出当前系统中所有可供查询的系统能力名称
hidumper -ls
```

### 5.2 核心硬件与服务查询
```bash
# 1. 电池与充电状态（电量百分比、充放电状态、电池温度、电压等）
hidumper -s BatteryService

# 2. 个人热点状态（是否激活 active state、热点 SSID、安全类型、已连设备列表）
hidumper -s WifiHotspot

# 3. 窗口管理器信息（当前获焦的前台应用窗口、分屏状态、Display 尺寸）
hidumper -s WindowManagerService

# 4. 网络连接管理器（当前活跃网络接口、默认网关、DNS 解析配置）
hidumper -s NetConnManager

# 5. 内存使用统计（系统总体内存分布，或指定进程 PID 的内存占用）
hidumper --mem
hidumper --mem <pid>

# 6. CPU 实时核心频率与拓扑
hidumper --cpufreq
```

---

## 6. 系统参数与服务控制 (`param` / `service_control`)

### 6.1 参数系统 (`param`)

鸿蒙使用高性能的内存共享参数系统（类似于安卓的 `getprop` / `setprop`）。

```bash
# 1. 获取所有系统参数
param get

# 2. 模糊查询核心设备信息
param get | grep -E 'os.name|model|brand|version.release|cpu'

# 3. 读取单个指定参数
param get const.product.model          # 获取设备型号 (如 ALN-AL10 / HBN-AL80)
param get const.build.version.release  # 获取系统发行版本
param get hw_sc.build.platform.version # 获取 HarmonyOS 核心版本

# 4. 列出所有参数的权限约束
param ls
```

### 6.2 系统服务控制 (`service_control`)
```bash
# 查看并管理鸿蒙 init 注册的系统后台守护进程
service_control start <service_name>
service_control stop <service_name>
```

---

## 7. 日志与性能跟踪 (`hilog` / `hisysevent` / `bytrace`)

### 7.1 系统日志 (`hilog`)
```bash
# 查看实时日志（支持指定 Tag 过滤）
hilog | grep -i "mms"

# 仅抓取指定领域或特定 Tag 的日志缓冲
hilog -x -T <tag_name>

# 清空日志缓冲区
hilog -r
```

### 7.2 性能追踪与事件
```bash
# 抓取 5 秒系统调用栈与渲染性能跟踪 (Trace)
bytrace -t 5 -b 4096 --overwrite ability app > /data/local/tmp/trace.ftrace

# 查询系统关键生命周期事件
hisysevent -l
```

---

## 8. 卓易通 (ANCO 安卓沙盒) 特权穿透实战

在纯血鸿蒙上，卓易通（ANCO）运行于轻量级沙盒容器内。通过宿主 UID 2000 特权，可以直接对容器执行穿透控制：

### 8.1 一键调起卓易通内隐藏的安卓系统设置

卓易通界面内隐藏了许多原生安卓设置，宿主 Shell 可通过 `aa start` 直接将其召唤至前台：

```bash
# 1. 弹出安卓原生【通知使用权 (Notification Access)】列表
#    可为 KDE Connect、短信转发器、MacroDroid、雹 等直接勾选通知权限
aa start -b com.android.settings -a com.android.settings.Settings\$NotificationAccessSettingsActivity

# 2. 打开安卓原生【无障碍 (Accessibility)】设置页
aa start -b com.android.settings -a com.android.settings.Settings\$AccessibilitySettingsActivity

# 3. 打开安卓原生【特殊应用权限】总览
aa start -b com.android.settings -a com.android.settings.Settings\$SpecialAccessSettingsActivity

# 4. 打开安卓原生【应用列表与权限详情】
aa start -b com.android.settings -a com.android.settings.Settings\$ManageApplicationsActivity
```

### 8.2 穿透启动卓易通内的安卓应用
```bash
# 直接唤醒并启动卓易通内安装的任意安卓 APK
aa start -b <android_package_name> -a <main_activity_name>

# 示例：启动卓易通内的短信转发器
aa start -b cn.ppps.forwarder -a cn.ppps.forwarder.activity.MainActivity

# 示例：启动卓易通内的 KDE Connect
aa start -b org.kde.kdeconnect_tp -a org.kde.kdeconnect.UserInterface.MainActivity
```

---

## 9. 常用 Linux / Toybox 基础命令速查

鸿蒙内置了完整的 `toybox` 工具集，支持绝大部分标准 Linux 脚本操作：

| 领域 | 常用命令 | 说明 |
| :--- | :--- | :--- |
| **进程管理** | `ps -ef` / `ps aux` | 查看系统全量进程与所属用户/沙盒 |
| | `kill -9 <pid>` | 强制结束指定进程 |
| | `pidof <name>` | 获取指定进程名的 PID |
| | `pgrep -f <pattern>` | 匹配并查询进程 |
| **网络诊断** | `ifconfig` / `ip addr` | 查看网卡接口与 IP 地址 |
| | `netstat -tlpn` | 查看系统监听中的网络端口与 Socket |
| | `ping -c 3 127.0.0.1` | 测试网络连通性 |
| **文本处理** | `grep -E 'pattern'` | 正则过滤文本 |
| | `sed 's/find/replace/g'` | 行内替换与流编辑 |
| | `paste -sd, file.txt` | 将多行合并为逗号分隔单行 |
| | `cut -d' ' -f1` | 字段截取 |
| **文件系统** | `ls -la /data/local/tmp` | 查看文件属性与权限 |
| | `chmod 755 <file>` | 修改文件执行权限 |
| | `df -h` | 查看各分区存储占用 |
| | `mkdir -p <dir>` | 递归创建目录 |
| **数据库** | `sqlite3 <db_file>` | 直接查询与调试应用数据库 |
