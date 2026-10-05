# ForceFastCharge

**强制充电**单功能版越狱插件。仅注入 `powerd`：系统把充电关掉（断流）之后，通过 AppleSMC 把充电开关写回「允许」，让它继续充到满。**不新增任何 daemon。**

> ⚠️ **v0.2.0 功能转向**：本插件原来做的是「强制快充」（吞掉系统的降流写，让充电更快）。
> 该方向已被实机证据否定，现改为**强制充电**（阻止系统断流）。原因见下一节。
>
> 🔧 **v0.3.0**：修「插上充电器圆点不显示」（建窗与状态变化耦合导致的死等，见下文）；
> 并为「强制充电到底走哪条通道」加了 user client external method 探针。
> 待机心跳现在也带电池遥测 —— 任何时刻取日志都能判断线在不在、系统有没有在限流。
>
> ⭐ **v0.4.0（当前）**：**从「拦截」改为「纠正」** —— 实测证明 powerd 全程不下发停充指令
> （它是充电状态的**读取者**，没有可拦的动作），真正的开关在 SMC 固件里。
> 本版照搬上游 `SBCPUChargeSMC` 的**恢复路径**：检测到「有线但没在充电」时，
> 把 `CH0C` / `CH0I` 的禁止位写回 0。**仍然只注入 powerd 一个进程，不新增 daemon。**
> 同时修正圆点判据：由 `IsCharging` 改为 `ExternalConnected`（插着线就显示），
> 并新增**橙点**表示「有线但系统没在充」。详见下文。

## 为什么不做「强制快充」了

2026-10-05 在 iPhone 14 Pro Max / iOS 16.6.1（20G81）上做了三重取证：

| # | 证据 | 结果 |
|---|---|---|
| ① | 插着充电器（`ExternalConnected=Yes` / `IsCharging=Yes`）dump 全表 IORegistry（23872 行） | `ChargeCurrentLimit` / `MaxChargeCurrent` / `AdapterPowerLimit` / `AdapterCurrentLimit` / `ChargingPowerLimit` / `ChargingCurrentLimit` / `USBPD*` / `Thermal*Limit` —— **命中 0 条** |
| ② | 把 `powerd` 本体（`/System/Library/CoreServices/powerd.bundle/powerd`）拉下来解析 `__cstring` | 电池相关键只有 `ChargingOverride` / `InflowOverride` / `ChargeInhibit` / `ChargeLimit` / `DisableInflow` / `ChargingState` / `InflowState` / `VacVoltageLimit` / `NotChargingReason` / `ChargerData` —— **全是「限 / 停 / 只读」，没有一个能提高电流** |
| ③ | 看运行时 hook 日志 | `setterCalls = 7`，全是 boot 期的系统键（TimeZoneOffsetSeconds / SleepWakeUUID / …），充电期间**零命中** |

**结论**：上游 `SBCPUPowerd.xm` 那套白名单是 macOS / Intel 时代的键名，在 iOS 上不存在 ⇒ 该插件**永远空转**，不是代码写错。

更根本的是：**iOS 用户态只能「限」（停充 / 限流 / 限百分比），不能「加」** —— 充电电流由内核 `AppleSmartBatteryManager` + 电池管理芯片（SMC）固件决定。所以「让充电更快」物理上做不到；**「不让它中断」可以做到**，这就是本插件现在的功能。

## 设计原则

1. **只注入 `powerd`，不新增 daemon** —— 生命周期 = powerd 生命周期，装上即一直生效。
   上游之所以要独立 daemon（`SBCPUChargeDaemon` + `applesmc.user-access` entitlement），是因为 **SpringBoard 没有 AppleSMC 权限**；
   而 powerd 作为系统电源守护进程**本身就有** —— v0.3.0 探针实测它自己就在 `IOServiceOpen(AppleSMC)` 并调用其读写通道（`selector=2` = `kSMCHandleYPCEvent`）。所以直接复用即可。
2. **写的值恒为「允许」，绝不写「禁止」** —— 唯一的写动作是把 `CH0C` / `CH0I` 的禁止位清成 0（恢复出厂默认）。
   不伪造电池读数、不改电量、不碰 `ChargeLimit`（充电上限百分比）、不碰 `FullyCharged`。
