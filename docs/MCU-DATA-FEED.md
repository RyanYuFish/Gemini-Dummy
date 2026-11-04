# 仪表数据模拟（MCU→仪表回馈）工作进度

> 最后更新：2026-11-03 04:58。给下一次接手用，只写「事实 / 已排除 / 下一步」。
> 细节与推导过程在 `docs/EMULATION.md §35–§38`。

## 一句话状态（2026-11-04 更新）

**★ 已闭环「脱离待机」：CFCP 对端必须 ACK 每一帧，否则 guest 内核 `cfcp_ack_q_work_handl`
重传 3 次丢弃 → 应用层拿不到属性 → 集群永远 LINE_DISCONNECT/待机页。**
修法：`tools/feed_render_frames.py` 收到 guest 帧即回静态 ACK（`fe5a aa a5 90 08 55 01 01 00
00 00 10 a5 55 5a`），并按 `KL15=0x99`(`0x21400030`)+`vehicle_info1`(`0x21707402`) 喂上行。
跑一次集群即点亮、状态栏（0km/电池/时间/「按SET查看详情」）渲染且状态持久。

**未解（下一棒）**：主显示区噪声 = PFC 背景层缺素材（§34）；主表盘图形受场景状态机约束
（§39.8，停在 DASH / 舞台 opacity=0）。这两块与「待机」是不同问题，别再当 ACK/链路问题查。

## 1. 已确认的事实（均有实测证据）

### 1.1 总线拓扑（维修手册针脚表，见 §35）

| 节点 | 接口 | 依据 |
|---|---|---|
| 仪表 DASH | RS-485 A/B(PIN17/18) + CAN-H/L(36/37) + 一线通(32) | 5.13 |
| 电机控制器 MCU | 只有 RS-485（16PIN-7 `485B/RX`、15 `485A/TX`） | 5.12.1 |
| T-BOX | 只有 RS-485（PIN4/9）+ 硬线唤醒 | 5.10 |
| BRS 雷达 | 与仪表/MCU/T-BOX 同一条 485 | 5.16.4 E311/E312/E313 |
| BMS / ABS | CAN 侧 | 5.16.2 / 5.16.5 |

结论：**T-BOX 与 MCU 都没有 CAN**；仪表/MCU/T-BOX/BRS 共用一对 485 多机总线。
主表盘的车速数据源只能是电机控制器。

### 1.2 SoC 侧只有 CFCP

* `rcar_taurus_cfcp.ko` → `cfcp_device_uart_open /dev/ttyS1`，**baud 115200**，协议 `MMI2.0`。
* guest 内**没有 CAN 驱动、也没有 485 驱动**；模型 `sunplus-sp8368.c` 全文无 CAN。
* 所以「模拟电机控制器」在工程上 = **让客户端（扮演 GD32）产出上行 CFCP 帧**。

### 1.3 上行载荷语义（§36 / §38.5）

```
DATA = 若干元素，元素 = { u16 payload_len (LE, 不含本头) ; payload[payload_len] }
payload = { u32 prop ; u32 areaId ; RawValue }
```

即 Android 式 `VehiclePropValue`，`CfcpControl::setValue(const VehiclePropValue&)`
在 `libapis.so @0x56da5`。旧笔记写的 "vhal_frame_len/pid/aid" 是误读。

### 1.4 记录帧（§36.3）

* `mcucom_rx_ride_info_update(u8,u8,u8,u8*,u16) @0x397c5`（**Thumb**，1448 B）。
* 自己就是 TLV walker：**BE u16 标签** + 数据；`0xCF01` → 拷 **33 B**，步进 **35**。
* 目的槽由第 2 个 u8 选：`3` → `this+0x270`，`4` → `this+0x2c8`。
* `mcucom_get_ride_info_record @0x26126` 从 `this+0x26c` 拷 `0x4d4`。

### 1.5 数据确实能到 App（§38.2）

发一帧后 dump 客端 RAM，能在 App 的收帧缓冲里看到完整帧：

```
55a5555a | fe5aaaa5 | 11 02 75 01 01 00 | 2d00 | 2b00 | 03 93 70 21 | 00000000 | cf01 …
```

## 2. 已排除（别再试）

| 结论 | 证据 |
|---|---|
| `setItem3` / `setItem4` 只**缓存**不解析 | 3 处稳定地址都是 `CF01+33B` 原样副本；0x10/0x20 A-B 差分**无任何派生值** |
| 84 组 (FRAME0 × 命令字 × 载荷) 全部不到 handler | 唯一标记字节 + 「33 字节无 CF01 前缀」签名，命中 **0** |
| ACK 不能当属性级 oracle | 伪造 prop `0x21709999` 一样回 ACK |
| **属性通道不驱动主表盘** | §29 实测 11 属性 × sub 0..4 共 55 组，framebuffer 变化恒 0 |
| `ride-info` 不是车速来源 | 入参是裸指针，只用于行程统计（单次里程/电耗） |

