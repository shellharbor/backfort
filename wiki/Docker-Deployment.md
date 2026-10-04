# Docker deployment

Backfort's container image is a production distribution of the same one-shot
CLI; it is not a separate service or a different backup format. A backup made
in the image has the same YAML schema, atomic `.complete` publication,
verification, retention and staged recovery behavior as one made by the native
`backfort.sh` installation.

The canonical image is `ghcr.io/shellharbor/backfort`. Stable releases publish
multi-architecture manifests for `linux/amd64` and `linux/arm64`:

```bash
docker pull ghcr.io/shellharbor/backfort:1.1.0
docker run --rm ghcr.io/shellharbor/backfort:1.1.0 --version
```

Use an exact version (or an image digest) in an operational Compose file.
Release builds also move `X.Y`, `X` and `latest` for stable releases only;
those aliases are convenient for evaluation, not a reproducible deployment.
The optional `shellharbor/backfort` Docker Hub mirror is published only when
the maintainers configure its release credentials. GHCR remains canonical.

## What the image contains

The production image is Debian-based rather than Alpine so Backfort keeps its
GNU tar behavior for POSIX ACLs, extended attributes, sparse files and numeric
owners. It includes Bash, GNU core utilities, Mike Farah `yq` v4, gzip, zstd,
age, GnuPG, Minisign, rclone, curl, msmtp, and the Docker CLI with the Compose
plugin. Optional tools do not enable a feature by themselves: the normal YAML
validation and environment checks still apply.

The image runs as root by default, deliberately. A full recovery can need to
create files owned by application UIDs and restore ACLs or extended attributes.
For a files-only plan, `user: "UID:GID"` is appropriate when the host mounts
are already owned by that account. That choice prevents owner-preserving
restore; it is a trade-off, not a general hardening upgrade.

The image has no daemon, listener, or long-running scheduler. Its default
command is `backfort -c /etc/backfort/config.yaml doctor`, so an omitted or
invalid config fails visibly. It intentionally has no Docker `HEALTHCHECK`:
an exited backup job has no meaningful ongoing health state. Use the exit code
of `doctor` as readiness and schedule `run` from the host.

## Minimal durable file-backup deployment

Create a protected deployment directory and copy the maintained examples:

```bash
sudo install -d -m 0700 /srv/backfort-container
sudo cp docker-compose.example.yml /srv/backfort-container/docker-compose.yml
sudo cp examples/docker-files-local.yaml /srv/backfort-container/config.yaml
sudoedit /srv/backfort-container/config.yaml
```

Edit `config.yaml` to choose a stable `host_id`, required paths, exclusions,
retention, encryption and destinations. The supplied configuration deliberately
uses **container paths**:

```yaml
settings:
  host_id: docker-host-01
  state_directory: /var/lib/backfort
  temp_directory: /var/tmp/backfort
  lock_file: /var/lib/backfort/backfort.lock
destinations:
  - name: local
    type: local
    path: /backups
jobs:
  - name: container-files
    source:
      type: files
      paths: [/source]
      exclude: ["*.log", "*/cache/*"]
      follow_symlinks: false
```

Set the two required variables to absolute **host** paths, then run the normal
preflight sequence:

```bash
export BACKFORT_SOURCE_DIR=/srv/application
export BACKFORT_BACKUP_DIR=/srv/backups/backfort
cd /srv/backfort-container
docker compose run --rm backfort doctor
docker compose run --rm backfort --dry-run run
docker compose run --rm backfort run
docker compose run --rm backfort verify latest --job container-files --full
```

The final command is a real full verification; add a staged restore drill to
your normal recovery policy just as you would for a native installation.

## Mount contract

Every path in the YAML is evaluated in the container. Do not expect a host
path to be visible merely because the host can see it.

| Purpose | Container path | Mount and permission | Why it persists or is restricted |
| --- | --- | --- | --- |
| Configuration | `/etc/backfort/config.yaml` | Bind mount, read-only | The policy remains host-controlled and cannot be edited by the job. |
| Source files | `/source` | Bind mount, normally read-only | Backfort needs to read data but never needs to alter the production source. |
| Local destination | `/backups` | Bind mount, read-write | Completed bundles must survive the container. Mount a host filesystem with recovery capacity. |
| Backfort state | `/var/lib/backfort` | Named volume or protected bind mount, read-write | Keeps notification state and a shared lock across separate `docker compose run` invocations. |
| Working space | `/var/tmp/backfort` | Named volume or protected bind mount, read-write | Holds an archive workspace; provision space for the largest expected working bundle. |
| General scratch space | `/tmp` | Small `tmpfs` | The Compose example makes the otherwise read-only root filesystem usable for short-lived scratch data. |

`docker-compose.example.yml` applies a read-only root filesystem and
`no-new-privileges`. These reduce accidental writes in the container; they do
not make a Docker socket safe, and they do not replace host filesystem
permissions. Keep configuration, rclone credentials, private keys and backup
destinations protected on the host.

## Secrets, rclone and encryption

Never build secrets into an image or place their values in YAML. Backfort's
configuration names environment variables, so provide their values only to the
specific run from an approved secret source. For example, a protected
environment file may be used by a host scheduler, but it must be readable only
by the backup account and must not be committed:

