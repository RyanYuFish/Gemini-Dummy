#!/bin/bash
# Launch the AE5I instrument-cluster emulator (sunplus-sp8368) and export the
# composited framebuffer to /tmp/ui-frame.ppm.  CFCP MCU peer talks to the
# guest over 127.0.0.1:9123 (see tools/feed_render_frames.py).
set -u
LAB=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
QEMU=$LAB/qemu-src/build/qemu-system-arm
KERNEL=$LAB/images/kernel-ae5i.bin
SPVD=$LAB/images/ae5i.spvd
APPEND='console=ttyS0,921600 loglevel=7 panic=1 mtdparts=sp_spinand.0:0x40000(nand_header),0x40000(xboot1),0xc0000(uboot1),0x1c0000(uboot2),0x80000(env),0x80000(env_redund),0x400000(ecos),0x480000(kernel),0x480000(rootfs.),0x80000(opt.),0x3000000(spsdk.),0x4040000(spapp.),0x1000000(nvm),0x40000(pq),0x40000(tcon),0x40000(iop_car),0x40000(vi),0x980000(isp_logo),0x40000(vendordata),0xbc0000(pat_logo),0x40000(version_info),0x40000(vd_restore),0x1000000(anm_logo),0x15540000(userdata) res_chunkmem=0x04000000@0x0C000000 res_fb0=0x00600000@0x0C000000 res_fb1=0x00600000@0x0C600000 res_fb2=0x00600000@0x0CC00000'
rm -f /tmp/ui-frame.ppm /tmp/ui-qemu.log /tmp/ui-serial.log /tmp/ui-mon.sock
export SP_IPC_STUB=1 SP_FB_MULTI=1 SP_FB_COMPOSITE=1
export SP_FB_FRAME=/tmp/ui-frame.ppm
# Diagnostics: trace the firmware's own PFC background / DMIX layer programming
# and answer its userspace IPC (pfc_server) so it can configure the layers.
#
# SP_IPC_MODE=2 = 内核回包 + 稍后补一份用户态副本。
#   ★ 别改成 1（只回用户态）：id=3（fbdss 取 UI 分辨率）用的是内核侧
#   IPC_FunctionCall 等待者，只回用户态会让它永远等不到 → 整个显示栈停摆
#   （串口刷 "RPC SERVER #7 NOT RUNNING!"），CFCP 也不再发帧。
#   id=23(0x17)=DOV 查询现在由模型**按 id 分流**转发给 PfcDispServer：
#   先写 bit15=0 的请求副本（内核路由到用户态 fifo），100us 后再写
#   bit15=1 的应答唤醒原 waiter。其它 id 一律保持内核回包，所以不会
#   饿死 id=3。开关 SP_IPC_IDROUTE=0 关闭 / =2 实验性 hold（会卡启动，
#   不要用）；SP_IPC_DOV_KEEPSEQ=0 可回退旧的清 seq 行为。见 §46。
#   已知：daemon 回包不经 doorbell，"get dov failed" 仍有 3 次；
#   DOV 图层配置 / 顶部黑条仍未闭环。
export SP_PFC_TRACE=1 SP_IPC_MODE=2
export SP_VDISK=$SPVD SP_VDISK_BASE=0x50000000
exec "$QEMU" -M sunplus-sp8368 -m 256 -kernel "$KERNEL" -append "$APPEND" \
  -serial file:/tmp/ui-serial.log \
  -chardev socket,id=cfcp,host=127.0.0.1,port=9123,server=on,wait=off \
  -serial chardev:cfcp \
  -monitor unix:/tmp/ui-mon.sock,server,nowait \
  -display none -no-reboot 2>/tmp/ui-qemu.log