3. **只在「有线但没在充电」时介入** —— 其余时间一次 SMC 写都不发；写操作本身有 10s 节流（连续失败 ≥3 次降为 60s）。
4. **写后必回读确认** —— 上游 V4.29 的教训：`IOConnectCallStructMethod` 返回成功 ≠ SMC 接受，且系统可能立刻覆盖回去。
5. **不绕过内核热保护** —— 内置 45℃ 上限，电池温度超过它就不再介入（见「效果边界与风险」一节）。

## 一个开关

| 开关 | 偏好键 | 默认 | 作用 |
|---|---|---|---|
| 强制充电（不断流） | `forceChargeEnabled` | `false` | 检测到「有线但没在充电」时，把 SMC 的 `CH0C` / `CH0I` 禁止位写回 0，让充电继续 |

**v0.4.0 主路径（SMC 纠正）**：读 `CH0C`（电池充电开关，bit0=1 表示禁止充电）、`CH0I`（外部供电开关，bit0=1 表示切断外部供电），**哪一位被置 1 就清哪一位**，写完回读确认。语义照搬上游 `SBCPUChargeSMC` 的恢复路径（与 Battman `restore` 同款）。
`CHCE` / `CH0R` / `CH0B` 只作诊断记录、**不参与判断** —— 上游 V4.28 的教训是：禁止位生效后 SMC 可能把 `CH0R` bit1 报成 No VBUS（哪怕线物理上还插着），若用它去拒绝"恢复"，设备会**卡死在阻断态**。

**v0.2.x 遗留路径（拦截，本机实测空转）**：仍保留对 `ChargeInhibit` / `DisableInflow` / `ChargeBlocked` 的拦截，覆盖三条写入通道（`IORegistryEntrySetCFProperty` 单数、`IOServiceSetCFProperty`、`IORegistryEntrySetCFProperties` **复数版**），以及 `IOServiceOpen` / `IOConnectCall*` 诊断探针 —— 它们是判断「powerd 到底走不走这条路」的证据来源，留着不碍事。

## 状态指示点（圆点）

> **红点 = 我们强制让它充**（SMC 纠正生效，已把系统关掉的充电打开）。
> **橙点 = 有线，但系统没在充电**（我们没介入 / 介入没成功）—— 看到它就说明系统正在断流。
> **绿点 = 电池自己的颜色**（系统原生充电，我们没介入）。
> **没插线时一律不显示**（两个模式一致）。

⭐ v0.4.0 起，「是否显示」的主判据是 **`ExternalConnected`（有没有插线）**，不再是 `IsCharging`。
原因：本机实测系统经常「插着线却拒绝充电」（76% / 0mA / `ncr=16`），用 `IsCharging` 当判据
等于**在最该显示的时候不显示** —— 这正是老板报「开了常显，插上还是不显示」的根因。

判据**不是**「开关开没开」（本插件的用法是常开），而是
**这一轮我们有没有真的把系统关掉的充电打开**（powerd 侧 `gSMCRecovered`）。
每次插线（`ExternalConnected` 上升沿）时自动重置。

| 模式 | 值 | 行为 |
|---|---|---|
| **仅强制**（默认） | `2` | 只有我们真在强制充电时才显示 🔴 红点；没干活就不显示 |
| 常显 | `1` | 只要**插着线**就显示：🟢 绿 = 系统在充；🟠 橙 = 有线但系统没在充；🔴 红 = 我们纠正成功 |

- 位置由设置页的 `dotX` / `dotY` 决定（默认 X=294 Y=29.4，灵动岛右侧）。
- 实现：独立 `UIWindow` + `windowLevel = UIWindowLevelAlert + 100`，`userInteractionEnabled = NO`，
  窗口铺满 scene、圆点 8×8 绝对定位，不接收触摸、不影响手势。
- 旧版 4 个模式（0 自动 / 1 常显 / 2 仅强制 / 3 关闭）已收敛为 2 个；旧值 1/2 语义不变、
  不需要迁移，其余旧值在打开设置页时自动归一化为「仅强制」。

## 运行状态标志

设置页「运行状态」区实时显示（数据由各 dylib 写入 Preferences 域文件，设置页按 `defaults=` 域读取）：

