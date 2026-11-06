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

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from cfcp_key import key_frame  # noqa: E402

# 仪表按键（CFCP cmd 0x0301 的 key id）：上 / 下 / SET / BACK
KEY_UP, KEY_DOWN, KEY_SET, KEY_BACK = 0xD2, 0xD3, 0xD4, 0xD5

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
PROP_POWER_ON_PASSWD = 0x21709701  # mcucom_(tx|rx)_power_on_passwd (6 B)
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


# ---------------------------------------------------------------- 电机控制器
# 2-bit 字段表：name -> (byte, bit0)。由「单 bit 载荷 + 固件日志 diff」实测
# （tools/lamp_bits.py，108 个语义位 / 40 个字段）。byte0..3 是整字节数值
# 字段 ABS_off / ABS_fault / camera / TC，byte15 未解出保持 0。
# 必须与 flutter_app/lib/emu/dash_up.dart 的 MotorStatus.encode() 逐字节一致。
LAMP_FIELDS = {
    'ota_not_regist': (4, 0), 'vin_not_write': (4, 2),
    'side_stand': (4, 4), 'ev_ready': (4, 6),
    'auto_start_stop': (5, 2), 'engine_kill': (5, 4),
    'cruise_control': (5, 6),
    'wind_wing': (6, 0), 'auto_lamp': (6, 6),
    'downhill': (7, 0), 'power_limiting': (7, 2),
    'power_battery_fault': (7, 4), 'power_battery_cut_off': (7, 6),
    'low_brake_fluid': (8, 0), 'discharging': (8, 2),
    'charging': (8, 4), 'electricity_connect': (8, 6),
    'parking': (9, 0), 'boosting': (9, 2),
    'low_engine_oil': (9, 4), 'eps_fault': (9, 6),
    'low_voltage': (10, 0), 'low_charge': (10, 2),
    'battery_fault': (10, 4), 'opc_alarm': (10, 6),
    'pos_light': (11, 0), 'big_light': (11, 2),
    'turn_right': (11, 4), 'turn_left': (11, 6),
    'high_beam': (12, 0), 'reverse_assist_power': (12, 2),
    'promotion_assist': (12, 4), 'engine_fault': (12, 6),
    'rcw_warn_status': (13, 0), 'bluetooth_key': (13, 2),
    'seat_cushion_lock_control': (13, 4),
    'turtle_speed_driving_light': (13, 6),
    'bsd_status': (14, 6),
}


class MotorStatus:
    """电机控制器（电控 MCU）上报的车辆状态。

    `TC` = TCS 启用与否；`parking` / `ev_ready` / `turn_*` / `high_beam` /
    `cruise_control` 是档位与把手按键对应的状态 icon 源。本类只产生状态
    字节，icon 一律由 guest 原厂 widget 自己画。
    """

    def __init__(self, tc=1, parking=1, **kw):
        self.abs_off = 0
        self.abs_fault = 0       # 恒 0：置位会弹 ABS 故障框卡住 App
        self.camera = 0
        self.tc = tc
        for name in LAMP_FIELDS:
            setattr(self, name, 0)
        self.parking = parking
        for k, v in kw.items():
            if not hasattr(self, k):
                raise KeyError('unknown motor status field: %s' % k)
            setattr(self, k, v)

    def encode(self):
        b = bytearray(16)
        b[0] = self.abs_off & 0xFF
        b[1] = self.abs_fault & 0xFF
        b[2] = self.camera & 0xFF
        b[3] = self.tc & 0xFF
        for name, (byte, bit0) in LAMP_FIELDS.items():
            b[byte] |= (getattr(self, name, 0) & 3) << bit0
        return bytes(b)


def motor_lamp_frame(m):
    """把电机控制器状态打包成 indicator_lamp 属性帧。"""
    return prop_frame(PROP_LAMP_IN, 0, m.encode())


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


# ------------------------------------------------------------------ 开机密码
# 逆向结论（docs/EMULATION.md §49）：仪表原生 Qt 类 PasswordUL / PasswordULFB70
# 负责界面与 4 位输入，MCU 负责校验。两边共用属性 0x21709701 的 6 B 结构：
#   [0..3] 4 位密码（ASCII 数字）  [4] 状态位  [5] 保留
# 状态位来自 libmcucommodule.so 的
# checkUint8AndEmitSignalIntWithBit + GOT 重定位逐位确认：
#   bit6 0x40 power_on_passwd.gointo_passwd_ui       (MCU→仪表：进入原生界面)
#   bit4 0x10 power_on_passwd.check_passwd_success   (校验通过)
#   bit3 0x08 power_on_passwd.tryNumber_error_lock_notify
#   bit5 0x20 power_on_passwd.shutdown_notify
#   bit7 0x80 power_on_passwd.verify_status          (仪表→MCU：提交校验)
class PowerOnPasswdBit:
    GO_INTO_UI = 0x40
    CHECK_SUCCESS = 0x10
    TRYNUMBER_ERROR = 0x08
    SHUTDOWN_NOTIFY = 0x20
    VERIFY_STATUS = 0x80


