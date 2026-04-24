"""Generated runner for one android_emulator target."""

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import time

MAIN_REPOSITORY = __MAIN_REPOSITORY__
EMULATOR_EXE_RLOCATION = __EMULATOR_EXE_RLOCATION__
ADB_RLOCATION = __ADB_RLOCATION__
AVDMANAGER_RLOCATION = __AVDMANAGER_RLOCATION__
JAVA_RLOCATION = __JAVA_RLOCATION__
SYSTEM_IMAGE_MARKER_RLOCATION = __SYSTEM_IMAGE_MARKER_RLOCATION__
SYSTEM_IMAGE = __SYSTEM_IMAGE__
LABEL = __LABEL__

BOOT_TIMEOUT_SEC = 300
SHUTDOWN_TIMEOUT_SEC = 30
EMULATOR_PORT_MIN = 5554
EMULATOR_PORT_MAX = 5680

sys.stdout.reconfigure(line_buffering=True)
sys.stderr.reconfigure(line_buffering=True)

_MANIFEST_CACHE = None


def _candidate_keys(path):
    yield path
    prefixes = []
    if MAIN_REPOSITORY:
        prefixes.append(MAIN_REPOSITORY)
    if "_main" not in prefixes:
        prefixes.append("_main")
    for prefix in prefixes:
        if not path.startswith(prefix + "/"):
            yield prefix + "/" + path


def _manifest_paths():
    seen = set()
    for path in (
        os.environ.get("RUNFILES_MANIFEST_FILE"),
        os.path.abspath(sys.argv[0]) + ".runfiles_manifest",
        os.path.join(os.path.abspath(sys.argv[0]) + ".runfiles", "MANIFEST"),
    ):
        if path and path not in seen:
            seen.add(path)
            yield path


def _load_manifest():
    global _MANIFEST_CACHE
    if _MANIFEST_CACHE is not None:
        return _MANIFEST_CACHE
    _MANIFEST_CACHE = {}
    for manifest in _manifest_paths():
        try:
            with open(manifest, "r", encoding="utf-8") as f:
                for line in f:
                    key, sep, value = line.rstrip("\n").partition(" ")
                    if sep:
                        _MANIFEST_CACHE[key] = value
            return _MANIFEST_CACHE
        except OSError:
            pass
    return _MANIFEST_CACHE


def rlocation(path):
    if os.path.isabs(path):
        return path

    runfiles_dir = os.environ.get("RUNFILES_DIR")
    if runfiles_dir:
        for key in _candidate_keys(path):
            candidate = os.path.join(runfiles_dir, *key.split("/"))
            if os.path.exists(candidate):
                return candidate

    manifest = _load_manifest()
    for key in _candidate_keys(path):
        if key in manifest:
            return manifest[key]

    raise SystemExit("runfiles: cannot resolve '%s'" % path)


def mangle_label(label):
    return label.lstrip("/").replace("/", "_").replace(":", "_")


def derived_avd_name(label):
    mangled = mangle_label(label)
    if len(mangled) <= 40:
        return "bz_" + mangled
    digest = hashlib.sha1(label.encode("utf-8")).hexdigest()[:10]
    return "bz_" + mangled[:28] + "_" + digest


def workspace_root():
    return os.environ.get("BUILD_WORKSPACE_DIRECTORY") or os.getcwd()


def state_dir_for(label):
    return os.path.join(
        workspace_root(), "_build", "android_emulators", mangle_label(label)
    )


def hermetic_env(java_home, sdk_root, avd_home):
    env = os.environ.copy()
    env["ANDROID_HOME"] = sdk_root
    env["ANDROID_SDK_ROOT"] = sdk_root
    env["ANDROID_AVD_HOME"] = avd_home
    env["JAVA_HOME"] = java_home
    env["PATH"] = os.path.join(java_home, "bin") + os.pathsep + env.get("PATH", "")
    return env


def run(cmd, env, **kwargs):
    pretty = " ".join(('"%s"' % c if " " in c else c) for c in cmd)
    print(">>", pretty)
    result = subprocess.run(cmd, env=env, **kwargs)
    if result.returncode != 0:
        raise SystemExit("command failed (%d): %s" % (result.returncode, pretty))
    return result


def run_capture(cmd, env):
    return subprocess.run(
        cmd,
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )


