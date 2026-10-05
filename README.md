# ForceFastCharge

**强制充电**单功能版越狱插件。仅注入 `powerd`：系统尝试停充（断流）时，拦下这次写入，让它继续充到满。

> ⚠️ **v0.2.0 功能转向**：本插件原来做的是「强制快充」（吞掉系统的降流写，让充电更快）。
> 该方向已被实机证据否定，现改为**强制充电**（阻止系统断流）。原因见下一节。

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

1. **只注入 `powerd`** —— 生命周期 = powerd 生命周期。powerd 由 launchd 常驻，故装上即一直生效，**不需要自拉 daemon**。
2. **不伪造电池状态、不改写注册表读回值、不主动写任何属性** —— 只在系统**自己发起**停充写入的那一刻拦一下（事件驱动，零轮询、零主动写盘）。
3. **只拦「停充方向」的写入** —— 系统同样会写 `ChargeInhibit = false` 来**解除**停充，那种写入对我们有利，原样放行。
4. **不碰 `ChargeLimit`**（充电上限百分比，那是用户意图）、**不碰 `FullyCharged` / 电量**（充满了就该停）。
5. **拦不到内核热保护** —— 温度保护由内核 SMC 层直接执行，**根本不经过 powerd**，想拦也拦不到。这反而是好事：我们的拦截不会破坏原厂热保护链。

## 一个开关

| 开关 | 偏好键 | 默认 | 作用 |
|---|---|---|---|
| 强制充电（不断流） | `forceChargeEnabled` | `false` | 系统写 `ChargeInhibit` / `DisableInflow` / `ChargeBlocked`（值为 true / 非 0）时拦下该写入，让它继续充 |

覆盖三条写入通道：`IORegistryEntrySetCFProperty`（单数）、`IORegistryEntrySetCFProperties`（**复数版，上游漏掉的那条**）、`IOServiceSetCFProperty`（本机 IOKit 无此符号时自动跳过）。另 hook `IOServiceOpen` 做纯诊断（记录 powerd 打开了哪些 IO service）。

## 状态指示点（圆点）

> **红点 = 我们强制让它充**（拦下了系统的停充写，正在阻止断流）。
> **绿点 = 电池自己的颜色**（系统原生充电，我们没介入）。
> 不充电时两个模式都不显示。

判据**不是**「开关开没开」（本插件的用法是常开），而是
**这一轮充电里我们有没有真的拦下系统停充**（powerd 侧 `sessionBlocked > 0`）。
每次开始充电会话时该计数会自动重置。

| 模式 | 值 | 行为 |
|---|---|---|
| **仅强制**（默认） | `2` | 只有我们真在阻止断流时才显示 🔴 红点；没干活就不显示 |
| 常显 | `1` | 只要在充电就显示：🟢 绿 = 系统自己在充；🔴 红 = 我们在阻止断流 |

- 位置由设置页的 `dotX` / `dotY` 决定（默认 X=294 Y=29.4，灵动岛右侧）。
- 实现：独立 `UIWindow` + `windowLevel = UIWindowLevelAlert + 1.0`，`userInteractionEnabled = NO`，
  窗口只占 24×24，不接收触摸、不影响手势。
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

## 构建

- rootless：`make package`
- roothide：`make package THEOS_PACKAGE_SCHEME=roothide`
- GitHub Actions 双变体 CI，产物在 `packages/*.deb`
