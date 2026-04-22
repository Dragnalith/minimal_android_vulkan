package(default_visibility = ["//visibility:public"])

filegroup(
    name = "android_jar",
    srcs = ["platforms/android-{platform_version}/android.jar"],
)

filegroup(
    name = "aapt2",
    srcs = ["build-tools/{build_tools}/aapt2.exe"],
)

filegroup(
    name = "zipalign",
    srcs = ["build-tools/{build_tools}/zipalign.exe"],
)

filegroup(
    name = "apksigner_jar",
    srcs = ["build-tools/{build_tools}/lib/apksigner.jar"],
)

filegroup(
    name = "adb",
    srcs = ["platform-tools/adb.exe"],
)

# adb.exe resolves AdbWinApi.dll / AdbWinUsbApi.dll by %PATH% relative to the
# executable itself; the whole platform-tools directory must be staged in
# runfiles for `bazel run //tools/android:target` to find them.
filegroup(
    name = "platform_tools_runtime",
    srcs = glob(["platform-tools/**/*"]),
)

filegroup(
    name = "avdmanager",
    srcs = ["cmdline-tools/latest/bin/avdmanager.bat"],
)

# avdmanager.bat loads the Java launcher + every jar under lib/ relative to
# itself; the whole cmdline-tools/latest tree must be staged in runfiles.
filegroup(
    name = "cmdline_tools_runtime",
    srcs = glob(["cmdline-tools/latest/**/*"]),
)
