# Sunplus SP8368 + GD32 MCU · 虚拟化后端方案

> 目标：在 QEMU 里跑**原装** AE5i/150Aura 系统（原厂 Linux-4.9.217 内核 + 原厂 rootfs/spsdk/spapp），
> 并把 **GD32 MCU** 也虚拟化，使按键、车辆信号、电源状态走真实 CFCP 链路，而不是 QEMU 假键盘。
> 本文是后端架构与实施规格；实测记录见 `SUNPLUS-MEMMAP.md` / `m1-bootlog.txt`。

---

## 1. 总体架构

```
┌────────────────────────── 宿主 macOS ──────────────────────────┐
│                                                                │
│  ┌─────────────────────┐        ┌──────────────────────────┐   │
│  │ QEMU (自建 v9.0.0)  │        │  GD32 MCU 模拟器 (新)     │   │
│  │  -M sunplus-sp8368  │        │  - CFCP 帧生成/解析       │   │
│  │                     │        │  - 车辆信号模型           │   │
│  │  RAM@0              │        │  - 按键脚本/UI            │   │
│  │  GIC@0x9F101000     │        │                          │   │
│  │  timer 27MHz        │        │                          │   │
│  │  UART0..3           │        │                          │   │
│  │   └ UART1 = ttyS1 ──┼──pty/──┼─ CFCP 帧 (双向)          │   │
│  │  PSU@0x9C000000     │ socket │                          │   │
│  │  blockrom/NAND      │        └──────────────────────────┘   │
│  │  显示/PFC           │                                       │
│  │  sunplus-vdisk ─────┼── SPVD 文件（NAND 扁平页 + 分区表）    │
│  └─────────┬───────────┘                                       │
│            │ 帧缓冲 / 串口日志                                  │
│  ┌─────────▼───────────┐                                       │
│  │ Flutter 前端        │  screendump → 画面；按键 → CFCP        │
│  └─────────────────────┘                                       │
└────────────────────────────────────────────────────────────────┘
```

**存储数据面已落地**：`sunplus-vdisk` 设备 + SPVD 容器（§2.1），NAND 内容以
「去 OOB 的扁平页 + 自描述头」形式交给虚拟化平台，内核侧还需 `sp_spinand` 控制器模型才能消费（见 §2.2）。

**两条独立通道**：
- **SoC 侧**：QEMU 机器模型提供 CPU/RAM/GIC/timer/UART/PSU/blockrom/显示。
- **MCU 侧**：宿主进程模拟 GD32，通过 `ttyS1` 与 SoC 交换 **CFCP 帧**。SoC 侧内核驱动 `rcar-taurus-cfcp.ko`
  （在 spsdk 里，启动后 insmod）绑定 `/dev/ttyS1`，把 KeyID 转成 Linux input 事件。

---

## 2. SoC 侧设备模型（SP8368/GEMINI）

| 设备 | 物理地址 | 状态 | 说明 |
|---|---|---|---|
| RAM | `0x0` | ✅ M1 | 256MB；内核链接 `0x408000`，ATAG_MEM start=0 |
| GIC-400 | `0x9F101000`(dist)/`0x9F102000`(cpu) | ✅ M1 | `arm_gic` GICv2，256 IRQ |
| ARM generic timer | — | ✅ M1 | `gt_cntfrq_hz=27000000` |
| K_TTYS UART ×4 | `0x9C102080/2100/4080/4100` | 🟡 M1 部分 | TX/LSR 已实现；**RX + IRQ 未实现**（CFCP 需要） |
| PSU/时钟 | `0x9C000000` (128KB) | 🟡 M1 桩 | 已可 trace（`SP_PSU_TRACE=1`）；语义未建模 |
| sysctl | `0x9C10A000` (4KB) | 🟡 M1 桩 | RAM |
| blockrom / SPI NAND | 驱动 device @`0xC0822F1C` | ❌ M3 | 板级配置 + rootfs 都靠它 |
| **sunplus-vdisk** | 数据窗 `0x50000000` / 寄存器 `0x40000000` | ✅ 2026-10-30 | SPVD 虚拟硬盘：NAND 扁平页线性窗 + 只读分区/几何寄存器窗 |
| PFC 显示控制器 | 待反解 | ❌ M4 | Launcher 输出面 |
| CFCP 串口 | UART1 = `ttyS1` | 🟡 | 需 UART RX/IRQ + MCU 模拟器 |

