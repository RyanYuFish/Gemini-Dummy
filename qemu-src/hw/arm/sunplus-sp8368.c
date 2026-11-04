/*
 * Sunplus SP8368 / GEMINI (CFMoto AE5i / 150Aura dashboard) machine model.
 *
 * Built so the ORIGINAL Linux-4.9.217 BSP image can boot: that kernel has no
 * device tree, no virtio, no 8250/pl011. It links at physical 0x408000 (DRAM
 * base 0x0) and only knows Sunplus K_TTYS UART + blockrom. See
 * Gemini-Dummy/docs/SUNPLUS-MEMMAP.md for the reverse-engineered memory map.
 *
 * M1 scope: RAM, GIC-400, ARM generic timer @27MHz, four K_TTYS UARTs, and an
 * ATAGS boot with machine id 0x0F34 ("GEMINI"). Goal is early console output;
 * PSU/clock and blockrom come in later milestones.
 *
 * This code is licensed under the GPL.
 */

#include "qemu/osdep.h"
#include "qapi/error.h"
#include "qemu/module.h"
#include "qemu/units.h"
#include "hw/boards.h"
#include "hw/arm/boot.h"
#include "hw/sysbus.h"
#include "hw/irq.h"
#include "hw/qdev-properties.h"
#include "hw/qdev-properties-system.h"
#include "hw/char/serial.h"
#include "hw/misc/unimp.h"
#include "hw/intc/arm_gic.h"
#include "chardev/char-fe.h"
#include "sysemu/sysemu.h"
#include "exec/address-spaces.h"
#include "cpu.h"
#include "target/arm/cpu-qom.h"
#include "target/arm/gtimer.h"

#include <sys/mman.h>
#include <sys/stat.h>
#include <fcntl.h>

/* ------------------------------------------------------------------ K_TTYS UART */

#define TYPE_SP_UART "sunplus-k-ttys-uart"
OBJECT_DECLARE_SIMPLE_TYPE(SPUartState, SP_UART)

struct SPUartState {
    SysBusDevice parent_obj;

    MemoryRegion iomem;
    CharBackend chr;
    qemu_irq irq;

    uint32_t regs[0x20];
    uint32_t idx;               /* UART index, only for the trace */
    bool trace;                 /* SP_UART_TRACE=1 */

    /* Received bytes waiting to be picked up by the driver. */
    uint8_t rx[256];
    unsigned rx_head, rx_tail;
};

#define SP_UART_RX_SIZE (sizeof(((SPUartState *)0)->rx))

/* K_TTYS register semantics from sunplus_uart_console_putchar():
 *   +0x00  TX data (write a byte)
 *   +0x04  LSR (bit0 = TX ready; the console spins until it is set)
 *   +0x1c  IER, bit4 = "TX empty" interrupt enable   (see below)
 * Everything else is shadowed so reads return sane data instead of 0xFF.
 *
 * ---------------------------------------------------------------------------
 * Why +0x1c bit4 has to drive the interrupt line.
 *
 * printk works without any of this because sunplus_uart_console_putchar()
 * (0xC056768C) polls LSR bit0 and writes +0x00 by hand.  The *normal* tty
 * write path does not: sunplus_uart_ops_start_tx() (0xC0566BB4) only ORs 0x10
 * into [membase+0x1c] and returns -- the byte is pushed by the interrupt
 * handler.  sunplus_uart_irq() (0xC05676C4) transmits in a loop guarded by
 *
 *   0xC056776E  ldr r0,[r2,#0x1c]; lsls r0,#0x1b; bpl <out>   ; bit4 still set?
 *   0xC0567774  ldr r2,[r2,#4];    lsls r2,#0x1f; bpl <out>   ; LSR bit0 (TX ready)
 *   0xC0567796  str.w sl,[r3]                                 ; byte -> [membase+0]
 *
 * and calls sunplus_uart_ops_stop_tx() (0xC0566B80) when the xmit buffer runs
 * dry, which clears bit4 again.  With no interrupt ever asserted the handler
 * never runs, so every user-space write() to /dev/console blocked forever --
 * the symptom was: zero non-kernel lines on the console, and Launcher's main
 * thread parked in write(fd=1, 28 bytes).
 *
 * On real silicon THRE asserts whenever the holding register is empty and the
 * enable bit is set.  Our transmitter is instantaneous, so that is simply
 * "bit4 set"; the driver clearing bit4 in stop_tx() is what deasserts it.
 */
#define SP_UART_REG_TX      0x00u      /* write: THR   read: RBR          */
#define SP_UART_REG_LSR     0x04u
#define SP_UART_REG_IER     0x1cu
#define SP_UART_IER_TX_EMPTY 0x10u
#define SP_UART_IER_TX_DONE  0x01u   /* status: last byte gone, see read */
#define SP_UART_IER_RX_READY 0x02u   /* status: a byte is waiting        */
#define SP_UART_LSR_TX_READY 0x41u
#define SP_UART_LSR_RX_READY 0x02u   /* bit1, see below                  */

/*
 * The +0x1c register is not a plain 8250 IER: reading it back yields the
 * interrupt *status* bits in the low two positions while the software
 * enables live in the upper ones.
 *
 *   bit0 (0x01)  TX ready   - the driver only ever writes 0x20/0x30, yet
 *                            sunplus_uart_irq() insists on `reg & 0x11 == 0x11`
 *                            before it will transmit.
 *   bit1 (0x02)  RX ready   - sunplus_uart_irq() (0xC05676C4) tests this bit
 *                            *first*:
 *                                ldr r2, [r3, #0x1c]
 *                                lsls r2, r2, #0x1e
 *                                bmi  0xC05677E0        <- receive path
 *                            That path then reads the byte straight out of
 *                            the data register:
 *                                ldr r3, [r5, r3]      ; reg[0] = RBR
 *                                bic r1, r3, #2
 *                                cmp r1, #0x11        ; XON/XOFF
 *                            and hands it to uart_insert_char().
 *   bit4 (0x10)  TX enable - set by start_tx(), cleared by stop_tx().
 *   bit5 (0x20)  RX enable - set at startup(), cleared by stop_rx().
 *
 * The driver never writes bit0 or bit1, so both are hardware status and must
 * not be latched by the driver's read-modify-write cycles.  We therefore mask
 * them out on write and recompute them on every read.
 */
#define SP_UART_IER_STATUS_MASK (SP_UART_IER_TX_DONE | SP_UART_IER_RX_READY)

static bool sp_uart_rx_pending(SPUartState *s)
{
    return s->rx_head != s->rx_tail;
}

/*
 * Update the interrupt line.
 *
 * Two reasons to assert it, both level-triggered:
 *   - THRE (bit4 of +0x1c enabled): our transmitter is instantaneous, so the
 *     holding register is always empty.  The driver clearing bit4 in
 *     sunplus_uart_ops_stop_tx() is what deasserts it.
 *   - a byte is waiting in the RX fifo.
 *
 * qemu_irq_pulse() is unusable here: it lowers the line again before the CPU
 * has sampled it.
 */
static void sp_uart_update_irq(SPUartState *s)
{
    bool lvl = !!(s->regs[SP_UART_REG_IER >> 2] & SP_UART_IER_TX_EMPTY) ||
               sp_uart_rx_pending(s);

    if (lvl) {
        qemu_irq_raise(s->irq);
    } else {
        qemu_irq_lower(s->irq);
    }
}

static int sp_uart_can_receive(void *opaque);

static void sp_uart_receive(void *opaque, const uint8_t *buf, int size);

static uint64_t sp_uart_read(void *opaque, hwaddr offset, unsigned size)
{
    SPUartState *s = opaque;

    if (offset == SP_UART_REG_TX && sp_uart_rx_pending(s)) {
        uint8_t ch = s->rx[s->rx_tail];

        s->rx_tail = (s->rx_tail + 1) % SP_UART_RX_SIZE;
        if (s->trace) {
            fprintf(stderr, "UART%d RBR -> %02x ('%c')\n", s->idx, ch,
                    (ch >= 0x20 && ch < 0x7f) ? ch : '.');
        }
        sp_uart_update_irq(s);
        /* The socket backend pauses when the FIFO is full. Resume delivery
         * after the guest consumes a byte, including binary CFCP traffic. */
        qemu_chr_fe_accept_input(&s->chr);
        return ch;
    }
    if (offset == 0x04 || offset == 0x05) {
        /*
         * bit0 = TX ready (sunplus_uart_console_putchar spins on it),
         * bit1 = RX data available.  That second bit is the one that matters
         * for input: sunplus_uart_irq() reaches its receive path only when
         * LSR bit1 is set, and it then reads the byte from +0 -- with
         * `bic r3, r3, #2; cmp r1, #0x11` right after, i.e. XON/XOFF (0x11 /
         * 0x13) software flow control.  sunplus_uart_ops_startup() also drains
         * the fifo through exactly this pair before enabling anything.
         */
        return SP_UART_LSR_TX_READY |
               (sp_uart_rx_pending(s) ? SP_UART_LSR_RX_READY : 0);
    }
    if (offset == SP_UART_REG_IER) {
        /*
         * bit0 and bit1 are hardware status, not enables (see the comment on
         * SP_UART_IER_STATUS_MASK): recompute them on every read instead of
         * latching whatever the driver last wrote back.
         */
        uint32_t v = s->regs[(offset >> 2) & 0x1f] & ~SP_UART_IER_STATUS_MASK;

        v |= SP_UART_IER_TX_DONE;                    /* transmitter is idle */
        if (sp_uart_rx_pending(s)) {
            v |= SP_UART_IER_RX_READY;               /* a byte is waiting   */
        }
        return v;
    }
    return s->regs[(offset >> 2) & 0x1f];
}

static void sp_uart_write(void *opaque, hwaddr offset, uint64_t value,
                          unsigned size)
{
    SPUartState *s = opaque;
    uint8_t ch;

    if (offset == SP_UART_REG_TX) {
        ch = value & 0xff;
        if (s->trace) {
            fprintf(stderr, "UART%d TX <- %02x '%c' (pc=%08x)\n", s->idx, ch,
                    (ch >= 0x20 && ch < 0x7f) ? ch : '.',
                    (uint32_t)cpu_env(current_cpu)->regs[15]);
        }
        if (qemu_chr_fe_backend_connected(&s->chr)) {
            qemu_chr_fe_write_all(&s->chr, &ch, 1);
        }
        return;
    }
    s->regs[(offset >> 2) & 0x1f] = value;

    if (offset == SP_UART_REG_IER) {
        /*
         * The driver does read-modify-write on this register (e.g.
         * start_tx(): ldr r3,[r2,#0x1c]; orr r3,r3,#0x10; str r3,[r2,#0x1c]),
         * and what it reads back contains the hardware status bits we
         * synthesise.  Strip them again on the way in, otherwise a stray
         * "RX ready" would latch on and keep the interrupt asserted.
         */
        s->regs[SP_UART_REG_IER >> 2] &= ~SP_UART_IER_STATUS_MASK;

        if (s->trace) {
            fprintf(stderr, "UART%d IER <- %08x (pc=%08x)\n", s->idx,
                    (uint32_t)value,
                    (uint32_t)cpu_env(current_cpu)->regs[15]);
        }
        sp_uart_update_irq(s);
    }
}

static int sp_uart_can_receive(void *opaque)
{
    SPUartState *s = opaque;

    return (s->rx_tail + SP_UART_RX_SIZE - s->rx_head - 1) % SP_UART_RX_SIZE;
}

static void sp_uart_receive(void *opaque, const uint8_t *buf, int size)
{
    SPUartState *s = opaque;
    int i;

    for (i = 0; i < size; i++) {
        if ((s->rx_head + 1) % SP_UART_RX_SIZE == s->rx_tail) {
            break;                      /* full: let the chardev retry later */
        }
        s->rx[s->rx_head] = buf[i];
        s->rx_head = (s->rx_head + 1) % SP_UART_RX_SIZE;
    }
    if (s->trace) {
        fprintf(stderr, "UART%d RX %d byte(s), first=%02x\n", s->idx, i,
                i ? buf[0] : 0);
    }
    sp_uart_update_irq(s);
}

static const MemoryRegionOps sp_uart_ops = {
    .read = sp_uart_read,
    .write = sp_uart_write,
    .endianness = DEVICE_LITTLE_ENDIAN,
    .impl.min_access_size = 1,
    .impl.max_access_size = 4,
    .valid.min_access_size = 1,
    .valid.max_access_size = 4,
};

static void sp_uart_realize(DeviceState *dev, Error **errp)
{
    SPUartState *s = SP_UART(dev);
    SysBusDevice *sbd = SYS_BUS_DEVICE(dev);

    memory_region_init_io(&s->iomem, OBJECT(s), &sp_uart_ops, s,
                          TYPE_SP_UART, 0x80);
    sysbus_init_mmio(sbd, &s->iomem);
    sysbus_init_irq(sbd, &s->irq);

    qemu_chr_fe_set_handlers(&s->chr, sp_uart_can_receive, sp_uart_receive,
                             NULL, NULL, s, NULL, true);
    s->trace = getenv("SP_UART_TRACE") != NULL;
}

static void sp_uart_init(Object *obj)
{
    SPUartState *s = SP_UART(obj);

    memset(s->regs, 0, sizeof(s->regs));
}

static Property sp_uart_props[] = {
    DEFINE_PROP_CHR("chardev", SPUartState, chr),
    DEFINE_PROP_UINT32("index", SPUartState, idx, 0),
    DEFINE_PROP_END_OF_LIST(),
};

static void sp_uart_class_init(ObjectClass *oc, void *data)
{
    DeviceClass *dc = DEVICE_CLASS(oc);

    dc->realize = sp_uart_realize;
    device_class_set_props(dc, sp_uart_props);
}

static const TypeInfo sp_uart_info = {
    .name          = TYPE_SP_UART,
    .parent        = TYPE_SYS_BUS_DEVICE,
    .instance_size = sizeof(SPUartState),
    .instance_init = sp_uart_init,
    .class_init    = sp_uart_class_init,
};

static void sp_uart_register_types(void)
{
    type_register_static(&sp_uart_info);
}
type_init(sp_uart_register_types)

/* ------------------------------------------------ SPVD virtual disk (NAND) */
/*
 * A VHD-like virtual hard disk for the Sunplus SPI-NAND storage.  It is backed
 * by an .spvd file produced by Gemini-Dummy/tools/nand2spvd.py:
 *
 *   [ 0x0000 header | bad-block map | partition table ]  (0x1000 bytes)
 *   [ 0x1000 ..  flat NAND data: page_count * page_size bytes, OOB stripped ]
 *
 * Two memory regions are exposed through sysbus:
 *   region 0  "sunplus-vdisk.regs"  : 4 KiB control + partition-table introspection
 *   region 1  "sunplus-vdisk.data"  : linear read-only flat NAND data (mmap'd file)
 *
 * The data region is a direct view of the NAND data address space: page N starts
 * at offset N*page_size.  This lets the machine (and, once its command protocol
 * is modelled, the guest's sp_spinand driver) read NAND contents without the
 * host having to understand physical bad-block sparsity.  The existing
 * SP_FW_FILE DRAM injection stays as a fallback for M2 diagnostics.
 */
#define TYPE_SP_VDISK "sunplus-vdisk"
OBJECT_DECLARE_SIMPLE_TYPE(SPVdiskState, SP_VDISK)

#define SPVD_MAGIC        0x44505653u   /* "SPVD" little-endian */
#define SPVD_HDR_SIZE     0x1000
#define SPVD_BAD_OFF      0x100
#define SPVD_PART_OFF     0x400
#define SPVD_PART_ENTRY   44            /* name[32] + addr + size + rsvd */
#define SPVD_MAX_PARTS    32
#define SPVD_PART_AREA    0x800

struct SPVdiskState {
    SysBusDevice parent_obj;

    MemoryRegion regs;
    MemoryRegion data;

    char *path;
    uint8_t *map;          /* mmap of the whole .spvd file */
    size_t map_size;

    uint32_t page_size, oob_size, ppb, blocks, page_count;
    uint32_t bad_count, part_count;
    uint32_t sel_page;
    uint64_t data_size;
    uint8_t part_area[SPVD_PART_AREA];
};

static uint32_t spvd_rd32(const uint8_t *p)
{
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) |
           ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static uint64_t spvd_rd64(const uint8_t *p)
{
    return (uint64_t)spvd_rd32(p) | ((uint64_t)spvd_rd32(p + 4) << 32);
}

static uint64_t sp_vdisk_reg_read(void *opaque, hwaddr off, unsigned size)
{
    SPVdiskState *s = opaque;
    uint32_t idx, o;

    switch (off) {
    case 0x00: return SPVD_MAGIC;
    case 0x04: return 1;                 /* format version */
    case 0x08: return s->page_size;
    case 0x0C: return s->page_count;
    case 0x10: return s->sel_page;
    case 0x14: return s->blocks;
    case 0x18: return s->bad_count;
    case 0x1C: return s->part_count;
    case 0x20: return s->ppb;
    case 0x24: return s->oob_size;
    }
    /* Partition-table introspection window: [0x400, 0x400+0x800) */
    if (off >= SPVD_PART_OFF && off < SPVD_PART_OFF + SPVD_PART_AREA) {
        idx = (off - SPVD_PART_OFF) / 4;
        o = (off - SPVD_PART_OFF) % 4;
        return s->part_area[idx * 4 + o] |
               (s->part_area[idx * 4 + o + 1] << 8) |
               (s->part_area[idx * 4 + o + 2] << 16) |
               (s->part_area[idx * 4 + o + 3] << 24);
    }
    return 0;
}

static void sp_vdisk_reg_write(void *opaque, hwaddr off, uint64_t val,
                               unsigned size)
{
    SPVdiskState *s = opaque;

    if (off == 0x10) {                    /* selected page */
        s->sel_page = (uint32_t)val % (s->page_count ? s->page_count : 1);
    }
}

static const MemoryRegionOps sp_vdisk_reg_ops = {
    .read = sp_vdisk_reg_read,
    .write = sp_vdisk_reg_write,
    .endianness = DEVICE_LITTLE_ENDIAN,
    .impl.min_access_size = 1,
    .impl.max_access_size = 4,
    .valid.min_access_size = 1,
    .valid.max_access_size = 4,
};

static void sp_vdisk_realize(DeviceState *dev, Error **errp)
{
    SPVdiskState *s = SP_VDISK(dev);
    SysBusDevice *sbd = SYS_BUS_DEVICE(dev);
    const uint8_t *h;
    struct stat st;
    int fd;

    if (!s->path) {
        error_setg(errp, "sunplus-vdisk: 'file' property is required");
        return;
    }
    fd = open(s->path, O_RDONLY);
    if (fd < 0) {
        error_setg_errno(errp, errno, "sunplus-vdisk: cannot open %s", s->path);
        return;
    }
    if (fstat(fd, &st) != 0 || st.st_size < SPVD_HDR_SIZE) {
        error_setg(errp, "sunplus-vdisk: %s too small", s->path);
        close(fd);
        return;
    }
    s->map_size = st.st_size;
    s->map = mmap(NULL, s->map_size, PROT_READ | PROT_WRITE, MAP_PRIVATE, fd, 0);
    close(fd);
    if (s->map == MAP_FAILED) {
        s->map = NULL;
        error_setg_errno(errp, errno, "sunplus-vdisk: mmap %s failed", s->path);
        return;
    }
    h = s->map;
    if (memcmp(h, "SPVD", 4) != 0) {
        error_setg(errp, "sunplus-vdisk: %s is not an SPVD image", s->path);
        return;
    }
    s->page_size  = spvd_rd32(h + 0x08);
    s->oob_size   = spvd_rd32(h + 0x0C);
    s->ppb        = spvd_rd32(h + 0x10);
    s->blocks     = spvd_rd32(h + 0x14);
    s->page_count = spvd_rd32(h + 0x18);
    s->data_size  = spvd_rd64(h + 0x20);
    s->bad_count  = spvd_rd32(h + 0x28);
    s->part_count = spvd_rd32(h + 0x2C);
    s->sel_page   = 0;

    if (s->part_count > SPVD_MAX_PARTS) {
        s->part_count = SPVD_MAX_PARTS;
    }
    memcpy(s->part_area, h + SPVD_PART_OFF, SPVD_PART_AREA);

    if (s->data_size == 0 ||
        SPVD_HDR_SIZE + s->data_size > s->map_size) {
        error_setg(errp, "sunplus-vdisk: %s data_size %" PRIu64
                   " inconsistent with file size", s->path, s->data_size);
        return;
    }

    /* region 1: linear, read-only flat NAND data (direct view of the disk) */
    memory_region_init_ram_ptr(&s->data, OBJECT(s), "sunplus-vdisk.data",
                               s->data_size, s->map + SPVD_HDR_SIZE);
    sysbus_init_mmio(sbd, &s->data);

    /* region 0: control + partition introspection */
    memory_region_init_io(&s->regs, OBJECT(s), &sp_vdisk_reg_ops, s,
                          "sunplus-vdisk.regs", SPVD_HDR_SIZE);
    sysbus_init_mmio(sbd, &s->regs);

    fprintf(stderr,
            "SP_VDISK: %s  page=%u oob=%u ppb=%u blocks=%u pages=%u "
            "data=%" PRIu64 " bad=%u parts=%u\n",
            s->path, s->page_size, s->oob_size, s->ppb, s->blocks,
            s->page_count, s->data_size, s->bad_count, s->part_count);
}

static void sp_vdisk_unrealize(DeviceState *dev)
{
    SPVdiskState *s = SP_VDISK(dev);

    if (s->map && s->map != MAP_FAILED) {
        munmap(s->map, s->map_size);
        s->map = NULL;
    }
    g_free(s->path);
    s->path = NULL;
}

static Property sp_vdisk_props[] = {
    DEFINE_PROP_STRING("file", SPVdiskState, path),
    DEFINE_PROP_END_OF_LIST(),
};

static void sp_vdisk_class_init(ObjectClass *oc, void *data)
{
    DeviceClass *dc = DEVICE_CLASS(oc);

    dc->realize = sp_vdisk_realize;
    dc->unrealize = sp_vdisk_unrealize;
    device_class_set_props(dc, sp_vdisk_props);
}

static const TypeInfo sp_vdisk_info = {
    .name          = TYPE_SP_VDISK,
    .parent        = TYPE_SYS_BUS_DEVICE,
    .instance_size = sizeof(SPVdiskState),
    .class_init    = sp_vdisk_class_init,
};

static void sp_vdisk_register_types(void)
{
    type_register_static(&sp_vdisk_info);
}
type_init(sp_vdisk_register_types)

/* ------------------------------------------------------------------ machine */

/* Reverse-engineered addresses (see SUNPLUS-MEMMAP.md). */
#define SP_DRAM_BASE        0x00000000ULL
#define SP_KERNEL_LINK      0x000408000ULL   /* Image link/entry address */
#define SP_MACHINE_ID       0x0F34           /* machine_desc "GEMINI" */
#define SP_BOOT_STUB_OFFSET 0x10000          /* QEMU: kernel = loader_start+0x10000 */

#define SP_GIC_DIST_ADDR    0x9F101000ULL
#define SP_GIC_CPU_ADDR     0x9F102000ULL
#define SP_GIC_NUM_IRQ      256
#define SP_TIMER_FREQ_HZ    27000000ULL

/* PSU / clock / pinmux register block (map_desc[0]). The kernel's sp_map_io()
 * statically maps virtual 0xF0800000 -> physical 0x9C000000 with LENGTH 0x20000,
 * so this region MUST cover the full 0x20000 or every access at 0xF0800900..
 * 0xF0820000 (incl. the console UART0 at 0x9c000900 and the clock/reset regs the
 * kernel scans) faults with an external abort (see boot trace: DFAR 0xf0807xxx).
 * M1 used 0x20000 and booted; a later shrink to 0x900 regressed early boot.
 * UART0 (0x9c000900) is overlaid as a SUBREGION on top of this PSU block so the
 * whole PSU range stays mapped AND the console UART gets its own registers.
 */
#define SP_PSU_ADDR         0x9C000000ULL
#define SP_PSU_SIZE         0x20000

/*
 * sp_i2cm0 lives inside the PSU window at +0x4600 and its completion line is
 * GIC SPI 40 ("40: ... sp_i2cm0" in the guest's /proc/interrupts). The ALS308
 * driver's five probe transfers are the only I2C users during boot.
 */
#define SP_I2C_IRQ_DEFAULT  40
#define SP_I2C_ADDR         0x04600
#define SP_I2C_STATUS       0x04600
#define SP_I2C_DATA         0x04608
#define SP_I2C_STATE        0x0461c
#define SP_I2C_IRQ_ENABLE   0x04624
#define SP_I2C_CMD          0x04660
#define SP_I2C_WINDOW_END   0x04680
/* bit 1 of the state word: transfer finished, slave did not acknowledge. */
#define SP_I2C_STATE_NACK   0x00000002u
#define SP_SYSCTL_ADDR      0x9C10A000ULL
#define SP_SYSCTL_SIZE      0x1000

/* Misc IP block sitting between the PSU window and the sysctl/GPU windows.
 *
 * sp_bch_probe() is the first caller: it takes a MEM resource from its
 * platform_device, devm_ioremap_resource()s it and stores the result, then
 * sp_bch_reset() writes 1 to base+0x10 and busy-polls bit0 of the same
 * register.  With nothing behind the address the *read* raises
 *
 *   Unhandled fault: external abort on non-linefetch (0x808) at 0xd0c2a010
 *   PC is at sp_bch_reset.constprop.0+0x12/0x74
 *
 * and the subsequent do_page_fault storm kills the idle task ("Attempted to
 * kill the idle task!"), stranding the boot right before sp_spinand_probe.
 * The fault's pte (9c101653) gives the physical base: 0x9C101000.
 *
 * The window deliberately stops at SP_SYSCTL_ADDR so it never overlaps the
 * sysctl or GPU subregions (a sibling overlap at equal priority is a QEMU
 * address-space error, not something the guest would ever see).
 */
#define SP_IP_ADDR          0x9C100000ULL
#define SP_IP_SIZE          0xA000      /* 0x9C100000..0x9C10A000 */

/* sp_bch register offsets, straight out of sp_bch_reset (0xC05B4CC8):
 *
 *   0xC05B4CD2  ldr  r4, [r3, #0xc]      ; r4 = s->base (ioremap VA)
 *   0xC05B4CD8  movs r3, #1
 *   0xC05B4CDA  str  r3, [r4, #0x10]     ; start reset, bit0 = busy
 *   0xC05B4CFA  ldr  r3, [r0]            ; r0 = r4+0x10
 *   0xC05B4D00  lsls r3, r3, #0x1f       ; isolate bit0
 *   0xC05B4D02  bmi  <poll again>        ; still busy -> keep waiting
 *   0xC05B4D12  str  r3, [r4, #0x14]     ; ~3
 *   0xC05B4D1A  str  r3, [r4, #0x18]     ; 0x11
 *   0xC05B4D22  str  r3, [r4, #0xc]      ; 1
 *
 * The offsets below are relative to SP_IP_ADDR, i.e. they already include the
 * 0x1000 that separates the BCH base from the start of the window.  Getting
 * this wrong is silent: the poll simply runs its 10-jiffy timeout and the
 * driver prints "sp_bch: reset timeout".
 */
