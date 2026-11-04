# 真机 vs 模拟器 Shell 指令差异报告

> 真机：Pura 70 Pro+ / HBN-AL80 / HarmonyOS 7.0.0.109(SP8C00E105R4P2) / API 26 / arm64-v8a
> 模拟器：Mate 70 Pro+ / HarmonyOS 7.0.0.107 / API 26 / x86_64
> 验证链路：文件总线（cmd.req / cmd.res），与 App 完全相同
> 逐条明细：[`真机指令验证明细.md`](真机指令验证明细.md)
> 日期：2026-11-04

---

## 一、总体结果

真机共验证 **60 条**命令，**57 通过**，3 条"失败"全部是**目标本身不存在**（不是命令失效）：

| 失败项 | 原因 |
|--------|------|
| `awk` | 真机 toybox 未内置 |
| `bm dump -a \| grep -ci android` | 真机无安卓容器（返回 0） |
| `bm dump -a \| grep -ci anco` | 真机无 ANCO（返回 0） |

---

## 二、本轮新增验证（之前模拟器无法验证的）

### 2.1 `power-shell setmode` 语义 —— ✅ 已确认生效

这是之前一直标注 `[未验证]` 的命令。真机上用 hilog 抓到了铁证：

```bash
power-shell setmode 601
→ hilog: powermgr/PowerMode: GetDeviceMode: pid: 953, uid: 1096, mode: 601

power-shell setmode 600
→ hilog: powermgr/PowerMode: GetDeviceMode: pid: 58404, uid: 2000, mode: 600
```

**结论**：
- `setmode 600` / `601` 真实修改了系统 PowerMode（值精确对应）
- 第二条日志里 `uid: 2000` 就是我们的 daemon，确认是我们触发的
- 另有 `anco_service_broker/Broker: ConvertPowerMode` 参与，说明存在模式转换层
- 有一条告警 `StandbyService: policy 600 not found in policy cache`，但不影响设置生效

> 602（超级省电）同样返回 RC=0，语义应与 601 一致，但未单独抓日志验证。

### 2.2 `hidumper -s <Service>` —— ❌ 确认不可用（非参数问题）

之前怀疑是参数不对，本轮彻底查清：

```bash
# 1. 帮助确实存在（说明 -a 参数被接受）
hidumper -s BatteryService -a '-h'
→ Usage: -h: dump help / -i: dump battery info

# 2. 用正确参数仍然只有标题
hidumper -s BatteryService -a '-i'
→ 只输出两行标题，无任何字段

# 3. 长度统计确认
$() 捕获: LEN=163（正好是两个标题行的长度）
```

**结论**：`hidumper -s <Service>` 在 shell（uid 2000）权限下拿不到 dump 内容，
不是参数问题，是权限/服务限制。**Phase 5 系统信息必须走 `@ohos.*` 原生 API。**

同一台机器上 `hidumper -ls`（84 个服务）、`--cpufreq`、`--cpuusage` 都能正常拿到数据，
只有 `-s <Service>` 这类 service dump 不行。

### 2.3 `aa dump -l` —— ❌ 确认输出不可捕获

```bash
# 直连 hdc（不经 shell 捕获）→ 能看到完整任务栈
aa dump -l
→ User ID #100 / current mission lists:{ Mission ID #789 ... bundle name [com.tencent.wechat] ...

# 命令替换 $() → 完全空
O=$(aa dump -l 2>&1); echo ${#O}
→ 0
```

**结论**：与模拟器一致。`aa dump` 系列输出走 pty/console，绕过 stdout，
daemon 的 `$()` 无法捕获。**已用 `uitest dumpLayout` 替代（已实现）。**

### 2.4 卓易通（ANCO）—— ❌ 真机同样没有

```bash
bm dump -a | grep -ci android  → 0
bm dump -a | grep -ci anco     → 0
bm dump -a | grep -iE 'anco|yitong|container|vmos|virtual'  → 无匹配
```