### 2.1 SPVD 虚拟硬盘（NAND 数据面，2026-10-30 落地）

目的：让虚拟化平台**直接吃 NAND 数据**，不必每次改代码/改镜像。SPVD 是 VHD 的类似物，
但按 Sunplus SPI-NAND 语义组织：一个自描述头 + 去 OOB 的扁平页序列。

**容器格式 v1（小端）**

| 偏移 | 字段 | 说明 |
|---|---|---|
| `0x000` | `char magic[4]` | `"SPVD"`（字节 53 50 56 44） |
| `0x004` | `u32 version` | 1 |
| `0x008/0x00C` | `u32 page_size / oob_size` | 4096 / 256（150Aura XT26G04C） |
| `0x010/0x014` | `u32 ppb / blocks` | 64 / 2048 |
| `0x018` | `u32 page_count` | 131072 |
| `0x01C` | `u32 data_offset` | 0x1000 |
| `0x020` | `u64 data_size` | 536870912 |
| `0x028/0x02C` | `u32 bad_count / part_count` | 5 / 10 |
| `0x030/0x034` | `u32 flags / header_crc32` | CRC 覆盖 `0x000..0x034` |
| `0x100` | `u32 bad_blocks[]` | 块号（本机 383/716/1049/1382/1715） |
| `0x400` | 分区项 44B | `name[32] + u32 addr + u32 size + u32 rsvd` |
| `0x1000` | 扁平页数据 | 逻辑页 N 位于 `N*page_size`，**OOB 已剔除** |

关键取舍：**扁平化**。分区表里的 `addr` 是「逻辑页起始字节」，与数据窗线性一致；
宿主机不需要在运行时处理坏块稀疏布局（坏块号只作为元数据给出，供将来的 FTL/控制器模型使用）。

**设备侧（`hw/arm/sunplus-sp8368.c`，`TYPE_SP_VDISK`）**

| Region | 地址 | 内容 |
|---|---|---|
| 0 | `0x50000000`（`SP_VDISK_BASE` 可改） | `mmap(MAP_PRIVATE)` 的扁平页数据，`memory_region_init_ram_ptr`，客机按页线性读 |
| 1 | `0x40000000` | 只读寄存器窗：`+0x00` magic、`+0x08` page_size、`+0x0C` page_count、`+0x14` blocks、`+0x18` bad_count、`+0x1C` part_count、`+0x20` ppb、`+0x24` oob；`[0x400,0xC00)` 透传分区表 |

挂载方式：环境变量 `SP_VDISK=/path/x.spvd`（可选 `SP_VDISK_BASE=0x..`）。
realize 时校验 magic 并打印：
`SP_VDISK: ... page=4096 oob=256 ppb=64 blocks=2048 pages=131072 data=536870912 bad=5 parts=10`。

**实测验证（2026-10-30，monitor `xp` 读回）**

| 位置 | 期望 | 实测 |
|---|---|---|
| `0x40000000` | magic `0x44505653` | ✅ |
| `0x50000000+0x800000` | uImage `27051956` | ✅ |
| `+0xC80000` / `+0x1180000` / `+0x4180000` | 三个 `hsqs`（squashfs） | ✅ rootfs / spsdk / spapp |
| 坏块 383 首页 | 全 `0xFF`（擦除态） | ✅ |

**工具**：`tools/nand2spvd.py`

```bash
python3 tools/nand2spvd.py "<nand dump>.BIN" /tmp/150aura.spvd   # 自动判定几何
python3 tools/nand2spvd.py --info /tmp/150aura.spvd              # 自检（CRC/坏块/分区）
```

### 2.2 数据面 ≠ 内核可消费：还差 `sp_spinand` 控制器模型

SPVD 提供的是**数据**（扁平页 + 分区描述），而内核里的 `sp_spinand` 驱动只认
**控制器寄存器协议**（命令/地址/读缓存）。因此在 vdisk 之上仍需一层控制器模型：

