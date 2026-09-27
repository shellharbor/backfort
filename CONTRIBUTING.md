# Contributing to Backfort

Thanks for helping improve Backfort. This project protects recovery data, so a
small change can affect whether a user can restore during an incident. Prefer
small, reviewable changes with clear safety and recovery behavior.

## Before you start

- Read the [README](README.md), the relevant [Wiki source](wiki/Home.md), and
  [security policy](SECURITY.md).
- Search existing issues and code before proposing an interface or duplicate
  implementation.
- Use a disposable source directory, state directory, backup destination, and
  test bucket/container. Never develop against production data.
- Do not report a security vulnerability in a public issue; follow
  [SECURITY.md](SECURITY.md) instead.

## Development setup

Backfort targets Linux with Bash 4.3+, GNU userland, and Mike Farah `yq` v4.
The CI workflow documents the complete test environment; it also checks Bash
4.3 syntax. CodeQL reviews GitHub Actions definitions, OpenSSF Scorecard
publishes supply-chain findings, and a release tag is checked against the CLI
version and Changelog. Start with a syntax check and the main smoke test:

```bash
bash -n backfort.sh tests/*.sh
bash tests/smoke.sh
```

When available, also run ShellCheck:

```bash
shellcheck backfort.sh tests/*.sh
```

Run the focused test for the changed surface. The suite includes quick backup,
rclone, Docker Compose and its restore assistant, crypto/signing, watchdog,
diff, pins, date-range deletion, interactive restore selection, notifications,
lifecycle hooks, and Prometheus metrics:

```bash
bash tests/quick.sh
bash tests/rclone-smoke.sh
bash tests/compose-smoke.sh
bash tests/restore-compose.sh
bash tests/crypto-smoke.sh
bash tests/watchdog.sh
bash tests/diff.sh
bash tests/pinned.sh
bash tests/delete-period.sh
bash tests/pick.sh
bash tests/notify.sh
bash tests/hooks.sh
bash tests/metrics.sh
```

The tests are intentionally hermetic: use their temporary fake Docker and
rclone boundaries rather than live cloud storage.

GitHub Actions also runs a Documentation workflow for local Markdown links in
the README, Wiki sources, examples, and community files. Keep public links
relative when they point inside this repository so that check can protect them.

## What a good contribution includes

1. One clear problem statement and a narrow implementation.
2. A focused automated test covering the behavior and its meaningful failure
   path. Security and destructive-operation changes need negative tests too.
3. A review of the recovery contract: incomplete bundles must remain unusable;
   restore remains staged; remote writes and deletes preserve commit-marker
   ordering.
4. Documentation synchronized with the changed public behavior:
   `README.md`, `config.example.yaml`, applicable `examples/`, and the relevant
   `wiki/` pages.
5. An update to `SKILL.md` when scope, CLI, YAML, safety rules, tests, layout,
   or documentation routing changes.

## Bash and security conventions

- Keep Bash compatible with version 4.3 and preserve `set -Eeuo pipefail` and
  the project's controlled `IFS` convention.
- Validate every external input at the boundary. Configuration is strict;
  unknown keys should not silently become defaults.
- Quote shell expansions. Do not introduce `eval`, template-driven execution,
  or user-controlled `bash -c` / `sh -c`.
- Never add passwords, cloud keys, encryption identities, database dumps, or
  production paths to commits, examples, fixtures, logs, or screenshots.
- Keep rclone operations narrow. Do not replace object-level publication with
  a broad remote `sync`.

## Pull requests

Explain the user-visible behavior, safety implications, tests run, and any
checks you could not run locally. Keep unrelated formatting or refactoring out
of the same pull request. Maintainers may request a recovery scenario or a
failure-path test before merging.

By contributing, you agree to follow the [Code of Conduct](CODE_OF_CONDUCT.md)
and license your contribution under this repository's [MIT License](LICENSE).
