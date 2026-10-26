# Backfort 1.4.0 container security verification

Verification date: **2026-10-26**. Status: **published and verified**.
Tag `v1.4.0` points to `5ceabc15cc5f99d6fdda67a1f2d9f538e6e7d511`.
Both registries contain amd64/arm64 images; stable aliases `1.4`, `1` and
`latest` match their respective release indexes. No Filaver Data files or
release policy were changed.

## Published multiarch indexes

| Registry | Immutable release reference |
| --- | --- |
| Docker Hub | `shellharbor/backfort:1.4.0@sha256:123dcd108b6e7cb25ee30e2d199d52b4f19662e518508cf3372df5dd9c3a08b0` |
| GHCR | `ghcr.io/shellharbor/backfort:1.4.0@sha256:f931ffa31afdefd72f69c6a85c42c9db7f0b0258cb7294a2f38c0bed9f4e31fe` |

These are registry **multiarch index** digests, not platform image or local
candidate digests. The release workflow attached provenance and SBOM data.

| Registry | amd64 manifest | arm64 manifest |
| --- | --- | --- |
| Docker Hub | `sha256:4bb84d395028a559292fdf538db83b2e825af20c7ff138d8d48eec4203ab2ff1` | `sha256:1961d6990c943858273d67f59a2686c2156d2f5d6997c2b8bcb28ed9199fb8b3` |
| GHCR | `sha256:cae40e9d14f8f6c1659492c763a0eec14ecd2f89008ebd5e8e06e13ae4a4614a` | `sha256:f7b6b9a3341b41ec6ec02e5b4603d18ac47292a8da5ffc3088914dfa812a4f8d` |

All four published variants were scanned with the same pinned Trivy 0.75
image, database and full vuln+secret settings used below. Each has C/H/M/L/U
**0/63/119/171/3**, OS-only **0/56/101/170/1**, zero secrets and none of the
five target CVEs. Image version/revision labels match 1.4.0 and the release
commit. Both Docker Hub engines match the tag's Bash bytes and pass real
crypto and ACL/xattr/numeric-owner backup/full-verify/restore after download.

