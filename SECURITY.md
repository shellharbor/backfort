# Security policy

Backfort handles backups, credentials, encryption material, cloud destinations,
and restore workflows. Security reports are welcome and should be handled
privately until users have a safe update path.

## Reporting a vulnerability

1. Use GitHub's private vulnerability-reporting flow from this repository's
   **Security** tab when that option is available.
2. If private reporting is not available, do **not** open a public issue with
   exploit details, credentials, backup IDs, bucket names, or customer data.
   Contact the project owner through the [ShellHarbor GitHub profile](https://github.com/shellharbor)
   to establish a safe channel first.
3. Include a minimal reproduction, affected Backfort version or commit,
   operating system, impact, and a safe mitigation when known. Redact all
   secrets and infrastructure identifiers.

Reports are assessed against the current development branch. The project does
not promise a fixed response or remediation deadline, but will acknowledge and
prioritize reproducible issues according to their impact on confidentiality,
integrity, availability, and recovery safety.

## In scope

- `backfort.sh`, its YAML validation, bundle publication, restore, deletion,
  encryption, signing, notification, and Docker Compose logic;
- tracked GitHub Actions workflows, test fixtures, configuration examples, and
  documentation that could lead to an unsafe default;
- accidental exposure of a secret in a tracked project file.

## Out of scope

- vulnerabilities in external services or tools such as Docker, rclone, cloud
  providers, GnuPG, age, Minisign, or the host operating system, unless
  Backfort's integration demonstrably causes the issue;
- unsupported local modifications, exposed credentials, or a compromised host
  without evidence of a Backfort flaw;
- denial-of-service testing against third-party storage or infrastructure
  without explicit authorization.

## Safe research guidelines

- Test only against systems and data you own or are authorized to assess.
- Prefer local fixtures, test buckets, and non-production containers.
- Do not access, alter, delete, encrypt, exfiltrate, or publish other users'
  data to demonstrate impact.
- Never include passwords, API tokens, private keys, backup payloads, database
  dumps, or personal information in a report, issue, pull request, or log.

If a secret is accidentally committed, revoke or rotate it immediately. Removing
the value from a later commit does not make the original exposure harmless.

## Disclosure

Please give maintainers a reasonable opportunity to investigate and prepare a
fix before publishing technical details. Once a fix or mitigation is available,
coordinated disclosure is encouraged, with credit when the reporter wants it.