#define SP_BCH_BASE         (0x9C101000ULL - SP_IP_ADDR)
#define SP_BCH_REG_CTRL     (SP_BCH_BASE + 0x00C)
#define SP_BCH_REG_STATUS   (SP_BCH_BASE + 0x010)
#define SP_BCH_REG_MASK     (SP_BCH_BASE + 0x014)
#define SP_BCH_REG_CFG      (SP_BCH_BASE + 0x018)

/* --------------------------------------------------- SPI-NAND controller
 *
 * sp_spinand_probe() maps the controller at 0x9C002B80, 84 bytes, plus a
 * 4608-byte DMA buffer and IRQ 55 -- exactly what the real unit prints:
 *
 *   [SPI-NAND] regs = 0xf0802b80@0x9c002b80, size = 84
 *   [SPI-NAND] buffer = 0xc7844000@0x07844000, size = 4608
 *   [SPI-NAND] irq = 55
 *
 * The driver is unusual: chip->cmd_ctrl() is an empty stub and
 * chip->dev_ready() returns 1, so nothing is bit-banged.  Every transfer is a
 * register transaction described by the driver itself.  spi_nand_readid()
 * (0xC05B3858) is the smallest one and the one that gates chip detection:
 *
 *   0xC05B3878  str  r6, [r4]        ; 0x00 = 0x01009FB1 | (5e1<<16)
 *   0xC05B3888  str  r3, [r4, #4]    ; 0x04
 *   0xC05B388E  str  r1, [r4, #8]    ; 0x08 = address (0 for READID)
 *   0xC05B3898  str  r3, [r4, #0x18] ; 0x18 = 0x880000
 *   0xC05B38A4  str  r3, [r4, #0x1c] ; 0x1c = 0x00150085
 *   0xC05B38AE  str  r3, [r4, #0x14] ; 0x14 = 0x200000  <-- start
 *   0xC05B38B0  bl   wait_spi_idle   ; poll 0x00 bit31 until clear
 *   0xC05B38B4  ldr  r3, [r4, #0xc]  ; 0x0c = 4 bytes of read data
 *
 * So the model only has to (a) keep 0x00 bit31 low so wait_spi_idle returns,
 * and (b) hand back the ID bytes in 0x0c once a transaction with SPI opcode
 * 0x9F has been started.  Without this the driver reports
 *
 *   nand: No NAND device found
 *   [SPI-NAND] ERR @ sp_spinand_probe(1787): Unsupport device(id=0x00000000)
 *
 * and no MTD device ever appears, so root=/dev/blockrom8 cannot mount.
 */
#define SP_SPINAND_ADDR     0x9C002B80ULL
#define SP_SPINAND_SIZE     0x100

#define SPN_REG_CMD         0x00    /* command dword; byte1 = SPI opcode    */
#define SPN_REG_ADDR        0x08    /* page number (op 0x00) / column (0x0f) */
#define SPN_REG_DATA        0x0C    /* 4 bytes per access                   */
#define SPN_REG_CTRL        0x14    /* bit21 start, bit17 busy              */
#define SPN_REG_COLUMN      0x3C    /* column within page+spare             */
#define SPN_REG_DMA_DST     0x34    /* DMA destination, physical DRAM       */
#define SPN_REG_DMA_AUX     0x38    /* second buffer: only written for full
                                     * page reads, NOT the destination     */
#define SPN_REG_IRQ_MASK    0x44
#define SPN_REG_IRQ_ACK     0x48    /* write-1-to-clear                     */
#define SPN_REG_DMA_LEN     0x50    /* byte count                           */

/* SPI opcode lives in byte 1 of the command dword (0x01009FB1 -> 0x9F). */
#define SPN_OPCODE(cmd)     (((cmd) >> 8) & 0xFF)
#define SPN_SUBOP(cmd)      (((cmd) >> 16) & 0xFF)   /* direction/length sel */
#define SPN_OP_READID       0x9F    /* JEDEC/ONFI read id                   */
#define SPN_OP_CACHE_READ   0x0F    /* read from cache (column based)       */
#define SPN_OP_CACHE_WRITE  0x1F    /* write to cache (feature registers)   */
#define SPN_OP_RESET        0xFF
#define SPN_OP_DMA          0x00    /* dram <-> cache; subop picks direction */
#define SPN_OP_PROGRAM      0x10    /* program execute                      */
#define SPN_OP_ERASE        0xD8    /* block erase                          */

/* Opcode 0x00 is shared by both directions; the selector lives in byte 2:
 *   0x01010082 = read  (page -> DRAM), 0x01020082 = write (DRAM -> page).
 * Getting this wrong is silent -- reads happen, writes vanish, and the
 * driver only reports "Wait dma done timeout". */
#define SPN_SUB_READ        0x01
#define SPN_SUB_WRITE       0x02

/* XTX XT26G04C: 512 MiB SLC, 4 KiB page / 128 B OOB / 256 KiB erase block.
 * The ID bytes are what the real unit reports at 0.297 s. */
#define SPN_MAF_ID          0x0B
#define SPN_DEV_ID          0x13
#define SPN_READID_DATA     ((SPN_DEV_ID << 8) | SPN_MAF_ID)

/* Fixed geometry of the 150Aura part, used when no .spvd is supplied. */
#define SPN_DEF_PAGE_SIZE   4096
#define SPN_DEF_OOB_SIZE    128
#define SPN_DEF_PPB         64
#define SPN_DEF_PAGE_COUNT  131072  /* 512 MiB / 4 KiB */
#define SPN_MAX_BAD         64

/* Vivante GPU register block. Base comes straight out of the guest's own
 * galcore config (global @0xC082123C = { 0x9C110000, 0x800, ... ,
 * 0x00400000, ..., irq 48 }); the driver maps it at 0xD080D000. We do not
 * model the GPU, we only need it to answer instead of aborting the bus.
 */
#define SP_GPU_ADDR         0x9C110000ULL
#define SP_GPU_SIZE         0x400000

/* §34 VPP / PFC display-controller register window.  The guest kernel MID_DISP
 * driver programs the P-gear background layer here; the real hardware lives at
 * ~0x41e60000.  Defined early so sp_ipc_stub can reference it. */
#define SP_VPP_BASE         0x41c00000ULL
#define SP_VPP_SIZE         0x00400000ULL
#define SP_VPP_REGS         (SP_VPP_SIZE / 4)

/* Injected board-config blob. The original BSP reads its board config from a
 * pointer in .data (kernel reads *(0xC08056C0/4) and ioremap()s it). On the real
 * board U-Boot fills that global with a DRAM-resident runtime.cfg pointer and
 * the SP ioremap mapper accepts it, because the mapper only resolves physical
 * ranges that were registered as real memory/MMIO windows (a VMA tree set up by
 * platform init). A fake high aperture such as 0x30000000 is NOT in that tree,
 * so the SP mapper's "new mapping" path fails and sp_config_init() returns -1.
 *
 * Fix: deposit the blob into REAL DRAM at SP_FW_ADDR (well above the kernel
 * image, inside the 0x0..0x10000000 board RAM). address_space_write() lands it
 * in the RAM MemoryRegion, which the SP ioremap mapper already backs. We then
 * point the kernel's config globals at this DRAM address. No fake MMIO window,
 * no kernel-code change -- pure data injection.
 */
#define SP_FW_ADDR          0x07000000ULL
#define SP_FW_SIZE          (1 * MiB)

#define SP_UART_COUNT       5
/* Addresses/IRQs taken verbatim from the guest's own probe output:
 *
 *   ttyS: ttyS0 at MMIO 0x9c000900 (irq = 97, ...) is a Sunplus_UART0
 *   ttyS: ttyS1 at MMIO 0x9c000980 (irq = 98, ...) is a Sunplus_UART1
 *   ttyS: ttyS2 at MMIO 0x9c000800 (irq = 99, ...) is a Sunplus_UART2
 *   K_TTYS: Skip UART3
 *   ttyS: ttyS4 at MMIO 0x9c00f900 (irq = 67, ...) is a Sunplus_UART4
 *
 * All of them live inside the PSU block (0x9C000000 + 0x20000), so they are
 * overlaid as SUBREGIONS of the PSU register file instead of being mapped to
 * their own top-level window -- that keeps the kernel's static PSU mapping
 * (0xF0800000 -> 0x9C000000, len 0x20000) coherent for both.
 */
static const hwaddr sp_uart_base[SP_UART_COUNT] = {
    0x9c000900, 0x9c000980, 0x9c000800, 0x9c000980 /* skipped */, 0x9c00f900,
};
static const int sp_uart_irq[SP_UART_COUNT] = { 97, 98, 99, 0, 67 };

/*
 * Convert a Linux IRQ number into the GIC's input-line number.
 *
 * QEMU's arm_gic numbers its inputs differently from the interrupt numbers the
 * guest sees: hw/intc/arm_gic.c gic_set_irq() says
 *
 *     [0..N-1]     : external interrupts
 *     "The first external input line is internal interrupt 32."
 *
 * and adds GIC_INTERNAL (32) before latching the pending bit.  So a driver
 * that does request_irq(47) is waiting for *input line 15*, not 47.
 *
 * This cost real debugging time: galcore self-reports "irqLine = 47"
 * (galcore.showArgs=1) yet its ISR only ever ran when GIC line 15 was
 * asserted.  The NAND (55) and IPC lines already subtracted 32 by hand; the
 * UARTs did not, which is why no UART interrupt ever reached the CPU (the
 * console hides it, because sunplus_uart_console_putchar() polls LSR).
 */
#define SP_GIC_SPI(irq)  ((irq) - 32)

typedef struct SP8368State {
    MachineState parent;

    ARMCPU *cpu;
    MemoryRegion ram;
    MemoryRegion psu;
    MemoryRegion sysctl;
    uint32_t psu_regs[SP_PSU_SIZE / 4];
    bool ipc_trace;             /* SP_IPC_TRACE=1: dump rpc mailbox traffic */
    bool ipc_stub;              /* SP_IPC_STUB=1: answer the mailbox */
    unsigned ipc_doors;         /* doorbell writes seen */
    qemu_irq ipc_irq;           /* EIPC line, see SP_IPC_IRQ */
    bool psu_trace;
    bool fw_trace;
    DeviceState *gic;
    DeviceState *uart[SP_UART_COUNT];
    DeviceState *vdisk;

    qemu_irq timer_fwd[8];
    unsigned timer_irqs[8];
    qemu_irq cpu_irq_fwd;
    unsigned cpu_irq_edges;
    QEMUTimer *stat_timer;      /* periodic "how many ticks so far" report */
    QEMUTimer *pc_timer;        /* SP_PC_TRACE=1: periodic guest PC sampler */
    unsigned pc_samples;
    unsigned fb_scanout_page[3];
    bool fb_scanout_known[3];
    uint32_t ui_w, ui_h;        /* panel UI size, see SP_UI_W_DEFAULT */

    /* --- power-on boot animation (SP_BOOT_ANIM=<anm_logo.bin>) --------- */
    /* The real unit plays anm_logo/logo.mkv on the bootloader's PE decoder
     * before Linux exists; this model has no PE block, so it replays the
     * pre-decoded original frames until the guest paints the panel. */
    QEMUTimer *anim_timer;
    uint8_t *anim_blob;         /* whole ANM2 file, kept in memory */
    size_t anim_blob_size;
    uint8_t *anim_frame;        /* last decoded frame, BGRA 32bpp */
    uint32_t anim_frames, anim_w, anim_h, anim_fps, anim_data_off;
    uint32_t anim_next;         /* next frame index to blit */
    int64_t anim_period_ns;
    int64_t anim_hold_since;    /* when the final frame went up, ns */
    int64_t anim_hold_max_ns;   /* SP_BOOT_ANIM_HOLD_MS override */
    bool anim_running;
    bool anim_trace;            /* SP_BOOT_ANIM_TRACE=1 */
    /* SP_WAKE_FILE=<path>: the real AE5i keeps the cluster LCD dark through
     * MCU boot and the locked state, and only "lights up" (replaying the
     * bootloader logo) once the vehicle is actually started (unlocked).  When
     * this env is set we do NOT auto-play at power-on; instead sp_pc_sample()
     * polls for the file and calls sp_anim_start() the moment the client
     * creates it (i.e. when the vehicle is unlocked). */
    bool anim_wake_armed;
    char *anim_wake_path;
    uint8_t *anim_snapshot;     /* page we overwrite; restored on anim stop so the
                                 * cluster returns to its pre-logo frame instead
                                 * of a black screen. */

    /* --- power-off shutdown animation (reverse logo replay) ----------- */
    /* The real unit plays a logo "out" on power-off.  We replay the same
     * pre-decoded asset backwards.  Triggered by SP_SHUTDOWN_WAKE_FILE, which
     * the client writes just before issuing `poweroff -f` so the user sees the
     * animation before the panel goes dark. */
    bool shutdown_wake_armed;
    char *shutdown_wake_path;
    QEMUTimer *shutdown_timer;
    uint8_t *shutdown_frame;
    uint32_t shutdown_frames, shutdown_next;
    int64_t shutdown_period_ns;
    bool shutdown_running;
    bool shutdown_trace;

    /* --- I2C controller fast-fail (ALS308 light-sensor probe) ---------- */
    /* The stock kernel probes an ALS308 over sp_i2cm0 and each of its five
     * transfers waits 10 s for a completion IRQ the model never raised
     * (measured: 5 x 10.24 s = 51 s of the ~59 s boot). The sensor has
     * nothing to do with the dashboard, so fake an immediate "transfer
     * finished" status and pulse the completion line instead of stalling. */
    qemu_irq i2c_irq;           /* GIC SPI 40, see SP_I2C_IRQ_DEFAULT */
    QEMUTimer *i2c_timer;
    bool i2c_fastfail;          /* SP_I2C_SLOW=1 restores the old stall */
    bool i2c_pending;           /* completion IRQ asserted, waiting for ack */
    bool i2c_armed;             /* a transfer was started: report NACK */
    unsigned i2c_fastfail_ops;
    bool i2c_trace;             /* SP_I2C_TRACE=1: log access PC once each */
    uint32_t i2c_seen_pc[24];   /* PC already reported, per observed offset */
    uint32_t i2c_seen_off[24];
    unsigned i2c_seen_n;
    /* SP_I2C_SET="1c=1,3c=1": force the value read back from those offsets
     * (relative to SP_I2C_ADDR).  Lets one build test several register
     * hypotheses without recompiling. */
    struct {
        uint32_t off;
        uint32_t val;
    } i2c_fake[8];
    unsigned i2c_fake_n;

    /* Vivante GPU register file (see sp_gpu_read/sp_gpu_write). */
    MemoryRegion gpu;
    uint32_t gpu_regs[SP_GPU_SIZE / 4];
    bool gpu_trace;
    unsigned gpu_reset_rounds;  /* reads of 0x004 == _ResetGPU rounds so far */

    /* --- command buffer execution (see sp_gpu_cmd_start) --------------- */
    qemu_irq gpu_irq;           /* GIC line 47, see SP_GPU_IRQ */
    QEMUTimer *gpu_timer;       /* completes the submitted command buffer  */
    uint32_t gpu_intr_status;   /* 0x010, what gckHARDWARE_Interrupt reads */
    uint32_t gpu_pending_event; /* bitmask of EVENT ids seen in the buffer */
    unsigned gpu_cmdbufs;       /* command buffers started so far          */
    uint8_t *gpu_cmd;           /* scratch copy of the last buffer         */
    uint32_t gpu_cmd_len;
    uint32_t gpu_fe_pc;
    bool gpu_fe_running;
    uint32_t gpu_2d_state[0x100]; /* state addresses 0x1200..0x15ff */
    uint32_t gpu_2d_palette[256]; /* PE2 INDEX_COLOR_TABLE32 at 0x3400 */
    unsigned gpu_pixel_trace_count;

    /* §34 VPP / PFC display-controller register file.  The guest's kernel
     * MID_DISP driver programs the background (P-gear wall + vehicle) layer by
     * writing these registers; the real hardware lives at ~0x41e60000.  We
     * model a logging window 0x41c00000..0x42000000 and capture the *real*
     * register programming the guest performs -- including the background source
     * buffer's physical address -- so we can composite the guest-decoded
     * bitmap (no pixel forgery).  vpp_regs[] is the shadow copy. */
    MemoryRegion vpp;
    uint32_t *vpp_regs;
    bool vpp_trace;

    /* SP_GPU_IRQ_SCAN=1: probe every GIC line, see sp_irqscan_cb(). */
    QEMUTimer *irqscan_timer;
    int irqscan_line;

    /* Second-stage IPC delivery, see sp_ipc_deliver_user().
     * 0x50 == SP_IPC_BLK, spelled out because the struct comes first. */
    QEMUTimer *ipc_timer;
    uint8_t ipc_pending[0x50];
    bool ipc_pending_valid;

    /* Misc IP window (currently only the NAND BCH ECC controller answers). */
    MemoryRegion ip;
    uint32_t ip_regs[SP_IP_SIZE / 4];
    bool ip_trace;

    /* SPI-NAND controller (see SP_SPINAND_ADDR). */
    MemoryRegion spinand;
    uint32_t spinand_regs[SP_SPINAND_SIZE / 4];
    bool spinand_trace;
    unsigned spinand_cmds;
    unsigned spinand_logs;      /* hard cap on trace lines, see sp_spinand_log() */

    /* SPI-NAND backing store: flat page data out of the .spvd image. */
    uint8_t *nand_map;
    size_t nand_map_size;
    uint64_t nand_data_off;
    uint32_t nand_page_size, nand_oob_size, nand_ppb, nand_page_count;
    uint32_t nand_bad[SPN_MAX_BAD];
    unsigned nand_bad_count;

    /* Small cache so op 0x0F (read from cache) can serve byte-wise reads after
     * a page has been fetched; also what reg 0x0C returns. */
    uint8_t nand_cache[SPN_DEF_PAGE_SIZE + 256];
    uint32_t nand_cache_pos;
    bool nand_cache_valid;

    qemu_irq nand_irq;
    bool nand_irq_pending;
    bool nand_cmd_armed;        /* a command dword was written, transfer due */
    bool nand_ctrl_busy;        /* reg 0x14 bit17/bit21 -- transfer in flight */
    unsigned nand_dma_reads;

    /* MUST live as long as the machine: arm_load_kernel() only stores the
     * pointer in env->boot_info and the reset handler (do_cpu_reset) reads it
     * back later -- long after the board init function has returned. A stack
     * local here silently gives the guest garbage loader_start/entry, skips
     * have_dtb()==false so set_kernel_args() never runs (no ATAGS, no
     * command line, no console=), and can point the PC into random DRAM.
     */
    struct arm_boot_info bootinfo;
} SP8368State;

/* PSU / clock / pinmux block. M2 keeps it as a register file and can trace
 * every access (SP_PSU_TRACE=1) so the kernel's clock protocol can be read off.
 */

/* EIPC (inter-core) handshake word, reverse-engineered from sp_ipc_init():
 *
 *   0xC07E22AE  ldr  r3, [0xf08081dc]      ; = phys 0x9C0081DC
 *   0xC07E22B4  cmp  r3, #0x5A5AA5A5
 *   0xC07E22B6  beq  <ready>               ; then ack at 0x9C00815C
 *   ... otherwise usleep_range(1000,1000) x3001 -> "Wait eCos ready timeout"
 *
 * On the real board the eCos co-processor publishes this magic once it is up.
 * We model the co-processor as ALREADY booted: reporting the magic makes the
 * A7 side take the ready path instead of burning 3 s and then tearing the
 * driver down (free_irq + kthread_stop), which used to strand the boot before
 * any console driver was even registered.
 */
#define SP_PSU_EIPC_READY_REG   0x081DC
#define SP_PSU_EIPC_ACK_REG     0x0815C
#define SP_PSU_EIPC_READY_MAGIC 0x5A5AA5A5u

/*
 * IPC / RPC mailbox ("eCos" peer), reverse-engineered from the rpc_* helpers
 * (see docs/EMULATION.md §0.2):
 *
 *   0x01000  doorbell   -- rpc_write_hw() does `*(u32*)0xF0801000 = 1`
 *   0x01004  peer status -- polled until (v & 0xFFFF0000) == 0
 *   0x08110  request     -- rpc_copy(0xF0808110, msg): 0x14 B header + payload
 *   0x08190  response    -- rpc_isr() copies 0x50 B from here, then wakes the
 *                           waiter whose channel is (u16@0xa >> 9) & 7
 *
 * Header dwords: [0]=owner ptr, [2]=u16 len, [3]=u16 (id & 0xfff) | flags,
 * [4]=seq, [5]=payload phys (len > 0x3c only, inline otherwise).
 */
/* Hardware test-and-set semaphores ("tset").
 *
 * sp_tset_lock() (0xC041945C) is called before the console is even registered:
 *
 *   mrs  r1, apsr ; cpsid i
 *   ldr  r2, [0xc0806028]        ; = phys 0x9C000580 (hw lock base)
 *   ldr  r3, [r2, r0, lsl #2]    ; <-- spins here with IRQs off
 *   cmp  r3, #0 ; beq <retry>
 *
 * sp_tset_unlock() writes 0 to the same word.  The A7 is the only agent we
 * model, so a read has to report "lock acquired" (non-zero) or the kernel
 * dead-loops before early console output: 610 k identical PSU reads of 0x580
 * and a `cpu_io_recompile` storm, no UART bytes at all.
 */
#define SP_PSU_TSET_BASE        0x00580
#define SP_PSU_TSET_NUM         32

#define SP_PSU_IPC_DOORBELL     0x08100   /* measured, NOT 0x01000        */
#define SP_PSU_IPC_STATUS       0x08104   /* poll (v & 0xffff0000) == 0   */
#define SP_PSU_IPC_REQ          0x08110
#define SP_PSU_IPC_RSP          0x08190
#define SP_IPC_BLK              0x50

/*
 * I2C register tracing.
 *
 * The ALS308 probe polls for ten seconds because the model never reports a
 * completed transfer.  To learn which register (and which bit) it waits on,
 * log the guest PC behind the first access to each I2C offset when
 * SP_I2C_TRACE=1, and allow single offsets to be overridden from the
 * environment (SP_I2C_SET="1c=1,3c=1") so one build can test several
 * register hypotheses without recompiling.
 *
 * What the trace showed (kernel-ae5i, 2026-11-01): after the driver writes
 * the command word to 0x4660 and unmasks the completion interrupt at 0x4624,
 * it spins on the *status* register 0x461c, and the ISR at 0xc05ee1cc decodes
 * bits 1/4/5/6/8/9/11 of that same word.  Bit 1 is "transfer finished, slave
 * NACKed": the driver then reports "No als308 detected" and moves on.  There
 * is no ALS308 behind this bus, so the model reports exactly that instead of
 * letting the driver burn its 10.24 s timeout on all five probe transfers.
 */
static void sp_i2c_note(SP8368State *s, hwaddr off, uint32_t v, bool write)
{
    uint32_t pc;
    uint32_t lr;
    unsigned i;

    if (!s->i2c_trace) {
        return;
    }
    pc = (uint32_t)s->cpu->env.regs[15];
    lr = (uint32_t)s->cpu->env.regs[14];
    for (i = 0; i < s->i2c_seen_n; i++) {
        if (s->i2c_seen_off[i] == (uint32_t)off) {
            if (s->i2c_seen_pc[i] != pc) {
                s->i2c_seen_pc[i] = pc;
                fprintf(stderr, "I2C %s %05" HWADDR_PRIx " = %08x "
                        "@pc=%08x lr=%08x\n",
                        write ? "wr" : "rd", off, v, pc, lr);
            }
            return;
        }
    }
    if (s->i2c_seen_n < G_N_ELEMENTS(s->i2c_seen_pc)) {
        s->i2c_seen_off[s->i2c_seen_n] = (uint32_t)off;
        s->i2c_seen_pc[s->i2c_seen_n] = pc;
        s->i2c_seen_n++;
        fprintf(stderr, "I2C %s %05" HWADDR_PRIx " = %08x @pc=%08x lr=%08x\n",
                write ? "wr" : "rd", off, v, pc, lr);
    }
}

static uint32_t sp_i2c_fake_get(SP8368State *s, hwaddr off, uint32_t v)
{
    unsigned i;

    for (i = 0; i < s->i2c_fake_n; i++) {
        if (s->i2c_fake[i].off == (uint32_t)off) {
            return s->i2c_fake[i].val;
        }
    }
    return v;
}

static uint64_t sp_psu_read(void *opaque, hwaddr off, unsigned size)
{
    SP8368State *s = opaque;
    uint32_t v = s->psu_regs[(off >> 2) & ((SP_PSU_SIZE / 4) - 1)];

    if (off == SP_PSU_EIPC_READY_REG) {
        v = SP_PSU_EIPC_READY_MAGIC;
    }
    /*
     * I2C fast-fail: reading the status register stands in for the driver's
     * ISR acknowledging the completion, so drop the level interrupt here the
     * same way a real "read clears interrupt" controller would.
     */
    if (s->i2c_fastfail && (uint32_t)off == SP_I2C_STATUS) {
        v = s->psu_regs[SP_I2C_STATUS >> 2];
        if (s->i2c_pending) {
            s->i2c_pending = false;
            if (s->i2c_irq) {
                qemu_irq_lower(s->i2c_irq);
            }
        }
    }
    if ((uint32_t)off >= SP_I2C_ADDR && (uint32_t)off < SP_I2C_WINDOW_END) {
        if (s->i2c_fastfail && s->i2c_armed && (uint32_t)off == SP_I2C_STATE) {
            v = SP_I2C_STATE_NACK;
        }
        v = sp_i2c_fake_get(s, off, v);
        sp_i2c_note(s, off, v, false);
    }
    if (off >= SP_PSU_TSET_BASE &&
        off < SP_PSU_TSET_BASE + SP_PSU_TSET_NUM * 4) {
        /* test-and-set: single agent, so the lock is always ours. */
        v = 1;
    }
    if (s->psu_trace) {
        fprintf(stderr, "PSU rd %05" HWADDR_PRIx " -> %08x\n", off, v);
    }
    return v;
}

/*
 * Minimal eCos stand-in for the rpc mailbox.
 *
 * The protocol is symmetric and in-place: the A7 side publishes a 0x50-byte
 * block at 0x8110 whose dword6 is the *physical* address of an out-of-line
 * payload buffer (len > 0x3c) that it fills with the request, then rings the
 * doorbell.  The peer writes its answer into that same buffer and echoes the
 * header -- with the request id in the high half of dword2 the reply is
 * automatically recognised as a reply -- to 0x8190 and raises the IPC irq.
 * rpc_isr() then routes it back to the waiter by (id >> 9) & 7.
 */
/*
 * Display geometry.
 *
 * The UI resolution is not ours to invent: the panel's own runtime_cfg
 * (partition runtime_cfg, text block "##runtime.cfg##") says
 *
 *     UI_width=1024
 *     UI_height=600
 *     rev_disp_act_w=1024 / rev_disp_act_h=600
 *
 * and both the boot animation in anm_logo (logo.mkv, H.264 1024x600 60 fps)
 * and the 16 full-screen theme assets embedded in libdashclustoractivity.so
 * are 1024x600.  Reporting 800x480 here made the原厂 theme lay the dashboard
 * out for a smaller panel, so only the left info column ever landed on screen.
 * SP_UI_RES=WxH overrides it for experiments.
 */