```yaml
services:
  backfort:
    env_file:
      - ./secrets.env
    volumes:
      - ./rclone.conf:/run/secrets/rclone.conf:ro
    environment:
      RCLONE_CONFIG: /run/secrets/rclone.conf
```

For age or GPG recovery, keep private recovery material outside the backup
writer according to the [configuration](Configuration) and
[restore](Restore-and-Verification) contracts. A GPG keyring must live on a
deliberate protected writable mount when it is needed inside the container;
the example state volume supplies the image's default `GNUPGHOME`, but do not
assume it contains a recovery private key.

## Docker Compose source jobs

The image contains the Docker client only for a YAML job that explicitly uses
`source.type: docker_compose`. Such a job needs the Docker socket and a mount
of the target project at the **same absolute host path**:

```yaml
services:
  backfort:
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - /srv/crm:/srv/crm:ro
    # If the socket is not world-readable, add its host numeric group:
    # group_add: ["998"]
```

With `project_dir: /srv/crm` in Backfort YAML, that mapping lets both the
containerized client and host Docker daemon resolve the project accurately.
Mapping the project to a different path (for example `/srv/crm:/project`) is
not supported for this nested-Docker case: Compose can hand the host a path it
cannot resolve when inspecting bind mounts.

The Docker socket is host-root-equivalent. A container with access can ask the
daemon to start privileged containers or mount host filesystems; `:ro` does
not remove that authority. Use the socket only for a trusted Backfort container
and an explicitly reviewed Compose job. Files-only jobs should not receive it.
Read [Docker Compose and Databases](Docker-Compose-and-Databases) before
backing up volumes or database containers.

## Schedule, monitor and recover

The supplied Compose service has `restart: "no"`. Schedule each one-shot run
from a host timer or cron entry, then arrange a separate prune window:

```cron
CRON_TZ=UTC
15 2 * * * cd /srv/backfort-container && BACKFORT_SOURCE_DIR=/srv/application BACKFORT_BACKUP_DIR=/srv/backups/backfort docker compose run --rm backfort run
45 3 * * * cd /srv/backfort-container && BACKFORT_SOURCE_DIR=/srv/application BACKFORT_BACKUP_DIR=/srv/backups/backfort docker compose run --rm backfort prune
```

Have your scheduler preserve the process exit status. Use `docker compose run
--rm backfort doctor` after configuration or credential changes, `watchdog` for
freshness, and the usual notification or Prometheus configuration when needed.
The image itself does not run a scheduler or an HTTP status page.

To restore, mount the desired destination and an explicit, empty recovery
directory, then use the same staged command:

```bash
docker compose run --rm \
  -v /srv/backfort-recovery:/restore \
  backfort restore latest --job container-files --to /restore
```

Do not add a production source mount to a recovery invocation unless it is
actually needed for the selected job. Inspect `/srv/backfort-recovery` first;
Backfort never performs in-place replacement. For Compose recovery, stage with
`restore-compose` and follow the separate import/volume procedure from
[Restore and Verification](Restore-and-Verification).

## Kubernetes-ready design policy

Dockerfiles, Compose definitions and any future microservices must be designed
for Kubernetes portability. Runtime configuration and secrets are supplied
externally, durable data has explicit persistent storage, logs go to
stdout/stderr, and process termination, resources and dependencies have a
documented deployment contract. Long-running services need meaningful probes;
finite Backfort commands use validation and completion status.

Backfort's Kubernetes workload is a Job or CronJob, with explicit
commands, persistent state and backup storage, and controlled overlap/retries.
CronJob concurrency settings alone cannot coordinate different CronJobs or
manual Jobs; the existing single-writer lock and its filesystem requirements
still matter. Ownership/ACL/xattr recovery retains its root and filesystem
requirements.

The repository supplies a Helm chart for mounted PVC-file backups and isolated
restore Jobs. See [Kubernetes Deployment](Kubernetes-Deployment) for its tested
scope, explicit storage/Secret mapping and suspended-first rollout. The existing
`docker_compose` adapter still needs a host Docker daemon, socket and matching
host project paths; it is not a native Kubernetes database/cluster adapter and
is rejected by that chart.

## Upgrade and rollback

1. Pin the current image tag or digest in `docker-compose.yml` and keep a copy
   of the current image reference.
2. Run `doctor`, a dry-run, and ideally `verify latest --full` with the new
   exact release tag before changing a scheduled job.
3. Do not use `docker compose down -v`: the named `backfort-state` and
   `backfort-work` volumes hold state and in-progress workspace data.
4. Roll back by restoring the prior image reference and rerunning `doctor`.
   The YAML and finished recovery bundles are backward-compatible operational
   data; an image rollback does not rewrite them.

Release builds attach OCI metadata, a provenance attestation and an SBOM. They
also build and run the real image on both supported architectures before an
image is published. See [Troubleshooting](Troubleshooting) for common container
mount and Compose-socket errors. Maintainers can find the durable rationale in
[ADR-001](../docs/ADR-001-docker-distribution.md).
