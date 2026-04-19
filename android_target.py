"""Interact with an already-connected Android device.

Usage:
    python android_target.py run <path/to/app.apk>
    python android_target.py log [extra adb logcat args...]
    python android_target.py list

Assumes a device is visible to adb (physical device plugged via USB or an
emulator previously started with start_emulator.py). This script is
intentionally oblivious to how the device got there.

Uses only the adb / aapt2 binaries under thirdparty/android_sdk.
"""

import argparse
import os
import re
import subprocess
import sys


ROOT   = os.path.dirname(os.path.abspath(__file__))
SDK    = os.path.join(ROOT, "thirdparty", "android_sdk")

AAPT2  = os.path.join(SDK, "build-tools", "36.1.0", "aapt2.exe")
ADB    = os.path.join(SDK, "platform-tools", "adb.exe")


def run(cmd, **kw):
    pretty = " ".join(('"%s"' % c if " " in c else c) for c in cmd)
    print(">>", pretty)
    r = subprocess.run(cmd, **kw)
    if r.returncode != 0:
        sys.exit("command failed (%d): %s" % (r.returncode, pretty))
    return r


def run_capture(cmd):
    r = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                       text=True)
    return r.returncode, r.stdout, r.stderr


def apk_package_and_activity(apk):
    rc, out, err = run_capture([AAPT2, "dump", "badging", apk])
    if rc != 0:
        sys.exit("aapt2 dump badging failed: %s" % err)
    pkg_m = re.search(r"package:\s+name='([^']+)'", out)
    act_m = re.search(r"launchable-activity:\s+name='([^']+)'", out)
    if not pkg_m:
        sys.exit("Could not find package in APK")
    pkg = pkg_m.group(1)
    act = act_m.group(1) if act_m else "android.app.NativeActivity"
    return pkg, act


def first_ready_device():
    """Return serial of the first adb device in state 'device', or None."""
    rc, out, _err = run_capture([ADB, "devices"])
    if rc != 0:
        return None
    for line in out.splitlines()[1:]:
        parts = line.strip().split()
        if len(parts) >= 2 and parts[1] == "device":
            return parts[0]
    return None


def require_device():
    serial = first_ready_device()
    if not serial:
        sys.exit("no device")
    return serial


def cmd_run(args):
    apk = os.path.abspath(args.apk)
    if not os.path.isfile(apk):
        sys.exit("APK not found: %s" % apk)

    package, activity = apk_package_and_activity(apk)
    print("APK package=%s activity=%s" % (package, activity))

    serial = require_device()
    print("Using device: %s" % serial)

    run([ADB, "-s", serial, "install", "-r", "-t", apk])
    run([ADB, "-s", serial, "shell", "am", "start",
         "-n", package + "/" + activity])

    print("\nLaunched %s on %s" % (package, serial))


def cmd_list(_args):
    rc, out, err = run_capture([ADB, "devices", "-l"])
    if rc != 0:
        sys.exit("adb devices failed: %s" % err)

    rows = []
    for line in out.splitlines()[1:]:
        line = line.strip()
        if not line:
            continue
        parts = line.split()
        if len(parts) < 2:
            continue
        serial, state = parts[0], parts[1]
        kind = "emulator" if serial.startswith("emulator-") else "usb"
        rows.append((serial, state, kind))

    if not rows:
        print("no device")
        return

    w = max(len(r[0]) for r in rows)
    for serial, state, kind in rows:
        print("%-*s  %-8s  %s" % (w, serial, kind, state))


def cmd_log(logcat_args):
    serial = require_device()
    # Stream logcat. We exec adb directly so Ctrl-C propagates cleanly and
    # output isn't buffered through Python.
    cmd = [ADB, "-s", serial, "logcat"] + list(logcat_args)
    try:
        r = subprocess.run(cmd)
    except KeyboardInterrupt:
        return
    sys.exit(r.returncode)


def main():
    # Handle `log` specially: forward every remaining arg to `adb logcat`
    # verbatim so users can pass flags like `-d` / `-t 50` without hitting
    # argparse's REMAINDER quirk with leading-dash tokens.
    if len(sys.argv) >= 2 and sys.argv[1] == "log":
        cmd_log(sys.argv[2:])
        return

    parser = argparse.ArgumentParser(prog="android_target.py",
                                     description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)

    p_run = sub.add_parser("run", help="install and launch an APK")
    p_run.add_argument("apk", help="path to the .apk to install and launch")
    p_run.set_defaults(func=cmd_run)

    sub.add_parser("log",
                   help="stream `adb logcat` from the device "
                        "(all remaining args are forwarded)")

    p_list = sub.add_parser("list",
                            help="list all connected devices (USB + emulator)")
    p_list.set_defaults(func=cmd_list)

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
