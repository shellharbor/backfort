# Kubernetes deployment

Backfort can run as a Kubernetes **Job or CronJob** using the Helm chart in
`charts/backfort`. It backs up explicitly mounted PVC files to a separate
backup PVC or any configured rclone destination. It uses the existing CLI,
YAML and portable recovery bundles, not a second backup engine.

This deployment supports Kubernetes 1.31+ and Helm 3. It is not a cluster
backup/discovery product: it does not query the API, export Kubernetes
resources, create CSI snapshots, invoke commands in database Pods, or migrate
a cluster automatically. The `docker_compose` source requires a Docker host
and is rejected by this chart. See [Docker Deployment](Docker-Deployment) for
that separate environment.

## Before installing

- Install in the same namespace as all source, state, destination and recovery
  PVCs and referenced Secrets. The chart never creates the application's PVC.
- Choose a stable, unique `config.settings.host_id`. Keep the original ID and
  destination configuration during recovery; `latest` is host-scoped.
- Check the actual CSI driver's access modes, mount permissions and filesystem
  semantics. A local destination needs working `flock`, rename and `sync -f`,
  not an object-storage/FUSE imitation of a normal filesystem.
- For `ReadWriteOnce`, application and backup Pods must use the same node or
  the storage must permit their attachment arrangement. RWO means single-node,
  not single-Pod access. Use appropriate node/pod affinity when needed.
  `ReadWriteOncePod` permits only one Pod: stop the application or provide an
  independently prepared clone for backup. Do not expect a second live mount.
- Reading a live PVC is **not application-consistent**, particularly for a
  database. Use an application-controlled quiesce/export procedure or an
  independently prepared consistent clone. This chart does not implement
  database dump or snapshot orchestration. Merely suspending Backfort's
  CronJob does not pause the application.
- Provision enough disk-backed working space for the complete uncompressed
  and processed bundle. `emptyDir.sizeLimit` is a limit, not a capacity
  reservation. CPU, memory and ephemeral-storage requests/limits are explicit
  in values and must be adapted to your largest backup.
- Use a cluster-independent offsite copy. A backup PVC on the same cluster is
  convenient for recovery drills, not disaster protection on its own.

## Install, with schedules safely suspended

From the repository checkout, copy and edit the **Helm values**, not a native
Backfort configuration file:

```bash
cp examples/kubernetes/pvc-local.values.yaml values.yaml
# Edit host_id, sources[].claimName, sizes and storage classes in values.yaml.
helm lint charts/backfort --strict -f values.yaml
helm upgrade --install backfort ./charts/backfort \
  --namespace application -f values.yaml
kubectl -n application get cronjobs,pvc
```

The target namespace and application PVC must already exist. Set
`image.repository`, `image.tag` or preferably `image.digest` to an available,
trusted release image. An empty tag uses `Chart.appVersion`; a digest takes
precedence. Build/load a local image when testing unreleased changes. No chart
repository or OCI chart publication is assumed by these commands.

The default release creates `backfort-config`, a tokenless ServiceAccount,
`backfort-state`, `backfort-backups`, and two **suspended** CronJobs:
`backfort-backup` (`run`) and `backfort-prune` (`prune`). Existing storage can
be selected through `storage.state.existingClaim` and
`storage.backups.existingClaim`. The chart keeps created PVCs on Helm
uninstall; no source or recovery PVC is created or deleted by it.

| Mount | Contract |
| --- | --- |
| `/etc/backfort` | Read-only ConfigMap; `config` in Helm values is the ordinary Backfort YAML. |
| `/source` or `/source/NAME` | Explicit existing source PVC, read-only. |
| `/var/lib/backfort` | Persistent state PVC, shared by all commands; contains owned `state/` and the common lock. |
| `/backups` | Separate persistent backup PVC, writable; optional for rclone-only jobs. |
| `/var/tmp/backfort` | Disk-backed `emptyDir`; owned `work/` contains temporary bundles and is discarded with the Pod. |
| `/tmp` | Small disk-backed scratch `emptyDir`. |
| `/run/secrets/NAME` | Optional existing Secret, read-only. |
| `/restore` | Explicit recovery PVC, mounted **only** in a manual Job; never a configured source/state/backup PVC. |

State and lock paths are restricted to children of `/var/lib/backfort` and
working paths to children of `/var/tmp/backfort`. Unique mounts and separate
claim names are checked when Helm renders. The CLI still performs its strict
configuration validation at execution; successful `helm lint` is not a
replacement for `doctor`.

## Run doctor, dry-run and first backup

