# Gemini-Dummy · AE5i 仪表仿真技术文档（截至 2026-11-04）

> 最新 AE5I GPU、CFCP/GD32 对端与 P/READY 实测见 §18、§25–§29、§36、§38；当前总路线及 OTA Update 全流程仿真验收见 §37。此前章节保留当时的实验记录。

## 项目最终目标与开发路线

**仿真器最终要完整模拟 AE5i 车辆仪表及其对外接口**，包括启动和整套画面渲染、原生按键、电源/解锁/READY、MCU 与车辆数据、蓝牙、Wi-Fi、RS-485 协议通信，以及 OTA Update 模式。OTA 必须覆盖进入原厂更新模式、选包、传输、校验、虚拟分区刷写、重启、故障和恢复；这是仿真器的核心目标，也是开始定制固件前的验收门槛。

完成仿真后，基于 AE5i 原厂 Qt 用户态开发自制仪表 UI，保留原厂启动链、内核及仪表已有通信硬件。最终让自制 UI 能通过仪表蓝牙连接车辆电机控制器，读取和修改控制器参数，并读取电池组 BMS 信息；目前目标设备为 APT F600 电机控制器、蚂蚁 ANT BMS 和电池计量模块。之后通过 OTA Update 渠道将经过仿真验证的固件无线刷入实车。

设备能力、蓝牙角色、Wi-Fi/P2P 用途以及电机控制器/BMS 实际使用的 BLE、RS-485 或其他总线，必须依硬件证据和逐步协议分析确认；目标功能先行，协议私有不改变路线。当前仿真仅有原厂 Linux/Qt 的部分启动与画面路径，蓝牙/Wi-Fi/目标外设协议和 OTA 刷写闭环仍未完成。分阶段工作与验收条件见 §37。

> ## ⚠️ 硬约束（2026-10-30 用户明确）
> **只允许用原装系统的 Linux 内核启动，禁止用 Debian/其它内核替代。**
> 理由：换内核会导致仿真不完整，影响后续工作结论。
> ⇒ 下文 §1「换 Debian 内核」的方案**仅作历史记录，不再作为交付路径**。
>
> ### 原装内核实证（`春风150aura ... .BIN`，偏移 0x880000）
> | 项 | 实测 |
> |---|---|
> | uImage | `Linux-4.9.217`，size=4,382,720，**load=ep=0x408000**，arch=ARM，comp=0 |
> | 载荷 | zImage（自解压；入口 `add r9,pc,#1; bx r9`），可重定位 |
> | 设备树 | **整个 512MB dump 无 `d00dfeed`** ⇒ 无 DT，硬编码板级初始化（2017 BSP） |
> | 控制台 | 仅 Sunplus **`3K_TTYS`**（无 8250/pl011/earlycon） |
> | 存储 | Sunplus **`blockrom`**（无 virtio-blk） |
> | 平台串 | `3K_SPPSU`、`gemini`、`spsdk` ⇒ **Sunplus SP8368/GEMINI BSP**，非 sunxi |
> ⇒ **任何现成 QEMU 机器都无法启动它**：virt 的 RAM 在 0x40000000（内核链接 0x408000）、无 Sunplus UART、无 blockrom。
>
> **原装内核内存映射（已反解）→ 见 [`SUNPLUS-MEMMAP.md`](./SUNPLUS-MEMMAP.md)**：RAM@0x0、GIC@0x9F101000、UART@0x9C102080/2100/4080/4100、timer 27MHz、PSU@0x9C000000。这是自建 QEMU 机器模型的规格书。

> ### 仿真基线（2026-11-03，owner 定义）
> 按文首最终目标推进。当前主线以 `firmware/nand-backup/AE5.BIN` 的原装 AE5I Linux-4.9.217、Qt 用户空间和 SPVD 为基准；保留启动链/内核，逐步补齐画面渲染、eCos/GD32、车辆数据、按键、电源、蓝牙、Wi-Fi、RS-485 与 OTA Update。CF150Aura（8AJ1）界面移植是历史研究，不再是当前固件目标。
>
> 当前顺序见 §37：闭合仪表运行时与车辆接口；在 QEMU 中执行 AE5I 原厂引导阶段和 OTA Update 路径，逐分区写入隔离的可持久 NAND 副本并重启验收；随后才以同一仿真环境开发和验证自制 Qt 用户态固件。
>
> Debian/virtio、150Aura 专用 IPC 回复和 150Aura 地址分析均保留作历史记录或对照，不作为 AE5I 当前基线。`guest_shell.py` 默认使用 `SP_COMPLETE_BOOT=1`，启用当前 mailbox peer 以完成原厂 init/Launcher 启动；设置 `SP_COMPLETE_BOOT=0` 可复现无协处理器的严格基线。该 peer 仍是仿真模型，不等于真实 eCos/GD32 固件。



> 把 ZEEHO AE5i 仪表（Sunplus SP8368-U / GEMINI + GD32 MCU）在 QEMU 里跑起来。
> 原厂内核/固件无法直接仿真 ⇒ 早期走过「Debian 主线内核 + 原厂 squashfs」混合方案（详见 §1，**仅作历史记录，不再作为交付路径**）；
> **当前主路径（2026-10-30 用户硬约束：必须用原装 Linux-4.9.217 内核启动）**：自建 `-M sunplus-sp8368` 机器直接带原厂内核（见 §0.1）。
> 本文档汇总已完成的验证、当前状态、已知硬边界与复现命令。

---

## 0. 一句话现状

**当前仅推进路线 B；路线 A 保留为历史记录**（硬约束见顶部 blockquote）：

- **路线 A · Debian 混合方案（历史记录，2026-10-30 起不再作为交付路径）**
  - ✅ 内核 + initrd + 原厂 squashfs 三层已能启动；仪表 Android init 接管，servicemanager / pfc_server / Launcher 依次拉起。
  - ✅ 显示管线打通：`-M virt,highmem=off` + `virtio-gpu-pci` → `/dev/fb0`（`virtio_gpudrmfb`）。
  - ✅ Full NAND dump 导入「提取」已验证（几何识别 + 坏块跳过 + 3 分区 squashfs 导出并成功启动）。
  - ⚠️ GUI 仍不亮（黑屏）：Launcher `QT_NO_REGULAREXPRESSION` 解析崩溃；binder 缺失 `IPC_FunctionCall error ret=-2`。
  - ⚠️ dump 导入未接入 Flutter 前端（`dump_image.dart` 待重建）。

- **路线 B · 原装内核 Bring-up（当前主路径，`-M sunplus-sp8368`）**
  - ✅ **M1 完成**：RAM/ATAGS(machine id `0x0F34`) → GIC-400 → arch timer 27MHz → 5 路 K_TTYS UART(console ttyS0@921600) → PSU 桩 → EIPC 握手 → GPU 寄存器桩。
  - ✅ **「主线程不动」已结题**：真因是 generic timer 的 **QEMUTimer scale 冻结**（`gt_cntfrq_hz` 在 `cpu_create()` 之后赋值）。修后 tick 正常、宿主 CPU 回到 0.26 s。详见 §0.1 根因 #5。
  - ✅ **M2 打通（2026-10-30）**：`sp_bch`/galcore 复位/SPI-NAND 识别/DMA 页读写+擦除/BBT/25 个 MTD 分区/squashfs 根挂载/`/init` 跑起来（zram、cfcp/imgdec、binder、`pfc_server`/`as_server` 全拉起）。
  - ✅ **M3 `spsdc` 外部中止（已修，§10.1）**、**M4 第一道闸门 `res_fb0` 缺参（已修，§10.2）**、**Galcore GPU 虚拟化（已修，§11）**、`SP_FB_DUMP` 验收指标打通（§10.3）。
  - ✅ **UART RX/TX 全打通（§13）**：双向交互 shell 可用（`tools/guest_shell.py`），CFCP(ttyS1) 与一切用户态调试前提具备。
  - ✅ **fb 注册链彻底打通（§14）**：`fbdss_init → _Get_UI_Res → IPC cmd3（UI 分辨率向 GD32 MCU 问）→ register_framebuffer → registered_fb[0]=cb54c400`；`/proc/fb`=`FB-O0-800x480`、stride=3200、bpp=32。
  - 🟡 **AE5I 原厂 Qt/GAL 已有实验性 2D 绘制**（§18）：Launcher 局部页面可见、GAL IRQ 增长；GPU 命令目前由 QEMU 宿主 CPU 仿真，宿主 GPU 加速暂挂。完整 PFC 合成与 P/READY 主表盘仍未闭环；原厂 logo 动画帧重放已接入。
  - ⚠️ **150Aura M4 结论不得外推到 AE5I**：此前 `res_fb0` IPC 应答、fb 表地址、DirectFB 诊断均按 150Aura 内核分析；在 AE5I 原版镜像上的新基线见 §16。
  - ✅ **AE5I 原版完整启动（§16）**：`firmware/nand-backup/AE5.BIN` → `images/ae5i.spvd` + `images/kernel-ae5i.bin`；完整 profile 可启动原装内核、25 分区、基础服务、framebuffer 注册和 Launcher。严格无 peer 基线仍保留用于协议验证。
  - 🟡 **MCU/CFCP 状态镜像已可观测（§29、§36）**：基线属性维持 guest 广播，客户端可显示仪表回传状态；属性下发经 55 组实验确认不驱动渲染。面板导航键能改变 guest 状态，车身 MCU 键需经上行车辆信号路径建模。
  - 🔎 **P/READY 主表盘上行未闭环（§36、§38）**：vhal 元素格式与 App 收帧已验证；§38 记录 ride-info 探针只到缓存层，当前研究转向 `vehicle_info1/2/3` 的 bytes 属性分发及字段映射，不能把 ACK 当作 handler 已消费。
  - ❌ **OTA Update 全流程尚未仿真**：当前 QEMU 直接加载 Linux 内核，未执行原厂 xboot/U-Boot；Flutter 没有 OTA 模式状态机、虚拟 P2P 传输或 NAND 分区写入路径。该项是核心缺口，详见 §37。


---

## 0.1 原装内核 Bring-up（`-M sunplus-sp8368`）

自建机器 `qemu-src/hw/arm/sunplus-sp8368.c` 直接启动原厂 `Linux-4.9.217` Image（无 DT、无 8250、无 virtio）。

```bash
cd Gemini-Dummy
SP_VDISK=images/150aura.spvd ./qemu-src/build/qemu-system-arm \
  -M sunplus-sp8368 -m 256 -kernel images/kernel-150aura.bin \
  -append "console=ttyS0,921600 loglevel=7 panic=1" \
  -serial file:/tmp/boot.log -display none -no-reboot -monitor none
```

**已通**：RAM/ATAGS（machine id `0x0F34`）→ GIC-400 → arch timer 27MHz → 5 路 K_TTYS UART（console ttyS0 921600）→ PSU 寄存器桩 → EIPC 握手 → GPU 寄存器桩 → galcore 复位 → `sp_bch` → SPI-NAND 识别 → **25 个 MTD 分区 → BBT → squashfs 根 → `/init` → 用户态服务**。整条 `do_initcall` 链 + 用户态启动共约 60 s（其中 ~50 s 仍是 als308 的 5×10 s I2C 等待），之后停在 IPC 超时导致的服务重启。

**八个已定位的根因**（都曾在不同阶段伪装成「莫名卡死」）：

| # | 症状 | 根因 | 修法 |
|---|---|---|---|
| 1 | PC 停在 `cpu_ca15_do_idle`，`ipc:1.6` 后全静 | `sp_ipc_init` 轮询 `0x9C0081DC != 0x5A5AA5A5` ×3001 次后拆驱动 | PSU `0x081DC` 读回魔数（eCos 视为已就绪） |
| 2 | `Kernel command line` 只有 `root=`，无 `console=`；UART 0 字节 | `struct arm_boot_info` 曾是 `sp8368_init()` 的**栈变量**，`arm_load_kernel()` 只存指针，`do_cpu_reset()` 复位时读到野值 ⇒ `have_dtb()` 为真、`set_kernel_args()` 根本不跑 | 结构体搬进 `SP8368State` |
| 3 | `Unhandled fault ... at 0xd080d000` → panic | GPU `0x9C110000` 无设备 | 加 GPU 寄存器文件 |
| 4 | 接上 GIC→CPU IRQ 后「停死、console 0 字节」 | **误判**。它没停，是慢了 ~50×；真因见 #5 | 连同 #5 一起消失；IRQ 线现已**常开** |
| **5** | **★ M2「主线程不动」的真因**：guest tick 看着正常 ~100 Hz，但宿主 CPU 100%、启动慢 ~50×，看起来像死在第一次 `local_irq_enable()` | `arm_cpu_realizefn()` 用 `scale = gt_cntfrq_period_ns()` 建 5 个 `QEMUTimer`，而 **QEMUTimer 的 scale 创建后冻结**。原代码在 `cpu_create()` **之后**才写 `gt_cntfrq_hz = 27 MHz`，于是 timer 停在默认 62.5 MHz / `GTIMER_SCALE=16`，而 `gt_cntfrq_period_ns()` 已报 37 ns ⇒ 每次 `timer_mod()` 算出 16/37 个「当下之前」的到期点 ⇒ `arm_gt_ptimer_cb` 立刻重排 ⇒ **arm/expire 自激风暴** | 拆开 `cpu_create()`：`object_new` + `qdev_prop_set_uint64(dev,"cntfrq",27e6)` + `qdev_realize`。**CNTFRQ 必须在 realize 之前设** |
| 6 | galcore 永不返回，`_ResetGPU` 空转 | 复位循环尾部判两个 idle 位：读 `0x004` **bit0**（`bpl` 重试）、读 `0x000` 的 `(v&0x30000)==0x30000`（否则重试）。纯寄存器文件读回 `0x900` ⇒ `&0x30000 = 0` ⇒ 永远重试 | GPU 读：`0x004` 恒或 bit0、`0x000` 恒或 `0x30000`。修后 **`GPU reset round 1`**（一轮即成） |
| 7 | `Unhandled fault ... at 0xd0c2a010` → panel panic | `sp_bch_probe` 的 MEM 资源在 **`0x9C101000`**（pte `9c101653` 反推），无设备 | 加 IP 窗口 `0x9C100000..0x9C10A000`；`BCH+0x10`（reset status）**bit0 永不自锁** |
| 8 | `nand: No NAND device found` / `Unsupport device(id=0x00000000)` | SPI-NAND 控制器 `0x9C002B80` 全 0；`chip->cmd_ctrl` 是空桩、`dev_ready` 恒 1，识别只走 `spi_nand_readid`：写 `0x00=0x01009FB1`(SPI op **0x9F**)、`0x08=addr`、`0x14=0x200000` 启动 → 轮询 `0x00` bit31 → **从 `0x0C` 取 4 字节 ID** | 加 SPI-NAND 子区域（PSU 子区域，offset `0x2B80`）：`0x00` 掩掉 bit31，`0x14` 带 bit21 且 opcode==0x9F 时把 `0x0000130B` 放进 `0x0C` |

### 关键证据链（根因 #5）

| 指标 | 修复前 | 修复后 |
|---|---|---|
| `-trace enable=arm_gt_recalc` 3 s 内次数 | 628,608 | **8,385** |
| 到 `Galcore version` 的墙钟 | 23.2 s | **0.83 s** |
| 宿主 CPU（`getrusage`） | 23.3 s | **0.26 s** |

> 教训：**tick 速率正常 ≠ 没有 timer 问题**。`arm_gt_recalc` 的计数才是判据；墙钟与宿主 CPU 必须一起量（`ps` 在本机沙箱被禁，用 `resource.getrusage(RUSAGE_CHILDREN)`）。

### M2 完成记录：SPI-NAND 数据通路（2026-10-30 结题）

识别通了之后，把「读/写/擦除」全部打通，四个独立坑：

| # | 症状 | 根因 | 修法 |
|---|---|---|---|
| 9 | 页读发了 DMA 也不走，`read_page` 尾部的 `bmi` 死循环（一次启动打印 **1,178 万行** `rd 014 -> 6b120000`） | 忙等 `0xC05B4066` 判的是 `0x14` 的 **bit17（dma in flight）清零**；模型把 `0x14` 当普通寄存器存着 `0x6B120000`，bit17 永为 1 | 传输**同步完成**后立刻清 `0x14` 的 bit17/bit21，读侧再兜一层掩码 |
| 10 | **所有 2048 块都判坏**（`Bad eraseblock 0..2047`），BBT 找不到 | DMA 目标我读成了 **`0x38`**；真正的目标是 **`0x34`**。`0x38` 只被整页读写过一次（像 bounce buffer），`0x34` 才是调用方缓冲区 —— 用 0x38 导致数据全落 bounce buffer，yaffs 挂上了但 `/init` 不见、spare 区也永远到不了坏块判定 | `dst = reg[0x34]`，`0x38` 仅作 `aux` 记录 |
| 11 | 写/擦除"成功"但内容不变，`Wait dma done timeout!` | **opcode `0x00` 是双向的**：方向在 cmd 的**第 2 字节**（`0x0101_0082` 读 / `0x0102_0082` 写）。只按第 1 字节取 op 时两者都当读 | `SPN_SUBOP(cmd)`；sub==2 走 DRAM→cache |
| 12 | 擦除后 `Wait pio done timeout!` 每 150 ms 刷一次、`erase` 永不完成 | 擦除用第三种启动约定：先写 **bit18**(`0x00040000`)、再 OR **bit21**(`0x00240000`)，然后**只等 `info->5a4`、一个寄存器都不读** ⇒ 不产生 IRQ 就永远等 | 只要启动字带 bit17 **或 bit18** 就抬 IRQ 55 |

补充：`nand_bbt` 写 BBT 用的是 op **`0x10`**（program execute），擦除是 op **`0xD8`**，批量读 cache 与"整页 program load"同 op 不同 sub。模型把 `.spvd` 以 **`MAP_PRIVATE | PROT_WRITE`** 映射 ⇒ 客户机可擦写、**磁盘上的原厂 dump 永远不被改**。

结果（`sn15`，100 s）：`Bad block table found at page 131008, version 0x01` → `VFS: Mounted root (squashfs filesystem)` → `devtmpfs: mounted` → `init: do_exec start` → zram/cfcp/imgdec/binder/`pfc_server`。

### M2 之后：IPC 邮箱（下一块，已实测到寄存器级）

`fbdss_init` 调 `IPC_FunctionCall(IPC_CMD_DISP_GET_FB_mod_info=3)`，等 7 s 超时 `err:-8`；用户态 `pfc_server` / `as_server` 读 IPC 设备返回 `-1`，约 1 s 后 init 重启系统。IPC 是 A7 Linux ↔ **eCos 协核**的共享内存邮箱 + 中断。

**邮箱寄存器（全部落在 PSU 窗口 `0x9C000000` 内，实测确认）**：

| 偏移 | 用途 | 协议 |
|---|---|---|
| `0x08100` | **门铃** | `rpc_write_hw()` 写 `1` 通知对端（**注意：不是 0x01000**） |
| `0x08104` | 对端状态 | 轮询到 `(v & 0xFFFF0000) == 0` 才可发；501 次 × 1 ms |
| `0x08110` | 请求块 | `rpc_copy(0xF0808110, msg)`：`0x14` B 头 + 外部 payload |
| `0x08190` | 应答块 | `rpc_isr()` 从这里 `rpc_copy` 出 `0x50` B，再唤醒等待者 |
| `0x081DC` | EIPC 就绪魔数 | `0x5A5AA5A5`（已伪造，让内核走 ready 分支） |

**请求头（实测抓包，cmd 3 / len 372）**：

```
0x8110: cf4c5700  00000000  00030174  0f526574  00000001  00000000  0f526400
        owner     zero      id<<16|len seq?     wait=1    zero      payload phys
        ↑ dword0  ↑ dword1  ↑ dword2  ↑ dword3  ↑ dword4  ↑ dword5  ↑ dword6
0x81dc: 5a5aa5a5   ← EIPC 魔数正好落在应答块之后
```

- `dword2 = (id << 16) | len`：`id=3`、`len=0x174=372`。
- `len > 0x3c` ⇒ payload 走外部缓冲区，`dword6` 是它的**物理地址**（本例 `0x0F526400`，在 DRAM 内可直接读）；`len <= 0x3c` 时 payload 内联在 `0x8114` 之后。
- cmd 3 的 payload 全 0：主核只发**空结构**，等对端填。

**应答侧路由（`rpc_isr` 0xC04189F0）**：`u16@+0xa`（即 dword2 高半 = `id`）的第 7 位=1 表示"对端发起的新请求"，=0 表示应答；第 5 位选唤醒队列（`+0x5ac` / `+0x55c`）；`(id >> 9) & 7` 是**通道号**。⇒ 只要把请求头原样回显到 `0x8190`（id<0x8000 自动满足"应答"特征），再抬 IPC 中断，`IPC_FunctionCall` 的 `wait_event` 就会被唤醒。

**cmd 3 应答结构（从 `fbdss_init` 0xC07EB150 反推）**：`0x174` = **3 条 `0x7c` 记录**：

| 偏移 | 含义（推断） |
|---|---|
| `+0x00` | 记录选择子，必须 `<= 2`（`cmp #2; bls`） |
| `+0x04` / `+0x08` | **宽 / 高**，两者必须非 0，后面相乘算 stride |
| `+0x0c` | stride |
| `+0x10` | 格式，低 12 位（`ubfx #0,#0xc`）必须为 0 |
| `+0x18`、`+0x1c`(0x17 B) | 名字/描述串 |
| `+0x34` | BPP（`>>3` 得每像素字节数） |

**还缺两块**：① IPC 中断号（`rpc_isr` 未在字面量池里出现，需从 GICD 使能位或暴力试探确认）；② 应答记录里的真实数值（面板 5 寸，需与真机 `dmesg` 或 PFC 寄存器对齐）。模型侧已加 `SP_IPC_TRACE=1`：门铃一响就 dump 请求块 + payload 前 64 B。



### 附：两个可直接用的命令行参数（`__setup`，非改内核）

`parse_res_rtcfg` / `parse_res_iop` 是 `__setup` 项，格式 **`<addr>@<size>`**（`parse_both`：`memparse` 取 addr，遇 `@` 再取 size）：

| 参数 | 落点 | 含义 |
|---|---|---|
| `res_rtcfg=0x07000000@0x98B` | `0xC08056C0/4` | runtime_cfg blob 的 DRAM 地址/长度（与 `SP_FW_FILE` 注入配套） |
| `res_iop=<addr>@<size>` | `0xC08056B8/C` | IOP 共享区 |

默认都是 `0xFFFFFFFF`（启动日志 `reservation parameter : ffffffff, ...` 那行）。

### 已知拖慢项（不影响正确性）

`als308` 光感 5 次 I2C 超时各等 10 s（共 ~50 s）。上游是 `sp_iop_i2c_probe` 失败 `-14`：它从 **`0xF084005C/0x60`** 拼 IOP base（`low + (high<<16)`），两处都读回 0 ⇒ `ioremap(0)` 失败。修好可让每次启动从 ~59 s 降到 ~9 s。


调试开关（全部 env，默认关）：

| 变量 | 作用 |
|---|---|
| `SP_TIMER_TRACE=1` | 每秒一行 `STAT timer_irqs=… cpu_irq_edges=… pc=…`（相邻行相减得**瞬时** tick 率）+ timer IRQ 边沿 |
| `SP_STACK_DUMP=1` | tick 第 400 次时 dump 内核栈（自动 VA→PA） |
| `SP_GPU_TRACE=1` | 打印每次 GPU 寄存器访问 + PC/LR，并在写 `0x000` 时 dump 栈；另打印 `GPU reset round N`（正常应为 1） |
| `SP_IP_TRACE=1` | 打印 IP 窗口访问（含 BCH `+0x10` reset status） |
| `SP_SPINAND_TRACE=1` | 打印 SPI-NAND 寄存器访问 + 传输的 `cmd/op/sub/addr/col/len`（DMA 那次带 `dst`/`aux`/块号） |
| `SP_PSU_TRACE=1` | 打印 PSU 寄存器访问 |
| `SP_IPC_TRACE=1` | 门铃（`0x9C008100`）一响就 dump rpc 请求块 + payload 前 64 B |
| `SP_VDISK=<path>` | 挂 `images/150aura.spvd`（512 MiB NAND 原始内容，page 4096 / OOB 256 in-image） |

> `SP_GIC_IRQ` **已删除**：IRQ 线现在是常开的（见根因 #4/#5）。

---

## 1. 硬件事实（已与静态证据互证）

| 项 | 事实 |
|---|---|
| SoC | **Sunplus（凌阳）SP8368-U，平台代号 GEMINI**；U-Boot 2014.04（`uboot_gemini_evb`）；Linux **4.9.217**；Qt **5.3.2** UI |
| CPU | **ARM Cortex-A7 / ARMv7-A / Thumb2 / armhf(EABI5)**，glibc 2.30 |
| GPU | Vivante **galcore**；显示 **LVDS/MIPI-DSI 5 寸** |
| 存储 | **SPI NAND XT26G04C 4Gb(512MB)**；rootfs 走 Sunplus 专有 `blockrom` MTD 分区块设备 |
| MCU | **GD32（Cortex-M）**：通电即起，负责行车、按键采集、提示音、刷卡/蓝牙解锁判定；**SoC 卡也能骑行** → MCU 完全独立 |
| 协核 | eCos（`sunplus/gemini_disc`，约 2.88MB）随 SoC |
| 调试口 | **ttyS0@921600**（UART4=debug）；**CFCP 走 /dev/ttyS1** |
| 版本锚点 | `spsdk-root/sdkinfo.rc`(GEMINI/AE5I/SW.1.01.15)、`spapp-root/appinfo.rc`(`cfmoto_8368_U_5_inch_eabihf_defconfig`)、`dist/rescue/manifest.json` |

**双芯片要点**：实车「把手开关 → GD32 MCU → CFCP KeyID 帧(/dev/ttyS1) → cfcp-keypad → Linux input」是按键与车辆数据唯一入口，**不经 SoC GPIO**。仿真里目前用 QEMU `sendkey` 占位，待 MCU/CFCP 模拟器补上。

### 历史记录：为什么早期认为原厂内核跑不起来

逐条实测阻塞：内核**无 pl011/8250/ns16550**（只有 Sunplus `K_TTYS`）→ virt 无 console；**无 virtio\*** → 无块/网；无 PSCI；rootfs 依赖专有 `blockrom`；内核加载地址 `0x408000` vs QEMU virt RAM base `0x40000000` → 地址空间不兼容；QEMU 11.x 无 SP8368/GEMINI 机器。

当时的临时对策是 Debian netboot 内核 `vmlinuz-armhf`（6.12.107+deb13-armmp）及 virtio 设备；该方案只用于早期服务链和 GUI 假设验证，已被自建 SP8368 机器模型取代，禁止作为当前仿真基线。

---

## 2. 仿真架构

本节中的 Flutter/virtio 三层架构是早期 Debian 混合路线的保留记录。当前运行时架构以 §0.1 的 `-M sunplus-sp8368`、原装内核、原厂 `.spvd` 和 QEMU 机器模型为准；Flutter 只负责宿主控制和取证，不参与 guest 的显示实现。

```
┌─────────────────────────────────────────────────────────────┐
│  macOS 宿主                                                  │
│  ┌──────────────────────┐      ┌──────────────────────────┐  │
│  │ Flutter macOS App    │      │ Python emu.py (HTTP :8800)│  │  (旧前端，保留)
│  │ (主前端, 不用 HTTP)   │      │   monitor telnet :4445   │  │
│  │  - Process.start QEMU│      │   VNC :5901              │  │
│  │  - monitor unix sock │      └──────────────────────────┘  │
│  │  - 串口桥 TCP :9001  │                                     │
│  │  - screendump→PPM→   │                                     │
│  │    RGBA→RawImage     │                                     │
│  └──────────┬───────────┘                                     │
└─────────────┼───────────────────────────────────────────────┘
              │ 子进程
┌─────────────▼───────────────────────────────────────────────┐
│  QEMU  qemu-system-arm -M virt,highmem=off -cpu cortex-a7     │
│   -kernel vmlinuz-armhf                                      │
│   -initrd initrd-final.cpio.gz   (Debian rootfs + qpreinit)   │
│   -device virtio-gpu-pci,xres=1024,yres=600  → /dev/fb0       │
│   -drive spsdk.squashfs  → 挂载 /usr/local                   │
│   -drive spapp.squashfs  → 挂载 /application                 │
│   -display none  (画面走 monitor screendump)                  │
└──────────────────────────────────────────────────────────────┘
```

- **三层数据**：① 内核（Debian 主线）；② initrd（`initrd-final.cpio.gz`：Debian 用户态 + `qpreinit.sh` + 仪表 Android init + `*.rc`）；③ 原厂 squashfs（`spsdk→/usr/local`、`spapp→/application`，含真实二进制/库/Qt 插件/Launcher）。
- **两前端**：
  1. `emu.py`（旧，HTTP API :8800 + VNC + monitor telnet :4445，纯标准库）—— 保留备用。
  2. **Flutter macOS App（当前主前端）**：完全不用 HTTP，`Process.start` 直管 QEMU 子进程；monitor 走 **unix socket** 发 `screendump`/`sendkey`；串口用 `-serial stdio` 读 stdout；画面 `PPM→RGBA→ui.decodeImageFromPixels→RawImage`；日志区用 QEMU/SER/MON/APP 四色区分并合并重复行。

---

## 3. 历史记录：Debian initramfs 启动链

```
内核 → rdinit=/sbin/qpreinit.sh
  qpreinit.sh:
    mount proc/sysfs/devtmpfs
    insmod DRM+virtio 模块（顺序敏感，见 §6）
    rm -f /usr/local /application        # 它们是 /tmp/sp/* 的符号链接
    mkdir -p /usr/local /application ...
    mount -t squashfs /dev/vdb /usr/local   # spsdk
    mount -t squashfs /dev/vda /application  # spapp
    [ -s /etc/machine-id ] || 生成
    rm -f /dev/mem /dev/kmem
    mknod /dev/chunkmem c 1 5 等   # 把 Sunplus 专有设备桩成 /dev/zero
    exec /init
  → 仪表 Android init 读 init.rc / init.gui.rc / init.environ.rc
    sys_setup.sh → 起 servicemanager/resourcemanager/pfc_server/gocsdk/vsserver/asserver/readbtchip
    setprop ro.start.Launcher 1 → Launcher 被 init 启动
```

- `init.gui.rc`：原厂 `QT_QPA_PLATFORM=directfb`；仿真变体 `patches/init.gui.qemu.rc` 改为 **`linuxfb`**（走 `/dev/fb0`）。
- Qt 平台插件只含 `libqdirectfb / libqlinuxfb / libqminimal / libqoffscreen`（**无 vnc / 无 eglfs**）；输入插件 `libqevdevkeyboardplugin.so` → 按键注入落 evdev event0 即可，不必重实现 CFCP。
- `default.prop`: `ro.platform.name=gemini_disc`。

---

## 4. 历史记录：Debian 混合路线的已完成工作

以下阶段记录的是旧的 `virt` + Debian 内核实验，不能代表当前 M4 基线。当前完成项以 §0、§10–§14 和文末基线为准。

| 阶段 | 内容 | 状态 |
|---|---|---|
| 1. 内核选型 | 原厂内核不可行 → 改用 Debian `vmlinuz-armhf`(6.12.107+deb13-armmp) | ✅ |
| 1. 起 shell | `-M virt -cpu cortex-a7 -m 512 -initrd initrd-ae5i.cpio.gz -append "rdinit=/sbin/qdiag.sh"` → 拿到 `root@AE5I:/#`，仪表 ARM 二进制可执行 | ✅ |
| 2. 显示 | `-M virt,highmem=off` + `virtio-gpu-pci` → `[drm] fb0: virtio_gpudrmfb` | ✅ |
| 2. 分区挂载 | spsdk/spapp squashfs 挂载成功；补内核模块（drm→…→virtio-gpu→virtio_blk→squashfs） | ✅ |
| 3. 服务链 | 让仪表自带 Android init 接管（property 系统 + `init.svc.*` 依赖），Launcher 被拉起 | ✅ |
| 3. 前端 | Flutter macOS app 跑通：PID/monitor/fps/串口实时；`ae5i_emu.app` + `qemu-system-arm` 并存 | ✅ |
| 3. 串口桥 | TCP :9001 外部终端直连 guest ttyAMA0，可执行命令 | ✅ |
| 当前 | **Full dump 导入·提取**：几何识别 + 坏块跳过 + 3 分区导出 | ✅(Python) ⚠️(未接 Flutter) |
| 当前（历史路线） | **GUI 点亮**：Launcher segv / binder 缺失 | ❌，路线已退役 |

---

## 5. Full NAND dump 导入（提取已验证）

> **2026-11-01 更新**：`rawimage/ref_ae5i_old_full.BIN` 已不存在。当前验证镜像 = **`firmware/nand-backup/AE5.BIN`**（AE5I，烧录器 dump，570,425,344 B），已转为 `images/ae5i.spvd` + `images/kernel-ae5i.bin`。四份 dump 的鉴定见 **§15**。

### 5.1 几何与坏块（实测）

- **几何 = 4096+256 = 4352 B/帧，64 页/块，2048 块**（本项目 NAND dump 统一按此已验证几何处理；不得沿用早期 `2048+128` 的错误判断）。
- 坏块（扫 OOB 字节）：**`[383, 716, 1049, 1382, 1715]`**，均不在 uboot/kernel 区；**坏块 383 落在 spapp 区间内**（该块数据被清零）。
- 3 个 squashfs 超块位于文件偏移 `0xd48000 / 0x1298000 / 0x4598000`（页对齐），逻辑偏移 `0xc80000 / 0x1180000 / 0x4180000`，大小 **4.0 / 43.6 / 52.1 MiB**（按大小对应 rootfs / spsdk / spapp）。

### 5.2 提取算法（要点）

1. 按候选几何（4352 / 2176）扫描**页对齐**（`fileoff % frame == 0`）的 `hsqs` 魔数；取命中最合理（≥2 个、bytes_used 合理）的几何。
2. 文件偏移 → 逻辑偏移：物理页 `p=foff/frame`，物理块 `b=p/ppb`，`bad_before = bad<b 的个数`，`logical = (b-bad_before)*ppb*data + (p%ppb)*data`。
3. `read_skip_bad`：按逻辑偏移顺序读数据页，遇到坏块整块跳过（坏块对逻辑内容无贡献，FTL 已重映射），拼出连续逻辑数据 = 合法 squashfs。
4. 按大小命名：最小=rootfs、中=spsdk、大=spapp。

### 5.3 验证结果

- Python 参考实现 `/tmp/extract_dump.py` 导出 3 个有效 squashfs（`file` 识别为 Squashfs，魔数 `hsqs`）。
- 用导出镜像启动 QEMU：**init 正常、Launcher 被拉起**（证明提取正确可用）；坏块 383 跳过逻辑生效（spapp 不再 `[FAIL]`）。
- ⚠️ **尚未接入 Flutter**：`lib/dump_image.dart`（几何探测 + 坏块跳过 + `useDump()` 镜像源切换 + UI 选择器）在会话重置中被回滚，需重建；`main.dart` 当前仍是「写死 `virtual/`」版本。

---

## 6. 历史记录：Debian 路线的 GUI 硬边界

本节描述的是旧路线的 Launcher 崩溃和 binder 缺失。它们不再是当前原装内核路线的首要问题；当前 GUI 阻塞点见 §14.5、§14.8 和 §14.11。

### 6.1 Launcher 不亮（黑屏）— 根因
实测日志：
```
Unable to parsing linuxfb param because of defining QT_NO_REGULAREXPRESSION
[Launcher]: enter signal_segv
[Launcher]: enter signal_segv
...
binder: cannot open device (No such file or directory)
IPC_FunctionCall error cmd=5 len=36 ret=-2
open /dev/chunkmem success
```
- **段错误真因**：Launcher 编译时定义了 `QT_NO_REGULAREXPRESSION`（禁用 QRegExp），但其启动代码仍用 QRegExp 解析 linuxfb 平台参数 → 空指针/UB → SIGSEGV。无论走 directfb（失败回退）还是 linuxfb，都会在解析处崩。
- `/dev/chunkmem` 桩已生效（`mknod c 1 5` = /dev/zero，open 成功），但 ioctl/mmap 语义不匹配 → 底层报 `hw memory device open fail` / `EIPC_Init failed`（与 eCos 协核 IPC）。
- `/dev/fb0` **确实存在**（virtio_gpudrmfb），所以 linuxfb 渲染链路技术上可行——只要 Launcher 不崩。
- binder 设备缺失 → `IPC_FunctionCall error ret=-2 (ENOENT)`：需 `binder_linux.ko`（已从 deb 抽出）+ 建 `/dev/binder` 节点（注意驱动 v8 / 用户态 v7 协议版本差异）。

### 6.2 结论
GUI 量产级点亮需要解决 Launcher 的 `QT_NO_REGULAREXPRESSION` 解析崩溃（最可能是 **LD_PRELOAD 拦截该解析路径**，或让 directfb/linuxfb 路径不触发该分支）；以及补齐 binder。两者都属二进制级改造，无源码时工作量大、风险高。当前 emulator 已能完整跑通「内核→init→服务链→Launcher 进程启动」，**仅 GUI 表面未渲染**。

---

## 7. 历史记录：Debian / Flutter 踩坑清单

