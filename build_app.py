"""Hermetic Android APK build for the minimal Vulkan sample.

Only uses tools under thirdparty/android_sdk and thirdparty/jdk.
No global tool dependency beyond the Python interpreter running this script.
No third-party Python packages; standard library only.

Outputs:
  _build/bin/vulkan_triangle.apk

Intermediates:
  _build/imd/...
"""

import os
import shutil
import subprocess
import sys
import zipfile


ROOT        = os.path.dirname(os.path.abspath(__file__))
THIRDPARTY  = os.path.join(ROOT, "thirdparty")
SDK         = os.path.join(THIRDPARTY, "android_sdk")
JDK         = os.path.join(THIRDPARTY, "jdk")

BUILD_TOOLS = os.path.join(SDK, "build-tools", "36.1.0")
PLATFORM    = os.path.join(SDK, "platforms", "android-36")
ANDROID_JAR = os.path.join(PLATFORM, "android.jar")
NDK         = os.path.join(SDK, "ndk", "29.0.14206865")

SHADER_TOOLS = os.path.join(NDK, "shader-tools", "windows-x86_64")
GLSLC        = os.path.join(SHADER_TOOLS, "glslc.exe")

LLVM_PREBUILT = os.path.join(NDK, "toolchains", "llvm", "prebuilt",
                             "windows-x86_64")
LLVM_BIN     = os.path.join(LLVM_PREBUILT, "bin")
CLANG        = os.path.join(LLVM_BIN, "clang.exe")
CLANGXX      = os.path.join(LLVM_BIN, "clang++.exe")
LIBCXX_SHARED = os.path.join(LLVM_PREBUILT, "sysroot", "usr", "lib",
                             "aarch64-linux-android", "libc++_shared.so")

NATIVE_APP_GLUE = os.path.join(NDK, "sources", "android", "native_app_glue")

JAVA    = os.path.join(JDK, "bin", "java.exe")
JAVAC   = os.path.join(JDK, "bin", "javac.exe")
KEYTOOL = os.path.join(JDK, "bin", "keytool.exe")

AAPT2       = os.path.join(BUILD_TOOLS, "aapt2.exe")
ZIPALIGN    = os.path.join(BUILD_TOOLS, "zipalign.exe")
D8_JAR      = os.path.join(BUILD_TOOLS, "lib", "d8.jar")
APKSIGNER_JAR = os.path.join(BUILD_TOOLS, "lib", "apksigner.jar")

APP_DIR        = os.path.join(ROOT, "app")
MANIFEST       = os.path.join(APP_DIR, "AndroidManifest.xml")
JAVA_SRC       = os.path.join(APP_DIR, "DexPlaceholder.java")
CPP_SRC        = os.path.join(APP_DIR, "cpp", "vulkan_main.cpp")

SHADERS_DIR    = os.path.join(ROOT, "shaders")
SHADERS        = [
    os.path.join(SHADERS_DIR, "triangle.vert"),
    os.path.join(SHADERS_DIR, "triangle.frag"),
]

BUILD_DIR      = os.path.join(ROOT, "_build")
IMD            = os.path.join(BUILD_DIR, "imd")
BIN            = os.path.join(BUILD_DIR, "bin")

ABI            = "arm64-v8a"
TARGET         = "aarch64-linux-android24"
LIB_NAME       = "vulkan_triangle"
SO_FILE        = "lib%s.so" % LIB_NAME
PACKAGE_NAME   = "com.example.vulkantriangle"
APK_NAME       = "vulkan_triangle.apk"


def run(cmd, cwd=None):
    pretty = " ".join(('"%s"' % c if " " in c else c) for c in cmd)
    print(">>", pretty)
    r = subprocess.run(cmd, cwd=cwd)
    if r.returncode != 0:
        sys.exit("command failed: %s" % pretty)


def ensure_dir(p):
    os.makedirs(p, exist_ok=True)


def compile_shaders(out_assets_dir):
    ensure_dir(out_assets_dir)
    for src in SHADERS:
        out = os.path.join(out_assets_dir, os.path.basename(src) + ".spv")
        run([GLSLC, "--target-env=vulkan1.0", "-o", out, src])


def compile_native(lib_out_dir):
    obj_dir = os.path.join(IMD, "obj")
    ensure_dir(obj_dir)
    ensure_dir(lib_out_dir)

    glue_c   = os.path.join(NATIVE_APP_GLUE, "android_native_app_glue.c")
    glue_obj = os.path.join(obj_dir, "android_native_app_glue.o")
    main_obj = os.path.join(obj_dir, "vulkan_main.o")

    common_cflags = [
        "--target=" + TARGET,
        "-fPIC",
        "-O2",
        "-isystem", NATIVE_APP_GLUE,
    ]

    run([CLANG] + common_cflags + ["-c", glue_c, "-o", glue_obj])

    run([CLANGXX] + common_cflags + [
        "-std=c++17",
        "-c", CPP_SRC,
        "-o", main_obj,
    ])

    so_path = os.path.join(lib_out_dir, SO_FILE)
    run([CLANGXX,
         "--target=" + TARGET,
         "-shared",
         "-Wl,-u,ANativeActivity_onCreate",
         "-o", so_path,
         glue_obj, main_obj,
         "-lvulkan", "-landroid", "-llog", "-ldl"])

    return so_path