Render a manual Job with the same release name and values as the installed
release. Rendering **only** its template avoids updating CronJobs and PVCs:

```bash
helm template backfort ./charts/backfort -n application -f values.yaml \
  --show-only templates/manual-job.yaml \
  --set manual.enabled=true --set manual.name=doctor-01 \
  --set-json 'manual.args=["doctor"]' | kubectl -n application apply -f -
kubectl -n application wait --for=condition=complete job/backfort-doctor-01 --timeout=5m
kubectl -n application logs job/backfort-doctor-01

helm template backfort ./charts/backfort -n application -f values.yaml \
  --show-only templates/manual-job.yaml \
  --set manual.enabled=true --set manual.name=plan-01 \
  --set-json 'manual.args=["--dry-run","run"]' | kubectl -n application apply -f -
kubectl -n application logs -f job/backfort-plan-01

kubectl -n application create job backfort-backup-01 --from=cronjob/backfort-backup
kubectl -n application wait --for=condition=complete job/backfort-backup-01 --timeout=60m
kubectl -n application logs job/backfort-backup-01
```

Creating a Job from a suspended CronJob is a deliberate manual run; suspension
blocks automatic scheduling, not this action. Give every manual Job a new
name: Job Pod templates are immutable, so reapplying a completed Job does not
run it again. Check `Failed` conditions, Pod termination exit codes and events
when `wait` times out; a timed-out client wait does not stop the Job.

`manual.args` starts with a supported ordinary Backfort command, optionally
preceded by `--dry-run` or `-n`. The chart does not support overriding the
mounted configuration or invoking quick/Compose commands in this workload.

## Verify and restore to an isolated PVC

Create a **separate** recovery PVC with suitable capacity and access mode,
then render a full verification Job:

```bash
helm template backfort ./charts/backfort -n application -f values.yaml \
  --show-only templates/manual-job.yaml \
  --set manual.enabled=true --set manual.name=verify-01 \
  --set-json 'manual.args=["verify","latest","--job","application-files","--full"]' \
  | kubectl -n application apply -f -
kubectl -n application wait --for=condition=complete job/backfort-verify-01 --timeout=60m
kubectl -n application logs job/backfort-verify-01
```

`examples/kubernetes/restore.values.yaml` supplies a manual restore Job using
the existing `backfort-recovery` claim. Adapt that claim before using it:

```bash
helm template backfort ./charts/backfort -n application -f values.yaml \
  -f examples/kubernetes/restore.values.yaml \
  --show-only templates/manual-job.yaml | kubectl -n application apply -f -
kubectl -n application wait --for=condition=complete job/backfort-restore-drill-01 --timeout=60m
kubectl -n application logs job/backfort-restore-drill-01
```

The new or empty target `/restore/result` avoids filesystem-root entries such
as `lost+found`. `/source/path` is recovered as `/restore/result/source/path`.
Inspect it from a separate recovery Pod or approved tool after the Job exits.
Reusing a nonempty target is rejected; do not wipe it to rerun a drill—choose
another empty target. Restoring never applies files back to production or
starts application/database Pods. Backfort validates the bundle and per-file
hashes before extraction. Normal restore still needs whatever keys/signature
policy the original backup used.

The chart requires a recovery claim and exactly one safe `--to /restore` or
child path for a manual `restore`; it rejects targets on state/backup mounts
and a recovery claim equal to any configured source, state or enabled backup
claim. Different PVC names can still alias underlying storage
in a misconfigured cluster; the operator must ensure actual isolation.

## Enable the external scheduler

After the manual backup and recovery drill pass, update your reviewed values
and release:

```bash
helm upgrade backfort ./charts/backfort -n application -f values.yaml \
  --set backup.suspend=false --set prune.suspend=false
```

Defaults are 02:15 and 03:45 UTC; customize `backup.schedule`, `prune.schedule`
and their `timeZone` values. Keep those changes in your durable values file
so a later upgrade does not accidentally resuspend/reconfigure them.

Both CronJobs use `concurrencyPolicy: Forbid`. Every Job has one Pod,
`restartPolicy: Never`, `backoffLimit: 0`, a finite execution deadline, a
termination grace period and a finished-Job TTL. These intentionally avoid
automatic reruns of partial work. CronJob scheduling is not exactly-once and
Forbid coordinates **only one CronJob**, not backup versus prune or manual
Jobs. Every mutating/full-recovery command must share the same persistent
Backfort state and lock. An overlapping command fails with code 3 rather than
waiting; schedule prune after the normal backup window and monitor failures.
Do not scale independent releases against one destination without deliberately
sharing the state/lock and defining unique host IDs where appropriate.