- **`-M virt,highmem=off` 必须加**：否则 ARM32 上 PCIe MMIO 窗口落 0x8000000000 超 32 位 → `pci-host-generic: missing "reg"` probe err -75 → 所有 PCI 设备（含 virtio-gpu）失效。
- **用 `rdinit=` 不用 `init=`**：initramfs 含 `/init` 时 Linux 优先 `ramdisk_execute_command`。
- **向 cpio(newc) 注入设备节点**（macOS 不能 mknod）：在 `TRAILER!!!` 前插入 `dev/console 5:1`、`dev/ttyAMA0 204:64`、`dev/null 1:3`。
- **Debian netboot 内核无 squashfs/virtio_blk/loop** → 须注入配对模块（版本须与 `vmlinuz` 一致：6.12.107+deb13-armmp）。
- **Android init mmap `/dev/mem` → external abort → panic**：pre-init 里 `rm -f /dev/mem` 走容错分支。
- **`/usr/local`、`/application` 是 `/tmp/sp/*` 的符号链接**，而 `fstab` 有 `tmpfs /tmp` → init 重挂 /tmp 会冲掉挂在那的 squashfs；须 `rm -f` 后建真实目录再 mount。
- **`/etc/machine-id` 缺失 → D-Bus 崩**：启动时生成。
- **busybox ash 不认 `export VAR value`** → 用 `VAR=v; export VAR`。
- **内核模块 insmod 顺序**：`drm → drm_kms_helper → drm_display_helper → ttm → drm_shmem_helper → drm_ttm_helper → drm_vram_helper → virtio_dma_buf → virtio-gpu → virtio_blk → squashfs`。
- **`tar -xf data.tar.xz` 路径不能带 `./` 前缀**，否则提取为空。
- **盘序**：vda=spapp、vdb=spsdk（QEMU 按地址排序，与命令行先后相反）；建议用**按大小判别**（spapp 更大）防错（见 `patches/init.gui.qemu.rc`）。
- **Flutter 前端三必改**：① 关 App Sandbox（删 `com.apple.security.app-sandbox`，否则嵌套沙箱 `EXC_BREAKPOINT/SIGTRAP`）；② squashfs 加 `readonly=on`（防写锁冲突）；③ `flutter test` 须 `export NO_PROXY=127.0.0.1,localhost,::1`（否则 WebSocket upgrade 失败）。
- **screendump 在 `-display none` 下仍可用**（PPM 1024×600×3），UI 全程不弹 QEMU 原生窗口。
- **日志刷屏**：`IPC_FunctionCall error ... ×N` 已做重复行合并；monitor 回显带 ANSI 控制符已清洗。

---

## 8. 历史复现命令（Debian / Flutter）

本节 A–C 均为退役路线。当前原装内核复现优先使用 §14.9 的工具；在 `Gemini-Dummy/` 下执行 `python3 tools/guest_shell.py "cat /proc/fb" "cat /proc/interrupts"`。修改模型后先执行 `python3 tools/build_model.py`。

### A. 最小启动（initramfs 内 shell）
```bash
qemu-system-arm -M virt -cpu cortex-a7 -m 512 \
  -kernel Gemini-Dummy/kernel/vmlinuz-armhf \
  -initrd Gemini-Dummy/initrd-ae5i.cpio.gz \
  -append "console=ttyAMA0 rdinit=/sbin/qdiag.sh" -serial stdio
```

### B. 显示 + 分区挂载 + 服务链（历史主链路）
```bash
qemu-system-arm -M virt,highmem=off -cpu cortex-a7 -m 768 \
  -kernel Gemini-Dummy/kernel/vmlinuz-armhf \
  -initrd Gemini-Dummy/initrd-final.cpio.gz \
  -device virtio-gpu-pci,xres=1024,yres=600 \
  -drive file=virtual/spsdk.squashfs,if=none,format=raw,id=sdk,readonly=on -device virtio-blk-device,drive=sdk \
  -drive file=virtual/spapp.squashfs,if=none,format=raw,id=app,readonly=on -device virtio-blk-device,drive=app \
  -display none -append "console=ttyAMA0 rdinit=/sbin/qpreinit.sh" -serial stdio
```

### C. 从 full dump 启动（Python 提取后）
```bash
python3 /tmp/extract_dump.py rawimage/ref_ae5i_old_full.BIN /tmp/dump_parts
qemu-system-arm -M virt,highmem=off -cpu cortex-a7 -m 768 \
  -kernel Gemini-Dummy/kernel/vmlinuz-armhf -initrd Gemini-Dummy/initrd-final.cpio.gz \
  -device virtio-gpu-pci,xres=1024,yres=600 \
  -drive file=/tmp/dump_parts/spsdk.squashfs,if=none,format=raw,id=sdk,readonly=on -device virtio-blk-device,drive=sdk \
  -drive file=/tmp/dump_parts/spapp.squashfs,if=none,format=raw,id=app,readonly=on -device virtio-blk-device,drive=app \
  -display none -append "console=ttyAMA0 rdinit=/sbin/qpreinit.sh" -serial stdio
```

### D. Flutter 前端
```bash
export PATH="/Users/ryanfish/fvm/versions/custom_zeeho/bin:$PATH"   # SDK 位置见 §26.4
export PUB_HOSTED_URL=https://pub.flutter-io.cn FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn
export NO_PROXY=127.0.0.1,localhost,::1
cd Gemini-Dummy/flutter_app
flutter pub get
flutter run -d macos      # 或 flutter build macos --debug && open build/macos/Build/Products/Debug/ae5i_emu.app
```

---

## 9. 历史开发方向（2026-10-31；由 AE5I §18 更新）

本节记录 150Aura 路线阶段的 M4 待办，不再代表当前 AE5I 工作方向。AE5I 的原厂镜像启动、实验 GAL 2D、CFCP 导航键、多 framebuffer 与未完成项以 §16–§18 为准。

1. **闭合 `libGAL.so` ↔ `/dev/galcore`**：从 `gal_config_init` 的 open/ioctl 入手，补齐能力查询、寄存器/命令缓冲语义和 IRQ 47 完成路径；以 `SP_GPU_TRACE=1`、`/proc/interrupts` 和无 recovery 为证据。
2. **修 DirectFB 自动探测**：确认 `systems/` 后端与 `gfxdrivers/libdirectfb_gal.so` 的加载条件，解决当前卡在 `Fusion Dispatch` 后的问题；不要添加无效的 `gfx=gal` 参数。
3. **完成 IPC 用户态投递（#21）**：根据 §12 的 FIFO/通道表，把对端请求投递到已注册的用户态通道，消除 `as_server`/`pfc_server` 的 `ipc cmd:-1|0xffffffff`；保留内核应答路径的回归检查。
4. **更新 rootfs 启动配置（#22）**：探测所需环境先做临时实验；前述链路稳定后再固化到 `init.gui.lite.rc`，确保 gal 驱动目录和运行时环境可被自动探测；重打包前记录 squashfs 校验和及 spvd 偏移 `0xc81000`。
5. **点亮验收**：重复启动并抓取 `SP_FB_DUMP`，`painted` 从 `0.0000` 变为非零；同时确认无 galcore recovery、无服务重启。
6. **后续扩展**：点亮后再做 MCU/CFCP 行为模拟、输入注入和 Flutter 前端增强。它们服务于回归和交互验证，不得提前改变显示基线。

### 9.1 仿真阶段边界与验收（历史快照）

本小节记录当时的阶段边界。验证镜像为 `firmware/nand-backup/AE5.BIN` 转出的 AE5I 镜像；更近的启动、显示和按键证据见 §16–§18。启动到 root shell 和运行 Qt Launcher 不等于显示或整车功能已仿真完成。

| 阶段 | 下一步产物 | 验收证据 |
|---|---|---|
| M4：原厂 UI 点亮（进行中） | AE5I eCos/GD32 IPC、DirectFB/galcore 初始化、像素写入 | `painted != 0` 只是首个门槛；还须确认抓帧是 AE5I UI 且连续更新，并记录经证据确认的物理地址和 stride |
| M5：车辆交互闭环（待 M4） | ttyS1 CFCP 对端、按键及车辆状态输入 | 原厂服务收到协议帧、产生原生动作，画面随速度/状态改变；不能只以 QEMU `sendkey` 代替整条协议验收 |
| 后续：功能回归 | AE5I 原厂服务、Qt 页面和数据通路 | 分别验证显示、按键、车辆数据和服务稳定性；与 150Aura 实验记录分开 |
| 后续：宿主集成与可复现交付 | Flutter 接入当前机器、持久化运行脚本和证据清单 | 从受版本管理的工具复现上述结果，核心流程不依赖 `/tmp/*.py`；导入工具沿用 4352 B NAND framing |

**GPU 能力边界**：§11 已验证复位、命令缓冲捕获、EVENT 解码和中断，不等于已实现 Vivante 的完整绘制/合成。若 ioctl 与驱动初始化已通而 `painted` 仍为零，应沿真实命令流查目标 surface、显存地址及实际绘制操作；不得通过伪造完成中断或手工写测试像素宣称原厂 UI 点亮。若真实 surface 不在默认 `0x0C000000`，先用映射证据校准 `SP_FB_ADDR`，再判断黑屏。

rootfs 重打包指宿主上的仿真副本，不授权制作 OTA 可刷包，也不修改 `firmware/`。所有阶段保留原装内核约束、`tools/build_model.py` 构建入口和读内存前 VA→PA 校准规则。

---

## 10. 历史基线：150Aura M3/M4 显示管线（2026-10-31）

> 本节的寄存器、IPC 回复、fb 地址和结论来自 `kernel-150aura.bin`；作为共用平台参考保留。AE5I 对照时必须重新验证，不能直接采用这些地址或响应值。

### 10.1 ✅ M3：`spsdc` 外部中止（已修）

`strb.w r3, [r2, #0xec]`（1 字节写）打到 PSU 窗口内的 `0x9C003F6C`，但四个 MMIO `MemoryRegionOps`
都声明了 `.valid.min_access_size = 4` ⇒ QEMU 在**进 handler 之前**回 `MEMTX_DECODE_ERROR`
⇒ `arm_cpu_do_transaction_failed()` 变成**同步外部中止**（FSR `0x808`）⇒ `Kernel panic`。
**修法**：四个 ops 全部 `.valid.min_access_size = 1`（保留 `.impl.min/max = 4`），
由 `access_with_adjusted_size()` 做字节 lane 拆并。

### 10.2 ✅ M4 第一道闸门：`res_fb0` 缺参（已修）

`fbdss_init()` 在 0.19 s 建显示设备，**anchor 直接取自内核命令行 `res_fb0`**
（`parse_res_fb0()` → 全局 `0xC08056D4` = 地址槽 / `0xC08056D0` = 大小槽，`.data` 默认 `0xFFFFFFFF`）。
由 `parse_both()` 反汇编可知格式是 **`res_fbN=<size>@<addr>`**：第一个数写大小槽，`@` 后第二个数写地址槽。

缺参时的连锁反应（这是 56 s 重启的**真正起点**）：

```
[_create_device:1395] Error! ... memory phy anchor(0xffffffff) not page aligned(4096)
[_create_device:1538] Error! win_id:0, Have error        ← 显示设备创建失败
   ↓  ~56 s 时 init 调 reboot(RESTART) → machine_restart → cfmoto_set_mcu_watchdog_status(gpio-8)
[   56.051] reboot: Restarting system
[   57.052] Reboot failed -- System halted                 ← 没有 MCU 替它掉电重启，纯挂死
```

补齐这四个参数后（`tools/mtdparts-150aura.txt` 的分区表 + 下面四行），显示设备**创建成功且无报错**：

```
res_chunkmem=0x04000000@0x0C000000     # 64 MiB chunk pool @ 0x0C000000
res_fb0=0x00800000@0x0C000000
res_fb1=0x00400000@0x0C800000
res_fb2=0x00400000@0x0CC00000
```

```
[    0.118516] chunkmem's cma_area base:0xc000000 size:0x4000000
[    0.118637] [chunkmem.0] pbase=0x0C000000 vbase=0xCC000000 size=0x04000000
[    0.194529] [_create_device:1519] fb0, win_id 0, mem VA 0x0(PA 0xc000000),
             Palette VA 0x0(PA 0x40000000), UI Res 800x480, size 0 + 0
```

`UI Res 800x480` 来自 IPC 回包 ⇒ **IPC 桩对 `IPC_CMD_DISP_GET_FB_mod_info`(id=3) 的应答已生效**。
`registered_fb[0]`（内核 `0xC0849684`）在 RAM 快照里可读到：`fix.smem_start=0x0C000000`、
`fix.line_length=3200`、`smem_len=0x177000`、`bpp=32` —— 几何全对。
**遗留**：`fb_info->screen_base`（+0x230）仍是 0（`ioremap()` 返回 NULL），
`Palette VA` 也是 0，`size 0 + 0`。DirectFB 走 `mmap(/dev/fb0)` 用的是 `fix.smem_start/smem_len`，
理论上不受 `screen_base` 影响，暂未确认它是 M4 的阻塞点。

**没有 `res_fb0` 之后不再重启**，系统能一路跑到用户态并稳定驻留（不再 `System halted`）。

### 10.3 `SP_FB_DUMP` 的两个坑（已修）

1. 原来 `if (!dir || !a_s) return;` —— 没给 `SP_FB_ADDR` 就**静默返回**，一个文件都不写。
   现在默认 `0x0C000000`（= `res_fb0`，因为那是我们告诉内核的唯一地址）。
2. 每次 dump 会往 stderr 打一行**点亮度量**，这是 M4 的验收指标：

```
FBDUMP 001: 0c000000 800x480 painted=0.0000
```

只要 `painted` 一直是 0，就说明**没有任何人往 fb0 写像素**；它跳起来的那一刻就是"点亮"。

### 10.4 真机基准对照（重要）

`logs/vehicle-boot-150aura.log`（真机用户态日志）证明两件事，别再当 bug 追：

| 现象 | 真机也有？ | 结论 |
|---|---|---|
| `PlatformControlImpl: [PlatformControl:496] Error! Framebuffer of Background not create.` | **有** | 常态，不是我们的问题 |
| `PfcDispServer` 起服务 / `spplfctrl`+`dispctrl` added / `startThreadPool finish` | 有 | 我们已在 54 s 全部复现 |
| `connectToServcie bind to network.accessory.manager fail` | 无（真机到得早） | 我们 nwserver 起得晚，稍后自己成功，无碍 |

### 10.5 🔄 当前卡点：Launcher 卡在 LiTE/DirectFB 引擎初始化

`SP_RAM_DUMP` + 离线工具 `/tmp/bt.py`（扫 `thread_info+0xc` 找 task、`pt_regs` 取 `r7`=syscall 号）
实测（快照 `ram_f3.bin`，wall 120 s）：

- Launcher 共 4 个线程，**全部 `state=1` 卡在 `futex`**（`r7=240`），**没有线程做 I/O**，
  说明是纯用户态锁等待，不是设备阻塞。
- 日志缓冲（RAM `0xb615000` 起，LogService 共享环形区）里 Launcher 最后一行为
  `[PluginLoader][~PluginLoader][L:20][PluginLoader] destruction.`，
  **没有** 真机紧随其后的 `[I][EngineLite] getMainLoop line:30` ⇒ 阻塞点在 `libenginelite.so`
  的静态构造 / `createEngine()` 里，即 **DirectFB 初始化**。
- 旁证：`pfc_server` / `as_server` 各有一个线程 `state=130`（TASK_KILLABLE，D 态）
  阻塞在 `read(fd, buf, 0x50)` —— 就是 `/dev/sp_ipc` 的用户态投递（**桩还没补**，见 §10.6）。
- 旁证：`[SpSnd.cpp][init][42]AUDIO ASSERT FAIL(NULL != mShareBufAddr)!` —— chunk/CMA 分配失败。

**已排除**：不是 `res_fb0`（已对）、不是参数缺失、不是 CPU 忙等（PC 采样 9 次全在
`cpu_v7_do_idle+0x6`，是真 idle）。

**下一步的三个抓手**（顺序已按 2026-11-01 基线调整）：

1. **先闭合 `libGAL.so` 的 galcore ioctl**：`/dev/galcore` 已能 open，当前缺的是能力查询和
   命令提交的用户态协议；先用最小 ioctl/寄存器响应验证 IRQ 47 和命令完成，不改 rootfs。
2. **再处理 DirectFB 驱动选择**：让 `gfxdrivers/libdirectfb_gal.so` 被自动探测并与现有
   `systems/` 后端协同，确认日志越过 `Fusion Dispatch`，再观察 `SP_FB_DUMP`。
3. **继续收敛 #21 IPC 用户态投递**：利用已完成的 UART RX 和 guest shell 反查 FIFO/通道，
   解决 `as_server`/`pfc_server` 的阻塞读；`chunkmem.1` 只在出现可复现的分配失败证据后处理。

### 10.6 复现与调试工具

```bash
# 规范启动（cmdline 已内置 mtdparts + res_chunkmem + res_fb0..2）
python3 /tmp/sprun.py <tag> 175 SP_IPC_STUB=1 SP_FB_DUMP=/tmp/fbd \
        SP_PC_MS=20000 SP_RAM_DUMP=/tmp/ram.bin SP_RAM_DUMP_AT=6

# 离线符号/地址互查
python3 /tmp/va.py at 0xc07eb150        # 地址 -> 符号+偏移
python3 /tmp/va.py range c0805690 c0805700
python3 /tmp/xref.py <lo> <hi>          # 谁 movw/movt 出这个地址

# 离线任务/栈分析（从 RAM 快照）
python3 /tmp/bt.py ram.bin --list       # 列出所有 task（state/comm/stack）
python3 /tmp/bt.py ram.bin Launcher     # 某进程 pt_regs + 内核栈

# 从 RAM 快照读内核注册表
#   registered_fb[] @ 0xC0849684，fb_info 各字段看 §10.2
```

**注意**：QEMU 侧 `SP_*` 调试开关不写在 `-append` 里，只作环境变量；`SP_EXTRA` 会追加到 cmdline。

---

## 11. 路线 B · Galcore GPU 虚拟化（2026-10-31）

把 galcore 从"能 probe 不死"推进到"寄存器语义 + 命令缓冲执行 + 完成中断"闭环。

### 11.1 ★ QEMU GIC 输入线号 = Linux IRQ − 32（全局坑）

`hw/intc/arm_gic.c` 的 `gic_set_irq()` 明确写着：

```
[0..N-1] : external interrupts
"The first external input line is internal interrupt 32."   → irq += GIC_INTERNAL
```

所以 **`qdev_get_gpio_in(gic, n)` 对应 guest 的 IRQ `n+32`**。本轮之前只有 NAND(55) 和
IPC 手工减了 32，**UART 的 97/98/99/67 没有减** ⇒ 从 M1 起 UART 中断从未送达 CPU（
控制台是轮询 `sunplus_uart_console_putchar()` 写的，所以一直没人发现）。

已统一为宏 `SP_GIC_SPI(irq) ((irq) - 32)`，四处调用点全部改用。

**定位手法**：`SP_GPU_IRQ_SCAN=1` 让模型逐个抬高 GIC 线（每次只保持一条为高，
`qemu_irq_pulse()` 会在 CPU 采样前就把线拉低，不能用），看哪条能让 galcore 的
`isrRoutine` 跑起来 —— 判据是 `gckHARDWARE_Interrupt()` 每次必读寄存器 `0x010`。
结果：**只有 line 15 有反应**（2031 次），而 galcore 自报 `irqLine = 47`，
47 − 32 = 15，完全吻合。

### 11.2 galcore 模块参数表（从内核 .data 直接读出来，不用猜）

`galcore.*` 是 `module_param_named` 的名字。`__param` 条目布局（32 位，非模块构建）：

```
+00 name   +04 mod(0)   +08 ops   +0C perm(16)+level(16)   +10 arg
```

扫 `galcore.irqLine` 字符串 → 找到引用它的条目 → arg 即变量地址：

| 参数 | 变量 | 默认值 |
|---|---|---|
| `galcore.irqLine` | `0xC0821238` | **47**（→ GIC line 15） |
| `galcore.registerMemBase` | `0xC082123C` | `0x9C110000`（= `SP_GPU_ADDR`） |
| `galcore.registerMemSize` | `0xC0821240` | `0x800` |
| `galcore.contiguousSize` | `0xC082125C` | `0x08000000` |
| `galcore.major` | `0xC0821234` | 199 |

`galcore.showArgs=1`（加进 `-append`）会让 galcore 自己把这张表打到 dmesg，可交叉验证。

### 11.3 寄存器语义（全部有反汇编证据）

| 偏移 | 含义 | 证据 |
|---|---|---|
| `0x000` | INTR_ACK，bit16/17 = AXI/AHB idle | `_ResetGPU` 尾部 `and #0x30000` |
| `0x004` | CHIP_IDLE，bit0 = IP idle | `_ResetGPU` bit0 |
| `0x010` | **中断状态**，ISR 读它 | `gckHARDWARE_Interrupt` `movs r2,#0x10` |
| `0x014` | 命令提交前写 `0xFFFFFFFF` | `gckHARDWARE_Execute` |
| `0x018/0x01C/0x020/0x024/0x034/0x0A8/0x470` | chip identity 七连读 | `_IdentifyHardware` |
| `0x400..0x410` | MMU 相关（5 个同值物理地址） | `gckHARDWARE_SetMMU` |
| `0x654` | **命令缓冲物理地址** | `gckHARDWARE_Execute` `movw r2,#0x654` |
| `0x658` | **命令控制** `(bytes+7)>>3 \| 0x10000`，bit16 = START | 同上 |

`gckHARDWARE_Execute()` 写完 `0x658` 之后 trace 就断了 —— 驱动在等完成中断。

### 11.4 命令流里的 EVENT 编码

`gckHARDWARE_Event()`（0xC057C3C4）写入两个常量字：

```
word0 = 0x08010E01          (movw #0xe01 / movt #0x801，常量)
word1 = 0x40 | eventId      (r3==4 → 0x40，再 orr r6；eventId ≤ 28)
```

（32 字节变体后面接 `0x08050100` + 5 个 0。）所以模型不必反推整个 Vivante 指令集，
**扫 `0x08010E01` 标记、取下一字低 5 位**即可拿到 event id。
`gckEVENT_Interrupt()` 把 status 位当成"event N 完成"（`Event->0x3C8 |= status`，
然后每个置位唤醒一个等待者）⇒ **status = 1 << eventId**。

初始化时提交的那条缓冲是 4 字、无 EVENT（实测 `380000c8 00000000 40000002 <自身地址>`）。

### 11.5 ★ 坑：不要对没有 EVENT 的缓冲伪造完成中断

`gckEVENT_Interrupt()` 对每个置位调用 `gckOS_AtomDecrement(Event->0x450)`。
初始化那条缓冲没有 EVENT ⇒ 没人 increment 过那个原子量 ⇒ 我们多报一次就把它减成 **-1**。
而 `_MonitorTimerFunction()`（0xC0570BF8）的判据正是"该原子量非 0 ⇒ GPU 卡死"：

```
21.008  *** GPU DRV CONFIG *** / GPU[0](ChipModel=0x0 ChipRevision=0x0)
21.192  Execute Count = 0x00000001 / End Addr = 0xFFFFFFFF
21.347  Number of Pending Interrupt: -1      ← 就是这个 -1
21.349  gckKERNEL_Recovery → [galcore]: Stop driver to keep scene.
```

recovery 之后驱动进入 `gckOS_Delay(10000)` 死循环，**DirectFB 还没起来 GPU 就废了**。
修法：扫不到 EVENT 就干脆不产生中断。修复后 `GPU STATE DUMP` / `Stop driver` 出现次数 = 0。

### 11.6 当前能力与验证

- 复位握手（`_ResetGPU` 一轮通过）、probe 完成、`/dev/galcore` 设备建立
- 命令缓冲捕获 + 解码 + 完成中断（IRQ 47 / line 15），ISR 实测响应
- `SP_GPU_TRACE=1` 打印调用点（从 `[sp+0x14]` 取调用者 LR，因为所有访问都过
  `gckOS_Read/WriteRegisterEx` 这层薄封装）+ 缓冲内容前 32 字
- `SP_GPU_IRQ=<n>` 可覆盖中断号；`SP_GPU_IRQ_SCAN=1` 扫描中断线

```bash
python3 /tmp/sprun.py g 16 SP_GPU_TRACE=1 SP_EXTRA="galcore.showArgs=1"
python3 /tmp/sprun.py g 16 SP_GPU_TRACE=1 SP_GPU_IRQ_SCAN=1   # 扫中断线
```

### 11.7 GPU 之后暴露出来的下一道闸门

galcore 活下来之后，用 RAM 快照 + `/tmp/bt.py` 枚举任务（guest 约 0.4× 墙钟，
`SP_RAM_DUMP` + `SP_RAM_DUMP_AT=28` + `SP_PC_MS=2000` 抓 ~56 s 时刻）：

| 任务 | state | pt_regs | 含义 |
|---|---|---|---|
| `Launcher` ×3 | 1 | `r7=4` write(fd=1, 28B) / `r7=240` futex | **主线程卡在写 stdout** |
| `as_server` | 130 | `r7=3` read(fd=7, 0x50) | 读 `/dev/sp_ipc` 阻塞（§路线 B 的 IPC 问题） |
| `pfc_server` | 130 | `r7=0` | 同上 |
| `init` | 1 | `r7=168` poll | 正常 |

并且**控制台上一条用户态输出都没有**（`grep -cvE '^\[' <log>` = 0），
对应 `SP_UART` 仍是 M1 桩：

- `sp_uart_can_receive()` 恒返回 0 ⇒ **RX 完全没实现**（这也解释了 `init=/bin/sh`
  拿不到交互 shell：输入根本进不去）
- `s->irq` 初始化后**从不置位**；RX 走 `sunplus_uart_rxdma{0,1}_irq`（DMA），
  IER 在 `+0x1c`（bit0 全局/RX、bit4 TX，`start_tx` 置 0x10，ISR 判 `&0x11 == 0x11`）

⇒ UART 曾是独立于 GPU 的第二条深水线；现已完成 RX/TX，交互 shell 可用，
因此它不再阻塞 M4。它仍是后续 CFCP（ttyS1 车辆协议，M5）模拟的前置条件。

### 11.8 ★ 已修：UART TX 中断 —— 用户态 stdout 全线打通

`sunplus_uart_irq()`（0xC05676C4）的发送循环：

```
0xC056776E  ldr r0,[r2,#0x1c]; lsls r0,#0x1b; bpl <out>   ; [membase+0x1c] bit4 = TX 使能
0xC0567774  ldr r2,[r2,#4];    lsls r2,#0x1f; bpl <out>   ; [membase+4] LSR bit0 = TX ready
0xC0567796  str.w sl,[r3]                                 ; 字节 -> [membase+0]
```

而 `sunplus_uart_ops_start_tx()`（0xC0566BB4）**只**把 0x10 OR 进 `+0x1c` 就返回，
字节全靠中断推 ⇒ 模型不抬中断时，**任何用户态 `write()` 到 /dev/console 都永久阻塞**。
ISR 发完自己调 `sunplus_uart_ops_stop_tx()`（0xC0566B80）清 bit4，正好用来撤销中断。

实现（等价于硬件 THRE 常有效，因为我们的发送是瞬时的）：

- `+0x1c` 写入时：置 bit4 ⇒ `qemu_irq_raise`，清 bit4 ⇒ `qemu_irq_lower`（电平触发，
  不用 `qemu_irq_pulse()`，它会在 CPU 采样前拉低）
- `+0x1c` 读回时：**OR 上 bit0**。驱动只写过 `0x20`（startup）和 `0x30`（start_tx,
  bit4|bit5），但 ISR 入口要求 `reg & 0x11 == 0x11` ⇒ **bit0 是硬件状态位**（"上个
  字节已发走"），不是软件使能位。

修完的效果（对比 `u1` → `u3`）：

| 指标 | 修前 | 修后 |
|---|---|---|
| 控制台非内核行数 | **0** | **39**（且出现 `root@8AJ1:/#` shell 提示符） |
| host_cpu / 100s | 47.8 s（中断风暴） | 3.95 s |
| 控制台体量 | 15 KB / 235 行 | 56 KB / 642 行 |

新暴露出来的用户态信息（此前完全不可见）：

```
EIPC_Init failed            ×2        ← 任务 B（IPC）
/application/lib/engine/libenginelite.so: load
[PluginLoader][~PluginLoader] destruction.     ← 仍停在这，缺 getMainLoop
Segmentation Fault! info.si_signo=6 (SIGABRT) /usr/local/bin/as_server() [0x24b06]
[SpSnd.cpp][init][42] AUDIO ASSERT FAIL(NULL != mShareBufAddr)!
```

修完后 Launcher 快照（4 线程）：3 × `r7=240` futex + 1 × **`r7=142` select(fd=8)**；
`as_server` 已 abort 消失 ⇒ **IPC 是唯一剩下的闸门**。

调试开关：`SP_UART_TRACE=1` 打印 `+0x1c` 的每次写入及其 PC。

### 11.9 历史记录：UART RX 的实现过程

早期曾误判 `sunplus_uart_irq()` 不读 RX 寄存器、RX 完全走 DMA；
该判断已被 §13.3 的实际收字节路径推翻。下面仅保留 DMA 路径线索：

- `sunplus_uart_rxdma0_irq()`（0xC0566E80）/ `rxdma1_irq`（0xC0566FFC）
- ISR 开头就读 `*(volatile u32*)0xF0800000`（物理 `0x9C000000`）比对 `0x650` / `0x680`
  —— 按 chip id 分支
- 数据来自一个 head/tail 环形缓冲（`[r7,#0x14]` / `[r7,#4]` / `[r7,#0x10]`）

DMA 控制器是 **`sp_cbdma`**（`mmio=0xf0800d00` = 物理 `0x9C000D00`，`irq=106`）。
早期模型没有实现它，但当前交互 shell 已由 UART RX/TX 路径打通，
`tools/guest_shell.py` 可稳定执行命令。`sp_cbdma` 保留为后续 CFCP/车辆数据模拟的扩展点，
不再是 M4 显示点亮的前置条件。

---

## 12. 路线 B · IPC 用户态投递（2026-10-31）

### 12.1 邮箱块格式（实测）

请求块在 `0x9C008110`，0x50 字节：

```
dw0 owner / msg 指针      dw1 ?            dw2 (id<<16)|len
dw3 payload_end           dw4 seq          dw5 ?
dw6 payload 物理地址（len>0x3c 时在外部，len<=0x3c 时是内联数据）
dw7 ?（7/8/0xa/0x4a，疑似通道或索引）
```

实测序列（`SP_IPC_TRACE=1`）：`id=3 len=0x174`、`id=2 len=0x174`（内核，fbdss_init）、
`id=8 len=0x10`、`id=15 len=0xc`、`id=5 len=0x24`（大量重复 —— 用户态）。

### 12.2 ★ rpc_isr 的路由规则（决定回包怎么填）

回包 id（u16，位于块内 `+0x0a`）的位含义：

| 位 | 含义 |
|---|---|
| bit15（`msg[0xb]` bit7） | **1** = 内核 `IPC_FunctionCall` 的应答（用 dw0 当 msg 指针，拷回、置 `msg+0x58`、唤醒 `msg+0x5c`） |
| bit12（`msg[0xb]` bit4） | 0 → fifo 数组 `+0x55c[chan]`；1 → `+0x5ac[chan]` |
| bits 9-11 | `chan = (id >> 9) & 7` |

`sp_ipc_read()` 阻塞在 `rpc_fifo_get(dev->chan[n].fifo)` 上，所以**只走内核分支的回包
永远满足不了用户态 read()** —— 这就是 `[as_server] ipc cmd:-1|0xffffffff err:-1`
（`sp_ipc_read+0x77`，即 `cmp r4,#0` 之后 `r4 == -1`）的真身。

### 12.3 ★ 通道表（从 RAM 快照直接读）

设备对象在 `*0xC08362F0`（实测 `0xcb59d800`），fifo 数组在 `+0x55c`、
sid 数组在 `+0x57c`（**注意 +0x58c/+0x5ac 是它们的别名/重叠**，别当成独立数组）：

```
+0x55c[4] = 0xca8ca000   <- 唯一注册的用户态 fifo
+0x57c[4] = 653          <- 对应 sid（pid）
其余全 0
```

通道号来自 **`write(fd, buf, count)` 的 count**：`sp_ipc_write()` 里
`cmp r2,#7 / cmp r2,#0xf` 直接拿 count 当通道号，所以 `write(fd, buf, 4)` 就是注册通道 4。
而请求里的 id 全都 < 0x200 ⇒ chan = 0 ⇒ 回包默认落到 `+0x55c[0]`（NULL）。

### 12.4 ★ 修掉一个真 panic：别给"通道注册"回内核式应答

`write(fd, buf, 4)` 也会走到 `rpc_write_hw()`，但它**从不设置 dw0**。
我们以前无条件回 bit15=1 的包，ISR 就把 dw0 当 msg 指针：

```
rpc_isr: r4 = dw0; rpc_copy(r4, msg); if (r4->0x50 == 0) up(&r4->0x58);
=> Kernel panic - not syncing: Fatal exception in interrupt
   [<c0418ab9>] (rpc_isr+0xc9) <- [<c043a5e7>] (up+0x23)
```

修法：只有 `dw0` 落在 `0xC0408000..0xD0000000` 才声称是内核应答。

### 12.5 新增开关与当前状态

- `SP_IPC_MODE`：0（默认，仅内核应答）／1（仅用户态 fifo）／2（两投：先内核、100 µs 后用户态）
- `SP_IPC_CHAN=<0..7>`：覆盖回包的通道位
- 投递前校验目标 fifo 是合法内核指针（`sp_ipc_user_fifo_ready()`），否则丢弃
  —— 不加这个，mode 2 会在启动早期把内核打挂

默认（mode 0）已验证**无回归**：无 panic、641 行、host_cpu 5.5 s。

**仍未解决**：`sp_ipc_read` 依然返回 -1。往 chan 4 定向投用户态副本会 panic，
说明我们还不清楚对端该"主动推"什么（as_server / pfc_server 是 RPC 服务端，
它们在等一个对端发起的请求）。UART RX 和交互 shell 已完成（§13），
下一步应直接利用 `tools/guest_shell.py` 在 guest 内检查通道注册、FIFO 布局和服务端请求，
然后实现 #21 的用户态投递；不要再把 UART 或 sp_cbdma 当作当前显示阻塞点。

---

## 13. UART RX 完成 ⇒ 交互 shell 打通（2026-10-31）

§11.9 只做通了 TX，RX 一直缺位。拿到交互 shell 后（本章），
`/proc/interrupts`、`/proc/*/maps`、`/proc/*/fd` 都能直接问 guest，
不再需要靠 RAM 快照反推。

### 13.1 `+0x1c` 是「IER + 状态」混合寄存器，不是纯 IER

驱动只写过两个值：`0x20`（`startup`）与 `0x30`（`start_tx`，bits 4|5）。
但 `sunplus_uart_irq` 入口要求 `reg & 0x11 == 0x11`（bit0 **和** bit4）——
bit4 是 `start_tx` 写的 TX 使能，那 bit0 从哪来？只能来自硬件。

```asm
0xC05676E8: ldr   r3, [r5, r3]      ; r3 = per-uart 寄存器基址
0xC05676EA: ldr   r2, [r3, #0x1c]   ; +0x1c
0xC05676EC: lsls  r2, r2, #0x1e     ; 测 bit1
0xC05676EE: bmi   #0xc05677e0        ; ← bit1 置位 ⇒ 收字节路径
```

同样的推理适用于 bit1：驱动从不写它 ⇒ 它是硬件状态位。

| bit | 含义 | 谁写 |
|---|---|---|
| 0 (0x01) | TX 完成 / 发送器空闲 | 硬件 |
| 1 (0x02) | RX 就绪（有字节可读） | 硬件 |
| 4 (0x10) | TX 使能 | `start_tx` / `stop_tx` |
| 5 (0x20) | RX 使能 | `startup` / `stop_rx` |

**模型写法**：读时算出来、写时 mask 掉。

```c
/* 读 */
uint32_t v = s->regs[(offset >> 2) & 0x1f] & ~SP_UART_IER_STATUS_MASK;
v |= SP_UART_IER_TX_DONE;
if (sp_uart_rx_pending(s)) {
    v |= SP_UART_IER_RX_READY;
}
/* 写：驱动做 RMW（ldr/orr/str），会把状态位又写回去，必须 mask */
s->regs[SP_UART_REG_IER >> 2] &= ~SP_UART_IER_STATUS_MASK;
```

### 13.2 ★ 回显乱码 `?` 的真根因：LSR bit5 不能置 1

症状：字节**读对了**（`UART0 RBR -> 65 ('e')`），但 guest 回显全是 `?`(0x3F)。

`uart_insert_char()` 的最后一个参数是 **tty flag 索引**，驱动这样算：

```asm
0xC0567874: ands  r1, sl, #0x3c    ; sl = LSR 字节，flag = LSR & 0x3c
```

8250 的 flag 索引里 `1 = TTY_BREAK`。而 8250 标准 LSR 的 **bit5 = THRE**，
`0x61 & 0x3c = 0x20` → 索引 2；`0x41 & 0x3c = 0x00` → 索引 0 (TTY_NORMAL)。

关键在于：这套驱动把 LSR 的 bit2..bit5 当**错误标志位**用，
所以 bit5 绝不能置位，否则每个字符都被判成 BREAK 而被改写成 `?`。

⇒ **本芯片 LSR 常态值 = `0x41`**（bit0 TX ready + bit6 TEMT），
**不是 8250 标准的 0x61**。改完立刻回显正确。

### 13.3 收字节路径在 `sunplus_uart_irq`，不在 `rxdma0_irq`

`sunplus_uart_irq`(0xC05676C4) 收到 `+0x1c` 的 bit1 → 0xC05677E0 →
读 LSR(`+0x04`) 取 bit1 判「有数据」→ 读 `+0x00` 取字节 →
`bic r1, r3, #2; cmp r1, #0x11` 判 XON/XOFF(0x11/0x13) → `uart_insert_char()`。

`sunplus_uart_rxdma0_irq`(0xC0566E80) 是**另一条** DMA 路径：
它读 `*(u32*)0xF0800000`（phys `0x9C000000` 偏移 0）比对 chip-id `0x650`/`0x680`，
从 guest 内存里的环形缓冲取字节。当前 **IRQ 106 (`sp_cbdma`) 计数 = 0**，未被使用。

### 13.4 模型改动清单（`hw/arm/sunplus-sp8368.c`）

1. `+0x1c` 读：`(regs & ~0x03) | 0x01 | (rx_pending ? 0x02 : 0)`；写时 `&= ~0x03`。
2. LSR 常态 `0x61` → **`0x41`**。
3. `sp_uart_can_receive()` 真实现（RX 环有空间才收）；`sp_uart_receive()` 入环 +
   `sp_uart_update_irq()`；读 `+0x00` 弹字节并清 RX_READY。
4. `SP_UART_TRACE=1` 打印 `UART%d TX <- xx (pc=…)` 与 `UART%d RBR -> xx`。
5. `sp_fb_dump()` 补 `g_mkdir_with_parents()`——目录不存在时旧代码静默丢掉
   painted 指标（`FBDUMP: cannot create …` 一刷屏却没人看）。

### 13.5 验收

```console
root@8AJ1:/# echo PROBE0
PROBE0
root@8AJ1:/# id; echo MK71184
uid=0(root) gid=0(root)
MK71184
```

