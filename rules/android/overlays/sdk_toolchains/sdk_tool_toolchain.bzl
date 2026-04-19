"""Toolchain rule carrying the Android SDK build-time tools.

Copied verbatim into the generated @android_sdk_toolchains repo by
android_sdk_toolchains_repo so that both the generated BUILD and the android_apk
rule implementation can load it through a stable label:
`@android_sdk_toolchains//:sdk_tool_toolchain.bzl`.
"""

AndroidSdkToolchainInfo = provider(
    doc = "Android SDK build-time tools.",
    fields = {
        "aapt2": "File — aapt2 executable.",
        "zipalign": "File — zipalign executable.",
        "apksigner_jar": "File — apksigner.jar launched via `java -jar`.",
        "android_jar": "File — platform android.jar consumed by -I to aapt2.",
    },
)

def _android_sdk_toolchain_impl(ctx):
    return [platform_common.ToolchainInfo(
        sdktoolchaininfo = AndroidSdkToolchainInfo(
            aapt2 = ctx.file.aapt2,
            zipalign = ctx.file.zipalign,
            apksigner_jar = ctx.file.apksigner_jar,
            android_jar = ctx.file.android_jar,
        ),
    )]

android_sdk_toolchain = rule(
    implementation = _android_sdk_toolchain_impl,
    attrs = {
        "aapt2": attr.label(
            allow_single_file = True,
            cfg = "exec",
            executable = True,
            mandatory = True,
        ),
        "zipalign": attr.label(
            allow_single_file = True,
            cfg = "exec",
            executable = True,
            mandatory = True,
        ),
        "apksigner_jar": attr.label(
            allow_single_file = True,
            mandatory = True,
        ),
        "android_jar": attr.label(
            allow_single_file = True,
            mandatory = True,
        ),
    },
)