| 层 | 现状 |
|---|---|
| 数据 + 分区元数据（SPVD / `sunplus-vdisk`） | ✅ 已完成 |
| SPI NAND 控制器命令协议（`sp_spinand`：page read / cache read / ID / status / ECC 状态） | ❌ 下一步（M2/M3 共同前提） |
| MTD → `blockrom` → squashfs / `runtime_cfg` | ❌ 随上一行解锁 |

⇒ **M2 仍未完成**：本轮把「NAND 内容怎么交给虚拟机」解决了，尚未把「内核怎么问 NAND」接上。
控制器模型完成后，`runtime_cfg` 才能被内核读到 → UART probe → `ttyS0` console。

**已从真车日志拿到全部控制器参数**（详见 `NAND-150AURA.md` §4）：

| 项 | 值 |
|---|---|
| 寄存器窗 | `0x9C002B80`，84 B —— 在 PSU 块内，需像 UART0 一样以 subregion 叠加 |
| DMA 缓冲 | 物理 `0x07844000`，4608 B（4096 + 512 spare） |
| IRQ | 55 |
| MTD | `sp_spinand.0`，25 个 cmdlinepart 分区 |

**当前真实卡点不在 NAND**：内核跑到 `0.121s` 后停在 `ipc:1.6`，CPU 位于 `cpu_ca15_do_idle`
（`dsb; wfi`），`SP_PSU_TRACE=1` 零 PSU 访问 → 驱动还没走到 SPI-NAND probe，
是 `ipc:1.6` 之后的 initcall 睡住（大概率 EIPC 与 eCos 协核的握手）。要先解决这一层。

### 2.3 M2 卡点（已实测定位，2026-10-30 修正）

内核日志（`m1-bootlog.txt`）：

```
sp_config_init() failed
Console: colour dummy device 80x30
sp_bootup_prot_get_range: invalid index 0
```

- `sp_config_init`（initcall @`0xC04196E8`）读两个全局 `0xC08056C0/0xC08056C4`（板级 config 块指针/长度），
  为空则返回 -1。**config 缺失 → 板级 platform device（含 UART）未注册 → K_TTYS 不 probe → 无 ttyS**。
- PSU 侧只观测到 5 次访问（`rd/wr 0x7A18`、`rd 0x81DC`），说明 UART 根本没走到 `sp_psu_activate`。
- `sp_clk_init` @`0xC07EA568` 是**空桩**（`movs r0,#0; bx r0`），时钟框架在本内核里不生效。

**★ 关键修正（用户实测：该镜像烧进 AE5i 能正常点亮、按键可用）**

config 一定存在于镜像中。U-Boot 里找到了证据：

```
runtime_cfg
runtime.cfg
nand_offread 0x%x 0x%x 0x%x 0x%x
ERROR: runtime config nand read failed, addr = 0x%x, %d.
```

即 **U-Boot 从 NAND 的 `runtime_cfg` 分区读出配置，加载到内存后交给内核**。
内核侧对应 `sp_spinand`(Sunplus SPI NAND 控制器) → MTD → `blockrom`/yaffs2 全栈。

⇒ **正确做法不是「注入 config」，而是像真机一样建模 NAND/blockrom**，让内核自己读 `runtime_cfg` 与 rootfs。
M2 与 M3 因此合并：**SPI NAND 模型是两者的共同前提**。

| 方案 | 评价 |
|---|---|
| **A. 建模 `sp_spinand` + MTD 分区表**，把镜像分区按物理地址喂给驱动 | **正解**：最忠实，config/rootfs/日志全走真机路径 |
| B. 只在 U-Boot 加载地址处注入 config 块 | 快，但要先精确定位 U-Boot 的加载地址与内核取用方式 |
| C. 改内核补 device | 与「原装内核」约束冲突，不做 |

> 结论：M2 不是 PSU 寄存器问题，而是**板级 config 供给问题**。先做 A（若你能提供分区 dump）或 B。

---

## 3. GD32 MCU 侧虚拟化

### 3.1 真实链路（已确认）

```
把手开关 → GD32 MCU → CFCP 帧 → /dev/ttyS1 → rcar-taurus-cfcp.ko → cfcp-keypad → Linux input → UI
```

- 帧字段：`Header / FRAME0 / FRAME1 / LEN / CMD / DATA / CheckSum / Tail`，
  含 `FunctionType`、`field_ACK`、`cmdid`、`vhal(pid/aid)`，带**重传队列 + ACK 等待**。