def power_passwd_frame(bits=0, digits=b"0000"):
    """Power_On_Passwd 6 B 属性帧。digits 是 4 个 ASCII 数字。"""
    b = bytearray(6)
    b[:4] = (digits + b"0000")[:4]
    b[4] = bits & 0xFF
    return prop_frame(PROP_POWER_ON_PASSWD, 0, bytes(b))


def parse_prop_frame(frame):
    """解析一条 CFCP 属性帧 → (prop, sub, payload)，不是属性帧返回 None。"""
    if len(frame) < 26 or frame[4] != 0x11:
        return None
    inner = struct.unpack_from("<H", frame, 12)[0]
    vlen = inner - 8
    if vlen < 0 or 22 + vlen > len(frame) - 4:
        return None
    return (struct.unpack_from("<I", frame, 14)[0],
            struct.unpack_from("<I", frame, 18)[0],
            bytes(frame[22:22 + vlen]))


class McuPassword:
    """MCU 侧开机密码会话（与 flutter_app/lib/emu/password.dart 逐位一致）。

    客户端**不保存任何可绘制的密码界面状态**：界面由固件 PasswordUL 画，
    按键原样透传给仪表，这里只做 MCU 侧的会话与校验。
    """

    PIN_LENGTH = 4  # PasswordULFB70::VertifyPasswd 只接受长度 4 的 QString

    def __init__(self, pin="0000"):
        self.pin = pin
        self.active = False
        self.digits = []
        self.cursor = 0
        self.failures = 0

    def begin(self):
        self.active = True
        self.digits = []
        self.cursor = 0

    def cancel(self):
        self.active = False
        self.digits = []
        self.cursor = 0

    def key(self, which):
        """which ∈ {up,down,set,back} → pending / accepted / rejected。"""
        if not self.active:
            return "pending"
        if which == "up":
            self.cursor = (self.cursor + 1) % 10
        elif which == "down":
            self.cursor = (self.cursor + 9) % 10
        elif which == "back":
            if self.digits:
                self.digits.pop()
                self.cursor = 0
        elif which == "set":
            self.digits.append(self.cursor)
            self.cursor = 0
            if len(self.digits) < self.PIN_LENGTH:
                return "pending"
            return self._check("".join(str(d) for d in self.digits))
        return "pending"

    def verify_frame(self, payload):
        """固件 mcucom_tx_power_on_passwd 直接提交 4 位密码时的校验。"""
        if len(payload) != 6:
            return "pending"
        # 关机通知优先：PasswordUL::shutDown()（长按 BACK 3 s / 右上角
        # 倒计时 10 步 × 1 s 归零）把 byte[4] |= 0x20 发上来，此时 4 位
        # 数字无意义，不能拿去比对密码。
        if self.active and (payload[4] & PowerOnPasswdBit.SHUTDOWN_NOTIFY):
            self.cancel()
            return "shutdown"
        if not self.active:
            return "pending"
        # AE5I Qt compares its cached password locally, then reports success
        # with zero digits and wire bit4. Only an active session may accept it.
        if payload[:4] == bytes(4) and payload[4] == PowerOnPasswdBit.CHECK_SUCCESS:
            self.failures = 0
            self.cancel()
            return "accepted"
        if payload[4] & PowerOnPasswdBit.GO_INTO_UI:
            return "pending"  # 这是 MCU→仪表方向的请求，不是提交
        chars = payload[:4]
        if not all(0x30 <= c <= 0x39 for c in chars):
            return "pending"
        return self._check("".join(chr(c) for c in chars))

    def _check(self, entered):
        self.digits = []
        self.cursor = 0
        if entered == self.pin:
            self.failures = 0
            self.active = False
            return "accepted"
        self.failures += 1
        return "rejected"


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

    def __init__(self, host, port, on_prop=None):
        self.s = socket.create_connection((host, port), timeout=5)
        self.s.setblocking(False)
        self.buf = b""
        self.acks = 0
        self.rxbytes = 0
        # 可选：guest→MCU 的属性帧回调 (prop, sub, payload)。
        # 默认 None，保证既有「只计数 + 回 ACK」的行为不变。
        self.on_prop = on_prop

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
            frame = self.buf[i:j + 3]
            self.buf = self.buf[j + 3:]
            n += 1
            if self.on_prop is not None:
                parsed = parse_prop_frame(frame)
                if parsed is not None:
                    self.on_prop(*parsed)
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


