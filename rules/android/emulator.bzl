"""Public entry point for the `android_emulator` rule.

Usage:
    load("//rules/android:emulator.bzl", "android_emulator")

    android_emulator(name = "my_emu")

    bazel run //:my_emu -- start
    bazel run //:my_emu -- stop
    bazel run //:my_emu -- status
"""

load("//rules/android/private:emulator_impl.bzl", _android_emulator = "android_emulator")

android_emulator = _android_emulator
