"""Interact with an already-connected Android device.

Invoked via `bazel run //tools/android:target -- <subcommand>`:

    bazel run //tools/android:target -- run <path/to/app.apk>
    bazel run //tools/android:target -- log [extra adb logcat args...]
    bazel run //tools/android:target -- list

Tool paths (adb, aapt2) are injected as `--adb=...` / `--aapt2=...` flags
by the py_binary's `args =` attribute (runfiles-relative) and resolved at
runtime via `runfiles_paths.resolve`.

Relative paths passed to subcommands are interpreted relative to the user's
cwd at `bazel run` time (`BUILD_WORKING_DIRECTORY`), so
`bazel run ... -- run bazel-bin/app/vulkan_triangle.apk` works from the repo.
"""

import argparse
import os
import re
import subprocess
import sys

from runfiles_paths import resolve

# `bazel run` captures stdout non-interactively; line-buffer so progress
# prints surface as the tool runs instead of only on exit.
sys.stdout.reconfigure(line_buffering=True)
sys.stderr.reconfigure(line_buffering=True)


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


def apk_package_and_activity(aapt2, apk):
    rc, out, err = run_capture([aapt2, "dump", "badging", apk])
    if rc != 0:
        sys.exit("aapt2 dump badging failed: %s" % err)
    pkg_m = re.search(r"package:\s+name='([^']+)'", out)
    act_m = re.search(r"launchable-activity:\s+name='([^']+)'", out)
    if not pkg_m:
        sys.exit("Could not find package in APK")
    pkg = pkg_m.group(1)
    act = act_m.group(1) if act_m else "android.app.NativeActivity"
    return pkg, act


def first_ready_device(adb):
    rc, out, _err = run_capture([adb, "devices"])
    if rc != 0:
        return None
    for line in out.splitlines()[1:]:
        parts = line.strip().split()
        if len(parts) >= 2 and parts[1] == "device":
            return parts[0]
    return None


def require_device(adb):
    serial = first_ready_device(adb)
    if not serial:
        sys.exit("no device")
    return serial


def workspace_abspath(p):
    # `bazel run` sets BUILD_WORKING_DIRECTORY to the user's shell cwd. Resolve
    # relative args against that so `bazel run ... -- run foo.apk` behaves like
    # the user typed from their shell.
    if os.path.isabs(p):
        return p
    base = os.environ.get("BUILD_WORKING_DIRECTORY") or os.getcwd()
    return os.path.abspath(os.path.join(base, p))


def install_apk(adb, serial, apk, package):
    """Install an APK, recovering from a stale signing-key mismatch.

    `adb install -r` refuses to replace a package that was previously
    installed with a different signing key (common after switching
    between debug/release builds or between machines). Android answers
    with INSTALL_FAILED_UPDATE_INCOMPATIBLE. On that specific failure we
    uninstall the old copy and retry once — anything else is a real
    error and propagates.
    """
    cmd = [adb, "-s", serial, "install", "-r", "-t", apk]
    pretty = " ".join(('"%s"' % c if " " in c else c) for c in cmd)
    print(">>", pretty)
    r = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                       text=True)
    sys.stdout.write(r.stdout)
    if r.returncode == 0:
        return
    if "INSTALL_FAILED_UPDATE_INCOMPATIBLE" not in r.stdout:
        sys.exit("command failed (%d): %s" % (r.returncode, pretty))

    print("Signing-key mismatch detected — uninstalling old %s and retrying"
          % package)
    run([adb, "-s", serial, "uninstall", package])
    run(cmd)


def cmd_run(adb, aapt2, args):
    apk = workspace_abspath(args.apk)
    if not os.path.isfile(apk):
        sys.exit("APK not found: %s" % apk)

    package, activity = apk_package_and_activity(aapt2, apk)
    print("APK package=%s activity=%s" % (package, activity))

    serial = require_device(adb)
    print("Using device: %s" % serial)

    install_apk(adb, serial, apk, package)
    run([adb, "-s", serial, "shell", "am", "start",
         "-n", package + "/" + activity])

    print("\nLaunched %s on %s" % (package, serial))


def cmd_list(adb, _aapt2, _args):
    rc, out, err = run_capture([adb, "devices", "-l"])
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


def cmd_log(adb, logcat_args):
    serial = require_device(adb)
    cmd = [adb, "-s", serial, "logcat"] + list(logcat_args)
    try:
        r = subprocess.run(cmd)
    except KeyboardInterrupt:
        return
    sys.exit(r.returncode)


def _split_tool_flags(argv):
    """Extract the injected --adb / --aapt2 flags from argv, returning
    (adb_rloc, aapt2_rloc, remaining_argv). These flags are placed in argv by
    the py_binary's `args = [...]` attribute (ahead of any user-supplied `--`
    arguments), so strip them before the subcommand parser runs.
    """
    adb = None
    aapt2 = None
    remaining = []
    for token in argv:
        if token.startswith("--adb="):
            adb = token[len("--adb="):]
        elif token.startswith("--aapt2="):
            aapt2 = token[len("--aapt2="):]
        else:
            remaining.append(token)
    if adb is None or aapt2 is None:
        sys.exit("target_tool: missing --adb / --aapt2 from BUILD args")
    return adb, aapt2, remaining


def main():
    adb_rloc, aapt2_rloc, argv = _split_tool_flags(sys.argv[1:])
    adb = resolve(adb_rloc)
    aapt2 = resolve(aapt2_rloc)

    # Handle `log` specially: forward every remaining arg to `adb logcat`
    # verbatim so users can pass flags like `-d` / `-t 50` without hitting
    # argparse's REMAINDER quirk with leading-dash tokens.
    if argv and argv[0] == "log":
        cmd_log(adb, argv[1:])
        return

    parser = argparse.ArgumentParser(
        prog="bazel run //tools/android:target --",
        description="Install / launch / inspect an APK on the connected device.",
    )
    sub = parser.add_subparsers(dest="command", required=True)

    p_run = sub.add_parser("run", help="install and launch an APK")
    p_run.add_argument("apk", help="path to the .apk to install and launch")
    p_run.set_defaults(func=cmd_run)

    sub.add_parser(
        "log",
        help="stream `adb logcat` from the device "
             "(all remaining args are forwarded)",
    )

    p_list = sub.add_parser(
        "list",
        help="list all connected devices (USB + emulator)",
    )
    p_list.set_defaults(func=cmd_list)

    args = parser.parse_args(argv)
    args.func(adb, aapt2, args)


if __name__ == "__main__":
    main()
