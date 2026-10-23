"""Forward literal arguments to the canonical engine without a supervising process."""

import os
import shutil
import sys
from collections.abc import Sequence
from pathlib import Path


def _resource_path(name: str) -> Path:
    """Use installed resources, or the exact source layout in a development checkout."""
    package = Path(__file__).resolve().parent
    bundled = package / "_data" / name
    if bundled.is_file():
        return bundled
    # A damaged installation must not discover an unrelated script above site-packages.
    root = package.parent.parent
    if package == root / "src" / "backfort" and (root / "pyproject.toml").is_file():
        source = root / name
        if source.is_file():
            return source
    raise FileNotFoundError(f"Missing packaged resource: {name}")


def _error(message: str) -> int:
    print(f"Backfort launcher: {message}", file=sys.stderr)
    return 2


def main(argv: Sequence[str] | None = None) -> int:
    """Launch the same CLI; return code 2 only for launcher prerequisites/errors."""
    arguments = list(sys.argv[1:] if argv is None else argv)
    if arguments == ["--print-example-config"]:
        try:
            contents = _resource_path("config.example.yaml").read_text(encoding="utf-8")
        except OSError:
            return _error("cannot read the example configuration; reinstall the package.")
        # The reference YAML is UTF-8 even when a Windows pipe uses a legacy code page.
        if hasattr(sys.stdout, "buffer"):
            sys.stdout.buffer.write(contents.encode("utf-8"))
        else:
            sys.stdout.write(contents)
        return 0

    if sys.platform != "linux":
        return _error("Linux is required. On Windows use WSL or the Docker image.")
    bash = shutil.which("bash")
    if bash is None:
        return _error("Bash 4.3+ is required; install Bash and the documented GNU utilities.")
    try:
        engine = _resource_path("backfort.sh")
    except OSError:
        return _error("cannot find the bundled Bash engine; reinstall the package.")
    try:
        # exec preserves PID, terminal, stdin/out/err, environment, signals and exit codes.
        # Never use a shell command string, bash -c, or an engine found on PATH.
        os.execv(bash, [bash, str(engine), *arguments])
    except OSError:
        return _error("cannot execute the Bash engine; check interpreter and file permissions.")
    return 0