The full main-commit [CI](https://github.com/shellharbor/backfort/actions/runs/40347867442),
[real Kubernetes PVC recovery](https://github.com/shellharbor/backfort/actions/runs/40347867440),
Python matrix, documentation, CodeQL and Scorecard passed before tag creation.
Tag [CI](https://github.com/shellharbor/backfort/actions/runs/40348979314),
[Kubernetes](https://github.com/shellharbor/backfort/actions/runs/40348979473),
Python and the complete [multiarch publication workflow](https://github.com/shellharbor/backfort/actions/runs/40348979537)
also passed. Full JSON reports and their SHA-256 manifest are available with
the [GitHub release](https://github.com/shellharbor/backfort/releases/tag/v1.4.0).

Both amd64 and arm64 production candidates remove all five requested bookworm CVEs and
have **zero CRITICAL findings**. They retain GnuPG, SMTP and GNU recovery
semantics. Trixie introduces one HIGH CVE, reported against seven GnuPG
packages; this report includes it without an exception or severity filter.

## Scope and acceptance criteria

- Replace the bookworm runtime with digest-pinned Debian trixie-slim.
- Use POSIX mawk, with build/image guards rejecting installed GNU awk.
- Keep GNU tar ACL/xattr/sparse/numeric-owner behavior and every feature
  package, including GnuPG and `msmtp-mta`.
- Run every shell regression driver on a test layer of the new image, plus
  real crypto and metadata recovery inside the untouched production image.
- Scan all OS and binary dependencies with Trivy 0.75 vulnerability **and
  secret** scanners. Report C/H/M/L/U, including unfixed findings. Require
  the five target CVEs absent and no CRITICAL with an available fix.
- Verify both release architectures before claiming a tested multiarch
  release. A local amd64 digest is not a published multiarch index digest.

Application version is **1.4.0**; Helm chart version is **0.1.1**,
with `appVersion: 1.4.0`. The CLI, configuration schema and bundle format do
not change. PyPI 1.4.0 has not been published by this task.

## Exact images and scanner

| Input | Reference |
| --- | --- |
| Downstream baseline | `docker.io/shellharbor/backfort:1.2.0@sha256:9c3a0e03fda11fc449e44417adfdd8b144b228426b666982bb4411b69ea6b84e` |
| Local candidate | `backfort:1.4.0-candidate-amd64` |
| Local candidate index | `sha256:38a4e2861084811bfd996fcfd84b11ea29a16dd79a9e9151daeaa6f4ee4dc690` (amd64 with build attestation; not a release index) |
| Candidate amd64 image manifest | `sha256:561733e83938a2d053a9f32e8a7c24f3edf2502d2ddc99be30e1b5b081b6297b` |
| Baseline arm64 image manifest | `sha256:16b66f1d9419593c323090328430fc84b208ac309fa654ea9a651be7479e2002` (member of the baseline index above) |
| Local arm64 candidate | `backfort:1.4.0-candidate-arm64` |
| Local arm64 candidate index | `sha256:1e338d741b2d44ef727317a9a9afcbb3030c43113ee35f558c1e2187226b8427` (arm64 with build attestation; not a release index) |
| Candidate arm64 image manifest | `sha256:bdfa56190ecc706ca07aa8f6289bc2215d5db77e6cfbf64c1d53a17f3118fb26` |
| Scanner | `aquasec/trivy:0.75.0@sha256:af6acf9a6b85dfe389a1941505c0ce9efef52a4719635e1a962f022a3d855daa` |
| Database | schema v2; updated `2026-10-26T07:15:18.945937093Z`; downloaded `2026-10-26T12:54:34.247721112Z` |

All baseline, candidate and published scans use this same cached database. Only the initial amd64 baseline
scan downloads it; subsequent scans use `--skip-db-update`. The test-only development image is
neither the release candidate nor the vulnerability-scan target.

All Dockerfile external stages are pinned to their multiarch indexes:

| Stage | Pinned reference |
| --- | --- |
| Runtime | `debian:trixie-slim@sha256:62bd423aeee912639ca8ee681c2b762cb3e25137e0a92b20be455898a9f034ad` |
| Docker CLI / Compose | `docker:29-cli@sha256:5e6baf67325a79f64ed3bed6863954d5e05d0f3d4e57cbdb14809346814bbfdb` |
| yq | `mikefarah/yq:4.54.1@sha256:4b3d9475d65571d28cbb19544d3820ec2945e4c8b2f18279394282b8dc3a592e` |
| rclone | `rclone/rclone:1.75.2@sha256:2687085f718d3c628f7fdfb77c52a1d344332aed543110bb88088f2c70d43eb5` |

APT packages are resolved from trixie repositories during the build, rather
than frozen to vulnerable versions. Pinning base indexes does not freeze APT
repository contents; re-scan the exact final release digest after publication.

## Full Trivy results: linux/amd64 and linux/arm64

Counts are package/target vulnerability findings, **not distinct CVE IDs**.
The total includes Debian packages and dependencies in copied Go binaries.
The OS-only rows are a separate subtotal, not additional findings.

| Scope / image | CRITICAL | HIGH | MEDIUM | LOW | UNKNOWN |
| --- | ---: | ---: | ---: | ---: | ---: |
| All packages: 1.2.0 amd64 | 8 | 107 | 215 | 192 | 6 |
| All packages: 1.4.0 amd64 | **0** | **63** | **119** | **171** | **3** |
| All packages: 1.2.0 arm64 | 8 | 107 | 215 | 192 | 6 |
| All packages: 1.4.0 arm64 | **0** | **63** | **119** | **171** | **3** |
| OS only: 1.2.0 amd64 | 8 | 87 | 163 | 188 | 4 |
| OS only: 1.4.0 amd64 | **0** | **56** | **101** | **170** | **1** |
| OS only: 1.2.0 arm64 | 8 | 87 | 163 | 188 | 4 |
| OS only: 1.4.0 arm64 | **0** | **56** | **101** | **170** | **1** |

Secret findings: **0 before, 0 after on both architectures**.
Target CVE findings after: **0 on both architectures**.
CRITICAL findings with a fixed version after: **0** (there are no CRITICAL
findings at all in this scan). No `.trivyignore`, VEX, severity exclusion or
`--ignore-unfixed` was used to obtain these results. Gawk is deliberately
replaced by mawk as requested; GnuPG, SMTP and their dependencies remain.

### The five requested CVEs

| CVE | Baseline package | Candidate result |
| --- | --- | --- |
| [CVE-2026-40468](https://security-tracker.debian.org/tracker/CVE-2026-40468) | gawk `1:5.2.1-2` | Absent: gawk is not installed; awk resolves to mawk. |
| [CVE-2026-40469](https://security-tracker.debian.org/tracker/CVE-2026-40469) | gawk `1:5.2.1-2` | Absent: gawk is not installed; all awk-dependent regressions run with mawk. |
| [CVE-2025-7458](https://security-tracker.debian.org/tracker/CVE-2025-7458) | `libsqlite3-0` `3.40.1-2+deb12u2` | Absent: installed `3.46.1-7+deb13u2`. |
| [CVE-2026-58016](https://security-tracker.debian.org/tracker/CVE-2026-58016) | `libglib2.0-0` `2.74.6-2+deb12u9` | Absent: trixie package is `libglib2.0-0t64`, installed `2.84.4-3~deb13u5`. |
| [CVE-2023-45853](https://security-tracker.debian.org/tracker/source-package/zlib) | `zlib1g` `1:1.2.13.dfsg-1` | Absent: installed `1:1.3.dfsg+really1.3.1-1+b1`. |

The baseline's other three CRITICAL findings, in `perl-base`, also disappear:
`CVE-2026-13221`, `CVE-2026-42496`, and `CVE-2026-8376`.

### New CRITICAL/HIGH findings

There are **no new CRITICAL CVEs**. Comparing CRITICAL/HIGH CVE IDs with the
baseline yields one newly introduced HIGH:

| CVE | Severity | Affected candidate packages | Fixed version reported by Trivy |
| --- | --- | --- | --- |
| [CVE-2026-24882](https://security-tracker.debian.org/tracker/CVE-2026-24882) | HIGH | `dirmngr`, `gnupg`, `gnupg-l10n`, `gpg`, `gpg-agent`, `gpgconf`, `gpgsm` (`2.4.7-21+deb13u1` series, binary rebuild suffixes where applicable) | None in trixie; all seven findings remain in the counts. |

Debian describes a stack buffer overflow in the TPM-backed key-decryption
helper of GnuPG. Bookworm is not affected, while trixie is marked vulnerable
and `no-dsa`; the tracker lists `2.4.9-8` as fixed in newer suites. This is
not represented as a clean HIGH scan or suppressed because normal backup
encryption succeeds. GnuPG remains installed as required. The owner must see
this risk before authorizing the release.

### All remaining HIGH findings

These are the complete HIGH CVE groups in both candidates. There are no
CRITICAL groups. An empty fixed version means the scanner reports no trixie
package fix; it does not establish that the vulnerability is harmless.

| CVE | Packages / binary targets | Fixed version in the scan |
| --- | --- | --- |
| CVE-2025-69720 | `libncursesw6`, `libtinfo6`, `ncurses-base`, `ncurses-bin` | None |
| CVE-2026-12064 | `curl`, `libcurl4t64` | None |
| CVE-2026-16742 | `libsystemd0`, `libudev1` | None |
| CVE-2026-24882 | Seven GnuPG packages listed above | None |
| CVE-2026-54369 | `acl`, `libacl1` | None |
| CVE-2026-76642 | `bsdutils`, `libblkid1`, `liblastlog2-2`, `libmount1`, `libsmartcols1`, `libuuid1`, `login`, `mount`, `util-linux` | None |
| CVE-2026-78408 | Same util-linux package group | None |
| CVE-2026-78409 | Same util-linux package group | None |
| CVE-2026-78410 | Same util-linux package group | None |
| CVE-2026-8458 | `curl`, `libcurl4t64` | None |
| CVE-2026-9538 | `perl-base` | None (`fix_deferred`) |
| CVE-2026-111943 | Go stdlib: rclone `v1.27.2`, yq `v1.27.1` | Go `1.26.10`, `1.27.3` |
| CVE-2026-78667 | Go stdlib: yq `v1.27.1` | Go `1.26.9`, `1.27.2` |
| CVE-2026-78669 | yq Go stdlib `v1.27.1`; `golang.org/x/net` in yq `v0.59.0` and Compose `v0.58.0` | Go `1.26.9` / `1.27.2`; x/net `0.60.0` |
| CVE-2026-97031 | Go stdlib: yq `v1.27.1` | Go `1.26.9`, `1.27.2` |

Those copied-binary HIGH findings were already present in the baseline scan;
they are disclosed here and remain outside the five-CVE base-image fix. Their
available fixes must not be confused with the acceptance rule of **no fixed
CRITICAL**.

## Runtime package and behavior check

Installed production-image versions match on amd64 and arm64:

| Package | Version | Relevant verification |
| --- | --- | --- |
| `acl` | `2.3.2-2+b1` | Numeric ACL survives production-image backup/restore. |
| `age` | `1.2.1-1+b5` | Real key generation, encryption, decryption and byte comparison. |
| `attr` | `1:2.5.2-3` | User xattr survives production-image backup/restore. |
| `bash` | `5.2.37-2+b10` | Runtime `5.2.37(1)`; full shell suite; separate genuine Bash 4.3 regression. |
| `ca-certificates` | `20250419+deb13u1` | Retained system trust store; matches on both architectures. |
| `coreutils` | `9.7-3` | Checksums, metadata and archive regressions. |
| `curl` | `8.14.1-2+deb13u7` | Version and local-file transfer in runtime smoke. |
| `findutils` | `4.10.0-3` | Archive inventory, retention and recovery regressions. |
| `gnupg` / `gpg` | `2.4.7-21+deb13u1` / `2.4.7-21+deb13u1+b5` | Real symmetric and asymmetric round trips; new HIGH remains disclosed. |
| `gzip` | `1.13-1+deb13u1` | Compression/recovery regressions. |
| `mawk` | `1.3.4.20250131-1` | `/usr/bin/awk` resolves to `/usr/bin/mawk`; no gawk command or installed package. |
| `minisign` | `0.12-1` | Real key generation, detached signing and verification. |
| `msmtp-mta` | `1.8.28-3` | Version and offline transport configuration parsing; `/usr/sbin/sendmail` resolves to msmtp. No external email is sent. |
| `tar` | `1.35+dfsg-3.1` | GNU tar; sparse/link/archive resilience and ACL/xattr/numeric-owner restore tests. |
| `util-linux` | `2.41.5-0+deb13u1` | `flock` and lock/overlap regressions. |
| `zstd` | `1.5.7+dfsg-1` | Real compress/decompress byte comparison. |

All explicitly installed APT package names remain valid in trixie. GLib's
transitive library name changes to `libglib2.0-0t64`. CA certificates are
retained. The image still includes rclone **1.75.2**, Docker CLI **29.9.2**,
Compose **5.6.1**, and Mike Farah yq **4.54.1**. No feature was removed to
reduce scanner findings.

## Regression evidence

Both production images are tested read-only with writable state/work mounts.
`tests/docker-image.sh` runs the real `tests/container/runtime-smoke.sh` within
that image, then performs a files backup, full verification and staged restore
with UID/GID **42424:42425**, named ACL UID **65534**, and a user xattr.

`tests/container/Dockerfile` adds only Python and ShellCheck test tooling to a
separate layer. `tests/container/suite.sh` copies the canonical engine/tests
to a Linux filesystem, confirms the engine matches the production binary and
runs all top-level shell regression drivers. `fake-*.sh` are helpers executed
by their owning tests, not standalone drivers. The unreadable-file regression
runs as `nobody`, rather than silently skipping under root. On Docker Desktop,
a test-only Docker CLI adapter maps that runner's `/tmp` named volume to the
same host volume for sibling-container bind mounts.

The first suite attempt passed every driver except `unreadable-file.sh`,
which inherited the production root-only `TMPDIR`. The runner now explicitly
uses its disposable `/tmp` volume. A repeat also exposed the existing
two-second Docker CLI startup bound as too short on Docker Desktop. The
fixture now allows five seconds while still checking the 600-second process
is killed inside the container and completes within 60 seconds. Its EXIT
trap is restored after sourcing the engine so cleanup actually runs. These
changes affect the test fixture, not the production timeout policy. The
final full repeat completed successfully: **29/29 drivers passed**, no
driver-level skips, exit code **0**. Syntax and ShellCheck gates also passed.
The full shell suite runs on amd64. ARM64 has a separate production-image
build and `tests/docker-image.sh` run under QEMU, not a claimed full ARM64
shell-suite run. Both architectures pass the real crypto and metadata
backup/full-verify/restore test. After replacing early-closing `head` version
output pipelines with fully consuming `sed`, both image tests were repeated
successfully; the first ARM64 diagnostic attempt had exited 141 from SIGPIPE.
Both image drivers were then run successfully as `nobody`, with intentional
Docker socket access, to check the non-root GitHub CI caller scenario. Bind
mountpoints are created by the caller before Docker starts, so cleanup does
not depend on deleting a daemon-owned restore directory. The image itself
retains root-capable recovery and still restores numeric owners correctly.

| Regression drivers | Result |
| --- | --- |
| `archive-resilience.sh`, `bash43-runtime.sh`, `config-cache.sh` | PASS |
| `compose-exec-timeout-real.sh`, `compose-real-integration.sh`, `compose-smoke.sh` | PASS |
| `crypto-smoke.sh`, `gpg-asymmetric.sh`, `docker-image.sh` | PASS |
| `delete-period.sh`, `diff.sh`, `pinned.sh`, `rclone-smoke.sh` | PASS |
| `fidelity.sh`, `file-hashes.sh`, `symlinks.sh`, `unreadable-file.sh` (nobody) | PASS |
| `hooks.sh`, `host-scope.sh`, `local-durability.sh`, `workspace-failure.sh` | PASS |
| `metrics.sh`, `notify.sh`, `preflight-failure.sh`, `watchdog.sh` | PASS |
| `pick.sh`, `quick.sh`, `restore-compose.sh`, `smoke.sh` | PASS |

Real Compose tests created isolated PostgreSQL/MySQL projects, captured their
data, restored to separate projects and checked the database contents. Cloud
upload behavior is covered by the existing rclone fixture tests; no real
cloud destination or SMTP recipient was contacted by the smoke test.

Separately verified: genuine Bash **4.3.48** syntax/runtime regression,
13 Helm contract/render checks, 16 Python launcher unit tests with 100%
branch coverage, and wheel/sdist build, Twine validation and isolated install
checks for local package version 1.4.0.

The owner explicitly approved ARM64 emulation on **2026-10-26**. The pinned
helper below registered only `arm64`/`qemu-aarch64` in Docker's Linux host;
the helper container was removed. Debian ARM64 then reported `aarch64` and
`dpkg --print-architecture` reported `arm64`. The ARM64 candidate built
successfully and passed its full production-image smoke, including the real
backup and metadata restore. Both Trivy metadata records identify the
intended architecture. Publication remains a separate approval gate.
Docker documents [manual binfmt registration](https://docs.docker.com/build/building/multi-platform/#install-qemu-manually)
as a fallback when bundled emulation fails. The reviewed helper index is
`tonistiigi/binfmt@sha256:400a4873b838d1b89194d982c45e5fb3cda4593fbfd7e08a02e76b03b21166f0`;
it was run with `--privileged --rm --install arm64` after that approval.

## Reproduce scans and runtime tests

On a Linux Docker host with native ARM64 or already configured ARM64
emulation, run from the repository root. These commands build locally and do
not publish anything. Keep the first downloaded Trivy database
unchanged for the baseline/candidate comparison:

```bash
mkdir -p .tmp/security-1.4.0
reports="$(pwd)/.tmp/security-1.4.0"
scanner='aquasec/trivy:0.75.0@sha256:af6acf9a6b85dfe389a1941505c0ce9efef52a4719635e1a962f022a3d855daa'
baseline='shellharbor/backfort:1.2.0@sha256:9c3a0e03fda11fc449e44417adfdd8b144b228426b666982bb4411b69ea6b84e'
docker pull --platform linux/amd64 "$baseline"
docker build --platform linux/amd64 --tag backfort:1.4.0-candidate-amd64 .
docker build --platform linux/arm64 --tag backfort:1.4.0-candidate-arm64 .
docker volume create backfort-trivy-140

scan() {
  report=$1 image=$2 platform=$3 image_source=$4
  shift 4
  docker run --rm \
    --mount type=bind,source=/var/run/docker.sock,target=/var/run/docker.sock,readonly \
    --mount type=volume,source=backfort-trivy-140,target=/cache \
    --mount "type=bind,source=$reports,target=/reports" \
    "$scanner" image --image-src "$image_source" --platform "$platform" \
    --cache-dir /cache --timeout 20m --scanners vuln,secret \
    --pkg-types os,library --list-all-pkgs --ignorefile /dev/null \
    --ignore-unfixed=false --severity CRITICAL,HIGH,MEDIUM,LOW,UNKNOWN \
    --format json --output "/reports/$report" "$@" "$image"
}
scan before-amd64.json "$baseline" linux/amd64 docker
scan after-amd64.json backfort:1.4.0-candidate-amd64 linux/amd64 docker --skip-db-update
scan before-arm64.json \
  shellharbor/backfort@sha256:16b66f1d9419593c323090328430fc84b208ac309fa654ea9a651be7479e2002 \
  linux/arm64 remote --skip-db-update
scan after-arm64.json backfort:1.4.0-candidate-arm64 linux/arm64 docker --skip-db-update

docker build --build-arg BACKFORT_IMAGE=backfort:1.4.0-candidate-amd64 \
  --file tests/container/Dockerfile --tag backfort:1.4.0-test-runner tests/container
docker volume create backfort-security-140-tests
docker run --rm \
  --mount type=bind,source=/var/run/docker.sock,target=/var/run/docker.sock \
  --mount type=volume,source=backfort-security-140-tests,target=/tmp \
  --mount "type=bind,source=$(pwd),target=/workspace,readonly" \
  --mount "type=bind,source=$reports,target=/reports" \
  --env BACKFORT_TEST_HOST_TMP=/var/lib/docker/volumes/backfort-security-140-tests/_data \
  backfort:1.4.0-test-runner \
  /workspace/tests/container/suite.sh backfort:1.4.0-candidate-amd64

# On a Linux host with the checkout's normal shell prerequisites:
DOCKER_DEFAULT_PLATFORM=linux/arm64 bash tests/docker-image.sh backfort:1.4.0-candidate-arm64
```

The full Docker regression requires an intentionally granted Docker socket;
use only a trusted, disposable test environment. The volume mountpoint in this
example is the standard rootful Docker path; verify it with
`docker volume inspect` on a different daemon. The test runner and socket are
not part of the production files-only deployment or its Kubernetes manifests.

Local evidence is retained outside Git in
`.tmp/security-1.4.0-20261026/`: full JSON reports, per-test logs and
`shell-suite.tsv`. Raw report SHA-256 values:

- Baseline `before-1.2.0-amd64.json`:
  `c270d879a89b8d0ef21d8554d303199a5374ffb8cc054f4d06d5cf83589551ba`.
- Candidate `after-1.4.0-amd64.json`:
  `fd821e62a03812ec09f828b29e56241f6b0046e33f73a290675bec757ba81273`.
- ARM64 baseline `before-1.2.0-arm64.json`:
  `75787d4aab52bcb5c5edab6d80e3d8ab8c533ecedb80d3afbac80b7a5eaa3f66`.
- ARM64 candidate `after-1.4.0-arm64.json`:
  `3c92f946d8dcf396e7b1e7d59a9b603462921fcd5529086d647a07b75cdc38bf`.
- Completed 29/29 `shell-suite.tsv`:
  `e41b550a7f28961059d04b052fed73cda2561c0dae0c820b6fa69fb10c8846da`.
- Final amd64 image smoke `docker-image-amd64.log`:
  `d866d1a9ac3ef6f7769801bae2441614f1eae3d82ab10d863e0ee78d586873c8`.
- Final arm64 image smoke `docker-image-arm64.log`:
  `e42d672aa8006cf0b83d2fea5a5eff51bd13237e4a6f775fbfbfe8b0e8fb6b05`.
- Non-root amd64 image driver `docker-image-nonroot-amd64.log`:
  `11336122be4b8c5ea70f5bb9bb9e98a08a618a6c114fd829332265db3ad7adad`.
- Non-root arm64 image driver `docker-image-nonroot-arm64.log`:
  `27409793a6ebee28ece3e467e4a902739ea2135a032dddde9571e6d11f916d1d`.

## Release and downstream boundary

The owner-authorized v1.4.0 tag and both image registries are published and
verified as recorded above. The new GnuPG HIGH finding was disclosed before
approval and remains in every scan without an exception. This task does not
publish PyPI 1.4.0; Python publishing remains a separate maintainer operation.

Filaver Data's tag/digest update, rebuild removal, bookworm pins and policy
exceptions are explicitly a separate task.

See [ADR-0003](../adr/0003-trixie-mawk-runtime.md) for the implementation
decision and rejected alternatives.