## 3. 工具速查

| 工具 | 用途 |
|---|---|
| `tools/vhal_probe.py` | 发 CFCP 帧 + 听回包（ACK / 属性广播）+ 抓内核日志。`identity`/`hex`/`elem`/`listen` |
| `tools/guest_mem.py` | monitor `pmemsave` 按需 dump **256 MiB / 0.9 s**；`dump`/`find`/`diff`/`hexdump` |
| `tools/arm_disasm.py` | capstone 反汇编 32 位 ARM ELF；`--list <关键字>` / `--callers` / `--scan <文本>` |
| `tools/mcufeed_sweep.py` | 组合批量发 + 「RAM 签名」判定是否被真正解析 |

三个坑（都踩过）：

1. `pmemsave` 的**文件名必须加引号**，否则报 `invalid char 't' in expression`。
2. **Thumb 判定用 `st_value & 1`**，`st_info` 不可靠。
3. 导出符号的模块内调用走 **PLT 桩**，`--callers` 按函数地址找不到；用 `--scan` 找常量更有效。
4. 长时间反复 connect/disconnect 会让 chardev 丢包 ⇒ **一个连接里做完所有发帧**。

## 4. 典型操作序列

```bash
# 1) 起仿真器（带 CFCP socket 9123 + monitor socket）
bash /tmp/run_ui.sh          # 或参考 §38 的 launch 参数

# 2) 探一帧并听回包
python3 Gemini-Dummy/tools/vhal_probe.py hex "0A00 02977021 00000000 0800" --seconds 3

# 3) 取客端内存快照并搜标记
python3 Gemini-Dummy/tools/guest_mem.py dump
python3 Gemini-Dummy/tools/guest_mem.py find 58083EDB6198F0D0D9A852D8DE9C32B1

# 4) 反汇编 guest 自己的实现
python3 Gemini-Dummy/tools/arm_disasm.py \
  /tmp/ae5i_spapp/root/lib/module/default/libmcucommodule.so \
  mcucom_rx_vehicle_info1_handle --n 120
```

## 5. 下一步（按优先级）

1. **反汇编 `mcucom_rx_vehicle_info1_handle @0x2aba5`**（952 B，Thumb），读出它解析的
   字节偏移 —— 车速/档位很可能在这里。同族还有 `vehicle_info3 @0x2af5d`（1832 B，
   最大，可能信息最全）与 `vehicle_info2 @0x2b801`（948 B）。
2. **定位 prop id**：`CfcpControl::setValue` 前 300 条指令几乎全是日志；需要顺着它调用的
   PLT 桩（`0x43500` 等）继续跟进，或用 `--scan` 找 `movw #0x……` 的 id 常量。
3. **检查前置门禁**：启动日志有 `GetECActivieState: -3`（EC 状态未知）。若 App 在 EC
   未初始化前丢弃车辆数据，需先喂 `KL15_STATE_handle(int)` / `vehicle_info` 建链。
4. 打通后按 `mcucom_rx_*` 逐个补齐：`power_battery`（电量）、`trip_1/2`（里程）、
   `indicator_lamp`（指示灯）。

## 6. 关键地址速查

| 符号 | 地址 | 备注 |
|---|---|---|
| `mcucom_rx_ride_info_update` | `0x397c5` | Thumb，TLV walker，0xCF01→33B |
| `mcucom_rx_vehicle_info1_handle` | `0x2aba5` | Thumb，`vector<u8>` |
| `mcucom_rx_vehicle_info2_handle` | `0x2b801` | Thumb |
| `mcucom_rx_vehicle_info3_handle` | `0x2af5d` | Thumb，最大 |
| `mcucom_rx_power_battery_handle` | `0x2bbb5` | Thumb |
| `mcucom_rx_KL15_STATE_handle` | `0x300a5` | Thumb，`int` |
| `mcucom_rx_indicator_lamp_handle` | `0x3b391` | Thumb，8532 B |
| `mcucom_get_ride_info_record` | `0x26126` | 从 `this+0x26c` 拷 `0x4d4` |
| `CfcpControl::setValue` | `libapis 0x56da5` | 接收侧分发器 |

---

## 相关文档

* `docs/EMULATION.md §35` 总线拓扑与「先做电机控制器」的决策依据
* `docs/EMULATION.md §36` 上行 vhal 信封的解法（含 oracle 方法论）
* `docs/EMULATION.md §38` 本轮实测：ride-info 全否 + 方向纠正 + 工具
* `docs/EMULATION.md §37` 总体目标修订（全功能仿真 → 自制 Qt 固件 → OTA）
