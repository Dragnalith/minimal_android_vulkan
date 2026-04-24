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

def _source_properties(ctx):
    props = {}
    for line in ctx.read("source.properties").splitlines():
        if "=" in line and not line.lstrip().startswith("#"):
            key, value = line.split("=", 1)
            props[key.strip()] = value.strip()
    return props

def _revision_xml(revision):
    parts = revision.split(".")
    names = ["major", "minor", "micro", "preview"]
    out = []
    for i, value in enumerate(parts[:4]):
        out.append("<{name}>{value}</{name}>".format(
            name = names[i],
            value = value,
        ))
    return "".join(out)

def _xml_escape(value):
    return (value
            .replace("&", "&amp;")
            .replace("<", "&lt;")
            .replace(">", "&gt;")
            .replace("\"", "&quot;"))

def _write_package_xml(ctx):
    # The emulator archive ships only source.properties. Modern sdkmanager /
    # avdmanager do not recognize that legacy metadata for the emulator package,
    # so materialize the package.xml they expect in an installed SDK.
    props = _source_properties(ctx)
    revision = props.get("Pkg.Revision", "0")
    display_name = props.get("Pkg.Desc", "Android Emulator")
    ctx.file("package.xml", """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<ns2:repository
    xmlns:ns2="http://schemas.android.com/repository/android/common/02"
    xmlns:ns5="http://schemas.android.com/repository/android/generic/02">
  <license id="android-sdk-license" type="text"/>
  <localPackage path="emulator" obsolete="false">
    <type-details xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:type="ns5:genericDetailsType"/>
    <revision>{revision}</revision>
    <display-name>{display_name}</display-name>
    <uses-license ref="android-sdk-license"/>
  </localPackage>
</ns2:repository>
""".format(
        revision = _revision_xml(revision),
        display_name = _xml_escape(display_name),
    ))

def _android_emulator_repo_impl(ctx):
    ctx.report_progress("Fetching Android emulator")
    ctx.download_and_extract(
        url = ctx.attr.url,
        sha256 = ctx.attr.sha256,
        type = "zip",
        stripPrefix = "emulator",
    )
    _write_package_xml(ctx)

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
