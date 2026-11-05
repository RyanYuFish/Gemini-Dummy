# AE5i 仪表模拟器

项目最终目标是完整仿真 AE5i 仪表功能，包括画面渲染、原生按键、电源状态、蓝牙、Wi-Fi、RS-485 通讯和 OTA Update 全流程；之后基于原厂 Qt 用户态定制仪表 UI，通过仪表蓝牙连接 APT F600 读取/修改参数、读取蚂蚁 ANT BMS 与电池计量信息，并最终用 OTA Update 无线刷入实车。

**当前客户端能力**：运行 AE5I 原厂 Linux-4.9.217 和 Qt Launcher，输出 1024×600 framebuffer。上电后由内置 MCU 对端（`lib/emu/dash_up.dart`）经 CFCP 喂 KL15、解锁通知与全量车辆数据，**P 档主界面（茶青背景墙 + 巨大 P + 整车 + 绿色地面 + 顶部光条 + 左列数据 + 底栏）全部由固件自己渲染**，含进场动画与下电 logo-out；所有上屏数值来自 `DashTelemetry`（电量 / 里程 / 电耗 / 续航 / 时间 / 挡位），不是离线贴图。电机控制器状态（TCS / 车速 / 档位 / 驾驶模式 / 转向 / 远光 / 定速 / READY）由 `MotorStatus` 经 `indicator_lamp` + `vehicle_info*` 周期上行，把手按键可实时改写。上、下、SET、BACK 支持按下、长按和释放；串口日志可实时查看并导出。蓝牙/Wi-Fi/RS-485 车辆外设仿真与 OTA Update 完整刷写流程尚未实现；详细状态和验收路线见 [EMULATION.md](../docs/EMULATION.md) 文首、§37、§41–§44。

准备自建 QEMU 和软件显示镜像：

```bash
python3 Gemini-Dummy/tools/build_model.py
python3 Gemini-Dummy/tools/prepare_software_display.py
```

运行前端：

```bash
# FLUTTER 指向所用 SDK 的 bin/flutter（本仓库不再内置 SDK）
export FLUTTER="${FLUTTER:-$HOME/fvm/versions/custom_zeeho/bin/flutter}"
cd Gemini-Dummy/flutter_app
"$FLUTTER" run -d macos
```

Release 构建：

```bash
FLUTTER_SUPPRESS_ANALYTICS=true "$FLUTTER" build macos --release
open build/macos/Build/Products/Release/ae5i_emu.app
```

2026-11-05 重建版：`build/macos/Build/Products/Release/ae5i_emu.app`。应用**不再写死任何绝对路径**：从 app 自身位置 / 脚本位置 / 当前目录逐级向上探测仓库根（识别 `qemu-src/`、`tools/`、`flutter_app/`），再据此定位自建 QEMU、SPVD 和原厂动画资源；目录改名或移动仓库都不会再出现「找不到 QEMU」。

需要本地 Flutter、Xcode、`unsquashfs`、`mksquashfs` 和 `Gemini-Dummy/images/ae5i.spvd`。软件显示镜像仅用于仿真。可用环境变量覆盖：`AE5I_PROJECT_ROOT`（仓库根或其上级工作区）、`AE5I_QEMU_BIN`、`AE5I_SPVD`、`AE5I_BOOT_ANIM`。

> ⚠️ **不要设 `HOME=/tmp`**：它会让 `.dart_tool/package_config.json` 指向 `/tmp/.pub-cache`，缓存被清理后 Flutter framework 编译报 `meta.dart: No such file or directory` / `Matrix4 isn't a type`。若已误设过，先跑一次 `flutter pub get --offline`（真实 HOME）重建包解析再构建。
>
> Flutter SDK 不再内置于本仓库，本机用 `$HOME/fvm/versions/custom_zeeho`（Flutter 3.47.9 / Dart 3.13.7，见 `docs/EMULATION.md` §26.4）。SDK 在 home 目录时，沙箱内跑 `test`/`build` 可能因 unlink `bin/cache/engine.stamp.tmp.*` 被拒；需让命令获得沙箱放行。`flutter --version` 不写 stamp，能过不代表没限制。

## 整车流程仿真

客户端把真车流程建模成状态机（`lib/emu/vehicle.dart`），并用它驱动 QEMU 的上电与下电：

```
断电 › 上电 › 未解锁 › 已解锁 › READY › 关机 › 拔电
```

- **上电**：启动 QEMU，原厂 Linux/Qt 仪表点亮，停在「未解锁」。
- **解锁**（四条路径，与真车一致）：
  1. 刷 NFC 卡；
  2. 蓝牙连上 TBOX 后长按「启动」键（Ready）；
  3. TBOX 在线时点「App 解锁」（TBOX 信号）；
  4. 以上都没有连接时长按 Ready，弹密码框；仿真密码默认 `000000`，可在面板修改（仅客户端演示，不是原厂密码）。
- **READY**：已解锁后长按 Ready 进入动力就绪。
- **正常下电**：已解锁 / READY 时刷卡关机，或 READY 时长按 Ready 关机；等 guest 报 `Power down`，再点「拔电」。
- **异常下电**：仍通电时点「强制拔电」会先弹风险确认，确认后日志标记「异常下电」。真车直接拔电源可能损伤车辆电力系统，这也是模拟器要提示的顺序。

