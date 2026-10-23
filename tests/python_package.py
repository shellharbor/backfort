#!/usr/bin/env python3
"""Check built artifacts, rebuild the sdist and exercise an isolated wheel install."""

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import tarfile
import tempfile
import venv
import zipfile
from collections.abc import Mapping, Sequence
from email.parser import BytesParser
from pathlib import Path

from packaging.requirements import Requirement

ROOT = Path(__file__).resolve().parents[1]


def run(
    arguments: Sequence[str],
    *,
    cwd: Path,
    env: Mapping[str, str] | None = None,
    expected: int = 0,
) -> subprocess.CompletedProcess[str]:
    """Run without a shell and retain failure evidence without dumping environment values."""
    result = subprocess.run(
        arguments,
        cwd=cwd,
        env=env,
        text=True,
        encoding="utf-8",
        capture_output=True,
        check=False,
        timeout=120,
    )
    if result.returncode != expected:
        raise AssertionError(
            f"Unexpected exit code {result.returncode} (expected {expected}):\n"
            f"{result.stdout}\n{result.stderr}"
        )
    return result


def check_wheel(wheel: Path, version: str) -> None:
    """The built wheel must contain the canonical engine/config, not a second copy in Git."""
    with zipfile.ZipFile(wheel) as archive:
        names = archive.namelist()
        for resource in ("backfort.sh", "config.example.yaml"):
            contents = archive.read(f"backfort/_data/{resource}")
            assert (
                hashlib.sha256(contents).digest()
                == hashlib.sha256((ROOT / resource).read_bytes()).digest()
            )
        metadata_name = next(name for name in names if name.endswith(".dist-info/METADATA"))
        metadata = BytesParser().parsebytes(archive.read(metadata_name))
        assert metadata["Name"] == "backfort"
        assert metadata["Version"] == version
        assert metadata["Requires-Python"] == ">=3.11"
        assert metadata["Metadata-Version"] == "2.4"
        requirements = [Requirement(value) for value in metadata.get_all("Requires-Dist", [])]
        assert all(
            requirement.marker is not None
            and not requirement.marker.evaluate({"extra": ""})
            and requirement.marker.evaluate({"extra": "dev"})
            for requirement in requirements
        )
        entry_points = next(name for name in names if name.endswith(".dist-info/entry_points.txt"))
        assert "backfort = backfort.cli:main" in archive.read(entry_points).decode()
        assert all(
            name.startswith(("backfort/", f"backfort-{version}.dist-info/")) for name in names
        )