`/proc/interrupts`：`97: 969  Sunplus_UART0`（Level）、`84: 15  rpc`、
`106: 0  sp_cbdma`。

### 13.6 取证工具：串口交互 shell

`/tmp/shrun.py`（由 `spsh4.py` 改造）：

```bash
python3 /tmp/shrun.py "cat /proc/interrupts" "ls -l /proc/*/fd"
```

- 自动等 `Freeing unused kernel memory` 与 `root@8AJ1:/#` 提示符；
- 每条命令后跟 `echo MK<n>` 标记，按标记切分输出；
- **guest 控制台一直在刷日志**，输出会互相穿插 ⇒ 复杂取证**先在 guest 内重定向到文件**
  （`cmd > /tmp/x.txt`）再 `cat /tmp/x.txt`；
- `dmesg` 只有 132 行（环形缓冲已滚掉），要更多得靠启动日志文件。

---

## 附录：关键文件索引

| 文件 | 作用 |
|---|---|
| `Gemini-Dummy/flutter_app/lib/main.dart` | Flutter 主前端（QEMU 控制 + 串口桥 + 画面） |
| `Gemini-Dummy/emu.py` | 旧 HTTP 前端（保留） |
| `Gemini-Dummy/kernel/vmlinuz-armhf` | Debian 6.12.107+deb13-armmp 内核 |
| `Gemini-Dummy/initrd-final.cpio.gz` | 最终 initrd（含 qpreinit.sh + Android init + rc） |
| `Gemini-Dummy/patches/init.gui.qemu.rc` | 仿真版 init.gui（linuxfb） |
| `Gemini-Dummy/initrd-{ae5i,diag,disp}.cpio.gz` | 各阶段 initrd 变体 |
| `virtual/{spsdk,spapp,rootfs}.squashfs` | 原厂分区（写死源） |
| `rawimage/ref_ae5i_old_full.BIN` | Full NAND dump（4352 几何，5 坏块） |
| `/tmp/extract_dump.py` | dump 提取参考实现（Python，已验证） |
| `dist/rescue/manifest.json` | 分区表锚点 |

## 14. ★ fb 注册链彻底打通（2026-10-31）—— 附一个"编译没生效"的坑

### 14.1 ★★ macOS 上 `make` 不更新运行用的二进制（踩了一整天）

QEMU 在 macOS 上**一律**把产物命名为 `qemu-system-arm-unsigned`
（`qemu-src/meson.build:3949-3951`），因为 QEMU 需要 codesign 才能用 HVF。
正式版 `qemu-system-arm` 是**手工 codesign 后复制**的。

后果：`make` 只更新 `-unsigned`，而 `sprun.py`/`shrun.py`/`mon.py` 全都指向
`build/qemu-system-arm` —— 于是**改完模型代码重新编译，跑的还是旧二进制**。
所有新加的探针/开关静默失效，表现为"代码明明写对了却完全没效果"
（本轮连续 6 次改动全部空跑就是被这个坑吃了）。

**修法**：新增 `tools/build_model.py` —— 构建后把 `-unsigned` 同步到
`qemu-system-arm`，并校验产物里含预期的探针字符串：

```bash
python3 tools/build_model.py          # 构建 + 同步 + 校验
python3 tools/build_model.py --check   # 只校验当前产物是否最新
```

**以后每次改模型代码都必须走这个脚本**，不要再直接 `make`。

### 14.2 `/dev/fb0` open 失败的真正根因：模型 IPC 回包的字段偏移全错

链路（全部实测/反汇编确认，不是推测）：

```
fbdss_init()                                   0xC07EB150
 └─ _Get_UI_Res()                              0xC0580944
     └─ IPC_FunctionCall(3, msg, 0x174)        ← ★ UI 分辨率是向 GD32 MCU 问的
 └─ 遍历 3 条 0x7c 记录 (sb+0x00 / +0x7c / +0xf4)
     └─ _create_device()  (内联在 fbdss_init)
         └─ register_framebuffer()             0xC054A96C
             ├─ device_create(class, NULL, dev_t, NULL, "fb%d", idx)   0xC0583D60
             │    └─ 失败 → 打印 "Unable to create device for framebuffer %d; errno = %ld"
             │                (0xC0763104) → fb_info+0x228 = 0
             └─ registered_fb[slot] = fb_info   0xC054AAAA: str r4,[r8,r5,lsl#2]
```

模型 `sp_ipc_fill_fb_info()` 之前按**自己猜的偏移**填回包
（`+0x04`=width、`+0x08`=height、`+0x34`=bpp、`+0x38`=size…），
与内核实际读取的偏移不一致 ⇒ `device_create()` 拿不到合法 `dev_t`/名称 ⇒
`registered_fb[]` **从未被写入** ⇒ `get_fb_info(0)` 返回 NULL ⇒
`fb_open()` 走 `request_module("fb%d")` 重试仍失败 ⇒ **-ENODEV**。

### 14.3 ★ 两张 fb 表不是同一个数组（此前笔记记错了）

| 表 | VA | 用途 | 谁写 |
|---|---|---|---|
| `registered_fb[]` | `0xC0800BDC` | **内核标准 fbdev 数组**，`get_fb_info(minor)` 按 minor 索引 | `register_framebuffer()` `0xC054AAAA` |
| 厂商 fb 表 | `0xC0849684` | Sunplus 自己的表 | `fbdss_init()` `0xC07EB636` |

`get_fb_info.part.0`（`0xC054ABF8`）反汇编：
`movw r3,#0xbdc / movt r3,#0xc080 / ldr.w r4,[r3,r4,lsl #2]` —— 索引 minor。
之前笔记把 `0xC0849684` 记成 `registered_fb[]`，是错的。

**VA→PA 换算：`PA = VA - 0xC0000000`**（内核 VA 0xC0000000 映射到物理 0）。
曾把 `0xC0800BDC` 误算成 `0x08000BDC`（多一个 0），导致读出来全是 0，
误判成"fb 没注册"。**读 guest 内存前先用已知非零值校准换算**。

### 14.4 新增模型探针：`SP_FB_REG=1`

`hw/arm/sunplus-sp8368.c` 新增 `sp_dump_fb_registries()`，在
**IPC cmd 3（UI 分辨率请求）** 与 **cmd 2（后续请求）** 各打一次
两张表的前 8 个 dword —— cmd 3 是 fb 创建**前**，cmd 2 是**后**，
一眼看出注册是否成功：

```
FBREG probe: id=3 len=372
FBREG generic registered_fb[] @VA c0800bdc: 00000000 ... (创建前，空)
FBREG vendor fb table        @VA c0849684: 00000000 ...
FBREG probe: id=2 len=372
FBREG --- after fb creation ---
FBREG generic registered_fb[] @VA c0800bdc: cb54c400 ... (创建后，已填!)
FBREG vendor fb table        @VA c0849684: cb54c400 ...
```

### 14.5 150Aura 现状与下一步（仅历史对照）

**已闭合（链路验证）**
- ✔ `fb_info` 完全正确：`/proc/fb`=`0 FB-O0-800x480`、stride=3200、bpp=32；`registered_fb[0]` 与厂商表（§14.3）都已填上（`SP_FB_REG` 探针：cmd3 后 `registered_fb[0]=0` → cmd2 后 `=cb54c400`）。
- ⚠️ **`/dev/fb0` open 返回 ENODEV 是正常现象，真机也一样**（见 §14.6）：vendor 内核 fbdev 用「major 0 + minor N」设备号，而节点是 29:0 ⇒ 必 ENODEV。这**不是仿真 bug**，`fb_info` 本身完全正确。**显示路线应走 DirectFB + galcore GPU 直绘，不是 fbdev。**

**150Aura M4 最后一公里（历史待办；不可套用到 AE5I）**
1. **`libGAL.so` 经 `/dev/galcore` ioctl 取 GPU 能力未通**（§14.10）：`exec 3<>/dev/galcore` 已证明 open 成功；当时待补的是 `gal_config_init` 的能力查询、命令提交和 IRQ 47 完成闭环，不能再把 `dd` 的 read EINVAL 当作 open 失败。
2. **DirectFB 卡在 gfxdriver 探测之前**（§14.8 / §14.11）：停在 `Fusion Dispatch` 之后、gfxdriver 加载前；当前 maps 中已见 `systems/libdirectfb_fbdev.so`，但尚无 gal 加速驱动工作的证据（两者是不同插件层，不能互相替代）。通过用户态提交与 IRQ 47 的对应关系验证第 1 项；M4 验收指标仍是 `SP_FB_DUMP` 的 `painted` 从 `0.0000` 变非 0。
3. **#21 IPC 用户态投递**（§12）：`[as_server] ipc cmd:-1|0xffffffff err:-1` + oops 栈 `sp_ipc_read+0x77`。内核分支已完成（回包 dword2=`(status<<16)|len`，bit15=1→内核分支）；用户态 fifo 投递（只有 chan 4 注册，§12.3）未通。
4. **#22 改 rootfs `init.gui.lite.rc`**：**注意不是加 `gfx=gal`**（DirectFB 1.6 **无 `gfx=` 参数**，§14.7；驱动靠 `dfb_graphics_drivers` 数组自动探测 `gfxdrivers/` 目录）—— 而是保证 `gfxdrivers/libdirectfb_gal.so` 能被自动探测选中。rootfs squashfs 可解压可重打包，分区在 spvd 偏移 `0xc81000`。

**DirectFB 插件全集**（`/tmp/sp/usr/local/lib/directfb-1.6-0-pure/`）：
```
gfxdrivers/   libdirectfb_gal.so              ← GPU 驱动，真机走这条
inputdrivers/ libdirectfb_linux_input.so  libdirectfb_tslib.so
interfaces/   ICoreResourceManager IDirectFBFont IDirectFBImageProvider
              IDirectFBVideoProvider IDirectFBWindows IWater
systems/      libdirectfb_devmem.so  libdirectfb_dummy.so  libdirectfb_fbdev.so
wm/           libdirectfbwm_default.so
```

### 14.6 ★ `/dev/fb0` 打不开是**真机也一样**的现象 —— 真机靠 GPU 直绘

实测（guest 内）：

```
stat /dev/fb0   ->  6:156 character special file 1d:0   (major 0x1d=29, minor 0)
/proc/devices    ->  29 fb
/sys/class/graphics/fb0/dev -> 29:0
dd if=/dev/fb0  ->  No such device (ENODEV)
```

而 `fb_open`（`0xC054AC3C`）开头就是：

```c
r3 = 0xffffe000;
r5 = inode->i_rdev;              /* [r0+0x2c] */
if (r5 & 0xffffe000) return -ENODEV;   /* ← 设备号高位必须为 0 */
minor = r5 & 0xfffff;           /* ubfx #0,#0x14 */
fb_info = get_fb_info(minor);
```

⇒ 这个 vendor 内核的 fbdev 走的是 **「major 0 + minor N」的设备号方案**
（掩码 `0xffffe000` 覆盖 bit13..31），而 `/dev/fb0` 是标准的 **29:0** ⇒
必然被判 ENODEV。**真机上也打不开 `/dev/fb0`**。

⇒ **真机的显示根本不走 fbdev**，而是 DirectFB 的 GPU 驱动
`gfxdrivers/libdirectfb_gal.so`（依赖 `libGAL.so`，直接操作 galcore GPU）。
这条路径完全不碰 `/dev/fb0`，所以真机 UI 正常。

**fb_info 本身是好的**（sysfs 全部正确）：
```
name=FB-O0-800x480  virtual_size=800,1536000  stride=3200  bits_per_pixel=32
```
⇒ fb 注册成功、fbdev 兼容层只是**没有可用的设备号**。

### 14.7 DirectFB 的驱动选择机制（实测）

- 核心 `libdirectfb-1.6.so.0.3.0` 里**没有 `gfx=` 这个选项**，
  有的是 **`system=`** 和 `fbdev=` ⇒ `gfx=gal` 是**无效参数**。
- 核心引用 `dfb_graphics_drivers` 数组，驱动通过
  `/usr/local/lib/directfb-1.6-0-pure/gfxdrivers/libdirectfb_*.so` 注册。
- 系统上**没有 `directfbrc`** ⇒ DirectFB 只能自动探测 gfxdrivers 目录。
- `libdirectfb_gal.so` 的依赖齐全：`libGAL.so`（219 KB，存在）、
  `libdirect-1.6.so.0`、`libfusion-1.6.so.0`、`libdirectfb-1.6.so.0`。
- `/dev/galcore`（major 199）存在，**open 已成功**（§14.10）；`dd` 的 EINVAL 来自 read，ioctl 能力查询仍待验证。

### 14.8 ★ DirectFB 初始化在 GPU 探测**之前**就卡住了

去掉 `quiet` 后 DirectFB 自己打的日志：

```
| DirectFB 1.6.3 |
(*) DirectFB/Core: Single Application Core. (2025-01-03 06:05)
(*) Direct/Memcpy: Using armasm_memcpy()
(*) Direct/Thread: Started 'Fusion Dispatch' (-1) [MESSAGING OTHER/OTHER 0/0] <8388608>...
                                     ↑ 日志到此为止，没有 gfxdriver 探测行
```

⇒ 卡在 Fusion 消息线程启动之后、gfxdriver 加载之前。
下一步应查 DirectFB 核心在 `dfb_graphics_drivers` 初始化时卡在哪
；`libGAL.so` 的初始化/ioctl 是候选调查点，尚不能仅凭日志缺失确认阻塞函数。
`/dev/galcore` 已能 open，不能再用 read 的 EINVAL 解释初始化失败。

**验收口径不变**：M4 = `FBDUMP painted` 从 0.0000 变非 0。

### 14.9 ★ guest 取证工具链（固化到 `Gemini-Dummy/tools/`）

| 工具 | 用途 |
|---|---|
| `tools/build_model.py` | **唯一正确的模型构建入口**：ninja 构建 → 同步 `qemu-system-arm-unsigned` → `qemu-system-arm` → 校验产物含探针字符串。`--check` 只校验。 |
| `tools/guest_shell.py` | guest 交互 shell。逐条命令模式（可靠）；`--script <文件>` 用 base64 送脚本（见下方坑）。 |
| `tools/fb_diag.py` | QEMU monitor 读 guest 物理内存的诊断脚本（`xp /Nw <addr>`）。 |

**guest 取证的三条实战规则**（都踩过）：

1. **guest 控制台一直在刷日志** ⇒ 复杂取证先在 guest 内写文件、再单独 `cat`。
2. **每次 `guest_shell.py` 都是全新 guest**（`/tmp` 是 tmpfs，重启即清）⇒
   多步操作必须**在同一次运行内**完成，否则前面造的 `/tmp/xxx` 全没了。
3. **UART 会丢字** ⇒ 往 guest 送长脚本必须**逐块校验**。
   `--script` 模式按 48 字节 base64 分块、每块写独立文件、最后 `cat` 拼接并核对总长度；
   校验不过会打印 `WARNING: script transfer incomplete`。
   **普通命令模式反而更稳**（短命令不丢字），优先用它。

**`guest_shell.py` 的两个细节**：
- 命令以 `&` 结尾时**不能**再追加 `; echo MK<n>`（shell 语法错误），
  工具已自动处理。
- `cd` 之后提示符会变成 `/tmp/sp/application/bin#`，等提示符的匹配要放宽。

### 14.10 ★ galcore 设备与参数（实测）

```
/dev/galcore          major 199, minor 0
/sys/module/galcore/parameters/:
    irqLine = 47            ← 与模型一致
    major  = 199
    baseAddress = 0x9C110000  ← GPU 寄存器基址, 与模型一致
    registerMemBase = 2618359808 = 0x9C110000
    registerMemSize = 2048
    physSize = 134217728 (128 MB)
    contiguousSize = 4194304 (4 MB)
    mmu = 1, bankSize = 0, powerManagement = 0, recovery = 0
```

`exec 3<>/dev/galcore` ⇒ **rc=0，open 成功**。
（`dd if=/dev/galcore` 报 EINVAL 是因为 **read** 被拒，不是 open 失败 —— 别被误导。）

### 14.11 ★ DirectFB 卡点的准确位置

去掉 `quiet` 后 DirectFB 自己打的日志**只有 15 行**，停在：

```
| DirectFB 1.6.3 |
(*) DirectFB/Core: Single Application Core.
(*) Direct/Memcpy: Using armasm_memcpy()
(*) Direct/Thread: Started 'Fusion Dispatch' (-1) [MESSAGING OTHER/OTHER 0/0] <8388608>...
```

- 之后**没有** gfxdriver 探测行 ⇒ 卡在 Fusion 消息线程启动之后、驱动加载之前。
- 但 `libdirectfb_fbdev.so` **确实被加载了**（在 `/proc/*/maps` 里）⇒
  说明已经走到后端选择，只是 `systems/` 下三个后端
  （`libdirectfb_{fbdev,devmem,dummy}.so`）里挑中了 fbdev。
- galcore 中断 47 计数始终 = 0 ⇒ 尚未观察到该用户态路径产生 GPU 完成中断；单凭计数不能证明驱动未加载。
- 该次 RAM 快照中 `/dev/galcore` 无进程持有 ⇒ 当时尚无证据表明 `libGAL.so` 走到 open；§14.10 的独立测试已证明 open 本身成功，当前应继续查 ioctl/能力查询。

**⇒ M4 最后一环的入口**：让 DirectFB 选中 `gfxdrivers/libdirectfb_gal.so`
，同时确认 `systems/` 后端的初始化能继续，并让 `libGAL.so` 的
`gal_config_init` 能通过 `/dev/galcore` 的 ioctl 拿到 GPU 能力。

因为 `systems/` 与 `gfxdrivers/` 是两个独立目录，**DirectFB 会分别探测**：
`systems/` 提供输出后端（fbdev/devmem/dummy），`gfxdrivers/` 提供加速驱动（gal）。
真机上 `fbdev` 后端打不开 `/dev/fb0`（ENODEV，见 §14.6）也会失败，
但真机靠 **gal 加速驱动** 仍然能出图 —— 仿真里 gal 没被选中/没加载成功，
所以整条链断在这里。

### 14.12 ★ guest 取证性能坑（实测）

在仿真里遍历 `/proc/[0-9]*/maps` **非常慢**（几百个进程，每个 maps 几十 KB，
且 4.9 的 procfs 读要走文件系统路径）⇒ 一条
`for p in /proc/[0-9]*; do grep ... $p/maps; done` 在 20 秒窗口里跑不完。

**正确做法**：
- 先用 `grep -q Launcher /proc/*/comm` 之类**先定位 PID**（`/proc/*/comm` 很小，很快），
  再只读那一个 PID 的 maps；
- 或者扫 **PID 区间**（`/proc/72[0-9]`）而不是全量 glob；
- 全量扫描放到 guest 内写文件，宿主再单独 `cat`。

### 14.13 ★ `guest_shell.py` 的三个必要修正（都已内置）

1. **命令以 `&` 结尾时不能追加 `; echo MK<n>`**（shell 语法错误）⇒
   改成追加一条独立的 `echo MK<n>`，标记照常出现，输出切分不受影响。
2. **`SP_CMD_WAIT`** 环境变量控制单条命令的等待秒数（默认 25）。
3. `--script` 模式逐块校验传输完整性，失败时打印
   `WARNING: script transfer incomplete (want N got M)`。
   **但普通命令模式更稳**（短命令不丢字），多步操作优先用普通命令模式，
   并保证**在同一次运行内**做完（`/tmp` 是 tmpfs，重启即清）。

### 14.14 150Aura 基线（可直接复现，不代表 AE5I）

```
$ cat /proc/fb
0 FB-O0-800x480
$ cat /sys/class/graphics/fb0/stride /sys/class/graphics/fb0/bits_per_pixel
3200
32
$ dd if=/dev/fb0 of=/dev/null bs=4 count=1
dd: /dev/fb0: No such device      (rc=1)
```

⇒ **fb0 注册成功、fb_info 完全正确**（800×480×32）；
⇒ **fbdev 兼容层打不开**（该 vendor 内核 fbdev 用「major 0 + minor N」设备号方案，
而节点是 29:0；**真机同样打不开**，见 §14.6）。

⇒ **因此仿真的显示路线不是 fbdev，而是 DirectFB + galcore GPU 直绘**
（`gfxdrivers/libdirectfb_gal.so` + `libGAL.so`），
这与真机一致；M4 的验收口径仍是 `SP_FB_DUMP` 的 `painted` 从 0.0000 变非 0。

---

## 15. 验证镜像鉴定：nand-backup 四份烧录器 dump（2026-11-01）

### 15.1 逐份鉴定结论

| 文件 | 机型判定 | 关键证据 | 与文件名 |
|---|---|---|---|
| **`AE5.BIN`** | **AE5I** | Qt 资源前缀 `PCODE_AE5I`；`hostname AE5I`；运行日志 `getVIN: 358122500139490` | ✅ **定为本项目验证镜像** |
| `备份ae5` | **AE5I** | `PCODE_AE5I`；`hostname AE5I` | ✅ 一致（备用） |
| `AE4 max XT26G04C.BIN` | **FE41 / AE4 Max** | `PCODE_FE41`；`hostname FE41`；U-Boot `jenkins-AE4-16`（2025-04-17） | ✅ 一致 |
| `AE4 max XT26G04C(1).BIN` | **FE41 / AE4 Max（较新）** | 同上 + 第二个 U-Boot `jenkins-AE4_OTA_DEV-26`（2025-09-11） | ✅ 一致 |

四份 MD5 互不相同（独立转储）：
```
AE4 max XT26G04C(1).BIN  6b929a2f672a8e3cb445c6a9bc44b5dd
AE4 max XT26G04C.BIN     85d391c31206afa33a648252957a2c39
AE5.BIN                  0dd5f39f1dc09486344f962c557a160c
备份ae5                  bd601b0827e04850301f7a9023ac1397
```

> `AE4`/`AE5` 字样在库里到处都是（C++ 符号 `PasswordULAE4::`、图片目录 `://AE4i/`），
> **不能直接 grep 字面量定机型**；必须看 Qt 资源前缀 `PCODE_*` 或 `init.environ.rc` 的 `hostname`。

### 15.2 几何（四份一致，实测）

- **4096 + 256 = 4352 B/帧，64 页/块，2048 块**；数据 512 MiB + OOB 32 MiB = 570,425,344 B。
- 坏块（OOB[0]/[1] ≠ 0xFF）：**`[383, 716, 1049, 1382, 1715]`**，四份完全相同。
- 判定：按 4352 解析时 `hsqs`/uImage 魔数全部页对齐；按 2176 解析时"坏块"变成数百个随机块（明显错误）。

关键分区（逻辑偏移，与 25 分区表吻合）：
| 分区 | 逻辑偏移 | 内容 |
|---|---|---|
| `uboot1` | `0x00080000` | uImage（`U-Boot 2014.04`） |
| `uboot2` | `0x00140000` | uImage |
| `ecos` | `0x00400000` | uImage |
| `kernel` | `0x00800000` | uImage `Linux-4.9.217`，load=ep=`0x408000`，data=4,390,912 |
| `rootfs.` | `0x00C80000` | squashfs 4.0 / LZO，4.00 MiB |
| `spsdk.` | `0x01180000` | squashfs 4.0 / LZO，43.56 MiB |
| `spapp.` | `0x04180000` | squashfs 4.0 / LZO，52.05 MiB |

### 15.3 两份 AE5I 的差异（同固件、两次读取）

`AE5.BIN` vs `备份ae5`：rootfs / spsdk **逐字节相同**；spapp 只有 2 处不同 ——
`libdashclustoractivity.so` **1 字节**（`+0x19884E5`）、`fonts/Alibaba-PuHuiTi-Bold.ttf` **2 字节**。
uboot1 构建时间不同：`AE5.BIN` = 2025-03-17，`备份ae5` = 2024-11-11。
⇒ 属同一固件的两次转储（差异在 NAND 读取噪声量级），不是两个版本。

### 15.4 产物与切换

| 产物 | 说明 |
|---|---|
| `images/kernel-ae5i.bin` | kernel uImage，4,390,976 B，header/data CRC 均校验通过 |
| `images/ae5i.spvd` | SPVD v1，536,875,008 B；page=4096 / oob=256 / ppb=64 / blocks=2048；坏块 5；25 分区 |

- `tools/guest_shell.py`、`tools/fb_diag.py` 默认镜像已切到 AE5i，可用 `SP_KERNEL` / `SP_VDISK` 覆盖。
- **CF150Aura（8AJ1）不再作为验证路线**；`images/kernel-150aura.bin`、`images/150aura.spvd` 仅留历史对照。

### 15.5 启动验收（启用实验性显示 IPC stub）

```
$ hostname
AE5I
$ cat /proc/fb
0 FB-O0-800x480
$ cat /proc/mtd | head -3
mtd0: 00040000 00040000 "nand_header"
mtd1: 00040000 00040000 "xboot1"
mtd2: 000c0000 00040000 "uboot1"
```

### 15.6 注意

- `AE5.BIN` 的 VIN = **`358122500139490`**，**不是**本项目车 `358122500143678`
  ⇒ 另一台 AE5i 的转储，**机型一致、整车身份不同**（做功能验证可以，别当本车配置基线）。
- `备份ae5` 的 userdata 无 VIN 日志 ⇒ 车源不可确认，仅作备用。
- 早期笔记「本机 AE5i 片 = 2048+128 / 128 PPB」与这四份 dump 不符：**这四份统一 4096+256 / 64 PPB**，两套几何别混用。

## 16. AE5I 原版镜像启动与当前阻塞（2026-11-01）

### 16.1 启动基线

`tools/guest_shell.py` 默认使用 `kernel-ae5i.bin` + `ae5i.spvd`，启动参数包含原厂 25 分区表和 `res_chunkmem`/`res_fb0..2`。实测无 IPC stub 时到达 `root@AE5I:/#`，`uname -a` 确认 Linux-4.9.217，`/proc/mtd` 列出 25 个分区；SPI-NAND 页读、UART0 RX/TX 和交互命令可用。

无 stub 的关键观察：

| 观察 | 结果 | 含义 |
|---|---|---|
| `/proc/fb`（严格无 peer） | 空 | 原厂 `fbdss` 没有拿到协处理器显示应答 |
| `/proc/interrupts` IRQ 84 (`rpc`) | 0 | 没有模拟 peer 响应 IPC mailbox |
| `sp_ipc` | 设备服务可启动，但 RPC 客户端读不到对端事件 | 缺少 eCos/GD32 peer 是当前显示启动链的直接缺口 |
| Launcher（严格无 peer） | 未出现在 `ps` | `init` 的 Launcher 启动依赖未完成 |
| `SP_FB_DUMP` 默认采样 | `painted=0.0000` | 该探针仍假设 PA `0x0C000000`/800×480；AE5I 地址未确认时不能据此断言实际 surface 全黑 |

启动日志另有 `sp_config_init() failed`、I2C adapter 缺失和 als308 多次 10 秒超时。这些是后续板级设备模型/启动耗时工作；当前先解决显示所需的 IPC 对端。

完整 profile 下，上述两项已分别变为 `0 FB-O0-800x480` 和常驻 `/application/bin/Launcher`；因此原厂用户态启动链已具备可复现验收路径。

### 16.2 完整启动 profile 与严格基线

完整 profile 使用当前 mailbox peer 的 cmd3 回复，使原厂 init 继续完成：`/proc/fb` 出现 `0 FB-O0-800x480`，`/application/bin/Launcher` 常驻，RPC IRQ84 有响应。该 peer 的显示记录仍来自共平台实验推断；GPU IRQ47 和真实像素绘制尚未作为 M4 验收。

默认完整启动：

```bash
python3 Gemini-Dummy/tools/guest_shell.py 'cat /proc/fb' 'ps | grep Launcher'
```

严格无 peer 基线：

```bash
SP_COMPLETE_BOOT=0 SP_CMD_WAIT=10 python3 Gemini-Dummy/tools/guest_shell.py \
  'cat /proc/fb' 'cat /proc/interrupts' 'ps'
```

显式 `SP_IPC_STUB` 仍可覆盖 profile。完整 profile 只证明原厂用户态启动链可运行，不可作为真实车辆协处理器或 GPU 像素路径已验证的证据。

`tools/fb_diag.py` 也已改为遵守此边界：默认不设置 IPC stub；只有显式提供 `SP_FB_TABLE_VA`、`SP_REGISTERED_FB_VA`、`SP_FB_USERS_VA` 才读取对应 guest 地址；`fb_info` 字段偏移须另以 `SP_FB_INFO_OFFSETS_CONFIRMED=1` 显式确认后才会探测。未配置时它跳过旧的 150Aura 地址/结构假设，避免对 AE5I 产生伪阳性。

### 16.3 当时计划（已由 §18 的 AE5I 进展取代）

以下计划是在 AE5I 专属 GAL/CFCP 工作完成前写下的阶段记录；当前状态和下一步以 §18 为准。

1. 分别从 `AE5.BIN` 的 kernel 和 rootfs/spsdk/spapp 提取 AE5I 自己的 `fbdss_init`、`_Get_UI_Res`、IPC ioctl/read/write 和 DirectFB 启动配置；为 AE5I 建独立地址/结构记录，不复用 §10–§14 的 150Aura 常量。
2. 解析 AE5I `ecos`/MCU 可用的启动配置和 IPC 请求，确定 cmd3 的真实回复及后续用户态事件；实现可开关、带请求/应答 trace 的 peer 模型，先让 `/proc/fb`、Qt Launcher 启动和用户态 IPC 读分别通过。
3. 从 AE5I kernel 的 `res_fbN` 参数和运行时 `fb_info` 证据确认 framebuffer PA、尺寸、stride、像素格式；再给 `SP_FB_DUMP` 提供正确参数。不要把默认 `0x0C000000` 或 150Aura 的 fb registry 地址当作 AE5I 真值。
4. 对照 `/proc/<Launcher>/maps`、fd、wchan、DirectFB 日志和 galcore IRQ，闭合 AE5I DirectFB system/gfxdriver、`libGAL.so` ioctl 和 GPU 命令完成路径。目标验收是连续抓到真实 AE5I UI 更新，并且无服务重启或 galcore recovery。
5. 显示闭环后再接 ttyS1 CFCP、GD32 行车状态和按键行为；当前 UART shell 已打通，但这不等于 CFCP 车辆数据仿真完成。

修改范围：本轮仅调整 `guest_shell.py` 的 stub 默认值和本文件记录。未改 `firmware/`、镜像数据或 QEMU 机器模型源码；没有生成任何可刷固件包。

## 17. AE5I 启动与软件显示回退（历史快照）

在 `AE5.BIN` 对应的 `images/kernel-ae5i.bin` + `images/ae5i.spvd` 上，原装
Linux-4.9.217 已完成启动，`/proc/fb` 为 `FB-O0-800x480`，原厂 Qt
`/application/bin/Launcher` 常驻并进入仪表主页面。DirectFB 已成功 mmap
800×480、ARGB、3200 stride、800×960 双缓冲 framebuffer；抓帧可见原厂
里程/耗电/总里程页面，证明 Qt 绘制链已经写入 guest RAM。

当时默认完整 profile 优先尝试 `galcore`。在 gal 用户信号/`libGAL.so`
ioctl 尚未闭合前，可生成一个只用于 QEMU 的软件栅格 SPVD：

```bash
python3 Gemini-Dummy/tools/prepare_software_display.py
SP_VDISK=dist/qemu-ae5i/ae5i-software.spvd \
  SP_FB_DUMP=/tmp/ae5i-fb \
  python3 Gemini-Dummy/tools/guest_shell.py 'cat /proc/fb' 'ps | grep Launcher'
```

生成器只复制 `images/ae5i.spvd`、重打包 rootfs 的 `init.environ.rc`（追加
`disable-module=gal,no-vt,no-vt-switch,no-hardware,vsync-none,no-flip-wait`），
输出到 `dist/qemu-ae5i/`，并写入 SHA-256 清单；不修改 `firmware/`，也不是
OTA/可刷包。软件路径的连续抓帧是当时的 Launcher 检查路径；后续 GAL、按键
和动画资源状态见 §18。

按键方面，该阶段只确认了 `cfcp-keypad` 和 `/dev/input/event0`。后续 §18
已用 ttyS1 CFCP 帧实测上、下、SET、BACK 的按下/释放；其他物理键仍待
KeyID 证据，不能从电气图推定。

## 18. AE5I GPU 和原生按键进展（2026-11-01）

### 18.1 GPU 模型

- 原厂 GAL 插件和 `libGAL.so` 已加载；原模型 chip model/features 为零，GAL 返回 `-13`（Vivante `NOT_SUPPORTED`），像素路径依赖软件回退。
- 通过 `SP_GPU_EXPERIMENTAL_GC320=1` 启用**实验性** GC320/PE2 诊断人格。这是兼容性假设，不是从 AE5I 原理图或实机确认的 GPU 型号，也不默认打开。
- FE 跟随 WAIT/LINK，空转时每 tick 只检查一次等待链；MMUv0 从 FE/PE 页表把 bit31=1 的 GPU 虚拟地址映射到 4 KiB 物理页。原厂 trace 验证了 `0x81...` 命令链和 IRQ47。
- 2D 已实现线性 ARGB/XRGB 的 CLEAR、源拷贝、source-over（支持已预乘/未预乘）、PE2 INDEX8 palette、nearest-neighbour STRETCH_BLT。遇到未支持的命令/布局停止 FE，避免误报完成。
- `python3 Gemini-Dummy/tests/test_gpu_2d.py`（15 项）验证 clipping、重叠拷贝、alpha、palette、缩放、MMU、WAIT patch、event 中断、未支持命令、fb0/fb1 翻页快照。
- 一次 AE5I guest 回归中，trace 记录 813 条受支持的 2D 操作、IRQ47=397、25 次翻页，Launcher 进入 `poll_schedule_timeout`，未见 GPU recovery；framebuffer 已出现 Launcher 页面。最初白色文字仅为 54 的差异来自抓取了过期的后台缓冲页：跟随 IPC cmd 6 选择显示页后，同一页面文字恢复为 255，与软件对照仅顶部区域的 390 像素不同。截图保存在 `dist/qemu-ae5i/{gal-preview,software-preview}.png`。
- 尚未覆盖完整 GPU、视频、所有像素格式与正确图层合成；不能以插件加载或单一非黑帧作为加速完全验收。

2026-11-01 后续优化：

- 2D 缩放、INDEX8 转换和 source-over 的行缓冲改为每个矩形复用，避免每条绘图命令按扫描线反复分配/释放宿主内存；GPU qtest 15 项已通过，收益尚无独立性能基准量化。
- `IPC cmd 6` 现在分别记录 window 0..2 的活动页。`SP_FB_WINDOW=0|1|2` 可抓取对应 `res_fb0`/`res_fb1`/`res_fb2` 地址，并跟随该窗口自己的翻页；`SP_FB_ADDR` 仍可显式覆盖基址。多窗口注册只属实验 profile，单层快照不能代表 PFC 最终合成输出。
- 新构建的三窗口实验回归里 `/proc/fb` 列出 fb0/fb1/fb2，Launcher PID 658 常驻，GAL IRQ47=264；用 `SP_FB_WINDOW=1` 独立抓取 fb1 仍是纯黑。注册窗口不等于背景已绘制或合成，当前 fb0 可见的仍是原厂 Qt Launcher 局部页面。
- 原厂 `anm_logo` 分区含 `logo.mkv`：从 SPVD 资源容器提取的 Matroska 流为 H.264、1024×600、60 fps、约 1.867 秒。启动链当前没有消费该资源的证据，尚未接入开机播放；也未闭合 PFC 背景层和车辆数据，所以仍不能验收启动动画 + 完整仪表。

该路径模拟 guest 的 Vivante 2D 命令语义，命令栅格化在 QEMU 宿主 CPU 上完成；“GPU”指 guest 看到的设备和 galcore 交互，不表示 QEMU 已把命令卸载给宿主 GPU。优化目标是命令兼容性与模拟开销，收益须以独立性能基准量化。

生成实验性 GAL SPVD（仅 QEMU 使用）：

```bash
python3 Gemini-Dummy/tools/prepare_software_display.py --profile gal \
  --output dist/qemu-ae5i/ae5i-gal.spvd
SP_VDISK=dist/qemu-ae5i/ae5i-gal.spvd SP_GPU_EXPERIMENTAL_GC320=1 \
  SP_GPU_2D_TRACE=1 SP_FB_FRAME=/tmp/ae5i-gal.ppm \
  python3 Gemini-Dummy/tools/guest_shell.py 'sleep 30; cat /proc/interrupts | grep galcore'
```

默认可靠显示仍用 `dist/qemu-ae5i/ae5i-software.spvd`。`SP_FB_FRAME` 原子更新单张 PPM，跟随 AE5I `IPC cmd 6` 的 fb0 缓冲页；显式 `SP_FB_ADDR` 时保留指定地址。此路径尚不是完整 PFC 叠层模型。旧实验 peer 在 64 次请求后停止应答；现对有效内核请求持续应答，用户态 peer 仍是未完成的实验模型。

按窗口检查实验性背景缓冲：

```bash
SP_FB_MULTI=1 SP_FB_WINDOW=1 \
SP_VDISK=dist/qemu-ae5i/ae5i-gal.spvd \
SP_GPU_EXPERIMENTAL_GC320=1 SP_FB_FRAME=/tmp/ae5i-fb1.ppm \
python3 Gemini-Dummy/tools/guest_shell.py 'sleep 20; cat /proc/fb'
```

### 18.2 原厂 CFCP 导航键

`instruction/page79-elec.jpg` 把手原理图标出左手菜单开关、转向及变光开关、另一组坐垫/定速/警示/喇叭开关，右手照明、模式和启动开关。图纸描述电气触点，并不提供 MCU 上报 KeyID；固件逻辑不能直接由线色推定。

Flutter 按键面板按图示左右把手分组：左侧列出 10 个实体控件，其中转向拨杆拆成左/右两个逻辑动作；右侧列出 3 个实体控件，其中档位拨杆拆成加/减动作。只有上、下、SET、BACK 四项启用 CFCP 注入，其他项保留为待映射状态。

AE5I `keymap.data` 与 Launcher `KeyDelegate` 推导出的导航 ID 经 guest 实测：上 `0xd2`、下 `0xd3`、SET/确认方向 `0xd4`、BACK/返回方向 `0xd5`。`rcar-taurus-cfcp.ko` 校验帧后向 `cfcp_key_value_report` 投递：值 1 是按下，值 3 是释放，值 0 被忽略。设备 `event0` 已观察到 `EV_KEY 1 → SYN → EV_KEY 0 → SYN`；四个键在原厂 Launcher 均出现按下/释放日志，截图显示里程、蓝牙及“我的 ZEEHO”页面切换。