#define SP_UI_W_DEFAULT     1024
#define SP_UI_H_DEFAULT     600
#define SP_FB_BASE          0x0C000000u   /* res_fb0 anchor              */
#define SP_FB_STEP          0x00600000u   /* 6 MiB per layer (>4.69 MiB) */

/*
 * 每个 fb 窗口的实际基址/大小。
 *
 * 默认按 SP_FB_STEP 平铺，但**以内核命令行里的 res_fbN 为准**——res_fbN 才是
 * 内核写进 fix.smem_start 的锚点，模型自己算的地址只是猜测。两者一旦不一致，
 * 我们抓「背景层」时读到的就是别的对象的内存（而且不会报错，只会一片黑）。
 *
 * 这个坑真实发生过：tools/fb_diag.py 用 4 MiB@0x0C800000 描述 fb1，而模型按
 * 6 MiB 步长算成 0x0C600000，相差 2 MiB。现在 cmdline / IPC 应答 / 帧导出
 * 三方共用这一张表，不可能再错位。
 */
static uint32_t sp_fb_win_addr[3] = {
    SP_FB_BASE, SP_FB_BASE + SP_FB_STEP, SP_FB_BASE + 2 * SP_FB_STEP
};
static uint32_t sp_fb_win_size[3] = { SP_FB_STEP, SP_FB_STEP, SP_FB_STEP };

static void sp_parse_res_fb(const char *cmdline)
{
    unsigned i, miss = 0;

    if (!cmdline) {
        return;
    }
    for (i = 0; i < 3; i++) {
        char key[16], size[32], addr[32];
        const char *p;

        snprintf(key, sizeof(key), "res_fb%u=", i);
        p = strstr(cmdline, key);
        if (!p) {
            miss++;
            continue;
        }
        p += strlen(key);
        if (sscanf(p, "%31[^@]@%31[^ ]", size, addr) != 2) {
            miss++;
            continue;
        }
        sp_fb_win_size[i] = strtoul(size, NULL, 0);
        sp_fb_win_addr[i] = strtoul(addr, NULL, 0);
    }
    fprintf(stderr, "FBWIN: cmdline res_fb0..2 = %08x/%08x (%x) %08x/%08x (%x) "
            "%08x/%08x (%x)%s\n",
            sp_fb_win_addr[0], sp_fb_win_size[0], sp_fb_win_size[0],
            sp_fb_win_addr[1], sp_fb_win_size[1], sp_fb_win_size[1],
            sp_fb_win_addr[2], sp_fb_win_size[2], sp_fb_win_size[2],
            miss ? "  (defaults for missing res_fbN)" : "");
}

/*
 * Power-on animation (tools/make_bootanim.py -> ANM2).
 *
 * On the hardware the first thing the panel ever shows is anm_logo's
 * logo.mkv: the eCos bootloader hands it to the PFC "PE" decoder long before
 * Linux runs, and userspace only calls PlatformControl::Stop_Animation_Logo()
 * once the Launcher has something to draw.  We start at the kernel, so without
 * this the panel is black from power-on to the Qt UI -- which is what the
 * emulator used to look like.
 *
 * SP_BOOT_ANIM=<anm_logo.bin> replays the device's own frames into fb0 at the
 * source rate, holds the last one, and gets out of the way the moment the
 * guest paints over it (that *is* Stop_Animation_Logo from our side).  Nothing
 * here invents pixels: every frame is decoded from the firmware asset.
 */
#define SP_ANIM_MAGIC       "ANM2"
#define SP_ANIM_HDR         24u
#define SP_ANIM_INDEX_ENTRY 8u
#define SP_ANIM_WATCH_MS    100     /* probe period once the logo is held */
#define SP_ANIM_SAMPLE_MS   60      /* frame publish period while it plays */
/* 常态下发布帧的节拍。
 *
 * 之前是 250 ms（4 fps）。原厂界面里的页切换、指示灯闪烁、表盘扫针都在
 * 运行期播放，4 fps 只能抽到几张静止图，观感就是「动画没渲染」。
 * 现在配合下面「内容未变就跳过写盘」的签名去重，静态画面几乎零成本，
 * 所以常态也能用 8 ms 发布。
 *
 * 为什么是 8 而不是更小：客户端 `_fastGrab` 是 12 ms，模型 8 ms 略快于它，
 * 保证每次轮询都有新帧可取。实测（`test/anim_quality.dart`，开机动画窗口）：
 * 16 ms→15.5 fps、8 ms 配 12 ms 轮询→55.7 fps（p50 帧间隔 16 ms，即原厂
 * logo 的原生帧周期）。真正限量的是**轮询间隔**，不是解码或发布。 */
#define SP_FB_PUBLISH_MS    8
#define SP_ANIM_HOLD_MAX_MS 8000    /* give up even if the guest never draws */
#define SP_ANIM_DIFF_PCT    3       /* sampled pixels that mean "guest drew" */

/* Where fb0 currently is: the kernel may flip pages once it owns the panel. */
static uint64_t sp_anim_fb_addr(SP8368State *s)
{
    uint64_t addr = SP_FB_BASE;

    if (!getenv("SP_FB_ADDR") && s->fb_scanout_known[0]) {
        addr += (uint64_t)s->fb_scanout_page[0] * s->ui_w * s->ui_h * 4u;
    }
    return addr;
}

/* Expand one RLE frame into s->anim_frame as BGRA (the panel's 0xAARRGGBB). */
static bool sp_anim_decode(SP8368State *s, uint32_t idx)
{
    uint64_t total = (uint64_t)s->anim_w * s->anim_h;
    size_t ent = SP_ANIM_HDR + idx * SP_ANIM_INDEX_ENTRY;
    uint32_t off = ldl_le_p(s->anim_blob + ent);
    uint32_t len = ldl_le_p(s->anim_blob + ent + 4);
    const uint8_t *p, *end;
    uint32_t *out = (uint32_t *)s->anim_frame;
    uint64_t n = 0;

    if (ent + SP_ANIM_INDEX_ENTRY > s->anim_blob_size ||
        (uint64_t)s->anim_data_off + off + len > s->anim_blob_size) {
        return false;
    }
    p = s->anim_blob + s->anim_data_off + off;
    end = p + len;
    while (p + 3 <= end && n < total) {
        unsigned v = p[0] | p[1] << 8;
        unsigned c = p[2];
        unsigned r, g, b;
        uint32_t px;

        p += 3;
        if (!c) {
            break;              /* early terminator: frame is all black */
        }
        /* RGB565 -> 8 bit by bit replication, the same rounding the panel
         * does, so the logo's white stays pure white. */
        r = (v >> 11) & 0x1f;
        g = (v >> 5) & 0x3f;
        b = v & 0x1f;
        px = 0xff000000u | ((r << 3) | (r >> 2)) << 16 |
             ((g << 2) | (g >> 4)) << 8 | ((b << 3) | (b >> 2));
        while (c-- && n < total) {
            out[n++] = px;
        }
    }
    return n == total;
}

static void sp_anim_deliver(SP8368State *s)
{
    address_space_write(&address_space_memory, sp_anim_fb_addr(s),
                        MEMTXATTRS_UNSPECIFIED, s->anim_frame,
                        (size_t)s->ui_w * s->ui_h * 4u);
}

/* Has the guest drawn over the page we are holding a frame on? */
static bool sp_anim_guest_painted(SP8368State *s)
{
    const unsigned samples = 512;
    uint64_t total = (uint64_t)s->ui_w * s->ui_h;
    uint64_t step = total / samples;
    uint64_t base = sp_anim_fb_addr(s);
    const uint32_t *ref = (const uint32_t *)s->anim_frame;
    unsigned i, diff = 0;

    if (!step) {
        return true;
    }
    for (i = 0; i < samples; i++) {
        uint32_t px = 0;

        address_space_read(&address_space_memory,
                           base + (uint64_t)i * step * 4u,
                           MEMTXATTRS_UNSPECIFIED, &px, 4);
        if (px != ref[(uint64_t)i * step]) {
            diff++;
        }
    }
    return diff * 100 >= samples * SP_ANIM_DIFF_PCT;
}

static void sp_anim_stop(SP8368State *s)
{
    size_t bytes = (size_t)s->ui_w * s->ui_h * 4u;
    uint32_t *cur = g_malloc(bytes);
    const uint32_t *ref = (const uint32_t *)s->anim_frame;
    size_t i, cleared = 0;

    s->anim_running = false;

    if (s->anim_snapshot) {
        /*
         * Put the panel back to whatever the guest had drawn before the logo
         * replay (its standby / Launcher frame) instead of leaving the logo's
         * last frame, or -- worse -- a black screen.  The logo itself is gone
         * because we overwrite the whole page with the snapshot.  This is what
         * makes the cluster "light up" straight into its real UI after boot,
         * rather than flashing black.
         */
        address_space_write(&address_space_memory, sp_anim_fb_addr(s),
                            MEMTXATTRS_UNSPECIFIED, s->anim_snapshot, bytes);
        g_free(s->anim_snapshot);
        s->anim_snapshot = NULL;
        fprintf(stderr, "BOOTANIM: restored pre-anim frame, stopped at %u frames\n",
                s->anim_next);
        g_free(cur);
        return;
    }

    /*
     * No snapshot (animation played at power-on, before any guest paint): take
     * the leftover logo back out so the ZEEHO mark does not stay stuck.
     */
    address_space_read(&address_space_memory, sp_anim_fb_addr(s),
                       MEMTXATTRS_UNSPECIFIED, cur, bytes);
    for (i = 0; i < bytes / 4; i++) {
        if (cur[i] && cur[i] == ref[i]) {
            cur[i] = 0;
            cleared++;
        }
    }
    if (cleared) {
        address_space_write(&address_space_memory, sp_anim_fb_addr(s),
                            MEMTXATTRS_UNSPECIFIED, cur, bytes);
    }
    g_free(cur);
    fprintf(stderr, "BOOTANIM: guest took the panel over after %u frames, "
            "cleared %zu stale px\n", s->anim_next, cleared);
}

static void sp_anim_tick(void *opaque)
{
    SP8368State *s = opaque;
    int64_t now = qemu_clock_get_ns(QEMU_CLOCK_VIRTUAL);

    if (!s->anim_running) {
        return;
    }
    if (s->anim_next < s->anim_frames) {
        if (!sp_anim_decode(s, s->anim_next)) {
            fprintf(stderr, "BOOTANIM: frame %u corrupt, stopping\n",
                    s->anim_next);
            s->anim_running = false;
            return;
        }
        sp_anim_deliver(s);
        if (s->anim_trace) {
            fprintf(stderr, "BOOTANIM: frame %u/%u at %lld ms\n", s->anim_next,
                    s->anim_frames, (long long)(now / 1000000));
        }
        s->anim_next++;
        if (s->anim_next == s->anim_frames) {
            s->anim_hold_since = now;
        }
        timer_mod(s->anim_timer, now + s->anim_period_ns);
        return;
    }

    if (sp_anim_guest_painted(s)) {
        sp_anim_stop(s);
        return;
    }
    if (now - s->anim_hold_since > s->anim_hold_max_ns) {
        fprintf(stderr, "BOOTANIM: no guest paint after %lld ms, stopping\n",
                (long long)(s->anim_hold_max_ns / 1000000));
        sp_anim_stop(s);
        return;
    }
    timer_mod(s->anim_timer, now + SP_ANIM_WATCH_MS * 1000000LL);
}

/* Power-off "logo out": replay the same asset backwards.  Delivers frame
 * `shutdown_frames-1 - shutdown_next` each tick until we reach frame 0. */
static void sp_shutdown_tick(void *opaque)
{
    SP8368State *s = opaque;
    int64_t now = qemu_clock_get_ns(QEMU_CLOCK_VIRTUAL);

    if (!s->shutdown_running) {
        return;
    }
    if (s->shutdown_next < s->shutdown_frames) {
        uint32_t idx = s->shutdown_frames - 1 - s->shutdown_next;
        if (!sp_anim_decode(s, idx)) {
            fprintf(stderr, "SHUTANIM: frame %u corrupt, stopping\n", idx);
            s->shutdown_running = false;
            return;
        }
        sp_anim_deliver(s);
        if (s->shutdown_trace) {
            fprintf(stderr, "SHUTANIM: frame %u/%u at %lld ms\n",
                    s->shutdown_next, s->shutdown_frames,
                    (long long)(now / 1000000));
        }
        s->shutdown_next++;
        timer_mod(s->shutdown_timer, now + s->shutdown_period_ns);
        return;
    }
    /* Played all the way back to the first frame: hold it briefly, then the
     * guest's own `poweroff -f` takes the panel dark. */
    s->shutdown_running = false;
    fprintf(stderr, "SHUTANIM: done, %u frames (logo out)\n", s->shutdown_frames);
    g_free(s->anim_frame);
    s->anim_frame = NULL;
}

static void sp_shutdown_start(SP8368State *s)
{
    const char *path = getenv("SP_SHUTDOWN_ANIM");
    gchar *buf = NULL;
    gsize len = 0;
    uint32_t frames, w, h, fps, data_off;

    if (!path || !path[0] || !strcmp(path, "0")) {
        path = getenv("SP_BOOT_ANIM"); /* fall back to the boot asset */
    }
    if (!path || !path[0] || !strcmp(path, "0")) {
        return;
    }
    if (!g_file_get_contents(path, &buf, &len, NULL)) {
        fprintf(stderr, "SHUTANIM: cannot read %s\n", path);
        return;
    }
    if (len < SP_ANIM_HDR + 4 || memcmp(buf, SP_ANIM_MAGIC, 4)) {
        fprintf(stderr, "SHUTANIM: %s is not an " SP_ANIM_MAGIC " blob\n", path);
        g_free(buf);
        return;
    }
    frames = ldl_le_p(buf + 8);
    w = ldl_le_p(buf + 12);
    h = ldl_le_p(buf + 16);
    fps = ldl_le_p(buf + 20);
    if (!frames || !fps || !w || !h || w != s->ui_w || h != s->ui_h) {
        fprintf(stderr, "SHUTANIM: %s geometry mismatch (%ux%u vs panel %ux%u)\n",
                path, w, h, s->ui_w, s->ui_h);
        g_free(buf);
        return;
    }
    data_off = ldl_le_p(buf + SP_ANIM_HDR + frames * SP_ANIM_INDEX_ENTRY);
    s->anim_blob = (uint8_t *)buf;   /* shared decode buffer with boot anim */
    s->anim_blob_size = len;
    s->anim_frames = frames;
    s->anim_w = w;
    s->anim_h = h;
    s->anim_fps = fps;
    s->anim_data_off = data_off;
    s->anim_frame = g_malloc((size_t)w * h * 4u);
    s->shutdown_period_ns = NANOSECONDS_PER_SECOND / fps;
    s->shutdown_frames = frames;
    s->shutdown_next = 0;
    s->shutdown_running = true;
    s->shutdown_trace = getenv("SP_SHUTDOWN_TRACE") != NULL;
    s->shutdown_timer = timer_new_ns(QEMU_CLOCK_VIRTUAL, sp_shutdown_tick, s);
    fprintf(stderr, "SHUTANIM: %ux%u %u frames @ %u fps (reverse) from %s\n",
            w, h, frames, fps, path);
    timer_mod(s->shutdown_timer, qemu_clock_get_ns(QEMU_CLOCK_VIRTUAL));
}

static void sp_anim_start(SP8368State *s)
{
    const char *path = getenv("SP_BOOT_ANIM");
    const char *hold_s = getenv("SP_BOOT_ANIM_HOLD_MS");
    gchar *buf = NULL;
    gsize len = 0;
    uint32_t frames, w, h, fps, data_off;

    if (!path || !path[0] || !strcmp(path, "0")) {
        return;
    }
    if (!g_file_get_contents(path, &buf, &len, NULL)) {
        fprintf(stderr, "BOOTANIM: cannot read %s\n", path);
        return;
    }
    if (len < SP_ANIM_HDR + 4 || memcmp(buf, SP_ANIM_MAGIC, 4)) {
        fprintf(stderr, "BOOTANIM: %s is not an " SP_ANIM_MAGIC " blob\n", path);
        g_free(buf);
        return;
    }
    frames = ldl_le_p(buf + 8);
    w = ldl_le_p(buf + 12);
    h = ldl_le_p(buf + 16);
    fps = ldl_le_p(buf + 20);
    if (!frames || !fps || !w || !h ||
        len < SP_ANIM_HDR + (gsize)frames * SP_ANIM_INDEX_ENTRY + 4) {
        fprintf(stderr, "BOOTANIM: %s header is inconsistent\n", path);
        g_free(buf);
        return;
    }
    data_off = ldl_le_p(buf + SP_ANIM_HDR + frames * SP_ANIM_INDEX_ENTRY);
    if (data_off < SP_ANIM_HDR + frames * SP_ANIM_INDEX_ENTRY + 4 ||
        data_off > len) {
        fprintf(stderr, "BOOTANIM: %s payload offset %#x is invalid\n",
                path, data_off);
        g_free(buf);
        return;
    }
    if (w != s->ui_w || h != s->ui_h) {
        /*
         * Refuse rather than scale: a stretched logo would be our invention,
         * and a wrong-size blit would just paint noise over the panel.
         */
        fprintf(stderr, "BOOTANIM: %s is %ux%u but the panel is %ux%u, "
                "skipped\n", path, w, h, s->ui_w, s->ui_h);
        g_free(buf);
        return;
    }

    s->anim_blob = (uint8_t *)buf;
    s->anim_blob_size = len;
    s->anim_frames = frames;
    s->anim_w = w;
    s->anim_h = h;
    s->anim_fps = fps;
    s->anim_data_off = data_off;
    s->anim_frame = g_malloc((size_t)w * h * 4u);
    s->anim_period_ns = NANOSECONDS_PER_SECOND / fps;
    s->anim_next = 0;
    s->anim_hold_since = 0;
    s->anim_running = true;

    /*
     * Save the page we are about to overwrite.  The deferred (wake-file) path
     * replays the logo over a cluster that already drew its standby frame, so on
     * stop we restore that frame instead of going black.  Skip when the panel is
     * still black (animation really is the first thing on screen).
     */
    {
        size_t bytes = (size_t)s->ui_w * s->ui_h * 4u;
        uint8_t *snap = g_malloc(bytes);
        uint64_t base = sp_anim_fb_addr(s);
        uint64_t total = (uint64_t)s->ui_w * s->ui_h;
        unsigned long nonzero = 0;
        uint32_t px;
        uint64_t i;

        address_space_read(&address_space_memory, base, MEMTXATTRS_UNSPECIFIED,
                           snap, bytes);
        for (i = 0; i < total; i += 97) {
            memcpy(&px, snap + i * 4, 4);
            if (px & 0x00ffffffu) nonzero++;
        }
        if (nonzero) {
            s->anim_snapshot = snap;
        } else {
            g_free(snap);
            s->anim_snapshot = NULL;
        }
    }

    s->anim_trace = getenv("SP_BOOT_ANIM_TRACE") != NULL;
    s->anim_hold_max_ns = SP_ANIM_HOLD_MAX_MS * 1000000LL;
    if (hold_s && hold_s[0]) {
        long ms = strtol(hold_s, NULL, 0);

        if (ms >= 0) {
            s->anim_hold_max_ns = (int64_t)ms * 1000000;
        }
    }
    s->anim_timer = timer_new_ns(QEMU_CLOCK_VIRTUAL, sp_anim_tick, s);
    fprintf(stderr, "BOOTANIM: %ux%u %u frames @ %u fps from %s\n", w, h,
            frames, fps, path);
    timer_mod(s->anim_timer, qemu_clock_get_ns(QEMU_CLOCK_VIRTUAL));
    /*
     * The frame sampler is armed 500 ms out for a normal boot, which would
     * miss the whole first half of the reveal (the logo is fully drawn by
     * ~600 ms).  Pull the first sample in so the client sees it draw in.
     */
    if (s->pc_timer && (getenv("SP_FB_FRAME") || getenv("SP_FB_DUMP"))) {
        timer_mod(s->pc_timer, qemu_clock_get_ms(QEMU_CLOCK_VIRTUAL) +
                               SP_ANIM_SAMPLE_MS);
    }
}

static void sp_ipc_fill_fb_info(uint8_t *p, uint32_t len, uint32_t w,
                                uint32_t h)
{
    /* IPC_CMD_DISP_GET_FB_mod_info: fbdss_init treats the 0x174-byte reply as
     * three 0x7c records and, for every record whose +0x04/+0x08 are non-zero,
     * calls _create_device() with that record's index used as the res_fbN
     * selector.
     *
     * AE5I field map, verified in fbdss_init at c07ed108:
     *   +0x00 selector, +0x04 width, +0x08 height
     *   +0x0c buffer count, +0x10 allocation alignment, +0x18 visual
     *   +0x1c name, +0x34 bpp, +0x38 grayscale
     *   +0x3c..0x6b red/green/blue/alpha fb_bitfield triples
     *   +0x70..0x78 are kernel outputs (PA, palette PA, allocation size).
     * By default only window 0 is advertised. SP_FB_MULTI is an experimental
     * probe for whether additional AE5I fb windows enable the PFC background.
     *
     * The anchor that actually ends up in fix.smem_start comes from the *kernel
     * parameter* res_fb0, not from here, so the two must agree.
     */
    const uint32_t bpp = 32;
    const uint32_t stride = w * (bpp / 8);
    /* AE5I fbdss_init (c07ed218): +0xc is the buffer count, +0x10
     * the allocation alignment. The kernel computes ALIGN(w*h*bpp/8,
     * alignment)*buffers. A stride/address here overflows smem_len to zero.
     * c07ed4ae copies four fb_bitfield triples from +0x3c..+0x6b. */
    const uint32_t alignment = 4096;
    const uint32_t red[3] = { 16, 8, 0 };
    const uint32_t green[3] = { 8, 8, 0 };
    const uint32_t blue[3] = { 0, 8, 0 };
    const uint32_t alpha[3] = { 24, 8, 0 };
    const uint32_t fbsize = stride * h;         /* 1024x600: 0x258000 */
    unsigned i, n = getenv("SP_FB_MULTI") ? 3 : 1;

    memset(p, 0, len);
    for (i = 0; i < n && (i + 1) * 0x7c <= len; i++) {
        uint8_t *record = p + i * 0x7c;
        uint32_t sel = i;
        uint32_t fb_addr = sp_fb_win_addr[i];
        /*
         * 缓冲区数不能一律给 2：res_fb1/fb2 只声明 4 MiB，而两帧 1024x600x4
         * 要 4.69 MiB，内核照这个数分配就会越界压到下一个窗口。按声明的
         * 窗口大小能放几帧就给几帧（fb0 的 6 MiB 仍然给 2 帧，行为不变）。
         */
        uint32_t buffers = fbsize ? sp_fb_win_size[i] / fbsize : 1;

        if (buffers < 1) {
            buffers = 1;
        }
        if (buffers > 2) {
            buffers = 2;
        }
        char name[4];

        snprintf(name, sizeof(name), "fb%u", i);
        memcpy(record + 0x00, &sel, 4);
        memcpy(record + 0x04, &w, 4);
        memcpy(record + 0x08, &h, 4);
        memcpy(record + 0x0c, &buffers, 4);
        memcpy(record + 0x10, &alignment, 4);
        memcpy(record + 0x14, &stride, 4);
        memcpy(record + 0x1c, name, sizeof(name) - 1);
        memcpy(record + 0x34, &bpp, 4);
        memcpy(record + 0x3c, red, sizeof(red));
        memcpy(record + 0x48, green, sizeof(green));
        memcpy(record + 0x54, blue, sizeof(blue));
        memcpy(record + 0x60, alpha, sizeof(alpha));
        memcpy(record + 0x70, &fb_addr, 4);
        memcpy(record + 0x74, &fbsize, 4);
        memcpy(record + 0x78, &fbsize, 4);
    }
}

static void sp_dump_fb_registries(SP8368State *s);

