# 内核显示栈逆向（AE5I GEMINI, Linux 4.9.217）

> 目的：让仿真器**用固件自己的实现**把 P 档主界面画出来（背景层/遮罩层/车辆层），不重绘。
> 本文件记录内核侧（kernel-ae5i.bin）逆向到的方法与结论。宿主侧见 `EMULATION.md §40/§41`。

## 1. 还原带符号的内核 ELF（关键使能）

`Gemini-Dummy/images/kernel-ae5i.bin` 是 **uImage（64 B 头，body @0x40），原始未压缩 Image，ARMv7 thumb2**。

```bash
python3 -c "d=open('Gemini-Dummy/images/kernel-ae5i.bin','rb').read();open('/tmp/ae5i_body.bin','wb').write(d[0x40:])"
python3 -m vmlinux_to_elf.scripts.vmlinux_to_elf --e-machine 40 --bit-size 32 \
        /tmp/ae5i_body.bin /tmp/ae5i_vmlinux.elf
# -> base 0xc0408000, 19766 个符号（含函数名）
```
坑：`HOME=/tmp` 会把 user site-packages 挪走导致 `ModuleNotFoundError`，装好后别改 HOME。

## 2. 反汇编（VA→file 映射）

`arm_disasm.py` 假设 VA==file_off，对内核 ELF 不成立。用 `tools/kdis.py`（按 PT_LOAD 映射）：
```bash
python3 Gemini-Dummy/tools/kdis.py /tmp/ae5i_vmlinux.elf rpc_isr --n 120       # Thumb
python3 Gemini-Dummy/tools/kdis.py /tmp/ae5i_vmlinux.elf 0xc0418b14 --n 80
```

## 3. IPC 契约（已完全解出）

| 符号 | 地址 | 作用 |
|---|---|---|
| `rpc_isr` | `0xc0418b14` | 收包分发：读 `io(0x9c008190)` 80B 应答块 |
| `IPC_FunctionCall` | `0xc0418070` | 内核同步调用（发→等→返回） |
| `rpc_fifo_get/put` | `0xc04175e8/0xc0417bd0` | 用户态 fifo |
| `sp_ipc_read/write` | `0xc04189ec/0xc0418520` | 用户态读写 |

**`rpc_isr` 路由**（读应答块 `sp+0xb` = dword2 最高字节）：
- **bit7=1（dword2 bit15=1）→ 内核分支**：`rpc_copy(msg, block)` 把应答块拷进 waiter 的 msg，
  置 `[msg+0x54]=1` 并 wake。**IPC_FunctionCall 的 waiter 只认这条。**
- bit7=0 → 用户态：`chan=(id>>9)&3`，fifo 基址 `[0xc08382f8] + (chan+0x16a/0x156)*4`；无 waiter 返回 1。

**`IPC_FunctionCall` 返回**：
- 请求 id-word（`msg+0xa`）= `(cmd & 0xFFF) | 原 bit12`（cmd=0x17 → 0x0017，**bit15=0**）。
- 发送后等 `[msg+0x54]`；**返回值 = 应答块 `msg+0xa` & 0xFFF，≥0x200 则减 0x400（负 errno）**。
  ⇒ 应答块 dword2 高半必须是 `0x8000`（内核分支+状态0）→ 返回 0。

**结论**：模型对 `id=23(0x17)/9` 必须回**内核分支**（dword2 高半 0x8000）。模型已加 `id==0x17/9`
进 req_kernel；`PFC_DOV: get dov failed` 由 **3 次降到 1 次**（剩 1 次是开机早期，属可容忍重试）。

## 4. 显示管线（内核符号）

| 符号 | 地址 | 作用 |
|---|---|---|
| `psu_display_vpp` | `0xc041be48` | VPP 配置，写**软件结构** `0xc080814c`（非硬件寄存器） |
| `psu_display_osd0/1/2_mode` | `0xc041bc40/bc60/bc80` | OSD 0/1/2 层 |
| `psu_display_tgen0/1/2_dmix0/1/2_mode` | `0xc041bcbc/bcd8/bcf4` | **DMIX 显示混合器** |
| `psu_display_tcon_mode` | `0xc041bd2c` | TCON |
| `psu_system_ipc` / `psu_system_ipc_mode` | `0xc041b048/0xc041ad0c` | PSU 系统 IPC（真正下发硬件） |

**图层 ↔ framebuffer**：OSD0/1/2 = 模型 res_fb0/1/2（window 0/1/2）。DMIX 按层混合输出到 TCON。
实车分层（用户实测）：背景(含顶部光条)=背景层、P 后半透明遮罩=第二层、车辆=更高层。

## 5. 当前阻塞 / 下一步

- **硬阻塞**：`window 1/2 一个像素都没写`（frame 仍 ~4.38% 非黑）。即固件**没往 OSD1/2 画内容**——
  不是合成丢层，是内容没产生。`id=9` 只写控制寄存器 `0x41e5fff8/0x41e614c0`(0x0e/0x38/0x3a)，
  **从不写图层源地址**；图层像素走 `psu_system_ipc` 真正下发的 VPP/DMIX 源，模型未仿真那一段。
- **下一步**：
  1. 逆 `psu_system_ipc`(0xc041b048) 看它如何把 `psu_display_*` 的软件结构下发到 VPP/DMIX 寄存器
     （源地址/步长/格式/alpha 在哪个偏移）。
  2. 模型里补 VPP/DMIX：把固件下发的源缓冲映射到 window1/2，并按层 alpha 合成。
  3. 验证：win1/2 非黑、`get dov failed` 归零、画面出背景+光条+大P+车辆。
- 备选加速：实车抓一段上电时的 IPC/CFCP（能直接给出源地址/格式真值）。
