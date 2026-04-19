"""Create (if needed) and start an Android emulator in the background.

After this script returns, the emulator process survives, simulating an
Android device plugged into the host over USB. `run_app.py` (and any
direct `adb` invocation) can then treat it as a ready device.

Usage: python start_emulator.py

Uses only tools from thirdparty/android_sdk and thirdparty/jdk.
"""

import os
import subprocess
import sys
import time


ROOT        = os.path.dirname(os.path.abspath(__file__))
SDK         = os.path.join(ROOT, "thirdparty", "android_sdk")
JDK         = os.path.join(ROOT, "thirdparty", "jdk")

CMDLINE     = os.path.join(SDK, "cmdline-tools", "latest", "bin")
AVDMANAGER  = os.path.join(CMDLINE, "avdmanager.bat")
EMULATOR    = os.path.join(SDK, "emulator", "emulator.exe")
ADB         = os.path.join(SDK, "platform-tools", "adb.exe")

AVD_NAME    = "vulkan_test"
SYS_IMAGE   = "system-images;android-36;google_apis;x86_64"
AVD_HOME    = os.path.join(ROOT, "_build", "avd")

BOOT_TIMEOUT_SEC = 300


def hermetic_env():
    env = os.environ.copy()
    env["ANDROID_HOME"]     = SDK
    env["ANDROID_SDK_ROOT"] = SDK
    env["ANDROID_AVD_HOME"] = AVD_HOME
    env["JAVA_HOME"]        = JDK
    env["PATH"]             = os.path.join(JDK, "bin") + os.pathsep + env.get("PATH", "")
    return env


def run(cmd, **kw):
    pretty = " ".join(('"%s"' % c if " " in c else c) for c in cmd)
    print(">>", pretty)
    r = subprocess.run(cmd, env=hermetic_env(), **kw)
    if r.returncode != 0:
        sys.exit("command failed (%d): %s" % (r.returncode, pretty))
    return r


def run_capture(cmd):
    r = subprocess.run(cmd, env=hermetic_env(),
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                       text=True)
    return r.returncode, r.stdout, r.stderr


def avd_exists():
    return os.path.isfile(os.path.join(AVD_HOME, AVD_NAME + ".ini"))


def create_avd():
    print("Creating AVD '%s' using %s" % (AVD_NAME, SYS_IMAGE))
    os.makedirs(AVD_HOME, exist_ok=True)
    p = subprocess.Popen(
        [AVDMANAGER, "create", "avd",
         "-n", AVD_NAME,
         "-k", SYS_IMAGE,
         "--force"],
        env=hermetic_env(),
        stdin=subprocess.PIPE,
        text=True,
    )
    p.communicate(input="no\n")
    if p.returncode != 0:
        sys.exit("avdmanager create failed (%d)" % p.returncode)


def running_emulator_serial():
    rc, out, _err = run_capture([ADB, "devices"])
    if rc != 0:
        return None
    for line in out.splitlines()[1:]:
        parts = line.strip().split()
        if len(parts) >= 2 and parts[0].startswith("emulator-") and parts[1] == "device":
            return parts[0]
    return None


def spawn_emulator_detached():
    """Spawn emulator.exe as a detached child so it outlives this script.

    Uses `cmd /c start` as the detach mechanism: `start` launches the
    command in its own process tree and returns immediately. The final
    emulator + qemu processes inherit `start`'s environment but a single
    hidden console, so no extra conhost windows pop up and the Qt/QEMU
    GUI window still appears normally.

    Additionally passes CREATE_BREAKAWAY_FROM_JOB so the child escapes any
    parent-held Job Object (e.g. when this script itself is launched inside
    Claude Code's / a harness's job that sets KILL_ON_JOB_CLOSE). Without
    that flag the emulator gets reaped the moment this script returns.
    """
    print("Starting emulator '%s' (detached)" % AVD_NAME)
    # `start "" /B <cmd>` — empty title (required when the exe path is
    # quoted) and /B to run without creating a new console window.
    cmd = (
        'start "" /B "' + EMULATOR + '" '
        '-avd ' + AVD_NAME + ' '
        '-no-snapshot-save -no-audio -no-boot-anim '
        '-gpu swiftshader_indirect'
    )

    base_flags = getattr(subprocess, "CREATE_NO_WINDOW", 0) if os.name == "nt" else 0
    breakaway = getattr(subprocess, "CREATE_BREAKAWAY_FROM_JOB", 0x01000000)

    popen_kwargs = dict(
        shell=True,
        env=hermetic_env(),
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        close_fds=True,
    )

    # Try to break away from the parent's Job Object first; if the job
    # disallows breakaway (no JOB_OBJECT_LIMIT_BREAKAWAY_OK) CreateProcess
    # fails with ERROR_ACCESS_DENIED — fall back to a plain detached spawn.
    try:
        subprocess.Popen(cmd, creationflags=base_flags | breakaway, **popen_kwargs)
    except OSError as e:
        print("CREATE_BREAKAWAY_FROM_JOB denied (%s); "
              "emulator will die with this process's job" % e)
        subprocess.Popen(cmd, creationflags=base_flags, **popen_kwargs)


def wait_for_boot(timeout=BOOT_TIMEOUT_SEC):
    print("Waiting for emulator to boot (up to %ds)..." % timeout)
    deadline = time.time() + timeout

    serial = None
    while time.time() < deadline:
        serial = running_emulator_serial()
        if serial:
            break
        time.sleep(2)
    if not serial:
        sys.exit("Emulator never appeared in `adb devices`")

    run([ADB, "-s", serial, "wait-for-device"])

    while time.time() < deadline:
        rc, out, _err = run_capture(
            [ADB, "-s", serial, "shell", "getprop", "sys.boot_completed"])
        if rc == 0 and out.strip() == "1":
            print("Emulator '%s' is booted." % serial)
            return serial
        time.sleep(2)
    sys.exit("Timed out waiting for sys.boot_completed=1")


def main():
    if avd_exists():
        print("Reusing existing AVD '%s'" % AVD_NAME)
    else:
        create_avd()

    run([ADB, "start-server"])

    # After adb start-server it can take a moment to enumerate an already
    # running emulator; poll briefly so we don't start a second one.
    serial = None
    for _ in range(5):
        serial = running_emulator_serial()
        if serial:
            break
        time.sleep(1)

    if serial:
        print("Emulator already running: %s" % serial)
        return

    spawn_emulator_detached()
    serial = wait_for_boot()
    print("\nDevice ready: %s" % serial)


if __name__ == "__main__":
    main()
