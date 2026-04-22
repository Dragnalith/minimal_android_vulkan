"""Resolve Android SDK / NDK / system-image archive URLs from Google's
transparency manifests.

The top-level manifest at
`https://dl.google.com/android/repository/repository2-3.xml` publishes every
`<remotePackage>` for build-tools, platforms, platform-tools, cmdline-tools,
NDK, emulator, and more. System-images live in separate per-tag manifests
rooted at `sys-img/<tag>/sys-img2-3.xml`. All of them ship SHA-1 only
(which `ctx.download_and_extract` can't consume), so downloads run with
`sha256=""` and the first-run SHA-256 is pinned via `MODULE.bazel.lock`.

Archive URLs inside each manifest are relative to the manifest's own
directory, so we carry a base URL alongside each manifest when merging
packages into the index.

`build_index(ctx)` returns:

    {
      "build-tools":    {"36.1.0":      {"linux": url, "windows": url, "macosx": url}, ...},
      "platforms":      {"android-36":  {"all": url}, ...},
      "platform-tools": {"36.0.0":      {"linux": url, ...}, ...},
      "cmdline-tools":  {"16.0":        {"linux": url, ...}, ...},
      "ndk":            {"29.0.14206865": {"windows": url, ...}, ...},
      "emulator":       {"latest":      {"windows": url, ...}},
      "system-images":  {"android-36;google_apis;x86_64": {"all": url}, ...},
    }
"""

REPO_BASE = "https://dl.google.com/android/repository/"
REPO_XML_URL = REPO_BASE + "repository2-3.xml"

# Per-tag system-image manifests. Each XML's archive `<url>` entries are
# relative to the XML's own directory, not REPO_BASE.
_SYS_IMG_TAGS = ("android", "google_apis", "google_apis_playstore")

_CATEGORIES = (
    "build-tools",
    "platforms",
    "platform-tools",
    "cmdline-tools",
    "ndk",
    "emulator",
    "system-images",
)

def _extract_between(text, open_tag, close_tag, start = 0):
    """Return (inner, end_pos) for the first `<open_tag>...<close_tag>` after
    `start`, or `(None, -1)` if not found."""
    open_idx = text.find(open_tag, start)
    if open_idx < 0:
        return None, -1
    inner_start = open_idx + len(open_tag)
    close_idx = text.find(close_tag, inner_start)
    if close_idx < 0:
        return None, -1
    return text[inner_start:close_idx], close_idx + len(close_tag)

def _extract_tag(text, tag):
    """Return the content of the first `<tag>...</tag>` in `text`, or None."""
    inner, _ = _extract_between(text, "<" + tag + ">", "</" + tag + ">")
    return inner

def _parse_archives(block):
    """Yield `{host_os, url}` dicts for every `<archive>...</archive>` in
    `block`. `host_os` is `None` when the archive element has no `<host-os>`
    child (OS-independent packages such as `platforms`)."""
    out = []
    cursor = 0
    for _ in range(1024):  # Starlark requires a bounded loop.
        inner, next_cursor = _extract_between(block, "<archive>", "</archive>", cursor)
        if inner == None:
            break
        url = _extract_tag(inner, "url")
        if not url:
            cursor = next_cursor
            continue
        host_os = _extract_tag(inner, "host-os")
        out.append({"host_os": host_os, "url": url.strip()})
        cursor = next_cursor
    return out

def _api_num(k):
    return int(k[len("android-"):]) if k.startswith("android-") else -1

def _version_key(v):
    parts = []
    for chunk in v.replace("-", ".").split("."):
        if chunk.isdigit():
            parts.append((0, int(chunk)))
        else:
            parts.append((1, chunk))
    return parts

def _merge_manifest(ctx, index, xml_url, local_name, base_url):
    """Fetch one repository XML manifest and merge its `<remotePackage>`
    entries into `index`. `base_url` is prepended to each archive's relative
    `<url>` to form the absolute download URL."""
    ctx.download(
        url = [xml_url],
        output = local_name,
        allow_fail = False,
    )
    text = ctx.read(local_name)

    chunks = text.split("<remotePackage ")
    for chunk in chunks[1:]:
        path_marker = 'path="'
        p_start = chunk.find(path_marker)
        if p_start < 0:
            continue
        p_start += len(path_marker)
        p_end = chunk.find('"', p_start)
        if p_end < 0:
            continue
        path = chunk[p_start:p_end]

        close_idx = chunk.find("</remotePackage>")
        if close_idx < 0:
            continue
        block = chunk[:close_idx]

        if ";" in path:
            category, version = path.split(";", 1)
        else:
            # Singleton packages such as `platform-tools` are modelled as
            # version "latest" so downstream lookup is uniform.
            category, version = path, "latest"

        if category not in index:
            continue

        archives = _parse_archives(block)
        if not archives:
            continue

        per_os = {}
        for arch in archives:
            host_os = arch["host_os"] or "all"
            per_os[host_os] = base_url + arch["url"]
        index[category][version] = per_os

def build_index(ctx):
    index = {cat: {} for cat in _CATEGORIES}

    # Top-level manifest: build-tools, platforms, platform-tools,
    # cmdline-tools, ndk, emulator, ...
    _merge_manifest(ctx, index, REPO_XML_URL, "repository2-3.xml", REPO_BASE)

    # Per-tag system-image manifests. Each is keyed by a `<tag>` (android,
    # google_apis, google_apis_playstore) and its archive URLs are relative
    # to that manifest's directory, not REPO_BASE.
    for tag in _SYS_IMG_TAGS:
        sub_base = REPO_BASE + "sys-img/" + tag + "/"
        _merge_manifest(
            ctx,
            index,
            sub_base + "sys-img2-3.xml",
            "sys-img-{}.xml".format(tag),
            sub_base,
        )

    return index

def resolve_version(index, category, version, host_os):
    """Look up a URL for (category, version) restricted to host_os.

    Returns `struct(url, sha256="", resolved_version)`. SHA-256 is empty
    because Google's manifest only publishes SHA-1; the lockfile pins the
    hash on first fetch.
    """
    bucket = index.get(category)
    if not bucket:
        fail("//rules/android: no '{}' entries in repository2-3.xml".format(category))

    if category == "platforms":
        if version == "latest":
            version = sorted(bucket.keys(), key = _api_num)[-1]
        per_os = bucket.get(version)
        if per_os == None:
            fail("//rules/android: platform '{}' not in repository2-3.xml. Candidates: {}".format(
                version, sorted(bucket.keys()),
            ))
        url = per_os.get("all") or per_os.get(host_os)
        if url == None:
            fail("//rules/android: platform '{}' has no archive. OSes: {}".format(
                version, sorted(per_os.keys()),
            ))
        return struct(url = url, sha256 = "", resolved_version = version)

    if version == "latest":
        candidates = [v for v in bucket.keys() if host_os in bucket[v] or "all" in bucket[v]]
        if not candidates:
            fail("//rules/android: no '{}' package for host '{}' in repository2-3.xml".format(category, host_os))
        version = sorted(candidates, key = _version_key)[-1]

    per_os = bucket.get(version)
    if per_os == None:
        fail("//rules/android: '{}' version '{}' not in repository2-3.xml. Candidates: {}".format(
            category, version, sorted(bucket.keys(), key = _version_key),
        ))
    url = per_os.get(host_os) or per_os.get("all")
    if url == None:
        fail("//rules/android: '{}' version '{}' has no '{}' archive. Available OSes: {}".format(
            category, version, host_os, sorted(per_os.keys()),
        ))
    return struct(url = url, sha256 = "", resolved_version = version)
