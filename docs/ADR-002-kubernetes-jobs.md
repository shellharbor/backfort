# ADR-002: Run Backfort as scoped PVC-file Job/CronJob workloads

- Status: accepted
- Date: 2026-10-02
- Owners: Backfort maintainers

## Context and decision

The reusable Docker image and one-shot CLI can protect files from explicitly
mounted Kubernetes PVCs without inventing another backup format or scheduler.
Ship a Helm 3 chart for Kubernetes 1.31+ with suspended backup/prune CronJobs,
manual Jobs, ConfigMap configuration, existing Secret references and durable
state/backup PVCs. Source and recovery claims remain operator-owned.

Each Job has one Pod, no automatic retries, a deadline and termination grace.
Forbid limits overlap within each CronJob, but all commands share the existing
persistent Backfort lock because different CronJobs/manual Jobs can overlap.
The runtime CLI remains unchanged; its doctor, publication marker, host scope,
full verification and staged restore remain authoritative.

Sources are read-only and recovery is isolated. Claim-name checks reject
source/state/backup/recovery overlap and mounts use explicit storage paths.
The chart requests no Kubernetes API token/RBAC, host paths, Docker socket or
privileged access. Full metadata recovery uses root with a reduced capability
set; a narrower non-root profile requires suitable storage/ownership.

## Consequences and alternatives

- Live PVC reads are not application/database-consistent. Quiescing, logical
  exports and consistent clones require an explicit application procedure.
- RWO/RWOP scheduling, root-squash, locking and CSI filesystem semantics remain
  real platform constraints. The chart cannot make an incompatible driver safe.
- Disk-backed ephemeral workspace needs enough capacity; interruption can leave
  harmless incomplete destination objects, not falsely completed backups.
- Native Pod exec/database dumps, API resource discovery, CSI snapshot
  orchestration and whole-cluster recovery are excluded. A privileged DaemonSet
  or a Docker socket on nodes would broaden authority without meeting this
  scoped requirement and is not an acceptable substitute.
- A daemon/Deployment with probes would conflict with the finite CLI lifecycle.
  Job completion and exit codes are the health signal.

## Validation and rollout

Rendering tests cover defaults, both image-reference modes, storage/secret
options, manual recovery, non-root settings and negative safety gates. Real
kind integration checks backup/full verification/metadata restoration, readonly
sources, cross-Job lock refusal, invalid configuration, nonempty restore refusal,
prune and non-root operation. CI repeats the isolated test with the actual image.

Roll out suspended, validate and rehearse recovery, then enable schedules.
Keep the exact image/config/state and completed bundles for rollback; created
PVCs survive Helm uninstall. Deployment steps and remaining limits are maintained
in [Kubernetes Deployment](../wiki/Kubernetes-Deployment.md).