| 行 | 数据源 | 含义 |
|---|---|---|
| powerd 已加载 | `com.chargecontrol.ffstatus` 域 `loaded` | `是` = dylib 已注入 powerd 且 hook 装好 |
| 强制充电是否在干活 | `com.chargecontrol.ffstatus` 域 `active` | `工作中` = 本轮充电拦下过停充（**红点判据**）；`待命` = 还没拦到 |
| 已拦截停充次数 | `com.chargecontrol.ffstatus` 域 `blocked` | 启动至今被拦下的停充写次数，**持续增长即代表确实在拦截** |
| 指示器已加载 | `com.chargecontrol.sbstatus` 域 `dotLoaded` | `是` = 指示点 target 已注入 SpringBoard |
| 圆点窗口 | `com.chargecontrol.sbstatus` 域 `dotWindow` | `是` = 指示点 UIWindow 已挂到屏幕 |
| 圆点当前状态 | `com.chargecontrol.sbstatus` 域 `dotState` | 此刻圆点应该是什么样（`红 · 正阻止系统断流` / `绿 · 系统原生充电` / `不显示`） |

> ⚠️ roothide 隐根下设置页读写 `/var/mobile/Library/Preferences/` 会被自动重定向到 jbroot 内的同名路径，
> 而注入系统进程的 dylib 直读直写真实路径。本插件已内置 jbroot 自定位（`FFJbrootPrefix`，dladdr 反推 + 目录扫描 + `/var/jb` 三级回退），
> 并把**所有候选路径都写一遍**，保证两边落到同一个文件。

### 排查「圆点一直不红」：先看 hook 有没有被调用

`ffcharge.log` 里的 `setter key seen: <键名>`、`IO service opened: <类名>` 与 `ff_status.plist` 的 `setterCalls` 是专门为此加的：

- `setterCalls == 0` → powerd **压根没调用**我们 hook 的 setter ⇒ hook 点不对；
- `setterCalls > 0` 且 `blockedWriteCount == 0` → 调了，但**没有停充方向的写入**（＝系统本来就没断流，圆点不该红，属正常）；
- `blockedWriteCount > 0` → 拦截链通了，圆点该是红的。
- `IO service opened:` 里若出现 `AppleSmartBatteryManagerUserClient`，说明 powerd 还走用户客户端通道
  （`IOConnectCallMethod`）——该通道目前**只观测不拦截**（externalMethod 参数结构未知，盲拦有风险）。

## 与旧版（ChargeControl 激进派）的区别

| | 旧版 `ChargeControl/Tweak.xm` | 本插件 |
|---|---|---|
| 注入 | powerd + thermalmonitord | **仅 powerd** |
| 触发方式 | 常驻改写 + **每 2s 主动清**停充标签 | **只在系统发起写入时拦一下**（事件驱动） |
| 电池状态 | 改写读回值 | **不伪造、不主动写** |
| 温度保护 | 一并拦截 | **拦不到也碰不到**（走内核，不经过 powerd） |

> 旧版黑屏根因：满流充 + 禁停充 + 无视温控 + 主动反复写 → 温度只升不降 → 越过临界值 → iOS thermal force-shutdown。
> 本插件从设计上不会触发该路径。

## 实际效果边界与风险

- 本插件**不能**让充电更快（见开头三铁证）；只能做到「系统想中断时不中断」。
- ⚠️ **风险提示**：若停充源于机身过热，强行继续充会加速电池老化。是否使用请自行权衡。
- 若系统停充是内核直接执行的（不经过用户态），插件拦不到 —— 此时红点不会亮，也不会造成任何影响。

## 偏好键

| 键 | 类型 | 默认 | 说明 |
|---|---|---|---|
| `forceChargeEnabled` | Bool | `false` | 强制充电主开关 |
| `indicatorShowMode` | Int | `2` | 圆点模式：`2` 仅强制（默认，只有我们干活才亮红）；`1` 常显（充电就显示，绿/红） |
| `dotX` / `dotY` | String | `294` / `29.4` | 圆点中心坐标（pt） |

偏好文件：`/var/mobile/Library/Preferences/com.chargecontrol.plist`（与旧版 ChargeControl 共用域）
设置变更通过 Darwin 通知 `com.chargecontrol/settingsChanged` 即时生效，另有 2s 轮询兜底。

## 诊断日志与状态文件

所有文件都在 `/var/mobile/Documents/ForceFastCharge/`（mobile 拥有、不被 roothide 重定向，powerd(root) 与 SpringBoard(mobile) 都能写）：