可在两终端复现：

```bash
SP_VDISK=dist/qemu-ae5i/ae5i-software.spvd SP_CFCP_PORT=4502 \
  python3 Gemini-Dummy/tools/guest_shell.py 'sleep 60'
python3 Gemini-Dummy/tools/cfcp_key.py up --hold 0.3
```

工具也接受 `down`、`right`、`left`、`fn` 或数值 KeyID。Flutter 面板通过相同 ttyS1 chardev 提供上、下、SET、BACK，按住和释放分别发帧；其他控件保持禁用。`fn` 仅为 Launcher 逻辑动作，尚未认定对应哪一个物理键。Pass、Hazard、Cruise、Custom、Horn、转向、照明、模式和 Ready 等仍需真实 MCU 帧或可靠逆向证据。车辆数据、MCU 握手和所有按键功能仍未闭环。

### 18.3 前端回归

Flutter 默认选择 AE5I 软件显示 SPVD、从该 SPVD 重新提取原厂内核、携带 AE5I 分区与 reserved-memory 启动参数，使用 framebuffer 快照及 CFCP 接口。`flutter test --no-pub test/boot_integration.dart` 已实际启动 QEMU、捕获 800×480 画面，并核验 Launcher 上键按下/释放日志。协议和界面单元测试：`python3 Gemini-Dummy/tests/test_cfcp_key.py`，以及 `flutter test --no-pub test/cfcp_test.dart test/spvd_test.dart test/ui_smoke_test.dart`。

### 18.4 仿真器客户端启动流程（2026-11-01）

客户端现在提供一条可操作的启动路径：

1. “选择固件”打开 SPVD 路径输入框，读取头部、几何、CRC、分区数和截断状态；启动前拒绝无效或不完整镜像。
2. 启动按钮进入“启动动画”阶段，在 800×480 仪表区域显示 ZEEHO 启动画面和进度，再进入“QEMU 启动中”；第一张 framebuffer 快照到达后自动切换为原厂画面。
3. 右侧持续显示 SPVD、内核、QEMU、monitor、串口和串口桥状态；底部按键面板发送已验证的 CFCP 按下/释放帧。

本节为早期客户端说明；当前已由 QEMU 模型重放原厂 `anm_logo/logo.mkv` 转换帧（见 §24），但尚未模拟 bootloader PE 解码器。真实 framebuffer 仍可能只显示局部 Qt Launcher 页面，PFC 背景合成、车辆数据和完整仪表 UI 尚未完成。宿主实体 GPU 加速暂缓；现有 guest 2D 命令由 QEMU 宿主 CPU 模拟。

客户端验证：`HOME=/tmp FLUTTER_SUPPRESS_ANALYTICS=true "$FLUTTER" test`（11 项通过；`FLUTTER` 见 §26）。

### 18.5 启动冲突、车辆事件和下电流程（2026-11-01）

- QEMU 会话不再固定占用 4502、`/tmp/ae5i-mon.sock` 和 `/tmp/ae5i-ui-frame.ppm`。每次上电创建独立临时目录，动态分配 CFCP 端口、monitor socket、kernel 临时文件和 framebuffer 文件；因此旧 QEMU 残留不会再导致 `Address already in use` 后立即黑屏退出。
- macOS 日志使用原生保存面板，导出内容包括状态、错误、固件路径、实际命令行、全部分类日志和重复次数。保存失败会显示错误并提供复制日志回退。
- 客户端增加“模拟刷 NFC 卡”“TBOX 启动车辆”“App 关机”和 Ready 长按入口。NFC/TBOX 事件会进入日志和车辆事件状态，但目前没有伪造未经确认的 MCU/TBOX 认证帧；状态明确显示“待固件协议接入”，不能当作车辆已解锁或 Ready 已确认。
- “停止/下电”先向 guest console 发 `sync; /sbin/poweroff -f`，等待 Linux `reboot: Power down` 后由 monitor `quit` 收尾；25 秒无确认时保留日志并标记“下电未完成”，另有“强制断电”入口。当前这条路径已经在 QEMU 回归中收到 `Power down`，但尚未等价于原车 `PowerManagerModule::shutDown()` 的 MCU OPC 退出通知。
- 原厂 `init.rc` 的 `shutdown.animation.start`/`shutdown.h264` 和 `libpowermanagermodule.so` 的 `shutDown()`、`processVehicleSignal()` 已确认；下一步应逆向其车辆信号触发条件，再实现真实认证/关机协议和关机动画。

## 19. 客户端整车流程状态机（2026-11-01）

§18.5 里“模拟刷 NFC 卡 / TBOX 启动车辆 / App 关机 / Ready 长按”四个孤立按钮已由本节的状态机取代：
上电与解锁不再是同一个动作，关机与拔电也被拆成两步。

### 19.1 真车流程（车主确认）

| 场景 | 真车行为 |
|---|---|
| 上电后刷卡 | 直接解锁 |
| 蓝牙连上 TBOX 后长按 Ready | 解锁 |
| App 点解锁（TBOX 信号） | 解锁 |
| 以上都没有连接，长按 Ready | 仪表原生密码输入界面：上/下选数字、SET 确认、BACK 删改；密码（手机 App 中设置）正确即解锁 |
| 停车 | 先刷卡关机，或长按 Ready 关机；等仪表断电后再拔电源 |
| 未关机直接拔电源 | **异常下电**，可能损伤车辆电力系统 |

### 19.2 状态与迁移

实现：`flutter_app/lib/emu/vehicle.dart`（纯逻辑，不碰进程/UI）。状态：

```
off（断电）→ booting（上电中）→ locked（未解锁）
             → unlocked（已解锁）→ ready（READY）
             → poweringOff（关机中）→ poweredOff（已关机·待拔电）
             → unsafeCut（异常下电）
```

| 当前 | 事件 | 结果 | 副作用 |
|---|---|---|---|
| off | 上电 | booting | 启动 QEMU |
| off | 刷卡 / App 解锁（TBOX 在线） | booting（`pendingUnlock`） | 启动 QEMU |
| booting | 首帧到达 | locked；若 `pendingUnlock` 则 unlocked | 无 |
| locked | 刷卡 | unlocked | 无 |
| locked | 长按 Ready + 蓝牙已连 | unlocked | 无 |
| locked | 长按 Ready + 蓝牙未连 | locked，`promptPassword` | 仪表进入原生密码输入界面（客户端以 HUD 镜像该界面，上/下/SET/BACK 实时转发给仪表） |
| locked | 密码正确 / App 解锁（TBOX 在线） | unlocked | 无 |
| unlocked | 长按 Ready | ready | 无 |
| unlocked / ready | 刷卡 | poweringOff | guest 正常关机 |
| ready | 长按 Ready | poweringOff | guest 正常关机 |
| poweringOff | guest 报 `Power down` | poweredOff | monitor `quit` |
| poweredOff | 拔电 | off | 结束会话 |
| poweredOff | 上电 | 拒绝（需先拔电） | 提示“关机 ≠ 断电” |
| unsafeCut | 上电 | booting | 直接重新上电 |
| 任一通电状态 | 拔电 | 状态不变，`confirmUnsafeCut` | UI 风险确认 |
| 确认异常下电 | forceCut | unsafeCut | 杀进程并记录 |
| booting | 上电失败/进程退出 | off | 记录失败 |
| 通电状态 | 进程异常退出 | unsafeCut | 等效异常断电 |

### 19.3 与 QEMU 生命周期绑定

- **上电** = `QemuController.powerOn()` → `start()`；首帧由 `_grab()` 触发 `bootReady`。
- **正常下电** = `_gracefulShutdown()`：向 guest console 发 `sync; /sbin/poweroff -f`，收到
  `Power down` 后迁到 `poweredOff`，再由 monitor `quit`；25 秒超时提示“可强制拔电”。
- **拔电** = `unplugPower()`；正常下电后只做收尾，仍通电时返回 `confirmUnsafeCut` 交给 UI。
- **异常退出** = QEMU exitCode 回调发现整车仍通电 → `fault` → `unsafeCut`。
- 兼容入口 `requestPowerOff(source)` 仍然保留，语义等同“客户端下电”，走正常关机。

### 19.4 UI

- 顶栏与画面左上角：状态徽标（同一套颜色）；画面底部在未解锁时显示“刷卡 / 长按 Ready 解锁”横幅。
- 面板主流程条：`断电 › 上电 › 未解锁 › 已解锁 › READY › 关机 › 拔电`，当前步高亮。
- 连接开关：`蓝牙→TBOX`、`TBOX 在线`，直接决定长按 Ready 与 App 解锁走哪条路径。
- `Ready 长按` 按钮与底部「启动」键长按等价；无连接时仪表进入原生密码输入界面，**不再用客户端弹窗假解锁**——由 上/下 选数字、SET 确认、BACK 删改，输完与手机 App 设置的密码（仿真默认 `000000`，可改）一致即解锁；上/下/SET/BACK 同时实时转发给仪表。
- 强制拔电前弹风险确认，明确“真车可能损伤电力系统、仿真只记日志”。
- 已关机（`poweredOff`）时「上电」禁用并提示先拔电；异常下电（`unsafeCut`）可直接重新上电。

### 19.5 验证

```bash
# 纯状态机 + UI + 协议单测（41 项）
HOME=/tmp FLUTTER_SUPPRESS_ANALYTICS=true "$FLUTTER" test

# 端到端：真实 QEMU，上电 → 未解锁 → 刷卡 → 已解锁 → READY → 长按关机 → 拔电
HOME=/tmp FLUTTER_SUPPRESS_ANALYTICS=true "$FLUTTER" test test/boot_integration.dart
```

`test/vehicle_test.dart` 覆盖四条解锁路径、正常下电、异常下电红线和完整流程；
`test/boot_integration.dart` 额外验证 QEMU 进程生命周期与 `/proc/fb` 画面。

实测（2026-11-01，59 秒）：端到端一次通过，`dist/qemu-ae5i/client-acceptance.log` 记录

```
[app] 上电：仪表开始启动
[app] 仪表启动完成 → 未解锁，等待刷卡 / Ready / App
[app] 刷卡解锁成功
[app] 长按 Ready → 动力就绪（READY）
[app] 长按 Ready 关机：等待仪表正常下电（下电完成后才能拔电）
[serial] reboot: Power down
[app] 仪表已正常关机（Power down）→ 现在可以拔电
[app] QEMU 退出，code=0
[app] 拔电完成（正常下电流程已走完）
```


### 19.6 边界

- 状态机只驱动客户端与 QEMU 生命周期；**没有伪造任何 MCU/TBOX 认证帧**，也没有改动固件。
- 画面上的“未解锁 / 已解锁 / READY”是客户端 HUD；仪表固件并不知道这层状态，
  不能作为原厂认证已完成的证据。
- 车辆数据、PFC 背景合成、原厂开机/关机动画仍未闭环（见 §18）。

## 20. 启动加速与整屏渲染定位（2026-11-01）

用户诉求：「优化启动速度，同时让整块仪表画面在显示区域正确渲染起来」。两件事分开做，
**只动机型模型与客户端，内核镜像与分区数据一字未改**。

### 20.1 启动慢的唯一根因：als308 的 5 次 10.24 s I2C 超时

原厂内核内建 `als308` 光照传感器驱动，probe 时向 `sp_i2cm0` 发 5 次传输，
每次等 10 s 超时（GIC 上无人回中断），合计 **51.4 s**，占 59 s 启动的 87 %：

```
[ 0.31] ... → [10.75] [I2C] Error: I2C write timeout !!
      → [20.99] → [31.22] → [41.47] → [51.71] als308_init: No als308 detected
[54.5] Launcher 起 → [59] 首帧
```

`initcall_blacklist=als308_init` 不可用：该 initcall 打印为 `calling 0xc06cf711`（无 kallsyms 名），
命令行无法定位 → 改在**模型侧**把这次传输直接判为“失败并完成”。

### 20.2 修法：I2C 控制器按“从机 NACK”立即完成

取证方式（`SP_I2C_TRACE=1` 打印每次访问的 guest PC/LR，再用 capstone 反汇编内核镜像，
镜像基线 `VA = 文件偏移 - 0x40 + 0x408000 + 0xC0000000`）：

- 驱动先写命令字到 `0x4660`、使能中断 `0x4624`，然后**轮询状态字 `0x461c`**；
- 中断服务例程在 `0xc05ee1cc`，读同一状态字并解析 bit 1/4/5/6/8/9/11；
- **bit1 = 传输结束 + 从机 NACK**，驱动收到即报 `No als308 detected` 并继续。

模型实现（`sunplus-sp8368.c`）：一旦驱动写过 `0x4624` bit0，读 `0x461c` 即返回 `0x2`
（`SP_I2C_STATE_NACK`）。这条总线上本来就没有 ALS308，返回 NACK 是**事实描述**，不是伪造成功。

| 变量 | 作用 |
|---|---|
| `SP_I2C_SLOW=1` | 关闭快失败，恢复历史 10 s/次停顿（对比用） |
| `SP_I2C_TRACE=1` | 打印 I2C 窗口每次访问的 `pc`/`lr`，定位驱动轮询点 |
| `SP_I2C_SET="1c=2,3c=1"` | 临时强制某偏移的读回值，用于单次构建内做寄存器假设验证 |

### 20.3 效果（同镜像、同参数）

| 里程碑 | 修前 | 修后 |
|---|---|---|
| `als308_init` | 51.7 s | **0.33 s** |
| `init: do_exec start`（进用户态） | 52.0 s | **1.95 s** |
| `Launcher`（`QT new Launcher start`） | 54.5 s | **2.9–4.1 s** |
| 首帧非黑（`SP_FB_DUMP`, 400 ms 采样） | ~59 s | **5.6 s**（第 14 帧） |

内核侧修后无 >1.3 s 的停顿；剩余时间是原厂用户态自身启动（DirectFB/Qt/主题
`setViewUi` 约 1 s、`libdashclustormodule.so` 重试到 12.2 s 才加载完成）。

### 20.4 为什么只画了左侧信息栏（整屏渲染定位）

画面内容 = 原厂 AE5I 首页「信息组」：单次里程 / 单次电耗 / 平均电耗 / 总里程，
bbox `(15,11)-(251,448)`，占 800×480 的 **3.67 %**；fb0 两页内容一致（双缓冲正常）。
`SP_FB_MULTI=1` 后 fb1（背景层）/fb2 注册成功且全黑，`PlatformControl` 不再报
`Framebuffer of Background not create`，`BackGroundFlipThread` 正常起线程。

原厂 Launcher 日志（`SP_FB_MULTI=1`）给出的结论：

```
[3.65-4.28] DashTheme01 setViewUi start/end，changeTheme = DashTheme01，initViewItem
[4.0-4.4]   updateViewOdo / updateViewTrip1 / updateViewDrivingMode ...
            updateViewEleLevel: 0, 0 → LINE_DISCONNECT
[12.2]      libdashclustormodule.so load success（此前 ModuleManager 每秒报 not exist）
```

- 主题**确实在跑**，并实绘了信息栏——所以不是“渲染管线坏了”；
- `updateViewSpeed` **一次都没被调用**，`updateViewEleLevel` 拿到 `LINE_DISCONNECT`，
  即主题判定**整车数据链路未连接**，主表盘与底部状态栏按设计不出现；
- 车辆数据只走 MCU：`libdashclustormodule` ← `mcucommodule` ← 内核 `rcar_taurus_cfcp`
  （`cfcp_keypad_init` / `cfcp_report_key` 也在这条链上）← UART 上的 GD32。
  模型目前不模拟 GD32，故 `[CFCP] cfcp_ack_q_work_handl ... resend_times is 3` 反复重发。

⇒ **整屏渲染的剩余缺口 = MCU/CFCP 车辆数据，不是显示栈。** 下一步要么在模型里模拟
GD32 的 CFCP 帧（协议可从 `GD32_APP` s19 反汇编得出），要么给 UART 侧注入 SetItem 数据。

### 20.5 客户端默认值（本次同步）

`flutter_app/lib/emu/machine.dart` 的 `LaunchSpec.env()` 新增：

- `SP_FB_MULTI=1`：注册 OSD0/1/2 三层，消除背景层缺失报错；
- `SP_FB_COMPOSITE=1`：按 PFC 层序把窗口 1 合成到 OSD 之下。背景全黑时与单层 dump
  **逐字节等价**（R/G/B 取值顺序一致），不会引入回归。

首帧从 59 s 提前到 ~6 s，客户端“点亮中”提示与副标题同步改成与实际一致的说法。

### 20.6 复现

```bash
python3 tools/build_model.py          # 唯一正确的模型构建入口

# 启动加速 + 首帧（AE5I 验证镜像）
SP_IPC_STUB=1 SP_FB_MULTI=1 SP_FB_COMPOSITE=1 SP_VDISK=images/ae5i.spvd \
SP_VDISK_BASE=0x50000000 SP_FB_DUMP=/tmp/fbd SP_PC_MS=400 \
  qemu-src/build/qemu-system-arm -M sunplus-sp8368 -m 256 \
  -kernel images/kernel-ae5i.bin -append "<见 MachineConst.defaultAppend>" \
  -serial file:/tmp/uart.log -display none -no-reboot

# 对比修前停顿
SP_I2C_SLOW=1 ...（同上）
```


## 21. 真实面板尺寸、顶部/底部状态栏与开机动画（2026-11-01）

用户诉求：「就算没有车辆数据，仪表界面也至少拥有完整的顶部与底部状态栏，包含电量信息、
时间等。首先修仪表画面渲染问题，真实仪表尺寸为 16:9。其次修复仪表开机动画问题。」
仍然**只改模型与客户端**，内核与分区数据未动。

### 21.1 尺寸：1024×600 是设备自己的说法，不是猜的

| 来源 | 值 |
|---|---|
| `runtime_cfg`（分区 `0x9280000`，`##runtime.cfg##`） | `UI_width=1024` / `UI_height=600` / `rev_disp_act_w/h=1024/600` |
| `anm_logo` 内 `logo.mkv` | H.264 **1024×600**，60 fps，112 帧 |
| `libdashclustoractivity.so` | 16 张整屏 PNG，均 1024×600 |

模型早已按 1024×600 报给内核（`SP_UI_W/H_DEFAULT`），但**客户端**还在用写死的
`aspectRatio: 800 / 480` 和「仪表画面 · 800×480」标题 → 画面被横向压扁，底部状态栏
看起来“缺一块”。改为按真实帧的宽高比渲染（`frame.width / frame.height`，无帧时用
1024/600 兜底），`kScreenW/H` 同步成 1024/600。

### 21.2 开机动画：原厂帧 + 模型重放

真机第一屏是 bootloader 交给 PFC「PE」解码硬件放的 `anm_logo/logo.mkv`，**Linux 还没起来**；
用户态只在 Launcher 有画面后调一次 `PlatformControl::Stop_Animation_Logo()`。模型没有 PE，
所以以前从上电到 Qt 界面全黑。

`tools/make_bootanim.py` 把原厂资产解出来给模型重放（没有一帧是我们画的）：

```
anm_logo @NAND 0xA9C0000 → PART 容器
  0x00 "PART" | 0x04 total(0xda90) | 0x08 0x10 | 0x0c 0x20
  0x10 name[24]="logo.mkv" | 0x28 size(0xda5c) | 0x2c offset(0x30)
  0x30 Matroska payload  ← 用 EBML 魔数 1a45dfa3 定位，长度取魔数前 8 字节
```

产物 `dist/qemu-ae5i/anm_logo.bin`（**ANM2**）：头 24 B + 112 × `{off,len}` 索引 +
每帧 `u16 值 | u8 连续数` 的 RLE。**故意不用 zlib**：QEMU 构建没链 `-lz`
（`build/build.ninja` 里 `-lz` 出现 0 次），而 RLE 解起来就是一个小循环。
全片 3.4 MiB（均 31 KiB/帧，最大 81 KiB），工具逐帧 `rle16_decode() == 原始 RGB565` 自校验。

模型侧（`sp_anim_start/sp_anim_tick/sp_anim_stop`）：

- `SP_BOOT_ANIM=<file>` 打开；分辨率与面板不符直接拒绝（缩放=凭空造像素）；
- 60 fps 逐帧解码成 BGRA 写进 fb0（`SP_FB_BASE`，有 page flip 时跟 `fb_scanout_page[0]`）；
- 播完**保持最后一帧**，每 100 ms 采样 512 个像素与自己的帧比对，≥3% 不同 = guest 已经画上去了；
- 交还时把"仍然等于我这一帧"的像素清黑（否则 Qt 没覆盖到的区域会永久留一个 logo），
  并打印 `BOOTANIM: guest took the panel over after N frames, cleared M stale px`；
- `SP_BOOT_ANIM_HOLD_MS`（默认 8000）是"guest 一直没画"的兜底。

取样节奏也跟着改：`SP_PC_MS=500` 的时候客户端只能看到 4 张定格的 logo，所以
`sp_pc_sample()` 在 `anim_running` 期间把发布间隔压到 **60 ms**，并把首次采样从 +500 ms
提前到 +60 ms（否则前 500 ms 的绘制过程全部丢失）。客户端 `_tickGrab()` 同步：开机
窗口内 90 ms 一帧，`displayLit` 之后回到 900 ms。

实测（`SP_FB_DUMP` 每 60 ms 一帧，painted%）：

```
fb_001 0.00% → fb_003 0.67% → fb_005 4.42% → fb_006 8.55%
→ fb_008 11.45% → fb_010 12.73% → fb_014 11.04% → 稳定 11.03%
```

`BOOTANIM: frame 111/112 at 1923 ms`，112/60=1.867 s，节奏正确。

### 21.3 顶部/底部状态栏到底是什么

Launcher 接管后的实测（`dist/qemu-ae5i/preview-fastboot.png`）：

| 区域 | 内容 | 来源 |
|---|---|---|
| 底部状态栏 | 电池图标 + `0%`、`0km`、`12:00` | 原厂主题实绘，**不需要车辆数据** |
| 左侧信息列 | 单次里程/单次电耗/平均电耗 `0Wh/km`/总里程 `0km`、`按「SET」查看详情` | 原厂 InfoModule |
| 顶部条带（y<90） | 只有一枚 **琥珀色 TC-off 指示灯**（686 px，bbox `123,11–160,48`） | 指示灯区，其余灯无信号即隐藏 |
| 中间主表盘 | 空 | 需要 `updateViewSpeed`，即 MCU/CFCP 车辆数据 |

即：**顶部不是“状态栏缺失”，而是指示灯条**——没有车辆信号就只有默认亮着的 TC-off 灯。
底部所需电量/时间本来就有，且渲染正确（底部内容止于 y=588，没有被面板裁掉）。

中间主表盘的链路仍是缺的（`updateViewEleLevel → LINE_DISCONNECT`、`updateViewSpeed`
从未被调用），它属于 §20.4 的 MCU/CFCP 缺口，不是渲染链问题。

### 21.4 顺带发现的线索（未处理）

- 窗口 1（PFC 背景层）**从来没被画过**：`SP_FB_WINDOW=1` 单转储全黑 → 主题整屏底图
  没进任何 framebuffer。这是 §20.4 记的「PFC 背景合成未闭环」。
- `SP_GPU_EXPERIMENTAL_GC320=1` 对此**没有改善**（仍是 4.42% 覆盖）。
- Launcher 每秒报一次 `[ModuleManager] "dashclustor" is not exist!!!`，而
  `libdashclustormodule.so` 确实存在——它在 `/application/lib/module/`，而
  ModuleManager 只加载了 `/application/lib/module/default/`（info/mcucom/ipc 三个）。
  `appinfo.rc` 没有模块清单，userdata/nvm 里也没有插件配置，疑似由工厂写入的属性决定。
  活动本体（`libdashclustoractivity.so`）加载正常，`DashClusterActivity::onCreate` 有打印，
  所以这条错误目前不影响已渲染的部分。

### 21.5 复现

```bash
python3 tools/make_bootanim.py        # 重新生成 dist/qemu-ae5i/anm_logo.bin（2 s）
python3 tools/build_model.py

SP_BOOT_ANIM=$PWD/../dist/qemu-ae5i/anm_logo.bin SP_BOOT_ANIM_TRACE=1 \
SP_FB_DUMP=/tmp/fbd SP_PC_MS=500 SP_FB_MULTI=1 SP_FB_COMPOSITE=1 ...（其余同 §20.6）
```

客户端：`flutter test --no-pub test/boot_integration.dart`（端到端，含动画交接，约 7 s）。

## 22. 上电/下电流程对齐真车：仪表只在解锁后才点亮（2026-11-01）

### 22.1 真车序列（车主确认）

```
上电 ⇒ MCU 启动（此刻串口开始有 MCU 相关日志输出）
     ⇒（等待刷 NFC 卡 / 云盒收到手机解锁信号 / 连接蓝牙后长按 Ready）
     启动车辆 ⇒ 仪表点亮
```

旧版客户端「点击上电车辆直接启动」与实车不符：上电后立刻播开机动画并把 Launcher
整屏点亮，看起来就是「已启动」。实车里 MCU（GD32）是常电大脑，负责认证；仪表（cluster
Linux）在解锁/启动之前保持黑屏待机，解锁瞬间才点亮并播放 logo 开机动画。

### 22.2 模型侧：`SP_WAKE_FILE` 延迟重放开机动画

`hw/arm/sunplus-sp8368.c` 的 `sp_anim_start` 原来在上电即把 `anm_logo.bin` 重放进 fb0。
新增环境变量 `SP_WAKE_FILE=<path>`：

- 不设 → 维持上电即播（兼容无门控场景 / headless）。
- 设置 → 上电**不播**，改由 `sp_pc_sample` 轮询该文件；客户端在「已解锁」时创建它，
  模型随即 `sp_anim_start` 重放 logo，并把帧采样频率拉到 60 ms（见 §21.2）。

`sp_pc_sample` 里轮询 `g_file_test(path, G_FILE_TEST_EXISTS)`，命中即触发一次（armed 标志防重入）。

### 22.3 客户端侧

- **MCU 上电串口日志**：`QemuController._emitMcuBoot()` 上电后按时序把代表性 GD32 启动
  日志流进日志面板（新增 `LogKind.mcu`，青色；串口桥横幅也改为 1024×600）。这是客户端对
  MCU 行为的仿真，与 `SP_IPC_STUB` 同一思路，并非运行真实固件。解锁时追加
  `MCU: key authenticated — release cluster wake`，下电时追加 `MCU: power-down`。
- **仪表点亮门控**：`VehicleState.isAwake`（unlocked/ready）。`_screenPanel` 在
  `booting`/`locked` 时显示 `_clusterStandby`（黑屏占位：「仪表待机 · MCU 启动中 / 等待解锁」），
  只在 `isAwake` 才显示 framebuffer。对应真车「解锁后仪表才点亮」。
- **`displayLit` 重新定义**：`state.isAwake && (非黑像素 || 正在播动画)`，不再依赖动画是否交还。
- **`bootReady` 与动画解耦**：`booting` 期首帧到达（Launcher 出画面）即转 `locked`；
  动画延迟到解锁才播，所以 `booting` 阶段不会有动画抢占该迁移。
- **唤醒触发**：`_dispatch` 在进入 `unlocked` 的沿触发 `_fireWake()`，写 `SP_WAKE_FILE`
  指向的 `<session>/wake`，让模型重放动画。三种解锁（刷卡/App/BT+Ready）以及「off 态刷卡唤醒」
  都经此路径。

### 22.4 验证

- 单测：`flutter test test/vehicle_test.dart`（44 项，含完整真车流程）。
- 端到端：`flutter test --no-pub test/boot_integration.dart` —
  `powerOn → booting(MCU) → locked(待机) → swipe → unlocked(点亮+动画) → ready → 关机 → 拔电`。
  断言延迟动画在解锁瞬间 `animating=true` 再交还 Launcher。

## 23. 按键全链路：11 个仪表 KeyID + MCU 侧车身模型（2026-11-01）

### 23.1 结论

面板 15 个实体控件里，**只有 4 个（上/下/SET/BACK）在真车上经过仪表**。其余 11 个
（超车灯/双闪/定速/自定义/喇叭/左转向/右转向/照明/加档/减档 = 10 个由 GD32 执行，
启动 = 长按 Ready 由 MCU 认证）本来就不进 cluster。所以「按了没反应」不是模拟器
缺陷，是链路不同 —— 修复方向不是往串口塞未验证 KeyID，而是把两条链路分开建模。

### 23.2 三条互相独立的证据

1. **内核只回显不过滤**：`[CFCP]CFCP_KEY:*** KeyID(0x%x),KeyValue(0x%x)` 对任何
   KeyID 都打印并投递 evdev（实测 0xd2 → evdev keycode 210，直通映射）。所以
   「串口能看到回显」≠「仪表会响应」。
2. **设备 `keymap.data` 只登记 11 个**：QMAP v1（magic `QMAP`、version 1、count 602），
   16 字节头 + 602 条 `>HHII`（12 字节）`(key, qtkey, unicode, mods)`。0xc0..0xff
   区间仅 11 条，且 qtkey 全为 `0x0000ffff`（`Qt::Key_unknown`）：
   `0xc8→0x1100230 0xc9→0x1100231 0xcf→0x1100230 0xd1→0x1100225 0xd2→0x1100227
   0xd3→0x110022b 0xd4→0x1100226 0xd5→0x110022e 0xd6→0x1100232 0xd7→0x1100234
   0xdf→0x1100286`。不在表里的 KeyID 到 evdev 后没有 Qt 映射，原厂 Launcher 不会
   产生 `keyPressEvent`。
3. **逐键实测 Launcher 动作名**（0x00..0xff 全扫 + 单键复测）：

| KeyID | 动作 | guest 侧表现 |
|---|---|---|
| `0xd2` | `app_key_up` | 列表上移 |
| `0xd3` | `app_key_down` | 列表下移 |
| `0xd4` | `app_key_right` | `clickEnter: 6` + `changeTheme` |
| `0xd5` | `app_key_left` | 切回 `DashTheme01` |
| `0xd6` | `app_key_ota` | 有命名动作 |
| `0xd7` | `app_key_960` | 有命名动作 |
| `0xc8 0xc9 0xcf 0xd1 0xdf` | 无 | 有 `keyPressEvent`，画面无变化 |
| `0xc0 0xc7 0xce` | 无 | 完全无响应 |

### 23.3 客户端实现（双通道）

- `lib/emu/keys.dart`：按上表重建。`InstrumentKey.code` = 仪表侧 CFCP KeyID（null =
  真车不经过仪表），`InstrumentKey.mcu` = MCU 侧功能；`supported` / `badge` 由此派生。
  `ClusterKeys` 只保留 11 个真 KeyID + 6 条动作名映射，删掉旧的 qemu monitor 键名占位。
- `lib/emu/mcu.dart`：`McuSim` + 不可变 `McuState`，只做车身语义（不碰 QEMU 生命周期）：
  双闪优先并清左右转、左右转互斥、远光/定速独立开关、超车灯瞬时 350 ms、档位 1..3
  夹紧并提示、喇叭无状态、自定义键提示需 SetItem4 功能码 7。下电 `resetOnPowerOff()`。
- `controller.pressInstrumentKey()`：统一入口。有 `code` → 发 CFCP 按下+释放（60 ms），
  并用 `actionName` 回报「仪表 app_key_xxx」；无 `code` → 交给 `McuSim`，每行写
  `LogKind.mcu` 日志。
- UI：按键第三行角标区分 **蓝 `0xFF7FB2FF` = CFCP KeyID** / **橙 `0xFFFFC978` = MCU**，
  「启动」显示「长按 Ready」；顶部新增「模拟 MCU 车身」状态条（左转/右转/双闪/远光/
  定速/档位），并明写"guest 画面不会因此变化"。

### 23.4 边界（不许声称已完成）

- **MCU→SoC 的车辆信号帧未实现**：QEMU 侧没有 GD32 peer 应答属性读，`libmcucommodule.so`
  的分发表（`mcucom_rx_indicator_lamp_handle` @0x3b391，`.rodata` 表项 @0x549c）仍未解出
  命令字与负载布局。所以转向/远光指示灯、车速、电量**不会**因为按键点亮。
- 自定义键切信息组需要 `SetItem4` 功能码 7 的下行通道，未接入。
- `0xd6`/`0xd7` 可用但不对应把手实体键，不给 UI 入口（`ClusterKeys.ota/ota960` 保留）。
- `0xd4` 触发 `changeTheme` 路径下，按上键**偶发** Launcher `SIGSEGV`（`si_addr 0x44`，
  `Launcher+0x16d1a`，深度 2），非稳定复现，未修。

### 23.5 取证方法与模型改动

- **ttyS4 干净二进制通道**：控制台上 goc/AudioService 等守护进程持续打印（`dmesg -n 1`
  压不住，噪声 75 K 字符/3 s），`od` 抓 `keymap.data` 会拼出伪数据。改为 `cat f > /dev/ttyS4`
  走独立 UART。模型侧把 UART 创建条件从「仅 UART0/1」放宽为
  `if (serial_hd(i) || i == 0)`，其余索引可接 `-serial`。
- **ONLCR 陷阱**：UART 默认把 `\n` 扩成 `\r\n`（`libvehiclesignalmodule.so` 应 63992 B，
  实收 64123 B，差值恰等于文件内 `\n` 数量 131）。`stty -F /dev/ttyS4 -opost raw` 无效
  （`Not a tty`），拉完必须 `data.replace(b'\r\n', b'\n')`，并以 `wc -c` 校验字节数。
- **按键帧**（`lib/emu/cfcp.dart` 与 `tools/cfcp_key.py` 一致）：`fe 5a aa a5` +
  `10 00 03 01 01 00` + u16 `8` + u32 `keyId`(LE) + u32 `value`(1 按下 / 3 释放 / 0 忽略)
  + 校验（`body[4..19]` 求和取反）+ `a5 55 5a`，共 24 B。
- **车辆属性帧**（SoC→MCU，ttyS1 抓到 8485 B / 266 帧）：`fe5aaaa5` + `11 02 75` + … +
  `{u32 prop_id, u32 offset, value}` + 校验 + `a5 55 5a`。观测到的 prop_id：
  `0x21709521`（值 0，173 次，疑似心跳轮询）、`0x21707701`（`0xc0`，16 次）、
  `0x21407072`（`0x0c/0x18/0x03/0x16`）、`0x21977002`（8/9/10）、`0x27407404`（`0xffffffff`）、
  `0x21701002`（32 B 字符串 `SW.1.00.56 AE5I`）、`0x21417310`（值 1）。
  这些常量只在 `libmcucommodule.so` 命中（0x26c40 / 0x35ba0 / 0x427e0 / 0x25e70 / 0x37844）。

### 23.6 顺带发现（未处理）

- `0xd4` 的 `changeTheme` 把画面从 `DashTheme01` 切到 `DashTheme04`，framebuffer 非黑像素
  比例 **4.664% → 12.995%**。说明「主表盘空」可能同时与主题选择和车辆数据缺失有关，
  值得作为独立线索追。
- `[ModuleManager] "dashclustor" is not exist!!!` 每秒刷屏是**只读文件系统**导致的必然结果：
  当时只观察到 `/application/lib/module/default/` 的早期扫描，而 `libdashclustormodule.so` 在父目录。后续日志证实模块约 15 秒自行加载成功（§28.5），不能认定模块始终缺失。`ActivityManagerImpl` 能正常加载
  `/application/lib/activity/default/libdashclustoractivity.so`，所以不影响启动。

### 23.7 验证

`flutter test test/mcu_test.dart test/key_table_test.dart test/ui_smoke_test.dart`
（16 项）+ 全量 62 项 + `flutter analyze` 无告警。`key_table_test` 把证据锁进断言：
`ClusterKeys.all` 必须是那 11 个 ID、6 条动作名、5 个 reserved 返回 null、每个面板键
恰好一条通道（启动例外：`code==null && mcu==null`）。

## 24. 开机/关机动画修复与背景空屏归因（2026-11-01）

### 24.1 问题回顾

用户报三件事：①开机动画显示不完全；②关机没动画（直接黑屏）；③仪表渲染有问题、
背景画面无法显示。其中 ①②是模型动画逻辑缺陷。③当时被归因为缺少车辆数据的预期空屏；该判断已被实车参考图及同页探针修正，详见 §28。

### 24.2 根因：旧 `sp_anim_stop` 在延迟唤醒场景把屏留黑

开机动画走 `SP_WAKE_FILE` 延迟到「解锁」才重放（§22）。旧 `sp_anim_stop()` 的逻辑是：
「逐像素比较当前帧与动画帧，只把两者相同的像素清零」。这在上电即播、guest 尚未画任何东西时
没问题（清掉 logo 残留即可）；但在**延迟唤醒**场景，guest 早已画好 Launcher 待机界面，
动画重放时用 logo 覆盖了 Launcher 帧，停动画时又只清「与 logo 相同的像素」——
于是 Launcher 原帧被 logo 盖掉、又没被恢复，整屏落黑（`painted` 跌到 0%）。

### 24.3 修法一：开机动画停播前整页恢复 `anim_snapshot`

`sp_anim_start()` 在开播前对当前 fb 页按每 97 像素采样；只要不是全黑（`px & 0x00ffffff`
非零计数 > 0），就把这一页存进 `s->anim_snapshot`。`sp_anim_stop()` 改为：若 `anim_snapshot`
存在，直接用快照整页写回 fb 再释放（`BOOTANIM: restored pre-anim frame`），不再逐像素清。
全黑场景（上电即播、guest 未画）仍走旧逻辑清 logo 残留。

- 源：`hw/arm/sunplus-sp8368.c` `sp_anim_stop()`（约 1248 行）、`sp_anim_start()` 中段
  （约 1500 行）。
- 重建：`python3 tools/build_model.py`（**必须走本脚本**，见 §10 铁律 1）。

### 24.4 修法二：关机动画倒放 logo（logo out）

新增 `SP_SHUTDOWN_WAKE_FILE` 触发文件 + `sp_shutdown_start()` / `sp_shutdown_tick()`：
客户端在下电前创建该文件，模型把 `SP_BOOT_ANIM`（缺省回退 `SP_SHUTDOWN_ANIM`）**倒序**重放
（`idx = frames-1-next`，每 tick 一帧），播完打印 `SHUTANIM: done, N frames (logo out)` 后
释放 `anim_frame`。随后 guest 自己的 `poweroff -f` 才把面板变黑——给了约 2 秒可见的 logo-out。

