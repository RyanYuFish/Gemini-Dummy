#!/usr/bin/env python3
"""Experiment: make the firmware show its own PasswordUL page.

AE5I `BaseWidget::initWidget()` (libcfeasyconnect.so @0x52170) does:

    if (mcucom) {
        auto p = mcucom->mcucom_get_power_on_passwd();   // 6 bytes cached
        if (p[4] & 0x02) slots_password_ui(1);            // show PasswordUL
    }

and `mcucom_rx_power_on_passwd_handle()` builds that cached bit from
**bit6 of payload byte[4]** of prop 0x21709701.  So the frame must arrive
BEFORE the activity widget is initialised - i.e. during pre-arm, long before
the dashboard's first frame.  Sending it after the UI is up (what we did in all
earlier probes) is simply too late.
"""
import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
import dash_up as D  # noqa: E402
import password_probe as P  # noqa: E402

DURATION = float(os.environ.get('EXP_DURATION', '45'))
BITS = int(os.environ.get('EXP_BITS', '0x40'), 0)


def snap(name):
    ppm = '/tmp/ui-frame.ppm'
    if not os.path.exists(ppm):
        print(f'   （还没帧）', flush=True)
        return
    png = f'/tmp/{name}.png'
    subprocess.run(['sips', '-s', 'format', 'png', ppm, '--out', png],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    print(f'   截图 {png}', flush=True)


def main():
    p = P.ProbePeer('127.0.0.1', 9123)
    t0 = time.time()

    # pre-arm: KL15 + RTC + 密码存在位（byte4 bit6），从第一刻就反复发
    for f in D.boot_sequence(0x99):
        p.send(f)
    p.pump()

    print(f'[exp] 持续发送 power_on_passwd byte4=0x{BITS:02x}（密码已设置）', flush=True)
    for i in range(int(DURATION / 0.15)):
        p.send(D.power_passwd_frame(BITS, b'0000'))
        p.send(D.vi2_frame(gear=0))
        p.send(D.vi1_frame())
        p.send(D.vi3_frame(drive_mode=1, battery=91))
        p.send(D.batt_frame(91))
        p.pump()
        t = time.time() - t0
        if i % 20 == 0:
            print(f'   t={t:5.1f}s {D.frame_stats()}', flush=True)
        if i % 40 == 20:
            snap('exp_pwinit')
        time.sleep(0.15)

    print(f'[exp] 结束 {D.frame_stats()}', flush=True)
    snap('exp_pwinit_final')


if __name__ == '__main__':
    main()
