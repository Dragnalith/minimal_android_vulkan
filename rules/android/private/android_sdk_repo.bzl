"""Repository rule that downloads the Android SDK and overlays a BUILD file
exposing the build-tools executables and platform android.jar as labels.
"""

def _android_sdk_repo_impl(ctx):
    ctx.download_and_extract(
        url = ctx.attr.url,
        sha256 = ctx.attr.sha256,
        type = "zip",
        stripPrefix = ctx.attr.strip_prefix,
    )
    ctx.template(
        "BUILD.bazel",
        ctx.attr.build_tpl,
        substitutions = {
            "{build_tools}": ctx.attr.build_tools,
            "{platform_version}": ctx.attr.platform_version,
        },
        executable = False,
    )
    return ctx.repo_metadata(reproducible = True)

android_sdk_repo = repository_rule(
    implementation = _android_sdk_repo_impl,
    attrs = {
        "url": attr.string(mandatory = True),
        "sha256": attr.string(default = ""),
        "strip_prefix": attr.string(default = ""),
        "build_tools": attr.string(mandatory = True, doc = "e.g. '36.1.0'"),
        "platform_version": attr.string(mandatory = True, doc = "e.g. '36'"),
        "build_tpl": attr.label(
            default = "//rules/android/overlays/sdk:BUILD.root.tpl",
            allow_single_file = True,
        ),
    },
)