static void sp_ipc_stub(SP8368State *s)
{
    uint8_t req[SP_IPC_BLK];
    uint32_t w[SP_IPC_BLK / 4];
    uint32_t id, len, pphys;

    address_space_read(&address_space_memory, SP_PSU_ADDR + SP_PSU_IPC_REQ,
                       MEMTXATTRS_UNSPECIFIED, req, sizeof(req));
    memcpy(w, req, sizeof(w));

    id    = w[2] >> 16;
    len   = w[2] & 0xFFFF;
    pphys = w[6];

    /* AE5I _ipc_swapbuf sends cmd 6, inline {window, buffer index}.
     * Record each accepted window scanout page so snapshots follow flips.
     *
     * ★ 翻页后必须把「新前沿」整页复制到「新后沿」。
     *
     * 这个 Qt QPA 是**增量绘制**的：每帧只重画发生变化的那几块，从不重画背景，
     * 它依赖后沿缓冲里已经存在上一帧的内容（背景仍在，只有动的 item 被重画，
     * 旧位置自然回到背景）。所以该 SoC 的 flip 是「copy front -> back」语义。
     * 模型早先只换了扫描页、没有复制，后沿就一直保留更旧的画面，新内容叠在
     * 旧内容上 ⇒ 文字重影（"骑行获得数据~" 叠在 "10.0km" 上）、进场动画整车
     * 拖尾、底栏零散残块。证据：`early` 进场时 OSD 页面里同时存在 6 份整车
     * 拷贝，且从 monitor pmemsave 出来的页面本身就带这些拷贝（不是合成器的锅）。
     */
    if (id == 6 && len == 8 && w[0] >= 0xC0408000u &&
        w[0] < 0xD0000000u && w[5] < 3 && w[6] <= 1) {
        unsigned win = w[5], page = w[6], other = w[6] ^ 1u;

        s->fb_scanout_page[win] = page;
        s->fb_scanout_known[win] = true;
        if (getenv("SP_FB_TRACE")) {
            fprintf(stderr, "FB scanout window=%u page=%u (IPC cmd 6)\n",
                    win, page);
        }
        if (!getenv("SP_FB_NO_FLIPCOPY") && s->ui_w && s->ui_h &&
            (uint64_t)sp_fb_win_size[win] >=
                (uint64_t)s->ui_w * s->ui_h * 4u * 2u) {
            uint64_t fbsz = (uint64_t)s->ui_w * s->ui_h * 4u;
            uint64_t src = (uint64_t)sp_fb_win_addr[win] + page * fbsz;
            uint64_t dst = (uint64_t)sp_fb_win_addr[win] + other * fbsz;
            uint8_t *tmp = g_malloc(fbsz);

            address_space_read(&address_space_memory, src,
                               MEMTXATTRS_UNSPECIFIED, tmp, fbsz);
            address_space_write(&address_space_memory, dst,
                                MEMTXATTRS_UNSPECIFIED, tmp, fbsz);
            g_free(tmp);
            if (getenv("SP_FB_TRACE")) {
                fprintf(stderr, "FB flipcopy window=%u %u->%u (%llu bytes)\n",
                        win, page, other, (unsigned long long)fbsz);
            }
        }
    }

    if (s->ipc_trace || getenv("SP_PFC_TRACE")) {
        fprintf(stderr, "IPC stub: id=%u len=%u payload=%08x", id, len, pphys);
        if (pphys && len >= 4) {
            /* SP_PFC_TRACE wants the whole payload so we can read any embedded
             * physical-address / layer-config the guest sends for the PFC
             * background (Draw_Background_From_Nand / DMIX plane). */
            unsigned n = (unsigned)len < 256 ? (unsigned)len : 256;
            unsigned i;

            for (i = 0; i + 4 <= n; i += 4) {
                uint32_t pd = 0;

                address_space_read(&address_space_memory, pphys + i,
                                   MEMTXATTRS_UNSPECIFIED, &pd, 4);
                fprintf(stderr, " %08x", pd);
            }
        }
        fprintf(stderr, "\n");
    }
    if (id == 3 && pphys && len >= 0x174) {
        uint8_t buf[0x174];

        sp_ipc_fill_fb_info(buf, sizeof(buf), s->ui_w, s->ui_h);
        address_space_write(&address_space_memory, pphys,
                            MEMTXATTRS_UNSPECIFIED, buf, sizeof(buf));
    }

    /* Dump the framebuffer registries right after the UI-resolution reply
     * (IPC cmd 3) has gone out -- fbdss_init() is about to build fb0 from
     * it, so this is the last chance to see the "before" state. */
    if (getenv("SP_FB_REG")) {
        fprintf(stderr, "FBREG probe: id=%u len=%u\n", id, len);
    }
    if ((s->ipc_trace || getenv("SP_FB_REG")) && id == 3) {
        sp_dump_fb_registries(s);
    }
    /* fbdss_init() builds fb0 between its UI-resolution request (cmd 3) and
     * the follow-up request (cmd 2), so cmd 2 shows the "after" state. */
    if ((s->ipc_trace || getenv("SP_FB_REG")) && id == 2) {
        fprintf(stderr, "FBREG --- after fb creation ---\n");
        sp_dump_fb_registries(s);
    }

    /* §34: mirror id=9 (MID_DISP) "write register" sub-commands into the VPP
     * register file.  The guest's kernel MID_DISP driver would normally write
     * these straight to the hardware at ~0x41e60000; in IPC-stub mode that path
     * is short-circuited, so we replay the write here from the (inline,
     * readable) payload: w[4] = register, w[5] = value, w[3] = extra argument.
     *
     * Measured on this build: only three register writes ever arrive, and all
     * three carry control bits (0x41e5fff8 <- 0x0e/0x3a, 0x41e614c0 <- 0x38).
     * No source-address register is ever programmed, which is consistent with
     * the background being a *platform layer* owned by libpfc_service
     * (PlatformControlImpl: get_bg_info / BackGroundFlipThread /
     * set_background_transparency / draw_background_from_nand) rather than a
     * scanout plane the app fills.  The mirror is kept because it makes those
     * control writes inspectable; it is not a source of background pixels. */
    if (id == 9 && (w[4] & 0xFF000000u) == 0x41000000u &&
        w[4] >= SP_VPP_BASE && w[4] < SP_VPP_BASE + SP_VPP_SIZE) {
        s->vpp_regs[(w[4] - SP_VPP_BASE) >> 2] = w[5];
        if (s->vpp_trace || getenv("SP_PFC_TRACE")) {
            fprintf(stderr, "VPP stub id=9 reg %08x <- %08x\n", w[4], w[5]);
        }
        /* some forms carry a second (reg,val) pair in w[6],w[7] */
        if (w[6] >= SP_VPP_BASE && w[6] < SP_VPP_BASE + SP_VPP_SIZE) {
            s->vpp_regs[(w[6] - SP_VPP_BASE) >> 2] = w[7];
        }
    }

    /* §34: full dump of the id=9 / id=23 mailbox block so we can find which
     * field carries the background bitmap's physical address (and the format /
     * geometry / alpha).  w[0..19] is the raw 80-byte IPC request block. */
    if ((s->vpp_trace || getenv("SP_PFC_TRACE")) && (id == 9 || id == 23)) {
        fprintf(stderr, "VPP-IPC id=%u len=%u blk=", id, len);
        for (int i = 0; i < 20; i++) {
            fprintf(stderr, " %08x", w[i]);
        }
        fprintf(stderr, "\n");
    }

    /* Build the reply header.
     *
     * dword2 = (status << 16) | len, and **bit15 of the status half must be
     * set**: rpc_isr() tests byte[0xb] bit7 to tell a reply to a kernel-side
     * IPC_FunctionCall() (bit7 = 1: copy the block back into the caller's msg,
     * set msg+0x58, wake msg+0x5c) from a peer-initiated request (bit7 = 0:
     * route to the userspace queues at +0x55c/+0x5ac, which is what we hit
     * first -- it answered "no waiter" 0x8FFA = err 3066).
     *
     * The low 12 bits of the same u16 become IPC_FunctionCall's return value
     * (>= 0x200 is reinterpreted as a negative errno), so status 0 = success.
     * dword0 (owner), dword3 (payload end), dword4 (seq) and dword6 (payload
     * phys) are echoed: msg+0x10 must keep matching the seq the sender stashed
     * at payload_end, or rpc_check_seq() rejects the reply. */
    /*
     * Routing.  rpc_isr() picks the destination from the *reply's* own id word
     * (u16 at +0x0a, i.e. the high half of dword2):
     *
     *   bit15 (msg[0xb] bit7) : 1 -> reply to a kernel IPC_FunctionCall()
     *                                 (dword0 is the waiter's msg; copy back,
     *                                  set msg+0x58, wake msg+0x5c)
     *                           0 -> deliver to userspace
     *   bit12 (msg[0xb] bit4) : 0 -> fifo at dev->+0x55c[chan]
     *                           1 -> fifo at dev->+0x5ac[chan]
     *   bits 9..11            : chan = (id >> 9) & 7
     *
     * sp_ipc_read() blocks in rpc_fifo_get() on exactly those fifos, so a
     * reply that only ever takes the kernel branch can never satisfy a
     * userspace read() -- which is what "ipc cmd:-1|0xffffffff err:-1"
     * (sp_ipc_read+0x77) actually is.
     *
     * SP_IPC_MODE selects which destination(s) we feed:
     *   0 (default) kernel only -- the historical behaviour, enough for
     *     fbdss_init's IPC_FunctionCall(3) but leaves userspace reads timing out
     *   1 userspace only (id echoed, bit15 cleared)
     *   2 both: kernel reply first, then a userspace copy ~100 us later
     */
    {
        const char *mode_s = getenv("SP_IPC_MODE");
        int mode = mode_s ? atoi(mode_s) : 0;
        uint32_t usr[SP_IPC_BLK / 4];

        memcpy(usr, req, sizeof(usr));
        usr[2] &= ~0x80000000u;         /* bit15 clear -> userspace fifo */

        {
            const char *c_s = getenv("SP_IPC_CHAN");
            if (c_s) {
                uint32_t idu = usr[2] >> 16;
                idu = (idu & ~0xE00u) | (((uint32_t)atoi(c_s) & 7u) << 9);
                usr[2] = (idu << 16) | (usr[2] & 0xFFFF);
            }
        }

        /*
         * Route the reply by the request's origin, mirroring what the guest
         * kernel's rpc_isr() does when it picks the destination:
         *
         *   id bit15 set   -> kernel-side IPC_FunctionCall()  (copy back into
         *                     the caller's msg object, wake msg+0x5c)
         *   id bit15 clear -> userspace sp_ipc_read()          (route to the
         *                     registered channel fifo)
         *
         * The old default (SP_IPC_MODE=0 => always kernel reply, bit15 set)
         * is exactly why pfc_server's userspace IPC_FunctionCall() "收不到应答"
         * (got 0x8FFA "no waiter") and the PFC background / DMIX plane config
         * was never delivered -- the SoC side (us) must answer on the
         * userspace channel for the launcher's display service to proceed.
         *
         * Robustness: the only kernel-originated ids we know are 3 (UI res) and
         * 6 (scanout swap); treat those as kernel even if their bit15 is not
         * set.  Everything else (9 = disp service, 0x17 = 23 = dov/PFC
         * register, ...) is a userspace request from pfc_server.
         *
         * 0x17 (23) and 9 come from IPC_FunctionCall() *waiters* (libspdovcfg's
         * dov_send_cmd issues cmd 0x17 via IPC_FunctionCall; MID_DISP id 9 is a
         * kernel driver write).  Their requests carry bit15=0 but the reply
         * MUST take the kernel copy-back branch (bit15=1, status 0) or the
         * waiter never wakes -> "PFC_DOV: get dov failed".  So force them
         * kernel even though the id-word does not say so.
         */
        bool req_kernel = ((id & 0x8000u) != 0) || id == 2 || id == 3 ||
                          id == 6 || id == 9 || id == 0x17;
        uint32_t reply[SP_IPC_BLK / 4];

        if (mode == 1) {                /* force userspace */
            memcpy(reply, usr, sizeof(reply));
        } else if (mode == 2) {         /* legacy: kernel reply + delayed copy */
            memcpy(reply, req, sizeof(reply));
            reply[2] = 0x80000000u | (reply[2] & 0xFFFF);
        } else {                        /* mode 0 / auto: by origin */
            if (req_kernel) {
                memcpy(reply, req, sizeof(reply));
                reply[2] = 0x80000000u | (reply[2] & 0xFFFF);
            } else {
                memcpy(reply, usr, sizeof(reply));
            }
        }

        /*
         * DOV command (id 0x17): libspdovcfg's dov_send_cmd reads the u16 at
         * msg+0xc from the reply and treats NON-zero as failure ("get dov
         * failed"); 0 means success (it then copies the returned bytes).  The
         * echo above leaves the request's pointer low-half there, so clear it.
         */
        if (id == 0x17) {
            reply[3] = 0;
            reply[4] = 0;
        }

        address_space_write(&address_space_memory,
                            SP_PSU_ADDR + SP_PSU_IPC_RSP,
                            MEMTXATTRS_UNSPECIFIED, reply, sizeof(reply));

        /* Legacy SP_IPC_MODE=2: a second, delayed copy to the userspace fifo.
         * Auto mode no longer needs it -- a single origin-correct reply is
         * already routed by the guest kernel. */
        if (mode == 2 && !req_kernel) {
            memcpy(s->ipc_pending, usr, sizeof(s->ipc_pending));
            s->ipc_pending_valid = true;
            timer_mod(s->ipc_timer,
                      qemu_clock_get_ns(QEMU_CLOCK_VIRTUAL) + 100 * 1000);
        }
    }

    /* Consume the doorbell so the next transfer's ready-poll passes. */
    s->psu_regs[SP_PSU_IPC_DOORBELL >> 2] = 0;

    if (s->ipc_irq) {
        qemu_irq_pulse(s->ipc_irq);
    }
}

/*
 * Is the userspace fifo rpc_isr() would pick for this block actually there?
 *
 * The device object's global pointer and the fifo-array offsets differ between
 * kernel builds: AE5i uses *0xC08382F8 with the arrays at +0x578 / +0x57c
 * (indexed by the channel in bits 9..11 of the id), while the older 150Aura
 * kernel used *0xC08362F0 with +0x55c / +0x5ac.  Try both so the legacy
 * SP_IPC_MODE=2 delayed-delivery path finds pfc_server's fifo on either.
 *
 * Note: in the normal (mode 0 / auto) path this helper is NOT on the
 * delivery critical path -- a single origin-correct reply is routed by the
 * guest kernel's own rpc_isr().  It is only consulted by the SP_IPC_MODE=2
 * second-delivery fallback.
 */
static bool sp_ipc_fifo_at(uint32_t dev, uint32_t base, uint32_t chan,
                           uint32_t *out)
{
    uint32_t fifo = 0;
    uint32_t off = dev - 0xC0000000u + base + chan * 4;

    address_space_read(&address_space_memory, off, MEMTXATTRS_UNSPECIFIED,
                       &fifo, 4);
    *out = fifo;
    return fifo >= 0xC0000000u && fifo < 0xD0000000u;
}

static bool sp_ipc_user_fifo_ready(SP8368State *s, const uint8_t *blk)
{
    uint32_t dev = 0, fifo = 0, id, chan;
    static const uint32_t devs[] = { 0xC08382F8u, 0xC08362F0u };
    static const uint32_t bases[][2] = { { 0x578, 0x57c }, { 0x55c, 0x5ac } };
    unsigned i, b;

    memcpy(&id, blk + 0x0a, 2);
    chan = (id >> 9) & 7;

    for (i = 0; i < 2; i++) {
        dev = 0;
        address_space_read(&address_space_memory, devs[i] - 0xC0000000u,
                           MEMTXATTRS_UNSPECIFIED, &dev, 4);
        if (dev < 0xC0000000u || dev >= 0xD0000000u) {
            continue;
        }
        for (b = 0; b < 2; b++) {
            if (sp_ipc_fifo_at(dev,
                              ((id & 0x1000u) ? bases[b][1] : bases[b][0]),
                              chan, &fifo)) {
                return true;
            }
        }
    }
    return false;
}

/*
 * Second (userspace) delivery for SP_IPC_MODE=2.  rpc_isr() runs off the
 * interrupt, so the two blocks have to be separated in time -- writing both
 * back to back would let the ISR see only the last one.
 */
static void sp_ipc_deliver_user(void *opaque)
{
    SP8368State *s = opaque;

    if (!s->ipc_pending_valid) {
        return;
    }
    s->ipc_pending_valid = false;

    if (!sp_ipc_user_fifo_ready(s, s->ipc_pending)) {
        if (s->ipc_trace) {
            fprintf(stderr, "IPC deliver: no userspace fifo, dropped\n");
        }
        return;
    }

    address_space_write(&address_space_memory, SP_PSU_ADDR + SP_PSU_IPC_RSP,
                        MEMTXATTRS_UNSPECIFIED, s->ipc_pending,
                        sizeof(s->ipc_pending));
    s->psu_regs[SP_PSU_IPC_DOORBELL >> 2] = 0;
    if (s->ipc_irq) {
        qemu_irq_pulse(s->ipc_irq);
    }
    if (s->ipc_trace) {
        fprintf(stderr, "IPC deliver: userspace copy\n");
    }
}

static void sp_ipc_dump_gic(SP8368State *s)
{
    uint32_t en[8];
    unsigned n, b;
    bool any = false;

    memset(en, 0, sizeof(en));
    address_space_read(&address_space_memory, SP_GIC_DIST_ADDR + 0x100,
                       MEMTXATTRS_UNSPECIFIED, en, sizeof(en));
    fprintf(stderr, "IPC gic enabled:");
    for (n = 0; n < 8; n++) {
        for (b = 0; b < 32; b++) {
            if (en[n] & (1u << b)) {
                fprintf(stderr, " %u", n * 32 + b);
                any = true;
            }
        }
    }
    fprintf(stderr, "%s\n", any ? "" : " (none)");
}

static void sp_ipc_dump_blk(SP8368State *s, const char *what, uint32_t base)
{
    uint8_t buf[SP_IPC_BLK];
    uint32_t w[SP_IPC_BLK / 4];
    int i;

    address_space_read(&address_space_memory, SP_PSU_ADDR + base,
                       MEMTXATTRS_UNSPECIFIED, buf, sizeof(buf));
    memcpy(w, buf, sizeof(w));
    fprintf(stderr, "IPC %s @%05x:", what, base);
    for (i = 0; i < SP_IPC_BLK / 4; i++) {
        fprintf(stderr, "%s%08x", (i % 4) ? " " : "  ", w[i]);
    }
    fprintf(stderr, "\n");

    /* Out-of-line payload: dword2 = (id << 16) | len, dword6 = payload phys. */
    if (w[2] >> 16 && (w[2] & 0xFFFF) > 0x3c && w[6]) {
        uint32_t len = w[2] & 0xFFFF;
        uint32_t off = w[6];
        uint8_t p[64];
        unsigned n = 0;

        while (n < len && n < sizeof(p)) {
            address_space_read(&address_space_memory, off + n,
                               MEMTXATTRS_UNSPECIFIED, p + n, 4);
            n += 4;
        }
        fprintf(stderr, "IPC %s payload @%08x (%u B):", what, off, len);
        for (i = 0; i < (int)n / 4; i++) {
            uint32_t v;
            memcpy(&v, p + i * 4, 4);
            fprintf(stderr, "%s%08x", (i % 4) ? " " : "  ", v);
        }
        fprintf(stderr, "\n");
    }
}

static void sp_i2c_irq_lower_cb(void *opaque)
{
    SP8368State *s = opaque;

    s->i2c_pending = false;
    if (s->i2c_irq) {
        qemu_irq_lower(s->i2c_irq);
    }
}

static void sp_psu_write(void *opaque, hwaddr off, uint64_t val, unsigned size)
{
    SP8368State *s = opaque;

    if (s->psu_trace) {
        fprintf(stderr, "PSU wr %05" HWADDR_PRIx " <- %08x\n", off,
                (uint32_t)val);
    }
    if ((uint32_t)off >= SP_I2C_ADDR && (uint32_t)off < SP_I2C_WINDOW_END) {
        sp_i2c_note(s, off, (uint32_t)val, true);
    }
    /*
     * I2C fast-fail. The driver's last step before blocking is enabling the
     * completion interrupt; report the transfer as finished and pulse the
     * line so the ALS308 light-sensor probe returns at once instead of
     * waiting 10 s per transfer (five of them cost 51 s of boot).
     */
    if (s->i2c_fastfail && (uint32_t)off == SP_I2C_IRQ_ENABLE && (val & 1) &&
        s->i2c_irq) {
        s->psu_regs[SP_I2C_STATUS >> 2] = 0xffffffffu;
        s->psu_regs[SP_I2C_DATA >> 2] = 0xffffffffu;
        s->i2c_fastfail_ops++;
        s->i2c_armed = true;    /* status reads now report "done, NACK" */
        s->i2c_pending = true;
        qemu_irq_raise(s->i2c_irq);
        /* Fallback: drop the level even if nobody reads the status. */
        timer_mod(s->i2c_timer,
                  qemu_clock_get_ns(QEMU_CLOCK_VIRTUAL) + 10 * 1000 * 1000);
        if (getenv("SP_I2C_TRACE")) {
            fprintf(stderr, "I2C fast-fail op %u (IRQ raised)\n",
                    s->i2c_fastfail_ops);
        }
    }
    if ((uint32_t)off == SP_PSU_IPC_DOORBELL && (val & 1)) {
        s->ipc_doors++;
        if (s->ipc_trace) {
            sp_ipc_dump_blk(s, "req", SP_PSU_IPC_REQ);
            if (s->ipc_doors == 1) {
                sp_ipc_dump_gic(s);
            }
        }
        if (s->ipc_stub) {
            uint32_t owner = 0;

            address_space_read(&address_space_memory, SP_PSU_ADDR + SP_PSU_IPC_REQ,
                               MEMTXATTRS_UNSPECIFIED, &owner, sizeof(owner));
            /* Early experimental userspace replies remain capped; valid
             * kernel calls, including framebuffer swaps, must not time out
             * after the first 64 requests. */
            if (s->ipc_doors <= 64 ||
                (owner >= 0xC0408000u && owner < 0xD0000000u)) {
                sp_ipc_stub(s);
            }
        }
    }
    s->psu_regs[(off >> 2) & ((SP_PSU_SIZE / 4) - 1)] = val;
}

/* valid.min_access_size MUST be 1, not 4.
 *
 * Device registers are word sized, so it is tempting to declare 4..4 and keep
 * the handlers word-only.  But arm_cpu_do_transaction_failed() turns a rejected
 * access into a *synchronous external abort* (FSR 0x808, "external abort on
 * non-linefetch"), which is exactly what killed the boot at 54 s:
 *
 *   spsdc_irq+0x1f3   strb.w  r3, [r2, #0xec]     ; byte write to 0xF0803F6C
 *
 * -- a 1-byte write into the SD controller, i.e. phys 0x9C003F6C, which *is*
 * inside this window.  With valid.min_access_size = 4 QEMU refuses the access
 * (MEMTX_DECODE_ERROR) before the handler ever runs.  Declaring 1..4 lets
 * access_with_adjusted_size() do the byte-lane extract/merge around the
 * word-oriented handlers below, which never see a partial access. */
static const MemoryRegionOps sp_psu_ops = {
    .read = sp_psu_read,
    .write = sp_psu_write,
    .endianness = DEVICE_LITTLE_ENDIAN,
    .impl.min_access_size = 4,
    .impl.max_access_size = 4,
    .valid.min_access_size = 1,
    .valid.max_access_size = 4,
};

/* Interrupt plumbing diagnostics.
 *
 * Both the CPU's generic-timer outputs and the GIC's CPU-side IRQ output are
 * routed through these little pass-through adapters so the model can count and
 * trace them. SP_TIMER_TRACE=1 prints the first edges, SP_STACK_DUMP=1 dumps
 * the kernel stack once the tick is well under way -- which is how a stall in
 * the *idle* task still yields a usable caller chain.
 */
static SP8368State *sp_machine;   /* single-core board: one instance */
static bool sp_timer_trace;
static bool sp_stack_dump;

static void sp_stack_dump_once(SP8368State *s)
{
    uint32_t sp = s->cpu->env.regs[13] & ~3u;
    /* kernel linear map: VA 0xC0000000 + phys */
    uint32_t pa = sp - 0xC0000000u;
    int k;

    fprintf(stderr, "STACK va=%08x pa=%08x:\n", sp, pa);
    for (k = 0; k < 256; k++) {
        uint32_t w = 0;
        address_space_read(&address_space_memory, pa + k * 4,
                           MEMTXATTRS_UNSPECIFIED, &w, 4);
        if (w >= 0xC0408000u && w < 0xC0860000u) {
            fprintf(stderr, "  [%02d] %08x\n", k, w);
        }
    }
}

/* Periodic guest PC sampler (SP_PC_TRACE=1).
 *
 * When the guest parks in a `udelay` poll loop there is no MMIO traffic and no
 * console output, so neither the PSU trace nor -d exec tail is much help.  A
 * host-clock timer that samples PC/LR/SP a few times a second plus the return
 * addresses found on the kernel stack gives a usable call chain instead.
 */
/* Dump the kernel printk ring buffer (SP_DUMP_LOG=1).
 *
 * A panic that happens before any console driver registers leaves *nothing* on
 * the UART: printk only buffers, and panic()'s own output never reaches a
 * device.  The text is still in the ring buffer in .data, so scan DRAM for the
 * first record ("Booting Linux on physical CPU") and print the tail of it.
 */
static void sp_dump_klog(SP8368State *s)
{
    /* The ring buffer (__log_buf) lives at the head of .bss: VA 0xC0836000,
     * i.e. physical 0x0836000.  Dump a window of it as text; records carry a
     * small binary header, so only printable runs are shown. */
    const char *env = getenv("SP_KLOG_ADDR");
    uint32_t base = env ? (uint32_t)strtoul(env, NULL, 0) : 0x0836000;
    uint32_t len = 0x200000;
    uint8_t *buf = g_malloc(len);
    char line[220];
    int n = 0;
    uint32_t i;

    address_space_read(&address_space_memory, base, MEMTXATTRS_UNSPECIFIED,
                       buf, len);
    fprintf(stderr, "===== KLOG @%08x =====\n", base);
    for (i = 0; i < len; i++) {
        unsigned char c = buf[i];

        if (c == '\n' || n == (int)sizeof(line) - 1) {
            if (n >= 12) {
                line[n] = 0;
                fprintf(stderr, "%s\n", line);
            }
            n = 0;
        } else if (c >= 0x20 && c < 0x7f) {
            line[n++] = c;
        } else {
            n = 0;
        }
    }
    fprintf(stderr, "===== end KLOG =====\n");
    g_free(buf);
}

/* Framebuffer snapshot (SP_FB_ADDR / SP_FB_W / SP_FB_H, dumped to
 * SP_FB_DUMP=<dir>/fb_<n>.ppm every sample).
 *
 * The panel hangs off the PFC/display controller, which the guest programs with
 * a physical framebuffer address that the kernel took from res_fb0.  We model
 * no scanout engine, so "lighting the panel up" means reading that memory back
 * and writing it out as an image -- 32bpp little-endian BGRA.
 *
 * SP_FB_WINDOW selects one of the experimental AE5I fb0..fb2 windows and maps
 * it to the matching res_fbN kernel parameter. SP_FB_ADDR overrides that mapping
 * when a guest-specific address has been independently confirmed.
 *
 * Alongside the PPM we print a non-black pixel ratio.  This is only a first
 * drawing probe: a non-zero value alone does not prove the selected window,
 * full UI, animation, or PFC composition is correct.
 */
#define SP_FB0_ADDR_DEFAULT     0x0C000000u

/* 便宜的帧签名（FNV-1a，跨步采样约 512 像素）。
 *
 * 用途：`SP_FB_FRAME` 是客户端实时读的帧文件，如果内容没变就没必要重写
 * 1.8 MB。有了它就能把发布节拍提到 25 fps：动画期间每拍都在变 → 正常写；
 * 静止画面 → 只花一次跨步扫描，不落盘。
 */
static uint32_t sp_fb_signature(uint32_t addr, uint32_t w, uint32_t h)
{
    uint64_t npix = (uint64_t)w * h;
    uint64_t step = npix > 512 ? npix / 512 : 1;
    uint32_t sig = 2166136261u;
    uint64_t p;

    for (p = 0; p < npix; p += step) {
        uint32_t px = 0;
        address_space_read(&address_space_memory, addr + p * 4,
                           MEMTXATTRS_UNSPECIFIED, &px, 4);
        sig = (sig ^ px) * 16777619u;
    }
    return sig;
}

/* 诊断：单独导出某一个显示层，并给出它的空间占用图。
 *
 * 为什么必须「并行」导出：主帧通道（SP_FB_FRAME）永远读窗口 0，因为客户端
 * 用 painted% 判断面板是否点亮。把 SP_FB_WINDOW 改成 1 会让窗口 0 不再导出
 * ⇒ 客户端看到全黑 ⇒ 永远卡在 booting（实测踩过）。所以「背景层到底是空的，
 * 还是我们读错了地址」这个问题，只能靠在同一次采样里把各层都抓下来对比。
 *
 * 输出 <dir>/layer<N>.ppm，每拍覆盖不堆文件；painted/alpha/占用图只在
 * 「历史峰值被刷新」时打印一行，避免刷屏。
 */
