"""Create (if needed) and start an Android emulator in the background.

Invoked via `bazel run //tools/android:simulator -- start`. After this process
returns, `emulator.exe` keeps running in the background — `adb devices` then
sees it as `emulator-<port>`, simulating a device plugged in over USB.

All tool paths (emulator, adb, avdmanager, java.exe) are injected as
runfiles-relative `--<flag>=...` arguments by the py_binary's `args =`
attribute. The system-image's staging directory is discovered via a marker
file inside `@android_system_image` so we can pass `--sdk_root <path>` to
avdmanager.
"""

import argparse
import os
import subprocess
import sys
import time

from runfiles_paths import resolve

# `bazel run` captures stdout non-interactively, so Python would otherwise
# block-buffer our prints and the tool looks hung until it exits. Line-buffer
# so each progress message surfaces immediately.
sys.stdout.reconfigure(line_buffering=True)
sys.stderr.reconfigure(line_buffering=True)


AVD_NAME = "vulkan_test"
BOOT_TIMEOUT_SEC = 300


def hermetic_env(java_home, sdk_root, avd_home):
    env = os.environ.copy()
    env["ANDROID_HOME"] = sdk_root
    env["ANDROID_SDK_ROOT"] = sdk_root
    env["ANDROID_AVD_HOME"] = avd_home
    env["JAVA_HOME"] = java_home
    env["PATH"] = os.path.join(java_home, "bin") + os.pathsep + env.get("PATH", "")
    return env


def run(cmd, env, **kw):
    pretty = " ".join(('"%s"' % c if " " in c else c) for c in cmd)
    print(">>", pretty)
    r = subprocess.run(cmd, env=env, **kw)
    if r.returncode != 0:
        sys.exit("command failed (%d): %s" % (r.returncode, pretty))
    return r


def run_capture(cmd, env):
    r = subprocess.run(cmd, env=env,
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                       text=True)
    return r.returncode, r.stdout, r.stderr


def avd_exists(avd_home):
    return os.path.isfile(os.path.join(avd_home, AVD_NAME + ".ini"))


def repair_avd_pointer(avd_home):
    """Rewrite the AVD's .ini `path=` if it points to a stale location.

    avdmanager bakes an absolute path into `<name>.ini` when the AVD is
    created. If the workspace is later moved on disk, the emulator follows
    that stale path, fails to read `config.ini`, and silently falls back
    to default settings (arm CPU) which then fatals. Rewriting the pointer
    in place is safe — it's just a redirect to the real `.avd` directory
    sitting next to it.
    """
    ini_path = os.path.join(avd_home, AVD_NAME + ".ini")
    expected = os.path.join(avd_home, AVD_NAME + ".avd")
    try:
        with open(ini_path, "r", encoding="utf-8") as f:
            lines = f.readlines()
    except OSError:
        return

    out = []
    changed = False
    for ln in lines:
        if ln.startswith("path="):
            current = ln[len("path="):].rstrip("\r\n")
            if os.path.normcase(os.path.normpath(current)) != \
               os.path.normcase(os.path.normpath(expected)):
                print("Repairing stale AVD path: %s -> %s" % (current, expected))
                ln = "path=%s\n" % expected
                changed = True
        out.append(ln)

    if changed:
        with open(ini_path, "w", encoding="utf-8") as f:
            f.writelines(out)


def create_avd(avdmanager, system_image_spec, sdk_root, avd_home, env):
    print("Creating AVD '%s' using %s" % (AVD_NAME, system_image_spec))
    os.makedirs(avd_home, exist_ok=True)
    p = subprocess.Popen(
        [avdmanager,
         "--sdk_root", sdk_root,
         "create", "avd",
         "-n", AVD_NAME,
         "-k", system_image_spec,
         "--force"],
        env=env,
        stdin=subprocess.PIPE,
        text=True,
    )
    # Decline the custom hardware-profile prompt.
    p.communicate(input="no\n")
    if p.returncode != 0:
        sys.exit("avdmanager create failed (%d)" % p.returncode)


def running_emulator_serial(adb, env):
    rc, out, _err = run_capture([adb, "devices"], env)
    if rc != 0:
        return None
    for line in out.splitlines()[1:]:
        parts = line.strip().split()
        if len(parts) >= 2 and parts[0].startswith("emulator-") and parts[1] == "device":
            return parts[0]
    return None


def all_emulator_serials(adb, env):
    """Return every `emulator-<port>` listed by `adb devices`, regardless
    of state. `stop` needs to reach emulators still in `offline` (early
    boot or mid-shutdown), not just fully-booted `device` ones."""
    rc, out, _err = run_capture([adb, "devices"], env)
    if rc != 0:
        return []
    serials = []
    for line in out.splitlines()[1:]:
        parts = line.strip().split()
        if len(parts) >= 1 and parts[0].startswith("emulator-"):
            serials.append(parts[0])
    return serials


