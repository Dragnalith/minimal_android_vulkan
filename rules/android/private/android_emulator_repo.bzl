"""Repository rule that downloads the Android Emulator package from Google's
channel and exposes the `emulator` binary plus its full runtime tree.

The archive `emulator-<host>-<rev>.zip` always unpacks into a single top-level
`emulator/` directory. `strip_prefix` lands its contents at the repo root so
the binary is reachable at `emulator.exe` (Windows) or `emulator` (Unix), with
the many sibling DLLs / qemu binaries / drivers alongside it.

Kept in its own repo (separate from `@android_sdk`) so `bazel build` targets
that don't use the emulator never trigger this download.
"""

def _is_windows(ctx):
    return "windows" in ctx.os.name.lower()

def _android_emulator_repo_impl(ctx):
    ctx.report_progress("Fetching Android emulator")
    ctx.download_and_extract(
        url = ctx.attr.url,
        sha256 = ctx.attr.sha256,
        type = "zip",
        stripPrefix = "emulator",
    )

    ctx.template(
        "BUILD.bazel",
        ctx.attr.build_tpl,
        substitutions = {
            "{emulator_exe}": "emulator.exe" if _is_windows(ctx) else "emulator",
        },
        executable = False,
    )
    return ctx.repo_metadata(reproducible = True)

android_emulator_repo = repository_rule(
    implementation = _android_emulator_repo_impl,
    attrs = {
        "url": attr.string(mandatory = True),
        "sha256": attr.string(default = ""),
        "build_tpl": attr.label(
            default = "//rules/android/overlays/emulator:BUILD.root.tpl",
            allow_single_file = True,
        ),
    },
)
