package(default_visibility = ["//visibility:public"])

# Marker file at the repo root; the emulator tool reads its rlocation-path to
# derive the SDK-root that ANDROID_SDK_ROOT should point at (the repo root
# itself, which already contains system-images/<api>/<tag>/<abi>/).
exports_files(["package_marker"])

# Every file shipped in the system-image archive, laid out as
# system-images/{package_path}/... so avdmanager and emulator find it via
# the normal SDK directory layout.
filegroup(
    name = "system_image_runtime",
    srcs = glob(
        ["{package_path}/**/*"],
        exclude = ["BUILD.bazel", "WORKSPACE", "MODULE.bazel"],
    ),
)