进一步核查了所有第三方包（排除 huawei/ohos 前缀），全部是正常鸿蒙原生应用
（canva、大麦、丁香园、WPS、支付宝、高德、各大银行等），
其中 `com.droi.tong` 经 `bm dump -n` 确认是普通 `app_gallery` 应用，不是容器。

**结论**：这台真机没装卓易通。相关穿透命令（`aa start -b com.android.settings ...`）
无法验证，需要用户安装卓易通后单独测试。

---

## 三、真机 vs 模拟器的关键差异

### 3.1 内核信息不同

| | 输出 |
|---|---|
| 模拟器 | `Linux localhost 5.10.210 #1 SMP ... x86_64 Toybox` |
| 真机 | `HarmonyOS localhost HongMeng Kernel 1.13.0 #1 SMP ... aarch64` |

真机跑的是鸿蒙自研内核（HongMeng Kernel 1.13.0），不是 Linux。
这解释了为什么很多 Linux 工具行为不同。

### 3.2 toybox 工具集裁剪更严重

| 工具 | 模拟器 | 真机 |
|------|--------|------|
| `tr` | ✅ | ❌ **缺失** |
| `awk` | ❌ | ❌ |
| `cut` `sed` `grep` `sort` `uniq` `xargs` `tee` | — | ✅ |
| `find` `du` `df` `free` `ps` `pidof` `md5sum` | — | ✅ |
| `netstat` `ifconfig` `ping` | — | ✅ |
| `sqlite3` `tar` `gzip` | — | ✅ |
| `curl` `wget` | — | ❌ |
| `getconf` `nc` `bytrace` | ❌ | ❌ |

**影响**：写命令时不能用 `tr`（模拟器可以）。去 CRLF 要用 `sed 's/\r$//'` 或 `cut`。

### 3.3 系统规模差异

| 指标 | 模拟器 | 真机 |
|------|--------|------|
| 已装应用 | 64 个 | **224 个** |
| 系统参数 | 535 项 | **689 项** |
| 进程数 | 192 | 218 |
| hidumper 服务数 | 43 | **84** |

---

## 四、⚠️ 危险命令（会卡死 daemon）

这是本轮最重要的**新发现**，直接影响 daemon 稳定性。

### 4.1 `hidumper -c`（dump 所有信息集群）

```
现象：执行后 daemon 永久失去响应
根因：阻塞在 Binder 调用（不可中断睡眠 D 状态）
程度：timeout 的 SIGTERM 无效，连 SIGKILL（-k 参数）也无法立即终止
恢复：必须 kill -9 daemon 并重启
```

### 4.2 `hidumper --mem`（不带管道）

```
现象：同样卡死 daemon
根因：真机 224 个应用 / 218 个进程，内存 dump 输出量极大，
      $() 捕获时缓冲区压力过大，进程阻塞
对比：`hidumper --mem | head -3` 能返回（RC=137 SIGKILL），
      因为 head 提前关闭管道触发 SIGPIPE
```

### 4.3 daemon 的两级超时（已修复但仍不够）

**修复内容**（`core/daemon.sh`）：

```sh
# 原来：timeout 30（只发 SIGTERM）
# 现在：timeout -k 5 20（20s 后 TERM，再 5s 后 KILL）
OUT=$(timeout -k 5 20 sh -c "${CMD}" 2>&1 < /dev/null)
```

**实测效果**：

| 场景 | 修复前 | 修复后 |
|------|--------|--------|
| `sqlite3 --version`（读 stdin 阻塞） | 永久卡死 | ✅ 正常返回 |
| `hidumper --mem \| head -3` | 永久卡死 | ✅ RC=137，daemon 存活 |
| `hidumper -c` | 永久卡死 | ❌ **仍卡死**（不可中断） |
| `hidumper --mem`（无管道） | 永久卡死 | ❌ **仍卡死** |

**结论**：`timeout -k` 能解决"用户态阻塞"（读 stdin、写管道、流式输出不退出），
但解决不了"内核态不可中断阻塞"（Binder 调用挂起）。

### 4.4 建议的应对措施

