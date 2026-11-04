# Sunplus SP8368/GEMINI · 原装内核内存映射（QEMU 机器模型依据）

> 来源：`春风150aura XT26G04C@WSON8.BIN` 偏移 `0x880000` 的 uImage（`Linux-4.9.217`，原始未压缩 Image，THUMB2）。
> 方法：`vmlinux-to-elf --e-machine 40 --bit-size 32` 从 kallsyms 恢复 **19,729 个符号**，再静态反汇编板级函数。
> 用途：这是「自建 Sunplus 机器模型」的规格书——QEMU 必须在该物理地址上提供对应设备，原装内核才可能启动。

---

## 1. 内核基址

| 项 | 值 |
|---|---|
| 镜像 | `Linux-4.9.217`（`#1 Mon Jul 21 20:26:22 CST 2025`，gcc 9.2.1 aarch32） |
| 类型 | **原始未压缩 ARM Image**（uImage `comp=0`，入口 `adr r9; bx r9`，THUMB2） |
| 物理加载/入口 | **`0x00000000 + 0x408000 = 0x408000`** |
| 内核虚拟基址 | **`0xC0408000`**（kallsyms_relative_base 解出） |
| PAGE_OFFSET | **`0xC0000000`** ⇒ **DRAM 物理基址 = `0x0`** |
| vermagic | `6.12...` 无关；本内核 `4.9.217 mod_unload modversions ARMv7 thumb2 p2v8` |
| 设备树 | **无**（全 512MB dump 无 `d00dfeed`，U-Boot 内也无）⇒ 板级文件 + ATAGS |

> **这是与 QEMU `virt` 的根本冲突**：virt 的 RAM 在 `0x40000000`，而本内核要在 `0x408000`。故必须自建机器（RAM@0x0）。

---

## 2. 静态 IO 映射（`sp_map_io` → `iotable_init(map_desc, 3)`）

`map_desc` 数组 @ `0xC07FB138`，3 项（`virtual, pfn, length, type`）：

| # | 虚拟地址 | 物理地址 | 长度 | 推断用途 |
|---|---|---|---|---|
| 0 | `0xF0800000` | **`0x9C000000`** | `0x20000` (128KB) | PSU / 时钟 / 引脚 / 系统控制主块 |
| 1 | `0xF0820000` | **`0x9F101000`** | `0x3000` (12KB) | **GIC**（分发器 + CPU 接口） |
| 2 | `0xF0823000` | **`0x9C10A000`** | `0x1000` (4KB) | 系统控制 2（复位/看门狗类） |

- `sp_init_irq` 调 `gic_init(0, 0x1d, 0xF0820000, 0xF0821000)` ⇒ GIC 分发器物理 **`0x9F101000`**、CPU 接口 **`0x9F102000`**，中断数上限 `0x1d`(29)。
- `sp_init_early` 写 `0xF0823000`(=物理 `0x9C10A000`) 值 3 ⇒ 系统控制寄存器。

---

## 3. UART（K_TTYS / `sunplus_uart`）

平台资源（`struct resource`，`flags=0x200 IORESOURCE_MEM`，另配 `flags=0x400 IORESOURCE_IRQ`）：

| UART | 物理基址 | 范围 | IRQ | 备注 |
|---|---|---|---|---|
| UART0 | **`0x9C102080`** | `+0x80` | **216 (0xD8)** | |
| UART1 | **`0x9C102100`** | `+0x80` | **215 (0xD7)** | |
| UART2 | **`0x9C104080`** | `+0x80` | 待精确 | |
| UART3 | **`0x9C104100`** | `+0x80` | **221 (0xDD)** | |

- 驱动：`sunplus_uart_platform_driver_probe`（`0xC0567160`），端口表 `0xC0820CA4`，步长 `0x18`。
- 控制台：`sp_uart.uart0_as_console` 模块参数；`sunplus_uart_console_putchar` @ `0xC056768C`（写 `membase+0x00` 发字符、读 `+0x04` 查 LSR bit0）。
- 时钟由 `psu_peripheral_uart0..3` 控制（PSU 块 `0x9C000000`）。
- **注意**：真机调试口是 `ttyS0@921600`；内核里另有 `UART4(UARTDBG)` 的 DMA 限制提示。首版机器模型建议把 **4 个 UART 全部**按 0x80 窗口映射，谁被 console 选中由 `uart0_as_console` 决定。

