#!/usr/bin/env python3
"""AE5I 仪表仿真器「点亮 + 进 P 档主界面」的 MCU 对端（正向工程版）。

逆向结论（为什么必须这么喂，见 Gemini-Dummy/docs/EMULATION.md §41）：

  1. CFCP 帧必须 ACK
     guest 内核 rcar-taurus-cfcp.ko 发出 0x75 属性帧后等 MCU 回 ACK，
     不回就 `cfcp_ack_q_work_handl ... resend_times is 3` 重传 3 次丢弃，
     应用层永远收不到属性。

  2. KL15 = 0x99（prop 0x21400030）
     `mcucom_rx_KL15_STATE_handle` 的「整车就绪/点亮」分支，OSD 才会出画面。

  3. ★ 解锁通知（prop 0x21709606 = mcucom_rx_synchronization_status，8 B）
     `AnimTheme01::slot_delayUpdateGear()` 开头有一道闸门：
         if ((sysState.byte[1] & 0x40) == 0) return;
     而 sysState.byte[1] bit6 就是 synchronization_status 的
         payload.byte[1] bit2   ->  MCU_SIGNAL_UNLOCK_NOTIFY
     不喂这一位，槽函数在 0xa46b6 就 return，换挡/换场景全部无效
     （画面永远停在 4.4% 非黑的「待机统计页」）。

  4. 挡位（prop 0x2170951d = mcucom_rx_vehicle_info2，24 B）
     `vehicle_info2.gear` 在 **byte[4]**：
         [0..3] remaind_fuel  [4] gear  [8..11] remind_milage
         [12..15] batt_12v_voltage      [16..19] ambTemperature
     gear = 1 时 `update_gear_data(1)` -> `切换挡位: 1` -> 场景机进入
     `Animation_Pstart_init()` -> `PGEARobj_showInit(true)`，也就是
     「右侧茶青墙 + 巨大 P + 整车 + 绿色地面 + 顶部绿光条」的 P 档主界面。

用法：
  python3 dash_up.py                 # 点亮并进 P 档，常驻保持（Ctrl-C 退出）
  python3 dash_up.py --duration 20   # 跑 20 秒后退出
  python3 dash_up.py --gear 0        # 回 DASH/统计页
  python3 dash_up.py --no-unlock     # 对照组：不喂解锁通知（应停在待机页）
  python3 dash_up.py --quiet         # 不打印逐帧状态
"""
import argparse
import os
import socket
import struct
import sys
import time

MAGIC = b"\xfe\x5a\xaa\xa5"
TAIL = b"\xa5\x55\x5a"
ACK = bytes([0xFE, 0x5A, 0xAA, 0xA5, 0x90, 0x08, 0x55, 0x01, 0x01, 0x00, 0x00, 0x00, 0x10, 0xA5, 0x55, 0x5A])
CMD_PROP = 0x00010175

PROP_KL15 = 0x21400030
PROP_SYNC = 0x21709606       # mcucom_rx_synchronization_status (8 B)
PROP_VI1 = 0x21707402        # mcucom_rx_vehicle_info1      (20 B)
PROP_VI2 = 0x2170951D        # mcucom_rx_vehicle_info2      (24 B)
PROP_VI3 = 0x2170952D        # mcucom_rx_vehicle_info3      (20 B) 电量/驾驶模式/电机温度/电压
PROP_ODO = 0x21707401        # mcucom_rx_trip_total_ODO     (24 B) 总里程/平均电耗
PROP_TRIP1 = 0x21700003      # mcucom_rx_trip_1             (24 B) 单次里程/单次电耗
PROP_TRIP2 = 0x21700004      # mcucom_rx_trip_2             (24 B)
PROP_RTC = 0x21707121        # mcucom_rx_RTC_report_handle  (6 B)  [yy,mm,dd,hh,mi,ss]
PROP_BATT = 0x21709600       # mcucom_rx_power_battery      (16 B) [0]lvl1 [1]lvl2 [2]all
PROP_LAMP = 0x21407072
PROP_LAMP_IN = 0x2170951E    # mcucom_rx_indicator_lamp (16 B) 上行指示灯位图
PROP_GEAR_STATUS = 0x21709702
PROP_HEARTBEAT = 0x21709521
PROP_VEH_STATUS = 0x21707701
PROP_SWVERSION = 0x21701002
PROP_HANDSHAKE = 0x21417310
PROP_CAP = 0x27407404