短期（已完成）：
- ✅ `timeout -k 5 20` 两级超时，覆盖大部分场景
- ✅ App 层 5 秒轮询超时，用户不会无限等待

中期（建议实现）：
- 在 daemon 或 App 层加**危险命令黑名单**：
  ```
  hidumper -c
  hidumper --mem          （无管道时）
  hilog -T <tag>          （流式，已有 timeout 兜底）
  tail -f                 （流式）
  logcat                  （不存在但防御）
  ```
- App 检测到连续超时后，提示用户"daemon 可能已挂起，请重启"

长期（可选）：
- daemon 改为**异步执行**：收到请求后 fork 子进程，主循环继续轮询，
  子进程结果写入 res 文件。这样即使子进程卡死，daemon 本身不会卡死。
  代价是复杂度上升，且需要处理子进程回收。

---

## 五、真机可用的完整能力清单

### 5.1 ✅ 完全可用

| 分类 | 命令 |
|------|------|
| 环境 | `id` `uname -a` `uname -m` `date` `uptime` `toybox` `env` |
| bm 包管理 | `bm dump -a` `bm dump -n` `bm get -u` `bm clean -c/-d` `bm help` |
| param | `param get` `param get <key>`（689 项） |
| 电源 | `power-shell wakeup/suspend/timeout -o/-r` **`setmode 600/601/602`** |
| 截图 | `snapshot_display -f <path>`（写 /data/local/tmp 正常） |
| 输入 | `uinput -T -c/-m/-d` `uinput -K -d N -u N`（含 Home/Back/音量/电源） |
| uitest | `uitest dumpLayout -p` `uitest uiInput click/swipe/keyEvent` `uitest screenCap` |
| hidumper | `-h` `-ls`(84服务) `--cpufreq` `--cpuusage` `--net`(部分) |
| 日志 | `hilog -h/-x/-r/-Q` `hisysevent -l` `SP_daemon -h` |
| Linux 工具 | `ps` `pidof` `ls` `df` `du` `free` `grep` `wc` `head` `tail` `sed` `cut` `find` `md5sum` `netstat` `ifconfig` `ping` `sqlite3` `tar` `gzip` |

### 5.2 ⚠️ 静默执行（RC=0 但无输出，操作生效）

- `aa start` / `aa force-stop`
- `power-shell wakeup/suspend/timeout/setmode`
- `uinput -K`（输出 `you raised the key N`，明确）

> App 层必须自行校验结果，不能只看 RC。`aa start` 失败也是 RC=0。

### 5.3 ❌ 不可用

| 命令 | 原因 | 替代方案 |
|------|------|---------|
| `aa dump -l` / `-a` / `-e` | 输出走 pty | `uitest dumpLayout` |
| `hidumper -s <Service>` | shell 权限拿不到 dump | `@ohos.*` 原生 API |
| `hidumper -c` | **卡死 daemon** | 不要用 |
| `hidumper --mem`（无管道） | **卡死 daemon** | 用 `\| head -N` 或 `@ohos` API |
| `awk` `tr` `getconf` `nc` `curl` `wget` `bytrace` | toybox 未内置 | `sed` / `cut` / 原生 API |
| 卓易通穿透全部 | 设备无安卓容器 | 需装卓易通后测试 |

---

## 六、给 App 开发的结论

1. **电池信息必须用 `@ohos.batteryInfo`** —— 真机 `hidumper -s BatteryService` 零数据
2. **热 点/窗口信息必须用原生 API** —— `hidumper -s` 全部拿不到
3. **前台应用必须用 `uitest dumpLayout`** —— `aa dump -l` 不可捕获（已实现）
4. **`setmode` 可以放心用** —— 已验证真实生效
5. **去掉 CRLF 不能用 `tr`** —— 真机没有，用 `sed 's/\r$//'`
6. **绝对不要在 App 里开放 `hidumper -c` / `hidumper --mem`** —— 会让 daemon 永久挂起
7. **所有 `aa` 命令执行后要自行校验** —— RC=0 不代表成功

---

_报告日期：2026-11-04 | 验证脚本：`scripts/verify-device.sh`_