static void sp_fb_dump_layer(SP8368State *s, unsigned window, const char *dir)
{
    enum { GRID_C = 16, GRID_R = 8 };
    static double peak[3] = { -1.0, -1.0, -1.0 };
    static unsigned peak_sample[3];
    char path[512];
    FILE *f;
    uint64_t addr, nonzero = 0, opaque = 0, total = 0;
    uint32_t w = s->ui_w, h = s->ui_h, x, y;
    unsigned cell[GRID_R][GRID_C];
    uint8_t *row;

    if (!dir || !w || !h || w > 4096 || h > 4096 || window > 2) {
        return;
    }
    addr = sp_fb_win_addr[window];
    if (s->fb_scanout_known[window]) {
        addr += (uint64_t)s->fb_scanout_page[window] * w * h * 4u;
    }

    g_mkdir_with_parents(dir, 0755);
    snprintf(path, sizeof(path), "%s/layer%u.ppm", dir, window);
    f = fopen(path, "wb");
    if (!f) {
        fprintf(stderr, "FBDUMP: cannot create %s: %s\n", path, strerror(errno));
        return;
    }
    memset(cell, 0, sizeof(cell));
    fprintf(f, "P6\n%u %u\n255\n", w, h);
    row = g_malloc(w * 4);
    for (y = 0; y < h; y++) {
        uint8_t *o = g_malloc(w * 3);

        address_space_read(&address_space_memory, addr + (uint64_t)y * w * 4,
                           MEMTXATTRS_UNSPECIFIED, row, w * 4);
        for (x = 0; x < w; x++) {
            uint32_t px = row[x * 4 + 0] | row[x * 4 + 1] << 8 |
                          row[x * 4 + 2] << 16 | row[x * 4 + 3] << 24;
            uint32_t rgb = px & 0x00ffffffu;

            if (rgb) {
                nonzero++;
                cell[(uint64_t)y * GRID_R / h][(uint64_t)x * GRID_C / w]++;
            }
            if (px >> 24) {
                opaque++;
            }
            total++;
            o[x * 3 + 0] = row[x * 4 + 2];
            o[x * 3 + 1] = row[x * 4 + 1];
            o[x * 3 + 2] = row[x * 4 + 0];
        }
        fwrite(o, 3, w, f);
        g_free(o);
    }
    g_free(row);
    fclose(f);

    {
        double painted = total ? (double)nonzero / (double)total : 0.0;

        if (painted <= peak[window]) {
            return;
        }
        peak[window] = painted;
        peak_sample[window] = s->pc_samples ? s->pc_samples : 0;
    }
    fprintf(stderr,
            "FBDUMP layer%u: %08llx %ux%u painted=%.6f alpha=%.6f "
            "peak@sample%u scanout_page=%u\n",
            window, (unsigned long long)addr, w, h,
            total ? (double)nonzero / (double)total : 0.0,
            total ? (double)opaque / (double)total : 0.0,
            peak_sample[window],
            s->fb_scanout_known[window] ? s->fb_scanout_page[window] : 0);
    /*
     * 占用图：# = 该格有非黑像素，. = 全黑。背景墙若存在，右半边应当有
     * 大片 #；整片 . 就说明 guest 从来没往这一层画过东西。
     */
    for (y = 0; y < GRID_R; y++) {
        char line[GRID_C + 1];

        for (x = 0; x < GRID_C; x++) {
            line[x] = cell[y][x] ? '#' : '.';
        }
        line[GRID_C] = '\0';
        fprintf(stderr, "FBDUMP layer%u    |%s|\n", window, line);
    }
}

/* 原始帧发布通道（SP_FB_RAW）：把窗口 0 的 BGRA 字节原样写出，另加一个
 * `.meta` 旁文件（seq / w / h / painted / addr）。**纯诊断用途**，客户端不
 * 使用它——原因见下面这段实测记录，别重复踩坑：
 *
 *  当初的假设是「客户端每帧要 2×61 万次 Dart 循环展开 PPM，一定是动画卡顿
 *  的主因」。做了零拷贝通道（模型直出 BGRA + 客户端 decodeImageFromPixels
 *  (bgra8888)）之后一测，**两种通道的帧间隔模式完全一致**（40/80 ms 交替）
 *  ⇒ 客户端解码从来不是瓶颈。真正的瓶颈是轮询间隔，见 `SP_FB_PUBLISH_MS`
 *  的注释。这条通道因此只保留给宿主侧离线取证（拿 PPM 不方便时用）。
 *
 * 已知缺陷：**开机动画窗口内会提前断流**（实测复现三次，均在 ~830 ms 停住，
 * 之后 2.3 s 才来一帧；同一场景走 PPM 通道可连续输出 6 s、334 帧）。原因
 * 未定位，所以不要用它做动画分析——分析动画请用 SP_FB_FRAME。
 *
 * 去重不用跨步签名单独判定（512 点会漏掉小图标的变化），签名只做一级闸门，
 * 最终由整帧 memcmp 定终局。
 */
static void sp_fb_publish_raw(SP8368State *s, const char *path)
{
    static uint8_t *buf, *shadow;
    static size_t buf_len, shadow_len;
    static bool shadow_valid, sig_valid;
    static uint32_t last_sig;
    static unsigned long seq;
    uint32_t w = s->ui_w, h = s->ui_h;
    uint64_t addr = sp_fb_win_addr[0];
    uint64_t npix, nonzero = 0;
    uint32_t sig;
    size_t need;
    uint32_t x, y;
    char tmp[512], meta[512];
    FILE *f;

    if (!path || !w || !h || w > 4096 || h > 4096) {
        return;
    }
    if (s->fb_scanout_known[0]) {
        addr += (uint64_t)s->fb_scanout_page[0] * w * h * 4u;
    }
    /*
     * 一级闸门：先算 512 点跨步签名。
     *
     * 这一步不能省。整帧 2.4 MB 的 read+memcmp 如果每拍都做，在 16 ms 节拍下
     * 就是每秒 150 MB 的额外内存流量，而 TCG 的 vCPU 抢的是同一份带宽——
     * 实测客户机会被拖慢到 2.8 fps（对照：只读 512 点时 17 fps）。
     * 签名挡住「没变」的绝大多数拍，变化时才付整帧代价。
     */
    sig = sp_fb_signature(addr, w, h);
    if (sig_valid && sig == last_sig) {
        return;
    }
    need = (size_t)w * h * 4u;
    if (need > buf_len) {
        g_free(buf);
        buf = g_malloc(need);
        buf_len = need;
    }
    if (need > shadow_len) {
        g_free(shadow);
        shadow = g_malloc0(need);
        shadow_len = need;
        shadow_valid = false;
    }
    if (!buf || !shadow) {
        return;
    }
    for (y = 0; y < h; y++) {
        address_space_read(&address_space_memory, addr + (uint64_t)y * w * 4,
                           MEMTXATTRS_UNSPECIFIED, buf + (size_t)y * w * 4,
                           w * 4);
    }
    last_sig = sig;
    sig_valid = true;
    /* 二级闸门：签名会撞（512 点可能漏掉小图标），用整帧比较定终局。 */
    if (shadow_valid && memcmp(buf, shadow, need) == 0) {
        return;
    }
    memcpy(shadow, buf, need);
    shadow_valid = true;

    npix = (uint64_t)w * h;
    for (x = 0; x < need; x += 4) {
        if (buf[x] | buf[x + 1] | buf[x + 2]) {
            nonzero++;
        }
    }

    snprintf(tmp, sizeof(tmp), "%s.tmp", path);
    f = fopen(tmp, "wb");
    if (!f) {
        return;
    }
    fwrite(buf, 1, need, f);
    fclose(f);
    if (rename(tmp, path) != 0) {
        fprintf(stderr, "FBRAW: cannot publish %s: %s\n", path,
                strerror(errno));
        return;
    }
    /*
     * 元数据最后写：seq 一旦前进，raw 文件必须已经是新的。客户端先读 meta、
     * seq 没变就直接跳过读取，所以顺序反过来会读到半新半旧的帧。
     */
    seq++;
    snprintf(meta, sizeof(meta), "%s.meta", path);
    f = fopen(meta, "w");
    if (f) {
        fprintf(f, "seq %lu\nw %u\nh %u\npainted %.6f\naddr %08llx\n", seq, w,
                h, npix ? (double)nonzero / (double)npix : 0.0,
                (unsigned long long)addr);
        fclose(f);
    }
}

static void sp_fb_dump(SP8368State *s, unsigned idx)
{
    const char *dir = getenv("SP_FB_DUMP");
    const char *frame = getenv("SP_FB_FRAME");
    const char *a_s = getenv("SP_FB_ADDR");
    const char *window_s = getenv("SP_FB_WINDOW");
    unsigned window = window_s ? strtoul(window_s, NULL, 0) : 0;
    const char *w_s = getenv("SP_FB_W");
    const char *h_s = getenv("SP_FB_H");
    uint32_t addr, w, h, x, y;
    uint64_t nonzero = 0, total = 0;
    uint8_t *row;
    char path[512];
    FILE *f;

    if (!dir && !frame) {
        return;
    }
    if (window > 2) {
        return;
    }
    addr = a_s ? strtoul(a_s, NULL, 0) : sp_fb_win_addr[window];
    w = w_s ? strtoul(w_s, NULL, 0) : s->ui_w;
    h = h_s ? strtoul(h_s, NULL, 0) : s->ui_h;
    if (!w || !h || w > 4096 || h > 4096) {
        return;
    }
    if (!a_s && s->fb_scanout_known[window] && w == s->ui_w && h == s->ui_h) {
        addr += s->fb_scanout_page[window] * (uint64_t)w * h * 4u;
    }

    /*
     * 实时帧路径（SP_FB_FRAME）按内容去重：没变就不重写。
     * 这样发布节拍可以压到 40 ms 而不必每拍都写 1.8 MB。
     * SP_FB_FORCE_REDRAW=1 可强制每拍都写（取证/对比用）。
     */
    if (frame && !getenv("SP_FB_FORCE_REDRAW")) {
        static uint32_t fb_sig[3];
        static bool fb_sig_valid[3];
        uint32_t sig = sp_fb_signature(addr, w, h);
        if (fb_sig_valid[window] && fb_sig[window] == sig) {
            return;
        }
        fb_sig[window] = sig;
        fb_sig_valid[window] = true;
    }

    if (frame) {
        snprintf(path, sizeof(path), "%s.tmp", frame);
    } else {
        snprintf(path, sizeof(path), "%s/fb_%03u.ppm", dir, idx);
    }
    f = fopen(path, "wb");
    if (!f) {
        /*
         * Create the directory ourselves: a missing SP_FB_DUMP directory used
         * to turn every dump into a "cannot create" message and silently lose
         * the painted-pixel metric that is the whole point of the dump.
         */
        if (dir && !frame) {
            g_mkdir_with_parents(dir, 0755);
        }
        f = fopen(path, "wb");
    }
    if (!f) {
        fprintf(stderr, "FBDUMP: cannot create %s\n", path);
        return;
    }
    fprintf(f, "P6\n%u %u\n255\n", w, h);
    if (getenv("SP_FB_COMPOSITE") && !a_s && window == 0 &&
        w == s->ui_w && h == s->ui_h) {
        /*
         * PFC-style layer stack: the background (window 1) sits under the
         * Qt OSD (window 0).  OSD pixels are BGRA; an empty pixel is either
         * transparent or black, and either way the background must show
         * through, so a non-black OSD pixel wins and everything else falls
         * back to the background.  With a black background this is byte
         * identical to the single-window dump, so it cannot regress.
         */
        uint32_t *bg = g_new0(uint32_t, w * h);
        uint32_t bgaddr = sp_fb_win_addr[1];

        if (s->fb_scanout_known[1]) {
            bgaddr += s->fb_scanout_page[1] * (uint64_t)w * h * 4u;
        }
        address_space_read(&address_space_memory, bgaddr,
                           MEMTXATTRS_UNSPECIFIED, bg, w * h * 4);
        row = g_malloc(w * 4);
        for (y = 0; y < h; y++) {
            uint8_t *o = g_malloc(w * 3);

            address_space_read(&address_space_memory,
                               addr + (uint64_t)y * w * 4,
                               MEMTXATTRS_UNSPECIFIED, row, w * 4);
            for (x = 0; x < w; x++) {
                uint32_t osdpx = row[x * 4 + 0] | row[x * 4 + 1] << 8 |
                                 row[x * 4 + 2] << 16 | row[x * 4 + 3] << 24;
                uint32_t px = (osdpx & 0x00ffffffu) ? osdpx
                                                    : bg[(uint64_t)y * w + x];
                uint8_t r = (px >> 16) & 0xff;
                uint8_t g = (px >> 8) & 0xff;
                uint8_t b = px & 0xff;

                if (r | g | b) {
                    nonzero++;
                }
                total++;
                o[x * 3 + 0] = r;
                o[x * 3 + 1] = g;
                o[x * 3 + 2] = b;
            }
            fwrite(o, 3, w, f);
            g_free(o);
        }
        g_free(row);
        g_free(bg);
        fclose(f);
        if (frame && rename(path, frame) != 0) {
            fprintf(stderr, "FBDUMP: cannot publish %s: %s\n", frame,
                    strerror(errno));
        }
        if (frame && !dir) {
            return;
        }
        fprintf(stderr, "FBDUMP %03u: %08x %ux%u composited painted=%.4f\n",
                idx, addr, w, h,
                total ? (double)nonzero / (double)total : 0.0);
        return;
    }
    row = g_malloc(w * 4);
    for (y = 0; y < h; y++) {
        uint8_t *o = g_malloc(w * 3);

        address_space_read(&address_space_memory, addr + (uint64_t)y * w * 4,
                           MEMTXATTRS_UNSPECIFIED, row, w * 4);
        for (x = 0; x < w; x++) {
            uint32_t px = row[x * 4 + 0] | row[x * 4 + 1] << 8 |
                          row[x * 4 + 2] << 16 | row[x * 4 + 3] << 24;

            if (px & 0x00ffffffu) {
                nonzero++;
            }
            total++;
            o[x * 3 + 0] = row[x * 4 + 2];   /* R (BGRA) */
            o[x * 3 + 1] = row[x * 4 + 1];   /* G */
            o[x * 3 + 2] = row[x * 4 + 0];   /* B */
        }
        fwrite(o, 3, w, f);
        g_free(o);
    }
    g_free(row);
    fclose(f);
    if (frame && rename(path, frame) != 0) {
        fprintf(stderr, "FBDUMP: cannot publish %s: %s\n", frame, strerror(errno));
    }
    if (frame && !dir) {
        return;
    }
    fprintf(stderr, "FBDUMP %03u: %08x %ux%u painted=%.4f\n", idx, addr, w, h,
            total ? (double)nonzero / (double)total : 0.0);
}

/* Full guest-RAM snapshot (SP_RAM_DUMP=<file>, SP_RAM_DUMP_AT=<sample>).
 *
 * Single most useful forensic tool for the display work: once the services are
 * up we can grep the dump offline for the framebuffer, for surface buffers, for
 * string tables, or for anything else that the guest only materialises at
 * runtime.
 */
static void sp_ram_dump(SP8368State *s)
{
    const char *path = getenv("SP_RAM_DUMP");
    uint64_t ram = s->parent.ram_size;
    const uint32_t chunk = 0x100000;
    uint8_t *buf;
    FILE *f;
    uint64_t off;

    if (!path) {
        return;
    }
    f = fopen(path, "wb");
    if (!f) {
        return;
    }
    buf = g_malloc(chunk);
    for (off = 0; off + chunk <= ram; off += chunk) {
        address_space_read(&address_space_memory, off, MEMTXATTRS_UNSPECIFIED,
                           buf, chunk);
        fwrite(buf, 1, chunk, f);
    }
    g_free(buf);
    fclose(f);
    fprintf(stderr, "RAMDUMP: wrote %s (%llu MiB)\n", path,
            (unsigned long long)(ram >> 20));
}

/* Dump the two framebuffer registries the 150Aura kernel keeps.
 *
 * There are TWO of them, and they are NOT the same array:
 *
 *   VA 0xC0800BDC  registered_fb[]  -- the *generic* fbdev core array.
 *      get_fb_info.part.0() (0xC054ABF8) indexes it with the minor number:
 *         movw r3,#0xbdc ; movt r3,#0xc080 ; ldr.w r4,[r3,r4,lsl #2]
 *      and fb_open() (0xC054AC3C) returns -ENODEV when that lookup is NULL.
 *      register_framebuffer() (0xC054A96C) is what fills it:
 *         movw r8,#0xbdc ; movt r8,#0xc080   (r8 = the array base)
 *         str.w r4,[r8,r5,lsl #2]           (0xC054AAAA, r5 = slot index)
 *
 *   VA 0xC0849684  the Sunplus vendor table, written by fbdss_init()
 *      (0xC07EB62E: movw r3,#0x9684 ; movt r3,#0xc084 ; str.w r4,[r3,r8,lsl#2])
 *
 * The kernel maps VA 0xC0000000.. to physical 0x0.., so PA = VA - 0xC0000000.
 */
#define SP_FB_REG_GENERIC_VA  0xC0800BDCu
#define SP_FB_REG_VENDOR_VA   0xC0849684u

static void sp_dump_fb_registries(SP8368State *s)
{
    static const struct {
        const char *name;
        uint32_t va;
    } tables[] = {
        { "generic registered_fb[]", SP_FB_REG_GENERIC_VA },
        { "vendor fb table       ", SP_FB_REG_VENDOR_VA   },
    };
    unsigned t;

    for (t = 0; t < ARRAY_SIZE(tables); t++) {
        uint32_t pa = tables[t].va - 0xC0000000u;
        uint32_t w[8];
        unsigned i;

        memset(w, 0, sizeof(w));
        address_space_read(&address_space_memory, pa, MEMTXATTRS_UNSPECIFIED,
                           w, sizeof(w));
        fprintf(stderr, "FBREG %s @VA %08x: ", tables[t].name, tables[t].va);
        for (i = 0; i < ARRAY_SIZE(w); i++) {
            fprintf(stderr, "%08x%s", w[i], i + 1 < ARRAY_SIZE(w) ? " " : "");
        }
        fprintf(stderr, "\n");
    }
}

/* Identify the task that owns the given kernel stack.
 *
 * ARM 4.9 keeps thread_info at the base of the 8 KiB kernel stack and its
 * 'task' member at offset 0xc (flags/preempt_count/addr_limit precede it), so
 * the current task_struct can be reached without any kernel symbol:
 *
 *   thread_info = sp & ~(THREAD_SIZE - 1)
 *   task        = *(u32 *)(thread_info + 0xc)
 *
 * 'comm' has no stable offset across configs, so scan the head of the
 * task_struct for short NUL-terminated printable runs and print them all --
 * enough to recognise init / pfc_server / as_server at a glance.
 */
static void sp_dump_current_task(SP8368State *s, uint32_t sp)
{
    uint32_t ti_pa = (sp & ~0x1fffu) - 0xC0000000u;
    uint32_t task = 0, task_pa, pid = 0;
    uint8_t buf[0x900];
    unsigned i;

    (void)s;
    address_space_read(&address_space_memory, ti_pa + 0xc,
                       MEMTXATTRS_UNSPECIFIED, &task, 4);
    if (task < 0xC0000000u || task >= 0xD8000000u) {
        fprintf(stderr, "   task=<bad %08x>\n", task);
        return;
    }
    task_pa = task - 0xC0000000u;
    address_space_read(&address_space_memory, task_pa + 0x1f0,
                       MEMTXATTRS_UNSPECIFIED, &pid, 4);
    address_space_read(&address_space_memory, task_pa,
                       MEMTXATTRS_UNSPECIFIED, buf, sizeof(buf));
    fprintf(stderr, "   task=%08x pid?=%u comm:", task, pid);
    for (i = 0; i + 2 < sizeof(buf); i++) {
        unsigned n = 0;

        while (n < 16 && i + n < sizeof(buf) &&
               buf[i + n] >= 0x20 && buf[i + n] < 0x7f) {
            n++;
        }
        if (n >= 2 && n < 16 && i + n < sizeof(buf) && buf[i + n] == 0) {
            fprintf(stderr, " +%x='%.*s'", i, (int)n, (const char *)buf + i);
            i += n;
        }
    }
    fprintf(stderr, "\n");

    /* The syscall's pt_regs sit at the very top of the kernel stack and are
     * never overwritten by anything the handler does (it grows downwards), so
     * they still hold the *userspace* pc/lr that issued the syscall.  ARM
     * pt_regs is {uregs[18]}: r0..r15, cpsr, orig_r0 -- at top-0x48. */
    {
        uint32_t regs[18];
        uint32_t top = (sp & ~0x1fffu) + 0x2000u;

        address_space_read(&address_space_memory,
                           top - 0x48 - 0xC0000000u, MEMTXATTRS_UNSPECIFIED,
                           regs, sizeof(regs));
        fprintf(stderr, "   pt_regs: r0=%08x r1=%08x r7=%08x "
                "user_pc=%08x user_lr=%08x cpsr=%08x\n",
                regs[0], regs[1], regs[7], regs[15], regs[14], regs[16]);
    }
}

static void sp_pc_sample(void *opaque)
{
    SP8368State *s = opaque;
    uint32_t pc = (uint32_t)s->cpu->env.regs[15];

    /*
     * SP_WAKE_FILE handshake: the client arms the boot animation at power-on
     * but only wants it to play once the vehicle is unlocked.  It signals that
     * by creating the file; the moment it exists we (re)start the replay and
     * pull the sampler in to 60 ms so the wake animation is seen frame by frame.
     */
    if (s->anim_wake_armed && !s->anim_running && s->anim_wake_path &&
        g_file_test(s->anim_wake_path, G_FILE_TEST_EXISTS)) {
        s->anim_wake_armed = false;
        sp_anim_start(s);
        if (s->pc_timer) {
            timer_mod(s->pc_timer,
                      qemu_clock_get_ms(QEMU_CLOCK_VIRTUAL) + SP_ANIM_SAMPLE_MS);
        }
    }

    if (s->shutdown_wake_armed && !s->shutdown_running && s->shutdown_wake_path &&
        g_file_test(s->shutdown_wake_path, G_FILE_TEST_EXISTS)) {
        s->shutdown_wake_armed = false;
        sp_shutdown_start(s);
    }

    uint32_t lr = (uint32_t)s->cpu->env.regs[14];
    uint32_t sp = (uint32_t)s->cpu->env.regs[13] & ~3u;
    uint32_t pa = sp - 0xC0000000u;
    const char *every_s = getenv("SP_PC_EVERY");
    unsigned every = every_s ? (unsigned)strtoul(every_s, NULL, 0) : 0;
    const char *max_s = getenv("SP_PC_MAX");
    unsigned maxn = max_s ? (unsigned)strtoul(max_s, NULL, 0) : 0;
    bool show = s->pc_samples < (maxn ? maxn : 40) ||
                (every && s->pc_samples % every == 0);
    int k;

    if (show && (!getenv("SP_FB_FRAME") || getenv("SP_PC_TRACE") ||
                 getenv("SP_FB_DUMP"))) {
        fprintf(stderr, "PC[%u] pc=%08x lr=%08x sp=%08x cpsr=%08x\n",
                s->pc_samples, pc, lr, sp,
                (uint32_t)s->cpu->env.uncached_cpsr);
        sp_dump_current_task(s, sp);
        for (k = 0; k < 192; k++) {
            uint32_t w = 0;

            address_space_read(&address_space_memory, pa + k * 4,
                               MEMTXATTRS_UNSPECIFIED, &w, 4);
            if (w >= 0xC0408000u && w < 0xC0860000u) {
                fprintf(stderr, "   stk[%3d] %08x\n", k, w);
            }
        }
    }

    s->pc_samples++;
    if (s->pc_samples == 2 && getenv("SP_DUMP_LOG")) {
        sp_dump_klog(s);
    }
    if (getenv("SP_FB_DUMP") || getenv("SP_FB_FRAME")) {
        sp_fb_dump(s, s->pc_samples);
    }
    sp_fb_publish_raw(s, getenv("SP_FB_RAW"));
    /*
     * 背景层诊断：在同一次采样里并行导出窗口 1/2。
     * 需要节流——16 ms 节拍下每拍写两张 1.8 MB 的诊断图会把 I/O 打满，
     * 默认每 15 拍（≈240 虚拟 ms）一次。峰值比较保证有价值的变化不会被漏掉。
     */
    {
        const char *bgdir = getenv("SP_FB_BG_DUMP");

        if (bgdir) {
            const char *every_s = getenv("SP_FB_BG_EVERY");
            unsigned every = every_s ? (unsigned)strtoul(every_s, NULL, 0) : 15;
            unsigned w;

            if (!every) {
                every = 1;
            }
            if (s->pc_samples % every == 0) {
                for (w = 1; w <= 2; w++) {
                    sp_fb_dump_layer(s, w, bgdir);
                }
            }
        }
    }
    if (getenv("SP_FB_REG")) {
        sp_dump_fb_registries(s);
    }
    {
        const char *at = getenv("SP_RAM_DUMP_AT");
        unsigned want = at ? (unsigned)strtoul(at, NULL, 0) : 120;

        if (getenv("SP_RAM_DUMP") && s->pc_samples == want) {
            sp_ram_dump(s);
        }
    }
    {
        const char *ms_s = getenv("SP_PC_MS");
        unsigned limit = (getenv("SP_FB_DUMP") || getenv("SP_RAM_DUMP"))
                         ? 1000 : 40;
        unsigned ms = ms_s ? (unsigned)strtoul(ms_s, NULL, 0)
                           : (unsigned)SP_FB_PUBLISH_MS;

        /*
         * The boot animation runs at 60 fps for under two seconds.  Publishing
         * the framebuffer at the usual 500 ms would show the client four stills
         * of a full-speed logo reveal, so sample fast while it plays and fall
         * back to the client's interval afterwards.
         */
        if (s->anim_running && ms > SP_ANIM_SAMPLE_MS) {
            ms = SP_ANIM_SAMPLE_MS;
        }
        if (maxn) {
            limit = maxn;
        }
        if ((!maxn && (getenv("SP_FB_FRAME") || getenv("SP_FB_RAW"))) ||
            s->pc_samples < limit) {
            timer_mod(s->pc_timer,
                      qemu_clock_get_ms(QEMU_CLOCK_VIRTUAL) + ms);
        }
    }
}

static void sp_timer_irq_probe(void *opaque, int n, int level)

{
    SP8368State *s = sp_machine;

    if (!s) {
        return;
    }
    if (level) {
        s->timer_irqs[n]++;
    }
    if (sp_timer_trace && s->timer_irqs[n] <= 5) {
        fprintf(stderr, "TIMER irq%d level=%d count=%u pc=%08x psr=%08x\n",
                n, level, s->timer_irqs[n],
                (uint32_t)s->cpu->env.regs[15],
                (uint32_t)s->cpu->env.uncached_cpsr);
    }
    if (sp_stack_dump && s->timer_irqs[n] == 400) {
        sp_stack_dump_once(s);
    }
    if (s->timer_fwd[n]) {
        qemu_set_irq(s->timer_fwd[n], level);
    }
}

static void sp_cpu_irq_probe(void *opaque, int n, int level)
{
    SP8368State *s = sp_machine;

    if (!s) {
        return;
    }
    if (level) {
        s->cpu_irq_edges++;
        if (sp_timer_trace) {
            fprintf(stderr, "CPUIRQ level=%d edges=%u pc=%08x\n", level,
                    s->cpu_irq_edges, (uint32_t)s->cpu->env.regs[15]);
        }
    }
    if (s->cpu_irq_fwd) {
        qemu_set_irq(s->cpu_irq_fwd, level);
    }
}

/* SP_TIMER_TRACE=1: once a second, report how many timer IRQs and CPU IRQ
 * edges have accumulated. Comparing successive lines gives the *instantaneous*
 * tick rate -- essential because the first four seconds look like a healthy
 * 96 Hz while the boot is already crawling. */
static void sp_stat_timer_cb(void *opaque)
{
    SP8368State *s = opaque;

    fprintf(stderr, "STAT timer_irqs=%u cpu_irq_edges=%u pc=%08x psr=%08x\n",
            s->timer_irqs[GTIMER_PHYS], s->cpu_irq_edges,
            (uint32_t)s->cpu->env.regs[15],
            (uint32_t)s->cpu->env.uncached_cpsr);
    if (getenv("SP_FB_REG")) {
        sp_dump_fb_registries(s);
    }
    timer_mod(s->stat_timer, qemu_clock_get_ms(QEMU_CLOCK_VIRTUAL) + 1000);
}