| 文件 | 写入者 | 内容 |
|---|---|---|
| `boot.log` | 两个 dylib 的 `%ctor` 第一行（纯 POSIX，不依赖 ObjC） | 加载痕迹：`path/pid/progname`，用于区分「ctor 没跑」与「写盘被拒」 |
| `ffcharge.log` | powerd 侧 | hook 安装、每次拦截的停充键、`setter key seen`、`IO service opened` |
| `ff_status.plist` | powerd 侧 | powerd 侧状态诊断副本 |
| `sb.log` | SpringBoard 侧 | 指示点创建、刷新、定时器心跳 |
| `sb_status.plist` | SpringBoard 侧 | 指示点状态诊断副本 |

设置页读的**状态域文件**（`ffstatus`/`sbstatus`）由 dylib 写入 jbroot 内的 `var/mobile/Library/Preferences/`。

安装/升级时由 `postinst` 自动清除日志，保证每次测试从干净状态开始；异常时 `touch /var/mobile/Documents/ForceFastCharge/disable` 可空跑止血。

### 日志"不更新"是正常的 —— 请先读这一节

拦截逻辑是**纯事件驱动**的：只有这些时刻才会写 `ffcharge.log` ——

1. powerd 启动（`=== boot ... ===` / `hooks installed ...`）
2. 开关变化（`forceCharge -> ON/OFF`）
3. 充电状态翻转（`charging state -> YES/NO`，拔插充电器）
4. **真的拦到系统停充**（`BLOCK stop-charge(set/setprops): ChargeInhibit`）
5. 白名单键被写（`stop-key seen: ...`，无论拦没拦）
6. 60 秒一次的存活心跳（v0.2.1 新增）

所以**没插充电器、或系统安安静静正常充电时，日志就是静止的 —— 这不是坏了**。
为了消除"静止 = 死了"的歧义，v0.2.1 加了心跳：

```
heartbeat idle pid=35209 hooks=1 force=1 charging=0 sessionBlocked=0 blocked=0 setterCalls=22
heartbeat charging pid=35209 hooks=1 force=1 cap=92% mA=1224 mV=4371 vac=4360 ncr=0 thermal=0 ext=1 temp=34.7C sessionBlocked=0 blocked=0 setterCalls=31
```

- 待机：`heartbeat idle`（1 行/分钟）→ 看到它就说明 dylib 活着、hook 还挂着
- 充电中：`heartbeat charging` + **电池遥测**，直接回答"系统到底有没有在给电流"
- 日志超 512KB 自动轮转（约 4 天量），不会无限增长

### 怎么读「系统为什么断流」

拔线/断流那一刻会多打一行 `charge stop reason:`：

```
charge stop reason: cap=92% mA=0 mV=4371 vac=4360 ncr=132 thermal=0 ext=1 temp=41.2C sessionBlocked=0
```

判读（这是"功能无效"与"没触发"的分水岭）：

| 观察 | 结论 |
|---|---|
| `ncr=0` / `ncr=128` | 正常（128 = 没接充电器），系统没在限你 |
| `ncr` 是别的值（如 132）且 `sessionBlocked=0` | 停充**不经过 powerd**（内核 SMC / 固件直控），我们拦不到 → 圆点不会红 |
| `sessionBlocked>0` 或日志里有 `BLOCK stop-charge` | 系统本来要停充，**被我们拦住了** → 圆点该是红的 |
| `thermal>0` | 温控介入过（累计秒数），说明是温度触发的限流 |

### 圆点不随插拔充电器刷新？先看心跳有没有打出来

v0.2.2 修掉了一个**完全静默**的根因：两侧的 2s 轮询定时器
（`dispatch_source_t`）此前声明为 `%ctor` 内的**局部变量** ——
ARC 下它在离开作用域时被 release，libdispatch 随即 cancel 掉这个已
`dispatch_resume` 的 source，定时器**永久失效，不崩溃、不报错、无日志**。

后果（v0.2.1 实机现象）：唯一还能刷新圆点的通路退化成
「用户在设置页操作 → Darwin 通知 → 两侧被唤起」，于是表现为
**插上充电器圆点不亮、拔掉也不灭，点一下设置页（应用位置）才更新**。

现在改为**文件级静态变量**持有强引用（block 内不捕获它，无循环引用）。

### v0.3.0：插上充电器圆点仍不显示 —— 建窗与状态变化被耦合在一起

定时器修好之后仍然"插上不亮"，实机日志把根因钉死了：

```
[1791186075.742] refresh force=1 charging=1 active=0 mode=1 ... win=0 vis=0 scene=0
[1791186076.377] refresh force=1 charging=1 active=0 mode=1 ... win=0 vis=0 scene=0
   ← 之后 47 秒完全静默（充电器一直插着）
[1791186123.278] refresh force=1 charging=0 active=0 mode=1 ... win=1 vis=1 scene=0
   ← 拔线的那一帧，窗口才被建出来
```

