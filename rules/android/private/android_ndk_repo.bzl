"""Repository rule that downloads the Android NDK and overlays a BUILD file
exposing native_app_glue, glslc, per-host compiler filegroups, and per-triplet
sysroot and libc++_shared filegroups as labels.
"""

def _android_ndk_repo_impl(ctx):
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
            "{min_api}": ctx.attr.min_api,
        },
        executable = False,
    )
    return ctx.repo_metadata(reproducible = True)

android_ndk_repo = repository_rule(
    implementation = _android_ndk_repo_impl,
    attrs = {
        "url": attr.string(mandatory = True),
        "sha256": attr.string(default = ""),
        "strip_prefix": attr.string(default = ""),
        "min_api": attr.string(mandatory = True, doc = "e.g. '24'"),
        "build_tpl": attr.label(
            default = "//rules/android/overlays/ndk:BUILD.root.tpl",
            allow_single_file = True,
        ),
    },
)