/* ------------------------------------------------------------------ GPU
 *
 * Vivante GPU register block @0x9C110000. The BSP statically maps it at
 * 0xD080D000 (first page of the vmalloc window) and galcore pokes it from
 * gckOS_WriteRegisterEx(); with nothing behind that address the first write
 * raises an external abort, oopses in do_page_fault and panics ("Attempted to
 * kill the idle task").
 *
 * So we keep a plain 32-bit register file here (reads return the last value
 * written, unwritten registers read 0) and can trace every access together
 * with the kernel PC (SP_GPU_TRACE=1) -- that trace is what tells us which
 * galcore wait loop we are stuck in.
 *
 * ------------------------------------------------------------------------
 * Two registers must not behave as plain storage, because they are the exit
 * condition of _ResetGPU (0xC057B910).  Its tail disassembles to:
 *
 *   0xC057BA12  read  0x004 -> [sp+4]
 *   0xC057BA24  lsls  r3, r3, #31      ; isolate bit0
 *   0xC057BA26  bpl   0xC057B92C       ; bit0 == 0 -> retry the whole round
 *   0xC057BA30  read  0x000 -> [sp]
 *   0xC057BA3A  and   r3, #0x30000
 *   0xC057BA3E  cmp   r3, #0x30000
 *   0xC057BA42  bne   0xC057B92C       ; bit16|bit17 != 11 -> retry
 *   0xC057BA46  movs  r0, #0           ; success
 *
 * The round's last write to 0x000 is 0x900 (after `bic #0x80000`), so a plain
 * register file reads back 0x900 -- (0x900 & 0x30000) == 0 -- and the loop can
 * never terminate.  The driver then sits in that ~1 ms retry loop forever and
 * device_initcall never reaches sp_spinand_module_init.
 *
 * On real silicon 0x000 is GCREG_INTR_ACK_REQ and bits 16/17 are the AXI/AHB
 * idle status the reset sequence just forced; 0x004 is GCREG_CHIP_IDLE with
 * bit0 = IP idle.  We model the post-reset result directly: idle is always
 * reported, so a single round of the sequence succeeds.
 */
#define SP_GPU_REG_CHIP_IDLE    0x004u      /* bit0: IP idle                */
#define SP_GPU_REG_INTR_ACK     0x000u      /* bit16|17: AXI/AHB idle       */
#define SP_GPU_IDLE_BIT         0x00000001u
#define SP_GPU_IDLE_ACK_BITS    0x00030000u

/* ------------------------------------------------------------------------
 * Command buffer execution.
 *
 * gckHARDWARE_Execute() (0xC057C1F4) is "start a command buffer":
 *
 *   0xC057C206  write 0x014 <- 0xFFFFFFFF
 *   0xC057C218  write 0x654 <- physical address of the buffer
 *   0xC057C238  write 0x658 <- ((bytes+7) >> 3) | 0x10000     ; bit16 = START
 *
 * so 0x654 is GCREG_CMD_BUFFER_ADDRESS and 0x658 GCREG_CMD_BUFFER_CONTROL.
 * The trace stops dead right after that write: the driver is then waiting for
 * the completion interrupt, which a bare register file can never produce.
 *
 * The interrupt status register is 0x010 -- gckHARDWARE_Interrupt()
 * (0xC057C634) reads exactly that offset and, when it is non-zero, calls
 * gckEVENT_Interrupt(Event, status).  gckEVENT_Interrupt() ORs status into
 * Event->0x3C8 and then wakes one waiter per set bit, so a set bit means
 * "event N finished".
 *
 * Which N?  It is encoded in the command stream by gckHARDWARE_Event()
 * (0xC057C3C4), which emits two words:
 *
 *   word0 = 0x08010E01                      (constant movw/movt pair)
 *   word1 = 0x40 | eventId                  (r3==4 -> 0x40, then orr r6)
 *
 * ...optionally followed by 0x08050100 + 5 zero words when the hardware wants
 * the 32-byte form.  Rather than reverse-engineer the whole Vivante command
 * encoding we scan the buffer for the constant marker and read the id out of
 * the next word.  eventId is forced <= 28 (cmp r6, #0x1C; bls).
 */
#define SP_GPU_REG_CMD_ADDR     0x654u
#define SP_GPU_REG_CMD_CTRL     0x658u
#define SP_GPU_REG_INTR_STATUS  0x010u
#define SP_GPU_CMD_START_BIT    0x00010000u
#define SP_GPU_EVENT_MARKER     0x08010E01u
#define SP_GPU_MAX_CMDBUF       (64u * 1024u)

/* Default GIC line for the GPU.  This is not a guess: galcore exposes
 * `galcore.irqLine` as a kernel parameter and the compiled-in default is read
 * straight out of .data --
 *
 *   /tmp/kstr.txt:  "galcore.irqLine"
 *   __param entry @ 0xC07B9EB4: name(0xC06EE334) mod(0) ops(0xC06D0264)
 *                              perm(0x01A4) arg(0xC0821238)
 *   0xC0821238  = 47
 *
 * (galcore.registerMemBase = 0x9C110000, i.e. our SP_GPU_ADDR, comes out of the
 * same table and confirms the layout.)
 */
#define SP_GPU_IRQ_DEFAULT      47

/*
 * The PC in the trace is useless on its own: every access goes through the
 * thin wrappers gckOS_ReadRegisterEx() (0xC056BC14) / gckOS_WriteRegisterEx()
 * (0xC056BDC4), so the reported PC is always that wrapper + a few bytes.
 *
 * Both wrappers open with `push {r3, r4, r5, r6, r7, lr}` and never move sp
 * again, so the *caller's* return address sits at [sp + 5*4].  Reading it
 * gives the gckHARDWARE / gckHAL routine that actually issued the access,
 * which is what tells us how far the HAL bring-up got.
 */
static uint32_t sp_gpu_caller(CPUARMState *env)
{
    uint32_t sp = env->regs[13] & ~3u;
    uint32_t lr = 0;

    /* sp is in the kernel linear map (0xC0000000 + phys). */
    if (sp >= 0xC0000000u && sp < 0xD0000000u) {
        address_space_read(&address_space_memory, sp - 0xC0000000u + 0x14,
                           MEMTXATTRS_UNSPECIFIED, &lr, 4);
    }
    return lr;
}

/* ------------------------------------------------------------------------
 * SP_GPU_IRQ_SCAN=1: walk every GIC line and pulse it, so we can find out
 * which one galcore actually registered on.  The probe is observable because
 * isrRoutine() -> gckKERNEL_Notify() -> gckHARDWARE_Interrupt() reads register
 * 0x010 every single time it runs, so the line we are looking for is the one
 * that makes "GPU rd 000010" appear in the GPU trace.
 *
 * One line is held high at a time (the previous one is dropped in the same
 * callback) rather than pulsed, because qemu_irq_pulse() lowers the line again
 * before the CPU has had a chance to sample it.
 */
static void sp_irqscan_cb(void *opaque)
{
    SP8368State *s = opaque;
    int prev = s->irqscan_line;
    int next = prev + 1;

    if (prev >= 0 && prev < SP_GIC_NUM_IRQ) {
        qemu_irq_lower(qdev_get_gpio_in(s->gic, prev));
    }
    if (next > 160) {
        fprintf(stderr, "IRQSCAN done\n");
        return;
    }
    fprintf(stderr, "IRQSCAN raise %d\n", next);
    qemu_irq_raise(qdev_get_gpio_in(s->gic, next));
    s->irqscan_line = next;
    timer_mod(s->irqscan_timer,
              qemu_clock_get_ns(QEMU_CLOCK_VIRTUAL) + 30 * 1000 * 1000);
}

/*
 * Raise the GPU interrupt while there is unserviced interrupt status and drop
 * the line again once the driver has consumed it.  Level-triggered on purpose:
 * qemu_irq_pulse() would assert and release inside the same call, and the GIC
 * discards a level that is already low by the time the CPU looks.
 */
static void sp_gpu_update_irq(SP8368State *s)
{
    if (s->gpu_intr_status) {
        qemu_irq_raise(s->gpu_irq);
    } else {
        qemu_irq_lower(s->gpu_irq);
    }
}

/*
 * Scan a captured command buffer for gckHARDWARE_Event() markers and collect
 * the event ids.  Returns the bitmask galcore expects in the interrupt status
 * register (bit N == "event N completed").
 */
static uint32_t sp_gpu_scan_events(SP8368State *s)
{
    uint32_t mask = 0;
    unsigned i;

    for (i = 0; i + 8 <= s->gpu_cmd_len; i += 4) {
        uint32_t w0, w1, id;

        w0 = ldl_le_p(s->gpu_cmd + i);
        if (w0 != SP_GPU_EVENT_MARKER) {
            continue;
        }
        w1 = ldl_le_p(s->gpu_cmd + i + 4);
        id = w1 & 0x1fu;
        if ((w1 & ~0x1fu) == 0x40u && id <= 28u) {
            mask |= 1u << id;
        }
        if (s->gpu_trace) {
            fprintf(stderr, "GPU cmd[%03u] event marker -> id=%u\n", i, id);
        }
    }
    return mask;
}

/* GC2D command and state fields: Etnaviv rnndb cmdstream.xml/state_2d.xml.
 * Implements linear 32-bit CLEAR, BIT_BLT and nearest-neighbour STRETCH_BLT,
 * with source-over blending and PE2 INDEX8-to-ARGB source-copy.
 * Unsupported modes stop the FE instead of completing an unrendered job.
 * Addresses are accepted only when the entire clipped target lies in RAM. */
#define SP_2D_STATE(s, offset) ((s)->gpu_2d_state[((offset) - 0x1200) / 4])

/* MMUv0: bit 31 selects a GPU virtual address; bits 30:12 index a flat
 * array of 4 KiB physical page addresses. The FE and pixel engine have
 * separate page-table registers. This is not the newer two-level MMUv2. */
static bool sp_gpu_mem(SP8368State *s, uint32_t addr, uint8_t *buf,
                       size_t size, unsigned table_reg, bool write)
{
    if ((uint64_t)addr + size > (uint64_t)UINT32_MAX + 1) {
        return false;
    }
    while (size) {
        uint32_t phys = addr;
        size_t chunk = MIN(size, 4096u - (addr & 4095u));

        if (addr & 0x80000000u) {
            uint8_t raw[4];
            uint32_t table = s->gpu_regs[table_reg >> 2];
            uint64_t entry = (uint64_t)table + ((addr & 0x7fffffffu) >> 12) * 4;

            if (!table || (table & 3) || entry + 4 > s->parent.ram_size ||
                address_space_read(&address_space_memory, entry,
                                   MEMTXATTRS_UNSPECIFIED, raw, 4) != MEMTX_OK) {
                return false;
            }
            phys = ldl_le_p(raw);
            if (!phys || (phys & 4095u)) {
                return false;
            }
            phys += addr & 4095u;
        }
        if ((uint64_t)phys + chunk > s->parent.ram_size) {
            return false;
        }
        if (buf && (write ? address_space_write(&address_space_memory, phys,
                                                 MEMTXATTRS_UNSPECIFIED, buf, chunk)
                          : address_space_read(&address_space_memory, phys,
                                                MEMTXATTRS_UNSPECIFIED, buf, chunk))
                   != MEMTX_OK) {
            return false;
        }
        addr += chunk;
        if (buf) {
            buf += chunk;
        }
        size -= chunk;
    }
    return true;
}

static bool sp_gpu_draw_2d(SP8368State *s, uint32_t pc, uint32_t header)
{
    uint32_t cfg = SP_2D_STATE(s, 0x1234);
    uint32_t base = SP_2D_STATE(s, 0x1228);
    uint32_t stride = SP_2D_STATE(s, 0x122c) & 0x3ffff;
    uint32_t clip0 = SP_2D_STATE(s, 0x1260);
    uint32_t clip1 = SP_2D_STATE(s, 0x1264);
    uint32_t color = SP_2D_STATE(s, 0x12c0);
    uint32_t src_cfg = SP_2D_STATE(s, 0x120c);
    uint32_t src_base = SP_2D_STATE(s, 0x1200);
    uint32_t src_stride = SP_2D_STATE(s, 0x1204) & 0x3ffff;
    uint32_t src_origin = SP_2D_STATE(s, 0x1210);
    uint32_t operation = (cfg >> 12) & 0xf;
    uint32_t src_format = (src_cfg >> 24) & 31;
    bool blend = (operation == 2 || operation == 4) &&
                 (SP_2D_STATE(s, 0x127c) & 1);
    bool global_alpha = SP_2D_STATE(s, 0x1280) == 0x31000200;
    bool indexed;
    unsigned count = (header >> 8) & 0xff;
    unsigned data_count = (header >> 16) & 0x7ff;
    unsigned i;

    if (!count || data_count ||
        (cfg & ((1u << 8) | (3u << 16) |
                (3u << 20) | (7u << 24))) ||
        (operation != 0 && operation != 2 && operation != 4) ||
        ((cfg & 31) != 5 && (cfg & 31) != 6) ||
        (SP_2D_STATE(s, 0x1230) & 0x10000) ||
        (SP_2D_STATE(s, 0x126c) & 0x31) ||
        SP_2D_STATE(s, 0x12d4) || !stride ||
        (uint64_t)pc + 8 + 8 * count > (uint64_t)UINT32_MAX + 1) {
        goto unsupported;
    }
    if (operation == 0 && !(s->gpu_regs[0x034 >> 2] & (1u << 7))) {
        goto unsupported; /* PE1.0 uses a distinct 8-byte clear pattern. */
    }
    if ((operation == 2 || operation == 4) &&
        (blend ? ((SP_2D_STATE(s, 0x127c) & ~0x00ff0001u) != 0 ||
                  (SP_2D_STATE(s, 0x1280) != 0x31000000 && !global_alpha) ||
                  (global_alpha ? SP_2D_STATE(s, 0x12d0) != 0x101 :
                                  SP_2D_STATE(s, 0x12d0) > 1))
               : SP_2D_STATE(s, 0x12d0) != 0)) {
        goto unsupported;
    }
    src_format = src_format ? src_format : (src_cfg & 15);
    indexed = src_format == 9;
    if ((operation == 2 || operation == 4) &&
        ((src_cfg & ((3u << 4) | (1u << 7) | (1u << 8) |
                     (3u << 20) | (3u << 30))) ||
         (SP_2D_STATE(s, 0x1208) & 0x10000) || !src_stride ||
         (SP_2D_STATE(s, 0x125c) & 0xff) != 0xcc ||
         (src_format != (cfg & 31) && !(indexed && !blend)))) {
        goto unsupported;
    }
    if (operation == 4 && (src_cfg & (1u << 6))) {
        goto unsupported;
    }
    for (i = 0; i < count; i++) {
        uint8_t raw[8], *pixels;
        g_autofree uint8_t *source_row = NULL;
        g_autofree uint8_t *blend_row = NULL;
        uint32_t top, bottom, x0, y0, x1, y1, x, y, width, height;
        uint64_t end;

        if (!sp_gpu_mem(s, pc + 8 + i * 8, raw, 8, 0x400, false)) {
            goto unsupported;
        }
        top = ldl_le_p(raw);
        bottom = ldl_le_p(raw + 4);
        x0 = MAX(top & 0xffff, clip0 & 0xffff);
        y0 = MAX(top >> 16, clip0 >> 16);
        x1 = MIN(bottom & 0xffff, clip1 & 0xffff);
        y1 = MIN(bottom >> 16, clip1 >> 16);
        if (x1 <= x0 || y1 <= y0) {
            continue;
        }
        end = (uint64_t)base + (uint64_t)(y1 - 1) * stride + (uint64_t)x1 * 4;
        if (x1 > 4096 || y1 > 4096 || x1 * 4 > stride ||
            end > (uint64_t)UINT32_MAX + 1) {
            goto unsupported;
        }
        width = x1 - x0;
        height = y1 - y0;
        for (y = 0; y < height; y++) {
            if (!sp_gpu_mem(s, base + (uint64_t)(y0 + y) * stride + x0 * 4,
                            NULL, width * 4, 0x408, true)) {
                goto unsupported;
            }
        }
        pixels = g_malloc((uint64_t)width * height * 4);
        if (operation == 0) {
            for (x = 0; x < width * height; x++) {
                stl_le_p(pixels + x * 4, color);
            }
        } else {
            uint32_t sx = (src_origin & 0xffff) + x0;
            uint32_t sy = (src_origin >> 16) + y0;
            uint32_t sx_last, sy_last, source_width;
            uint32_t fx = SP_2D_STATE(s, 0x1220) & 0x7fffffff;
            uint32_t fy = SP_2D_STATE(s, 0x1224) & 0x7fffffff;

            if (!(src_cfg & (1u << 6))) { /* absolute source origin */
                sx -= top & 0xffff;
                sy -= top >> 16;
            }
            unsigned src_bpp = indexed ? 1 : 4;
            if (operation == 4) {
                uint32_t left = top & 0xffff, upper = top >> 16;
                uint64_t xa = (src_origin & 0xffff) + ((uint64_t)(x0 - left) * fx >> 16);
                uint64_t xb = (src_origin & 0xffff) + ((uint64_t)(x1 - 1 - left) * fx >> 16);
                uint64_t ya = (src_origin >> 16) + ((uint64_t)(y0 - upper) * fy >> 16);
                uint64_t yb = (src_origin >> 16) + ((uint64_t)(y1 - 1 - upper) * fy >> 16);
                uint32_t source_size = SP_2D_STATE(s, 0x1214);

                if (xb >= (uint64_t)(src_origin & 0xffff) + (source_size & 0xffff) ||
                    yb >= (uint64_t)(src_origin >> 16) + (source_size >> 16) ||
                    xb >= 4096 || yb >= 4096) {
                    g_free(pixels);
                    goto unsupported;
                }
                sx = xa;
                sx_last = xb;
                sy = ya;
                sy_last = yb;
            } else {
                sx_last = sx + width - 1;
                sy_last = sy + height - 1;
            }
            source_width = sx_last - sx + 1;
            end = (uint64_t)src_base + (uint64_t)sy_last * src_stride +
                  (uint64_t)(sx_last + 1) * src_bpp;
            if (sx_last >= 4096 || sy_last >= 4096 ||
                (sx_last + 1) * src_bpp > src_stride ||
                end > (uint64_t)UINT32_MAX + 1) {
                g_free(pixels);
                goto unsupported;
            }
            /* Reuse conversion scratch for the rectangle, rather than allocating
             * and freeing once per scanline. Snapshot before any writes so
             * overlapping copies remain well-defined. */
            if (indexed || operation == 4) {
                source_row = g_malloc(source_width * src_bpp);
            }
            for (y = 0; y < height; y++) {
                uint32_t source_y = operation == 4 ? (src_origin >> 16) +
                    ((uint64_t)(y0 + y - (top >> 16)) * fy >> 16) : sy + y;
                bool convert = indexed || operation == 4;
                uint8_t *source = convert ? source_row :
                                  pixels + (uint64_t)y * width * 4;
                if (!sp_gpu_mem(s, src_base + (uint64_t)source_y *
                                src_stride + sx * src_bpp, source,
                                source_width * src_bpp, 0x408, false)) {
                    g_free(pixels);
                    goto unsupported;
                }
                if (convert) {
                    for (x = 0; x < width; x++) {
                        uint32_t source_x = operation == 4 ?
                            (src_origin & 0xffff) +
                            ((uint64_t)(x0 + x - (top & 0xffff)) * fx >> 16) - sx : x;
                        uint32_t value = indexed ? s->gpu_2d_palette[source[source_x]] :
                                         ldl_le_p(source + source_x * 4);
                        stl_le_p(pixels + ((uint64_t)y * width + x) * 4,
                                 value);
                    }
                }
            }
        }
        if (blend) {
            blend_row = g_malloc(width * 4);
        }
        for (y = 0; y < height; y++) {
            uint8_t *out = pixels + (uint64_t)y * width * 4;
            if (blend) {
                uint8_t *dst = blend_row;
                const char *pixel_trace = getenv("SP_GPU_PIXEL_TRACE");
                unsigned trace_x = 0, trace_y = 0;
                bool trace_row = pixel_trace && s->gpu_pixel_trace_count < 200 &&
                    sscanf(pixel_trace, "%u,%u", &trace_x, &trace_y) == 2 &&
                    trace_x >= x0 && trace_x < x1 && trace_y == y0 + y;
                if (!sp_gpu_mem(s, base + (uint64_t)(y0 + y) * stride + x0 * 4,
                                dst, width * 4, 0x408, false)) {
                    g_free(pixels);
                    goto unsupported;
                }
                for (x = 0; x < width; x++) {
                    uint8_t *sp = out + x * 4, *dp = dst + x * 4;
                    uint32_t before = trace_row && x == trace_x - x0 ? ldl_le_p(sp) : 0;
                    unsigned a = (cfg & 31) == 5 ? 255 : sp[3];
                    unsigned ga = global_alpha ? SP_2D_STATE(s, 0x12c8) >> 24 : 255;
                    unsigned effective_a = (a * ga + 127) / 255;
                    unsigned inv = 255 - effective_a, c;

                    for (c = 0; c < 3; c++) {
                        unsigned src = (SP_2D_STATE(s, 0x12d0) & 1) ?
                                       (sp[c] * a + 127) / 255 : sp[c];
                        if (SP_2D_STATE(s, 0x12d0) & 0x100) {
                            src = (src * ga + 127) / 255;
                        }
                        sp[c] = MIN(255, src + (dp[c] * inv + 127) / 255);
                    }
                    sp[3] = MIN(255, effective_a + (dp[3] * inv + 127) / 255);
                    if (trace_row && x == trace_x - x0) {
                        fprintf(stderr, "GPU PIXEL pc=%08x dst=%08x src=%08x "
                                "under=%08x out=%08x mode=%08x multiply=%08x "
                                "global=%08x\n", pc, base, before, ldl_le_p(dp),
                                ldl_le_p(sp), SP_2D_STATE(s, 0x1280),
                                SP_2D_STATE(s, 0x12d0), SP_2D_STATE(s, 0x12c8));
                        s->gpu_pixel_trace_count++;
                    }
                }
            }
            if (!sp_gpu_mem(s, base + (uint64_t)(y0 + y) * stride + x0 * 4,
                            out, width * 4, 0x408, true)) {
                g_free(pixels);
                goto unsupported;
            }
        }
        g_free(pixels);
    }
    if (getenv("SP_GPU_2D_TRACE")) {
        fprintf(stderr, "GPU 2D %s pc=%08x dst=%08x count=%u\n",
                operation == 0 ? "CLEAR" : operation == 4 ? "STRETCH" :
                blend ? "BLEND" : "BIT_BLT",
                pc, base, count);
    }
    return true;

unsupported:
    fprintf(stderr, "GPU 2D unsupported pc=%08x cmd=%08x cfg=%08x stride=%u\n",
            pc, header, cfg, stride);
    return false;
}

static void sp_gpu_cmd_done(void *opaque)
{
    SP8368State *s = opaque;
    uint32_t done = 0;
    unsigned budget = 512;

    /* The kernel starts the FE once, then patches WAIT/LINK tails in RAM.
     * Scanning only the original prefetch buffer misses every later EVENT,
     * leaving gckOS_WaitUserSignal asleep. Follow the live command stream,
     * yielding on bounded batches so patched LINKs are observed next tick.
     * DRAW_2D implements conservative CLEAR and BIT_BLT subsets. */
    while (s->gpu_fe_running && budget--) {
        uint8_t raw[8];
        uint32_t pc = s->gpu_fe_pc, head, data, op;
        if ((pc & 7) || !sp_gpu_mem(s, pc, raw, sizeof(raw), 0x400, false)) {
            fprintf(stderr, "GPU FE invalid address pc=%08x\n", pc);
            s->gpu_fe_running = false;
            break;
        }
        head = ldl_le_p(raw);
        data = ldl_le_p(raw + 4);
        op = head >> 27;
        if (op == 1) { /* LOAD_STATE, padded to an 8-byte boundary */
            unsigned count = (head >> 16) & 0x3ff;
            unsigned reg = head & 0xffff, j;
            if (!count) {
                count = 1024;
            }
            if ((uint64_t)pc + (count + 1) * 4 > (uint64_t)UINT32_MAX + 1) {
                s->gpu_fe_running = false;
                break;
            }
            for (j = 0; j < count; j++) {
                uint8_t word[4];
                uint32_t value;
                if (!sp_gpu_mem(s, pc + 4 + j * 4, word, 4, 0x400, false)) {
                    fprintf(stderr, "GPU FE invalid state address pc=%08x\n", pc);
                    s->gpu_fe_running = false;
                    break;
                }
                value = ldl_le_p(word);
                if (reg + j >= 0x480 && reg + j < 0x580) {
                    s->gpu_2d_state[reg + j - 0x480] = value;
                }
                if (reg + j >= 0xd00 && reg + j < 0xe00) {
                    s->gpu_2d_palette[reg + j - 0xd00] = value;
                }
                if (getenv("SP_GPU_2D_TRACE") && reg + j >= 0x480 &&
                    reg + j < 0x500) {
                    fprintf(stderr, "GPU 2D state %04x=%08x pc=%08x\n",
                            (reg + j) * 4, value, pc);
                }
                if (reg + j == 0xe01 && (value & 0x60) &&
                    (value & 0x1f) <= 28) {
                    done |= 1u << (value & 0x1f);
                    if (s->gpu_trace) {
                        fprintf(stderr, "GPU FE EVENT pc=%08x value=%08x\n",
                                pc, value);
                    }
                }
            }
            if (!s->gpu_fe_running) {
                break;
            }
            s->gpu_fe_pc += ((count + 2) & ~1u) * 4;
        } else if (op == 4) { /* DRAW_2D */
            if (!sp_gpu_draw_2d(s, pc, head)) {
                s->gpu_fe_running = false;
                break;
            }
            s->gpu_fe_pc += 8 + ((head >> 8) & 0xff) * 8;
        } else if (op == 8) { /* LINK */
            s->gpu_fe_pc = data;
        } else if (op == 2) { /* END */
            s->gpu_fe_running = false;
        } else if (op == 7 && (uint64_t)pc + 16 <= (uint64_t)UINT32_MAX + 1) {
            uint8_t next[8];

            /* The idle FE loops WAIT -> LINK back to WAIT until the driver
             * patches the first word. Poll once per timer tick, not 512 times
             * per tick; keep PC on WAIT so the patched command is observed. */
            if (sp_gpu_mem(s, pc + 8, next, 8, 0x400, false) &&
                (ldl_le_p(next) >> 27) == 8 && ldl_le_p(next + 4) == pc) {
                break;
            }
            s->gpu_fe_pc += 8;
        } else if (op == 3 || op == 7 || op == 9) { /* NOP, WAIT, STALL */
            s->gpu_fe_pc += 8;
        } else {
            if (s->gpu_trace) {
                fprintf(stderr, "GPU FE unsupported pc=%08x cmd=%08x\n", pc, head);
            }
            s->gpu_fe_running = false;
        }
    }
    s->gpu_regs[0x664 >> 2] = s->gpu_fe_pc;
    if (s->gpu_fe_running) {
        timer_mod(s->gpu_timer,
                  qemu_clock_get_ns(QEMU_CLOCK_VIRTUAL) + 1000 * 1000);
    }
    /*
     * *** Do NOT invent an interrupt when the buffer carried no EVENT. ***
     *
     * gckEVENT_Interrupt() decrements Event->0x450 once per set status bit.
     * The buffer galcore submits during init has no EVENT command in it, so
     * nothing had incremented that atom -- reporting a completion anyway drove
     * the counter to -1, and _MonitorTimerFunction() only calls
     * gckKERNEL_Recovery() when that atom is non-zero.  Twenty seconds later
     * the driver declared the GPU stuck, dumped it and parked itself in the
     * "Stop driver to keep scene." delay loop, which kills DirectFB before it
     * ever runs.  The give-away in the dump was
     * "Number of Pending Interrupt: -1".
     *
     * A buffer with no event simply produces no interrupt.
     */
    if (done == 0) {
        return;
    }
    s->gpu_intr_status |= done;
    sp_gpu_update_irq(s);
}