- 内核日志锚点：`CFCP_KEY:KeyID(0x%x) Press/Release`、`cfcp_keypad_probe success`。
- 用户态消费者：`libmcucommodule.so`、`libvehiclesignalmodule.so`（`updateGear/updateCurrentPower/reverseGear`）、
  `libpowermanagermodule.so`（`accOn/accOff`、`normalBoot/wakeupBoot`、`openScreen/closeScreen`）。
- 唤醒源：`WAKE_SRC_ACC`、`WAKE_SRC_POWER_KEY`、`WAKE_SRC_MCU_WDG`、`WAKE_SRC_ON_CALL_KEY`、`WAKE_SRC_POWERFAILE`。

### 3.2 MCU 模拟器设计

**形态**：独立宿主进程（Python 或 C），通过 pty/socket 与 QEMU 的 UART1 相连。

| 模块 | 职责 |
|---|---|
| 传输层 | 打开 QEMU 暴露的 `/dev/ttysXXX`（或 TCP），按 CFCP 帧收发，处理分帧/校验 |
| 协议层 | 解析 SoC→MCU 命令；生成 MCU→SoC 上报，维护 `ACK` 与重传计数 |
| 车辆模型 | 车速、电量、里程、温度、档位/模式、Ready、故障码；可按脚本变化 |
| 按键注入 | 面板点击 → 构造 `KeyID` 帧（Press/Release 成对）→ ttyS1 |
| 电源状态 | ACC on/off、唤醒源、休眠/唤醒时序 |
| 观测 | 帧日志（十六进制 + 解码），与 QEMU 串口日志并列显示 |

**QEMU 侧接线**：
```
-serial null -serial chardev:cfcp ...   # UART1 绑定 socket chardev
-chardev socket,id=cfcp,path=/tmp/cfcp.sock,server=on,wait=off
```
（当前机器模型把 4 个 UART 都映射了；需让 UART1 用独立 chardev，并实现 RX + IRQ。）

**UART RX/IRQ 需求（M2/M4 必做）**：
- 收字符 → 放入 FIFO，拉高 IRQ；
- 驱动读数据寄存器时清中断；
- 需匹配 K_TTYS 的寄存器语义（接收数据寄存器偏移、IIR/状态位）。

**已从驱动反解出的 K_TTYS 寄存器事实**（`sunplus_uart_irq` @`0xC05676C4`、`ops_startup` @`0xC056738C`）：

| 偏移 | 用途 |
|---|---|
| `+0x00` | TX 写 / RX 读（数据寄存器） |
| `+0x04` | LSR（bit0 = TX ready；console 轮询此位） |
| `+0x1C` | **中断状态**：bit1 与 `(val & 0x11) == 0x11` 参与中断判定 |

> 注意：**不是 16550 布局**（16550 的 LSR 在 +5、IIR 在 +2），所以不能直接用 QEMU `serial`。
> RX FIFO 深度、IIR 具体位义与清除方式仍需继续反解 `sunplus_uart_irq` 的完整分支。

### 3.3 按键映射（待逐键实测）

| 物理键 | KeyID | 备注 |
|---|---|---|
| 导航上/下/左/右 | 待测 | 由 CFCP 帧捕获 |
| SET / BACK | 待测 | |
| 加减档 | 待测 | AE5i 无档位，映射驾驶模式 |
| Ready | 待测 | 电源状态机 |
| 其余 | 待测 | 用 `CFCP_KEY:KeyID(0x%x)` 日志逐键采集 |

> 采集方法：真机串口跑 `dmesg -w | grep CFCP_KEY`，逐键按下记录 KeyID + Press/Release。

---

## 4. 里程碑

| 里程碑 | 内容 | 验收 |
|---|---|---|
| **M1** ✅ | 机器模型跑起原装内核（RAM/GIC/timer/UART/ATAGS） | `__log_buf` 出现 `Booting Linux` / `Memory:` |
| **M1.5** ✅ | **SPVD 虚拟硬盘 + `sunplus-vdisk`**：NAND 数据（去 OOB 扁平页 + 分区表 + 坏块）交给虚拟机；前端直接从 NAND 抽内核启动 | `SP_VDISK:` 打印 + `xp 0x50800000` 见 uImage、三处 `hsqs` |
| **M2** 🟡 | **`sp_spinand` 控制器协议**（在 SPVD 之上）+ MTD 分区 → 内核读到 `runtime_cfg` → UART probe → `ttyS0` console | 串口直接输出完整 dmesg |
| **M3** | 同一数据面继续提供 rootfs 分区 → 挂载 → `Run /init` | 内核执行到 `/init` |
| **M4** | PFC 显示 + spsdk 服务链 → Launcher | 画面点亮 |
| **M5** | GD32 MCU 模拟器 + CFCP → 按键/车辆信号闭环 | 按键触发真实功能 |