def adb_devices(adb, env):
    result = run_capture([adb, "devices"], env)
    if result.returncode != 0:
        return []
    rows = []
    for line in result.stdout.splitlines()[1:]:
        parts = line.strip().split()
        if len(parts) >= 2:
            rows.append((parts[0], parts[1]))
    return rows


def running_serials(adb, env):
    return [serial for serial, _state in adb_devices(adb, env) if serial.startswith("emulator-")]


def used_emulator_ports(adb, env):
    ports = set()
    for serial in running_serials(adb, env):
        match = re.match(r"emulator-(\d+)", serial)
        if match:
            ports.add(int(match.group(1)))
    return ports


def pick_free_port(used):
    for port in range(EMULATOR_PORT_MIN, EMULATOR_PORT_MAX + 1, 2):
        if port not in used:
            return port
    raise SystemExit(
        "No free emulator console port in [%d, %d]." % (EMULATOR_PORT_MIN, EMULATOR_PORT_MAX)
    )


def avd_exists(avd_home, avd_name):
    return os.path.isfile(os.path.join(avd_home, avd_name + ".ini"))


def repair_avd_pointer(avd_home, avd_name):
    ini_path = os.path.join(avd_home, avd_name + ".ini")
    expected = os.path.join(avd_home, avd_name + ".avd")
    try:
        with open(ini_path, "r", encoding="utf-8") as f:
            lines = f.readlines()
    except OSError:
        return

    changed = False
    out = []
    for line in lines:
        if line.startswith("path="):
            current = line[len("path="):].rstrip("\r\n")
            if os.path.normcase(os.path.normpath(current)) != os.path.normcase(os.path.normpath(expected)):
                print("Repairing stale AVD path: %s -> %s" % (current, expected))
                line = "path=%s\n" % expected
                changed = True
        out.append(line)
    if changed:
        with open(ini_path, "w", encoding="utf-8") as f:
            f.writelines(out)


def _ensure_junction(link, target):
    if os.name == "nt":
        link = os.path.normpath(link)
        target = os.path.normpath(target)

    if os.path.lexists(link):
        try:
            current = os.path.realpath(link)
            if os.path.normcase(os.path.normpath(current)) == os.path.normcase(os.path.normpath(target)):
                return
        except OSError:
            pass

        is_junction = hasattr(os.path, "isjunction") and os.path.isjunction(link)
        if is_junction:
            os.rmdir(link)
        elif os.path.isdir(link) and not os.path.islink(link):
            shutil.rmtree(link)
        else:
            os.unlink(link)

    if os.name == "nt":
        result = subprocess.run(
            ["cmd.exe", "/c", "mklink", "/J", link, target],
            capture_output=True,
            text=True,
        )
        if result.returncode != 0:
            raise SystemExit(
                "mklink /J %s -> %s failed: %s"
                % (link, target, result.stderr.strip() or result.stdout.strip())
            )
    else:
        os.symlink(target, link)


def _build_avd_sdk_view(state_dir, sdk_root, sysimg_root, emulator_root):
    view_root = os.path.join(state_dir, "sdk_view")
    os.makedirs(view_root, exist_ok=True)
    for package_dir in ("cmdline-tools", "platform-tools", "platforms", "build-tools"):
        _ensure_junction(
            os.path.join(view_root, package_dir),
            os.path.join(sdk_root, package_dir),
        )
    _ensure_junction(
        os.path.join(view_root, "emulator"),
        emulator_root,
    )
    _ensure_junction(
        os.path.join(view_root, "system-images"),
        os.path.join(sysimg_root, "system-images"),
    )
    try:
        os.remove(os.path.join(view_root, ".knownPackages"))
    except FileNotFoundError:
        pass
    return os.path.join(view_root, "cmdline-tools", "latest")


