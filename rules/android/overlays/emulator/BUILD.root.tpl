package(default_visibility = ["//visibility:public"])

# The emulator binary itself. Template substitution picks between
# `emulator.exe` (Windows) and `emulator` (Linux / macOS) at fetch time.
filegroup(
    name = "emulator",
    srcs = ["{emulator_exe}"],
)

# Every file shipped in the emulator archive. The emulator binary dynamically
# loads dozens of sibling DLLs, qemu sub-binaries, drivers and resource files,
# so `bazel run //tools/android:simulator` needs all of them in runfiles.
filegroup(
    name = "emulator_runtime",
    srcs = glob(
        ["**/*"],
        exclude = ["BUILD.bazel", "WORKSPACE", "MODULE.bazel"],
    ),
)