**根因是刷新入口的短路顺序**，不是注入、不是开关、不是场景：

```objc
// 旧代码（v0.2.2）
if (!forceNotify && !changed) return;          // ← 状态没变就提前返回
...
[[FFIndicator shared] updateWithCharging:...]; // ← 而建窗只发生在这里面！
```

SB 刚重启时 scene 尚未就绪 → 首次建窗失败 → 插着充电器时状态**恒稳** →
每 2s 的 tick 全部在 `return` 处提前退出 → **窗口再也没有任何重试机会**，
一直到某次状态翻转（拔线）才把窗口建出来。

v0.3.0 的修法（四件事一起做，一次到位）：

| # | 改动 | 解决什么 |
|---|---|---|
| ① | 每轮 tick **无条件先** `ensureWindowAsync()`（幂等、非阻塞），再做变化检测 | 建窗与状态变化彻底解耦，失败后每 2s 自动重试 |
| ② | `ff_currentScene()` 放宽：ForegroundActive → 任意 `UIWindowScene` → 从已有窗口反查 | SB 启动早期/锁屏切换时不再"挑不到场景" |
| ③ | `+sceneState` / `+diagLine` 改读**主线程缓存** | 后台线程直接读 `UIApplication` 拿不到 connectedScenes，**恒返回 0** —— 这个假值会把人往"场景不对"的沟里带 |
| ④ | 窗口改为**铺满 scene**、圆点用绝对坐标定位（不再用 24×24 小窗口） | scene 化 `UIWindow` 的 frame 由 scene 掌管，小 frame 可能被系统重置 → 圆点随窗口飘到原点，日志仍报"可见"却肉眼看不到 |
| ⑤ | 窗口补一个透明空 `rootViewController`，`windowLevel` 提到 `Alert + 100`，坐标 clamp 进屏幕 | 排除"裸窗口不参与合成""被状态栏/灵动岛盖住""坐标填越界"三种不显示 |

验证方法（插拔充电器后最多等 2s）：

```bash
ssh root@192.168.3.156 'tail -20 /rootfs/private/var/mobile/Documents/ForceFastCharge/sb.log'
```

| 观察 | 结论 |
|---|---|
| `heartbeat ... vis=1 ... [lvl=2100 hid=0 ...]` | 定时器与圆点窗口都正常（1 行/分钟） |
| `refresh ... charging=1 vis=1` | 插电后圆点已显示 |
| `refresh ... charging=0 vis=0` | 拔线后圆点已隐藏 |
| `[win=nil]` 或 `[no-scene]` | 窗口压根没建出来（场景未就绪）—— 现在每 2s 会重试，持续出现才算异常 |
| `hid=0` 却肉眼看不到 | 看同一行的 `win=` / `dot=` 坐标，判断是否被遮挡或跑到屏外 |
| 连 `heartbeat` 都没有 | 定时器仍未工作 |

> ⚠️ 同类陷阱：ARC + GCD 定时器**必须**由 `static` / ivar 持有强引用。
> 写成局部变量在模拟器/单次调用里可能"看起来正常"（恰好没被回收），
> 在常驻进程里则表现为"功能时好时坏或干脆全无"。排查此类问题时，
> 第一件事就是**确认心跳/日志里的"定期"输出到底有没有**。
>
> ⚠️ 另一个陷阱：**别把"建窗"这类必须重试的动作放在"状态变化"的短路分支后面**。
> 事件驱动省 CPU 是对的，但"每轮都该做的事"（保活、重试、兜底）必须放在短路之前。

### v0.4.0：从「拦截」改为「纠正」—— 强制充电到底怎么做

**为什么不再拦截**：v0.2.x / v0.3.0 的日志已经把这条路彻底否掉 ——

| 观测 | 含义 |
|---|---|
| `setterCalls` 从 boot 后恒定（22 → 32），整个充电会话 **0 次充电相关写** | powerd 不通过 IOKit setter 控制充电 |
| `IOConnectCall*` 探针只在**启动期**记录到 `AppleSMC(sel 0/1/2)`、`AppleSmartBatteryManager(sel 4)` | 充电过程中 powerd 没有任何 user client 调用 |
| 全表 24349 行 IORegistry 里，上游 8 个电流/功率限制键 **命中 0 条** | 上游那套白名单在本机不存在 |

