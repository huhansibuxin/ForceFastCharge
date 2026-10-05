# ForceFastCharge

强制快充**单功能**版越狱插件。仅注入 `powerd`，阻止系统把充电电流/功率上限往下压。

移植自 [`mowang7426/sbcpu`](https://github.com/mowang7426/sbcpu) 的 `SBCPUPowerd.xm`（V3.1.14+ 独立 powerd 目标），剥离全部限充 / 温度停充 / AppleSMC 逻辑，只保留强制快充一项。

## 设计原则

1. **只注入 `powerd`** —— 生命周期 = powerd 生命周期。powerd 由 launchd 常驻，故装上即一直生效，**不需要自拉 daemon**。
2. **不伪造电池状态、不改写注册表读回值**。
3. **只「吞掉」降流写指令**（命中白名单键时 `return KERN_SUCCESS`，实际不写入），不主动把电流顶到某个值。
4. **默认不拦截温度安全键**。

## 两个开关

| 开关 | 偏好键 | 默认 | 作用 |
|---|---|---|---|
| 强制快充 | `forceChargeEnabled` | `false` | 吞掉**系统软件层**降流键（`ChargeCurrentLimit` / `MaxChargeCurrent` / `AdapterPowerLimit` / `AdapterCurrentLimit` / `ChargingPowerLimit` / `ChargingCurrentLimit` / `USBPDCurrentLimit` / `USBPDPowerLimit`）。安全档。 |
| 强制覆盖温控降流 | `forceThermalOverrideEnabled` | `false` | 额外吞掉**温控派生**键（`ThermalMaxChargeCurrent` / `ThermalChargingLimit` / `ThermalChargeCurrentLimit` / `ThermalAdapterCurrentLimit`）。⚠️ **高风险** |

### 为什么温控要单独一个开关

机身过热时，iOS 是通过 `ThermalMaxChargeCurrent` 这类**温控派生键**停止充电的——这就是「高温时系统原生不允许」。这属于原厂安全保护链。

- 旧版 CPUthermal 把温控键**也列进拦截白名单**，等于无视热保护 → 满流充且不自停 → 越过临界温度 → **thermal force-shutdown（黑屏）**。
- 本插件**默认放行**温控键，所以只开「强制快充」不会触发该路径。
- 只有你显式打开第二个开关才会覆盖温控，此时需自行承担过热强制关机与电池老化风险。

## 状态指示点（圆点）

> **圆点的唯一作用：判断强制快充到底有没有在起作用。** 所以默认模式就是「仅强制」——
> 只有一个判断点：我们真在干活（拦到系统降流）才亮红点。其余情况一律不显示。

判据**不是**「强制快充开关开没开」（本插件的用法是常开），而是
**这一轮充电里我们有没有真的拦到系统降流**（powerd 侧 `sessionBlocked > 0`）。
每次开始充电会话时该计数会自动重置。

| 模式 | 值 | 行为 |
|---|---|---|
| **仅强制**（默认） | `2` | 只有我们真在拦降流时才显示 🔴 红点；我们没干活就不显示 |
| 常显 | `1` | 只要在充电就显示：🟢 绿 = 系统原生充电（我们没介入）；🔴 红 = 我们在拦降流 |

- **不充电时两个模式都不显示**（拔线即消失）。
- 颜色只有两个：**绿 = 系统自己就充得很好、我们无事可做**；**红 = 强制快充确实在干活**。
- 位置由设置页的 `dotX` / `dotY` 决定（默认 X=294 Y=29.4，灵动岛右侧）。
- 实现：独立 `UIWindow` + `windowLevel = UIWindowLevelAlert + 1.0`，`userInteractionEnabled = NO`，
  窗口只占 24×24，不接收触摸、不影响手势。
- 旧版 4 个模式（0 自动 / 1 常显 / 2 仅强制 / 3 关闭）已收敛为 2 个；旧值 1/2 语义不变、
  不需要迁移，其余旧值在打开设置页时自动归一化为「仅强制」。

## 运行状态标志

设置页「运行状态」区实时显示（数据由各 dylib 写入 Preferences 域文件，设置页按 `defaults=` 域读取）：

| 行 | 数据源 | 含义 |
|---|---|---|
| powerd 已加载 | `com.chargecontrol.ffstatus` 域 `loaded` | `是` = dylib 已注入 powerd 且 hook 装好；`否` = 未注入或未重启 powerd |
| 强制快充是否在干活 | `com.chargecontrol.ffstatus` 域 `active` | `工作中` = 本轮充电拦到过降流（**红点判据**）；`待命` = 还没拦到 |
| 已拦截降流次数 | `com.chargecontrol.ffstatus` 域 `blocked` | 启动至今被拦下的降流写次数，**数值持续增长即代表确实在拦截生效** |
| 指示器已加载 | `com.chargecontrol.sbstatus` 域 `dotLoaded` | `是` = 指示点 target 已注入 SpringBoard |
| 圆点窗口 | `com.chargecontrol.sbstatus` 域 `dotWindow` | `是` = 指示点 UIWindow 已挂到屏幕 |
| 圆点当前状态 | `com.chargecontrol.sbstatus` 域 `dotState` | 此刻圆点应该是什么样（`红 · 强制快充工作中` / `绿 · 系统原生充电` / `不显示`），不必盯着状态栏核对 |

> ⚠️ roothide 隐根下设置页读写 `/var/mobile/Library/Preferences/` 会被自动重定向到 jbroot 内的同名路径，
> 而注入系统进程的 dylib 直读直写真实路径。本插件已内置 jbroot 自定位（`FFJbrootPrefix`，dladdr 反推 + 目录扫描 + `/var/jb` 三级回退），
> 并把**所有候选路径都写一遍**，保证两边落到同一个文件——这是 v0.1.3 修复「设置页永远显示未加载」的关键。

### 排查「圆点一直不红」：先看 hook 有没有被调用

`ffcharge.log` 里的 `setter key seen: <键名>` 与 `ff_status.plist` 的 `setterCalls` 是专门为此加的：

- `setterCalls == 0` → powerd **压根没调用**我们 hook 的 setter ⇒ hook 点不对（不是白名单问题）；
- `setterCalls > 0` 且 `blockedWriteCount == 0` → 调了，但**键名没命中白名单**，需要扩白名单；
- `blockedWriteCount > 0` → 拦截链通了，圆点该是红的。

## 与旧版（ChargeControl 激进派）的区别

| | 旧版 `ChargeControl/Tweak.xm` | 本插件（默认档） |
|---|---|---|
| 注入 | powerd + thermalmonitord | **仅 powerd** |
| 降流处理 | 强行顶回「原生满量」，读不到灌 **5000mA(5A)** | **直接吞掉写请求**，不改值 |
| 停充标签 | 每 2s 清 `ChargingPaused`/`ForceDisableCharge`/`NotChargingReason`/优化位 | **完全不碰** |
| 温控派生键 | 一并拦截 | **默认放行**（需单独开关） |
| 电池状态 | 改写读回值 | **不伪造** |

> 旧版黑屏根因：满流充 + 禁停充 + 无视温控 → 温度只升不降 → 越过临界值 → iOS thermal force-shutdown。
> 本插件默认档从设计上不会触发该路径。

## 实际效果边界

充电速度最终由**充电器额定功率、线材规格、电池 BMS 与机身温度**共同决定。本插件只保证「系统不主动往下压电流上限」，无法突破充电器功率天花板，也**无法绕过高温时的降流保护**（除非开启高风险开关）。

## 偏好键

| 键 | 类型 | 默认 | 说明 |
|---|---|---|---|
| `forceChargeEnabled` | Bool | `false` | 强制快充主开关 |
| `forceThermalOverrideEnabled` | Bool | `false` | 高温强制（高风险） |
| `indicatorShowMode` | Int | `2` | 圆点模式：`2` 仅强制（默认，只有我们干活才亮红）；`1` 常显（充电就显示，绿/红） |
| `dotX` / `dotY` | String | `294` / `29.4` | 圆点中心坐标（pt） |

偏好文件：`/var/mobile/Library/Preferences/com.chargecontrol.plist`（与旧版 ChargeControl 共用域）
设置变更通过 Darwin 通知 `com.chargecontrol/settingsChanged` 即时生效，另有 2s 轮询兜底。

## 诊断日志与状态文件

所有文件都在 `/var/mobile/Documents/ForceFastCharge/`（mobile 拥有、不被 roothide 重定向，powerd(root) 与 SpringBoard(mobile) 都能写）：

| 文件 | 写入者 | 内容 |
|---|---|---|
| `boot.log` | 两个 dylib 的 `%ctor` 第一行（纯 POSIX，不依赖 ObjC） | 加载痕迹：`path/pid/progname`，用于区分「ctor 没跑」与「写盘被拒」 |
| `ffcharge.log` | powerd 侧 | hook 安装、每次拦截的降流键 |
| `ff_status.plist` | powerd 侧 | powerd 侧状态诊断副本 |
| `sb.log` | SpringBoard 侧 | 指示点创建、刷新、定时器心跳 |
| `sb_status.plist` | SpringBoard 侧 | 指示点状态诊断副本 |

设置页读的**状态域文件**（`ffstatus`/`sbstatus`）由 dylib 写入 jbroot 内的 `var/mobile/Library/Preferences/`。

安装/升级时由 `postinst` 自动清除日志，保证每次测试从干净状态开始；异常时 `touch /var/mobile/Documents/ForceFastCharge/disable` 可空跑止血。

## 构建

- rootless：`make package`
- roothide：`make package THEOS_PACKAGE_SCHEME=roothide`
- GitHub Actions 双变体 CI，产物在 `packages/*.deb`