def compile_java(classes_dir):
    ensure_dir(classes_dir)
    run([JAVAC,
         "-source", "1.8",
         "-target", "1.8",
         "-bootclasspath", ANDROID_JAR,
         "-d", classes_dir,
         JAVA_SRC])


def run_d8(classes_dir, dex_out_dir):
    ensure_dir(dex_out_dir)
    class_files = []
    for dirpath, _dirs, files in os.walk(classes_dir):
        for f in files:
            if f.endswith(".class"):
                class_files.append(os.path.join(dirpath, f))
    run([JAVA,
         "-cp", D8_JAR,
         "com.android.tools.r8.D8",
         "--min-api", "24",
         "--output", dex_out_dir,
         "--lib", ANDROID_JAR,
         ] + class_files)


def aapt2_link(assets_dir, out_apk):
    run([AAPT2, "link",
         "-I", ANDROID_JAR,
         "--manifest", MANIFEST,
         "-A", assets_dir,
         "--min-sdk-version", "24",
         "--target-sdk-version", "36",
         "-o", out_apk])


def add_to_apk(apk_path, entries):
    """entries: list of (archive_name, fs_path, compress)."""
    with zipfile.ZipFile(apk_path, "a", zipfile.ZIP_DEFLATED) as zf:
        for arcname, fs_path, compress in entries:
            ctype = zipfile.ZIP_DEFLATED if compress else zipfile.ZIP_STORED
            zi = zipfile.ZipInfo.from_file(fs_path, arcname)
            zi.compress_type = ctype
            with open(fs_path, "rb") as fh:
                zf.writestr(zi, fh.read())


def ensure_debug_keystore(path):
    if os.path.exists(path):
        return
    run([KEYTOOL,
         "-genkeypair",
         "-keystore", path,
         "-storepass", "android",
         "-keypass", "android",
         "-alias", "androiddebugkey",
         "-dname", "CN=Android Debug,O=Android,C=US",
         "-keyalg", "RSA",
         "-keysize", "2048",
         "-validity", "10000"])


def sign_apk(keystore, in_apk, out_apk):
    shutil.copy2(in_apk, out_apk)
    run([JAVA,
         "-jar", APKSIGNER_JAR,
         "sign",
         "--ks", keystore,
         "--ks-pass", "pass:android",
         "--key-pass", "pass:android",
         "--ks-key-alias", "androiddebugkey",
         "--min-sdk-version", "24",
         out_apk])


def main():
    if os.path.isdir(IMD):
        shutil.rmtree(IMD)
    ensure_dir(IMD)
    ensure_dir(BIN)

    assets_dir    = os.path.join(IMD, "assets")
    lib_out_dir   = os.path.join(IMD, "lib", ABI)
    classes_dir   = os.path.join(IMD, "classes")
    dex_dir       = os.path.join(IMD, "dex")
    # Keep the debug keystore outside IMD so a clean rebuild keeps the same
    # signing identity; otherwise `adb install -r` fails with
    # INSTALL_FAILED_UPDATE_INCOMPATIBLE when the user tries to reinstall.
    keystore      = os.path.join(BUILD_DIR, "debug.keystore")
    base_apk      = os.path.join(IMD, "base.apk")
    unaligned_apk = os.path.join(IMD, "unaligned.apk")
    aligned_apk   = os.path.join(IMD, "aligned.apk")
    final_apk     = os.path.join(BIN, APK_NAME)

    print("[1/7] Compiling shaders")
    compile_shaders(assets_dir)

    print("[2/7] Compiling native library for %s" % ABI)
    so_path = compile_native(lib_out_dir)
    # libvulkan_triangle.so is linked against libc++_shared.so (NDK default),
    # so we must ship it next to our library in the APK.
    libcxx_dst = os.path.join(lib_out_dir, "libc++_shared.so")
    shutil.copy2(LIBCXX_SHARED, libcxx_dst)

    print("[3/7] Compiling Java sources")
    compile_java(classes_dir)

    print("[4/7] Dexing class files")
    run_d8(classes_dir, dex_dir)

    print("[5/7] Linking resources / manifest with aapt2")
    aapt2_link(assets_dir, base_apk)

    print("[6/7] Adding classes.dex and native libs to APK")
    shutil.copy2(base_apk, unaligned_apk)
    add_to_apk(unaligned_apk, [
        ("classes.dex",
         os.path.join(dex_dir, "classes.dex"),
         True),
        ("lib/%s/%s" % (ABI, SO_FILE),
         so_path,
         False),
        ("lib/%s/libc++_shared.so" % ABI,
         os.path.join(lib_out_dir, "libc++_shared.so"),
         False),
    ])

    print("[6b/7] zipalign")
    run([ZIPALIGN, "-p", "-f", "4", unaligned_apk, aligned_apk])

    print("[7/7] Signing APK")
    ensure_debug_keystore(keystore)
    sign_apk(keystore, aligned_apk, final_apk)

    print("\nBuilt %s" % final_apk)


if __name__ == "__main__":
    main()