def build(f0, f1, cmd, data):
    body = bytearray([f0 & 0xFF, f1 & 0xFF])
    body += cmd.to_bytes(4, "little")
    body += len(data).to_bytes(2, "little")
    body += bytes(data)
    return MAGIC + bytes(body) + bytes([(~sum(body)) & 0xFF]) + TAIL


def prop_frame(prop, sub, value):
    inner = 4 + 4 + len(value)
    data = struct.pack("<HH", inner, prop & 0xFFFF)
    data += struct.pack("<H", (prop >> 16) & 0xFFFF)
    data += struct.pack("<I", sub & 0xFFFFFFFF)
    data += bytes(value)
    return build(0x11, 0x02, CMD_PROP, data)


def prop_u32(prop, v):
    return prop_frame(prop, 0, struct.pack("<I", v & 0xFFFFFFFF))


def vi1_frame(speed=0, inst_elec=0, rpm=0, water_temp=0):
    b = bytearray(20)
    struct.pack_into("<i", b, 0, speed)         # wheel_spd
    struct.pack_into("<i", b, 4, inst_elec)     # inst_elec_consume
    struct.pack_into("<i", b, 12, rpm)          # engine_rpm
    struct.pack_into("<i", b, 16, water_temp)   # water_temp
    return prop_frame(PROP_VI1, 0, bytes(b))


def vi2_frame(gear=1, remaind_fuel=0, remind_milage=0, batt_12v=0, amb_temp=25):
    b = bytearray(24)
    struct.pack_into("<I", b, 0, remaind_fuel)
    b[4] = gear & 0xFF
    struct.pack_into("<I", b, 8, remind_milage)   # 底栏「续航 km」
    struct.pack_into("<I", b, 12, batt_12v)
    struct.pack_into("<i", b, 16, amb_temp)
    return prop_frame(PROP_VI2, 0, bytes(b))


def batt_frame(level=91):
    """power_battery: 16 B。 [0] level1  [1] level2  [2] all(%)  ← 底栏电量百分比"""
    b = bytearray(16)
    b[0] = level & 0xFF
    b[1] = level & 0xFF
    b[2] = level & 0xFF
    return prop_frame(PROP_BATT, 0, bytes(b))


def sync_frame(unlock=True):
    """synchronization_status: 8 B.
       byte[1] bit2 -> UNLOCK_NOTIFY -> sysState[1] bit6（slot_delayUpdateGear 的闸门）
    """
    b = bytearray(8)
    if unlock:
        b[1] |= 0x04
    return prop_frame(PROP_SYNC, 0, bytes(b))


def lamp_frame(hexstr):
    """indicator_lamp: 16 B 指示灯位图（MCU 上行 → 固件画顶部指示灯区）。

    位定义（tools/lamp_bits.py 用「单 bit 载荷 + 日志 diff」实测出来的）：
       byte0 bit0 = ABS_off        （仪表显示 (ABS) 带斜杠的图标 = ABS 关闭）
       byte1      = ABS_fault     （ABS 故障；置位会弹故障框，别乱设）
       其余字节/位的语义还没逐个解完，未解前保持 0。

    hexstr 形如 '01'（=byte0=0x01）或 '0000...'（16 字节）。
    """
    if not hexstr:
        return None
    s = hexstr.replace(' ', '')
    if len(s) % 2:
        s = '0' + s
    data = bytes.fromhex(s)
    if len(data) > 16:
        data = data[:16]
    data = data + bytes(16 - len(data))
    return prop_frame(PROP_LAMP_IN, 0, data)