客户端接线（`flutter_app/lib/emu/`）：
- `machine.dart` `LaunchSpec.shutdownWakeFile` → `env()` 映射 `SP_SHUTDOWN_WAKE_FILE`；
  仅在 `bootAnim != null` 时附带，路径 `$dir/shutdown-wake`。
- `controller.dart`：`_sendShutdownCommand()` 先写 `_shutdownWakeFile`（`shutdown\n`），
  延时 2.2 s 后 `_reallyPoweroff()` 向 guest console 发 `sync; /sbin/poweroff -f`
  （绕过不响应 busybox 信号的 vendor init）；`_cleanup()` 复位 `_shutdownWakeFile` /
  `_shutdownAnimSent`。

### 24.5 验证数据（当前二进制，mtime 2026-11-01 19:08）

- **开机动画**：`fbtimeline.py` 时间线——t=0–10 s `painted=0.00%`（guest 还在 boot，屏本就黑，
  非 bug）；t=13 s 起 `4.37%`（Launcher 待机界面）；解锁后 logo 帧 `11.03%`；播完回到 `4.37%`
  **不再 0% 黑屏**（旧版末帧 0%）。`BOOTANIM: restored pre-anim frame` 日志确认走新分支。
- **关机动画**：`fbshut.py`——`SP_SHUTDOWN_WAKE_FILE` 触发后 `SHUTANIM: frame 83/112 …
  111/112`，`done, 112 frames (logo out)`；`painted` 峰值 **12.72%**（logo 可见），
  153 帧 >10%；`poweroff -f` 之后才跌回 0%（符合预期）。

### 24.6 背景空屏的早期假设（已撤回）

当时观察到 Launcher 只画左侧信息栏和底部状态栏，因此把主表盘空黑归因为缺少车辆数据。这只是早期假设，不能据此排除渲染、模块加载、数据分发或 PFC 合成问题。实车 P 与 READY 参考图均有中部主画面；2026-11-02 同页探针中 READY 前后仅左侧有 297 px 差异，中/右/底栏为 0 px。当前原因未定，最新排查路径见 §28。

---

## 25. CFCP 属性帧格式与 GD32 对端（2026-11-01；属性方向见 §29）

目标：让「加减档 / 双闪 / 转向 / 远近光」这类**由 GD32 执行**的把手功能真正驱动仪表，
而不只是客户端 UI 上的橙色标记。

### 25.1 CFCP 属性帧格式（逐字节证实；不是车辆上行格式）

从会话记录里恢复出真机抓包的两帧，反推并 1:1 复现：

```
[0..4)   fe 5a aa a5            魔术字
[4..10)  11 02 75 01 01 00      属性帧头（键帧是 10 00 03 01 01 00）
[10..12) len   u16 LE           = inner + 2
[12..14) inner u16 LE           = 4(prop) + 4(sub) + valueLen
[14..18) prop  u32 LE           属性 id
[18..22) sub   u32 LE           子索引（多数 0）
[22..)   value                  int32 LE，或定长 ASCII（尾部补 0）
[chk]    ~sum(bytes[4..chk]) & 0xff
[tail]   a5 55 5a
```

校验和公式与 `cfcp.dart` 的键帧（`~sum(bytes[4..20))`）**完全一致**，两处互证。

真机样本（已作为回归用例，见 `test/cfcp_test.dart`）：

| 用途 | 真机帧（hex） |
|---|---|
| 握手 `prop=0x21417310` 值 1 | `fe5aaaa5 110275 010100 0e00 0c00 10734121 00000000 01000000 75 a5555a` |
| 版本串 `prop=0x21701002` | `fe5aaaa5 110275 010100 2200 2000 02107021 00000000 "SW.1.00.56 AE5I"…(24B) 3c a5555a` |

### 25.2 属性 id 与证据等级

| prop id | 语义 | 证据 |
|---|---|---|
| `0x21417310` | 握手/就绪，恒 1 | **已证实**（抓包反复出现，值恒 1） |
| `0x21701002` | MCU 软件版本串 | **已证实**（抓包含 `"SW.1.00.56 AE5I"`） |
| `0x21709521` | 心跳，值 0，约 1 Hz | **已证实**（抓包 173 次） |
| `0x21407072` | SoC 广播的灯态位图 | 实测多个位图值；仅面板下键导致的 6→38（bit5）已关联，其他位语义未定。旧四种灯态枚举推测已撤回，见 §29 |
| `0x21709702` | SoC 广播的 2 字节状态 | guest 样本 8/9/10；不是客户端 P/READY 注入依据。旧 `0x21977002` 为错配副本中的错误 ID，已废弃 |
| `0x21707701` | 车辆状态字节 | 推断：抓包值 `0xc0` |
| `0x27407404` | 能力/掩码 | 推断：抓包值 `0xffffffff` |

灯态编码尚未逐项在仪表上确认。后续状态注入必须有实车帧或固件调用链证据；不得把候选属性当作档位或默认发送猜测状态。

### 25.3 早期语义落点（错配副本，地址与分发结论已作废）

以下为当时的历史分析，不能用于 AE5I 基线；正确库来源及地址见 §27.1–§27.2。

`VehicleSignalModule` 暴露了完整的语义信号槽：

```
updateGear(float) / reverseGear(bool)     档位
updateCurrentSpeend(int) / updateRPM(int) 车速 / 转速
updateLampStatus(int8)                    灯态位（转向/远近光/双闪）
updateWarningInfo(int8)                   告警
updateTirePressureFront/Back, updateMileage, updateElectricPercent …
```

`updateIntVehiclePropValue`（@`0x1db8c`）按 prop_id **嵌套跳转表**分发：首段覆盖
`0x21407059..0x21407064`（基址字面量 `0xdebf8fa7` → `0x21407059`）；`0x21407072`
落在 `0x1dc68` 分支但只精确匹配 `0x27407404 / 0x21407401 / 0x21407403 / 0x21407148`，
因此它实际走 **bytes/string** 属性路径（与其字节型取值一致）。

### 25.4 实现：客户端 CFCP 对端（属性方向结论见 §29）

`machine.dart` 把 **UART1(ttyS1)** 接到 `-chardev socket,id=cfcp`，客户端本来就是该
socket 的对端（`sendKeyEvent` 往它写键帧）。因此「GD32 仿真」在客户端侧落地，写进去的
是真机格式的 CFCP 帧；收发链路已验证，但尚无证据证明这些帧触发 MCUCOM 车辆信号更新或主表盘绘制：

- `lib/emu/cfcp.dart` 新增 `cfcpPropFrame(propId, sub, intValue/strValue)`（字节级对齐真机）。
- `lib/emu/gd32.dart` 整理 `CfcpProp` 为 guest 广播状态与 MCU 下行命令两类，新增原始灯态观测与镜像状态模型；
  `gd32BootFrames`、`gd32StateFrames`、`gd32HeartbeatFrame`、`describeFrame`。
- `lib/emu/controller.dart` 抽出 `_ensureCfcp/_cfcpSend`；**解锁**时 `_startGd32()`
  发维持 guest 状态镜像的基线（版本/握手/能力/状态/样本值/心跳 + 灯态）并起 **1 Hz 心跳**；MCU 键按下后
  `_emitMcuState()` 发灯态属性；下电 `_stopGd32()`。这些帧不是车辆上行，也不会驱动主表盘。

> §29 的真机库反汇编和双向镜像实验已纠正属性帧方向：这些是 SoC 命令/状态镜像，不是主表盘车辆数据上行。帧格式/校验仍有真机样本支持，但协议收发不等于固件已消费车辆状态。

### 25.5 启动动画「不完整」的真因与修法

`sp_anim_tick` 是**先播完全部 112 帧**，然后才判 `sp_anim_guest_painted`，不会「3 帧就停」
（推翻了此前的猜测）。真因在**客户端采样率**：

- 解锁发生在上电 6 s 之后，`displayLit` 已为 true ⇒ `_fastGrabPhase` 返回 false ⇒
  用 900 ms 慢速；而 logo 是 1024×600@60fps、约 1.87 s 播完，模型每 60 ms 发布一帧
  ⇒ 客户端只抓到 2~3 帧 ⇒ 看起来「没播完」。
- 修法：`_fastGrabPhase` 在 `animating.value` 为真时**强制 90 ms**；并把模型停播日志
  `restored pre-anim` / `stopped at` 也纳入「动画已停」判定（否则停播日志会被误判为再次开播）。

### 25.6 验证与限制（诚实边界）

- `cfcpPropFrame` 已用 Python 复刻与两帧真机样本逐字节比对：握手帧 **MATCH**；版本帧
  与恢复样本一致（该样本在会话恢复时被截掉尾部 `555a`，补齐后相同）。Dart 侧回归用例
  已写入 `test/cfcp_test.dart`。
- **2026-11-02 更新**：SDK 已接入；66 项 Flutter 测试与静态分析已通过，真实 QEMU 探针也已运行。CFCP ACK/属性收发可用，但 P/READY 主画面与车辆数据消费未闭环。后续 §29 恢复 `0x21709702=8` 作为状态镜像基线，不解释为 P 档或客户端模拟档位。

## 26. 清理项目内残缺的 Flutter 软件包（2026-11-01）

### 26.1 清理范围

按「项目内不再留残缺 Flutter 包」的要求，移除以下四项（**全部移入废纸篓，可恢复**，
未做不可逆删除）：

| 路径 | 体积 | 性质 | 说明 |
| --- | --- | --- | --- |
| `Gemini-Dummy/flutter-sdk/` | 3.9 G | 内置 SDK 副本 | flutter 仓库 git 克隆（非发行版 zip），含 302 M `.git` |
| `Gemini-Dummy/flutter_app/.dart_tool/` | 88 M | 构建产物 | `package_config.json` 里 `flutterRoot` 写死旧 SDK 绝对路径 |
| `Gemini-Dummy/flutter_app/build/` | 811 M | 构建产物 | 含旧的 `ae5i_emu.app`（universal arm64+x86_64，约 40 M） |
| `Gemini-Dummy/flutter_app/macos/Flutter/ephemeral/` | 116 K | 生成配置 | `FLUTTER_ROOT` / `FlutterInputs.xcfilelist` 写死旧 SDK 路径 |

恢复位置：`~/.Trash/zeeho-flutter-cleanup-20261101/`（`flutter-sdk`、`flutter_app-build`、
`flutter_app-ephemeral`）。确认无需回退后清空废纸篓即可回收约 4.8 G。

### 26.2 被移除 SDK 的确证信息（可精确复现）

移除前实测记录，避免以后重新踩坑：

```
Flutter 3.47.9 • channel stable
Framework • revision c197ca5199e9ee5661e865596c9c07294dfab51c (2026-10-29)
Engine    • revision 89c39edfdfae2949f6806e4a315c0c08522238b7
            content hash 9e025265bef30b838c0c1b68cad19decf97048f2
Tools     • Dart 3.13.7 • DevTools 2.60.0
host      • macOS arm64 (Apple M1 Pro)
```

复现命令：`git clone https://github.com/flutter/flutter.git -b stable` 后 checkout 上述
framework SHA，再 `flutter precache --macos`。

### 26.3 被移除 SDK 的实际残缺点（诚实说明）

它**并非完全不能用**：`bin/flutter --version` 正常，`bin/dart` 为 3.13.7(macos_arm64)，
`flutter_tools.snapshot`、`flutter_patched_sdk`、`material_fonts` 齐备，
`FlutterMacOS.xcframework` 是 universal（`macos-arm64_x86_64`），所以 arm64 上构建 macOS
包没问题。真正的残缺在：

- 只下载了 `darwin-x64` / `darwin-x64-profile` / `darwin-x64-release` 三套 host artifact，
  **没有 `darwin-arm64`**（flutter 在 arm64 宿主上仍会尝试拉取该目录）。
- `bin/cache/` 里遗留 **17 个 `engine.stamp.tmp.*`** ⇒ precache 被中断过 17 次，
  缓存状态不干净。
- 它是 git 克隆（含 302 M 历史）而非发行版压缩包，3.9 G 全程躺在仓库里。

### 26.4 现用 SDK 位置（使用者指定，2026-11-01）

```bash
export FLUTTER=/Users/ryanfish/fvm/versions/custom_zeeho/bin/flutter
```

- 版本与被清理那套**同源同版**：Flutter 3.47.9 stable，framework
  `c197ca5199e9ee5661e865596c9c07294dfab51c`，engine `89c39edfdfae2949f6806e4a315c0c08522238b7`，
  Dart 3.13.7，host macOS arm64。目录 4.1 G（比仓库内那套多一个 `.pub-preload-cache`，196 项预载包）。
- 缓存干净：`bin/cache/*.tmp.*` 为 **0** 个（被清理那套有 17 个）；host artifact 仍只有
  `darwin-x64` / `-profile` / `-release` 三套——macOS 侧靠 universal
  `FlutterMacOS.xcframework`（`macos-arm64_x86_64`）兜住，arm64 构建无影响。
- **放置约束（重要，别误判）**：SDK 在 home 目录时，**沙箱内**跑 flutter 会在写
  `bin/cache/engine.stamp` 处被拒：

  ```
  [sandbox] 命令被沙箱拦截，以下操作被拒绝：
    - /Users/ryanfish/fvm/versions/custom_zeeho/bin/cache/engine.stamp.tmp.<pid> (file-unlink)
  Brokered host rename source refused by file policy: prompt
  ```

  即 flutter 的「写 tmp → rename 覆盖 stamp」需要 unlink 权限，home 路径拿不到。
  - **陷阱**：`flutter --version` 能跑通，会让人误以为没限制——它不写 stamp；
    `test` / `build` 会写。本机若命令未获沙箱放行，会在启动 2 秒内以
    `engine.stamp.tmp.<pid>` 失败退出。
  - 可行二选一：① 让该 flutter 命令**获得沙箱放行**（本会话里前台命令会被
    escalation-approved，日志末尾打 `⚠️ Sandbox bypassed`）；② 把 SDK 放回工作区内。
  - `HOME=/tmp FLUTTER_SUPPRESS_ANALYTICS=true` 只解决 pub 缓存与 analytics，
    **不解决** SDK 自身 `bin/cache` 的写入。
- 所有文档/脚本统一用 `FLUTTER` 变量指向该 `bin/flutter`
  （`Gemini-Dummy/PROJECT-STRUCTURE.md`、`Gemini-Dummy/flutter_app/README.md`、本文 §8.D/§18.4/§19.5）。

### 26.5 新 SDK 接入实测（2026-11-01）

在 `Gemini-Dummy/flutter_app` 下用上述 SDK 实跑，**是本项目首次真正跑通 Flutter 工具链**
（此前只有静态核验）：

```bash
cd Gemini-Dummy/flutter_app
export FLUTTER=/Users/ryanfish/fvm/versions/custom_zeeho/bin/flutter
export HOME=/tmp FLUTTER_SUPPRESS_ANALYTICS=true
"$FLUTTER" pub get     # Got dependencies!（material_color_utilities 0.13.0、test_api 0.7.12 可升）
"$FLUTTER" test        # 66 项全部通过
"$FLUTTER" analyze     # No issues found!
```

- `pub get` 重新生成 `.dart_tool/package_config.json`，`flutterRoot` 已指向
  `file:///Users/ryanfish/fvm/versions/custom_zeeho`（旧路径是
  `…/Gemini-Dummy/flutter-sdk`，已彻底不引用）。
- `test` 覆盖：`cfcp_test`（含两帧真机样本逐字节回归）、`mcu_test`、`vehicle_test`、
  `spvd_test`、`ppm_test`、`key_table_test`、`ui_smoke_test`，共 66 项。
- `build/macos` 尚未重建，仓库内仍无现成 `.app`。

### 26.6 端到端实测：CFCP 属性帧确实上了 ttyS1（2026-11-01）

`qemu-src/build/qemu-system-arm` 已存在（28 MB，19:08 构建），所以端到端可以跑：

```bash
"$FLUTTER" test --no-pub test/boot_integration.dart     # 21 秒，All tests passed!
```

链路走完：上电 → 未解锁 → 刷卡解锁 → 重放开机动画 → 上键 0xd2 按下/释放（guest 回显
`keypress:1100227`/`keyprelease:1100227`）→ 长按 Ready → 关机 → `reboot: Power down` → 拔电。
日志落在 `dist/qemu-ae5i/client-acceptance.log`（3638 行）。

**新证据（§25 的「客户端对端」不再是纸面推测）**——解锁瞬间客户端确实把属性帧写进 ttyS1：

```
[mcu] MCU: key authenticated — release cluster wake (replay logo)
[mcu] GD32: CFCP 属性上报已启动（基线 + 心跳 1 Hz）
[mcu] GD32 → CFCP prop=0x21701002 sub=0 str="SW.1.00.56 AE5I"
[mcu] GD32 → CFCP prop=0x21417310 sub=0 int=1
[mcu] GD32 → CFCP prop=0x27407404 sub=0 int=-1
[mcu] GD32 → CFCP prop=0x21707701 sub=0 int=192
[mcu] GD32 → CFCP prop=0x21709521 sub=0 int=0
[mcu] GD32 → CFCP prop=0x21407072 sub=0 int=0
[mcu] GD32 → CFCP prop=0x21977002 sub=0 int=8
```

**但 guest 侧没有证据表明这些属性被应用**，且暴露了下个卡点：

```
[serial] [CFCP] cfcp_ack_q_work_handl.L131 resend_times is 3, del list:cmdid:0x75,1,1, 0#### .
```

- `cmdid:0x75` 正是属性帧的命令字，**3 次重传后丢弃** ⇒ CFCP 是带 ACK 的可靠链路，
  客户端只发不 ACK，driver 侧会话没走完。
- guest 日志里**没有** `prop is 0x…` / `cfcp_device_map_ioctl` / 版本串 `SW.1.00.56`
  ⇒ 应用层（`mcucom_rx_CFRide` → `setIntVehiclePropValue` → 主表盘）大概率没被触发。
- 结论：**«灯态/档位点亮仪表» 仍未闭环**，下一步必须补 CFCP ACK/握手响应（按
  `cmdid:0x75,1,1` 的 ack 语义回帧），再对比 `SP_FB_DUMP` 的 `painted%` 是否随
  `0x21407072/0x21977002` 变化。**在此之前不得宣称已完成 GD32 模拟。**

构建 release 包：

```bash
HOME=/tmp FLUTTER_SUPPRESS_ANALYTICS=true "$FLUTTER" build macos --release
```



## 27. 真机 AE5i 库校正 + MCU 属性 id 重定位（2026-11-01 晚）
> 本节能解释 §25/§26 里几处"未确认/错 id"的来由，并给出修正后的权威结论。所有逆向均已改用**真机 AE5i 库**（见 §27.1）。

### 27.1 ★ 真机库来源纠正（此前逆向基准是错的）
- 之前一直拿 `firmware/spapp-root/` 的 `libvehiclesignalmodule.so` 做逆向，但其库 **md5 与真机不符**（错配的宿主副本）。
- 真机 AE5i 库 = `images/ae5i.spvd`（验证镜像）。重建：按坏块 `{383,716,1049,1382,1715}` 跳过 → 重建 spapp 逻辑镜像（spvd 几何 page=4096/ppb=64/blocks=2048，spapp 起始块 262）→ `unsquashfs` 解包 → `/tmp/ae5i_spapp/root/lib/module/default/`。
- 此后所有逆向改用这份真机库。

### 27.2 ★ 集群显示属性不在 `libvehiclesignalmodule.so`
- 真机 `libvehiclesignalmodule.so`：`updateIntVehiclePropValue` @ **0x8174**（旧记 0x1db8c 是错配副本地址，作废）、`connectSlots` @ 0xa0cc。它只分发车辆信号（速度/RPM/电量…），**不含**仪表集群显示属性。
- 集群显示属性（档位/灯态/心跳/版本）在 **`libmcucommodule.so`**（MCU 通信模块）。字节搜索确证：
  - `0x21709702`（候选，语义未定） @off214088、`0x21407072`(灯态) @off272352、`0x21709521`(心跳) @off158784、`0x21701002`(版本) @off227396；`0x21417310`(握手) 在 `libapis.so`。
  - `0x21407072` 同时出现在 `libdashclustoractivity.so`（仪表渲染侧）。
- **旧 `0x21977002` 是错 id**：全模块搜索都搜不到，来自错配宿主副本，**真机 AE5i 中不存在**，已废弃。

### 27.3 ★ `libmcucommodule.so` 的 CFCP 属性 id 不是内联字面量
- 整个 `.text` 扫不到任何 `0x2xxxxxxx`（`ldr [pc]`），静态反汇编看不到属性 id。
- CFCP 属性帧是模块**发出**给集群的；MCU 串口进来的是另一套 **TLV 协议**。`mcucom_rx_ride_info_update` @0x397c4 是 MCU 串口解析器：读 16-bit 大端 tag，标签 `0xCF01..0xCF0B` 各字段落模块结构体偏移 `0x4c`(1B)/`0x4e`/`0x50`/`0x52`/`0x54`/`0x56`(2B)/`0x44`/`0x48`(4B)。
- ⇒ 要驱动集群，需把 MCU 串口 TLV 字段映射到发出的 CFCP 属性（`0x21709702` 等）；速度/电压/RPM 对应哪个 CFCP 属性**仍未全解**。

### 27.4 客户端代码已据此修正（`gd32.dart`）
- 当时把错误 ID 更正为 `0x21709702` 并发送默认值 8；此档位解释于 2026-11-02 撤回，见 §28.4。§29 恢复样本 8 作为 guest 状态镜像基线；按键状态上报不发送该属性，也不据此推导 P/READY。
- `describeFrame`：支持 1/2/4 字节按 int 打印。
- `cfcp_test.dart`：错误 id 用例改为 0x21709702。`flutter analyze` 干净（home SDK + sandbox bypass）。

### 27.5 69 帧属性扫描结论（数据消费未证实）
- `mcu_prop_scan.dart`：基线噪声 **0px**，但 69 条候选属性帧**全部 0 像素变化** → 此实验未建立候选属性与绘制变化的关系，不能据此排除属性、数据分发、页面门控或合成问题。
- ACK 现已闭合（guest 收到 SoC 属性时客户端回 ACK）；这只证明 CFCP 字节链路可收发，不证明 MCU 上报触发了 `libmcucommodule` 的车辆数据更新。

### 27.6 页面勘察校正（2026-11-02 补充：同页像素对照）
- 动画采样竞态已修复：先等待 `animating=true` 再等待 `false`，避免将首帧 logo 误当作 Launcher 静态页。同页 READY 对照左侧差异 297 px（x=124..159,y=16..31），中部、右侧、底栏均 0 px；此差异不能认定为原生 READY 指示。
- `cluster_pages_probe.dart` 原先调用 Ready 时未设置 TBOX/蓝牙条件，实际进入密码输入流程；原 `10-ready.png` 因而**不是 READY 样本**。
- 探针已修正：先设置客户端 BLE/TBOX 在线，再长按 Ready，并断言状态机为 `VehicleState.ready` 后截屏。原厂 guest 仍显示左侧信息/蓝牙提示页，未显示 READY 主表盘。
- 用户提供的实车图 `instruction/IMG_7663.jpeg`（驻车/P）与 `IMG_7664.jpeg`（READY）显示两种状态都有中部主画面；不能再用“当前页不同”解释主表盘缺失，须继续排查车辆信号与 PFC 渲染链。

### 27.7 当前状态与下一步
- ✅ 客户端 GD32 peer 已发送真机格式 CFCP 属性帧；guest→客户端 ACK 与 SoC→MCU peer 属性解析已经接通。
- ⏳ 仪表消费/车辆信号映射与主画面仍未闭环；不得把 READY 状态机、CFCP ACK 或按键日志描述为原厂 READY/P 档已渲染。
- 下一步：从真机 `libmcucommodule.so` `mcucom_rx_ride_info_update` 的 `0xCF01..0xCF0B` TLV 解析继续反解字段，再从实车 CFCP 样本确认驻车/P、Ready、速度与功率相关信号；先做单字段差分并建立 framebuffer 像素证据，再接入 peer 验证 P/READY 两态。

## 28. 实车 P / READY 参考与 MCU 仿真校正（2026-11-02）

### 28.1 参考画面验收项

| 状态 | 实车图 | 需要闭环的原厂元素 |
|---|---|---|
| 驻车 / 未 READY | `instruction/IMG_7663.jpeg` | 顶部 STREET 模式；中部车辆图与大号 P；左侧行程/电耗数据；底部电量、续航、天气与时间 |
| READY 静止 | `instruction/IMG_7664.jpeg` | 顶部绿色 READY；中部 0 km/h；右侧 −10/0/10 刻度与功率条、0.0 W；左侧数据和底部状态栏 |

两图的左侧数据与底栏相同，核心状态差异在中部 P/READY 速度卡片和 READY 功率区。照片是视觉目标，不足以推断 CFCP 属性 ID、枚举值或默认车辆数据。

### 28.2 本轮验证与代码变化

- 修正 `test/cluster_pages_probe.dart`：建立 BLE/TBOX 客户端连接条件后才长按 Ready，并断言状态为 `VehicleState.ready`；真实 AE5I QEMU 探针通过（20 秒）。旧 `10-ready.png` 因缺少 BLE/TBOX 前提不能作为 READY 样本；最新探针以 `10-ready-same-page.png` 与导航前 `00-unlocked.png` 作同页对照。
- P/驻车参考可对应客户端 `unlocked`（未进入 READY），READY 对应 `VehicleState.ready`；客户端状态机不会把未知认证/车辆信号注入原厂固件。
- 实测 READY guest framebuffer 仍是左侧信息/蓝牙提示局部画面；主画面没有实车图中的 READY、0 km/h、功率条。现有 69 个 CFCP 候选帧扫描全为 0 像素差；ACK 完整的会话也没有主画面变化证据。
- Flutter 状态提示已校正：CFCP 对端已接通，但车辆数据到原厂主表盘的映射和 PFC 背景层尚未闭环。仪表区继续显示 guest 原始 framebuffer，不叠加伪造的客户端 P/READY 图层。

### 28.3 当前 MCU 模拟边界与验收

- 已完成：CFCP 字节格式回归、上/下/SET/BACK 按键注入、客户端 GD32 对端基线/心跳/实验灯态帧发送、ACK 与属性收包、整车状态机进入 READY、客户端日志和 QEMU 运行测试。
- 未完成：点亮 AE5I 仪表主画面的真实 MCU UART TLV/IPC 数据源；`0xCF01..0xCF0B` 到渲染属性的完整映射；P 档/READY 与速度、功率值的原厂主表盘差分；PFC 多层最终合成验证。
- READY 探针只验证客户端状态转换及当前原厂 framebuffer，不代表车辆 READY 信号已被固件接受。软件显示 SPVD、宿主 CPU 2D 栅格化仍是当前仿真路径；实体 GPU 卸载保持暂挂。
- 验收需同时满足：READY 截图可见实车对应主画面元素；驻车与 READY 切换由有证据的车辆状态驱动；guest 原生 framebuffer 的绘制/差分区域覆盖中部表盘与右侧功率区；客户端模拟层不覆盖或伪称原厂输出。

### 28.4 三档假设撤回与同页取证

- AE5i 无机械变速箱。`0x21709702` 出现在库中、样本出现 8/9/10，不足以证明它代表 1/2/3 档，也不能解释 P、READY、ECO/STREET。删除 `McuState.gear` 与 `gearValue`，当时默认基线和状态上报不再发送该属性；§29 恢复样本 8 作为 guest 状态镜像基线，未将它解释为 P/READY。加减拨杆保留实体控件入口，仅记录映射待验证，不改变模拟档位。§23、§25、§27.4 的三档/默认 8 为已撤回的历史实现。
- 实车参考还同时改变骑行模式：P 图是 STREET，READY 图是 ECO；不能把全部画面差异都归于 READY。两图都证明原厂应有中部主画面，但照片不能提供控制器在线、P、READY 或模式报文编码。
- `cluster_pages_probe.dart` 先抓未 READY 客户端画面，再建立 BLE/TBOX 条件、断言客户端 READY，同一 Launcher 页面截图后才发送导航键；避免翻页/换主题污染 P/READY 对照。`states.txt` 保存完整 QEMU/串口/客户端日志及左/中/右/底栏 RGB 像素差，截图仍来自 guest framebuffer。
- 先定位原生数据分发到绘制的实际缺口：`mcucom_rx_*` 解析入口 → MCUCOM Qt 信号 → DashClustorModule → activity。`mcucom_rx_ride_info_update` 带 ride-info/cloud 相关参数，其 TLV 不应仅凭名称认定为实时速度/READY 数据；须通过调用方与信号连接交叉验证。再核验 PFC 多层输出；当前不能排除数据门控、模块连接或合成链任一原因。

### 28.5 软件显示复跑与模块加载证据校正

- 2026-11-02 复核发现：早期 `--expose-dashclustor-module` 参数没有传入执行函数，所谓诊断镜像实际只修改了软件显示配置，未增加模块链接。修正参数后又确认 rootfs 中不存在该模块目录，不能直接在那里添加链接；已撤去未验证的选项，避免误导。不能把这次运行称作“补链接实验”。
- `dist/qemu-ae5i/ae5i-dashmodule-probe.spvd` 的名称保留历史用途，其 JSON 清单确认只有 `init.environ.rc` 的软件显示配置变更。日志中 DashClustorModule 自行加载成功，但仍有 `LINE_DISCONNECT`；这证明普通软件显示启动链可加载模块，不能证明 MCU 数据分发成功。
- 探针新增模块初始化闸门：等待 `dashclustor_getMCUComModule_init` 的 `Connect true` 再截图，排除初始 Launcher 帧先于车辆数据消费者建立的竞态。报告头记录实际 `AE5I_SPVD` 路径，避免把其他 profile 误标为 factory。复跑通过（约 27 秒）：同页差分左 297 px（x=124..159,y=16..31），中/右/底 0 px。截图、区域像素差及完整会话日志位于 `dist/qemu-ae5i/pages/`。
- 本轮未修改 QEMU 机器模型；未覆盖原厂镜像、默认 profile，未生成 OTA 包。Flutter 全量 66 项测试通过，`flutter analyze --no-pub` 无问题。

## 29. MCU 仿真方向校正与主表盘阻塞点定位（2026-11-02）

本节是 §23.4/§27/§28 的续：将属性方向和车辆信号路径分别验证。当前已定位接收槽与
IPC 取数入口，但上行封装、Launcher 信号门控及 PFC 合成都仍待验证。

### 29.1 固件侧：60 个真实属性 id 全部归位

在真机 `libmcucommodule.so`（`images/ae5i.spvd` → `unsquashfs` → `/tmp/ae5i_spapp/root/lib/module/default/`）
里按「高 16 位 ∈ {0x2140,0x2170,0x2171,0x2740}」精确扫出 **60 个** 属性 id
（早期 0x20–0x2F 全范围扫是噪声，地址/偏移/颜色都命中同一区间，不可信）。

再用 capstone 按**函数**解码（符号表 `st_value & ~1` 要清 Thumb 位；整段线性扫会
在段首的字面量池上错位，只解出 36 条指令——这是之前一直扫不到的原因），
得到每个 id 的拥有者：

| id | 拥有函数 | 语义 |
|---|---|---|
| `0x21417310` | `mcucom_tx_*` / 握手 | 握手=1 |
| `0x21701002` | `internal_set_SWVersion()` | SW 版本串 `SW.1.00.56 AE5I` |
| `0x21709521` | `mcucom_tx_DownLinkData()` | 心跳=0 |
| `0x27407404` | `mcucom_ble_tire_pressure()` | 能力/胎压掩码=0xffffffff |
| `0x21707701..03` | `mcucom_tx_BtAddr()` 等 | 状态字节 / BT 地址 |
| `0x21407072` | `peridic_task()` | **灯态（位图）**，周期广播 |
| `0x21709702` | `mcucom_set_system_send(unsigned short)` | **档位，2 字节**，8/9/10 |
| `0x21407065..71` | `mcucom_set_trip1_clean/trip2_clean/brighness_adj/spd_unit/tmp_unit/car_theme/resetMaintanceODO` | 下行设置 |
| `0x21409305/08/09` | `mcucom_set_AUTO_HEADLIGHT/ABS/MTC` | 下行设置 |
| `0x21709301..03` / `0x21707073` | `mcucom_tx_setItem1..4` | 下行设置项（自定义键功能码 7 走 setItem4） |
| `0x21709510/11/13` | `mcucom_tx_OtaQRCodeUrl/WifiStatus/BLEAddr` | **字符串属性** |
| `0x27400027` / `0x27410028` | `mcucom_ble_tire_temp()` / 胎压丢失 | 胎况 |

⇒ **这 60 个 id 全部是 SoC 侧的命令/状态**，没有一条是「MCU→SoC 车辆信号」。
上一版 `gd32.dart` 把 `0x21407072`(灯态)、`0x21709702`(档位) 当成「MCU 上报」
是**方向搞反**。

### 29.2 集群渲染侧的信号面（`libdashclustoractivity.so`）

主题类 `DashTheme01`/`DashTheme04`/`BaseTheme` 暴露的槽位（Qt 元对象字符串）：
`updateViewSpeed(int)`、`updateViewGear(int)`、`updateViewEleLevel(int)`、
`updateViewOdo(QString)`、`updateViewTrip1/2(QString)`、
`updateViewAvgEleConsumption(QString)`、`updateViewInsEleConsumption(int)`、
`updateViewDrivingMode(int)`、`updateViewPower/EleVoltage/EleCurrent(QString)`、
`updateViewRpm/MotoRpm(int)`、`updateViewTCLevel(int)`、`updateViewLimitSpeed(int)`、
`updateViewCVTTemp(Level)`、`updateViewStart/EndCharging`、`updateViewStart/EndDisCharging`、
`updateViewDriveTwo/FourDirveMode(Lock/FrontLock/BackLock)`、`updateViewTime` 等。

⇒ 主表盘需要的是 **speed / gear / eleLevel / odo / trip / drivingMode** 等，
这些**不在**上面那 60 个 id 里 —— 它们来自 MCU→SoC 上行。

### 29.3 上行（MCU→SoC）那一环定位到了

`libmcucommodule.so` 的接收侧槽函数：

| 函数 | 地址 | 说明 |
|---|---|---|
| `mcucom_rx_ride_info_update(u8,u8,u8,u8*,u16)` | `0x397c4` (+1448) | **ride info TLV 解析**：载荷是**大端 u16 标签** `0xCF01`/`0xCF02`…，每条记录 **35 B**（2 B 标签 + 33 B 负载）；子类型参数 3/4 决定写入 `this+0x270` / `this+0x2c8` |
| `mcucom_rx_ride_info_status_handle(RIDE_INFO_TYPE,u8)` | `0x283a1` (+792) | 按字段类型分发 |
| `mcucom_rx_indicator_lamp_handle(vector<u8>)` | `0x3b390` (+8532) | **指示灯**（最大的一个） |
| `mcucom_rx_vehicle_info1/2/3_handle(vector<u8>)` | `0x2aba4`/`0x2b800`/`0x2af5c` | 车辆信息 |
| `mcucom_rx_KL15_STATE_handle(int)` | `0x300a4` (+408) | **KL15 = 点火/整车就绪** |
| `mcucom_rx_cruise_shock_level_handle` / `mcucom_rx_trip_1` / `trip_2` / `trip_total_ODO` | `0x2e92c`/`0x2eb25`/`0x2f091`/`0x3dcbc` | 定速/行程 |

它们都是 **Qt 槽**（无直接 `bl` 调用者，由 `IpcModule` 的信号驱动）。
`libnipcmodule.so` 侧对应：`ipc_get_dataFromMCU()` @`0xbe84`、`ipc_try_dataFromMCU()`
@`0xbad8`、`ipc_get_dataFromMCU_cfg()` @`0x9cf4`、`get_ipc_vehData()` @`0xc274`、
`get_ipc_indLight()` @`0xc3ac`；`libdashclustormodule.so` 侧有 `updateSpeed`、
`dashclustor_get_dataFromMCU`、`dashclustor_set_dataToMCU`。

⇒ **当前关键缺口之一**：这些上游载荷的**外层封装**（怎么从 ttyS1 字节流里切出来）。
`0xCF01` 标签在真机库里**不是**字面量（早期笔记里的 0xCF01..0xCF0B 出自错配副本），
标签比较用 `movw r3,#0xcf01` 立即数形式出现在 `0x3994a`/`0x39970` 处。

### 29.4 实测：这条属性通道是**双向镜像**，且**不驱动渲染**

打开 `AE5I_CFCP_TRACE=1` 后抓 guest→客户端方向（新增探针
`test/cfcp_upstream.dart`）：

* guest 会把**我们写进去的值原样广播回来**：发版本串 → 广播
  `prop=0x21701002` 同串；发握手=1 → 广播 `0x21417310=1`；心跳 0 → 每秒广播
  `0x21709521=0`；能力 0xffffffff → 广播 `0x27407404=-1`。
  **去掉这些基线帧，guest 的属性表就是空的、什么都不广播**（已实测，见 §29.6）。
* guest 同时广播**我们从没发过**的值 ⇒ 那是集群自己的状态：
  * **灯态位图** `0x21407072`：实测 6 / 7 / 13 / 18 / 19 / 30 / 38 / −23 / −24 /
    −13 / −28 / −33 / −35（**位图，不是旧笔记的 0x03/0x0c/0x18/0x16**）
  * **档位** `0x21709702`：8 / 10（2 字节小端）
  * `0x21707701` 状态字节：6 字节负载
  * `0x27407404`/`0x27400027`/`0x27410028` 出现在 **sub=1 与 sub=4** 两种变体
    ⇒ **`sub` 是变体选择器**，不是固定 0
* **我们写属性不会改变集群渲染**：11 个候选属性 × sub 0..4 共 **55 组**全扫，
  framebuffer 变化**恒为 0**，guest 也不回播我们的值
  （`test/sub_probe.dart`）。⇒ 下行属性路线**到此排除**，不要再试。

### 29.5 面板键有效、MCU 车身键无效（`test/key_effect.dart`）

逐键按完再对比 guest 自己广播的灯态位图：

* **面板键**（上/下/SET/BACK）**会**改变 guest 的灯态位图（实测「下」使
  `0x21407072` 由 **6 → 38**，Δ=0x20 即 bit5）⇒ 集群状态机是活的、**按键功能通**。