def spawn_emulator_detached(emulator, sysdir, env):
    """Spawn emulator.exe so it outlives this script and `bazel run`.

    `bazel run` places its children in a Windows Job Object without
    JOB_OBJECT_LIMIT_BREAKAWAY_OK, so a direct CREATE_BREAKAWAY_FROM_JOB
    in the caller is denied with ERROR_ACCESS_DENIED and any spawned
    emulator gets reaped the moment this script returns.

    Instead we ask the WMI provider (WmiPrvSE.exe) to create the process
    for us. That service runs in its own job outside ours, so the child
    it creates is not in our job tree — the emulator keeps running after
    `bazel run` exits, exactly as if launched from Explorer.

    Win32_Process.Create does not accept an environment dict, so env
    vars are injected inline via a cmd.exe `set ... & set ... & emu.exe`
    wrapper. stdout/stderr go to a log file so startup failures are
    diagnosable after the fact.
    """
    log_path = os.path.join(env["ANDROID_AVD_HOME"], "emulator.log")
    print("Starting emulator '%s' (detached via WMI; log: %s)" % (AVD_NAME, log_path))

    env_setters = " & ".join(
        'set "%s=%s"' % (k, env[k])
        for k in ("ANDROID_HOME", "ANDROID_SDK_ROOT",
                  "ANDROID_AVD_HOME", "JAVA_HOME")
    )
    emulator_cmd = (
        '"%s" -avd %s -sysdir "%s" -no-snapshot-save -no-audio -no-boot-anim '
        '-gpu swiftshader_indirect > "%s" 2>&1'
        % (emulator, AVD_NAME, sysdir, log_path)
    )
    target = "cmd.exe /d /c " + env_setters + " & " + emulator_cmd

    ps_script = (
        "$cmd = '" + target.replace("'", "''") + "'\n"
        "$r = Invoke-CimMethod -ClassName Win32_Process -MethodName Create "
        "-Arguments @{ CommandLine = $cmd }\n"
        "if ($r.ReturnValue -ne 0) {\n"
        "    Write-Error ('WMI Win32_Process.Create returned ' + $r.ReturnValue)\n"
        "    exit 1\n"
        "}\n"
        "Write-Output $r.ProcessId\n"
    )

    r = subprocess.run(
        ["powershell.exe", "-NoProfile", "-NonInteractive",
         "-ExecutionPolicy", "Bypass", "-Command", ps_script],
        capture_output=True, text=True,
    )
    if r.returncode != 0:
        sys.exit("Failed to spawn emulator via WMI (rc=%d)\nstdout: %s\nstderr: %s"
                 % (r.returncode, r.stdout.strip(), r.stderr.strip()))

    pid = r.stdout.strip()
    print("Emulator spawned outside bazel's job (pid=%s)" % pid)


def wait_for_boot(adb, env, timeout=BOOT_TIMEOUT_SEC):
    print("Waiting for emulator to boot (up to %ds)..." % timeout)
    deadline = time.time() + timeout

    serial = None
    while time.time() < deadline:
        serial = running_emulator_serial(adb, env)
        if serial:
            break
        time.sleep(2)
    if not serial:
        sys.exit("Emulator never appeared in `adb devices`")

    run([adb, "-s", serial, "wait-for-device"], env)

    while time.time() < deadline:
        rc, out, _err = run_capture(
            [adb, "-s", serial, "shell", "getprop", "sys.boot_completed"], env)
        if rc == 0 and out.strip() == "1":
            print("Emulator '%s' is booted." % serial)
            return serial
        time.sleep(2)
    sys.exit("Timed out waiting for sys.boot_completed=1")


def workspace_root():
    # `bazel run` sets BUILD_WORKSPACE_DIRECTORY to the workspace root. Fall
    # back to cwd if someone runs the tool outside `bazel run`.
    return os.environ.get("BUILD_WORKSPACE_DIRECTORY") or os.getcwd()


