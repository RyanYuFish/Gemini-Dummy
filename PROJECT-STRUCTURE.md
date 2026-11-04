# Gemini-Dummy 工程结构

`Gemini-Dummy` 只保留可复现仿真启动链所需的源码、镜像和验证工具。对外分享前先读 [`README.md`](./README.md) 的「合规红线」。生成内容统一放在 `dist/`（项目级）或 Flutter 的 `build/`，不作为源码提交。

| 路径 | 用途 | 处理原则 |
| --- | --- | --- |
| `qemu-src/` | 自建 QEMU `sunplus-sp8368` 机器模型和构建树 | 修改模型后运行 `tools/build_model.py` |
| `flutter_app/` | macOS 仿真器客户端、控制器、SPVD 解析、按键和测试 | 用外部 Flutter SDK 构建（`FLUTTER` 环境变量指定） |
| `images/` | AE5I/历史对照 SPVD 与原装内核 | 原始验证输入，不覆盖 |
| `tools/` | SPVD、guest shell、fb/GPU/CFCP 工具 | 脚本输出写入 `dist/` 或 `/tmp` |
| `tests/` | GPU 2D、CFCP 协议回归 | 修改模型或按键协议后运行 |
| `docs/` | 仿真方向、内存图、后端设计和启动记录 | 进度同步到 `docs/EMULATION.md` |
| `patches/` | guest 启动配置补丁 | 仅作输入材料，不直接替换 `firmware/` |
| `logs/` | 历史启动日志 | 不作为运行时日志目录 |
| `firmware/` | 仿真辅助固件片段 | 只读基线，禁止覆盖 |

## 常用命令

```bash
cd Gemini-Dummy
python3 tools/build_model.py          # 编译模型（macOS 必须用这个脚本）
bash run_ui.sh                        # 起仿真器（另开终端跑下面的喂食）
python3 tools/dash_up.py --duration 20 --png /tmp/out.png   # MCU 对端：点亮仪表
python3 tests/test_gpu_2d.py
python3 tests/test_cfcp_key.py

cd flutter_app                        # 可选：macOS 图形客户端
export FLUTTER=/path/to/flutter/bin/flutter
HOME=/tmp FLUTTER_SUPPRESS_ANALYTICS=true "$FLUTTER" test
HOME=/tmp FLUTTER_SUPPRESS_ANALYTICS=true "$FLUTTER" build macos --release
```

Flutter SDK **不再内置于本仓库**（原 `Gemini-Dummy/flutter-sdk/` 已于 2026-11-01 清理，见 `docs/EMULATION.md` §26）。
用外部 SDK，由 `FLUTTER` 环境变量指向其 `bin/flutter`；所有 flutter 命令必须带
`HOME=/tmp FLUTTER_SUPPRESS_ANALYTICS=true`（pub 缓存/analytics 写 `/tmp`）。

> 项目总入口与对外说明见 [`README.md`](./README.md)；文档导航见 [`docs/README.md`](./docs/README.md)。

⚠️ SDK 在 home 目录时，**沙箱内**跑 `test`/`build` 会因 unlink `bin/cache/engine.stamp.tmp.*` 被拒（`flutter --version` 不写 stamp，所以能过，别被误导）。需让命令获得沙箱放行，或把 SDK 放回工作区内。

实测（2026-11-01）：`pub get` 通过、`test` **66 项全过**、`analyze` 无问题、端到端 `test/boot_integration.dart` **21 秒通过**（真实 QEMU 全程）。

`__pycache__`、`.DS_Store`、Flutter `.dart_tool`、`build/` 和 `macos/Flutter/ephemeral` 都是可再生内容；整理时可以清除。`qemu-src/build/` 的 QEMU 可执行文件是运行依赖，不能按普通临时目录删除。

## 当前 macOS 验收包

Release 客户端：`flutter_app/build/macos/Build/Products/Release/ae5i_emu.app`

该包为 universal macOS 应用（`arm64` + `x86_64`，约 40 MB，ad-hoc 签名）。打开后可选择 `dist/qemu-ae5i/ae5i-software.spvd` 或其他有效 SPVD；QEMU 可执行文件仍由 `qemu-src/build/qemu-system-arm` 提供。
