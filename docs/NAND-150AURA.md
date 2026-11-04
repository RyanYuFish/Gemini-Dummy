# 150Aura NAND 规格与真机启动基准

> 全部数据来自本机 dump（`rawimage/春风150aura XT26G04C(x1+ISP)@WSON8(8x6mm).BIN`，570,425,344 B）
> 与其 **userdata 分区里保存的真车启动日志**（`0x0B760000` 起）。不是推测。

---

## 1. 介质与几何

| 项 | 值 | 来源 |
|---|---|---|
| 芯片 | XTX XT26G04C（Manufacturer 0x0b / Chip 0x13） | 内核日志 |
| 容量 | 512 MiB SLC | 内核日志 |
| page / OOB（内核口径） | 4096 / **128** | `nand: 512 MiB, SLC, erase size: 256 KiB, page size: 4096, OOB size: 128` |
| page / OOB（dump 口径） | 4096 / **256**（4352 B/帧） | 文件大小 570,425,344 = 131072 × 4352 |
| 块 | 64 页 = 256 KiB；2048 块 | 由上推得 |
| 坏块 | `383, 716, 1049, 1382, 1715` | 日志 `nand_read_bbt: bad block at 0x…` ÷ 0x40000 |

> dump 的 OOB 是硬件 spare 区 256 B；驱动只用其中 128 B 做 ECC。**扁平数据（去 OOB）两边一致**，
> 所以 SPVD 的去 OOB 视图可直接与内核的分区偏移对齐。

## 2. 分区表（25 项，cmdlinepart）

来源：日志 `Creating 25 MTD partitions on "sp_spinand.0"`。地址为**扁平字节偏移**（已去 OOB），
因此与 SPVD 数据窗一一对应。`kernel` 起是 `blockromN` 对应的 squashfs/yaffs。

| # | 名称 | 起始 | 大小 | 内容 |
|---|---|---|---|---|
| 0 | nand_header | `0x00000000` | 256 K | 引导头 |
| 1 | xboot1 | `0x00040000` | 256 K | 一级引导 |
| 2 | uboot1 | `0x00080000` | 768 K | U-Boot 主 |
| 3 | uboot2 | `0x00140000` | 1792 K | U-Boot 备 |
| 4 | env | `0x00300000` | 512 K | U-Boot 环境 |
| 5 | env_redund | `0x00380000` | 512 K | 环境备份 |
| 6 | ecos | `0x00400000` | 4 M | eCos 协核固件 |
| 7 | **kernel** | `0x00800000` | 4.5 M | uImage（payload 0x42E000） |
| 8 | rootfs. | `0x00C80000` | 4.5 M | squashfs → blockrom8 |
| 9 | opt. | `0x01100000` | 512 K | → blockrom9 |
| 10 | spsdk. | `0x01180000` | 48 M | squashfs → blockrom10 |
| 11 | spapp. | `0x04180000` | 64 M | squashfs → blockrom11（含 1 坏块） |
| 12 | nvm | `0x081C0000` | 16 M | yaffs（mtdblock12） |
| 13 | pq | `0x091C0000` | 256 K | 画质参数 |
| 14 | tcon | `0x09200000` | 256 K | 时序参数 |
| 15 | iop_car | `0x09240000` | 256 K | IOP 车载参数 |
| 16 | **runtime_cfg** | `0x09280000` | 1 M | **PART 容器**（见 §3） |
| 17 | vi | `0x09380000` | 256 K | 视频输入参数 |
| 18 | isp_logo | `0x093C0000` | 9.5 M | 开机 logo |
| 19 | vendordata | `0x09D40000` | 256 K | 厂商数据（mtd19） |
| 20 | pat_logo | `0x09D80000` | 11.75 M | 产测 logo |
| 21 | version_info | `0x0A940000` | 256 K | 版本串（文本） |
| 22 | vd_restore | `0x0A980000` | 256 K | 厂商数据备份 |
| 23 | anm_logo | `0x0A9C0000` | 1 M | 动画 logo |
| 24 | userdata | `0x0AAC0000` | 341 M | yaffs（mtdblock24，含真车日志） |

## 3. runtime_cfg 是 PART 容器（不是裸文本）

`0x09280000` 处布局（小端）：

```
0x000  "PART"           magic
0x004  u32 0x00003990   容器总长（最后一个 blob 的 end）
0x008  u32 0x00000010   目录偏移
0x00C  u32 0x000000E0   目录长度（224 = 7 × 32）
0x010  目录项 × 7，每项 32 B： char name[24] + u32 size + u32 offset
0x0F0  blob 区
```

目录实测：

| 名称 | size | offset |
|---|---|---|
| runtime.cfg | 0x98B (2443) | 0x0F0 |
| MP_EXTEN.bin | 0xA00 | 0xA80 |
| ITU_EXTEN.bin | 0xA00 | 0x1480 |
| MP.bin | 0x128 | 0x1E80 |
| ITU.bin | 0x128 | 0x1FB0 |
| DPS.bin | 0x10A4 | 0x20E0 |
| vendordata.bin | 0x800 | 0x3190 |

