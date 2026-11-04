# AE5i 仪表模拟器

项目最终目标是完整仿真 AE5i 仪表功能，包括画面渲染、原生按键、电源状态、蓝牙、Wi-Fi、RS-485 通讯和 OTA Update 全流程；之后基于原厂 Qt 用户态定制仪表 UI，通过仪表蓝牙连接 APT F600 读取/修改参数、读取蚂蚁 ANT BMS 与电池计量信息，并最终用 OTA Update 无线刷入实车。

**当前客户端能力**：运行 AE5I 原厂 Linux-4.9.217 和 Qt Launcher，可显示 800×480 framebuffer；启动时可选择 SPVD，显示启动动画和 QEMU 启动状态；上、下、SET、BACK 支持按下、长按和释放；串口日志可实时查看并导出。蓝牙/Wi-Fi/RS-485 车辆外设仿真与 OTA Update 完整刷写流程尚未实现；详细状态和验收路线见 [EMULATION.md](../docs/EMULATION.md) 文首、§37。

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

状态机只驱动客户端与 QEMU 生命周期，**不伪造未经确认的 MCU/TBOX 认证帧**；画面左上角的解锁状态是客户端 HUD，不代表仪表固件已认证。原厂 `anm_logo/logo.mkv` 帧现由 QEMU 模型重放。MCU 面板显示 SoC 回传的灯态位图、状态与心跳；CFCP 属性是状态镜像，写入属性不会驱动主表盘。P/READY 主画面仍缺 MCU→SoC 上行车辆数据，§38 的 ride-info 探针只到缓存层，当前研究转向 `vehicle_info1/2/3` bytes 属性。PFC 背景合成未闭环，实体 GPU 加速暂挂。OTA Update 处于引导阶段，而当前 QEMU 直接加载内核，因此 OTA 模式、P2P 传输和虚拟 NAND 刷写尚未仿真。详细进度见 [EMULATION.md](../docs/EMULATION.md) §24–§38。

测试：

```bash
FLUTTER_SUPPRESS_ANALYTICS=true "$FLUTTER" test
# 端到端（真实 QEMU，约 2–4 分钟）
FLUTTER_SUPPRESS_ANALYTICS=true "$FLUTTER" test test/boot_integration.dart
```