def round_trip(command: Sequence[str], directory: Path, env: Mapping[str, str]) -> None:
    """Exercise real backup/verification, exclusions and the nonempty-restore boundary."""
    source = directory / "source with spaces"
    source.mkdir()
    (source / "important.txt").write_text("Python package round trip\n", encoding="utf-8")
    (source / "ignored.log").write_text("excluded\n", encoding="utf-8")
    config = directory / "config with spaces.yaml"
    backup = directory / "backups"
    plan = {
        "version": 1,
        "settings": {
            "host_id": "python-package-host",
            "state_directory": str(directory / "state"),
            "temp_directory": str(directory / "work"),
            "lock_file": str(directory / "state/backfort.lock"),
            "min_free_mb": 0,
        },
        "destinations": [{"name": "local", "type": "local", "path": str(backup)}],
        "jobs": [
            {
                "name": "package",
                "source": {
                    "type": "files",
                    "paths": [str(source)],
                    "exclude": ["*.log"],
                    "follow_symlinks": False,
                },
                "destinations": ["local"],
                "success": {"min_copies": 1},
                "compression": {"method": "gzip", "level": 6},
                "encryption": {"method": "none"},
                "retention": {
                    "keep_last": 1,
                    "min_keep": 1,
                    "keep_daily": 0,
                    "keep_weekly": 0,
                    "keep_monthly": 0,
                },
            }
        ],
    }
    config.write_text(json.dumps(plan), encoding="utf-8")
    prefix = [*command, "-c", str(config)]
    run([*prefix, "doctor"], cwd=directory, env=env)
    run([*prefix, "--dry-run", "run"], cwd=directory, env=env)
    assert not list(backup.glob("*.complete"))
    run([*prefix, "run"], cwd=directory, env=env)
    assert len(list(backup.glob("*.complete"))) == 1
    listing = run([*prefix, "list", "--job", "package", "--json"], cwd=directory, env=env)
    assert len(json.loads(listing.stdout)) == 1
    run([*prefix, "verify", "latest", "--job", "package", "--full"], cwd=directory, env=env)
    restore = directory / "restore"
    run(
        [*prefix, "restore", "latest", "--job", "package", "--to", str(restore)],
        cwd=directory,
        env=env,
    )
    restored = restore / str(source).lstrip("/")
    assert (restored / "important.txt").read_bytes() == (source / "important.txt").read_bytes()
    assert not (restored / "ignored.log").exists()
    run(
        [*prefix, "restore", "latest", "--job", "package", "--to", str(restore)],
        cwd=directory,
        env=env,
        expected=2,
    )

    # The Python entry point must preserve the engine's partial and policy-failure exits.
    blocker = directory / "not-a-directory"
    blocker.write_text("blocked\n", encoding="utf-8")
    plan["destinations"].append(
        {"name": "blocked", "type": "local", "path": str(blocker / "backup")}
    )
    plan["jobs"][0]["destinations"].append("blocked")
    config.write_text(json.dumps(plan), encoding="utf-8")
    run([*prefix, "run"], cwd=directory, env=env, expected=1)
    plan["jobs"][0]["success"]["min_copies"] = 2
    config.write_text(json.dumps(plan), encoding="utf-8")
    run([*prefix, "run"], cwd=directory, env=env, expected=3)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dist-directory", type=Path, default=ROOT / "dist")
    parser.add_argument(
        "--round-trip", action="store_true", help="Require Linux/GNU tools/yq for a real backup"
    )
    options = parser.parse_args()
    version_match = re.search(
        r'^readonly BACKFORT_VERSION="([0-9]+\.[0-9]+\.[0-9]+)"$',
        (ROOT / "backfort.sh").read_text(encoding="utf-8"),
        re.MULTILINE,
    )
    assert version_match, "The Bash engine must declare a release version"
    version = version_match[1]
    distribution = options.dist_directory.resolve()
    wheel = distribution / f"backfort-{version}-py3-none-any.whl"
    sdist = distribution / f"backfort-{version}.tar.gz"
    check_wheel(wheel, version)
    assert sdist.is_file(), "Missing source distribution"
    with tarfile.open(sdist, "r:gz") as archive:
        prefix = f"backfort-{version}/"
        permitted = {
            "README.md",
            "backfort.sh",
            "config.example.yaml",
            "run_backfort.py",
            "pyproject.toml",
            "LICENSE",
            ".gitignore",
            "PKG-INFO",
            "docs/pypi.md",
            "src/backfort/__init__.py",
            "src/backfort/__main__.py",
            "src/backfort/cli.py",
            "tests/test_python_launcher.py",
            "tests/python_package.py",
        }
        for member in archive.getmembers():
            assert member.isfile() and member.name.startswith(prefix), member.name
            assert member.name.removeprefix(prefix) in permitted, member.name
    if options.round_trip and sys.platform != "linux":
        parser.error("--round-trip requires Linux; use WSL, CI or a disposable Linux container")

    with tempfile.TemporaryDirectory(prefix="backfort-package-") as temporary:
        directory = Path(temporary)
        clean_env = os.environ.copy()
        clean_env.pop("PYTHONPATH", None)
        clean_env.pop("PYTHONHOME", None)
        clean_env["PYTHONNOUSERSITE"] = "1"
        rebuilt = directory / "rebuilt"
        run(
            [
                sys.executable,
                "-m",
                "pip",
                "wheel",
                "--no-deps",
                "--no-index",
                "--no-build-isolation",
                "--wheel-dir",
                str(rebuilt),
                str(sdist),
            ],
            cwd=directory,
            env=clean_env,
        )
        check_wheel(rebuilt / wheel.name, version)

        environment = directory / "environment"
        venv.EnvBuilder(with_pip=True).create(environment)
        scripts = environment / ("Scripts" if os.name == "nt" else "bin")
        python = scripts / ("python.exe" if os.name == "nt" else "python")
        executable = scripts / ("backfort.exe" if os.name == "nt" else "backfort")
        run(
            [str(python), "-m", "pip", "install", "--no-deps", "--no-index", str(wheel)],
            cwd=directory,
            env=clean_env,
        )
        imported = run(
            [str(python), "-I", "-c", "import backfort; print(backfort.__file__)"],
            cwd=directory,
            env=clean_env,
        )
        assert Path(imported.stdout.strip()).is_relative_to(environment)
        for command in (
            [str(executable)],
            [str(python), "-I", "-m", "backfort"],
            [sys.executable, str(ROOT / "run_backfort.py")],
        ):
            sample = run([*command, "--print-example-config"], cwd=directory, env=clean_env)
            assert sample.stdout == (ROOT / "config.example.yaml").read_text(encoding="utf-8")
            if sys.platform == "linux":
                result = run([*command, "--version"], cwd=directory, env=clean_env)
                assert result.stdout.strip() == f"Backfort {version}"
                run([*command, "--help"], cwd=directory, env=clean_env)
                run(
                    [*command, "--invalid-synthetic-option"],
                    cwd=directory,
                    env=clean_env,
                    expected=2,
                )
            else:
                result = run([*command, "--version"], cwd=directory, env=clean_env, expected=2)
                assert "Linux is required" in result.stderr
        if options.round_trip:
            round_trip([str(executable)], directory, clean_env)
        print("Wheel, rebuilt sdist, isolated install and entry points: OK")
        if options.round_trip:
            print("Real backup/full verify/restore/exclusion and exit codes 0/1/2/3: OK")


if __name__ == "__main__":
    main()
