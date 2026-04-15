"""Repository rule that creates a local JDK from a workspace-relative path.

Supports $WORKSPACE_ROOT prefix just like android_sdk_repository and
android_ndk_repository.
"""

load("@rules_java//toolchains:local_java_repository.bzl", "local_java_runtime")

def _local_jdk_repo_impl(repository_ctx):
    jdk_path = repository_ctx.attr.java_home
    if jdk_path.startswith("$WORKSPACE_ROOT"):
        jdk_path = str(repository_ctx.workspace_root) + jdk_path.removeprefix("$WORKSPACE_ROOT")

    path = repository_ctx.path(jdk_path)
    if not path.exists:
        fail("JDK path %s does not exist (resolved: %s)" % (repository_ctx.attr.java_home, jdk_path))

    for entry in path.readdir():
        repository_ctx.symlink(entry, entry.basename)

    version = repository_ctx.attr.version

    repository_ctx.file(
        "BUILD.bazel",
        content = """\
load("@rules_java//toolchains:local_java_repository.bzl", "local_java_runtime")
load("@platforms//host:constraints.bzl", "HOST_CONSTRAINTS")

local_java_runtime(
    name = "{name}",
    java_home = ".",
    version = "{version}",
    exec_compatible_with = HOST_CONSTRAINTS,
)
""".format(name = repository_ctx.attr.runtime_name, version = version),
    )

_local_jdk_repo = repository_rule(
    implementation = _local_jdk_repo_impl,
    attrs = {
        "java_home": attr.string(mandatory = True),
        "version": attr.string(mandatory = True),
        "runtime_name": attr.string(mandatory = True),
    },
    local = True,
)

def _local_jdk_extension_impl(module_ctx):
    for mod in module_ctx.modules:
        if not mod.is_root:
            continue
        for cfg in mod.tags.configure:
            _local_jdk_repo(
                name = cfg.name,
                java_home = cfg.java_home,
                version = cfg.version,
                runtime_name = cfg.name,
            )

local_jdk_extension = module_extension(
    implementation = _local_jdk_extension_impl,
    tag_classes = {
        "configure": tag_class(attrs = {
            "name": attr.string(mandatory = True),
            "java_home": attr.string(mandatory = True),
            "version": attr.string(mandatory = True),
        }),
    },
)