状态机只驱动客户端与 QEMU 生命周期；画面左上角的解锁状态是客户端 HUD。原厂 `anm_logo/logo.mkv` 帧由 QEMU 模型在解锁时重放。

## 画面点亮链路（MCU 对端）

2026-11-05 之前，app 里只有 11-02 的旧 MCU 基线（版本 / 握手 / 心跳，且只在**用户解锁后**才发），既没有 KL15 也没有解锁闸门和挡位，所以固件一直停在黑屏 / 4.37% 非黑的待机统计页 —— 蓝绿背景、右侧大 P、整车和进场动画全都不出现。

现在 MCU 对端在**上电时**就启动（真车 MCU 与仪表同电源），`lib/emu/dash_up.dart` 完整移植了 `tools/dash_up.py`：

1. 逐帧 ACK guest 的 CFCP 属性帧（不回 ACK 会被重传 3 次后丢弃）；
2. **pre-arm**：只喂 `KL15=0x99` + RTC，**禁喂解锁**，否则进场动画被拆帧成整车拖尾、时钟留下残影；
3. **settle**：连发 20 拍全量车辆数据，`gear` 固定 0，不触发场景动画；
4. **enter**：**只写一次** `gear=1`，触发 `Animation_Pstart_init()` → `PGEARobj_showInit(true)`；
5. **保持**：0.5 s 心跳 / 数据（挡位绝不重复发），掉回待机时自愈重放。

全部画面元素由 guest 里原厂 `DashTheme01` 的 QGraphicsScene 绘制；上屏数值来自 `DashTelemetry`，本项目不合成、不重绘任何像素。

> ⚠️ 反复写 `gear` 会让 `slot_delayUpdateGear` 重摆顶部 DRL/ECO，图标叠成双份。`indicator_lamp` 现在**恒周期上报**（`MotorStatus`），但 `ABS_fault` 位恒 0 —— 置位会弹故障框卡住 App。

## 电机控制器模拟与关机动画（2026-11-05）

把手上非仪表侧的按键不再只改客户端状态，而是实时改写 `MotorStatus` 并
立即经 CFCP 上行（不等 0.5 s 心跳），由固件自己的 widget 决定如何渲染：

| 按键 | 电控状态 |
|---|---|
| 转向 ◀ / ▶ / 双闪 | `indicator_lamp.turn_left` / `turn_right` |
| 照明 / 超车灯 | `high_beam` / `big_light` |
| 定速 | `CruiseControl` |
| 加档 / 减档 | `vehicle_info3.drive_mode`（ECO / STREET / SPORT） |
| 自定义键 | `TC`（TCS 启用 ↔ 关闭） |
| 长按 Ready / 关机 | `EV_READY` / `parking` |

客户端状态条同步显示 TCS、驾驶模式、挡位、车速与 READY。16 B 布局由
`tools/lamp_bits.py` 逐位解出（40 个字段 / 108 个语义位），Dart 与 Python
实现逐字节一致（19 帧 `--frames` 回归）。

下电时模型先倒放 112 帧原厂 `anm_logo`（约 1.87 s），播完才发
`poweroff -f`；客户端在 `poweringOff` 期间继续显示画面与「关机动画」提示。

命令行端到端验收（纯 Dart，不依赖 Flutter UI）：

```bash
dart run tool/dash_up_check.dart --frames                       # 帧字节与 tools/dash_up.py 逐字节比对
dart run tool/dash_up_check.dart --duration 90 --out /tmp/check.ppm
dart run tool/dash_up_check.dart --duration 25 --shutdown      # 含关机动画采样
```

验收值（§45 之后）：非黑 **≈94.6%**、茶青 **≈44.8%**（待机页只有 ~4%，
背景色平面此时不启用），进场动画 `4.0→91.0→…→94.6%`，
关机动画 `10.9→12.4→2.6→0.0%`，`RESULT PASS`。
非黑变高是 PFC 背景色平面把透明区填了底色，茶青占比恒定说明主界面元素没被动过。

顶部状态区的方形黑条已在模型侧解决：实现 PFC 显示控制器的**背景色平面**
（颜色从固件自己 OSD 已画出的暗色像素采样，不重绘、不合成、不引入外部位图），
仅主界面启用；window1 若将来由固件贴了真实背景位图会自动接管。
顺带纠正了旧结论：`PFC_DOV : get dov failed` 来自 `getBTMAC` 拼 WiFi 名，
与显示层无关（§45.1）。

已知限制：原厂镜像不含背景 `.yuv`、guest 也没有 `/dev/fb1`，所以
window1 仍是空层（当前用的是背景**色**而非背景位图）。另有右下角进场动画
首帧残块（§42.6）、`ambTemperature` 已喂但 P 档不上屏（§42.8）。
OTA Update 处于引导阶段，当前 QEMU 直接加载内核，因此 OTA 模式、
P2P 传输和虚拟 NAND 刷写尚未仿真。详细进度见
[EMULATION.md](../docs/EMULATION.md) §24–§45。

测试：

```bash
FLUTTER_SUPPRESS_ANALYTICS=true "$FLUTTER" test
# 端到端（真实 QEMU，约 2–4 分钟）
FLUTTER_SUPPRESS_ANALYTICS=true "$FLUTTER" test test/boot_integration.dart
```