def vi3_frame(drive_mode=1, battery=91, motor_temp=30, batt_voltage=4800,
              batt_current=0, charging_time=0):
    """vehicle_info3: 20 B（逆向测出的打包布局，字段偏移按 handler 日志反推）
         [1] drive_mode      (1=ECO,2=STREET,3=SPORT)
         [2] battery         (0..100 %)
         [3] motor_temp      (℃)
         [4] 电机第二温度
         [11..12] power_batt_voltage (u16 LE, 0.1 V)
         [13..14] power_batt_current (u16 LE)
         [15..16] charging_time      (u16 LE, min)
    """
    b = bytearray(20)
    b[1] = drive_mode & 0xFF
    b[2] = battery & 0xFF
    b[3] = motor_temp & 0xFF
    b[4] = motor_temp & 0xFF
    struct.pack_into("<H", b, 11, batt_voltage & 0xFFFF)
    struct.pack_into("<H", b, 13, batt_current & 0xFFFF)
    struct.pack_into("<H", b, 15, charging_time & 0xFFFF)
    return prop_frame(PROP_VI3, 0, bytes(b))


def odo_frame(odo_km_x10=5060, avg_power_x10=287, speed=0, drivetime=0):
    """trip_total_ODO: 24 B
         [0..3]  odo            (0.1 km)
         [4..7]  avg fuel consume
         [8..11] avg power consume  (0.1 Wh/km)  <- 左列「平均电耗」
         [12..15] speed
         [16..19] drivetime
    """
    b = bytearray(24)
    struct.pack_into("<I", b, 0, odo_km_x10 & 0xFFFFFFFF)
    struct.pack_into("<I", b, 4, 0)
    struct.pack_into("<I", b, 8, avg_power_x10 & 0xFFFFFFFF)
    struct.pack_into("<I", b, 12, speed & 0xFFFFFFFF)
    struct.pack_into("<I", b, 16, drivetime & 0xFFFFFFFF)
    return prop_frame(PROP_ODO, 0, bytes(b))


def trip_frame(prop=PROP_TRIP1, odo_x10=100, avg_power_x10=35, avg_fuel=0,
               speed=0, drivetime=0):
    """trip_1 / trip_2: 24 B，布局与 trip_total_ODO 相同
         [0..3] odo (0.1 km)   [4..7] avg fuel   [8..11] avg power (0.1 Wh)
    """
    b = bytearray(24)
    struct.pack_into("<I", b, 0, odo_x10 & 0xFFFFFFFF)
    struct.pack_into("<I", b, 4, avg_fuel & 0xFFFFFFFF)
    struct.pack_into("<I", b, 8, avg_power_x10 & 0xFFFFFFFF)
    struct.pack_into("<I", b, 12, speed & 0xFFFFFFFF)
    struct.pack_into("<I", b, 16, drivetime & 0xFFFFFFFF)
    return prop_frame(prop, 0, bytes(b))


def boot_sequence(kl15=0x99):
    """模拟上电：版本握手 + 能力 + 状态 + 心跳 + KL15。"""
    return [
        prop_frame(PROP_SWVERSION, 0, b"SW.1.00.56 AE5I".ljust(24, b"\x00")),
        prop_u32(PROP_HANDSHAKE, 1),
        prop_u32(PROP_CAP, 0xFFFFFFFF),
        prop_u32(PROP_VEH_STATUS, 0xC0),
        prop_frame(PROP_GEAR_STATUS, 0, bytes([8, 0])),
        prop_u32(PROP_HEARTBEAT, 0),
        prop_u32(PROP_LAMP, 0),
        prop_u32(PROP_KL15, kl15),
    ]