> M2/M3 共用同一数据面：SPVD 解决「数据从哪来」，`sp_spinand` 解决「内核怎么读」，
> 两者合起来才是完整 NAND。先出 `runtime_cfg` 让 console 通，再补其余分区推进 M3。

---

## 5. 工具与复现

```bash
# 构建（macOS arm64，必须用 /opt/homebrew 依赖）
cd Gemini-Dummy/qemu-src
export PATH="/opt/homebrew/bin:$HOME/.local/bin:$PATH"
export PKG_CONFIG_PATH=$(ls -d /opt/homebrew/opt/*/lib/pkgconfig | tr '\n' ':')
export PYTHON=<有 distlib 的 python3>
./configure --target-list=arm-softmmu --disable-werror \
  --disable-sdl --disable-gtk --disable-opengl --disable-vnc --disable-curses
ninja -C build qemu-system-arm

# 1) NAND dump → SPVD（自动判几何；写几何/坏块/分区 + CRC32）
python3 tools/nand2spvd.py \
  "../rawimage/春风150aura  XT26G04C(x1+ISP)@WSON8(8x6mm).BIN" /tmp/150aura.spvd
python3 tools/nand2spvd.py --info /tmp/150aura.spvd

# 2) 启动（内核从 SPVD 现场抽出，无需外部 Image）
SP_VDISK=/tmp/150aura.spvd ./build/qemu-system-arm \
  -M sunplus-sp8368 -m 256 -kernel /tmp/ae5i-kernel-Image.bin \
  -append 'console=ttyS0,921600 loglevel=7' \
  -serial file:/tmp/sp_boot.log -display none -no-reboot \
  -monitor unix:/tmp/ae5i-mon.sock,server,nowait

# 3) 前端同一条路径自检（自建 QEMU → SPVD → 抽内核 → 拉起）
cd flutter_app && dart run tool/boot_check.dart --run 6

# PSU 访问追踪
SP_PSU_TRACE=1 ./build/qemu-system-arm ...

# 提取内核日志（无 console 时的取证手段）：ring buffer 在 0x836000
#   monitor: pmemsave 0x836000 0x40000 "/tmp/ringbuf.bin"    ← 文件名必须带引号
#   strings -a -n 8 /tmp/ringbuf.bin | grep -E 'Booting Linux|Memory:|sp_config'
```

---

## 6. 对「原装内核」约束的遵守

- 机器模型只提供**硬件**，不改内核代码。
- 唯一对内核镜像的改动是**启动参数字符串**（内置 cmdline 后追加 `console=`/`earlycon=`），
  用于无 console 时的取证；若不允许，M2 走「板级 config → 真实 ttyS0」路线即可完全不动内核。
- 所有反解地址来自 `vmlinux-to-elf` 恢复的 19,729 个符号，未做猜测。

---

## 7. 仿真客户端结构：Flutter 前端 + 自建 Sunplus QEMU 后端

### 7.1 为什么必须自建 QEMU

系统 `qemu-system-arm`（Homebrew 11.x）**没有** `sunplus-sp8368`，用 `-M virt` 跑出来的是通用
Cortex-A7 + virtio，和真机的 PSU/PSU 内嵌 UART/SPI NAND/PFC 全不对应（此前正是因此卡在
「Launcher 启动即 segv」）。所以后端固定为 `Gemini-Dummy/qemu-src/build/qemu-system-arm`，
前端解析路径时**找不到就报错，绝不回落系统 QEMU**。

### 7.2 进程与通道

