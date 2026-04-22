"""Thin wrapper over `python.runfiles.Runfiles` for the Android tools.

`py_binary(args = ["--flag=$(rlocationpath //some:label)"])` passes the
runfiles-relative path as a positional argument. This helper resolves it to
an absolute filesystem path at runtime.
"""

from python.runfiles import Runfiles

_RUNFILES = Runfiles.Create()


def resolve(rlocation_path: str) -> str:
    """Return the absolute path for a runfiles-relative path.

    Fails loudly if the file is not materialised in runfiles; this catches
    BUILD misconfigurations (label present in `args` but missing from `data`)
    early instead of producing obscure 'file not found' errors downstream.
    """
    abs_path = _RUNFILES.Rlocation(rlocation_path)
    if abs_path is None:
        raise SystemExit(
            "runfiles: cannot resolve '%s'. Is the label listed in the py_binary's "
            "`data` attribute?" % rlocation_path
        )
    return abs_path