class Peer:
    """ACK 每一帧并周期喂数据的最小 CFCP 对端。"""

    def __init__(self, host, port):
        self.s = socket.create_connection((host, port), timeout=5)
        self.s.setblocking(False)
        self.buf = b""
        self.acks = 0
        self.rxbytes = 0

    def pump(self):
        """收包 + 逐帧回 ACK。返回本次收到的完整帧数。"""
        n = 0
        try:
            chunk = self.s.recv(65536)
        except (BlockingIOError, socket.timeout):
            return 0
        except OSError:
            return 0
        if not chunk:
            return 0
        self.rxbytes += len(chunk)
        self.buf += chunk
        while True:
            i = self.buf.find(MAGIC)
            if i < 0:
                self.buf = b""
                break
            j = self.buf.find(TAIL, i)
            if j < 0:
                self.buf = self.buf[i:]
                break
            self.buf = self.buf[j + 3:]
            n += 1
        if n:
            try:
                self.s.sendall(ACK * n)
                self.acks += n
            except OSError:
                pass
        return n

    def send(self, frame):
        try:
            self.s.sendall(frame)
            return True
        except OSError:
            return False

    def close(self):
        try:
            self.s.close()
        except OSError:
            pass


def frame_stats():
    p = '/tmp/ui-frame.ppm'
    if not os.path.exists(p):
        return None
    try:
        with open(p, 'rb') as f:
            f.readline()
            wh = f.readline().split()
            w, h = int(wh[0]), int(wh[1])
            f.readline()
            d = f.read()
    except (OSError, ValueError, IndexError):
        return None
    n = w * h
    nb = sum(1 for i in range(n) if d[i * 3] + d[i * 3 + 1] + d[i * 3 + 2] > 10)
    teal = sum(1 for i in range(n) if d[i * 3 + 1] >= d[i * 3] and d[i * 3 + 2] >= d[i * 3]
               and (d[i * 3 + 1] + d[i * 3 + 2]) > 40)
    return w, h, 100.0 * nb / n, 100.0 * teal / n


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--host', default='127.0.0.1')
    ap.add_argument('--port', type=int, default=9123)
    ap.add_argument('--duration', type=float, default=0, help='0 = 常驻')
    ap.add_argument('--gear', type=int, default=1, help='1=P(主界面) 0=统计页')
    ap.add_argument('--kl15', type=lambda s: int(s, 0), default=0x99)
    ap.add_argument('--no-unlock', action='store_true', help='对照组：不喂解锁通知')
    ap.add_argument('--speed', type=int, default=0)
    ap.add_argument('--rpm', type=int, default=0)
    ap.add_argument('--temp', type=int, default=0)
    ap.add_argument('--soc', type=int, default=91, help='电量 %')
    ap.add_argument('--amb-temp', type=int, default=25,
                    help='环境温度 ℃（vehicle_info2.amb_temp，底栏右下角）')
    ap.add_argument('--range', type=int, default=0,
                    help='续航 km（vehicle_info2.remind_milage）。默认 0：该数字位由固件'
                         '先画 "0km" 再被更新，而它重画时只覆盖自己新文本的矩形，'
                         '非 0 值（更宽）左侧会留下旧字（"000km"）。要给真值可传'
                         ' --range 100，但底栏会有残影。')
    ap.add_argument('--drive-mode', type=int, default=1, help='1=ECO 2=STREET 3=SPORT')
    ap.add_argument('--lamps', default='',
                    help='指示灯位图（16B hex）。00=全灭；01=byte0 bit0=ABS_off '
                         '(实车照里那个 (ABS) 带斜杠图标)。见 tools/lamp_bits.py')
    ap.add_argument('--odo', type=int, default=5060, help='总里程，0.1 km 单位')
    ap.add_argument('--avg-power', type=int, default=287, help='平均电耗，0.1 Wh/km')
    ap.add_argument('--trip', type=int, default=100, help='单次里程，0.1 km 单位')
    ap.add_argument('--trip-power', type=int, default=35, help='单次电耗，0.1 Wh')
    ap.add_argument('--rtc', default='auto',
                    help='时间："auto"=跟随宿主机本地时间（默认），或 "yy,mm,dd,hh,mi,ss"，'
                         'none=不喂（App 用自己的时钟）')
    ap.add_argument('--quiet', action='store_true')
    ap.add_argument('--png', default=None)
    args = ap.parse_args()

    try:
        p = Peer(args.host, args.port)
    except OSError as e:
        sys.exit(f"连不上 {args.host}:{args.port}（仿真器没起来？）：{e}")

    # RTC：默认跟随宿主机本地时间（= MCU 上报的真实时钟），不再固定 12:00。
    # 只在「分钟变化」时重发，避免频繁跳变扰动 App 的定时/彩蛋逻辑。
    def rtc_now():
        t = time.localtime()
        return prop_frame(PROP_RTC, 0,
                          bytes([t.tm_year % 100, t.tm_mon, t.tm_mday,
                                 t.tm_hour, t.tm_min, t.tm_sec]))

    lamp_f = lamp_frame(args.lamps)

    rtc_frame = None
    if args.rtc == 'auto':
        rtc_frame = rtc_now()
    elif args.rtc and args.rtc != 'none':
        parts = [int(x) for x in args.rtc.split(',')]
        if len(parts) != 6:
            sys.exit('--rtc 需要 6 个数：yy,mm,dd,hh,mi,ss，或 auto')
        rtc_frame = prop_frame(PROP_RTC, 0, bytes(v & 0xFF for v in parts))

    # ★ Phase 0「pre-arm」：趁 App 还没画第一屏，先把 KL15 / 解锁 / RTC 灌进去。
    #   原因：时钟 item 首帧会用 App 自己的 12:00 画一遍，之后我们再把时间改掉时，
    #   它只重画自己新文本的矩形，旧字右侧（"12:00" 的尾巴）会留下残影
    #   （显示成 "3:2t00"）。在首帧之前就把正确时间塞进去，就不会有这一层残影。
    t_pre = time.time()
    for f in boot_sequence(args.kl15):
        p.send(f)
    time.sleep(0.25)
    p.pump()
    while time.time() - t_pre < 25.0:
        st = frame_stats()
        if st and st[2] > 3.0:      # App 已经画出第一屏，pre-arm 结束
            break
        p.pump()
        p.send(prop_u32(PROP_KL15, args.kl15))
        if rtc_frame is not None:
            p.send(rtc_frame)
        time.sleep(0.2)
    p.pump()

    for f in boot_sequence(args.kl15):
        p.send(f)
    time.sleep(0.35)
    p.pump()

    if not args.no_unlock:
        p.send(sync_frame(True))          # ★ 解锁通知：放行 slot_delayUpdateGear
    time.sleep(0.35)
    p.pump()

    # ★ 两段式进场（实测出来的唯一稳妥顺序）
    #   Phase 1「settle」：连发 20 拍把数据推到位，**挡位保持 0（不进 P 档）**，
    #     这样不会触发任何场景动画、也不会反复 setPos 顶部图标。
    #   Phase 2「enter」：写完数据后**只写一次**目标挡位，让场景机切一次 PGEAR，
    #     然后耐心等动画跑完。
    def burst(n, sleep_s):
        for _ in range(n):
            p.send(vi2_frame(gear=0, remind_milage=args.range, amb_temp=args.amb_temp))
            p.send(vi1_frame(args.speed, 0, args.rpm, args.temp))
            p.send(vi3_frame(drive_mode=args.drive_mode, battery=args.soc))
            p.send(batt_frame(args.soc))
            p.send(odo_frame(odo_km_x10=args.odo, avg_power_x10=args.avg_power))
            p.send(trip_frame(PROP_TRIP1, args.trip, args.trip_power))
            time.sleep(sleep_s)
            p.pump()

    burst(20, 0.15)
    # Phase 2：**只写一次挡位**，然后耐心等进场动画跑完。
    #
    # 早先这里做「两轮 gear0->gear1 re-init」是为了把顶部 DRL/ECO 摆正，但实测
    # 每次写 gear 都会让 slot_delayUpdateGear 重新 setPos，多写几次反而把两个
    # 图标叠到一起，同时每次重进场景都会再画一份动画首帧（底部残块）。配合模型
    # 的 flip-copy 修复后，单次写入即可得到干净画面。
    p.send(vi2_frame(gear=args.gear, remind_milage=args.range, amb_temp=args.amb_temp))
    if rtc_frame is not None:
        p.send(rtc_frame)
    time.sleep(0.4)
    p.pump()
    # 指示灯放在进场动画之后再送：提前送会让 App 重建场景并重画占位文字
    # （"骑行获得数据~" 压在真值下面）。动画跑完再送，图标一次画到位。
    if lamp_f is not None:
        time.sleep(2.5)
        p.pump()
        p.send(lamp_f)
        time.sleep(0.6)
        p.pump()

    start = time.time()
    last = 0.0
    last_report = 0.0
    gear_sent = True          # 挡位已发；只有「App 重启/画面掉回待机」时才重发
    low_streak = 0
    last_min = time.localtime().tm_min
    # 进场序列刚跑完：此后若画面仍/又变低，说明 App 重启或序列打空 -> 允许自愈重放。
    was_up = True
    while True:
        p.pump()
        now = time.time()
        if now - last > 0.5:              # 心跳 / KL15 / 数据 保持（挡位不重复发！）
            p.send(prop_u32(PROP_KL15, args.kl15))
            p.send(prop_u32(PROP_HEARTBEAT, 0))
            p.send(vi1_frame(args.speed, 0, args.rpm, args.temp))
            p.send(vi3_frame(drive_mode=args.drive_mode, battery=args.soc))
            p.send(batt_frame(args.soc))
            p.send(odo_frame(odo_km_x10=args.odo, avg_power_x10=args.avg_power))
            p.send(trip_frame(PROP_TRIP1, args.trip, args.trip_power))
            # RTC 只在分钟翻页时补一发（每 0.5s 重发会不断扰动 App 的定时器）
            if args.rtc == 'auto':
                if time.localtime().tm_min != last_min:
                    last_min = time.localtime().tm_min
                    p.send(rtc_now())
            elif rtc_frame is not None:
                p.send(rtc_frame)
            if not args.no_unlock:
                p.send(sync_frame(True))
            last = now
        if now - last_report > 3.0:
            st = frame_stats()
            if st:
                if not args.quiet:
                    print(f"[{now - start:5.1f}s] frame {st[0]}x{st[1]} nonblack={st[2]:.2f}% teal={st[3]:.2f}%  acks={p.acks}")
                # 自愈：Launcher 每隔 ~2 分钟会重启一次，重启后 sysState/挡位都归零，
                # 画面掉回 ~4% 的待机统计页。检测到就重放一次「上电+解锁+挡位」。
                if st[2] >= 15.0:
                    was_up = True
                    low_streak = 0
                elif was_up:
                    low_streak += 1
                if was_up and low_streak >= 3:
                    if not args.quiet:
                        print("    ↻ 画面掉回待机，重放上电序列")
                    for f in boot_sequence(args.kl15):
                        p.send(f)
                    time.sleep(0.3)
                    p.pump()
                    if not args.no_unlock:
                        p.send(sync_frame(True))
                    time.sleep(0.2)
                    p.send(prop_u32(PROP_KL15, args.kl15))
                    burst(20, 0.12)
                    p.send(vi2_frame(gear=args.gear, remind_milage=args.range, amb_temp=args.amb_temp))
                    time.sleep(0.4)
                    p.pump()
                    low_streak = 0
                    was_up = False
            last_report = now
        if args.duration and now - start >= args.duration:
            break
        time.sleep(0.02)

    if args.png:
        st = frame_stats()
        if st:
            try:
                from PIL import Image
                Image.open('/tmp/ui-frame.ppm').convert('RGB').save(args.png)
                print("saved", args.png)
            except Exception as e:
                print("png fail:", e)
    p.close()
    st = frame_stats()
    if st:
        print(f"final: nonblack={st[2]:.2f}% teal={st[3]:.2f}%  acks={p.acks}")


if __name__ == '__main__':
    main()