> K_TTYS 寄存器布局接近 8250（THR@+0、LSR@+4），QEMU 可用 `serial` 设备近似，但需按 0x80 步长与上述 IRQ 布线。

---

## 4. 定时器

`sp_timer_init` @ `0xC07E1A38`：
```
bl 0xC07EA568                 ; sp timer 初始化
...
arch_timer_init_no_dt(0x019BFCC0, 0xC06CF584)
```
- **arch timer 频率 = `0x019BFCC0` = 27,000,000 Hz（27MHz）**。
- 这要求机器模型把 ARM generic timer 频率设为 27MHz（QEMU 默认 62.5MHz 会导致时间快 2.3 倍）。QEMU 的 `virt` 用 `<dt>` 传入；自建机器需在 `arch_timer` 属性里设 `clock-frequency = 27000000`。

---

## 5. 存储 / blockrom / NAND

- `blockrom_init` @ `0xC07EC4E4`；`blockrom_add_mtd` / `blockrom_readsect` / `blockrom_writesect`（把 MTD 分区暴露为 `/dev/blockromN` 块设备）。
- NAND ECC：`sp_bch`（platform_device @ `0xC0805500`，`sp_init` @ `0xC07E1A62` 注册），`sp_bch_probe` @ `0xC0614724`。
- **drivers 在 spsdk**：`/usr/local/drivers/*.ko`（含 cfcp 等），由 `init.rc` 在启动后 `insmod`。
- rootfs：`root=/dev/blockrom8 init=/init`（真机），**机器模型必须提供 blockrom 语义**（MTD 分区表 → 块设备），否则 rootfs 挂不上。
- 分区表：`dist/rescue/manifest.json`；本 dump 实际布局见 `EMULATION.md §5`。
- ⚠️ 待补：`sp_bch` 的寄存器物理基址、MTD 分区表来源（U-Boot env / 固定表）。下一步从 `sp_bch_probe` 反汇编取。

---

## 6. 已恢复的关键符号（可直接用于后续 RE）

| 符号 | 地址 |
|---|---|
| `sp_init_early` / `sp_init` / `sp_init_irq` | `0xC07E1A80` / `0xC07E1A62` / `0xC07E1A22` |
| `sp_map_io` | `0xC07E1AAE` |
| `sp_timer_init` | `0xC07E1A38` |
| `gic_init` | `0xC07E9E22` |
| `arch_timer_init_no_dt` | `0xC07ED568` |
| `sunplus_uart_platform_driver_probe` | `0xC0567160` |
| `sunplus_uart_console_putchar` | `0xC056768C` |
| `blockrom_init` | `0xC07EC4E4` |
| `sp_bch_probe` | `0xC0614724` |
| `init_machine_late` | `0xC07DF276` |

工具链：`vmlinux-to-elf`（`~/.local/bin`）、`capstone`、`dtc`、`llvm-objdump`。
复现：
```bash
python3 -c "d=open('/tmp/aura_kernel.uimage','rb').read()[64:];open('/tmp/aura_kernel_body.bin','wb').write(d)"
~/.local/bin/vmlinux-to-elf --e-machine 40 --bit-size 32 --base-address 0x408000 \
  /tmp/aura_kernel_body.bin /tmp/aura_vmlinux.elf
```

---

## 7. 机器模型规格（QEMU 侧要实现的）

| 设备 | 物理地址 | 大小 | QEMU 近似 | 难度 |
|---|---|---|---|---|
| RAM | `0x0` | ≥256MB（真机 512MB NAND，DRAM 容量待定） | `memory_region_init_ram` @0 | 低 |
| GIC-400 | `0x9F101000` | 0x2000 | `arm_gic`（GICv2） | 低 |
| ARM generic timer | — | — | `clock-frequency=27000000` | 低 |
| UART ×4 (K_TTYS) | `0x9C102080/2100/4080/4100` | 0x80 | `serial`（16550 近似） | 中（寄存器差异） |
| PSU/系统控制 | `0x9C000000` | 0x20000 | 占位 RAM/寄存器桩 | 中 |
| 系统控制2 | `0x9C10A000` | 0x1000 | 占位 | 低 |
| blockrom / NAND | 待定 | — | MTD + 块设备 | **高** |
| ATAGS / 启动参数 | — | — | 自建机器需按 Sunplus 期望传参 | 中 |