* **MCU 车身键**（转向/双闪/远光/喇叭/定速/超车灯/加减速档）**一个都没改变**
  guest 广播 ⇒ 与真车一致（这些键由 GD32 执行、不经仪表），要让集群指示灯点亮
  必须走上行车辆信号帧（§29.3）。

### 29.6 一次走错方向引发的回归（已修，值得记）

按「这些 id 是 SoC→MCU」的理解把基线帧全删掉后，guest 广播属性集**变成空**，
`clusterState` 什么都没有。说明基线帧是**链路前提**（它们给 guest 的属性表供料），
不是可有可无的装饰。已恢复，并在 `gd32.dart` 里写清「镜像」语义。

### 29.7 页面地图（`test/mcu_render_probe.dart`，截图存 `dist/qemu-ae5i/render/`）

* 面板键导航可达：待机统计页（painted≈26142 px）/ 扫码连接页 / Wi-Fi 设置页
  （右上角有 "P" 与 "ECO"）/ 「发现新版本」弹窗页。
* **所有可达页面都没有中央主表盘**；右半屏基本全黑。
* 灌 58 个真实属性帧会**大幅重绘**（→ 97368 px）但落到「无网络 / 新版本」弹窗页，
  不是主表盘——原因是把 int 值塞进了字符串型属性（如 `0x21709510` 是 OTA 二维码
  URL 字符串），guest 解析出垃圾。**这个"大重绘"是假象，别当成主表盘出来了。**
* 第一次跑该探针时崩在 `panel-确认 / ►.png`（SET 键 `sub` 含 `/` 与空格，
  非法文件名）——已加 `san()` 消毒。

### 29.8 本轮改动清单

* `lib/emu/gd32.dart`
  * 头部注释重写：方向/镜像语义、60 个 id 归属、上行待解的那一环、灯态位图更正。
  * `CfcpProp` 重新归类：新增 `lampMask`/`gear`/`swVersion`/`tireTemp`/`tireLost`/
    `otaQrUrl` 等**集群广播**属性；新增 `kGuestPublishedProps` 集合。
  * `CfcpPropLegacy` 保留旧名别名（旧 `lampStatus`/`gear`）以免外部引用断裂。
  * `lampStatusValue()`（臆造的 0x03/0x0c/0x18/0x16）删除，换成
    `lampMaskFromState()`：**未确认的位一律置 0**（宁可少点亮，也不点亮错的灯）。
  * 新增 `ClusterPeerState`：guest 广播状态的快照（含 `mcuLinkUp`/`lampBit5`）。
  * `describeFrame()` 的「过短」阈值 30 → **26**（2 字节负载的帧是 28 B，原来被
    误判成过短）。
* `lib/emu/controller.dart`
  * 新增 `clusterState`（`ValueNotifier<ClusterPeerState>`），入站属性帧实时并入。
  * `_handleCfcpFrame()` 日志保持 `prop=0x.. sub=.. value=..` **机读格式**
    （探针依赖）＋追加人类可读说明。
  * `_startGd32()` / `_emitMcuState()` 注释与日志改成实测语义。
* `lib/main.dart`：MCU 状态条右侧改为显示 **SoC 广播回来的真实仪表状态**
  （灯态/档位/状态），不再显示臆造的「模式待验证」占位。
* `test/ui_smoke_test.dart`：断言随之更新（`SoC 灯态/档位/状态`）。
* 新增探针（均不进默认套件，文件名不匹配 `*_test.dart`）：
  `test/mcu_render_probe.dart`、`test/cfcp_upstream.dart`、`test/key_effect.dart`、
  `test/lamp_bits.dart`、`test/sub_probe.dart`。

### 29.9 当时的下一步（上行数据路径；已由 §36 更新）

> 后续校正：§36 解出外层 vhal 元素与 CF01 记录；§38 的探针只见缓存，主表盘研究转向 vehicle_info1/2/3 bytes 属性。下文保留当时研究记录。

解出 **MCU→SoC 上行帧的外层封装**：从 ttyS1 字节流里切出
`mcucom_rx_ride_info_update` 期望的 **35 B 记录**（大端 u16 标签 `0xCF01…`+
33 B 负载），以及 `mcucom_rx_indicator_lamp_handle` 期望的指示灯载荷，
按 `RIDE_INFO_TYPE` 填 speed/gear/KL15 等字段 ⇒ 主表盘才可能点亮。
建议入口：`libnipcmodule.so` 的 `ipc_try_dataFromMCU()`（`0xbad8`，日志里有
`try0..try3`）与 `ipc_get_dataFromMCU()`（`0xbe84`），从它们的载荷偏移反推。

### 29.10 文档与客户端验收版（2026-11-02）

- 总览、状态页、Flutter README 和长期记忆已同步本节结论：CFCP 属性是 guest 状态/命令镜像；车辆数据显示依赖 MCU→SoC 上行 IPC；P/READY、PFC 合成与上行封装未闭环；宿主实体 GPU 加速暂挂。
- 修正 `gd32.dart` 中将 `0x21709702=8` 描述为 P 档/三档映射的旧注释。样本 8 留作维持 guest 属性广播的基线，不代表车辆 P/READY 状态。
- Flutter 全量测试 **69 项通过**，`flutter analyze --no-pub` 无问题。
- macOS Release 构建通过：`Gemini-Dummy/flutter_app/build/macos/Build/Products/Release/ae5i_emu.app`，约 41 MiB；Universal 二进制包含 arm64 与 x86_64，`codesign --verify --deep --strict` 通过。应用运行依赖本机工作区中的自建 QEMU、SPVD 与动画资源。
- 无需重建 QEMU 机器模型。本次未修改 `firmware/`、factory dump 或默认 SPVD，未生成 OTA/flashable 包。

## 30. 动画不播的渲染侧真因 + CFCP 帧格式彻底解出（2026-11-02 下午）

### 30.1 归因更正（owner 2026-11-02 明确）

| 现象 | 是否与电机控制器通信有关 |
|---|---|
| 动画/画面渲染不正常 | **无关** —— 属渲染/帧发布链路 |
| 近光灯 / 远光灯 | **无关** |
| 除 上/下/BACK/SET 外的手把键功能、天气、ABS 检测、胎压监测、TCS 检测、电池电量 | **有关** |

上一版把「动画不播」也归到 MCU 链路上是错的，本条撤回。

### 30.2 动画不播的真因：帧发布被钉在 ~1 fps

两处叠加，都在**采样/发布**侧，与车辆数据无关：

1. **客户端**：`_fastGrabPhase` 只在启动后 20 s 内为真，之后**永久降速到 900 ms**
   （≈1.1 fps）。运行期的页切换、指示灯闪烁、表盘扫针于是只剩一两张静帧。
2. **模型**：`SP_FB_PUBLISH_MS` 缺失，`sp_fb_dump` 的发布节拍固定 **250 ms**
   （4 fps），且**没有「内容未变就跳过」**，所以不能简单把节拍调快。

修法：
- 客户机侧 `controller.dart`：改为**按画面是否在变自适应** —— 变化时 40 ms
  （≈25 fps，与模型对齐），连续 8 帧逐像素一致才降到 300 ms。删掉「20 s 后永久
  降速」的硬编码。
- 模型侧 `sunplus-sp8368.c`：
  * 新增 `SP_FB_PUBLISH_MS = 16`，常态发布节拍由 250 ms 提到 16 ms；
  * `sp_fb_dump` 增加**跨步签名去重**（FNV-1a，约 512 个采样点）——内容与上次
    相同就跳过写盘，静止画面几乎零成本；`SP_FB_FORCE_REDRAW=1` 可强制每拍都写。

实测（`test/frame_rate.dart`，真实 QEMU）：静止 3.0 fps（客户端有意降速）、
按键转场 3~10 fps（多次测量波动大）。**1 fps → 数 fps 的质变已达成**；剩余上限
是**客户机在 TCG 下自身的出帧能力**（发布定时器走 QEMU 虚拟时钟，客户机约 30%
速度，16 虚拟 ms ≈ 50 ms 实际），不是轮询 bug。

> 试过「静止后退避到 120 ms」反而更差（4.8 fps）：慢采样会**错过**短暂转场，
> 形成「越慢越检测不到变化」的正反馈。已撤回，保持定速 16 ms + 去重。

### 30.3 CFCP 帧格式：从内核模块字段表彻底解出

来源 `firmware/spsdk-root/drivers/rcar-taurus-cfcp.ko`（与 guest 内驱动同源，
未 strip）。字段描述符表在 `.data` 偏移 **0x130**，8 条 × 20 B，`+0xc` 是长度、
`+0x10` 是帧内偏移；`+0xa0` 是 header 字节、`+0xa4` 是 tail 字节：

| 字段 | 偏移 | 长度 | 实测 |
|---|---|---|---|
| Header | 0x00 | 4 | `fe 5a aa a5` |
| FRAME0 | 0x04 | 1 | `0x11`；**bit7=is_response**，bit6..4=type(1..4)，bit3..1 必须 0 |
| FRAME1 | 0x05 | 1 | `0x02`（属性）/ `0x08`（ACK） |
| 命令字 | 0x06 | 4 | `75 01 01 00`（属性）/ `55 01 01 00`（ACK） |
| 数据长度 | 0x0a | 2 | u16 LE = DATA 字节数 |
| DATA | 0x0c | n | 载荷 |
| CHECKSUM | 0x0c+n | 1 | `~sum(自 FRAME0 起至 DATA 末) & 0xff` |
| TAIL | +1 | 3 | `a5 55 5a` |

驱动侧常量（反汇编，均已落到 `lib/emu/cfcp.dart` 注释）：
- `get_Direction` / `get_field_is_response`：`b>>7`；`get_field_type`：`(b>>4)&7`；
  `get_field_ACK`：`b&0xf`。
- `check_FRAME0`：(b>>4)&7 ∈ 1..4 且 `b&0x0e == 0`；`check_CMD`：(b>>4)&6 == 0；
  `check_LEN`：签 16 位读、须 < 0x200。
- `dispatch_one_frame`：`is_response=1` → `cfcp_queue_ack_clean`（这是**我们发的
  ACK 被识别**的原因）；`=0` → 需要 ACK 就回 ACK，再 `cfcp_dispatch_q_frame`
  投递用户态。
- `prepare_data_for_transceive`：属性载荷按
  `[0]=0x11 | BE32 | len+0xa | len+8 | prop | arg2 | data` 组装（长度 = dataLen+0x11）。

> 注：早期笔记里的「14 字节 inner = prop+sub+value」只是**我们当前实现**的写法，
> 驱动真正期望的是上面 `prepare_data_for_transceive` 的 17+ 字节结构。两者都能
> 通过帧级校验（帧级只看 header/frame0/len/checksum/tail），差别在**载荷解析**。

### 30.4 上行载荷：内核直接指出缺什么

把 35 B TLV 当上行载荷发进去，guest 内核自己打印：

```
[CFCP] cfcp_parse_prop_data.L279 exist illegel vhal frame array,
       vhal_frame_len : 35 index = 0 vhal_len : 465.
```

⇒ DATA 必须是 **vhal frame array**（每元素带 `vhal_frame_len / pid / aid`），
不是裸 TLV。帧级封装已被接受（有 ACK），**只差 vhal 元素的字段布局**。

扫 `(FRAME0, FRAME1, 命令字)` 矩阵（`test/uplink_sweep.dart`，4×4×7=112 组）：
全部组合都能被驱动接受并回 ACK（因为帧级校验通过），但**只有载荷合法的组合才会
进用户态槽**——目前无一命中，印证瓶颈在载荷而不是封装。

### 30.5 本轮改动

* `qemu-src/hw/arm/sunplus-sp8368.c`：`SP_FB_PUBLISH_MS=16`、
  `sp_fb_signature()` + `SP_FB_FRAME` 去重、`SP_FB_FORCE_REDRAW` 逃生阀。
  已按铁律用 `tools/build_model.py` 重建（build ok）。
* `lib/emu/controller.dart`：采样自适应（`_fastGrab=40ms` / `_slowGrab=300ms` /
  `_stillLimit=8` + 跨步签名）；新增 `sendRawFrame()` 供协议探针。
* `lib/emu/cfcp.dart`：写入验证后的字段布局；新增 `cfcpBuildFrame()` /
  `cfcpParseFrame()` / `CfcpFrame`。
* 新增探针 `test/uplink_sweep.dart`、`test/frame_rate.dart`。
* 验证：`flutter analyze` 无问题；全量 **69 项 PASS**。

### 30.6 下一步

1. **动画**（与 MCU 无关）：已解决「钉在 1 fps」；若仍不够流畅，需客户机侧提帧率
   （TCG 性能/GPU 卸载），属另一个方向。
2. **近/远光**（与 MCU 无关）：需找独立输入路径（非上行帧），尚未定位。
3. **ABS/TCS/胎压/电量/天气 + 其余手把键**（与 MCU 有关）：解 `vhal frame` 元素
   布局（`vhal_frame_len/pid/aid`），再做帧级拼装。

## 31. 实车 P 档参考图对照：背景层与整车模型缺失（2026-11-02）

### 31.1 参考图（owner 提供，真车、电机控制器/铅酸电量计/TBOX 均正常）

* `instruction/IMG_7663.jpeg` — **P 档**：左列信息（单次里程/单次电耗/平均电耗/总里程）＋
  顶部 ABS 徽标、"STREET" 模式、RADAR 徽标、右上角圆形图标；**右侧一面绿色背景墙，
  墙上有巨大的 "P"**，中央是**整车 3D 模型**；底栏 `按「SET」查看详情` / 91% / 100km /
  25℃ / 0:10。
* `instruction/IMG_7664.jpeg` — **READY**：中央青色卡片 ECO + 大 `0 km/h`，右侧蓝色
  速度刻度（10/0/−10）与绿色功率条 `0.0w`，顶部绿色 `READY`。**没有背景墙与整车模型**。

owner 补充：**档位与渲染无关**，P/READY 是拍摄时手动切换的；**P 档时无论电机控制器
是否正常，都应渲染出背景与车辆模型**。

### 31.2 我们目前的状态（逐项对照）

| 参考图元素 | 仿真器 | 层 |
|---|---|---|
| 左列信息（单次里程/电耗/平均电耗/总里程） | ✅ 有 | OSD（窗口 0） |
| 底栏 `按「SET」查看详情` / 电量% / km / 温度 / 时间 | ✅ 有 | OSD |
| 顶部条带（指示灯区） | ✅ 有（TC-off 等） | OSD |
| **右侧绿色背景墙 + 巨大 "P"** | ❌ 全黑 | **背景层（窗口 1）** |
| **中央整车 3D 模型** | ❌ 缺 | 背景层 / 3D |
| "STREET" 模式徽标、RADAR 徽标 | ❌ 缺 | OSD（需主题/状态位） |

⇒ 差别集中在**背景层**：OSD 层画得好好的，背景层是空的。

### 31.3 已排除的项

* `SP_FB_MULTI=1`（注册 3 个显示层）与 `SP_FB_COMPOSITE=1`（把窗口 1 合成到 OSD 之下）
  客户端都已开启，合成代码本身正确（背景全黑时逐字节等价于单层 dump）。
* guest 日志里**没有** `Framebuffer of Background not create`（该串含 "Framebuffer"，
  已被探针的过滤词覆盖）⇒ 背景 framebuffer **是创建成功的**，只是**没有内容**。
* 模型内置的 fb 注册表转储（`SP_FB_REG=1`）在 AE5i 上读出全 0；但这组 VA
  （`c0800bdc` / `c0849684`）是从 **150aura** 内核取证来的，对 AE5i 不可作结论。

### 31.4 结论与下一步

**结论**：背景墙与整车模型从来没被 guest 画出来（不是我们合成错了）。模型自身的
注释也指出「仪表显示路径是 **PFC/VPP**，不是 GPU」，所以这不是 Galcore 的问题，
而是 PFC 的**背景层绘制/位块搬运**没有发生。

**下一步（按代价从低到高）**：
1. 让模型**同时导出窗口 1/2**（新增 `SP_FB_BG_DUMP`，在同一个采样点分别写
   `frame.bg1.ppm` / `frame.bg2.ppm`）。现在把 `SP_FB_WINDOW=1` 会让客户端永远
   看不到点亮（窗口 1 全黑 → `painted` 恒 0 → 卡在 booting），所以必须并行导出。
   有了它就能直接判定「背景层是空」还是「背景层有图但我们读错地址」。
2. 若窗口 1 为空：追 PFC 的背景层初始化与 `ioctl`（guest 侧 PFC 驱动），确认它在
   等哪个资源/什么条件下才画背景（很可能与主题 `DashTheme01/04` 或
   `PlatformControl` 的 ResourceManager 相关）。
3. 3D 整车模型另算：它是 GLES 渲染，本模型只有寄存器级 GPU 桩，短时间不可能出图；
   但**背景墙（2D）先出来**就已经能让 P 档画面接近实车。

### 31.5 本轮附带修复

* `machine.dart` 去掉 `SP_PC_MS=500` —— 它会**覆盖**模型侧 `SP_FB_PUBLISH_MS`，
  把整帧发布钉在 2 fps（这是上一轮帧率提升有限的原因）。
* 新增诊断透传 `AE5I_EXTRA_ENV="K1=V1;K2=V2"`，探针可临时给模型加环境变量。
* `test/bg_probe.dart` 文件名撞名修复（SET/BACK 的 `sub` 消毒后都是 `_______`，
  后用 `label + 序号 + KeyID` 命名）。

## 32. 背景层定性闭合 + 动画帧率瓶颈定位（2026-11-02 傍晚）

§31 把「右半屏空白」定位到背景层，并把整车模型记为「GLES 3D，短期不可能」。
**本节推翻后半句**：背景不是实时 3D 渲染，而是一张**内嵌静态位图**，由 **PFC 硬件
图层**从 NAND 侧装入——两者都跟 GPU 无关。

### 32.1 证据链（按发现顺序）

1. **窗口 1/2 从未被使用。** 给模型加 `SP_FB_BG_DUMP`，在同一次采样里并行导出
   窗口 0/1/2（不能只设 `SP_FB_WINDOW=1`，那会让客户端 `painted` 恒 0 卡在
   booting——§31 踩过）。结果：
   ```
   FBWIN: cmdline res_fb0..2 = 0c000000/800000  0c800000/400000  0cc00000/400000
   FBDUMP layer1: 0c800000 1024x600 painted=0.000000 alpha=0.000000
   FBDUMP layer2: 0cc00000 1024x600 painted=0.000000 alpha=0.000000
   FB scanout window=0 page=0/1 (IPC cmd 6)   ← 只有窗口 0 翻页
   ```
   占用图 16×8 全空。⇒ **不是「读错地址」，是 guest 根本没往这两层画。**

2. **guest 认为背景是存在的。** 串口日志：
   ```
   PlatformControlImpl: [get_bg_info 1519] Background W/H: 1024/600
   ```
   且本轮**没有** `Framebuffer of Background not create`。IPC cmd 3/2 的 372 字节
   记录里 width=0x400(1024)、height=0x258(600)，分辨率协商正确。

3. **`/proc/iomem` 里没有任何显示控制器**，只有 `9c110000-9c1107ff galcore
   register region`。也就是说 PFC 不是通过一个我们漏建的 MMIO 设备工作的。

4. **机制在固件库里写着。** `firmware/spsdk-root/lib/libsppfc.so` 导出：
   ```
   SPPlatformControlImpl::Draw_Background_From_Nand(uint, BgUpdateMode_e)
   SPPlatformControlImpl::Set_Background_Transparency(bool, BgUpdateMode_e)
   ```
   `bin/pfc_server` 是独立的 userspace 守护进程（`/usr/local/bin/pfc_server`，
   走 Android binder，`libpfc_service.so` / `libsppfc.so`）。
   ⇒ **背景是 PFC 硬件图层，由 PlatformControl 直接装入/控制透明度**，
   与 Linux framebuffer 完全无关；我们的模型没有 PFC，所以它永远画不出来。

5. **背景确实是一张静态位图。** 主题库 `libdashclustoractivity.so` 内嵌 677 个
   PNG，其中 21 张是 1024×600 全屏资源。抽出来看：
   * `631_18066a3.png` / `590_1317f42.png` — **首页背景**：侧视整车 + 茶青背景墙，
     左侧留白正好给信息列；
   * `18_153458.png` / `66_248e40.png` — 充电场景（整车 + ZEEHO 充电桩 + 光带）；
   * `204_abadac.png` / `89_2cd238.png` / `205_ae755f.png` — 地台/光带渐变遮罩；
   * `525_e50014` / `660_1905219` / `663_194deb5` — 同图的暗化版本；
   * `16_14f810.png` — 「密码解锁启动中…」。

   ⇒ 参考图右侧那面墙 + 整车 = **2D 位图**，不是 GLES 现场渲染。**这去掉了
   「需要完整 GLES 实现」这个不可逾越的门槛**，剩下的只是「谁来把这张图
   送到屏幕上」。

### 32.2 顺带查清的两件事

* **GPU 2D 引擎是在跑的**：打开 `SP_GPU_EXPERIMENTAL_GC320=1` + `SP_GPU_2D_TRACE`
  后，状态写入 35481 条、`GPU FE unsupported` 为 **0**，说明 DRAW_2D 全部被接受
  并执行。作业的目标地址是 `0x0c000000`（fb0）、`0x0aef9300`、`0x04c00000`。
  但 fb0 的 `painted` 只从 4.37% 变成 4.42% ⇒ **2D 引擎没有画背景**，它只做
  清屏和 OSD 合成。把 `0x04c00000` 按 1024×600 渲染出来是**抖动噪声**
  （GPU tile 数据），不是画面。
* **`res_fbN` 三方地址曾经不一致**：`tools/fb_diag.py` 写的是
  `0x0C800000`/4 MiB，`tools/guest_shell.py` 写的是 `0x0C600000`/6 MiB，而模型
  自己按 `SP_FB_STEP=0x600000` 推算。同一块「窗口 1」在不同工具里指向不同物理
  地址，任一方取证都会得出错误结论。**已修**：模型启动时解析
  `machine->kernel_cmdline` 里的 `res_fb0..2`，三方共用一张表
  （`sp_fb_win_addr[]` / `sp_fb_win_size[]`），并在 stderr 打印一行
  `FBWIN: cmdline res_fb0..2 = ...` 供核对。IPC 应答的 buffer 数也改成按声明的
  窗口大小推导（原来一律给 2，4 MiB 的窗口放不下 2×2.36 MiB，会越界压到下一个）。

### 32.3 动画帧率的真正瓶颈：轮询间隔，不是解码

§30 把发布节拍从 250 ms 提到 16 ms 后，实测动画仍只有 15 fps。此前的猜测是
「客户端每帧要 2×61 万次 Dart 循环展开 PPM」。**这个猜测是错的**：做了零拷贝的
原始 BGRA 通道（模型直出 + `.meta`，客户端 `decodeImageFromPixels(bgra8888)`）
之后，两种通道的帧间隔模式**完全一致**（40/80 ms 交替）。

真正的变量是客户端轮询间隔。`test/anim_quality.dart`（真实 QEMU，开机 logo
动画窗口 6 s）：

| 客户端轮询 | 模型发布 | 到达帧率 | 帧间隔 p50 / p95 / max |
|---|---|---|---|
| 40 ms | 16 ms | 15.5 fps | 77 / 83 / 139 ms |
| 20 ms | 8 ms | 32.5 fps | 34 / 42 / 65 ms |
| **12 ms** | **8 ms** | **55.7 fps** | **17 / 25 / 28 ms** |

原厂 logo 是 1024x600@60fps，`p50=17 ms` 已经等于它的原生帧周期 ⇒ 动画在
仿真器里**恢复成接近原速播放**（此前 6 s 才走完 1.9 s 的动画）。

### 32.4 本轮改动

* `qemu-src/hw/arm/sunplus-sp8368.c`
  * `SP_FB_BG_DUMP`：同拍并行导出窗口 1/2，打印 painted/alpha + 16×8 占用图
    （只在历史峰值刷新时打印，避免刷屏）。节流用 `SP_FB_BG_EVERY`（默认 15 拍）。
  * `SP_FB_RAW`：原始 BGRA + `.meta`（seq/w/h/painted/addr）。**保留为离线取证
    工具，客户端不使用**，代码里写明了「无性能收益」和「动画窗口内会提前断流」
    两个已知结论，避免后人重走。
  * `sp_parse_res_fb()`：启动时解析 cmdline 的 `res_fbN`，与 IPC 应答、帧导出
    共用同一组地址；IPC 的 buffer 数按窗口大小推导。
  * `SP_FB_PUBLISH_MS` 16 → **8**。
* `flutter_app/lib/emu/controller.dart`：`_fastGrab` 40 → **12 ms**（注释里附
  上面那张实测表，避免又被当成「随便调小」）。
* `flutter_app/lib/emu/machine.dart`：保留 PPM 通道，注释记录「原始通道无收益」。
* 新增探针 `test/anim_quality.dart`：动画窗口的到达帧率 + 帧间隔分位数 + 逐帧
  时间线（判定空档出现在动画之前还是之后）。

### 32.5 验证

* `flutter analyze` → No issues found；`flutter test` 全量 **69 项 PASS**。
* 模型按铁律用 `tools/build_model.py` 重建（含 `SP_FB_RAW`/`SP_FB_BG_DUMP`
  字符串存在性校验）。
* 未改 factory dump / 默认 SPVD / 内核源码，未生成 OTA 包。

### 32.6 下一步（背景层，唯一剩下的视觉缺口）

方向已经明确：**不需要 GLES，只需要让那张 1024×600 位图出现在 PFC 背景层上**。

1. 解 `pfc_server` 的服务端实现（`libpfc_service.so` 的 Bn 侧 + `libspdovcfg.so`），
   找到 `draw_background_from_nand` 真正写的是哪块内存/哪组寄存器，以及
   `BgUpdateMode_e` 的取值语义。
2. 若确认它写的是某块 PFC 私有缓冲：在模型里建最小 PFC 图层模型（背景层地址 +
   透明度），把真实缓冲区按层序合成到窗口 0 导出——与 `SP_FB_COMPOSITE` 现在
   对窗口 1 做的完全同类，不是伪造像素。
3. 若确认它依赖 NAND 侧的 logo 分区：本机 `pat_logo` 是空的（70.7% 0xFF +
   29.3% 零），说明这条路径在本机上不装数据，需要再看 `isp_logo`/`anm_logo`。
4. **在此之前不要"贴图"**：直接把主题里的 `631_18066a3.png` 贴到画面上属于
   伪造合成（选哪张、透明度、层序都是猜的），违反「不伪造像素」的项目约束。

## 33. 背景层硬阻塞定位：VPP/PFC 硬件图层，无客端可读帧缓冲（2026-11-03）

### 33.1 已验证：IPC 路由修复生效（§32.6 路线 1 的前半段完成）

* 用 `tools/build_model.py` 重建后，起真实 guest（`run_ae5i.sh`：`-M sunplus-sp8368 -m 256`、
  `SP_IPC_STUB=1 SP_FB_MULTI=1 SP_FB_COMPOSITE=1 SP_PFC_TRACE=1 SP_FB_BG_DUMP=...`）。
* 日志确认 `IPC stub: id=23`（=`0x17`，`libspdovcfg` 的 `dov_send_cmd` → PFC 背景配置）
  **真的被下发到了用户态 pfc_server**（全日志出现 3 次 `id=23 len=14`，payload 首字为
  guest VA `b53fccf8` / `b49fecf8`）。这正是 §32.6 猜测的根因：旧 `sp_ipc_stub` 把所有请求
  都按内核格式回（bit15 置位），导致 pfc_server 的 `IPC_FunctionCall()` 永远收不到应答、
  PFC 背景配置从未下发。改按请求来源路由后此路已通。
* 结论：背景缺失**不是**因为 IPC 配置没下发，而是下发后 guest 走的是**硬件合成路径**。

### 33.2 实证：背景位图不在任何客端可读 RAM 区

* `SP_FB_BG_DUMP` 同拍导出 layer1/layer2：`painted=0.000000`、占用图全 `.`，与 §32 一致
  （窗口 1/2 从未被写）。
* 通过 QEMU monitor `sum 0x100000` 逐 1MB 块扫描整段 chunkmem 保留显存
  `0x0C000000..0x10000000`（64MB）：
  - 仅 `0x0C000000..0x0C500000`（窗口 0 = OSD 仪表盘）非零；
  - 窗口 1（`0x0C600000`）、窗口 2（`0x0CC00000`）全零；
  - `0x0C500000` 之后整段 44MB **全零**。
  → 解码后的背景缓冲**不在 fbdev 窗口，也不在 chunkmem 保留显存**。

### 33.3 关键证据：背景由 VPP/PFC 显示控制器 MMIO 配置（≈0x41e60000）

* 反汇编 `libpfc_service.so` / `libsppfc.so` 确认：`Draw_Background_From_Nand` 在
  `libsppfc.so` 仅 68 字节（binder 转发包装）；真正实现在 `libpfc_service.so`
  `BackGroundFlipThread::threadLoop`（0x104fd，772 字节），其内部只调 libc
  （`getpid`/`snprintf`/`pthread_mutex_*`/`fcntl64`/`system`…），**真正的图像解码/写寄存器
  经由 binder 事务 + `MID_DISP_*`（`libmid_disp.so`：SetVpp2BackgroundLayer /
  SetG2dBackgroundLayer / DirectFlipBufferEx）完成**。
* 解析 id=9（MID_DISP）与 id=23 的 IPC 请求包（w0–w3 头，w4+ payload）：

  ```
  id=9  len=0x10  payload = 41e614c0 00000038 00000000 00000000
  id=9  len=0x14  payload = 41e5fff8 0000003a 00000000 00000000 00000001
  id=9  len=0x1c  payload = 41c9cab1 ...   (41e5fff8 ...)
  ```

  payload 首字 `0x41e614c0 / 0x41e5fff8 / 0x41e61c34 / 0x41c9cab1` 落在 **0x41exxxx 区间，
  远超 256MB RAM（0x0..0x10000000）** → 这是 **VPP/PFC 显示控制器 MMIO 基址（≈0x41e60000）**，
  不是 RAM 地址。guest 是在**写 VPP 背景层寄存器**来配置背景，而不是把位图写进某块 RAM。
* 模型里**完全没有 VPP/PFC 的 MMIO 区域**（grep 全文件仅 GIC/UART/PSU/SPINAND/VDISK），
  这些寄存器写被静默丢弃（无 unimplemented 日志）。解码后的背景位图由 **VPP 硬件**从一块
  缓冲 DMA 合成，该缓冲的**物理地址写进了我们没有建模的 VPP 寄存器** —— 因此没有可供读取的
  客端帧缓冲。

### 33.4 结论：硬阻塞，且在本约束下无法绕过

* P 档背景（右侧茶青墙 + 整车）是 **VPP/PFC 硬件图层**，由 ≈0x41e60000 的 MMIO 寄存器配置，
  当前 QEMU 模型未实现该显示控制器。**在不伪造像素的前提下，当前无法渲染该背景**。
* 这不是遗漏、也不是轮询/解码瓶颈（那部分 §32 已修），而是缺一个 **PFC/VPP 显示控制器模型**。
* 非法路径（禁止）：自行解码主题库 `631_18066a3.png` / `590_1317f42.png` 并贴图 —— 选哪张、
  透明度、层序都是猜的，违反「不伪造像素」。

### 33.5 合法的下一步（若要做，工作量较大，单列）

1. 在模型里建最小 **VPP/display MMIO 区域（基址 ≈0x41e60000）**，捕获背景层
   source-buffer PA 寄存器 + 几何/格式/alpha/rect 寄存器（寄存器布局需从 `libmid_disp` /
   VPP 内核驱动 / 数据手册逆向）。
2. 该 PA 指向的缓冲**就是 guest 自己解码的真实位图**（落在客端 RAM 内）——读它、
   按 guest 寄存器给定的层序/透明度合成到窗口 0 之下。这是合法路径：像素来自 guest 自身，
   不是我们猜的。
3. 前提风险：guest 的 VPP 驱动必须在我们的精简 guest 里真正运行并把缓冲分配在
   **≤256MB** 的 RAM 内；若其分配器假定更大物理空间（PA 落在 0x41exxxx 这种非 RAM 区），
   则缓冲本身不在我们 RAM 中，仍需先扩 RAM 或改分配。需先验证。

> 状态：IPC 路由修复已验证；**背景渲染 = 硬阻塞，本轮未关闭**。OSD/仪表盘（窗口 0）正常。

## 34. 背景层定性更正：内容在 app 资源里，缺的是「没人请求绘制」（2026-11-03 夜）

> 本节**推翻 §33.4 的定性**。§33.2/§33.3 的观测（窗口 1/2 全零、只有 0x41exxxx 控制位写）
> 仍然成立；错的是由它们推出的结论。

### 34.1 被否掉的假设：不存在「PFCB_AML」位图容器

* 上一轮据 `cpu_memory_rw_debug` 在 VA `b6ed24e2` 读到 `5046435f 414e4d4c` 推断有一个
  `PFCB_AML` 容器装着解码后的背景位图 —— **错误**。
* 改为扫物理 RAM 的 `PFC` 前缀后实测：全 RAM 57 处命中，全是**资源名字符串**
  （`PFC_ANMLOGO` / `PFC_ResetCbk` / `PFCCallback` / `PFC_DOV` / `PFC_NVM` / `PFC_Get_Key_`），
  即 `PFC_ANMLOGO`（=PFC 动画 logo 资源类型名）的前 8 字节恰好是 `PFC_ANML`。
  当初读到的就是它，不是位图容器。
* 256MB 全 RAM 快照（`SP_RAM_DUMP`，t≈70s，UI 已出）逐 1MB 块按 `alpha=0xFF` 筛：
  11 个块命中，RCB 均值全部 ≈(3~9) **近黑**；把窗口 0/1/2 直接渲染成 PNG 也证实
  win1/win2 = 100% 零、win0 仅 26686/614400 非黑像素（就是那点文字和图标）。
  → **客端 RAM 里从头到尾没有一张彩色背景位图。**

### 34.2 新证据：背景图内容本来就在 app 里

* `libdashclustoractivity.so` 内嵌 672 张 PNG（Qt RCC 裸存），其中 **18 张 1024×600 全屏图**。
* 用资源清单（`dist/power-gauge-research/overlay-investigation/resources.json`，593 条
  「大小 ↔ 资源名」）按字节数反查，三张全屏图的身份确定：

  | 内嵌偏移 | 字节数 | 资源名 |
  |---|---|---|
  | `0x18066a3` | 170032 | `/res/res/AE4iMenu/ShortMotoPic/settingbg.png`（设置页背景：茶青 Z 墙 + 整车） |
  | `0x1317f42` | 188245 | `/res/res/AE4iMenu/LongMotoPic/settingbg.png` |
  | — | 169685 | `/AE4i/AE4i/P档背景.png` = **P 档表盘背景**，实为**白→淡青渐变**，不是墙+整车 |

* 即 §31/§32 说的「茶青墙 + 整车」实际是**设置页**的车辆图背景；P 档表盘本身是一层浅色渐变。
  两张都在 app/资源包里，**内容是确定的**，§33.4 里「选哪张是猜的」这条不再成立。

### 34.3 新证据：背景是独立平台层，owner 是 libpfc_service

* `libpfc_service.so`（spsdk 分区）导出 `spplfctrl::IPlatformControl`，日志实测（boot 2.8s，
  早于 Launcher 3.2s）：
  ```
  PlatformControlImpl: [get_bg_info 1519] Background W/H: 1024/600
  PlatformControlImpl: BackGroundFlipThread 297
  PlatformControlImpl: BackGroundTransparencyThread 164
  ```
* 相关 API：`set_background_transparency(bool,u32)`、`draw_background_from_nand(u32,u32)`。
  即背景层 = 独立 framebuffer + 翻页线程 + 透明混合，**不在 Qt 场景里**。
  这解释了为什么窗口 0 只有 UI：OSD 与背景层本来就分属两层。

### 34.4 新证据：本机没有任何模块去填这个层

* **机制已查明**（`libpfc_service.so` rodata 原文）：
  ```
  /tmp/sp/application/etc/background/
  dd if=%s%d.yuv of=/dev/fb%d ibs=%d obs=%d count=1 seek=%d &> /dev/null
  [%s %d] set background to %s
  ```
  即背景 = 一个 **YUV 文件**，用 `dd` 整块写进 `/dev/fbN`（`ibs/obs/count/seek` 全是
  shell 透传）。所以它既不进 Qt 场景，也不是 VPP 解码器 —— 就是往另一块 framebuffer 里 dd。
* 全 spapp 搜索 `Draw_Background_From_Nand`（注意大小写）：**零调用方**；
  该符号只出现在 `firmware/spsdk-root/lib/libsppfc.so` 的 binder 转发桩里。
* 全 spapp + spsdk 搜 `set_background_transparency` / `get_bg_info`：**除 libpfc_service 自身实现
  外无客户端**。串口日志整轮 `set background` / `.yuv` / `excute` / `flip fb` **命中 0 次**
  → 这条路径在本机**一次都没被触发过**。
* 同时窗口 1/2 在快照里恒零、`SP_FB_BG_DUMP` 的 layer1/2 `painted=0`。
  → guest 侧确实一次都没画过背景。

### 34.5 id=9 只下发控制位，没有源地址

* 实测整轮只有 3 条寄存器写：`41e5fff8←0x0e`、`41e614c0←0x38`、`41e5fff8←0x3a`。
  都是控制/使能位，**没有一条是 source-buffer 物理地址**。
* 模型新建的 VPP MMIO 记录窗（`0x41c00000` +4MB，`SP_VPP_TRACE`）**零访问** —— 符合预期：
  IPC 桩把 id=9 短路了，内核 MID_DISP 根本没机会做 MMIO。寄存器镜像已保留供取证。

### 34.6 结论（更正 §33.4）

* 缺的**不是** PFC/VPP 解码器模型，而是「**没有任何组件请求绘制背景**」。
* 当前画面（`DashTheme01` + 左侧「骑行获得数据~」空态 + 右侧空）在**无车辆数据**状态下自洽：
  app 输出连贯，不存在丢层/丢帧。
* 「硬阻塞 = 缺显示控制器模型」定性作废；但背景层仍未关闭，阻塞点转移到**配置/数据**。

### 34.7 下一步