`runtime.cfg` 本体是文本：`##runtime.cfg##` 头 + `key=value`，共 2443 字节，
含 `uadma1_port` / `bt_uart_port` / `pmUA0_TXD` / `pmSPI_NAND` / `UI_width` 等 130+ 项。
已导出为 `Gemini-Dummy/firmware/runtime.cfg`；整包导出为 `Gemini-Dummy/firmware/runtime_part.bin`。

### 内核侧期望

`arch/arm/mach-gemini/sp_vendor_data.c` 的 `sp_config_init()`（`0xC04196E8`）：

```asm
movw r2,#0x56c0 / movt r2,#0xc080   ; cfg_ptr
movw r3,#0x56c4 / movt r3,#0xc080   ; cfg_len
ldr  r1,[r2] ; ldr r0,[r3]          ; (ptr, len)
bl   0xC0413110                     ; 经 [0xC08054BC] 的函数指针分发
cbnz r0, +                         ; 成功则用返回值
mov  r0,#0xC7000000                 ; 失败则回落到线性映射 0x07000000
str  r0,[0xC08362FC]                ; cfg_base，供 sp_config_get_* 使用
```

`.data` 里这两个全局的初值是 **`0x07000000` / `0x98B`** —— 即引导程序应把
`runtime.cfg` 的 2443 字节放到物理 `0x07000000`。

### 实测结果（尚未成功）

| 注入内容 | 大小 | 结果 |
|---|---|---|
| 空 | — | `sp_config_init() failed` |
| `runtime.cfg` 文本 | 2443 | 仍 failed（注入内容在内存中确认存活） |
| `runtime_part.bin`（PART 容器） | 14736 | 仍 failed |

⇒ 失败点在 `0xC0413110` 的分发目标（`[0xC08054BC]` 处的函数指针）内部，
与注入地址无关。**下一步**：读 `0xC08054BC` 的安装者，确认它要的是
「PART 容器 / 裸文本 / 另一层封装」，以及是否还要求 CRC 或长度头。

## 4. SPI-NAND 控制器（M2 建模目标）

日志原文：

```
[SPI-NAND] sp_spinand_probe in
[SPI-NAND] regs   = 0xf0802b80@0x9c002b80, size = 84
[SPI-NAND] buffer = 0xc7844000@0x07844000, size = 4608
[SPI-NAND] irq    = 55
[SPI-NAND] rts    = 1
[SPI-NAND] rndbadtest = 0
```

| 项 | 值 | 说明 |
|---|---|---|
| 寄存器窗 | `0x9C002B80`，84 B（0x54） | 在 PSU 块（`0x9C000000`）内，与 UART0 一样需以 subregion 叠加 |
| DMA 缓冲 | 物理 `0x07844000`，4608 B | 4096 数据 + 512 spare；平坦区，模型侧无需特殊处理 |
| IRQ | 55 | GIC SPI 55 |
| MTD 名 | `sp_spinand.0` | 分区全部来自 cmdlinepart |

驱动符号：`sp_spinand_probe/cmdfunc/cmd_ctrl/read_buf/write_buf/read_page/
write_page/waitfunc/dev_ready/select_chip/config_dev/suspend/resume`。

## 5. 真机启动基准（对照用）

`Gemini-Dummy/logs/vehicle-boot-150aura.log` 是本机 dump 里提取的真车日志片段。关键序列：

```
0.294  [SPI-NAND] sp_spinand_probe in
0.297  nand: XTX XT26G04C, 512 MiB, SLC, page 4096, OOB 128
0.299  Bad block table found at page 131008 / 130944
0.303  25 cmdlinepart partitions found
0.365  [SPI-NAND] regs/buffer/irq 打印
0.368  CFCP_KEY:cfcp_keypad_init → cfcp_keypad_probe success
0.371  K_TTYS: sunplus_uart_ops_startup, empty the data in rx fifo
0.373  VFS: Mounted root (squashfs) readonly on device 258:8
0.441  yaffs mount mtdblock12 / mtdblock24
1.50   [CFCP] open /dev/ttyS1 @115200
```

## 6. 当前仿真卡点（2026-10-30 实测）

- 内核跑到 `0.121s`，最后一条日志是 `ipc:1.6`；此后无任何 printk。
- CPU 停在 `cpu_ca15_do_idle`（`dsb; wfi; bx lr`）→ **不是死循环，是 init 线程睡住**。
- `SP_PSU_TRACE=1` 下 **零** PSU 访问；`-d unimp,guest_errors` 只有一条
  `Invalid read at 0xA0CA00BC` → SPI-NAND 驱动**尚未开始 probe**。
- ⇒ 卡点在 `ipc:1.6` 之后的某个 initcall，最可能是 **EIPC 与 eCos 协核的握手**
  （本机没有第二核，握手永不返回）。这是 M2 之前必须先解决的一层。