def send_password_result(peer, pw, result, quiet=False):
    """MCU 校验结果 → 回给仪表（原生 PasswordUL 的状态位）。"""
    if result == "accepted":
        peer.send(power_passwd_frame(PowerOnPasswdBit.CHECK_SUCCESS))
        peer.send(sync_frame(True))
        if not quiet:
            print("[pw] MCU 校验通过 → check_passwd_success + 解锁通知")
    elif result == "rejected":
        peer.send(power_passwd_frame(PowerOnPasswdBit.TRYNUMBER_ERROR))
        time.sleep(0.12)
        peer.send(power_passwd_frame())  # 清位，允许下一次上升沿
        if not quiet:
            print(f"[pw] MCU 校验失败（第 {pw.failures} 次）")
    elif result == "shutdown":
        # 工具只负责 MCU 对端；真正的下电由仿真客户端执行。
        if not quiet:
            print("[pw] 固件要求关机（长按 BACK / 倒计时归零）→ MCU 应执行正常下电")


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
                    help='诊断用：直接指定 indicator_lamp 的 16B hex，覆盖电控状态')
    ap.add_argument('--tcs', type=int, default=1, choices=[0, 1, 2],
                    help='电机控制器上报的 TCS 状态：1=启用 2=关闭（默认 1）')
    ap.add_argument('--no-motor', action='store_true',
                    help='对照组：不喂电机控制器状态帧（2026-11-05 之前的旧行为）')
    ap.add_argument('--pin', default='0000',
                    help='MCU 侧开机密码（4 位；真车由手机 App 写入 GD32）')
    ap.add_argument('--password-ui', dest='password_ui', action='store_true',
                    default=False,
                    help='开机上报「已设置开机密码」→ 固件原生 PasswordUL 在 initWidget '
                         '时自己弹出（默认关；只有在手把键唤醒且手机未连接的真车场景才需要）')
    ap.add_argument('--no-password-ui', dest='password_ui', action='store_false',
                    help='不报密码存在位（默认），直接进 P 档主界面')
    ap.add_argument('--password-timeout', type=float, default=120.0,
                    help='等待固件提交密码的秒数')
    ap.add_argument('--auto-pin', action='store_true',
                    help='仿真便利：进入密码页后自动用上/SET 键输入 --pin（无人在场时自检用）')
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

    pw = McuPassword(args.pin)
    try:
        p = Peer(args.host, args.port)
    except OSError as e:
        sys.exit(f"连不上 {args.host}:{args.port}（仿真器没起来？）：{e}")

    # 固件 PasswordUL 提交 4 位密码时，由 MCU 侧校验并回状态位。
    def on_pw_prop(prop, sub, payload):
        if prop != PROP_POWER_ON_PASSWD:
            return
        result = pw.verify_frame(payload)
        if result == "pending":
            return
        if not args.quiet:
            print("[pw] 收到固件 PasswordUL 提交的密码，MCU 校验")
        send_password_result(p, pw, result, args.quiet)

    p.on_prop = on_pw_prop

    # RTC：默认跟随宿主机本地时间（= MCU 上报的真实时钟），不再固定 12:00。
    # 只在「分钟变化」时重发，避免频繁跳变扰动 App 的定时/彩蛋逻辑。
    def rtc_now():
        t = time.localtime()
        return prop_frame(PROP_RTC, 0,
                          bytes([t.tm_year % 100, t.tm_mon, t.tm_mday,
                                 t.tm_hour, t.tm_min, t.tm_sec]))

    # 电机控制器状态：真车从第一拍起就周期上报 TCS / READY / 驻车 / 灯态，
    # 不能因为「暂时没有 icon 要显示」就整帧不发（旧版正是这样，导致仪表
    # 收不到任何电控状态）。--lamps 用于逐位诊断覆盖，--no-motor 做对照。
    motor = MotorStatus(tc=args.tcs)
    lamp_override = lamp_frame(args.lamps)

    def lamp_now():
        if lamp_override is not None:
            return lamp_override
        return None if args.no_motor else motor_lamp_frame(motor)

    rtc_frame = None
    if args.rtc == 'auto':
        rtc_frame = rtc_now()
    elif args.rtc and args.rtc != 'none':
        parts = [int(x) for x in args.rtc.split(',')]
        if len(parts) != 6:
            sys.exit('--rtc 需要 6 个数：yy,mm,dd,hh,mi,ss，或 auto')
        rtc_frame = prop_frame(PROP_RTC, 0, bytes(v & 0xFF for v in parts))

    # ★ Phase 0「pre-arm」：趁 App 还没画第一屏，先把 KL15 / RTC 灌进去。
    #   原因：时钟 item 首帧会用 App 自己的 12:00 画一遍，之后我们再把时间改掉时，
    #   它只重画自己新文本的矩形，旧字右侧（"12:00" 的尾巴）会留下残影
    #   （显示成 "3:2t00"）。在首帧之前就把正确时间塞进去，就不会有这一层残影。
    #
    #   ★★ 开机密码也必须在 pre-arm 里报：AE5I 的
    #   BaseWidget::initWidget()（libcfeasyconnect.so @0x52170）在**初始化时**
    #   读 mcucom_get_power_on_passwd()，只要返回的 6 B 里 byte[4] bit1 置位，
    #   就调 slots_password_ui(1) 把原生 PasswordUL 页建出来。而
    #   mcucom_rx_power_on_passwd_handle() 正是把 payload byte[4] 的 bit6
    #   存成那个 bit1。所以这一帧必须在界面初始化之前到达 —— 界面起来之后再发
    #   就太晚了（之前所有"发 bit6 没反应"的测试都是这个原因）。
    pw_bits = PowerOnPasswdBit.GO_INTO_UI if args.password_ui else 0
    t_pre = time.time()

    for f in boot_sequence(args.kl15):
        p.send(f)
    if args.password_ui:
        p.send(power_passwd_frame(pw_bits))
    time.sleep(0.25)
    p.pump()
    while time.time() - t_pre < 25.0:
        st = frame_stats()
        # 有密码页时首屏很暗（≈2.5% 非黑），门槛要放低，否则会白等到超时。
        if st and st[2] > (1.0 if args.password_ui else 3.0):
            break                     # App 已经画出第一屏，pre-arm 结束
        p.pump()
        p.send(prop_u32(PROP_KL15, args.kl15))
        if rtc_frame is not None:
            p.send(rtc_frame)
        if args.password_ui:
            p.send(power_passwd_frame(pw_bits))
        time.sleep(0.2)
    p.pump()

    for f in boot_sequence(args.kl15):
        p.send(f)
    time.sleep(0.35)
    p.pump()

    # ★ 已设置密码时：先不电解锁通知，等用户在固件原生 PasswordUL 上输入并被
    #   MCU 校验通过；只有真车流程走完才放行 slot_delayUpdateGear 进主界面。
    if args.password_ui:
        pw.begin()
        if not args.quiet:
            print(f"[pw] 已上报「密码已设置」→ 固件应显示原生密码解锁页；"
                  f"等待固件提交 4 位密码（{args.password_timeout:.0f}s 超时）")
        deadline = time.time() + args.password_timeout
        if args.auto_pin:
            # 模拟用户按键：上键把当前位加到目标数字，再按 SET 确认下一位。
            time.sleep(1.5)
            p.pump()
            for ch in args.pin[:McuPassword.PIN_LENGTH]:
                for _ in range(int(ch)):
                    p.send(key_frame(KEY_UP, True))
                    time.sleep(0.05)
                    p.send(key_frame(KEY_UP, False))
                    time.sleep(0.12)
                p.send(key_frame(KEY_SET, True))
                time.sleep(0.05)
                p.send(key_frame(KEY_SET, False))
                time.sleep(0.25)
                p.pump()
            if not args.quiet:
                print(f"[pw] 已用按键输入 {args.pin}")
        while time.time() < deadline:
            p.pump()
            if not pw.active:            # 校验通过后 on_pw_prop 会把会话关掉
                break
            p.send(prop_u32(PROP_KL15, args.kl15))
            p.send(power_passwd_frame(pw_bits))   # 保持「已设置」位
            if rtc_frame is not None:
                p.send(rtc_frame)
            time.sleep(0.5)
        p.pump()
        if pw.active:
            pw.cancel()
            if not args.quiet:
                print("[pw] 等待超时，按未验证继续（仅仿真便利）")
            if not args.no_unlock:
                p.send(sync_frame(True))
        elif not args.no_unlock:
            p.send(sync_frame(True))       # 校验通过：此帧由 send_password_result 已发
        time.sleep(0.35)
        p.pump()
    elif not args.no_unlock:
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
    # 电控状态放在进场动画之后再送：提前送会让 App 重建场景并重画占位文字
    # （"骑行获得数据~" 压在真值下面）。动画跑完再送，状态一次到位。
    time.sleep(2.5)
    p.pump()
    f = lamp_now()
    if f is not None:
        p.send(f)
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
            lamp_keep = lamp_now()        # 电控：TCS / READY / 驻车 / 灯态周期上报
            if lamp_keep is not None:
                p.send(lamp_keep)
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
