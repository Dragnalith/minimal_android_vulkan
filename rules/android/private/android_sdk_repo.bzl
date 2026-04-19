"""Repository rule that downloads Android SDK components from their official
channels (URLs and SHA-256s resolved from F-Droid's transparency log by the
module extension) and overlays this project's rich BUILD file on top.

Layout produced at the repo root:

    build-tools/<revision>/...
    platform-tools/...
    platforms/android-<api>/...
    cmdline-tools/<version>/...
    cmdline-tools/latest/     (copy; populated only if cmdline-tools requested)
    licenses/<license-id>
"""

load(":extract.bzl", "copy_tree", "extract_flattened")
load(":licenses.bzl", "KNOWN_LICENSES")

def _write_licenses(ctx):
    for license_id, hashes in KNOWN_LICENSES.items():
        ctx.file("licenses/{}".format(license_id), hashes)

def _android_sdk_repo_impl(ctx):
    components = json.decode(ctx.attr.components)

    for i, comp in enumerate(components):
        extract_flattened(
            ctx,
            url = comp["url"],
            sha256 = comp["sha256"],
            dst = comp["dst"],
            tmp_name = "_tmp_{}".format(i),
        )
        if comp.get("alias_latest"):
            copy_tree(ctx, comp["dst"], "cmdline-tools/latest")

    if ctx.attr.accept_licenses:
        _write_licenses(ctx)

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
        "components": attr.string(
            mandatory = True,
            doc = "JSON list of {url, sha256, dst[, alias_latest]} dicts.",
        ),
        "accept_licenses": attr.bool(default = True),
        "build_tools": attr.string(mandatory = True, doc = "e.g. '36.1.0'"),
        "platform_version": attr.string(mandatory = True, doc = "e.g. '36'"),
        "build_tpl": attr.label(
            default = "//rules/android/overlays/sdk:BUILD.root.tpl",
            allow_single_file = True,
        ),
    },
)
