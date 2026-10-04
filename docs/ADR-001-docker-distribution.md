# ADR-001: Ship Backfort as a one-shot Debian-based container image

- Status: accepted
- Date: 2026-09-29
- Owners: Backfort maintainers

## Context

Backfort is a Linux Bash CLI whose recovery guarantees depend on GNU tar
support for numeric ownership, ACLs, extended attributes and sparse files. It
is scheduled externally and exits after each command; it does not provide an
HTTP service or maintain a daemon state. Operators also need an image that can
run an explicit `docker_compose` job against a deliberately granted host
Docker socket without changing the YAML schema or recovery bundle format.

## Decision

Ship a multi-stage, Debian-based image as an additional distribution method.
It installs the GNU userland and Backfort's optional runtime clients, includes
the Docker CLI with Compose plugin, and invokes the same `backfort.sh` entry
point as a native installation. Its default command is `doctor`; there is no
Docker `HEALTHCHECK`, automatic restart policy, or in-container scheduler.

The image remains root-capable by default because full recovery can require
recreating owners and Linux metadata. A documented non-root override is only
for files-only paths whose mounts allow it. Containerized Compose jobs must
mount the target project at its identical absolute host path and explicitly
mount the Docker socket; the socket is treated as host-root-equivalent.

Release tags publish OCI-labelled `linux/amd64` and `linux/arm64` images to
GHCR after a real image smoke test. Exact tags are immutable; stable aliases
move only for stable semantic versions. Docker Hub is a conditional mirror,
not a dependency of GHCR publication.

## Consequences

### Positive

- Operators receive one portable, versioned runtime without rebuilding the
  required toolchain on every host.
- Native and container deployments preserve one YAML, verification and staged
  recovery contract.
- CI validates an actual image backup, full verification, restore and invalid
  configuration path before it is released for both supported architectures.

### Costs and risks

- The image is larger than an Alpine alternative because GNU fidelity and
  optional recovery tooling are intentional requirements.
- A Docker socket grants far more authority than a normal read-only source
  mount. It is restricted to reviewed Compose jobs and cannot be considered a
  general hardening control.
- Root is necessary for full fidelity but requires operators to protect the
  image's writable state, working and destination mounts.

### Operational impact

- Migration/rollout: copy the maintained Compose and YAML examples into a
  protected deployment directory, pin an exact image, run `doctor` and a
  dry-run, then schedule `docker compose run --rm backfort run` on the host.
- Observability: use the command exit code from `doctor`, structured logs,
  notifications, Prometheus textfile metrics and `watchdog`; there is no
  persistent container health endpoint.
- Rollback/recovery: restore the prior exact image reference without deleting
  state volumes, then run `doctor`. Existing completed bundles remain the
  established portable recovery format.

## Alternatives considered

### Alpine-based runtime

Rejected because BusyBox-oriented defaults do not provide the GNU tar behavior
that Backfort's fidelity contract relies on. Adding a parallel GNU stack would
make the image less clear without reducing the recovery risk.

### A permanent scheduled container with a health check

Rejected because it would introduce a second scheduler and ambiguous liveness
semantics for a CLI that is meant to start, complete a deliberate command, and
exit. Host cron or systemd remains the explicit scheduler boundary.

### Non-root image for every job

Rejected because it would silently prevent reliable preservation of ownership
and metadata in the full recovery path. Non-root is retained as a documented
files-only choice.

## Validation

`tests/docker-image.sh` performs a backup, full verification, staged restore
and invalid-config check against a real local image. CI repeats this after a
normal build; a release workflow builds and tests both supported
architectures before it pushes GHCR images with provenance and SBOM
attestations. Revisit the base image and optional tool set through the weekly
Dependabot Docker updates and when Backfort's recovery fidelity requirements
change.