/*
 * 0x658 write with bit16: fetch the buffer, remember its events and finish it
 * shortly afterwards.  The delay is what makes the driver actually go to sleep
 * and take a real interrupt instead of winning a race against a status bit
 * that is already set.
 */
static void sp_gpu_cmd_start(SP8368State *s)
{
    uint32_t addr = s->gpu_regs[SP_GPU_REG_CMD_ADDR >> 2];
    uint32_t ctrl = s->gpu_regs[SP_GPU_REG_CMD_CTRL >> 2];
    uint32_t bytes;

    s->gpu_cmdbufs++;

    /*
     * galcore submits one buffer at a time and waits for its interrupt, but do
     * not rely on it: if a buffer is still in flight, retire it right now so
     * its events are not overwritten by the new one's.
     */
    if (timer_pending(s->gpu_timer)) {
        timer_del(s->gpu_timer);
    }

    bytes = (ctrl & 0xffffu) * 8u;          /* control field counts 8-byte units */
    if (bytes == 0 || bytes > SP_GPU_MAX_CMDBUF) {
        bytes = 0;
    }

    if (s->gpu_cmd == NULL) {
        s->gpu_cmd = g_malloc(SP_GPU_MAX_CMDBUF);
    }
    if (bytes && !sp_gpu_mem(s, addr, s->gpu_cmd, bytes, 0x400, false)) {
        fprintf(stderr, "GPU cmd buffer invalid address=%08x len=%u\n", addr, bytes);
        bytes = 0;
    }
    s->gpu_cmd_len = bytes;
    s->gpu_pending_event = sp_gpu_scan_events(s);
    s->gpu_fe_pc = addr;
    s->gpu_fe_running = bytes != 0;

    if (s->gpu_trace) {
        unsigned i, n = bytes / 4;

        fprintf(stderr, "GPU cmdbuf #%u: addr=%08x len=%u bytes ->\n",
                s->gpu_cmdbufs, addr, bytes);
        for (i = 0; i < n && i < 32; i++) {
            fprintf(stderr, "   [%02u] %08x\n", i, ldl_le_p(s->gpu_cmd + i * 4));
        }
        if (n > 32) {
            fprintf(stderr, "   ... (%u more words)\n", n - 32);
        }
    }

    timer_mod(s->gpu_timer,
              qemu_clock_get_ns(QEMU_CLOCK_VIRTUAL) + 50 * 1000);
}

static uint64_t sp_gpu_read(void *opaque, hwaddr off, unsigned size)
{
    SP8368State *s = opaque;
    CPUARMState *env = current_cpu ? cpu_env(current_cpu) : NULL;
    uint32_t v = s->gpu_regs[(off >> 2) & ((SP_GPU_SIZE / 4) - 1)];

    switch ((uint32_t)off) {
    case SP_GPU_REG_CHIP_IDLE:
        /*
         * One read of 0x004 per _ResetGPU round.  Before the idle bits above
         * were modelled this counter climbed without bound (the loop spun
         * forever); a handful of rounds now means the sequence completed.
         */
        s->gpu_reset_rounds++;
        if (s->gpu_reset_rounds <= 4 && env) {
            fprintf(stderr, "GPU reset round %u (pc=%08" PRIx64 ")\n",
                    s->gpu_reset_rounds, (uint64_t)env->regs[15]);
        }
        v |= SP_GPU_IDLE_BIT;
        break;
    case SP_GPU_REG_INTR_ACK:
        /*
         * Bits 16/17 are status, not latched state: the driver rewrites this
         * register several times per round (0xb00, 0x900, 0x80900, 0x81900,
         * 0x80900, 0x900) and only checks them at the end of the round, so
         * reporting them as always-asserted is what a finished reset looks
         * like.  Keep the value it wrote in the low bits so any other logic
         * reading this register back still sees its own write.
         */
        v |= SP_GPU_IDLE_ACK_BITS;
        break;
    case SP_GPU_REG_INTR_STATUS:
        /*
         * Read-and-clear.  gckHARDWARE_Interrupt() only reads this register --
         * it never writes an acknowledge back -- so if the bit stayed set the
         * line would stay asserted and the GIC would re-enter the ISR forever.
         */
        v = s->gpu_intr_status;
        s->gpu_intr_status = 0;
        sp_gpu_update_irq(s);
        break;
    default:
        break;
    }

    if (s->gpu_trace && env) {
        fprintf(stderr, "GPU rd %06" HWADDR_PRIx " -> %08x  (cl=%08x)\n",
                off, v, sp_gpu_caller(env));
    }
    return v;
}

static void sp_gpu_write(void *opaque, hwaddr off, uint64_t val, unsigned size)
{
    SP8368State *s = opaque;
    CPUARMState *env = current_cpu ? cpu_env(current_cpu) : NULL;

    if (s->gpu_trace && env) {
        fprintf(stderr, "GPU wr %06" HWADDR_PRIx " <- %08x  (cl=%08x)\n",
                off, (uint32_t)val, sp_gpu_caller(env));
    }
    if (s->gpu_trace && env && off == 0) {
        /* off 0 is the galcore "power/clock control" register, touched only at
         * the very start of a hardware init/reset sequence -- a good place to
         * grab the caller chain before the driver parks itself in a wait. */
        sp_stack_dump_once(s);
    }
    s->gpu_regs[(off >> 2) & ((SP_GPU_SIZE / 4) - 1)] = (uint32_t)val;

    switch ((uint32_t)off) {
    case SP_GPU_REG_INTR_ACK:
        /* Write-1-to-clear semantics on the real core; galcore does write this
         * register during reset, so treat any write as an acknowledge. */
        s->gpu_intr_status = 0;
        sp_gpu_update_irq(s);
        break;
    case SP_GPU_REG_CMD_CTRL:
        if ((uint32_t)val & SP_GPU_CMD_START_BIT) {
            sp_gpu_cmd_start(s);
        }
        break;
    default:
        break;
    }
}

static const MemoryRegionOps sp_gpu_ops = {
    .read = sp_gpu_read,
    .write = sp_gpu_write,
    .endianness = DEVICE_LITTLE_ENDIAN,
    .impl.min_access_size = 4,
    .impl.max_access_size = 4,
    .valid.min_access_size = 1,     /* see the note on sp_psu_ops */
    .valid.max_access_size = 4,
};

/* ----------------------------------------------------- VPP / PFC display ctrl
 *
 * §34: a logging/behavioural model of the display controller the guest programs
 * for the P-gear background layer (right-side wall + vehicle).  The guest's
 * kernel MID_DISP driver writes VPP registers here; on a real SoC those writes
 * point a hardware compositor at a guest-decoded bitmap.  We capture the writes
 * so we can later read that bitmap from RAM and composite it faithfully.
 *
 * Base 0x41c00000 / 4 MiB covers the observed register windows
 * (0x41c9cab1, 0x41e5fff8, 0x41e614c0, 0x41e61c34 all fall inside it).
 * (SP_VPP_BASE / SP_VPP_SIZE / SP_VPP_REGS are defined with the other
 * platform constants near SP_GPU_SIZE.)
 */
static uint64_t sp_vpp_read(void *opaque, hwaddr off, unsigned size)
{
    SP8368State *s = opaque;
    uint32_t v = 0;

    if ((off >> 2) < SP_VPP_REGS) {
        v = s->vpp_regs[off >> 2];
    }
    if (s->vpp_trace) {
        fprintf(stderr, "VPP R %08llx sz=%u -> %08x\n",
                (unsigned long long)(SP_VPP_BASE + off), size, v);
    }
    return v;
}

static void sp_vpp_write(void *opaque, hwaddr off, uint64_t val, unsigned size)
{
    SP8368State *s = opaque;
    hwaddr abs = SP_VPP_BASE + off;

    if ((off >> 2) < SP_VPP_REGS) {
        s->vpp_regs[off >> 2] = (uint32_t)val;
    }
    if (s->vpp_trace || getenv("SP_PFC_TRACE")) {
        fprintf(stderr, "VPP W %08llx sz=%u <- %08llx\n",
                (unsigned long long)abs, size, (unsigned long long)val);
    }
}

static const MemoryRegionOps sp_vpp_ops = {
    .read = sp_vpp_read,
    .write = sp_vpp_write,
    .endianness = DEVICE_LITTLE_ENDIAN,
    .impl.min_access_size = 4,
    .impl.max_access_size = 4,
    .valid.min_access_size = 1,
    .valid.max_access_size = 4,
};


/* ------------------------------------------------------- misc IP / NAND BCH
 *
 * Plain register file plus one behavioural exception: the BCH status register
 * reports "not busy" no matter what was written.  sp_bch_reset() sets bit0 and
 * then spins on it, so a storage register would make the poll run until its
 * jiffies-based timeout expires and the probe fail with -ETIMEDOUT.  Returning
 * a cleared bit0 models a reset that completes instantly, which is also what
 * the hardware looks like by the time the driver reads it back.
 */
static uint64_t sp_ip_read(void *opaque, hwaddr off, unsigned size)
{
    SP8368State *s = opaque;
    CPUARMState *env = cpu_env(current_cpu);
    uint32_t v = s->ip_regs[(off >> 2) & ((SP_IP_SIZE / 4) - 1)];

    if ((uint32_t)off == SP_BCH_REG_STATUS) {
        v &= ~1u;               /* reset already finished: bit0 never sticks */
    }

    if (s->ip_trace) {
        fprintf(stderr, "IP rd %06" HWADDR_PRIx " -> %08x  (pc=%08"
                PRIx64 " lr=%08" PRIx64 ")\n", off, v,
                (uint64_t)env->regs[15], (uint64_t)env->regs[14]);
    }
    return v;
}

static void sp_ip_write(void *opaque, hwaddr off, uint64_t val, unsigned size)
{
    SP8368State *s = opaque;
    CPUARMState *env = cpu_env(current_cpu);

    if (s->ip_trace) {
        fprintf(stderr, "IP wr %06" HWADDR_PRIx " <- %08x  (pc=%08"
                PRIx64 " lr=%08" PRIx64 ")\n", off, (uint32_t)val,
                (uint64_t)env->regs[15], (uint64_t)env->regs[14]);
    }
    s->ip_regs[(off >> 2) & ((SP_IP_SIZE / 4) - 1)] = val;
}

static const MemoryRegionOps sp_ip_ops = {
    .read = sp_ip_read,
    .write = sp_ip_write,
    .endianness = DEVICE_LITTLE_ENDIAN,
    .impl.min_access_size = 4,
    .impl.max_access_size = 4,
    .valid.min_access_size = 1,     /* see the note on sp_psu_ops */
    .valid.max_access_size = 4,
};

/* ------------------------------------------------------------ SPI-NAND regs
 *
 * The controller is a command/register machine: the driver writes a command
 * dword, a page/column, a DMA destination and a byte count, then sets the start
 * bit and waits.  Every transfer the driver issued while probing was decoded
 * from the register trace (SP_SPINAND_TRACE=1):
 *
 *   op 0xFF  reset          -> nothing to do
 *   op 0x9F  read id        -> 4 ID bytes in 0x0C     (gates chip detection)
 *   op 0x1F  write to cache -> feature registers (0xA0/0xB0), no-ops for us
 *   op 0x0F  read cache     -> byte-wise from 0x0C, column in 0x08
 *   op 0x00  dma page read  -> 0x08 = page, 0x3C = column, 0x50 = length,
 *                              0x38 = DRAM destination; then a wait_event on
 *                              info->5a4 that ONLY spi_nand_irq() can satisfy.
 *
 * spi_nand_irq (0xC05B3020) clears info->5a4 and W1C-acks 0x48, so the model
 * raises IRQ 55 with the transfer and drops it when the driver writes 0x48 --
 * exactly the level-sensitive handshake the real controller performs.
 */
static void sp_nand_load(SP8368State *s, const char *path)
{
    struct stat st;
    int fd;
    const uint8_t *h;

    s->nand_page_size  = SPN_DEF_PAGE_SIZE;
    s->nand_oob_size   = SPN_DEF_OOB_SIZE;
    s->nand_ppb        = SPN_DEF_PPB;
    s->nand_page_count = SPN_DEF_PAGE_COUNT;
    s->nand_data_off   = 0;
    s->nand_bad_count  = 0;

    if (!path) {
        fprintf(stderr, "SPN: no SP_VDISK given, NAND reads return 0xFF\n");
        return;
    }
    fd = open(path, O_RDONLY);
    if (fd < 0) {
        fprintf(stderr, "SPN: cannot open %s: %s\n", path, strerror(errno));
        return;
    }
    if (fstat(fd, &st) != 0 || st.st_size < (off_t)SPVD_HDR_SIZE) {
        fprintf(stderr, "SPN: %s too small\n", path);
        close(fd);
        return;
    }
    s->nand_map_size = st.st_size;
    /* MAP_PRIVATE + PROT_WRITE gives us copy-on-write: the guest can erase and
     * program pages (BBT updates, runtime_cfg, userdata) while the pristine
     * .spvd on disk stays byte-for-byte untouched -- the image is a factory
     * dump and must never be modified in place. */
    s->nand_map = mmap(NULL, s->nand_map_size, PROT_READ | PROT_WRITE,
                       MAP_PRIVATE, fd, 0);
    close(fd);
    if (s->nand_map == MAP_FAILED) {
        s->nand_map = NULL;
        fprintf(stderr, "SPN: mmap %s failed: %s\n", path, strerror(errno));
        return;
    }
    h = s->nand_map;
    if (memcmp(h, "SPVD", 4) != 0) {
        fprintf(stderr, "SPN: %s is not an SPVD image\n", path);
        return;
    }
    s->nand_page_size  = spvd_rd32(h + 0x08);
    s->nand_ppb        = spvd_rd32(h + 0x10);
    s->nand_page_count = spvd_rd32(h + 0x18);
    s->nand_data_off   = spvd_rd32(h + 0x1C);   /* data_offset, 0x1000 */
    if (!s->nand_data_off) {
        s->nand_data_off = SPVD_HDR_SIZE;
    }
    s->nand_oob_size = SPN_DEF_OOB_SIZE;        /* image stores data only */

    {
        uint32_t n = spvd_rd32(h + 0x28);
        uint32_t i;
        if (n > SPN_MAX_BAD) {
            n = SPN_MAX_BAD;
        }
        s->nand_bad_count = n;
        for (i = 0; i < n; i++) {
            s->nand_bad[i] = spvd_rd32(h + SPVD_BAD_OFF + i * 4);
        }
    }

    fprintf(stderr, "SPN: %s page=%u oob=%u ppb=%u pages=%u bad=%u\n",
            path, s->nand_page_size, s->nand_oob_size, s->nand_ppb,
            s->nand_page_count, s->nand_bad_count);
}

static bool sp_nand_block_is_bad(SP8368State *s, uint32_t page)
{
    uint32_t blk = page / (s->nand_ppb ? s->nand_ppb : 1);
    unsigned i;

    for (i = 0; i < s->nand_bad_count; i++) {
        if (s->nand_bad[i] == blk) {
            return true;
        }
    }
    return false;
}

/* Materialise one page (data + spare) into nand_cache. */
static void sp_nand_fetch_page(SP8368State *s, uint32_t page)
{
    uint32_t total = s->nand_page_size + s->nand_oob_size;
    uint8_t *c = s->nand_cache;

    memset(c, 0xFF, sizeof(s->nand_cache));

    if (s->nand_map && page < s->nand_page_count) {
        uint64_t off = s->nand_data_off +
                       (uint64_t)page * s->nand_page_size;
        if (off + s->nand_page_size <= s->nand_map_size) {
            memcpy(c, s->nand_map + off, s->nand_page_size);
        }
    }
    /* Spare area: everything erased (0xFF) except the bad-block marker, which
     * nand_default_bbt() looks for in the first spare byte.  The five blocks in
     * the .spvd header reproduce the real unit's nand_read_bbt() output. */
    if (sp_nand_block_is_bad(s, page)) {
        c[s->nand_page_size] = 0x00;
    }
    s->nand_cache_pos = 0;
    s->nand_cache_valid = true;
    (void)total;
}

/* Bounded tracing.  A stalled busy-wait polls a single register in a tight
 * loop, so an unconditional SP_SPINAND_TRACE=1 print produced 11.7 M lines in
 * one boot -- minutes of I/O that bury every interesting line.  Everything
 * goes through this gate, which stops after a few hundred lines total. */
static bool sp_spinand_log(SP8368State *s)
{
    if (!s->spinand_trace || s->spinand_logs >= 200000) {
        return false;
    }
    s->spinand_logs++;
    return true;
}

static uint64_t sp_spinand_read(void *opaque, hwaddr off, unsigned size)
{
    SP8368State *s = opaque;
    CPUARMState *env = cpu_env(current_cpu);
    uint32_t v = s->spinand_regs[(off >> 2) & ((SP_SPINAND_SIZE / 4) - 1)];

    switch ((uint32_t)off) {
    case SPN_REG_CMD:
        v &= ~0x80000000u;      /* transfer finished: bit31 never asserts */
        break;
    case SPN_REG_CTRL:
        /*
         * Bit17 is the "dma in flight" flag that sp_spinand_read_page() spins
         * on:
         *
         *   0xC05B4066  ldr.w r2,[ip]      ; ip = reg+0x14
         *   0xC05B406E  lsls  r2,r2,#0xe   ; bit17 -> bit31
         *   0xC05B4070  bmi   0xC05B4066   ; still busy -> loop
         *
         * Our transfer completes inside the write that kicked it, so by the
         * time this register is polled the flag must read back clear.  Leaving
         * the written value (0x6B120000) in the register file wedges the boot
         * in that loop forever -- the DMA itself has already succeeded.
         */
        if (!s->nand_ctrl_busy) {
            v &= ~((1u << 17) | (1u << 21));
        }
        break;
    case SPN_REG_DATA:
        if (s->nand_cache_valid && s->nand_cache_pos + 4 <=
            s->nand_page_size + s->nand_oob_size) {
            v = (uint32_t)s->nand_cache[s->nand_cache_pos] |
                ((uint32_t)s->nand_cache[s->nand_cache_pos + 1] << 8) |
                ((uint32_t)s->nand_cache[s->nand_cache_pos + 2] << 16) |
                ((uint32_t)s->nand_cache[s->nand_cache_pos + 3] << 24);
            s->nand_cache_pos += 4;
        }
        break;
    default:
        break;
    }

    if (sp_spinand_log(s)) {
        fprintf(stderr, "SPN rd %03" HWADDR_PRIx " -> %08x  (pc=%08"
                PRIx64 " lr=%08" PRIx64 ")\n", off, v,
                (uint64_t)env->regs[15], (uint64_t)env->regs[14]);
    }
    return v;
}

static void sp_spinand_do_dma(SP8368State *s, bool to_nand)
{
    uint32_t page = s->spinand_regs[SPN_REG_ADDR >> 2];
    uint32_t col  = s->spinand_regs[SPN_REG_COLUMN >> 2];
    uint32_t len  = s->spinand_regs[SPN_REG_DMA_LEN >> 2];
    uint32_t dst  = s->spinand_regs[SPN_REG_DMA_DST >> 2];
    uint32_t total = s->nand_page_size + s->nand_oob_size;

    sp_nand_fetch_page(s, page);

    if (col >= total) {
        col = 0;
    }
    if (len > total - col) {
        len = total - col;
    }

    /*
     * The destination is reg 0x34, and the transfer always starts there:
     * reg 0x38 is a *second* address that only the full-page read programs
     * (page read: 0x34 = caller buffer, 0x38 = controller bounce buffer;
     * oob read: only 0x34 is written).  Using 0x38 as the destination made
     * every page land in the bounce buffer instead of the yaffs buffer, which
     * is why the rootfs mounted but /init was "missing", and why the spare
     * area never reached the bad-block check.
     */
    if (to_nand) {
        address_space_read(&address_space_memory, dst, MEMTXATTRS_UNSPECIFIED,
                           s->nand_cache + col, len);
    } else {
        address_space_write(&address_space_memory, dst, MEMTXATTRS_UNSPECIFIED,
                            s->nand_cache + col, len);
    }

    s->nand_dma_reads++;
    if (s->spinand_trace && s->nand_dma_reads <= 24) {
        fprintf(stderr, "SPN dma %u %s: page=%u col=%u len=%u dst=%08x "
                "aux=%08x blk=%u\n", s->nand_dma_reads,
                to_nand ? "wr" : "rd", page, col, len, dst,
                s->spinand_regs[SPN_REG_DMA_AUX >> 2],
                page / (s->nand_ppb ? s->nand_ppb : 1));
    }
}

/* Program execute: the page cache becomes the block's content for `page`.
 * The backing store is mapped MAP_PRIVATE, so this is a copy-on-write page
 * and the pristine .spvd on disk is never touched. */
static void sp_nand_store_page(SP8368State *s, uint32_t page)
{
    uint64_t off = s->nand_data_off + (uint64_t)page * s->nand_page_size;

    if (!s->nand_map || page >= s->nand_page_count) {
        return;
    }
    if (off + s->nand_page_size > s->nand_map_size) {
        return;
    }
    memcpy(s->nand_map + off, s->nand_cache, s->nand_page_size);
}

static void sp_nand_erase_block(SP8368State *s, uint32_t page)
{
    uint32_t ppb = s->nand_ppb ? s->nand_ppb : 1;
    uint64_t blk = page / ppb;
    uint64_t off = s->nand_data_off + blk * ppb * s->nand_page_size;
    uint64_t len = (uint64_t)ppb * s->nand_page_size;

    if (!s->nand_map) {
        return;
    }
    if (off + len > s->nand_map_size) {
        return;
    }
    memset(s->nand_map + off, 0xFF, len);
}

static void sp_spinand_write(void *opaque, hwaddr off, uint64_t val,
                             unsigned size)
{
    SP8368State *s = opaque;
    CPUARMState *env = cpu_env(current_cpu);
    uint32_t v = (uint32_t)val;
    /* Snapshot the old value BEFORE storing: the DMA kick is detected as an
     * edge on bit17, and reading it back after the store would always compare
     * the new value against itself (no edge -> no transfer, silently). */
    uint32_t prev = s->spinand_regs[(off >> 2) & ((SP_SPINAND_SIZE / 4) - 1)];

    if (sp_spinand_log(s)) {
        fprintf(stderr, "SPN wr %03" HWADDR_PRIx " <- %08x  (pc=%08"
                PRIx64 " lr=%08" PRIx64 ")\n", off, v,
                (uint64_t)env->regs[15], (uint64_t)env->regs[14]);
    }

    s->spinand_regs[(off >> 2) & ((SP_SPINAND_SIZE / 4) - 1)] = v;

    if ((uint32_t)off == SPN_REG_IRQ_ACK && s->nand_irq_pending) {
        /* W1C: the handler writes back whatever 0x48 read, which drops the
         * line again.  Level-sensitive, so this is the de-assert edge. */
        s->nand_irq_pending = false;
        qemu_set_irq(s->nand_irq, 0);
        return;
    }

    if ((uint32_t)off == SPN_REG_CTRL) {
        bool kick;

        /*
         * Two different "go" conventions are in use, and getting this wrong is
         * silent -- the transfer simply never happens and the driver dies on
         * its 10-jiffy timeout:
         *
         *   simple ops (reset / readid / cache)  write 0x00200000, bit21
         *   dma page read                        write 0x6B100000 (bit20) from
         *                                        read_page, then the completion
         *                                        helper ORs 0x20000 (bit17) and
         *                                        only THEN waits on info->5a4
         *
         * The bit17 edge is the one that matters for DMA: firing on the earlier
         * 0x6B100000 write would raise the interrupt before the helper has set
         * info->5a4 = 1, so the wakeup would be lost and the wait would time
         * out anyway.  cmd_armed (set by every write to reg 0x00) keeps it to
         * exactly one transfer per command dword.
         */
        kick = ((v & (1u << 17)) && !(prev & (1u << 17))) ||
               (v & (1u << 21));

        if (kick && s->nand_cmd_armed) {
            uint32_t cmd = s->spinand_regs[SPN_REG_CMD >> 2];
            uint32_t op = SPN_OPCODE(cmd);
            uint32_t sub = SPN_SUBOP(cmd);
            /* Only the bit17 firing goes through spi_nand_trigger_and_wait_dma,
             * i.e. it is the only case that waits for info->5a4 (cleared by
             * spi_nand_irq).  Raising IRQ 55 for the simple bit21 commands
             * would inject a spurious interrupt into a polled transfer.
             *
             * Erase uses a third convention: bit18 (0x00040000) starts the
             * block-erase engine, then bit21 is ORed in (0x00240000) to fire
             * it, and the driver still waits on info->5a4 without touching a
             * single register -- so bit18 has to raise the irq too, otherwise
             * nand_erase() sits in its 150 ms poll and prints
             * "Wait pio done timeout" forever. */
            bool via_irq = (v & ((1u << 17) | (1u << 18))) != 0;

            s->nand_cmd_armed = false;
            s->spinand_cmds++;
            s->nand_ctrl_busy = true;
            if (s->spinand_trace &&
                (op != SPN_OP_DMA || s->spinand_cmds <= 20)) {
                fprintf(stderr, "SPN xfer %u: cmd=%08x op=%02x sub=%02x "
                        "addr=%08x col=%08x len=%08x\n",
                        s->spinand_cmds, cmd, op, sub,
                        s->spinand_regs[SPN_REG_ADDR >> 2],
                        s->spinand_regs[SPN_REG_COLUMN >> 2],
                        s->spinand_regs[SPN_REG_DMA_LEN >> 2]);
            }

            switch (op) {
            case SPN_OP_READID:
                s->nand_cache_valid = false;
                s->spinand_regs[SPN_REG_DATA >> 2] = SPN_READID_DATA;
                break;
            case SPN_OP_CACHE_READ: {
                /*
                 * Column doubles as the "feature register" selector: 0xA0 block
                 * lock, 0xB0 configuration, 0xC0 status.  They must NOT fall
                 * through to the page cache -- returning the chip ID for a
                 * status poll leaves OIP (bit0) set and spi_nand_waitfunc()
                 * spins forever, which looks exactly like a dead NAND.
                 * Reporting 0 means "ready, no ECC errors" on every poll.
                 */
                uint32_t col = s->spinand_regs[SPN_REG_ADDR >> 2];

                if (col >= 0xA0) {
                    s->nand_cache_valid = false;
                    s->spinand_regs[SPN_REG_DATA >> 2] = 0;
                } else {
                    s->nand_cache_pos = col;   /* bytes out of fetched page */
                }
                break;
            }
            case SPN_OP_DMA:
                sp_spinand_do_dma(s, sub == SPN_SUB_WRITE);
                break;
            case SPN_OP_PROGRAM:
                /* Program execute: the page cache is now the page content. */
                sp_nand_store_page(s, s->spinand_regs[SPN_REG_ADDR >> 2]);
                break;
            case SPN_OP_ERASE:
                sp_nand_erase_block(s, s->spinand_regs[SPN_REG_ADDR >> 2]);
                break;
            default:
                break;
            }

            /*
             * The transfer ran to completion synchronously, so retire the
             * start bits.  Keeping 0x6B120000 in the register file would make
             * the read path report "still busy" forever; see the mask in
             * sp_spinand_read().  bit20/bit30/bit31 are left alone because the
             * driver re-writes the whole dword for the next command anyway.
             */
            s->spinand_regs[SPN_REG_CTRL >> 2] &= ~((1u << 17) | (1u << 21));
            s->nand_ctrl_busy = false;

            if (via_irq && s->nand_irq) {
                s->nand_irq_pending = true;
                qemu_set_irq(s->nand_irq, 1);
            }
        }
    } else if ((uint32_t)off == SPN_REG_CMD) {
        s->nand_cmd_armed = true;       /* a fresh command dword was laid down */
    }
}

