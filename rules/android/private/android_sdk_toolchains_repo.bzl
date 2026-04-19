"""Generates the @android_sdk_toolchains repo holding the SDK toolchain type
and toolchain() decls that register aapt2/zipalign/apksigner against it.

`@android_sdk` (the files repo) stays separate — this repo only emits the
rule-based toolchain plumbing and references @android_sdk file labels.
"""

def _android_sdk_toolchains_repo_impl(ctx):
    ctx.template("sdk_tool_toolchain.bzl", ctx.attr.rule_src, executable = False)
    ctx.template(
        "BUILD.bazel",
        ctx.attr.build_tpl,
        substitutions = {
            "{sdk_repo}": ctx.attr.sdk_repo_name,
        },
        executable = False,
    )
    return ctx.repo_metadata(reproducible = True)

android_sdk_toolchains_repo = repository_rule(
    implementation = _android_sdk_toolchains_repo_impl,
    attrs = {
        "sdk_repo_name": attr.string(mandatory = True),
        "rule_src": attr.label(
            default = "//rules/android/overlays/sdk_toolchains:sdk_tool_toolchain.bzl",
            allow_single_file = True,
        ),
        "build_tpl": attr.label(
            default = "//rules/android/overlays/sdk_toolchains:BUILD.root.tpl",
            allow_single_file = True,
        ),
    },
)