1. 查真机上 `set_background(name)` 由谁触发。机制是 `dd if=/tmp/sp/application/etc/background/
   <name>N.yuv of=/dev/fb<N>`，因此前提有两个：
   - **触发方**：本机全程无任何客户端调用（已实证）；
   - **素材**：guest 内实测 **根本没有** —— `/tmp/sp/application/etc/` 只有
     `EasyConnect / bluetooth / ipod / log_service`，无 `background/`；全盘
     `find / -name '*.yuv'` **零命中**；NAND 全镜像也搜不到 `.yuv` / `etc/background`。
     → 这台车的 spapp **没带背景素材**，因此背景层本来就无内容可画。
2. 若要做「按实车逻辑渲染背景」，正确的模型改动是**提供一块真正可写的 `/dev/fb1`**（现在是
   `ENODEV`），让 guest 自己 `dd` 进去；模型再把这块 fb 按 `set_background_transparency` 的
   开关合成到窗口 0 之下。像素完全来自 guest，仍然不伪造。
3. 主表盘本身：`/AE4i/AE4i/P档背景.png`（白→淡青渐变）+ 整车 + P 徽标 由 app 画；它不出现的
   直接原因是**无车辆数据 → app 停在空态**（左侧「骑行获得数据~」就是占位文案）。归到 §30
   的主表盘阻塞点：**先有 CFCP 上行车辆数据（speed/gear/eleLevel/odo/trip）**。
4. 模型侧本轮改动：新建 VPP MMIO 记录窗 + id=9 寄存器镜像；删除上一轮基于错误假设的
   「全 RAM 扫魔数」（它每次 IPC 都要白扫 256MB，会拖慢 guest）。

> 状态：**背景层仍未关闭**；但定性从「缺硬件模型」更正为「缺触发/数据」。
> OSD 仪表盘（窗口 0）正常，帧与清理前逐像素一致（仅时钟数字不同）。

## 35. 车辆数据从哪来：主线束/维修手册的接口拓扑（2026-11-03）

来源：`instruction/AE5i 电轻摩维修手册初版.pdf`（5.10 / 5.12.1 / 5.13 / 5.16.x 针脚与
故障码表）、`instruction/AE5i Pro 主线布局图.pdf`（线束布局，仅连接器定位，无网络拓扑）。

### 35.1 各节点接口（手册针脚原文）

| 节点 | 接口 | 依据 |
|---|---|---|
| 仪表 DASH | **RS-485 A/B** + **CAN-H/L** + 一线通 | 5.13 A 针 17/18（485-A/B）、36/37（CAN-H/L）、32（一线通） |
| 电机控制器 (MCU) | **只有 RS-485**：16PIN-7 `485B/RX`、16PIN-15 `485A/TX` | 5.12.1 |
| 智能中控 T-BOX | **只有 RS-485**：PIN4 `RS485-B`、PIN9 `RS485-A` | 5.10 |
| BRS 盲区雷达 | 与 仪表/MCU/T-BOX **同网** | 5.16.4 自带 `E311 仪表通讯故障`/`E312 MCU 通讯故障`/`E313 T-BOX 通讯故障` |
| BMS | CAN 侧 | 5.16.2 `E202 BMS 通信故障` |
| ABS | CAN 侧 | 5.16.5 E321~E336 |

要点：
* **T-BOX 没有 CAN**，只有一对 RS-485 + 硬线唤醒（PIN2 输入唤醒 / PIN7 输出唤醒仪表）。
* **电机控制器也没有 CAN**，只有一对 RS-485，且引脚名写成 `TX/RX` ⇒ 应答方。
* 仪表只有一个 485 对，而 MCU 与 T-BOX 都接它，且 BRS 能同时报「MCU/T-BOX 通讯故障」
  ⇒ **仪表 / 电机控制器 / T-BOX / BRS 是同一对 RS-485 上的多机总线**（按地址区分，
  与 CFCP 载荷里的 `aid` 字段吻合）。
* 推论（未实证）：T-BOX 上报云端的车速/里程很可能就是**监听这条 485 总线**拿到的。

### 35.2 结论：先做电机控制器（MCU）模拟，不做 T-BOX

1. **数据源唯一性**：speed/gear/eleLevel/odo/trip 只有电机控制器会产生；T-BOX 是
   云端网关 + 蓝牙，**不可能产生**这些量。模拟 T-BOX 拿不到表盘数据。
2. **接口对称性**：T-BOX 无 CAN，模拟它也补不出 CAN 侧的 BMS/ABS。
3. **仿真器结构**：模型里**没有 RS-485 总线模型，也没有 CAN 模型**（`sunplus-sp8368.c`
   全文无 CAN）。SoC 的对端就是 Flutter 客户端里的 `lib/emu/gd32.dart`（我们自己在扮演
   GD32）。所以「模拟电机控制器」落到实现上 = **让 `gd32.dart` 产生 MCU 来源的上行
   ride-info 帧**，而不是去模拟一条真实 485 物理链路。
4. 本节当时将 T-BOX 延后；§37 已将 OTA 列为核心并行研究项。OTA 需要的实际节点按 AE5i 执行链取证，不预设必须先完成 T-BOX 全部功能。

### 35.3 上行帧的落点（当时待办，已由 §36 更新）

* 当时已知接收侧：`mcucom_rx_ride_info_update(u8,u8,u8,u8*,u16) @0x397c4`，载荷是**大端 u16 TLV
  标签 `0xCF01/0xCF02…`，每条 35 B**。
* §36 已解出 vhal 元素为 `{u16 payload_len (LE); payload[]}`，裸 TLV 错误已消失，记录被接受并 ACK。
* 后续 §38 更新：探针只到 App 缓存，尚未命中 ride-info handler；主表盘研究转向 `vehicle_info1/2/3` bytes 属性分发，不再把 ride-info 字段当作唯一入口。

## 36. CFCP 上行 vhal 信封彻底解出（2026-11-03 深夜）

### 36.1 方法：拿内核报错当 oracle

内核那句报错会**回显它自己解析出来的字段**：

```
[CFCP] cfcp_parse_prop_data.L279 exist illegel vhal frame array,
       vhal_frame_len : 64 index = 0 vhal_len : 465.
```

于是不必盲扫组合：发一段「第 i 字节 = i」的身份载荷，看它报什么，就能反解字段位置。

### 36.2 结论：元素 = `{u16 payload_len (LE); payload[payload_len]}`

单字节置 0xFF 逐位探测（载荷 64 B 全零，只把第 k 字节改成 0xFF）：

| 探针 | 内核报出 |
|---|---|
| 全零 | **不报错**（等价于 32 个空元素，解析器一路走完） |
| `byte[0]=FF` | index=0, vhal_len=0x0101 |
| `byte[1]=FF` | index=0, vhal_len=0xFF02 |
| `byte[2]=FF` | index=**2**, vhal_len=0x0101 |
| `byte[3]=FF` | index=**2**, vhal_len=0xFF02 |
| `byte[4]=FF` | index=**4**, vhal_len=0x0101 |

反解出 **`vhal_len` = 元素偏移 0 处的 LE u16 + 2**，且解析器按该值步进。即

```c
struct vhal_elem { u16 payload_len;   /* LE，不含本头 */  u8 payload[payload_len]; };
```

验证：`[len_lo len_hi] + 35B(CF01 记录)` 发进去，`illegel vhal frame array` **消失**；
多发几个元素（含空元素）也不报错。

### 36.3 记录帧：BE u16 标签 + 数据，0xCF01 是 33 B

`libmcucommodule.so` 的 `mcucom_rx_ride_info_update(u8,u8,u8,u8*,u16) @0x397c5`
（**Thumb**，1448 B）反汇编（`tools/arm_disasm.py`）：

```asm
0x3993c  ldrb  r3, [r5, r4]          ; tag 高字节
0x39940  ldrb.w r8, [r2, #1]         ; tag 低字节
0x39946  orr.w r8, r8, r3, lsl #8    ; tag = BE u16
0x3994a  movw  r3, #0xcf01
0x3994e  cmp   r8, r3
0x39950  bne   <下一个标签>
0x39956  add.w r2, r6, #0x20         ; 拷 32 字节
0x39966  ldrb  r2, [r6]              ; 第 33 字节
0x39968  adds  r4, #0x23             ; 步进 0x23 = 35
```

* 标签 **0xCF01** → 把 **33 B** 数据整体拷到结构体，记录总长 **35 B**，与 §29.9 一致。
* 目的槽由**第 2 个 u8 参数**选：`=3` → `this+0x270`，`=4` → `this+0x2c8`，其它值走另一分支。
* `mcucom_get_ride_info_record @0x26126` 从 `this+0x26c` 拷 **0x4d4** 字节出去。

### 36.4 调用来源

* 该 handler **没有任何模块 import**（全 spapp grep 只在本模块出现），但本模块
  `.rel` 里有 **R_ARM_JUMP_SLOT** 指向它 ⇒ 经 PLT 调用。
* `libnipcmodule.so` 有 `ipc_get_dataFromMCU_setItem1..4`，而 handler 的槽位选择正好是
  **3/4** ⇒ 上行 ride-info 走 **setItem3 / setItem4** 这两块数据。
* 链路：`CFCP(ttyS1)` → 内核 `cfcp_dispatch_q_frame` → 用户态 → `libnipcmodule`
  `ipc_*_dataFromMCU_setItemN` → `mcucom_rx_ride_info_update`。

### 36.5 已验证 / 未解

已验证（本轮）：
* 信封（元素布局）**通**——内核不再报 `illegel vhal frame array`；
* 帧被接受并 **回 ACK**（`ACK cmd=0x00010155`，说明 `dispatch_one_frame` 走了用户态投递分支）；
* 记录帧格式（BE 标签 + 33 B，步进 35）**通**。

未解：
1. **33 B 结构体内部字段偏移**（speed/gear/eleLevel/odo/trip）。要读 `this+0x270` 的消费者，
   它在 **dashclustor** 侧（本模块无调用点）。
2. **vhal 元素里哪个字段选 setItem3/4**。载荷前几字节可能就是 pid/aid，
   可用「逐字节置位 + 观察 guest 属性广播」的方式继续定位。

### 36.6 新增工具

* `tools/vhal_probe.py` —— 发 CFCP 帧 + **监听回包**（ACK / 属性广播）+ 抓内核日志。
  `identity` / `hex` / `elem` / `listen` 四种模式。
* `tools/arm_disasm.py` —— capstone 按符号反汇编 32 位 ARM ELF（自动判 Thumb），
  支持 `--list <关键字>`、`--callers <符号>`、`--addr`。
  注意：Thumb 判定要用 `st_value & 1`，不能只看 `st_info`（本库多数符号是 Thumb）。

## 37. OTA 仿真实施路线与验收（目标见文首，2026-11-03）

### 37.1 用户目标与优先级

目标按顺序推进：

1. **先完成 AE5i 仪表全功能仿真。** 包括原厂引导、开机动画、全画面渲染与合成、原生按键、上电/解锁/READY/下电、MCU/车辆数据、蓝牙、Wi-Fi、RS-485 协议通信，以及 **OTA Update 模式下从选包到刷写、重启、验收/恢复的完整闭环**。OTA 仿真是仿真器核心验收项，也是固件定制前置门槛。
2. **再定制自制 Qt 仪表 UI。** 基于 AE5i 原厂 Qt 用户态，保留原厂启动链、内核、MCU 接口与仪表通信硬件；目标 UI 通过仪表蓝牙连接 APT F600，读取/修改电机控制器参数，并读取蚂蚁 ANT BMS 和电池计量信息。使用同一仿真环境和虚拟外设做回归。
3. **最后通过 OTA Update 无线刷入实车。** 仿真、包静态审计、恢复演练均通过且用户明确下令后，才进入可刷包/实车步骤。仿真研究不授权生成或推送可刷包。

外接设备研究对象已记录：APT F600 电机控制器、蚂蚁 ANT BMS、电池计量模块。目标能力是通过仪表原厂蓝牙功能连接并完成参数读取/修改和 BMS 信息读取；其实际通信承载可能涉及 BLE/GATT、RS-485 或其他车载总线，需实测确认。协议私有不构成路线阻塞；后续以合法连接/通讯样本逐项差分。当前仅有主线束拓扑、静态固件配置等线索，不能据此声称 BLE/GATT 角色、多设备并发、控制器/BMS 协议或物理蓝牙芯片已验证。

### 37.2 现状校正：OTA 仍未仿真

| 子系统 | 目前证据 | 缺口 |
|---|---|---|
| 启动 | QEMU 能从 `AE5.BIN` 对应的 SPVD 提取并**直接加载 Linux-4.9.217**；原厂 logo 帧由模型重放 | 当前没有执行 xboot/U-Boot，也没有复现 U-Boot PE 动画解码和引导状态转换 |
| OTA 入口 | `docs/53` 记录实车在上电瞬间长按 `Set + 下` 10 秒进入 OTA Update；真实 OTA 窗口在引导阶段 | 仿真器没有此启动组合键/OTA 模式状态机；不能用 `0xd6 app_key_ota` 代替，两者不是同一入口 |
| 传输 | `docs/55` 记录 OTA 窗口启动的 10086 P2P 服务接收裸 `GEMINI_PACK.BIN`，以 `OTA` 命令触发写包；SpeedHunter 推送链路在实车可用 | QEMU 没有虚拟 Wi-Fi Direct/P2P 服务，也未让实际客户端向 guest 传包 |
| 包校验 | `docs/53` 的 SpeedHunter 前置六项检查、`docs/54` 的分区表/脚本/uImage 校验方法已存在 | 仿真器没有选包到校验报告的连接，也没验证目标 U-Boot 对 AE5i 包的真实接受/拒绝行为 |
| NAND 写入 | SPVD 描述 25 个 AE5i MTD 分区；当前 Linux 启动可访问 NAND 模型 | 当前 OTA 包表的 19 项与 AE5i 25 个 MTD 分区之间的映射、原厂脚本实际擦写顺序、GD32 更新/复位影响仍须逐项复核；需写入可重启复用的隔离副本 |
| 更新结果 | 无 | 无分区擦写/写入/回读、掉线或断电故障注入、更新后冷启动、原厂包恢复及版本核验闭环 |

因此当前客户端即使能选择 SPVD/启动固件，也不代表它能仿真 OTA Update。当前 QEMU 启动路径绕开了 OTA 所在的引导阶段，OTA 完整仿真状态为 **未实现**。

### 37.3 仿真器实施路线

| 阶段 | 工作 | 通过条件 |
|---|---|---|
| A. 固化基线 | 仅使用 AE5I `AE5.BIN` / `images/ae5i.spvd`；记录 xboot、U-Boot、25 个 MTD 分区和 OTA 包内 19 项表/脚本的逐项映射。保持 `firmware/` 原件只读 | 每个结论有分区、偏移、脚本或实车 OTA 记录支撑；不得把 8AJ1 行为套到 AE5i |
| B. 可执行引导链与 NAND | 让原厂 AE5i 引导代码在 `sunplus-sp8368` 模型中运行，补齐其实际使用的启动介质、按键/MCU 复位与显示接口；SPI-NAND 写擦在单独可持久化的 copy-on-write 副本中完成，原始 SPVD 不可变 | 从虚拟冷上电执行原厂引导代码，按键选择正常启动和 OTA Update 两条路径；正常路径继续进入原厂 Linux/Launcher |
| C. OTA 窗口与客户端 | 在上电边沿识别 `Set + 下` 长按时序，显示 guest 原生 OTA 窗口；建隔离虚拟 P2P 链路，让仿真客户端/SpeedHunter 真实走选包、校验、连接、传包、结束命令和日志回传 | 能由客户端上传真实格式 OTA BIN；guest 收包长度/分块/结束状态和客户端报告一致，不接受只改 Flutter 画面的假成功 |
| D. 原厂升级与持久化 | 按 AE5i 实际 U-Boot 更新脚本解析包、按分区名擦写/写入并执行原有回读校验；实现 NAND 坏块、擦写边界和相关 GD32 路径。记录每次虚拟写入 | guest 日志、写入副本哈希、分区差异、重启版本一致；重复冷启动不丢更新结果 |
| E. 故障与恢复 | 注入错误机型/损坏校验/分区越界/传输中断/写入或回读错误/写入中断/重启失败；验证 OTA 界面、日志和后续启动行为；再推原厂 AE5i 包做虚拟恢复 | 每类故障有可重复用例和明确结果；部分更新状态与真实引导代码行为一致；原厂包恢复后回到基准系统。恢复是目标，不预先宣称任意中断都可恢复 |
| F. 仪表功能回归 | 完成原生画面、P/READY、车辆信号、导航/车身按键、上电/认证/关机、BLE 与目标外设；APT F600、ANT BMS、计量模块协议逐步逆向 | 每项标注原厂执行、仿真执行、桩、透传或未实现；端到端状态与有证据的实车样本一致 |
| G. 固件定制前门 | 在上述同一虚拟 NAND/OTA 通道内安装自制 Qt 用户态候选，跑完整仪表与 OTA 回归；不得修改 boot chain/kernel 基线 | 原厂包升级和回退闭环通过、功能矩阵通过、六项包检查与 Launcher 静态审计通过，且没有虚拟写入触及真实设备 |

实现中需分清三个执行者：SpeedHunter 负责选包与客户端侧六项预检；OTA P2P 服务负责传输/结束协议；原厂 U-Boot/更新脚本负责目标分区擦写及其回读校验。六项预检通过不等于 U-Boot 刷写成功，P2P 100% 不等于更新完成，必须以虚拟冷启动后的实际运行版本作为成功判据。

### 37.4 研究顺序与立即工作

1. 先从 AE5i `xboot1`/`uboot1`/`uboot2` 和 OTA BIN 的实际更新脚本确认入口按键、10086 服务启动位置、包布局、19 项表到 25 个 MTD 分区的映射、每个写入/校验动作及 MCU/GD32 更新调用；`docs/53`–`docs/55` 是协议线索，不替代这一轮 AE5i 二进制核验。
2. 当前模型直接加载 kernel；评估并实现原厂引导代码运行所需的最小外设，不以手工跳转至 Linux 后伪造 OTA 屏代替。如果存在只能在模型中代行的硬件操作，必须把边界与真实代码路径分开记录。
3. 将 NAND 模型从“运行期不改源 SPVD”扩成每次仿真独立、可检查、可丢弃/复用的持久写入层。原件和真实车辆均不得作为写入目标。
4. OTA 闭环先用可识别的原厂 AE5i 包作只在虚拟存储上的升级/恢复测试；故障注入覆盖验证门、传输门、分区门和重启门。不得为了测试产出或上传自制可刷包。
5. 车辆运行时研究以 §38 的 `vehicle_info1/2/3` bytes 属性分发为当前入口，继续验证消费者及字段；完成车辆外设协议研究后再推进 Qt 用户态定制。用户提供的设备目标为 APT F600、ANT BMS 和电池计量模块；先确定每个设备实际总线、BLE 服务角色与采样方式，再建立可重复的虚拟 peer。

### 37.5 交付验收定义

“仿真器完成”至少要求：原厂 AE5I 启动行为和各功能矩阵可回归；选择真实格式固件包后能在模拟器中进入原厂 OTA 模式；客户端与 guest 完成真实传输和校验；原厂更新代码修改隔离 NAND 副本；成功更新可以冷启动到新版本；故障能产生与执行阶段相符的结果；原厂 AE5i 包可在虚拟机中恢复；串口日志和每个分区的变更证据可导出。仅有 OTA 页面、进度条或客户端状态变化不算通过。

OTA 仿真完成后才以同一路径迭代自制 Qt 固件。实车 OTA 是最后阶段，继续受根目录 `AGENTS.md` 的包审计、用户明确授权、工厂包恢复准备和实车验收红线约束。

## 38. 上行喂数据的实测结论：ride-info 这条路走不通（2026-11-03 凌晨）

### 38.1 新增观测能力（本轮最大产出）

* **按需 dump 客端物理内存**：QEMU monitor `pmemsave 0 0x10000000 "/tmp/x.bin"`
  ——文件名**必须加引号**，否则报 `invalid char 't' in expression`。
  256 MiB 只要 **0.9 s**，可以高频用。工具 `tools/guest_mem.py`（dump/find/diff/hexdump）。
* **反汇编工具** `tools/arm_disasm.py`：`--list` / `--callers` / `--scan <文本>`。
  `--scan "0xcf01"` 证明**整个 libmcucommodule 只有一处**比较 0xCF01，
  就在 `mcucom_rx_ride_info_update` 里 ⇒ 这个函数自己就是 TLV walker。
* 注意：Thumb 判定要用 `st_value & 1`（`st_info` 不可靠）；
  导出符号的模块内调用走 **PLT 桩**，`--callers` 按函数地址找不到。

### 38.2 实证：数据确实进了 App，但只是被"缓存"

发 `CF01 + 33 个互异字节`（prop=setItem3），dump RAM 搜标记：

* 命中 3 处**稳定地址**（`0xa912c79` / `0xa992444` / `0xa99aa8d`）都是
  `CF 01 + 33 B` **原样副本**；
* 另有一处（`0xa93d5xx`）是 App 的 **CFCP 收帧缓冲**，能看到完整帧
  `55a5555a | fe5aaaa5 | 11 02 75 01 01 00 | 2d00 | 2b00 | 03 93 70 21 | 00000000 | cf01 …`。

判据：A/B 两个不同标记（0x10 vs 0x20）做差分，**没有任何"派生值"**出现
（搜 `0x10101010` / `0x1010` 在同址对应 `0x20202020` / `0x2020`，命中 0）
⇒ **值只是字节缓存，没有被任何字段解释**。

### 38.3 84 组组合全否

把 `FRAME0 ∈ {11,21,31,41}` × `命令字 ∈ {75,70,71,72,74,76,55}` ×
`载荷 ∈ {裸 TLV, setItem3 包裹, setItem4 包裹}` 共 84 组各发一遍，
每组用**唯一标记字节**，最后 dump 一次，搜「33 个同值字节且前两字节不是 `CF 01`」
（这正是 handler 命中后的复制形态）：

**命中 0 组。** ⇒ 这些组合都只到"缓存"层，没有一个触发 `mcucom_rx_ride_info_update`。

### 38.4 关键认识：ride-info 不是主表盘的数据源

handler 清单（`--list mcucom_rx`，共 41 个）里：

| handler | 入参 | 可能承载 |
|---|---|---|
| `mcucom_rx_ride_info_update` | `(u8,u8,u8,u8*,u16)` 裸指针 | 行程统计（单次里程/电耗） |
| `mcucom_rx_vehicle_info1/2/3_handle` | **`vector<u8>`** | **整车信息（含车速等）** |
| `mcucom_rx_power_battery_handle` | `vector<u8>` | 电池/电量 |
| `mcucom_rx_trip_1/trip_2` | `vector<u8>` | 里程 |
| `mcucom_rx_KL15_STATE_handle` | `int` | 点火/READY |
| `mcucom_rx_indicator_lamp_handle` | `vector<u8>` | 指示灯（8532 B，最大） |

`vector<u8>` 入参 ⇒ 对应 `CfcpControl::setBytesVehiclePropValue(i,i,vector<u8>)`
（libapis 导出）。**主表盘的车速更可能来自 `vehicle_info1/2/3`（bytes 型属性），
而不是 35 B 的 ride-info 记录**——这也解释了为什么 ride-info 怎么喂都不动画面。

### 38.5 上行其实是 Android 式 VehiclePropValue

`libapis.so` 有 `CfcpControl::setValue(const VehiclePropValue&) @0x56da5` 与
`VehiclePropValue::RawValue`。所以 DATA 的语义是：

```
{u16 len; u32 prop; u32 areaId; RawValue{int32 | float | bytes | string | int32[]}}
```

与本轮解出的 vhal 元素布局 `{u16 payload_len; payload}` **完全吻合**
（payload = prop + areaId + value）。之前"vhal_frame_len/pid/aid"的叫法是误读。

### 38.6 下一步（按性价比排序）

1. **转攻 `vehicle_info1/2/3`**：反汇编 `mcucom_rx_vehicle_info1_handle @0x2aba5`
   （952 B，Thumb），读出它解析的字节偏移；它的入参是 vector，喂法就是
   `setBytesVehiclePropValue` 那一型（DATA = len + prop + areaId + bytes）。
2. **定位 prop id**：`CfcpControl::setValue` 是分发器，但前 300 条指令几乎全是日志；
   需要顺着它调用的 PLT 桩（`0x43500` 等）继续往下，或直接按
   「真实 id 集合」小范围试（`vehicle_info1/2/3` 的 id 应该和 `mcucom_get_vehicle_infoN`
   相邻）。
3. **注意 App 可能有前置门禁**：启动日志里 `GetECActivieState: -3`（EC 状态未知）。
   若 App 在 EC 未初始化前丢弃车辆数据，则必须先喂 `KL15_STATE` / `vehicle_info` 建链。

> 状态：**上行仍未打通**。但已确认信封、记录格式、数据确实到达 App，并把范围从
> "ride-info" 收窄到 "vehicle_info1/2/3（bytes 型属性）"。

## 39. 画面缺元素的定性：不是渲染/合成 bug，是集群停在「待机统计页」（2026-11-03 清晨）

### 39.1 与实车参考图逐项对照

参考：`instruction/IMG_7663.jpeg`（真车 P 档，见 §31.1）。

| 元素 | 实车 | 仿真器 | 层 |
|---|---|---|---|
| 左列 单次里程/单次电耗/平均电耗/总里程 | 有 | **有，逐字一致**（含「骑行获得数据~」占位） | OSD |
| 底栏 按「SET」查看详情 / 电量% / km / 时间 | 有 | **有** | OSD |
| 顶部指示灯区 | ABS 徽标 + `☰ STREET` + 右上圆形图标 + 一串绿色光条 | **只有 1 个「TC 关闭」琥珀图标** | OSD |
| 右侧茶青墙 + 巨大 P + 整车 + 绿色地面 | 有 | **全无** | 缺失 |
| 底栏天气/温度 | 25℃ | 无 | 缺失 |

### 39.2 已排除：不是合成丢了层

`pmemsave` 逐窗统计（本机实测，UI 已静止）：

```
win0 @0x0c000000  非黑像素 53750 / 1572864  (3.4%)
win1 @0x0c600000  非黑像素       0           (0.0%)
win2 @0x0cc00000  非黑像素       0           (0.0%)
```

⇒ 窗口 1/2 **一个像素都没写**，不是"画了但没合成"。

### 39.3 已排除：属性通道改不动布局

在一个连接里依次写属性并逐次抓帧（基线 = 静止帧）：

| 写入 | 变化像素 |
|---|---|
| `car_theme` 0x21407070 = 1/2/3 | 4011（仅时钟数字） |
| `setItem1` 0x21709301 = theme 1..4 | 7861（仅时钟+电量条动画） |
| `gear` 0x21709702 = 0/1/2/3/8 | 4011 |
| `status` 0x21707701 逐字节置 1/2/3/4/0x10/0x80/0xFF（42 组） | **无一组 >15000** |

⇒ 与 §29 一致：**属性通道不驱动集群渲染**。

### 39.4 素材其实都在 app 里

`libdashclustoractivity.so` 内嵌 **672 张 PNG**，其中 17 张 1024×600。按字节数查
`resources.json` 得到 8 张的身份（其余在 .so 的 Qt 资源里，清单未收录）：

| 偏移 | 字节 | 资源名 |
|---|---|---|
| `0x14f810` | 14180 | `/AE4i/AE4i/密码解锁动画.png` |
| `0x2cd238` | 169685 | `/AE4i/AE4i/P档背景.png`（**浅色渐变，不是舞台**） |
| `0x9908cd` | 54657 | `/AE4i/AE4i/弹窗/白色大背景.png` |
| `0x9d6048` | 79118 | `/AE4i/AE4i/弹窗/红色大背景.png` |
| `0xa1e63d` | 117658 | `/AE4i/AE4i/弹窗/黄色大背景.png` |
| `0xa886ee` | 132309 | `/AE4i/AE4i/充电界面/10%以下背景.png` |
| `0xabadac` | 182191 | `/AE4i/AE4i/充电界面/10%以上背景.png` |
| `0xae755f` | 190022 | `/AE4i/AE4i/充电界面/开机充电背景.png` |
| `0x1317f42` | 188245 | `AE4iMenu/LongMotoPic/settingbg.png` |
| `0x18066a3` | 170032 | `AE4iMenu/ShortMotoPic/settingbg.png` |

**另有 6 张「小踏板 + 茶青墙 + 大 P + 顶部绿光条」舞台图**（`0x153458`/`0x248e40` 亮版、
`0xd7a9b0`/`0xe50014`/`0x1905219`/`0x194deb5` 暗版），名字不在清单里，
但构图与实车照一致 —— **素材存在，只是没被画**。

### 39.5 根因：客户端「解锁」没有告诉 guest

* 现在这一页就是 §29.7 记的**待机统计页**，不是主表盘。
* 客户端 `swipeCard()` / `longPressReady()` 只走 `_apply(VehicleEvent...)`
  —— 纯**客户端状态机**，不向 guest 发任何「已解锁/已上电」帧
  （`lib/emu/controller.dart` 里只有 `_forwardKeyTap` 会真发 CFCP 键帧）。
* 真车上这一步是 MCU 上报 KL15/READY 完成的；guest 收不到，就永远停在待机页。
  这也解释了为什么客户端"解锁后"看到的仍是同一张待机图。

### 39.6 下一步

1. **补 KL15/READY 上行**（唯一阻塞点）：`mcucom_rx_KL15_STATE_handle(int) @0x300a5`
   是它的落点，走 `setIntVehiclePropValue` 那一型；需要先定位它的 prop id
   （方法见 §38.6）。
2. 打通后应看到集群切到主表盘，P 档时舞台/整车按 owner 规则无条件出现。
3. 顶部徽标（ABS/STREET/RADAR/光条）另行确认状态源，可能来自
   `vehicle_info1/2/3` 与 `indicator_lamp_handle`。

> 状态：**画面缺元素 = 集群停机状态未切换**，不是合成丢层、也不是主题/档位属性。

### 39.7 补充：舞台页有一个「配置门闸」

反汇编 `BaseWidget::initCfmotoRide @0xc06dd`（424 B，Thumb）：

```asm
0x000c0716  ldrb.w  r3, [r4, #0x140]
0x000c071a  lsls    r5, r3, #0x1a        ; 把 bit5 移到符号位
0x000c071c  bpl.w   #0xc0822             ; bit5 == 0 → 直接返回
...                                       ; 之后才 operator new(0x40) 建控件
0x000c0772  blx     #0x80784             ; setVisible(true)
```

* 门闸是 `BaseWidget + 0x140` 的 **bit5**；为 0 时连控件都不创建。
* 之后建立的控件几何约 `x=616, y=183, w=340, h=140`（右侧中部一小块），
  所以 `CFmoto_Ride` **可能只是右中那块卡片，不是整面舞台墙**。
* `CFmoto_Ride::get_sys_CFmoto_Ride / set_sys_CFmoto_Ride` 走的是
  **持久化配置读写**（`DataSaveControl` 一类），不是实时信号 ⇒ 舞台是否出现
  取决于**存下来的设置**，而这份设置在本次 dump 里没有明文键名（QString 为 UTF-16，
  `strings -e l` 也没命中）。

⇒ 结论调整：舞台缺失**很可能不是"实时数据没喂"，而是"持久化设置里没打开"**。
下一步应去 `userdata` 分区找 app 的设置文件，而不是继续猜信号。

### 39.8 舞台为什么是透明的：它是「场景状态机」里的一层，当前停在 DASH 场景

**素材加载没问题（实证）**：`P档背景_小.png`（400×350，主色 `(0,103,96)`）在 guest RAM 里
命中该色 **419,970** 个像素，集中在 `0x05800000` / `0x07000000`（各 128,959）；
深色 `(0,66,61)` 命中 **14,996**，与 PNG 里该色的像素数**完全相同**
⇒ 图已解码进内存（两份副本），只是没被合成到屏幕上。

**舞台是谁画的（反汇编）**：`libdashclustoractivity.so` 里是一套**场景状态机**：

| 符号 | 地址 | 作用 |
|---|---|---|
| `DashTheme01::PGEARobj_showInit(bool)` | `0xa1d41` | 把 P 档场景各 item 的 **opacity 设 1.0**（`vmov s0,#1.0` → `setOpacity`）；真时还有 `==2` 分支选日/夜变体 |
| `DashTheme01::AnimationPGEAR_Init` | `0x91cb9` | P 档场景动画初始化（3912 B） |
| `DashTheme01::PGEARobj_setLampPos` | `0x8fcfd` | 墙上指示灯位置 |
| `DashTheme01::slot_delayUpdateGear` | `0xa455d` | 档位变化入口（2124 B） |
| `DashTheme01::PGEARobj_showInit` 的 moc 名 | — | 与 `DASHobj_showInit` / `MASKobj_showInit` / `CSSobj_showInit` / `EGGSobj_show` 并列，属 `SenceEnum {DASH, PGEAR, MASK, CSS, EGGS}` |

⇒ 舞台不是"没素材"也不是"没画"，而是**它这一层的 opacity 停在 0**，
因为 `PGEARobj_showInit(true)` 没被调用（当前停在 DASH 场景）。

**试过的触发方式全部无效**（每次都以「茶青像素数」为客观判据）：

| 手段 | 结果 |
|---|---|
| `status` 0x21707701 逐字节单 bit（6×9=54 组） | 茶青恒 225（该 225 是底栏图标） |
| `gear` 0x21709702 = 0..12 | 恒 225 |
| `car_theme` / `setItem1` theme 1..4 | 仅时钟+电量条 |
| 面板键 SET/BACK/下（真 CFCP 键帧） | **与上一帧 0 像素差异** |

> 最后一条是新发现：**面板键现在完全不改变画面**。按 §29.4 键是通的（还会改灯态位图），
> 所以"键无反应 + 舞台透明"更像是**集群整体停在一个未完成初始化的状态**，
> 而不是单点渲染 bug。下一步应先查 `setViewUi()` 之后场景为何没进入 PGEAR。

### 39.9 修正属性路由推断：`0x10103` 是按键命令

2026-11-03 对正在运行的 AE5I guest 做了单帧验证，纠正上一轮对驱动 `is_filter()` 的误读：

* `is_filter()` 开头比较 `cmd == 0x00010103` 后调用 `key_handle()`；将属性 type `0x11`
  配上该命令发送，guest 实际打印 `[CFCP] key_handle.L62 error data_len(4) < 8`。
  因此 `0x10103` 是按键处理路径，**不是**属性帧的替代命令；不能据此修改属性帧命令。
* 运行中的属性广播仍使用 `cmd=0x00010175`。上一轮通过 `vhal_probe.py` 对 `0x10103`
  的试发仅验证了分发到按键处理器，不能证明 vehicle-info handler 收到属性。
* `dispatch_one_frame()` 会按帧字段判断 ACK、队列和分发；`is_filter()` 还承担其它
  描述符过滤工作，单独看到 `0x10103` 分支不足以推断属性路径。

所以 §39.5–§39.8 对“客户端解锁未向 guest 注入车辆数据”“PGEAR 场景未激活”的解释
仍是待验证假设，不能作为唯一根因。中央黑屏尚未修复；目前证据只证明仪表 Qt 的部分
DirectFB/GAL 页面可画、P 档资源可解码，以及已知属性写入不能驱动画面。下一步需要从
原厂 Launcher 的 CFCP 读包解析（`parseRxCFCPBuf`）、驱动用户态 FIFO 路由与运行时 handler
日志三方闭环 vehicle-info 的正确命令/内层格式，再以 framebuffer 差分确认 UI 响应；若
handler 已消费而 framebuffer 仍无主画面变化，再追 `DashTheme01` 信号槽、场景切换和
PFC 背景源。没有该闭环前不应改造渲染器去伪造原厂像素。

## 40. PFC 背景层喂真图：主区噪声 → 真·P 档主界面（2026-11-04）

**症状**：CFCP ACK 修好、KL15=0x99 点亮后，状态栏能画，但主显示区不对（早期是雪花噪声）。
**根因**：合成器 `sp_fb_dump` 的 `SP_FB_COMPOSITE` 分支把 **window 1** 当 PFC 背景层（OSD
透明处回落到 bg）。真机 window 1 由 `libpfc_service` 填；仿真里这条路**从不触发**（§39.8）
⇒ window 1 是**未初始化 RAM** ⇒ 表现为雪花噪声。

**修法（模拟器侧，喂真图）**：
1. 模型加 `SP_FB_BG_FILE`：`sp_load_bg_bitmap()` 在机器 init 读入 1024×600×4 裸 BGRA32
   （byte0=B/1=G/2=R/3=A，与合成器 `bg[]` 字节序一致），`sp_fb_dump` 合成分支优先用它当
   bg（`bg_static`），否则回落读 window 1。
2. `run_ui.sh` 导出 `SP_FB_BG_FILE=$LAB/assets/dash_bg_1024x600.bgra`。
3. 背景图由 `tools/make_dash_bg.py` 生成：从权威 .so 抠素材 + 按实车照合成。

**★ 两次踩坑（关键教训）**：
- **别用 `virtual/spapp-root` 的 .so**：那是 **AE4i 构建（34.6 MB, md5 `90e6…`）**，与 guest
  实际运行的 **AE5I 构建（`/tmp/ae5i_spapp`，27.5 MB, md5 `2482…`）不同**。第一次从 AE4i
  抠的品牌渐变其实是**音乐页背景**，被用户一眼识破。先 `stat`+`md5` 确认 .so 就是 guest 那份。
- **P 档主界面不是一张图**：它是**合成**——暗底 + 绿色地面 + 整车 cutout + 茶青墙含巨大 P +
  顶部绿光条；素材全是 `libdashclustoractivity.so` 里的**独立 Qt 资源**（RGBA 带 alpha），
  由场景机合成。§39.8 的 PGEAR 场景不激活 ⇒ 仿真里永远缺右侧。故用 `make_dash_bg.py` 按
  `instruction/IMG_7663.jpeg` 的布局**离线合成**一张背景（用真素材，非手绘）。

**素材（AE5I .so 内，均 RGBA）**：
| 元素 | 偏移 | 尺寸 |
|---|---|---|
| 茶青墙 + 巨大 P | `0x2a5c23` | 400×350 |
| 整车侧视（镜像后朝右） | `0x12008a9` | 560×400 |
| P 档浅色底 | `0x2cd238` | 1024×600 |

**验收**：成品非黑 ~98%；画面 = 暗底 + 左列信息（单次里程/电耗/平均/总里程）+ 中央朝右整车 +
右侧茶青墙大 P + 绿地面 + 顶部绿光条 + 底栏（按SET/电池/km/时间），**与实车照 IMG_7663 逐项对齐**。
> 样张：`Gemini-Dummy/artifacts/dash_pgear_composed.png`（成品）、`dash_before_noise.png`（早期噪声）、
> `asset_pwall_P.png` / `asset_vehicle_side.png`（素材）。
> 重跑：`python3 tools/make_dash_bg.py` → `python3 tools/build_model.py` → `bash run_ui.sh` →
> `python3 tools/feed_render_frames.py`。

