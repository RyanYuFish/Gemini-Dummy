# qemu-src —— Gemini-Dummy 用的 QEMU 分叉

这是 **QEMU v9.0.0** 的源码树（上游：https://gitlab.com/qemu-project/qemu ，GPLv2），
加上本项目自建的 ARM 机器模型，用来跑 ZEEHO AE5i 仪表的**原厂**内核与 spapp。

## 相对上游 QEMU v9.0.0 的改动（共 5 个文件）

| 文件 | 改动 |
|---|---|
| `hw/arm/sunplus-sp8368.c` | **新增**（本项目核心，约 4.8k 行）：`sunplus-sp8368` 机器模型 |
| `hw/arm/meson.build` | 注册新机器 |
| `hw/arm/Kconfig` | 新机器的 Kconfig 项 |
| `hw/arm/boot.c` / `include/hw/arm/boot.h` | 启动时把原厂内核参数（cmdline）传给 guest |

补丁集同时单独导出在 [`../patches/qemu/gemini-dummy-v9.0.0.patch`](../patches/qemu/gemini-dummy-v9.0.0.patch)，
想从纯净上游重建可以用：

```bash
git clone --depth 1 --branch v9.0.0 https://gitlab.com/qemu-project/qemu.git
cd qemu && git apply /path/to/gemini-dummy-v9.0.0.patch
```

> 本目录里的 `build/` 是本地编译产物（已 gitignore）。**改完模型必须重新编译**，
> 见 [`../tools/build_model.py`](../tools/build_model.py)（macOS 上 meson 只产
> `qemu-system-arm-unsigned`，脚本会 codesign 后同步到 `build/qemu-system-arm`）。

## 模型能力速览（`hw/arm/sunplus-sp8368.c`）

- 原厂 Sunplus SP8368 / GEMINI 平台：RAM@0、UART 3K_SPPSU、timer 27 MHz、PSU@0x9C000000、
  blockrom flash、I²C、GPU 2D 寄存器；
- **SoC IPC 邮箱桩**（`sp_ipc_stub`）：按 `rpc_isr` 的规则在「内核等待者」与「用户态 fifo」
  之间路由应答；
- **显示**：3 个 fb 窗口 + PFC/VPP/DMIX 寄存器追踪 + 按层合成导出 PPM；
- **翻页 copy front→back**（`_ipc_swapbuf` 之后整页复制）：这是增量绘制的 Qt QPA 正确工作的前提，
  详见 [`../docs/EMULATION.md`](../docs/EMULATION.md) §42；
- 调试开关一律走环境变量 `SP_*`（清单见 [`../README.md`](../README.md) §5.1）。
