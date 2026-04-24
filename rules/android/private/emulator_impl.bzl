"""`android_emulator` rule implementation."""

load("//rules/android/private:runner_common.bzl", "rlocation_path", "write_python_launcher")

_PYTHON_TOOLCHAIN = "@rules_python//python:toolchain_type"

def _py_string(value):
    return repr(value)

def _main_repo_label(label):
    if label.package:
        return "//{}:{}".format(label.package, label.name)
    return "//:{}".format(label.name)

def _android_emulator_impl(ctx):
    runner_script = ctx.actions.declare_file(ctx.label.name + "_runner.py")
    ctx.actions.expand_template(
        template = ctx.file._emulator_runner_template,
        output = runner_script,
        substitutions = {
            "__MAIN_REPOSITORY__": _py_string(ctx.workspace_name),
            "__EMULATOR_EXE_RLOCATION__": _py_string(rlocation_path(ctx.file._emulator_exe)),
            "__ADB_RLOCATION__": _py_string(rlocation_path(ctx.file._adb)),
            "__AVDMANAGER_RLOCATION__": _py_string(rlocation_path(ctx.file._avdmanager)),
            "__JAVA_RLOCATION__": _py_string(rlocation_path(ctx.file._java)),
            "__SYSTEM_IMAGE_MARKER_RLOCATION__": _py_string(rlocation_path(ctx.file._system_image_marker)),
            "__SYSTEM_IMAGE__": _py_string(ctx.attr.system_image),
            "__LABEL__": _py_string(_main_repo_label(ctx.label)),
        },
        is_executable = True,
    )

    py_runtime = ctx.toolchains[_PYTHON_TOOLCHAIN].py3_runtime
    python_executable = py_runtime.interpreter
    if not python_executable:
        fail("android_emulator currently requires a hermetic Python toolchain.")

    launcher = write_python_launcher(ctx, ctx.label.name, python_executable, runner_script)
    runtime_files = (
        ctx.files._emulator_runtime +
        ctx.files._platform_tools_runtime +
        ctx.files._cmdline_tools_runtime +
        ctx.files._system_image_runtime +
        ctx.files._jdk
    )
    runfiles = ctx.runfiles(
        files = [
            launcher,
            runner_script,
            ctx.file._emulator_exe,
            ctx.file._adb,
            ctx.file._avdmanager,
            ctx.file._java,
            ctx.file._system_image_marker,
        ],
        transitive_files = depset(
            runtime_files,
            transitive = [py_runtime.files],
        ),
    )
    return [DefaultInfo(
        files = depset([launcher, runner_script]),
        executable = launcher,
        runfiles = runfiles,
    )]

android_emulator = rule(
    implementation = _android_emulator_impl,
    attrs = {
        "system_image": attr.string(
            default = "system-images;android-36;google_apis;x86_64",
            doc = "SDK system image package spec used to create the AVD.",
        ),
        "_emulator_runner_template": attr.label(
            allow_single_file = True,
            default = "//rules/android/private:emulator_runner.py.tpl",
        ),
        "_emulator_exe": attr.label(
            allow_single_file = True,
            default = "@android_emulator//:emulator",
        ),
        "_emulator_runtime": attr.label(
            allow_files = True,
            default = "@android_emulator//:emulator_runtime",
        ),
        "_adb": attr.label(
            allow_single_file = True,
            default = "@android_sdk//:adb",
        ),
        "_platform_tools_runtime": attr.label(
            allow_files = True,
            default = "@android_sdk//:platform_tools_runtime",
        ),
        "_avdmanager": attr.label(
            allow_single_file = True,
            default = "@android_sdk//:avdmanager",
        ),
        "_cmdline_tools_runtime": attr.label(
            allow_files = True,
            default = "@android_sdk//:cmdline_tools_runtime",
        ),
        "_system_image_marker": attr.label(
            allow_single_file = True,
            default = "@android_system_image//:package_marker",
        ),
        "_system_image_runtime": attr.label(
            allow_files = True,
            default = "@android_system_image//:system_image_runtime",
        ),
        "_java": attr.label(
            allow_single_file = True,
            default = "@remote_jdk//:bin/java.exe",
        ),
        "_jdk": attr.label(
            allow_files = True,
            default = "@remote_jdk//:jdk",
        ),
        "_windows_constraint": attr.label(
            default = "@platforms//os:windows",
        ),
    },
    toolchains = [_PYTHON_TOOLCHAIN],
    executable = True,
)