SIGTERM cleanup is best-effort and Bash can defer it while a foreground tool
is running. SIGKILL, eviction or a node failure can leave orphan destination
objects, but an interrupted bundle without `.complete` is not recoverable.
Tune `job.activeDeadlineSeconds` and `terminationGracePeriodSeconds` for large
archives/uploads and application cleanup; never promise guaranteed unfreeze
after a hard failure. Logs go to stdout/stderr, with Job completion and the
existing Backfort exit codes as the one-shot health signal.

## Offsite copies and existing Secrets

The rclone example disables the local backup PVC and selects the same normal
remote configuration used outside Kubernetes:

```bash
# Supply an already-protected rclone config; do not paste credentials in values.
kubectl -n application create secret generic backfort-rclone \
  --from-file=rclone.conf=/secure/path/rclone.conf
helm upgrade --install backfort ./charts/backfort -n application \
  -f values.yaml -f examples/kubernetes/rclone.values.yaml
```

Edit the remote name, bucket/path and host ID in that override. Helm replaces
lists, so `config.jobs`, `config.destinations`, `sources` and `secretMounts`
overrides must supply their full intended lists. The mounted rclone config is
read-only; configure and refresh provider tokens outside Backfort when needed.
Protect API access to Secrets—base64 representation is not encryption.

`envFromSecret` selects an existing Secret whose keys become environment
variables. Encryption and notification configuration still references only
their variable names. `secretMounts` is for file credentials; `env` is for
non-secret values such as `RCLONE_CONFIG`. Neither the chart nor Helm creates
credential values. Keep backup-writer public keys separate from recovery-only
private keys, as in [Configuration](Configuration).

## Root and the narrower non-root profile

The default root-capable profile preserves other owners, ACLs and xattrs on a
compatible filesystem. It drops all capabilities and adds only `CHOWN`,
`DAC_OVERRIDE`, `FOWNER`, `FSETID`, `SETFCAP`; it uses a read-only image filesystem,
RuntimeDefault seccomp and no privilege escalation. There is no Docker socket,
hostPath, privileged container, host network, API token or RBAC grant.
Root remains authority over the writable mounted PVCs; protect them carefully.
The chart does not grant admission-policy exemptions for root workloads.

For files wholly owned/readable by a dedicated account, layer
`examples/kubernetes/nonroot.values.yaml` with UID/GID 1000 and no capabilities.
The CSI driver must permit that UID to create owned state/work/restore child
directories. `fsGroup` may change mounted volume group ownership/permissions;
review its effect on the application PVC before enabling it. The default root
profile deliberately sets no `fsGroup`, so it does not request that change.
`FSETID` preserves SGID mode bits for other groups during recovery rather than
letting Linux silently clear them. NFS root-squash or broken cross-client locking may require a different storage
arrangement, not extra privileges. Non-root recovery of another UID's metadata
is not promised. Test the full drill with the actual source and CSI driver.

## Upgrades, uninstall and maintainer checks

Pin an available image version/digest, retain your values and all persistent
state/backup claims, suspend schedules during incompatible changes, then run
`doctor`, full verification and a drill. Helm uninstall leaves chart-created
PVCs through the keep policy; to reuse them, explicitly configure
`storage.*.existingClaim`. Never delete the state or backup PVC as routine
cleanup. Job TTL/history remove Kubernetes objects, **not** Backfort bundles;
only the explicit `prune` policy ages those out.

The Kubernetes workflow runs `helm lint`, `tests/kubernetes_chart.py`, then
`tests/kubernetes_integration.py` against the real image in a disposable kind
1.34.0 cluster. The latter uses a private kubeconfig and explicit context,
checks metadata recovery, readonly sources, shared lock refusal, invalid
configuration, nonempty-target refusal, prune and non-root round trips, and
deletes only its randomly named test cluster. It does not validate every CSI
driver, admission policy, architecture or real cloud provider credential.
See [Troubleshooting](Troubleshooting) and
[ADR-002](../docs/ADR-002-kubernetes-jobs.md).

Platform semantics: [CronJobs](https://kubernetes.io/docs/concepts/workloads/controllers/cron-jobs/),
[PVC access modes](https://kubernetes.io/docs/concepts/storage/persistent-volumes/),
[security contexts](https://kubernetes.io/docs/tasks/configure-pod-container/security-context/),
[Linux SGID preservation](https://man7.org/linux/man-pages/man2/chmod.2.html).