```
┌──────────────── Flutter 主进程（前端 UI）────────────────┐
│  EmuPage ── QemuController ── SerialBridge(TCP 9001)     │
│                  │  ▲                    ▲               │
│   unix monitor ──┘  │ stdout(串口)       │ 外部终端连接   │
└──────────────────────┼────────────────────┼──────────────┘
                       │                    │
┌──────────────────────▼────────────────────┴──────────────┐
│            qemu-system-arm -M sunplus-sp8368             │
│   RAM@0 · GIC@0x9F101000 · timer 27MHz · UART0..4        │
│   sunplus-vdisk: 数据窗@0x50000000 / 寄存器@0x40000000     │
└──────────────────────┬───────────────────────────────────┘
                       │ SP_VDISK=/path/xxx.spvd（mmap）
                  ┌────▼─────┐
                  │ SPVD 文件 │  NAND 扁平页 + 分区表 + 坏块表
                  └──────────┘
```

- **无 HTTP**：前端直接持有子进程。
- 画面：`monitor screendump` → PPM → RGBA → `RawImage`（PFC 未建模前恒为「等待画面」）。
- 按键：`monitor sendkey` 占位；M5 改为向 CFCP chardev 写 KeyID 帧。
- 串口：`-serial stdio`；`SerialBridge` 把同一份字节流镜像给 `tcp://127.0.0.1:9001`，
  外部 `nc` / `picocom` 可直接接管 console。

### 7.3 前端分层（`Gemini-Dummy/flutter_app/lib/`）

| 文件 | 职责 | 是否可单测 |
|---|---|---|
| `emu/paths.dart` | 路径解析：自建 QEMU、SPVD 候选、原始 dump、内核缓存路径 | ✅ |
| `emu/spvd.dart` | SPVD 头/坏块/分区解析、CRC32、`extractKernel()`（uImage → 裸 Image） | ✅ |
| `emu/machine.dart` | `MachineConst` / `LaunchSpec`（argv + env）/ `BootPreparation.prepare()` | ✅ |
| `emu/controller.dart` | 子进程、monitor、串口桥、抓帧、日志模型 | 手测 |
| `emu/keys.dart` | 实车 13 个把手控件（左 10 / 右 3） | ✅ |
| `emu/ppm.dart` | screendump PPM 解码 | ✅ |
| `main.dart` | UI（画面 / SPVD / 进程 / 日志 / 按键 五区），并 re-export 上述模块供测试 | 冒烟 |

**启动流程（`BootPreparation.prepare`）**：自建 QEMU → 找 SPVD → 校验 magic/CRC →
从 `kernel` 分区抽 uImage 载荷到 `/tmp/ae5i-kernel-Image.bin` → 组 `LaunchSpec`。
任何一步失败都给出可照抄的修复命令，而不是抛异常。

### 7.4 环境变量

| 变量 | 作用 |
|---|---|
| `AE5I_QEMU_BIN` | 覆盖自建 QEMU 路径（默认 `qemu-src/build/qemu-system-arm`） |
| `AE5I_SPVD` | 覆盖 SPVD 路径（默认依次找 `Gemini-Dummy/images/150aura.spvd`、`/tmp/150aura.spvd`） |
| `SP_VDISK` / `SP_VDISK_BASE` | 由前端自动注入给 QEMU；手动启动时自己给 |
| `SP_FW_FILE` / `SP_FW_TRACE` | 板级 config 注入（M2 兜底手段，保留） |
| `SP_PSU_TRACE` | 打印 PSU 寄存器访问 |

### 7.5 已验证 / 未验证

已验证（2026-10-30）：
- `dart run tool/boot_check.dart --run 6` 全链路通过，QEMU stderr 打出 `SP_VDISK:` 与 `mapped flat data @0x50000000`。
- monitor `xp` 抽查：uImage `27051956`、rootfs/spsdk/spapp 三处 `hsqs`、坏块 383 首页全 `FF`。
- 客机 ring buffer：`Booting Linux on physical CPU 0x0` / `Linux version 4.9.217` / `Memory: 251328K/262144K`，
  随后仍是 `sp_config_init() failed` + `Console: colour dummy device 80x30` → **M2 状态不变**。
- `flutter analyze` 无问题；`flutter test` 10/10 通过。

未验证：画面（PFC 未建模）、按键真实效果（CFCP 未接）、AE5i 数据面（几何 2048+128 / PPB 128，
坏块 `335/620/905/1190/1475/1760`，需另一份 SPVD）。