static const MemoryRegionOps sp_spinand_ops = {
    .read = sp_spinand_read,
    .write = sp_spinand_write,
    .endianness = DEVICE_LITTLE_ENDIAN,
    .impl.min_access_size = 4,
    .impl.max_access_size = 4,
    .valid.min_access_size = 1,     /* see the note on sp_psu_ops */
    .valid.max_access_size = 4,
};

#define TYPE_SP8368_MACHINE MACHINE_TYPE_NAME("sunplus-sp8368")

OBJECT_DECLARE_SIMPLE_TYPE(SP8368State, SP8368_MACHINE)


static void sp8368_init(MachineState *machine)
{
    SP8368State *s = SP8368_MACHINE(machine);
    const char *kernel_filename = machine->kernel_filename;
    int i;

    sp_machine = s;
    /* res_fbN 是内核真正的 fb 锚点，先对齐再谈抓哪一层。 */
    sp_parse_res_fb(machine->kernel_cmdline);
    sp_timer_trace = getenv("SP_TIMER_TRACE") != NULL;
    sp_stack_dump = getenv("SP_STACK_DUMP") != NULL;
    if (sp_timer_trace || getenv("SP_FB_REG")) {
        s->stat_timer = timer_new_ms(QEMU_CLOCK_VIRTUAL, sp_stat_timer_cb, s);
        timer_mod(s->stat_timer, qemu_clock_get_ms(QEMU_CLOCK_VIRTUAL) + 1000);
    }
    if (getenv("SP_PC_TRACE") || getenv("SP_FB_DUMP") || getenv("SP_FB_FRAME") ||
        getenv("SP_RAM_DUMP") || getenv("SP_FB_REG") ||
        getenv("SP_FB_BG_DUMP") || getenv("SP_FB_RAW")) {
        /*
         * QEMU_CLOCK_VIRTUAL, not REALTIME: the realtime clock does not
         * advance while the vCPU is running a tight guest loop, so a
         * REALTIME-based timer can starve the sampler entirely.
         */
        s->pc_timer = timer_new_ms(QEMU_CLOCK_VIRTUAL, sp_pc_sample, s);
        timer_mod(s->pc_timer, qemu_clock_get_ms(QEMU_CLOCK_VIRTUAL) + 500);
    }

    /* RAM at physical 0 */
    memory_region_init_ram(&s->ram, NULL, "sp8368.ram", machine->ram_size,
                           &error_fatal);
    memory_region_add_subregion(get_system_memory(), SP_DRAM_BASE, &s->ram);

    /*
     * Cortex-A7 with the generic timer at 27 MHz.
     *
     * CNTFRQ must be set BEFORE the CPU is realized.  arm_cpu_realizefn()
     * creates the five QEMUTimers with scale = gt_cntfrq_period_ns(), and a
     * QEMUTimer's scale is frozen at creation; assigning gt_cntfrq_hz after
     * cpu_create() leaves the timers on the old 62.5 MHz / scale-16 default
     * while gt_cntfrq_period_ns() already reports 37 ns.  Every timer_mod()
     * then computes an expiry at 16/37 of "now" -- i.e. in the past -- so the
     * physical-timer callback re-arms itself immediately and QEMU spins in an
     * endless arm/expire storm: 100% host CPU, yet the guest still observes a
     * perfectly normal 100 Hz tick and boots ~50x slower.
     */
    s->cpu = ARM_CPU(object_new(machine->cpu_type));
    qdev_prop_set_uint64(DEVICE(s->cpu), "cntfrq", SP_TIMER_FREQ_HZ);
    qdev_realize(DEVICE(s->cpu), NULL, &error_fatal);

    /* GIC-400: region 0 = distributor, region 1 = CPU interface */
    s->gic = qdev_new(TYPE_ARM_GIC);
    qdev_prop_set_uint32(s->gic, "num-cpu", 1);
    qdev_prop_set_uint32(s->gic, "num-irq", SP_GIC_NUM_IRQ);
    qdev_prop_set_uint32(s->gic, "revision", 2);
    sysbus_realize_and_unref(SYS_BUS_DEVICE(s->gic), &error_fatal);
    sysbus_mmio_map(SYS_BUS_DEVICE(s->gic), 0, SP_GIC_DIST_ADDR);
    sysbus_mmio_map(SYS_BUS_DEVICE(s->gic), 1, SP_GIC_CPU_ADDR);

    /* Connect the GIC's CPU-side outputs to the core's IRQ/FIQ inputs.
     *
     * This is the piece that makes the model an interrupt-driven machine at
     * all: without it every IRQ is enabled, prioritised and left pending
     * forever, the vCPU sits in cpu_ca15_do_idle (WFI) and nothing ever wakes
     * up. That used to look like "galcore deadlocks in gckOS_Delay()" -- the
     * hrtimer really did expire, the GIC really did raise INTID 30, it just
     * had no wire to the CPU.
     *
     * arm_gic exposes num_cpu outputs for IRQ followed by num_cpu for FIQ,
     * so with a single core: 0 = IRQ, 1 = FIQ.
     */
    /*
     * Real interrupt delivery, always on.
     *
     * Historical note (kept because it cost two days): this used to be gated
     * behind SP_GIC_IRQ because connecting the line appeared to make the boot
     * stop dead at the first local_irq_enable().  It never stopped -- it ran
     * ~50x slower.  The cause was the generic-timer scale, not the interrupt
     * line: gt_cntfrq_hz was assigned after cpu_create(), so the QEMUTimers
     * kept the 62.5 MHz / scale-16 default while gt_cntfrq_period_ns()
     * reported 37 ns, and every timer_mod() landed in the past -> an
     * arm/expire storm that pinned the host CPU.  With CNTFRQ set before
     * realize (see above) the tick costs nothing and the line belongs on.
     */
    s->cpu_irq_fwd = qdev_get_gpio_in(DEVICE(s->cpu), ARM_CPU_IRQ);
    sysbus_connect_irq(SYS_BUS_DEVICE(s->gic), 0,
                       qemu_allocate_irq(sp_cpu_irq_probe, NULL, 0));
    sysbus_connect_irq(SYS_BUS_DEVICE(s->gic), 1,
                       qdev_get_gpio_in(DEVICE(s->cpu), ARM_CPU_FIQ));

    /* Wire the CPU's generic-timer outputs into the GIC PPIs.
     *
     * This is NOT optional: without it the kernel boots fine until the first
     * schedule_timeout()/usleep_range() and then never wakes up. Symptom is a
     * boot log that dies at sp_ipc_init()'s "ipc:1.6" with the vCPU halted in
     * cpu_ca15_do_idle and no further printk (tick never fires, jiffies frozen).
     *
     * arm_gic_common's GPIO layout is [0..N-1] = SPIs, then 32 PPIs per CPU,
     * i.e. PPI intid P of CPU 0 is GPIO (num_irq - 32) + P. Same formula the
     * virt board uses (NUM_IRQS + i * GIC_INTERNAL).
     */
    {
        DeviceState *cpudev = DEVICE(s->cpu);
        const int ppi_base = SP_GIC_NUM_IRQ - 32;
        /* Architectural INTIDs (include/hw/arm/bsa.h) */
        const int timer_intid[] = {
            [GTIMER_PHYS]    = 30,  /* ARCH_TIMER_NS_EL1_IRQ */
            [GTIMER_VIRT]    = 27,  /* ARCH_TIMER_VIRT_IRQ */
            [GTIMER_HYP]     = 26,  /* ARCH_TIMER_NS_EL2_IRQ */
            [GTIMER_SEC]     = 29,  /* ARCH_TIMER_S_EL1_IRQ */
            [GTIMER_HYPVIRT] = 28,  /* ARCH_TIMER_NS_EL2_VIRT_IRQ */
        };
        int t;

        for (t = 0; t < ARRAY_SIZE(timer_intid); t++) {
            /* qemu_allocate_irq() passes n back to the handler verbatim, so
             * the timer index travels in n -- never in opaque (a truncated
             * pointer there silently corrupts memory). */
            s->timer_fwd[t] = qdev_get_gpio_in(s->gic,
                                              ppi_base + timer_intid[t]);
            qdev_connect_gpio_out(cpudev, t,
                                  qemu_allocate_irq(sp_timer_irq_probe,
                                                    NULL, t));
        }
    }

    /* PSU/clock and sysctl register stubs, so early clock init stops faulting */
    s->psu_trace = getenv("SP_PSU_TRACE") != NULL;
    s->ipc_trace = getenv("SP_IPC_TRACE") != NULL;
    s->ipc_stub = getenv("SP_IPC_STUB") != NULL;
    memory_region_init_io(&s->psu, OBJECT(s), &sp_psu_ops, s, "sp8368.psu",
                          SP_PSU_SIZE);
    memory_region_add_subregion(get_system_memory(), SP_PSU_ADDR, &s->psu);
    memory_region_init_ram(&s->sysctl, NULL, "sp8368.sysctl", SP_SYSCTL_SIZE,
                           &error_fatal);
    memory_region_add_subregion(get_system_memory(), SP_SYSCTL_ADDR,
                                &s->sysctl);

    /* Misc IP window: the NAND BCH ECC controller lives at 0x9C101000 and its
     * reset-status read is what used to abort the bus (see SP_IP_ADDR). */
    s->ip_trace = getenv("SP_IP_TRACE") != NULL;
    memory_region_init_io(&s->ip, OBJECT(s), &sp_ip_ops, s, "sp8368.ip",
                          SP_IP_SIZE);
    memory_region_add_subregion(get_system_memory(), SP_IP_ADDR, &s->ip);

    /* SPI-NAND controller. Its window lies inside the PSU block, so it must be
     * a SUBREGION of psu rather than a sibling at system_memory level -- two
     * equal-priority siblings covering the same address is a topology error,
     * whereas a subregion is resolved before its container as intended. */
    s->spinand_trace = getenv("SP_SPINAND_TRACE") != NULL;
    memory_region_init_io(&s->spinand, OBJECT(s), &sp_spinand_ops, s,
                          "sp8368.spinand", SP_SPINAND_SIZE);
    memory_region_add_subregion(&s->psu, SP_SPINAND_ADDR - SP_PSU_ADDR,
                                &s->spinand);

    /* SPI-NAND backing store + its completion interrupt.
     *
     * The driver's page read ends in wait_event(info->5a4 == 0), which only
     * spi_nand_irq() can satisfy, so irq 55 has to be a real GIC input.  The
     * arm_gic input GPIO array starts at SPI 32, hence the "55 - 32" index. */
    sp_nand_load(s, getenv("SP_VDISK"));
    s->nand_irq = qdev_get_gpio_in(DEVICE(s->gic), SP_GIC_SPI(55));

    /* EIPC line for the rpc mailbox stub.  The number is not discoverable from
     * a literal pool (rpc_isr is referenced through computed code), so it is
     * settable and defaults to the one that works (see EMULATION.md). */
    {
        const char *irq_s = getenv("SP_IPC_IRQ");
        int ipc_irq = irq_s ? atoi(irq_s) : 84;
        s->ipc_irq = qdev_get_gpio_in(DEVICE(s->gic), SP_GIC_SPI(ipc_irq));
        s->ipc_timer = timer_new_ns(QEMU_CLOCK_VIRTUAL, sp_ipc_deliver_user, s);
    }

    /* Injected board-config blob. SP_FW_ADDR is inside real DRAM, so the blob
     * is deposited directly into the RAM MemoryRegion via address_space_write().
     * The guest kernel ioremap()s SP_FW_ADDR; the SP mapper backs it because it
     * is real, registered RAM. This is pure data injection: no kernel code is
     * modified. (The old fake 0x30000000 MMIO window was rejected by the SP
     * ioremap mapper, which only resolves ranges in its VMA tree.) */
    {
        const char *fwfile = getenv("SP_FW_FILE");
        s->fw_trace = getenv("SP_FW_TRACE") != NULL;
        if (fwfile) {
            FILE *ff = fopen(fwfile, "rb");
            if (ff) {
                fseek(ff, 0, SEEK_END);
                long fz = ftell(ff);
                fseek(ff, 0, SEEK_SET);
                if (fz > 0 && fz <= SP_FW_SIZE) {
                    uint8_t *fb = g_malloc(fz);
                    size_t rd = fread(fb, 1, fz, ff);
                    fclose(ff);
                    if (rd == (size_t)fz) {
                        MemTxResult r = address_space_write(
                            &address_space_memory, SP_FW_ADDR,
                            MEMTXATTRS_UNSPECIFIED, fb, fz);
                        fprintf(stderr,
                                "SP_FW: loaded %ld bytes from %s -> DRAM @0x%llx %s\n",
                                fz, fwfile,
                                (unsigned long long)SP_FW_ADDR,
                                r == MEMTX_OK ? "ok" : "FAIL");
                        if (s->fw_trace) {
                            for (long i = 0; i < fz; i += 4) {
                                uint32_t w = 0;
                                memcpy(&w, fb + i, MIN(4, fz - i));
                                fprintf(stderr,
                                        "FW wr %05lx <- %08x\n",
                                        (unsigned long)(SP_FW_ADDR - SP_FW_ADDR + i),
                                        w);
                            }
                        }
                    } else {
                        fprintf(stderr, "SP_FW: short read %zu/%ld of %s\n",
                                rd, fz, fwfile);
                    }
                    g_free(fb);
                } else {
                    fclose(ff);
                    fprintf(stderr, "SP_FW: bad size %ld for %s\n", fz, fwfile);
                }
            } else {
                fprintf(stderr, "SP_FW: cannot open %s\n", fwfile);
            }
        }
    }

    /* Five K_TTYS UARTs, all inside the PSU window (see sp_uart_base). A
     * Chardev can only feed one frontend, so UART0 uses the -serial chardev
     * and UART1 may use a second -serial backend for the CFCP peer. The
     * remaining UARTs default to separate files for inspection.
     */
    for (i = 0; i < SP_UART_COUNT; i++) {
        Chardev *chr;

        if (i == 3) {
            continue;   /* the BSP prints "K_TTYS: Skip UART3" and never maps it */
        }
        if (serial_hd(i) || i == 0) {
            /*
             * ttyS0 is the console, ttyS1 the CFCP peer.  Any other UART can
             * be given a -serial backend too (the tools use ttyS4 as a clean
             * binary pipe to pull files out of the guest without the console
             * log stream corrupting them).
             */
            chr = serial_hd(i);
        } else {
            char label[16], path[64];

            snprintf(label, sizeof(label), "spuart%d", i);
            snprintf(path, sizeof(path), "file:/tmp/sp_uart%d.log", i);
            chr = qemu_chr_new(label, path, NULL);
        }
        s->uart[i] = qdev_new(TYPE_SP_UART);
        qdev_prop_set_chr(s->uart[i], "chardev", chr);
        qdev_prop_set_uint32(s->uart[i], "index", i);
        sysbus_realize_and_unref(SYS_BUS_DEVICE(s->uart[i]), &error_fatal);
        MemoryRegion *umr = sysbus_mmio_get_region(SYS_BUS_DEVICE(s->uart[i]), 0);
        /* Overlay on the PSU block: the kernel's static PSU mapping
         * (0xF0800000 -> 0x9C000000, len 0x20000) then covers both the
         * clock/pinmux registers and every UART. */
        memory_region_add_subregion(&s->psu, sp_uart_base[i] - SP_PSU_ADDR, umr);
        if (sp_uart_irq[i]) {
            sysbus_connect_irq(SYS_BUS_DEVICE(s->uart[i]), 0,
                               qdev_get_gpio_in(s->gic, SP_GIC_SPI(sp_uart_irq[i])));
        }
    }

    /*
     * Vivante GPU (Galcore) register block @0x9C110000.
     *
     * The BSP statically maps it at 0xD080D000 (first page of the vmalloc
     * window) and galcore pokes it from gckOS_WriteRegisterEx(); with nothing
     * behind that address the very first write raises an external abort,
     * oopses in do_page_fault and panics ("Attempted to kill the idle task")
     * -- which used to kill the boot just after "Galcore version ...".
     * We only need the driver to fail *gracefully* here (the dashboard's
     * display path is PFC/VPP, not the GPU), so a read-back register file
     * (instead of unimp, which always reads 0) is the right shape.
     */
    s->gpu_trace = getenv("SP_GPU_TRACE") != NULL;
    /* Diagnostic personality, not an assertion about the real SP8368 chip.
     * It advertises a GC320-style 2D/PE2 pipeline so the original driver can
     * be traced against the partial DRAW_2D implementation. Off by default. */
    if (getenv("SP_GPU_EXPERIMENTAL_GC320")) {
        s->gpu_regs[0x01c >> 2] = 1u << 9; /* PIPE_2D */
        s->gpu_regs[0x020 >> 2] = 0x320;
        s->gpu_regs[0x024 >> 2] = 0x5000;
        s->gpu_regs[0x034 >> 2] = 1u << 7; /* 2DPE20 */
        fprintf(stderr, "GPU experimental GC320 personality enabled\n");
    }
    memory_region_init_io(&s->gpu, OBJECT(s), &sp_gpu_ops, s,
                          "sunplus-gpu", SP_GPU_SIZE);
    memory_region_add_subregion(get_system_memory(), SP_GPU_ADDR, &s->gpu);

    /* §34 VPP / PFC display-controller register file.  Captures the guest's real
     * background-layer programming so we can composite the guest-decoded bitmap.
     * Mapped at 0x41c00000 (covers the 0x41e6xxxx register window and the
     * 0x41c9xxxx block the IPC payloads reference). */
    s->vpp_trace = getenv("SP_VPP_TRACE") != NULL;
    s->vpp_regs = g_malloc0(SP_VPP_REGS * sizeof(uint32_t));
    memory_region_init_io(&s->vpp, OBJECT(s), &sp_vpp_ops, s,
                          "sunplus-vpp", SP_VPP_SIZE);
    memory_region_add_subregion(get_system_memory(), SP_VPP_BASE, &s->vpp);

    /*
     * Command completion interrupt.  The line number is galcore.irqLine's
     * compiled-in default (47); SP_GPU_IRQ overrides it in case that turns out
     * to be wrong.  Without this line a submitted command buffer never
     * completes and every galcore client blocks in gckOS_WaitSignal().
     */
    {
        const char *irq_s = getenv("SP_GPU_IRQ");
        int irq = irq_s ? atoi(irq_s) : SP_GPU_IRQ_DEFAULT;

        if (irq >= 0 && irq < SP_GIC_NUM_IRQ) {
            s->gpu_irq = qdev_get_gpio_in(s->gic, SP_GIC_SPI(irq));
        }
        s->gpu_timer = timer_new_ns(QEMU_CLOCK_VIRTUAL, sp_gpu_cmd_done, s);
        if (!s->gpu_irq) {
            fprintf(stderr, "warning: no GPU interrupt line (%d)\n", irq);
        }
    }
    if (getenv("SP_GPU_IRQ_SCAN")) {
        s->irqscan_line = -1;
        s->irqscan_timer = timer_new_ns(QEMU_CLOCK_VIRTUAL, sp_irqscan_cb, s);
        timer_mod(s->irqscan_timer,
                  qemu_clock_get_ns(QEMU_CLOCK_VIRTUAL) + 3ULL * 1000 * 1000 * 1000);
    }

    /*
     * I2C completion line (sp_i2cm0 -> GIC SPI 40, from the guest's
     * /proc/interrupts). Used only by the fast-fail pulse; SP_I2C_SLOW=1
     * keeps the historical 10 s-per-transfer stalls for comparison.
     */
    s->i2c_fastfail = !getenv("SP_I2C_SLOW");
    s->i2c_trace = getenv("SP_I2C_TRACE") != NULL;
    /*
     * Panel UI resolution.  The原厂 runtime_cfg (partition runtime_cfg) says
     * UI_width=1024 / UI_height=600, and logo.mkv plus every full-screen
     * theme asset agree, so that is the default; SP_UI_RES=WxH overrides.
     */
    s->ui_w = SP_UI_W_DEFAULT;
    s->ui_h = SP_UI_H_DEFAULT;
    {
        const char *res = getenv("SP_UI_RES");

        if (res && res[0]) {
            unsigned w = 0, h = 0;

            if (sscanf(res, "%ux%u", &w, &h) == 2 && w >= 64 && h >= 64 &&
                w <= 4096 && h <= 4096) {
                s->ui_w = w;
                s->ui_h = h;
            } else {
                fprintf(stderr, "warning: ignoring SP_UI_RES=%s\n", res);
            }
        }
        fprintf(stderr, "UI resolution %ux%u (fb step %#x)\n", s->ui_w,
                s->ui_h, SP_FB_STEP);
    }
    /*
     * Replay the bootloader-era logo animation, if the client handed us the
     * pre-decoded asset.  Nothing happens without SP_BOOT_ANIM, so headless
     * runs are unaffected.
     *
     * With SP_WAKE_FILE set the replay is deferred: the cluster stays dark
     * through MCU boot + locked state and the logo only plays when the client
     * signals "vehicle started" by creating that file (it does so on unlock).
     */
    {
        const char *wake = getenv("SP_WAKE_FILE");

        if (wake && wake[0]) {
            s->anim_wake_path = g_strdup(wake);
            s->anim_wake_armed = true;
            fprintf(stderr,
                    "BOOTANIM: deferred until wake file appears: %s\n", wake);
        } else {
            sp_anim_start(s);
        }

        const char *swake = getenv("SP_SHUTDOWN_WAKE_FILE");
        if (swake && swake[0]) {
            s->shutdown_wake_path = g_strdup(swake);
            s->shutdown_wake_armed = true;
            fprintf(stderr,
                    "SHUTANIM: deferred until shutdown wake file appears: %s\n",
                    swake);
        }
    }
    {
        const char *set = getenv("SP_I2C_SET");

        /* "1c=1,3c=1": force values read back from I2C offsets (hex). */
        while (set && *set && s->i2c_fake_n < G_N_ELEMENTS(s->i2c_fake)) {
            char *end = NULL;
            uint32_t rel = (uint32_t)strtoul(set, &end, 16);
            uint32_t val;

            if (!end || *end != '=') {
                break;
            }
            set = end + 1;
            val = (uint32_t)strtoul(set, &end, 16);
            s->i2c_fake[s->i2c_fake_n].off = SP_I2C_ADDR + rel;
            s->i2c_fake[s->i2c_fake_n].val = val;
            s->i2c_fake_n++;
            fprintf(stderr, "I2C force %05x = %08x\n",
                    SP_I2C_ADDR + rel, val);
            set = (end && *end == ',') ? end + 1 : NULL;
        }
    }
    {
        const char *irq_s = getenv("SP_I2C_IRQ");
        int irq = irq_s ? atoi(irq_s) : SP_I2C_IRQ_DEFAULT;

        s->i2c_timer = timer_new_ns(QEMU_CLOCK_VIRTUAL, sp_i2c_irq_lower_cb, s);
        if (irq >= 0 && irq < SP_GIC_NUM_IRQ) {
            s->i2c_irq = qdev_get_gpio_in(s->gic, SP_GIC_SPI(irq));
        }
        if (s->i2c_fastfail) {
            if (s->i2c_irq) {
                fprintf(stderr,
                        "I2C fast-fail enabled (sp_i2cm0 IRQ %d)\n", irq);
            } else {
                fprintf(stderr,
                        "warning: I2C fast-fail has no interrupt line (%d)\n",
                        irq);
            }
        }
    }

    /*
     * Optional SPVD virtual disk (the NAND storage as a VHD-like image).
     * Attach with SP_VDISK=/path/150aura.spvd.  Region 0 = linear read-only
     * flat NAND data (direct page view), region 1 = control/partition regs.
     * Bases are chosen clear of RAM (0..256M), PSU (0x9C000000) and GIC.
     */
    {
        const char *vdpath = getenv("SP_VDISK");
        if (vdpath && vdpath[0]) {
            const char *b = getenv("SP_VDISK_BASE");
            uint64_t data_base = (b && b[0]) ? g_ascii_strtoull(b, NULL, 16)
                                             : 0x50000000ULL;
            uint64_t regs_base = 0x40000000ULL;

            s->vdisk = qdev_new(TYPE_SP_VDISK);
            qdev_prop_set_string(s->vdisk, "file", vdpath);
            sysbus_realize_and_unref(SYS_BUS_DEVICE(s->vdisk), &error_fatal);
            sysbus_mmio_map(SYS_BUS_DEVICE(s->vdisk), 0, data_base);
            sysbus_mmio_map(SYS_BUS_DEVICE(s->vdisk), 1, regs_base);
            fprintf(stderr,
                    "SP_VDISK: mapped flat data @0x%llx, regs @0x%llx\n",
                    (unsigned long long)data_base, (unsigned long long)regs_base);
        }
    }

    /*
     * Boot the original raw Image. QEMU loads a 32-bit ARM kernel at
     * loader_start + 0x10000 and puts its boot stub + ATAGS at loader_start,
     * so shift loader_start down to land the kernel on its link address.
     * ATAG_MEM still has to report DRAM starting at 0 -> mem_start.
     *
     * NOTE: the struct arm_boot_info must outlive this function (see the
     * comment on SP8368State::bootinfo) -- hence s->bootinfo, not a local.
     */
    struct arm_boot_info *info = &s->bootinfo;

    memset(info, 0, sizeof(*info));
    info->ram_size = machine->ram_size;
    info->loader_start = SP_KERNEL_LINK - SP_BOOT_STUB_OFFSET;
    info->mem_start = SP_DRAM_BASE;
    info->mem_start_set = true;
    info->kernel_filename = kernel_filename;
    info->kernel_cmdline = machine->kernel_cmdline ?
                           machine->kernel_cmdline : "console=ttyS0,921600";
    info->board_id = SP_MACHINE_ID;

    arm_load_kernel(s->cpu, machine, info);
}

static void sp8368_machine_class_init(ObjectClass *oc, void *data)
{
    MachineClass *mc = MACHINE_CLASS(oc);

    mc->desc = "Sunplus SP8368/GEMINI dashboard (AE5i / 150Aura)";
    mc->init = sp8368_init;
    mc->default_cpu_type = ARM_CPU_TYPE_NAME("cortex-a7");
    mc->default_ram_size = 256 * MiB;
}

static const TypeInfo sp8368_machine_info = {
    .name          = TYPE_SP8368_MACHINE,
    .parent        = TYPE_MACHINE,
    .instance_size = sizeof(SP8368State),
    .class_init    = sp8368_machine_class_init,
};

static void sp8368_machine_register_types(void)
{
    type_register_static(&sp8368_machine_info);
}
type_init(sp8368_machine_register_types)
