"""Repository rule that downloads one Android system-image package from
Google's channel and lays it out under the `system-images/<api>/<tag>/<abi>/`
path that `avdmanager` and `emulator` expect when `ANDROID_SDK_ROOT` points
at the repo root.

`repository2-3.xml` models each system-image as a package whose path is
`system-images;<api>;<tag>;<abi>` (e.g. `system-images;android-36;google_apis;x86_64`).
The archive unpacks into a single top-level `<abi>/` directory.

Kept in its own repo (separate from `@android_sdk`) so `bazel build` targets
that don't use the emulator never trigger this multi-hundred-megabyte download.
"""

load(":extract.bzl", "extract_flattened")

def _parse_version(version):
    """Split `<api>;<tag>;<abi>` into its three components."""
    parts = version.split(";")
    if len(parts) != 3:
        fail("//rules/android: expected 'api;tag;abi', got '{}'".format(version))
    return parts[0], parts[1], parts[2]

def _android_system_image_repo_impl(ctx):
    api, tag, abi = _parse_version(ctx.attr.version)
    dst = "system-images/{}/{}/{}".format(api, tag, abi)

    ctx.report_progress(
        "Fetching system-image {};{};{}".format(api, tag, abi),
    )
    extract_flattened(
        ctx,
        url = ctx.attr.url,
        sha256 = ctx.attr.sha256,
        dst = dst,
        tmp_name = "_tmp_sys_image",
    )

    # Marker file whose rlocation-path the py_binary uses to walk back up to
    # the repo root. Writing a generated file is cheaper than exposing a deep
    # globbed filegroup member, and its presence is stable across releases.
    ctx.file(
        "package_marker",
        "system-images/{}/{}/{}\n".format(api, tag, abi),
    )

    ctx.template(
        "BUILD.bazel",
        ctx.attr.build_tpl,
        substitutions = {
            "{package_path}": dst,
        },
        executable = False,
    )
    return ctx.repo_metadata(reproducible = True)

android_system_image_repo = repository_rule(
    implementation = _android_system_image_repo_impl,
    attrs = {
        "url": attr.string(mandatory = True),
        "sha256": attr.string(default = ""),
        "version": attr.string(
            mandatory = True,
            doc = "'<api>;<tag>;<abi>', e.g. 'android-36;google_apis;x86_64'.",
        ),
        "build_tpl": attr.label(
            default = "//rules/android/overlays/system_image:BUILD.root.tpl",
            allow_single_file = True,
        ),
    },
)
