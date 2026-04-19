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