> ⚠️ **现实评估**：这是完整的 SoC 机器模型工程（RAM/UART/GIC/PSU/NAND/ATAGS），不是配置问题。建议分里程碑：
> M1 RAM+GIC+timer+UART → 看到内核早期 console 输出；
> M2 PSU/时钟占位 → 过时钟/GPIO 初始化；
> M3 blockrom/NAND → 挂 rootfs 起 init；
> M4 spsdk/spapp + 服务链 → UI。

---

## 8. M1 实测结果（2026-10-30，已跑通）

机器模型已实现并编译进自建 QEMU（源码 `Gemini-Dummy/qemu-src`，tag **v9.0.0**，仅 `arm-softmmu`，关闭 SDL/GTK/VNC）：

```
./build/qemu-system-arm -M sunplus-sp8368 -m 256 \
  -kernel /tmp/aura_kernel_body.bin \        # 原装 Linux-4.9.217 原始 Image
  -serial file:/tmp/sp_boot.log -display none -no-reboot
```

**结果：原装内核成功启动**（证据 = 从 `__log_buf` 提取，见 `docs/m1-bootlog.txt`）：

```
Booting Linux on physical CPU 0x0
Linux version 4.9.217 ... #1 Mon Jul 21 20:26:22 CST 2025
Memory: 251328K/262144K available (... 4096K cma-reserved)
sp_map_io
sp_init_early: open backlight
init arch timer
devtmpfs: initialized
sp_config_init() failed
Console: colour dummy device 80x30
sp_bootup_prot_get_range: invalid index 0    ← 停在这里（需要 blockrom 配置）
```

- ✅ RAM@0x0、GIC@0x9F101000、27MHz timer、ATAGS（machine id 0x0F34）全部被内核接受。
- ✅ 内核执行到板级 init，随后进入 `cpu_ca15_do_idle`（idle，未崩溃）。
- ⚠️ **无串口输出**：内核内置 cmdline（`CONFIG_CMDLINE` 强制）覆盖 `-append`，且 K_TTYS 驱动未 probe
  → 无 ttyS、无 earlycon 注册，console 退化为 `colour dummy`。解决办法二选一：
  1. **M2**：实现 PSU 时钟框架（`0x9C000000`），让 K_TTYS 的 `sp_psu_activate` 成功、ttyS0 注册；
  2. 或在镜像内置 cmdline 后追加 `earlycon=...`（已试，早期 console 仍未注册，需进一步确认驱动名）。
- ⚠️ **下一步阻塞**：`sp_config_init() failed` / `sp_bootup_prot_get_range: invalid index 0`
  → 板级配置从 **blockrom/NAND** 读取，需要 **M3** 的 blockrom 设备模型。

### 机器模型当前实现（`hw/arm/sunplus-sp8368.c`）

| 组件 | 实现 |
|---|---|
| RAM | `memory_region_init_ram` @0x0，默认 256MB |
| GIC | `arm_gic`（GICv2，revision 2），dist @0x9F101000 / cpu @0x9F102000 |
| Timer | `cpu->gt_cntfrq_hz = 27000000` |
| UART ×4 | 自定义 `sunplus-k-ttys-uart`：TX@+0，LSR@+4/+5 返回 0x61，IRQ 216/215/220/221 |
| PSU / sysctl | RAM 桩（0x9C000000/0x20000、0x9C10A000/0x1000） |
| Boot | `arm_load_kernel` + 自定义 `mem_start`（ATAG_MEM start=0）；loader_start=0x3F8000 使内核落 0x408000 |

### 对 QEMU 的改动（全部在 `Gemini-Dummy/qemu-src`）

1. `hw/arm/sunplus-sp8368.c`（新增机器 + K_TTYS UART）
2. `include/hw/arm/boot.h` / `hw/arm/boot.c`：新增 `mem_start` / `mem_start_set`，让 ATAG_MEM 能报 DRAM@0
3. `hw/arm/meson.build` / `hw/arm/Kconfig`：注册 `SUNPLUS_SP8368`

### 构建要点（macOS Apple Silicon）

- 用 **arm64** 依赖：`PKG_CONFIG_PATH=$(ls -d /opt/homebrew/opt/*/lib/pkgconfig | tr '\n' ':')`
  （`/usr/local` 的 glib/pixman/libpng 是 x86_64，会链接失败）
- `PYTHON=<有 distlib 的 python>`；`--disable-sdl --disable-gtk --disable-opengl --disable-vnc --disable-curses`
- gitee 镜像 HEAD 是 2024-05-23 开发快照（链接失败），须 `git checkout v9.0.0`