⇒ powerd 是充电状态的**读取者**，不是决策者 —— **没有可拦的动作**。

**真正能生效的做法**：充电开关在 SMC 固件里，用户态唯一通道是 AppleSMC user client。

| SMC 键 | 含义 | 我们做什么 |
|---|---|---|
| `CH0C` bit0 | 电池充电开关（1 = 禁止充电） | 读；若为 1 → 写 0 |
| `CH0I` bit0 | 外部供电开关（1 = 切断外部供电） | 读；若为 1 → 写 0 |
| `CHCE` | ExternalConnected | 只记录 |
| `CH0R` bit1 | No VBUS | **只记录，不参与判断**（上游 V4.28 的教训） |
| `CH0B` | OBC managed charging | 只记录 |

流程（每 2s 一次，只在需要时才真正读写），**照着上游 `SBCPUChargeSMC` 的恢复路径**：

```
有线？ ──否──> 不动
   │是
在充电？ ──是──> 不动
   │否
温度 ≥ 45℃？ ──是──> 只记日志，不动
   │否
读 CH0C / CH0I
   ├─ 两位都是 0 → 记「停充不在这一层」，不动（用户态无解）
   └─ 任一位是 1 → 写 0 → 回读确认 → 成功则记 FIX
```

**怎么读结果**（`ffcharge.log`）：

| 日志 | 结论 |
|---|---|
| `smc: FIX 停充已纠正 CH0C 1→0 …（本会话第 N 次）` | ✅ **功能生效** —— 系统确实关过充电，我们把它打开了（此时圆点是红的） |
| `smc: CH0C=0x00 CH0I=0x00 均为允许，但未充电 → 停充不在这一层` | ⚠️ 停充发生在 SMC 更深层（温度 / VBUS / 电量策略），用户态无解 |
| `smc: read CH0C failed io=0xe00002c2（AppleSMC 权限不足？）` | ⚠️ powerd 没有 SMC 权限 → 才需要考虑独立 daemon |
| `smc: CH0C 写 0 后回读仍 0x01 —— 被系统立刻覆盖` | ⚠️ 写了但被系统立刻写回（拉锯），`streak` 会涨、重试自动降到 60s |

心跳里也能一眼看到：
`smc[CH0C=.. CH0I=.. CH0B=.. CHCE=.. CH0R=.. fix=本会话/累计 err=.. streak=.. rec=..]`

> ⚠️ **重要前提**：上面这些都需要**老板把开关打开**（`forceChargeEnabled`）。开关关闭时一次 SMC 都不读、不写。

### v0.3.0：77% 停充却没有任何拦截 —— 先分清「拔线」与「系统停充」

powerd 侧现在的 `heartbeat` **待机时也带电池遥测**，任何时刻取日志都能一眼判定：

```bash
ssh root@192.168.3.156 'tail -5 /rootfs/private/var/mobile/Documents/ForceFastCharge/ffcharge.log'
```

| 字段 | 含义 |
|---|---|
| `ext=1` / `ext=0` | ExternalConnected：**1 = 线插着**、0 = 真的没有外部电源 |
| `ncr=` | NotChargingReason：0=正常；128=未接充电器；其余值=被系统/固件限制 |
| `mA=` | ChargingCurrent：当前实际充电电流，0 = 真的没在进电 |
| `vac=` | VacVoltageLimit：输入电压上限。正常 5V 档位约 5000；被压到 4360 之类 = 系统在**降功率** |
| `temp=` | 电池温度（℃）。>40 起降流，>45 附近可能直接停充 |
| `setterCalls=` | 累计的 IOKit setter 调用数。**boot 后恒定不增长 = powerd 不用这条通道控制充电** |
| `io-conn method/struct: <服务> selector=N` | v0.3.0 新增探针：powerd 通过 user client external method 下发了哪些命令（只观测不改行为） |

**判读分水岭**：停充那一刻若 `ext=1` 而 `sessionBlocked=0` ⇒ 停充由内核/SMC 直接执行、
不经过 powerd，**我们拦不到**；若 `ext=0` ⇒ 那一刻线确实不在（拔线或接触不良）。

## 构建

- rootless：`make package`
- roothide：`make package THEOS_PACKAGE_SCHEME=roothide`
- GitHub Actions 双变体 CI，产物在 `packages/*.deb`