def cmd_start(opts):
    emulator = resolve(opts.emulator)
    adb = resolve(opts.adb)
    avdmanager = resolve(opts.avdmanager)
    java_exe = resolve(opts.java)

    # JAVA_HOME = parent-of-parent of java.exe  ( <root>/bin/java.exe )
    java_home = os.path.dirname(os.path.dirname(java_exe))

    # Two distinct "roots" are needed because the Android tools split
    # responsibilities across our two Bazel repos:
    #
    #   * `sdk_root` (@android_sdk) holds `platform-tools/`, `cmdline-tools/`,
    #     etc. The emulator sanity-checks ANDROID_SDK_ROOT for this layout
    #     and FATALs on "Broken AVD system path" if it's missing.
    #   * `sysimg_root` (@android_system_image) holds `system-images/...` —
    #     what avdmanager needs to resolve `-k system-images;...`.
    #
    # We therefore set ANDROID_SDK_ROOT = sdk_root (makes the emulator happy),
    # but pass `--sdk_root sysimg_root` to avdmanager via the CLI and give
    # the emulator `-sysdir <absolute sysimg>` so it doesn't re-resolve the
    # AVD's relative `image.sysdir.1` against our ANDROID_SDK_ROOT.
    sdk_root = os.path.dirname(os.path.dirname(adb))  # <sdk>/platform-tools/adb.exe
    sys_marker = resolve(opts.system_image_root_marker)
    sysimg_root = os.path.dirname(sys_marker)
    sysdir = os.path.join(sysimg_root, *opts.system_image.split(";"))

    avd_home = os.path.join(workspace_root(), "_build", "avd")
    env = hermetic_env(java_home, sdk_root, avd_home)

    # If an emulator is already running, detect it before creating/spawning a
    # new one so `bazel run ... -- start` is idempotent.
    if avd_exists(avd_home):
        print("Reusing existing AVD '%s' (%s)" % (AVD_NAME, avd_home))
        repair_avd_pointer(avd_home)
    else:
        create_avd(avdmanager, opts.system_image, sysimg_root, avd_home, env)

    run([adb, "start-server"], env)

    # After adb start-server it can take a moment to enumerate an already
    # running emulator; poll briefly so we don't start a second one. Use
    # `all_emulator_serials` (not running_emulator_serial) so we also pick
    # up emulators in `offline` state — e.g. one from an earlier `start`
    # that was interrupted while still booting. Spawning another on top
    # would collide on the console port.
    existing = []
    for _ in range(5):
        existing = all_emulator_serials(adb, env)
        if existing:
            break
        time.sleep(1)

    if existing:
        print("Emulator already present: %s" % ", ".join(existing))
    else:
        spawn_emulator_detached(emulator, sysdir, env)

    # Always wait for a full boot before returning so callers can issue
    # `adb install` / `adb shell` immediately after this command exits.
    serial = wait_for_boot(adb, env)
    print("\nDevice ready: %s" % serial)


SHUTDOWN_TIMEOUT_SEC = 30


def cmd_stop(opts):
    """Ask the running emulator(s) to shut down cleanly via `adb emu kill`.

    `adb emu kill` is the supported path: adb sends a `kill` over the
    emulator's console port, qemu saves state (or not, with
    `-no-snapshot-save`) and exits. Avoids having to track the PID we
    handed off to WMI, which is liable to go stale as soon as qemu
    re-execs its worker subprocesses.
    """
    adb = resolve(opts.adb)
    env = os.environ.copy()

    # If the adb server isn't up, no emulators are reachable through it —
    # but start the server first just to be sure we're not missing a
    # detached emulator from a previous session.
    run([adb, "start-server"], env)

    serials = all_emulator_serials(adb, env)
    if not serials:
        print("No emulator running.")
        return

    for serial in serials:
        print("Stopping %s" % serial)
        # Don't hard-fail on per-emulator errors: `emu kill` can race the
        # emulator's own exit and return non-zero even when it worked.
        subprocess.run([adb, "-s", serial, "emu", "kill"], env=env)

    deadline = time.time() + SHUTDOWN_TIMEOUT_SEC
    while time.time() < deadline:
        if not all_emulator_serials(adb, env):
            print("Emulator stopped.")
            return
        time.sleep(1)
    sys.exit("Emulator still present in `adb devices` after %ds: %s"
             % (SHUTDOWN_TIMEOUT_SEC, all_emulator_serials(adb, env)))


def main():
    parser = argparse.ArgumentParser(
        prog="bazel run //tools/android:simulator --",
        description="Manage the bazel-managed Android emulator.",
    )
    # Runfiles paths injected by the py_binary's `args =` attribute. Parsed
    # here (rather than via a separate pre-pass) so that `--help` surfaces
    # subcommand docs without the noise.
    parser.add_argument("--emulator", required=True)
    parser.add_argument("--adb", required=True)
    parser.add_argument("--avdmanager", required=True)
    parser.add_argument("--java", required=True)
    parser.add_argument("--system-image-root-marker", required=True,
                        dest="system_image_root_marker")
    parser.add_argument("--system-image", required=True,
                        dest="system_image",
                        help="system-image package spec, e.g. "
                             "'system-images;android-36;google_apis;x86_64'")

    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("start", help="create AVD if needed and boot the emulator "
                                 "detached; returns once the device is ready")
    sub.add_parser("stop", help="ask every running emulator to shut down "
                                "cleanly via `adb emu kill`")

    args = parser.parse_args()
    if args.command == "start":
        cmd_start(args)
    elif args.command == "stop":
        cmd_stop(args)


if __name__ == "__main__":
    main()
