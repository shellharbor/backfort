# ADR-0003: Move the container runtime to Debian trixie and POSIX mawk

- Date: 2026-10-26
- Status: accepted; v1.4.0 publication authorized by the owner

## Context

The pinned downstream Backfort 1.2.0 bookworm image has CRITICAL findings in
gawk, SQLite, GLib and zlib that cannot all be remediated within bookworm.
Backfort must preserve GnuPG, SMTP, encryption/signing and GNU tar's
ACL/xattr/sparse/numeric-owner recovery contract. Removing those features or
adding scanner exceptions would not meet the request.

## Decision

Use Debian trixie-slim pinned to its multi-architecture index digest. Pin the
Docker CLI, yq and rclone stage indexes too. Retain GNU tar/coreutils and all
existing feature packages, replacing gawk with explicit mawk. The engine's
awk programs use POSIX operations; the image build and regression test assert
that awk resolves to mawk and gawk is not installed.

Prepare application version 1.4.0 and chart patch 0.1.1. CLI/YAML and backup
formats do not change. Do not publish/push a release tag before explicit owner
approval, and do not change the downstream Filaver Data repository or policy.

## Alternatives

- Keep bookworm and suppress its CVEs: rejected; it leaves the requested
  findings present and hides the security delta.
- Remove GnuPG/msmtp: rejected because it removes supported features.
- Replace GNU tar/userland with Alpine: rejected because recovery fidelity
  depends on GNU behavior and would require a separate compatibility project.
- Upgrade gawk alone: rejected because both requested gawk issues remain
  affected in newer Debian suites; GNU-specific awk is not required.

## Consequences and verification

glib's binary package becomes `libglib2.0-0t64`; package versions and behavior
must be checked, not assumed from the distribution name. A newer suite can
introduce different vulnerabilities. Report all severities and new HIGH/
CRITICAL findings without suppressing unfixed issues or secret scanning.

Run Trivy 0.75 with one unchanged vulnerability database against the baseline
and production candidate, not the development test layer. Require all five
target CVEs absent and no CRITICAL with a fixed version. Run every shell
regression driver on the new runtime, real crypto/metadata image tests and
the separate Bash 4.3 compatibility regression. Preserve root-capable recovery,
the narrower optional non-root profile, readonly deployment/storage contracts
and one-shot Kubernetes Job/CronJob operation.

See [the verification report](../security/trixie-1.4.0.md) for actual evidence,
remaining risks and publication status. A local index digest is not proof of
publication in a registry.
