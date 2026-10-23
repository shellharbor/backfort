# ADR-0002: Bundle the Bash engine behind a Python launcher

- Date: 2026-10-23
- Status: accepted

## Context

The user requested Python-script execution and a PyPI package. Backfort's Linux
Bash engine already implements recovery safeguards. A wheel must work without
a checkout or separately installed script; Python does not supply GNU tools.

## Options

1. Rewrite the engine in Python, duplicating recovery logic and changing scope.
2. Download/find an external engine, adding network/PATH/version ambiguity.
3. Bundle the canonical root engine during builds and pass literal arguments.

## Decision

Choose option 3. Hatchling reads the version from `backfort.sh` and includes
its exact bytes and the reference config. An explicit sdist allowlist excludes
local AI-KIT/secrets. No generated engine copy or separate version is tracked.
The standard-library launcher requires Linux/Python 3.11+ and uses `os.execv`
to preserve process and terminal semantics. Only standalone
`--print-example-config` is interpreted in Python. `run_backfort.py` bootstraps
the checkout without shadowing the installed `backfort` package.

## Consequences

Archives, validation, privileges, native shell execution and Docker/Helm
runtime contracts remain unchanged. Windows/macOS execution is rejected with
guidance instead of claiming GNU fidelity. System dependencies stay external.
No engine download, dependency installation or privilege elevation occurs.
Publishing is a manual tagged-release operation through protected environments
and trusted publishers configured by the owner. Rollback selects an earlier
trusted wheel and does not rewrite bundles.

## Verification

See [launcher tests](../../tests/test_python_launcher.py),
[artifact/recovery checks](../../tests/python_package.py) and the
[runbook](../../wiki/Python-and-PyPI.md): literal arguments, prerequisite
failures, canonical resources, isolated installs, rebuilt sdists, complete
launcher branch coverage, real restore and engine exit codes.
