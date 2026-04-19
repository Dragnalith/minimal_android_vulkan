"""Bazel module extension for the in-tree Android rules.

Typical `MODULE.bazel` pattern:

```
android = use_extension("//rules/android:extensions.bzl", "android")
android.sdk(
    url              = "https://.../android_sdk.zip",
    sha256           = "...",
    build_tools      = "36.1.0",
    platform_version = "36",
)
android.ndk(
    url     = "https://.../android_ndk.zip",
    sha256  = "...",
    version = "29.0.14206865",
    min_api = "24",
)
use_repo(android, "android_sdk", "android_ndk",
         "android_sdk_toolchains", "android_ndk_toolchains")
register_toolchains(
    "@android_sdk_toolchains//:all",
    "@android_ndk_toolchains//:all",
)
```

Only the root module may declare these tags — they set up global toolchains.
"""

load("//rules/android/private:android_ndk_repo.bzl", "android_ndk_repo")
load("//rules/android/private:android_ndk_toolchains_repo.bzl", "android_ndk_toolchains_repo")
load("//rules/android/private:android_sdk_repo.bzl", "android_sdk_repo")
load("//rules/android/private:android_sdk_toolchains_repo.bzl", "android_sdk_toolchains_repo")

# Fixed repo names so `use_repo(...)` is stable across root module edits.
SDK_REPO_NAME = "android_sdk"
NDK_REPO_NAME = "android_ndk"
SDK_TOOLCHAINS_REPO_NAME = "android_sdk_toolchains"
NDK_TOOLCHAINS_REPO_NAME = "android_ndk_toolchains"

def _android_impl(mctx):
    sdk_tag = None
    ndk_tag = None

    for mod in mctx.modules:
        if not mod.is_root:
            fail(
                "The 'android' module extension may only be used by the root " +
                "module (saw '{}').".format(mod.name),
            )
        for tag in mod.tags.sdk:
            if sdk_tag != None:
                fail("android.sdk(...) may only be declared once.")
            sdk_tag = tag
        for tag in mod.tags.ndk:
            if ndk_tag != None:
                fail("android.ndk(...) may only be declared once.")
            ndk_tag = tag

    if sdk_tag == None:
        fail("android.sdk(...) must be declared exactly once.")
    if ndk_tag == None:
        fail("android.ndk(...) must be declared exactly once.")

    android_sdk_repo(
        name = SDK_REPO_NAME,
        url = sdk_tag.url,
        sha256 = sdk_tag.sha256,
        strip_prefix = sdk_tag.strip_prefix,
        build_tools = sdk_tag.build_tools,
        platform_version = sdk_tag.platform_version,
    )
    android_ndk_repo(
        name = NDK_REPO_NAME,
        url = ndk_tag.url,
        sha256 = ndk_tag.sha256,
        strip_prefix = ndk_tag.strip_prefix,
        min_api = ndk_tag.min_api,
    )
    android_sdk_toolchains_repo(
        name = SDK_TOOLCHAINS_REPO_NAME,
        sdk_repo_name = SDK_REPO_NAME,
    )
    android_ndk_toolchains_repo(
        name = NDK_TOOLCHAINS_REPO_NAME,
        ndk_repo_name = NDK_REPO_NAME,
        min_api = ndk_tag.min_api,
    )

    return mctx.extension_metadata(reproducible = True)

_sdk_tag = tag_class(attrs = {
    "url": attr.string(mandatory = True),
    "sha256": attr.string(default = ""),
    "strip_prefix": attr.string(default = ""),
    "build_tools": attr.string(mandatory = True, doc = "e.g. '36.1.0'"),
    "platform_version": attr.string(mandatory = True, doc = "e.g. '36'"),
})

_ndk_tag = tag_class(attrs = {
    "url": attr.string(mandatory = True),
    "sha256": attr.string(default = ""),
    "strip_prefix": attr.string(default = ""),
    "version": attr.string(mandatory = True, doc = "NDK version string, e.g. '29.0.14206865'. Recorded for provenance only."),
    "min_api": attr.string(mandatory = True, doc = "e.g. '24'"),
})

android = module_extension(
    implementation = _android_impl,
    tag_classes = {
        "sdk": _sdk_tag,
        "ndk": _ndk_tag,
    },
)