def create_avd(cfg):
    print("Creating AVD '%s' using %s" % (cfg.avd_name, cfg.system_image))
    os.makedirs(cfg.avd_home, exist_ok=True)

    toolsdir = _build_avd_sdk_view(
        cfg.state_dir,
        cfg.sdk_root,
        cfg.sysimg_root,
        cfg.emulator_root,
    )
    avd_env = dict(cfg.env)
    avd_env["JAVA_OPTS"] = '-Dcom.android.sdkmanager.toolsdir="%s"' % toolsdir

    proc = subprocess.Popen(
        [
            cfg.avdmanager,
            "create",
            "avd",
            "-n",
            cfg.avd_name,
            "-k",
            cfg.system_image,
            "--force",
        ],
        env=avd_env,
        stdin=subprocess.PIPE,
        text=True,
    )
    proc.communicate(input="no\n")
    if proc.returncode != 0:
        raise SystemExit("avdmanager create failed (%d)" % proc.returncode)


def spawn_emulator_detached(cfg, port):
    print("Starting emulator '%s' on port %d (log: %s)" % (cfg.avd_name, port, cfg.log_path))
    cmd = [
        cfg.emulator_exe,
        "-avd",
        cfg.avd_name,
        "-sysdir",
        cfg.sysdir,
        "-port",
        str(port),
        "-no-snapshot-save",
        "-no-audio",
        "-no-boot-anim",
        "-gpu",
        "swiftshader_indirect",
    ]

    if os.name != "nt":
        with open(cfg.log_path, "ab") as log:
            proc = subprocess.Popen(
                cmd,
                env=cfg.env,
                stdout=log,
                stderr=subprocess.STDOUT,
                start_new_session=True,
            )
        return proc.pid

    env_setters = " & ".join(
        'set "%s=%s"' % (key, cfg.env[key])
        for key in ("ANDROID_HOME", "ANDROID_SDK_ROOT", "ANDROID_AVD_HOME", "JAVA_HOME")
    )
    emulator_cmd = (
        '"%s" -avd %s -sysdir "%s" -port %d -no-snapshot-save -no-audio '
        '-no-boot-anim -gpu swiftshader_indirect > "%s" 2>&1'
        % (cfg.emulator_exe, cfg.avd_name, cfg.sysdir, port, cfg.log_path)
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
    result = subprocess.run(
        [
            "powershell.exe",
            "-NoProfile",
            "-NonInteractive",
            "-ExecutionPolicy",
            "Bypass",
            "-Command",
            ps_script,
        ],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise SystemExit(
            "Failed to spawn emulator via WMI (rc=%d)\nstdout: %s\nstderr: %s"
            % (result.returncode, result.stdout.strip(), result.stderr.strip())
        )
    return int(result.stdout.strip())


def wait_for_boot(cfg, serial):
    print("Waiting for %s to boot (up to %ds)..." % (serial, BOOT_TIMEOUT_SEC))
    deadline = time.time() + BOOT_TIMEOUT_SEC

    while time.time() < deadline:
        if dict(adb_devices(cfg.adb, cfg.env)).get(serial) == "device":
            break
        time.sleep(2)
    else:
        raise SystemExit("Emulator %s never reached 'device' state." % serial)

    while time.time() < deadline:
        result = run_capture(
            [cfg.adb, "-s", serial, "shell", "getprop", "sys.boot_completed"],
            cfg.env,
        )
        if result.returncode == 0 and result.stdout.strip() == "1":
            break
        time.sleep(2)
    else:
        raise SystemExit("Timed out waiting for sys.boot_completed=1 on %s." % serial)

    while time.time() < deadline:
        result = run_capture([cfg.adb, "-s", serial, "shell", "pm", "path", "android"], cfg.env)
        if result.returncode == 0:
            print("Emulator %s is booted." % serial)
            return
        time.sleep(2)
    raise SystemExit("Timed out waiting for PackageManager on %s." % serial)


def _state_path(state_dir):
    return os.path.join(state_dir, "state.json")


def load_state(state_dir):
    try:
        with open(_state_path(state_dir), "r", encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def save_state(state_dir, data):
    os.makedirs(state_dir, exist_ok=True)
    with open(_state_path(state_dir), "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2)


def clear_state(state_dir):
    try:
        os.remove(_state_path(state_dir))
    except OSError:
        pass


def is_live(cfg, serial):
    return dict(adb_devices(cfg.adb, cfg.env)).get(serial) in ("device", "offline")


class Config:
    def __init__(self):
        self.label = LABEL
        self.state_dir = state_dir_for(self.label)
        self.avd_name = derived_avd_name(self.label)
        self.avd_home = os.path.join(self.state_dir, "avd_home")
        self.log_path = os.path.join(self.state_dir, "emulator.log")

        self.emulator_exe = rlocation(EMULATOR_EXE_RLOCATION)
        self.emulator_root = os.path.dirname(self.emulator_exe)
        self.adb = rlocation(ADB_RLOCATION)
        self.avdmanager = rlocation(AVDMANAGER_RLOCATION)
        java_exe = rlocation(JAVA_RLOCATION)
        self.java_home = os.path.dirname(os.path.dirname(java_exe))

        self.sdk_root = os.path.dirname(os.path.dirname(self.adb))
        sys_marker = rlocation(SYSTEM_IMAGE_MARKER_RLOCATION)
        self.sysimg_root = os.path.dirname(sys_marker)
        self.sysdir = os.path.join(self.sysimg_root, *SYSTEM_IMAGE.split(";"))
        self.system_image = SYSTEM_IMAGE
        self.env = hermetic_env(self.java_home, self.sdk_root, self.avd_home)


def cmd_start(cfg):
    existing = load_state(cfg.state_dir)
    if existing and is_live(cfg, existing["serial"]):
        raise SystemExit(
            "Emulator '%s' already running as %s. Run `stop` first."
            % (cfg.label, existing["serial"])
        )
    if existing:
        clear_state(cfg.state_dir)

    os.makedirs(cfg.state_dir, exist_ok=True)

    if avd_exists(cfg.avd_home, cfg.avd_name):
        print("Reusing existing AVD '%s' (%s)" % (cfg.avd_name, cfg.avd_home))
        repair_avd_pointer(cfg.avd_home, cfg.avd_name)
    else:
        create_avd(cfg)

    run([cfg.adb, "start-server"], cfg.env)
    port = pick_free_port(used_emulator_ports(cfg.adb, cfg.env))
    serial = "emulator-%d" % port
    pid = spawn_emulator_detached(cfg, port)
    save_state(
        cfg.state_dir,
        {
            "label": cfg.label,
            "port": port,
            "serial": serial,
            "pid": pid,
            "log": cfg.log_path,
        },
    )
    print("Emulator spawned (pid=%d, serial=%s)" % (pid, serial))
    wait_for_boot(cfg, serial)
    print("Device ready: %s" % serial)


def cmd_stop(cfg):
    state = load_state(cfg.state_dir)
    if not state:
        print("Emulator '%s' is not running." % cfg.label)
        return

    serial = state["serial"]
    run([cfg.adb, "start-server"], cfg.env)
    if not is_live(cfg, serial):
        print("Emulator '%s' is not visible to adb; cleaning state." % cfg.label)
        clear_state(cfg.state_dir)
        return

    print("Stopping %s (%s)" % (cfg.label, serial))
    subprocess.run([cfg.adb, "-s", serial, "emu", "kill"], env=cfg.env)
    deadline = time.time() + SHUTDOWN_TIMEOUT_SEC
    while time.time() < deadline:
        if not is_live(cfg, serial):
            clear_state(cfg.state_dir)
            print("Emulator stopped.")
            return
        time.sleep(1)
    raise SystemExit("Emulator %s still present after %ds." % (serial, SHUTDOWN_TIMEOUT_SEC))


def cmd_status(cfg):
    state = load_state(cfg.state_dir)
    running = False
    serial = None
    pid = None
    if state:
        serial = state["serial"]
        pid = state.get("pid")
        running = is_live(cfg, serial)
        if not running:
            clear_state(cfg.state_dir)

    print("label:    %s" % cfg.label)
    print("running:  %s" % ("yes" if running else "no"))
    if running:
        print("serial:   %s" % serial)
        if pid is not None:
            print("pid:      %s" % pid)
    print("state:    %s" % cfg.state_dir)
    if os.path.isfile(cfg.log_path):
        print("log:      %s" % cfg.log_path)


def main():
    parser = argparse.ArgumentParser(
        prog="bazel run //<pkg>:<emulator> --",
        description="Manage one Android emulator target.",
    )
    parser.add_argument("command", choices = ["start", "stop", "status"])
    opts = parser.parse_args()

    cfg = Config()
    if opts.command == "start":
        cmd_start(cfg)
    elif opts.command == "stop":
        cmd_stop(cfg)
    else:
        cmd_status(cfg)


if __name__ == "__main__":
    main()
