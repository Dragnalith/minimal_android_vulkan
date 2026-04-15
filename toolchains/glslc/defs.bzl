"""Starlark definitions for the glslc SPIR-V compiler toolchain.

Usage:
    load("//toolchains/glslc:defs.bzl", "glsl_shader")

    glsl_shader(
        name       = "triangle_vert",
        src        = "triangle.vert",
        target_env = "vulkan1.0",
    )
"""

GlslcInfo = provider(
    doc = "Information about the glslc SPIR-V compiler.",
    fields = {
        "glslc": "A File object for the glslc executable.",
    },
)

def _glslc_toolchain_impl(ctx):
    toolchain_info = platform_common.ToolchainInfo(
        glslcinfo = GlslcInfo(glslc = ctx.file.glslc),
    )
    return [toolchain_info]

glslc_toolchain = rule(
    implementation = _glslc_toolchain_impl,
    attrs = {
        "glslc": attr.label(
            doc               = "The glslc compiler executable.",
            allow_single_file = True,
            mandatory         = True,
            cfg               = "exec",
        ),
    },
)

_GLSLC_TOOLCHAIN_TYPE = "//toolchains/glslc:toolchain_type"

def _glsl_shader_impl(ctx):
    tc    = ctx.toolchains[_GLSLC_TOOLCHAIN_TYPE].glslcinfo
    glslc = tc.glslc
    src   = ctx.file.src

    out = ctx.actions.declare_file(src.basename + ".spv")

    args = ctx.actions.args()
    args.add("--target-env=" + ctx.attr.target_env)
    args.add("-o", out)
    args.add(src)

    ctx.actions.run(
        executable       = glslc,
        arguments        = [args],
        inputs           = [src],
        outputs          = [out],
        mnemonic         = "GlslCompile",
        progress_message = "Compiling GLSL shader %s -> %s" % (
            src.short_path, out.short_path),
    )

    return [DefaultInfo(files = depset([out]))]

glsl_shader = rule(
    implementation = _glsl_shader_impl,
    attrs = {
        "src": attr.label(
            doc               = "A single GLSL source file.",
            allow_single_file = [".vert", ".frag", ".comp", ".geom", ".tesc", ".tese"],
            mandatory         = True,
        ),
        "target_env": attr.string(
            doc     = "Vulkan target environment passed to glslc.",
            default = "vulkan1.0",
        ),
    },
    toolchains = [_GLSLC_TOOLCHAIN_TYPE],
)
