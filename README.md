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

## 运行状态标志

设置页「运行状态」区实时显示（数据由 powerd 侧写入 `status.plist`）：

| 字段 | 含义 |
|---|---|
| `tweakLoaded` | `YES` = dylib 已注入 powerd 且 hook 装好；若为 `NO` 说明未注入（需确认 powerd 已重启） |
| `blockedWrites` | 启动至今被拦下的降流写次数，**数值持续增长即代表确实在拦截生效** |

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

偏好文件：`/var/mobile/Library/Preferences/com.chargecontrol.plist`（与旧版 ChargeControl 共用域）
设置变更通过 Darwin 通知 `com.chargecontrol/settingsChanged` 即时生效，另有 2s 轮询兜底。

## 诊断日志与状态文件

- 日志：`/var/mobile/ForceFastCharge/ffcharge.log`
- 状态：`/var/mobile/ForceFastCharge/status.plist`

安装/升级时由 `postinst` 自动清除日志，保证每次测试从干净状态开始。

## 构建

- rootless：`make package`
- roothide：`make package THEOS_PACKAGE_SCHEME=roothide`
- GitHub Actions 双变体 CI，产物在 `packages/*.deb`
