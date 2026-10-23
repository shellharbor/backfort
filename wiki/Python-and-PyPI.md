# Python launcher and PyPI distribution

The optional Python distribution bundles the canonical Bash engine and example
YAML. It requires **Python 3.11+ on Linux**, Bash 4.3+, GNU utilities and Mike
Farah yq v4. Python's package named `yq` is a different, incompatible tool.
Feature-specific dependencies (Docker Compose, rclone, crypto tools) remain
external. Native Bash and production Docker/Helm use do not require Python.

## Install and run

Install the published 1.3.0 release with pipx:

```bash
pipx install 'backfort==1.3.0'
backfort --version
```

Or use pip in a virtual environment:

```bash
python3 -m venv .venv
.venv/bin/python -m pip install 'backfort==1.3.0'
.venv/bin/backfort --version
.venv/bin/python -m backfort --help
```

If the release is not available on your index yet, install a trusted
`v1.3.0` checkout with `.venv/bin/python -m pip install .` instead.
Do not install into a system-managed Python.
For privileged backups use a deliberately protected, root-owned installation,
not a user-writable virtual environment executed as root.

Direct execution also works without installing a Python package:

```bash
python3 /opt/backfort/run_backfort.py --version
python3 /opt/backfort/run_backfort.py -c /etc/backfort/config.yaml doctor
```

Use Linux Python inside WSL or the existing image on Windows. Native
Windows/macOS backup execution returns code 2; configuration printing works
without Linux or Bash.

## Configuration and backup

Choose a new output filename: shell redirection overwrites existing files.

```bash
backfort --print-example-config > backfort.example.yaml
# Edit host ID, absolute paths, keys, job names, destinations and retention.
backfort -c "$PWD/backfort.example.yaml" doctor
backfort -c "$PWD/backfort.example.yaml" --dry-run run
backfort -c "$PWD/backfort.example.yaml" run
backfort -c "$PWD/backfort.example.yaml" verify latest --job application --full
backfort -c "$PWD/backfort.example.yaml" restore latest --job application --to /srv/recovery
```

Adapt the job name. Recovery requires a new/empty target and appropriate keys.
The sole wrapper flag is standalone `--print-example-config`: it writes YAML
to stdout and creates no files itself. All other arguments use the Bash parser.
The launcher replaces itself with `os.execv`, preserving literal arguments,
PID, terminal I/O, environment, signals, working directory and engine exits.
It never downloads an engine, uses `bash -c`, elevates privilege or finds an
unrelated `backfort.sh` on PATH. Launcher prerequisite errors return code 2.

## Build and test

```bash
python3 -m venv .venv
.venv/bin/python -m pip install -e '.[dev]'
.venv/bin/python -m ruff check .
.venv/bin/python -m ruff format --check .
.venv/bin/python -m coverage run -m unittest discover -s tests -p 'test_python_*.py' -v
.venv/bin/python -m coverage report
.venv/bin/python -m build
.venv/bin/python -m twine check --strict dist/*
.venv/bin/python tests/python_package.py --round-trip
```

The round trip requires Linux/GNU/yq. It checks isolated wheel installation,
module and console entry points, canonical resources, metadata, rebuilding the
sdist, real backup/full verify/staged restore, excluded files, nonempty-target
refusal and exit codes 0/1/2/3. Without `--round-trip`, artifact/installation
checks also run on Windows. CI tests Python 3.11–3.14/Linux and the Windows
boundary, and requires 100% launcher branch coverage. Dependabot proposes
weekly updates for the Python build and development requirements.

## Integrity and versioning

Hatchling reads `BACKFORT_VERSION` directly from root `backfort.sh`, then
includes that exact engine and reference YAML in each wheel. Never track a
generated engine copy or add an independent Python version. The source archive
uses an explicit allowlist excluding local AI-KIT, credentials and build caches.
The package has no runtime Python dependencies and makes no backup-format or
native CLI change. Both formats explicitly use core metadata 2.4 for
compatibility with the declared Twine 6 toolchain, rather than inheriting a
newer backend default that the upload validator cannot yet parse.

## Publish: explicit maintainer operation

Ordinary CI builds artifacts but does not publish. The manual `Publish Python
package` workflow defaults to TestPyPI, requires a matching `vX.Y.Z` release
tag/CLI version/confirmed Changelog heading, and uses trusted publishing.

1. Confirm ownership/availability of `backfort` separately on PyPI and TestPyPI.
   A missing project page neither reserves the name nor grants upload access.
2. Configure pending/existing trusted publishers for owner `shellharbor`, repo
   `backfort`, workflow `pypi-publish.yml`, and the corresponding `pypi` or
   `testpypi` environment. Set up each index separately.
3. Create those GitHub environments, restrict them to reviewed release tags
   and require maintainer approval. No permanent PyPI API token is needed.
4. Confirm the next release, synchronize version-bearing files, and move its
   project notes from `Unreleased` under an exact `## X.Y.Z` heading. Run full
   required CI before tagging. Do not retag an old release for new contents.
5. Run the workflow **from that tag** with `testpypi`, inspect/install the result
   in an isolated environment, then explicitly run with `pypi`. A maintainer
   may explicitly choose a first publication directly to PyPI after successful
   package/recovery checks and required CI; record that choice rather than
   claiming TestPyPI was tested. The 1.3.0 maintainer chose that path.

For this release, select tag `v1.3.0` in the Actions run dialog. From an
authorized GitHub CLI session, the equivalent dispatches are:

```bash
gh workflow run pypi-publish.yml --repo shellharbor/backfort \
  --ref v1.3.0 -f repository=testpypi
# Inspect the successful TestPyPI upload and validate an isolated install first.
gh workflow run pypi-publish.yml --repo shellharbor/backfort \
  --ref v1.3.0 -f repository=pypi
```

Check the published metadata and install without fallback to another index:

```bash
python3 -m venv /tmp/backfort-testpypi-1.3.0
/tmp/backfort-testpypi-1.3.0/bin/python -m pip install \
  --index-url https://test.pypi.org/simple/ --no-deps 'backfort==1.3.0'
/tmp/backfort-testpypi-1.3.0/bin/backfort --version
```

Use a new environment for each check and run outside the source checkout.
For the final PyPI check, use `https://pypi.org/simple/` instead. Linux and
external Bash/GNU/yq prerequisites still apply. Confirm the project page shows
version `1.3.0` and both wheel and source archive; a local build, GitHub release
or successful workflow dispatch is not proof of publication.

Versions cannot be overwritten. Files under `dist/` are local artifacts, not
evidence of publication. The repository owner must configure index permissions.
See [PyPI trusted publishing](https://docs.pypi.org/trusted-publishers/using-a-publisher/).