**顺带确证（数据链真的通了）**：喂 `vehicle_info1`(0x21707402) 后串口出现
`mcucommodule vehicle_info1.water_temp : 80` 与 `[BaseWidget] update_speed_data: 250, 155.25`
⇒ 车速/水温确已进到主表盘控件（纠正 §38"只缓存不解析"的悲观结论，至少 speed/temp 生效）。

**仍未解（下一棒）**：本节用**离线合成背景**补齐右侧，没动 `DashTheme01` 的 PGEAR 场景机
（§39.8）。要出"大速度表"（真实速度表盘）仍需闭环 `setViewUi()`→PGEAR 的触发条件；届时背景层
可去掉合成图、改由场景机自己画。

### 40.1 修正：撤回音乐页合成，改为「固件原图 + 实车布局」（2026-11-04）

**用户否决**：上面那版用的是 `bg_09`——其实是**音乐页背景**，且右侧大P/整车没出。要求全程用固件元素。

**RE 结论（真·固件路径走不通）**：P 档主界面本由
`DashTheme01::PGEARobj_showInit(true)` 给 **9 个 item `setOpacity(1.0)`**（右侧茶青墙大P、整车、
绿地面、绿光条…）；它们的位置在 `PGEARobj_setLampPos`（`blx 0x80a74` = `setPos(x,y)`，
浮点字面量 `584/648/224/280/336/392/544/522/578/634`），动画在 `AnimationPGEAR_Init`
（`0.34/0.68/0.8/0.93/1024.0`）。但 `showInit` 是 **Qt 信号槽、无直接调用者**；实测 gear 属性
不触发它，guest 还在 `get_ride_info` 超时 ⇒ 场景机停在 DASH，**无法让固件自己画**。

**最终做法**：从 AE5I `.so` 抠**固件原图**（茶青墙大P `0x2a5c23` 400×350、整车 `0x12008a9`
560×400 镜像朝右），按实车照 `instruction/IMG_7663.jpeg` 的布局离线合成
`assets/dash_bg_1024x600.bgra`，经 `SP_FB_BG_FILE` 喂 window1。结果非黑 ~98%，与实车照逐项对齐。
> 样张：`artifacts/dash_compare_final.png`、`dash_pgear_final.png`、`dash_bg_elements.png`
> 注：主界面 per-item 精确变换埋在动画/构造数据里（数据池打断反汇编），布局按实车照校准；
> 真要像素级固件坐标需继续解动画数据池，或实现 get_ride_info 应答让场景机自己跑。

---

## 41. ★ P 档主界面：固件自己画出来了（2026-11-04 夜，已闭环）

> 本节是 §39.8 / §40.1 的终局。**画面全部由仪表固件自己的 QGraphicsScene 绘制**，
> 没有任何离线合成、没有重绘、没有伪造像素。之前所有「缺素材 / 缺图层引擎」的结论都不需要了。

### 41.1 真正的阻塞：两个 MCU 属性没人喂

`DashTheme01::slot_delayUpdateGear()` 开头有一道**硬闸门**（`0xa46a6`）：

```
r3 = this->0x164;  if (r3 != 0) return;        // 0xa46ac
r3 = [sp+0xc];     if (r3 == 0) return;        // 0xa46b6  ★ 卡在这里
```

`[sp+0xc]` = `mcucom_get_sysState().byte[1] & 0x40`（`0xa459e` 取 sysState、`0xa45a2` 取 byte[1]、
`ubfx #6,#1`）。日志第三个参数就是它：待机时一直是 `slot_delayUpdateGear: 0, 1, 0, 0` ⇒ **0 = 直接 return**，
换挡、换场景、PGEAR 全部无效。

写这个 bit 的只有 `mcucom_rx_synchronization_status`（`0x3871c`）：

```
payload[0]        -> sysState.byte[0]      (MCU_SIGNAL_AUTOMATIC_SHUTDOWN)
payload[1] bit7   -> sysState.byte[1] bit0 (MCU_SIGNAL_INTER_OAT_BACKDOOE)
payload[1] bits3-6-> sysState.byte[1] bits1-4 (MCU_SIGNAL_VEHICLE_SELECTION)
payload[1] bit2   -> sysState.byte[1] bit6 (MCU_SIGNAL_UNLOCK_NOTIFY)   ★ 就是这道闸门
```

⇒ **必须喂「解锁通知」**，也就是真车上 MCU 报告的「已解锁/整车就绪」。

### 41.2 场景机的状态表（`Animation_Setinit(SenceEnum)`，`0xa4054`）

```
state = this->0x70c;  sence = r5;
if (this->0x704 == sence) goto 尾处理;            // 已经是这个场景，跳过
switch (state) {
  case 0: sence==1 -> Animation_Mstart_init(); state=1;   // DASH（统计页）
          sence==2 -> Animation_Pstart_init(); state=1;   // ★ PGEAR
  case 1: sence==2 -> Animation_Mend_init(); state=3;
          sence==0 -> Animation_Mend_init(); state=6;
  case 2: sence==1 -> Animation_Pend_init(); state=4;
          sence==0 -> Animation_Pend_init(); state=7;
}
this->0x704 = sence;
```

- `Animation_Mstart_init` → **`DASHobj_showInit(true)`**（`0x97f82`）
- `Animation_Pstart_init` → **`PGEARobj_showInit(true)`**（`0xa3bd2`）★ 右侧大 P 场景
- `PGEARobj_showInit(true)` = 给 **9 个 item `setOpacity(1.0)`**，位置由 item 自己在创建时设好

`slot_delayUpdateGear` 在通过闸门后按 `vehicle_info2.gear` 分派（`0xa4968 cmp r3,#3; bhi 0xa4be8`）：

- gear 0..3 → 走到 `Animation_Setinit(1)`（DASH）
- gear **> 3** → `Animation_Setinit(2)`（PGEAR）

但实测 **gear=1** 就能进 P 档主界面（真车 P 挡就是这个值）：闸门打开后
`update_gear_data(1)` → `切换挡位: 1` → 场景机切过去。

### 41.3 上行属性表（逆向 `parse_byte_vector_value` + 实测双向确认）

| prop | handler | 长度 | 布局 |
|---|---|---|---|
| `0x21400030` | KL15_STATE | int | `0x99`=整车就绪点亮 / `0x55`=待机 |
| `0x21709606` | synchronization_status | **8** | `[1]bit2`=UNLOCK_NOTIFY ★ |
| `0x2170951d` | vehicle_info2 | **24** | `[0..3]`remaind_fuel **`[4]`gear** `[8..11]`remind_milage `[12..15]`batt_12v `[16..19]`ambTemp |
| `0x2170952d` | vehicle_info3 | **20** | `[1]`drive_mode `[2]`battery `[3][4]`motor_temp `[6..7]`power_num `[8]`power_100 `[9..10]`batt_temp `[11..12]`voltage `[13..14]`current `[15..16]`charging_time |
| `0x21707401` | trip_total_ODO | **24** | `[0..3]`odo(0.1km) `[4..7]`avg fuel **`[8..11]`avg power(0.1Wh/km)** `[12..15]`speed `[16..19]`drivetime |
| `0x21700003` | trip_1 | **24** | 同 odo 布局（单次里程/单次电耗） |
| `0x21700004` | trip_2 | **24** | 同上 |
| `0x21707402` | vehicle_info1 | **20** | `[0..3]`wheel_spd `[4..7]`inst_elec `[12..15]`rpm `[16..19]`water_temp |
| `0x21707121` | RTC_report | **6** | `[yy,mm,dd,hh,mi,ss]`（改时间会持久到 guest 时钟） |
| `0x2170951e` | indicator_lamp | **16** | 位图指示灯（ABS/TC/EV_READY/大灯/转向…） |
| `0x21709600` | power_battery | **16** | `[0]`level1 `[1]`level2 **`[2]`all = 电量 %** |

发现方法（可复用）：**喂「第 i 字节 = i」的身份载荷**，handler 自己会把解析出的字段打进日志
（`vehicle_info2.gear : 4` / `vehicle_info2.remaind_fuel : 50462976` = `0x03020100`），
偏移一次就全对上了。长度不对时 handler 会打 `size erro, size= N`，据此二分即可。

### 41.4 ★ 进场顺序（三段式，踩了很久才定下来）

`slot_delayUpdateGear` 每次都用 `setPos(x - bounds.width()*0.5, ...)` 重摆两个顶部 item
（`this+0xdc` / `this+0xe4`，即 DRL 图标与 ECO）。这带来两个互相拉扯的约束：

1. **底栏「续航 km」的数字位要连发几拍才落定**：只发 1 拍会留下旧数字残影
   （画面上是 `"0"` 与 `"00km"` 叠在一起）。
2. **但每次发 gear 都会重摆顶部 item**：连发几十拍后 DRL/ECO 会横向漂移出重影。

⇒ 唯一稳妥的进场顺序（`tools/dash_up.py` 已固化）：

```
① settle  : 连发 20 拍 vi2+vi3+batt+odo+trip（0.15s 间隔）→ 数字位全部落定
② re-init : 反复 2 轮「gear 0 → 等 0.9s → gear 目标 → 等 1.6s」
            → 场景机重跑 Animation_*_init，把顶部 item 摆回正确位置
③ 保持    : 之后只发 KL15/心跳/vi3/batt/odo/trip，**不再发 gear**
```

只做 1 轮 re-init 时顶部 item 有时仍停在漂移位上（时序相关），**两轮稳定收敛**。

**关于 Launcher 重启（重要纠正）**：早期看到进程约每 130 s 换一个 PID，一度以为有固定看门狗。
但用三段式稳定喂食连跑 **32 分钟，`setViewUi` 只出现 1 次**（进程号全程不变），
画面稳定在 59.64%。⇒ 那些重启是**我们反复灌数据 / RTC 时间跳变**逼出来的，不是常态。
`dash_up.py` 仍保留自愈（「曾点亮过 + 非黑 < 15% 连续三次」→ 重放①②），
但它现在是保险丝，不是日常路径。

### 41.5 验收

| 指标 | 修复前 | 修复后 |
|---|---|---|
| 非黑像素 | 4.37% | **59.66% ~ 60.14%** |
| 茶青/绿占比 | 4.04% | **44.89% ~ 45.36%** |

画面 = 暗底 + 中央朝右整车 + **右侧茶青墙 + 巨大 P** + 绿色地面 + 顶部绿光条 +
左列（单次里程 10.0km / 单次电耗 3.5Wh / 平均电耗 28.7Wh/km / 总里程 506km）+
底栏（按「SET」查看详情 / 电量 / 续航 / 时间）。**全部是固件自己的 item，零合成。**

> 样张：`artifacts/dash_fw_real_vs_emu.png`、`artifacts/dash_fw_pgear.png`
> 复现：`bash run_ui.sh`（后台）→ `python3 tools/dash_up.py --duration 20 --png out.png`

### 41.6 已知瑕疵 / 未做

- 底栏 **续航 km** = `vehicle_info2.remind_milage`（`[8..11]`），**已能出真值**（实测 123km / 100km）。
  但固件里该数字位像是有两个重叠 item，喂非 0 值后可能留下残影；
  `dash_up.py` 默认 `--range 0` 保证画面干净，需要真值显式传 `--range 100`。
- **时间**：`0x21707121`（6 B，`[yy,mm,dd,hh,mi,ss]`）实测可改 guest 时钟；
  但时间跳变会扰动 App 的定时/节日彩蛋逻辑（曾出现整屏变黑），故默认不喂，`--rtc` 可选。
- 顶部 **ABS / TC / RADAR / STREET** 等：靠 `indicator_lamp`（`0x2170951e`，16 B）位图，尚未解位定义。
- 底栏电量已通：`power_battery` = **prop `0x21709600`（16 B）**，`[2]` = `electricity_all`(%)。

### 41.7 工具

- `tools/dash_up.py` —— 合规 MCU 对端：ACK 每帧 + 上电序列 + 解锁 + 挡位 + 全量数据 + 自愈。
- `tools/cfcp_probe.py` —— 探测台：`--frame` 看帧统计、`--sweep A:B` 扫 prop、`--lit` 点亮。
- `tools/probe_prop.py` —— 单 prop 身份载荷探针。
- `tools/sores.py` —— **.so 反汇编器（解 PLT → 符号名）**，本轮所有调用图都是它给的。
- `tools/xcaller.py` / `tools/kdis.py` —— 通用 bl/blx 调用者扫描 / 内核 ELF 反汇编。

---

## 42. 花屏收尾：缺的是「翻页时前沿→后沿整页复制」（2026-11-04 下午）

§41 把 P 档主界面点亮了，但画面上仍有几处花屏：顶部图标叠成两份、左列数字和
"骑行获得数据~" 叠在一起、底栏数字重影、进场动画留下整车拖尾和右下角一块残图。

### 42.1 定位：残影在 OSD 里，不在合成器

1. `monitor pmemsave 0x0C000000` 把 fb0 两个 page 转出来 → **当前显示的 page 与
   导出帧逐字节相同**，也就是说残影是**固件自己画进显存**的，不是模型的合成问题。
2. `tools/entry_probe.py --mode early`（趁 Launcher 初始化就把挡位灌进去）能抓到
   **同时存在 6 份整车拷贝**的帧 —— 说明每帧只画「变化的那一块」，**从不重画背景**。
3. 结论：这个 Qt QPA 是增量绘制 + 双缓冲；它期望**翻页时后沿缓冲里已经是上一帧的
   内容**（背景还在，只有动的 item 被重画，旧位置自然回到背景）。

模型早先只按 IPC cmd 6 换了扫描页、**没做这次复制**，后沿一直停留在更旧的画面上，
于是新内容一层层叠上去 ⇒ 全部花屏现象。

### 42.2 模型修复：swapbuf 时整页 copy front → back

`sp_ipc_stub()` 里 `id == 6`（`_ipc_swapbuf`，inline `{window, page}`）分支新增：
换完扫描页后，把**新前沿**整页 memcpy 到**新后沿**（`ui_w*ui_h*4` 字节）。
`SP_FB_NO_FLIPCOPY=1` 可关掉做 A/B 对照。

验证：开启后两页内容一致（之前两页分别是 12:00/12:03 两代画面）；底栏/左列不再
出现「上一代文字压在新文字下面」的重影。

### 42.3 进场顺序（第三版，才是干净的）

```
Phase 0  pre-arm : App 还没画第一屏时，只喂 KL15 + RTC（**不要喂解锁！**）
                   —— 时钟首帧就用正确时间画，省掉"12:00 尾巴"残影
Phase 1  settle  : 连发 20 拍全量数据，**gear 固定 0**（不进 P 档，不触发动画）
Phase 2  enter   : **只写一次** gear=1 → 场景机切一次 PGEAR → 等动画跑完
```

踩过的坑：

- **pre-arm 里绝不能带 `sync`（解锁）**：解锁提前打开闸门后，挡位会在 App 初始化
  过程中生效，动画被拆成 6 帧渲染 ⇒ 整车拖尾（`early` 模式就是这个现象）。
- **挡位不能反复写**：每次 `slot_delayUpdateGear` 都会重摆顶部 DRL/ECO，写多几次
  两个图标就叠到一起（用户截图里左上角那个"双图标"）。
- **进场后才改数字会留残影**：数字 item 重画时只覆盖自己新文本的矩形，
  `0km → 100km` 变宽后旧的 `0` 留在左边（显示成 `000km`）。所以续航默认 0；
  真要非 0 值，残影是固件行为，不是仿真问题（见 42.5）。

### 42.4 本轮 MCU 数据补全（底栏/时间不再是"假的"）

| 显示项 | 来源 prop | 说明 |
|---|---|---|
| 91% | `0x21709600` power_battery `[2]` | 电量 |
| 0km | `0x2170951d` vi2 `[8..11]` remind_milage | 续航（默认 0） |
| 3:12 | `0x21707121` RTC 6B | **跟随宿主机本地时间**（12 小时制显示） |
| 10.0km / 3.5Wh | `0x21700003` trip_1 | 单次里程/单次电耗 |
| 28.7Wh/km / 506km | `0x21707401` trip_total_ODO | 平均电耗/总里程 |
| ECO | `0x2170952d` vi3 `[1]` | 驾驶模式 |

`tools/dash_up.py` 已按此改造：`--rtc auto`（默认，宿主机时间）、`--range` 默认 0、
一次性写挡位 + pre-arm。

### 42.5 仍未解决：进场动画首帧留下的一小块

右下角 (930..1024, 470..540) 有一块 ~94×70 的残图（茶青墙角 + 车轮），来自进场
动画的**第一帧**（动画把整场从右下角小尺寸放大/滑入，第一帧的像素没有任何后续
绘制覆盖它）。固件自己不会清屏，所以这块一直在。

真机上它应该由 `libpfc_service` 的 **`BackGroundFlipThread`（背景层每帧重贴）**
擦掉 —— 也就是 §41 里那条还没打通的 PFC/DOV 背景层路径。**这是下一棒**：
把 PFC 背景层做出来，动画残影会随"每帧重贴背景"自然消失。

### 42.6 PFC/DOV 背景层：为什么还差最后一块

串口里 `PfcDispServer: PFC/Display services are starting.....` 说明**固件自己的
PFC 显示服务是在跑的**，App 也拿到了 `get_bg_info Background W/H: 1024/600`，
但它随后去问 DOV 图层配置时失败：

```
PFC_DOV : get dov failed            ← Launcher → PfcDispServer 的 DOV 查询
```

逆向到的协议（模型日志 `VPP-IPC id=23`）：

```
blk[2] = 0x0017000e   id=0x17(23), len=14
blk[4] = 0x00000287   seq
blk[5..7] = 3 个指针（结果缓冲区 / 长度 / 数据）
blk[8] = 0x000054e1   DOV 子命令
```

`libspdovcfg::dov_send_cmd` 收包后读 `msg+0xc` 的 u16：**≠0 判失败**，0 才算成功，
然后把返回的字节拷进 App 给的缓冲区。

**模型目前的局限**：只能"伪造回包"，不能把请求真正转发给 `PfcDispServer` 再把它的
回包送回等待者。试过 `SP_IPC_MODE=1`（只回用户态）：`get dov failed` 从 3 降到 1，
但 **id=3（fbdss 取 UI 分辨率）用的是内核侧等待者，只回用户态会让整个显示栈停摆**
（串口刷 `RPC SERVER #7 NOT RUNNING!`，CFCP 也不再发帧）⇒ 已回退 mode=2。

⇒ 真要打通需要**模型实现一次真正的用户态 IPC 往返**（转发请求 → 等 daemon 回包 →
按 bit15 送回 waiter），这是 §41 遗留的 PFC/DOV 图层引擎工作。

### 42.7 指示灯位图（indicator_lamp）解出来的部分

`0x2170951e`（16 B）用「单 bit 载荷 + 日志 diff」解出（`tools/lamp_bits.py`）：

| bit | 字段 | 屏幕效果 |
|---|---|---|
| byte0 bit0 | `ABS_off` | 顶部出现 (ABS) 带斜杠图标（≈x365） |
| byte0 bit2 | （未命名） | 顶部 y16..31 一条横带 |
| byte0 bit5 | （未命名） | 顶部指示灯行整体重画（y11..48） |
| byte1 bit0..6 | `ABS_fault` | **会弹故障框**（App 卡住），别乱设 |

⚠ 固件**从不擦除**旧像素，所以指示灯只能"加"不能"减"：开机默认已经画了一个
TC-off 图标，再喂 `ABS_off` 会变成两个图标叠加（且新图标被上边界裁掉）。
⇒ `dash_up.py` 默认**不喂**灯（`--lamps` 留空）；要喂就在进场动画**之后**喂一次。

### 42.8 环境温度字段

`vehicle_info2`（`0x2170951d`，24 B）字段偏移已用身份载荷全部确认：

```
[0..3] remaind_fuel   [4] gear   [8..11] remind_milage
[12..15] batt_12v_voltage   [16..19] ambTemperature
```

`ambTemperature` 喂 25（℃）**在 P 档主界面不上屏**（实车照底栏右侧有 `25℃`，
我们这边只出时钟）⇒ 该 widget 的显示条件还没解，prop 已经喂对了。

## 43. Flutter app 黑屏根因与修复：把 §41 链路搬进客户端（2026-11-05）

### 43.1 现象与根因

11-05 重建的 `ae5i_emu.app` 上电后画面依旧全黑，没有蓝绿背景墙 / 右侧大 P /
整车 / 进场动画。排查后确认**不是模型问题，也不是路径问题**（上一轮已修好
「找不到 QEMU」），而是 **app 里的 MCU 模拟从未升级到 §41 的逆向成果**：

| | `run_ui.sh` + `tools/dash_up.py`（已验收） | Flutter app（修复前） |
|---|---|---|
| CFCP 连接时机 | QEMU 起来即连 | 上电即连（仅 ACK，**不发数据**） |
| 数据启动时机 | 立即 pre-arm | **等用户手动解锁**才启动 |
| 发的帧 | KL15 / RTC / 解锁通知 / vi1 / vi2 / vi3 / batt / ODO / trip / 心跳 | 11-02 旧基线：版本 / 握手 / 能力 / 状态 / `0x21709702` / 心跳 / 灯态 |
| `KL15=0x99` | ✅ | ❌ → OSD 不点亮 |
| `synchronization_status` | ✅ | ❌ → `slot_delayUpdateGear` 在 `0xa46b6` 直接 return |
| `vehicle_info2.gear=1` | ✅ | ❌ → 场景机永远不去 `Animation_Pstart_init()` |
| 三段式进场 | ✅ | ❌ |

⇒ guest 属性表为空、App 停在黑屏 / 4.37% 非黑的待机统计页。源码注释当时甚至还
写着「上行车辆信号帧格式未解出」，而 §41 早已把它全解出来了 —— 典型的
「工具链成果没回流到产品代码」。

### 43.2 修复

新增 `flutter_app/lib/emu/dash_up.dart`（**纯 Dart、不依赖 Flutter**，便于 CI 验收），
把 `dash_up.py` 完整移植：

* `DashProp`：全部上行 prop id；
* `DashTelemetry`：**MCU 遥测数据源**，所有上屏数值的唯一真值源
  （默认 91% 电量 / 506.0 km / 28.7 Wh·km⁻¹ / 10.0 km / 3.5 Wh / ECO / P 挡 / 25℃），
  由固件自己的 widget 渲染，本项目不合成任何像素；
* 帧构造：`dashVi1Frame` / `dashVi2Frame` / `dashVi3Frame` / `dashBattFrame` /
  `dashSyncFrame` / `dashOdoFrame` / `dashTripFrame` / `dashRtcFrame` /
  `dashLampFrame` / `dashBootFrames` / `dashDataFrames` / `dashKeepFrames`；
* `DashUpFeeder`：`preArm → boot → unlock → settle(20 拍 gear=0) →
  enter(只写一次 gear=1) → hold(0.5 s 心跳 + 掉回待机自愈)` 状态机。

`flutter_app/lib/emu/controller.dart` 的接入点：

* `start()` 在 `_connectCfcpEarly()` 之后立刻 `_startDashUp()`，不再等用户解锁
  （真车 MCU 与仪表同电源上电）；
* 删掉旧 `_startGd32()` 基线帧与 1 Hz 旧心跳，避免两个数据源打架；
* `_fireWake()` 只保留「解锁时重放 bootloader logo」，**不重复发基线、不重写挡位**；
* ACK 改为直写 socket，**不排进 `_keyQueue`** —— 三段式进场会连续排几十帧数据，
  ACK 若排队尾会被延迟数秒，guest 内核重传 3 次后丢弃属性帧；
* `displayLit` 判定加入 `_clusterEntered`，让 UI 指示器诚实反映固件已点亮。

环境变量保持 `SP_IPC_MODE` 不设（模型默认 0 = 按来源路由，优于 `run_ui.sh` 的 2），
`SP_FB_NO_FLIPCOPY` 不设（§42 的翻页整页复制默认开启）。

### 43.3 验证

**帧字节一致性**：`tool/dash_up_check.dart --frames` 输出 18 帧 hex，与
`tools/dash_up.py` 同顺序输出 `diff` 为空（boot 8 帧 + sync + vi1 + vi2×2 + vi3 +
batt + odo + trip + 固定 RTC + lamp）。

**端到端**（纯 Dart 起 QEMU + `DashUpFeeder`，与 app 完全相同的 `LaunchSpec`）：

```
$ dart run tool/dash_up_check.dart --duration 90 --out /tmp/check.ppm
[12s] nonblack=59.61% teal=44.85%   ← enter 之后立刻进 P 档
[90s] nonblack=59.62% teal=44.86%
FINAL ... acks=128 rx=858 entered=true
RESULT PASS
```

90 秒全程稳定在 59.5% / 44.8%，与 §41.5 手动 `dash_up.py` 的验收值
（59.66~60.14% / 44.9~45.4%）一致，自愈未触发。导出帧人工核对：右侧茶青墙 +
巨大 P + 银灰整车 + 顶部斜向绿光条 + 左列四项数据（10.0 km / 3.5 Wh /
28.7 Wh·km⁻¹ / 506 km）+ 绿色地面 + 底栏（91% / 0km / 当前 RTC 时间），
**无花屏、无重影、无文字叠加**。数值全部来自 `DashTelemetry`，时间跟随宿主机。
验收帧：`artifacts/dash_app_pgear_verified.png`（模型导出的 PPM 仅做格式转换，
像素未改，仍是固件自己画出来的画面）。

进场动画采样（`enter` 后每 100 ms 的非黑占比）证明动画确实在播，不是直接
跳到静态终帧：

```
4.0 4.0 47.6 50.0 52.8 53.4 57.8 58.6 59.6 59.5 59.6 → 稳定 59.6
```

### 43.4 工具与遗留

* `flutter_app/tool/dash_up_check.dart`：`--frames` 字节回归 / 默认端到端验收 /
  `--duration` / `--out`；`enter` 阶段每 100 ms 采样非黑占比，用来确认
  `Animation_Pstart_init()` 的进场动画确实在播。
* 仍保留 `SP_WAKE_FILE` 门控：用户手动解锁时模型会插播一段 bootloader logo。
  它与 P 档进场动画是两套独立动画（前者模型重放、后者固件 Qt 场景机绘制），
  上电自动进场不依赖它；若要让两段严格串行，可把 `LaunchSpec.wakeFile` 置空
  改为上电即播 logo。
* §42.6 的 PFC/DOV 背景层、§42.7 指示灯默认不喂、§42.8 环境温度不上屏，
  这些已知限制不变。

## 44. 关机动画遮挡 / 电机控制器模拟 / 顶部黑条归因（2026-11-05 下午）

三条反馈：① 点「停止 / 下电」看不到关机动画；② 除上/下/SET/BACK 之外
的按键几乎无效，仪表没收到 TCS、车速、车辆档位等电控状态；③ 顶部有一条
方形黑色 —— 真车没接电机控制器时，那些 icon 位置应该是**透明的**。

### 44.1 关机动画：模型一直在播，是客户端遮挡

取证（单连接探针 + `SP_SHUTDOWN_WAKE_FILE` + `SP_SHUTDOWN_TRACE=1`）：

```
SHUTANIM: 1024x600 112 frames @ 60 fps (reverse) from .../anm_logo.bin
SHUTANIM: frame 0/112 … frame 111/112 … done, 112 frames (logo out)
painted: 58.30%（P 档）→ 11.01%（logo 可见）→ 0%（面板熄灭）
```

模型侧 `sp_shutdown_start()` / `sp_shutdown_tick()` 完全正常。真正原因是
`VehicleStateX.isAwake` 只含 `unlocked / ready`：一点下电就变 `poweringOff`，
`main.dart` 的画面组件立刻用 `_clusterStandby()` 盖住整个画面，一帧都看不见。

修法：

* `vehicle.dart`：`isAwake` 加入 `poweringOff`（logo-out 播完前面板仍亮）。
* `controller.dart`：新增 `shutdownAnimating`；把动画触发从
  `_sendShutdownCommand()`（要求 `_consoleReady`，而 `root@AE5I:/#` 只在启动
  早期出现一次、随后被 `_serialTail` 冲掉）里拆出来，改由
  `_gracefulShutdown()` 直接调 `_startShutdownAnimation()`：写触发文件 →
  置 `animating`（保持高频抓帧）→ 2.2 s 后才发 `poweroff -f`。
* `main.dart`：下电期间显示「关机动画 · 原厂 logo out」，不再盖画面。
* `tool/dash_up_check.dart --shutdown`：端到端采样 24 帧并纳入 `RESULT PASS`。

### 44.2 电机控制器（电控 MCU）模拟：补齐上行状态

用户澄清：「仪表没有收到仿真的电机控制器返回的任何车辆状态信息，例如
TCS 启用与否、车速、车辆档位等，因此没有显示对应 icon 所代表的状态」。

根因：`dash_up.py` / `dash_up.dart` 的 `indicator_lamp`（`0x2170951e`,
16 B）**默认整帧不喂**（旧注释「固件从不擦除旧像素，灯只能加不能减」），
`McuSim` 的把手按键也只改客户端状态、从不上行。

先用「单 bit 载荷 + 固件日志 diff」把 16 B 布局完整解出（108 个语义位 /
40 个字段，见 `tools/lamp_bits.py`）：

| 字节 | 字段（每字节 4 个 2-bit 字段，0=灭 / 1=亮 / 2=告警） |
|---|---|
| byte0..3 | **整字节数值**：`ABS_off` / `ABS_fault` / `camera` / **`TC`（TCS）** |
| byte4 | `OTA_not_regist` / `vin_not_write` / `sideStand` / `EV_READY` |
| byte5 | `auto_start_stop` / `engine_kill` / **`CruiseControl`** |
| byte9 | **`parking`** / `boosting` / `low_engline_oil` / `eps_fault` |
| byte11 | `pos_light` / `big_light` / **`turn_right` / `turn_left`** |
| byte12 | **`high_beam`** / `reverse_assist_power` / `promotion_assist` / `engine_fault` |
| 其余 | `charging` / `low_voltage` / `bsd_status` / `bluetooth_key` / `rcw_warn_status` … |

编码 `value << bit0`；byte15 未解出保持 0；`ABS_fault` 置位会弹故障框卡住
App，恒 0。

实现：

* 新增纯 Dart `MotorStatus`（`lib/emu/dash_up.dart`）与 Python 对等的
  `MotorStatus` / `LAMP_FIELDS`（`tools/dash_up.py`），逐字节一致。
* `dashLampFrame()` 改为**恒返回一帧**（默认 TCS 启用 + P 挡驻车），
  `dashKeepFrames()` 每 0.5 s 周期上报；进场动画结束后先补一拍。
* `DashUpFeeder.motorChanged()`：状态变化立即补一拍，不等心跳；**不写
  `vehicle_info2.gear`**（§41.4，反复写会让顶部 DRL/ECO 图标叠成双份）。
* 按键接线：转向/双闪 → `turn_left/right`；远光 → `high_beam` + `big_light`；
  定速 → `CruiseControl`；加/减档 → `vehicle_info3.drive_mode`
  (1=ECO / 2=STREET / 3=SPORT)；自定义键 → `TC`；整车 READY 状态机切换
  `EV_READY` / `parking`。客户端状态条新增 TCS / 模式 / 挡位 / 车速 / READY。
* 帧字节回归：Dart 与 Python 同序 **19 帧 `diff` 为空**；
  `test/dash_up_test.dart` 固化 16 B 布局、保持期恒上报、三段式进场三条红线；
  `test/vehicle_test.dart` 固化「poweringOff 期间面板仍可见」。

### 44.3 顶部方形黑条：透明处露出的是空的 PFC 背景层（未闭环）

用户定性为渲染问题：「对应 icon 的位置不是黑色，而是透明的」。取证：

| 证据 | 结果 |
|---|---|
| `monitor xp` 读 OSD 顶部像素 | `00 00 00 ff`（BGRA，**不透明**纯黑，alpha=255） |
| `SP_FB_BG_DUMP` 导 window1 / window2 | 两层 **0.00% 非黑**（全空） |
| `sp_fb_dump` 的 `SP_FB_COMPOSITE` 分支 | `(osdpx & 0x00ffffff) ? osdpx : bg[window1]`：纯黑被当作透明色键，回落到空背景层 ⇒ 仍是黑 |
| 逐个喂 `indicator_lamp` 40 字段 / gear 0..3 / speed 0..80 / drive_mode 0..3 / `EV_READY` | 顶部 y<90 非黑恒 **4.7%**，零变化 |
| 同期串口 | `切换挡位: 0` / `update_speed_data: 0, 0` / `slots_lamp_abs_off: 0` 均有 ⇒ **帧已被 handler 消费**，是 P 档场景没把状态 icon 画到屏幕 |

结论：那块黑不是「缺图标留下的空位」，而是 **OSD 透明色键下面没有背景
画面**。真机此处由 `libpfc_service` 的 `BackGroundFlipThread` 每帧把背景
位图贴到 PFC 背景层（window1）；仿真里这条链路正是 §42.6 记的
`PFC_DOV : get dov failed`（VPP/DOV 图层引擎未打通）。所以：

* 补电控状态**不能**让它消失（12 组组合实测顶部零变化），但状态链本身
  已按用户要求补齐（§44.2）；
* 按实车照重绘 / 离线合成是用户明令禁止的；
* 正解是打通 VPP/DOV 背景层，让固件自己的背景位图出现在 window1，
  「透明」才有东西可露。**这是当前唯一剩下的硬限制**。

下一步两条路（需用户定夺）：① 在模型里建最小 VPP 显示层，正确应答
`id=0x17` DOV 查询并转发 `PfcDispServer` 回包给 waiter；② 经用户同意，
把 `libdashclustoractivity.so` 内 1024×600 的 P 档底图**原样**（不重绘、
不合成、像素不改）喂给 window1 作为过渡。

### 44.4 验收（2026-11-05）

| 项 | 结果 |
|---|---|
| `dart analyze lib tool test` | 无问题 |
| `flutter test`（6 套件） | 66 项全通过 |
| Dart / Python 帧字节 | 19 帧 `diff` 为空 |
| 端到端 `--duration 25 --shutdown` | 非黑 **59.45%** / 茶青 **44.76%**，`entered=true`；进场动画 `4.0→47.0→…→59.6%`；关机动画 `10.9→12.1→1.3→0.0%`（`SHUTANIM VISIBLE`）；`RESULT PASS` |
| Release app | 重新构建，见 `flutter_app/build/macos/Build/Products/Release/ae5i_emu.app` |

---

## 45. PFC 背景色平面尝试失败 —— 已完整回滚（2026-11-05 晚）

18:38 提交 `f16b6da` 试图用「PFC 显示控制器背景色平面」消除顶部黑条：
window1 为空时，用 guest 自己 OSD 暗色像素的均值填一层平坦底色。
**用户实测判定失败**：黑条没消掉，且整幅背景对比度失真（茶青墙与左侧
深绿底被压暗、中部出现更黑的矩形分界）。已 `git revert` 完整回滚，
模型源码与二进制回到 `d1c08eb` 状态，`--duration 20 --shutdown` 复验
非黑 **59.46%** / 茶青 **44.76%**、`RESULT PASS`，与 §44.4 基线一致。

### 45.1 ★ 更正：本轮「DOV 与背景层无关」的归因是错的

`f16b6da` 曾断言 `PFC_DOV : get dov failed` 只是 `getBTMAC()` 拼 WiFi 名
（`ZEEHO-b5aa15`）时的良性日志，与显示层无关。**该结论片面，作废**：
`libspdovcfg.so` 内部导出的调用者确实只有 `getBTMAC` / `getSwingLevel` /
`getUniqueKey`，但外部（`PfcDispServer` 侧）还会用
**`subcmd=0x54e1`** 调 `dov_send_cmd()` 查询 **DOV 图层配置**，这才是
`PfcDispServer` 拿到 `get_bg_info Background W/H: 1024/600` 之后卡住的那一步。

用户确认的链路与判据（恢复 §42.6 / `run_ui.sh` 注释的原始结论）：

```
PfcDispServer 在跑 → get_bg_info 1024/600 成功
  → IPC id=0x17, len=14, subcmd=0x54e1 查 DOV 图层配置
  → dov_send_cmd() 收包后读 msg+0xc，非 0 判失败
  → "PFC_DoV : get dov failed" ⇒ 图层配置不生效 ⇒ 背景层空
```

模型当前**只能伪造回包**（`reply[3]=0; reply[4]=0`），让状态字看起来成功，
但 daemon 从未参与、图层参数仍是空的。真正需要的是
**「转发请求 → 等 daemon 回包 → 按 dword2 bit15 送回原 waiter」** 的双向事务。

### 45.2 已验证的路由约束（不要再试全局切换）

| 实验 | 结果 |
|---|---|
| `SP_IPC_MODE=1`（只回用户态） | `get dov failed` 次数 **3 → 1**，说明有一个 DOV 请求确实被 daemon 接走处理了 |
| 同上 | 但 `id=3`（`fbdss` 取 UI 分辨率）是**内核侧 `IPC_FunctionCall` 等待者**，只回用户态 → 永不唤醒 → 串口刷 `RPC SERVER #7 NOT RUNNING!`，整个显示栈停摆、CFCP 停发 |
| `SP_IPC_MODE=2`（内核回包 + 延迟用户态副本） | 显示栈能起来，但 DOV 仍是伪造应答，背景层不通 |

⇒ 正解必须**按 id 分流**：`id=3/2/6/9` 保持内核等待者（bit15=1）；
`id=0x17` 单独做「转发给 daemon → 收回包 → 按 bit15 送回 waiter」事务，
并带超时兜底，避免 daemon 不回时卡死。**不能**用全局 `SP_IPC_MODE` 一刀切。

### 45.3 当前状态

渲染已回滚到 §44 验收版；顶部黑条与 PFC/DOV 背景层**仍未解决**，
按路径 1 继续（见 §42.6、§44.3、`run_ui.sh` 注释）。
本轮 `libspdovcfg.so` / `libpfc_service.so` / `pfc_server` 已从 SPVD 的
`spsdk` 分区（squashfs @0x1181000）解出至 `/tmp/ae5i_spsdk_root`，
供后续反汇编 `subcmd=0x54e1` 的调用点使用。
