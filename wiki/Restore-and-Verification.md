# Restore and verification

Recovery is a workflow, not just an extraction command. Inspect a backup,
verify its integrity, restore to a deliberate target, then test the recovered
application or data.

## Find a version

```bash
backfort.sh -c /etc/backfort/config.yaml list --job web
backfort.sh -c /etc/backfort/config.yaml status --job web
backfort.sh -c /etc/backfort/config.yaml restore --pick --job web --to /srv/recovery/web
```

`restore --pick` presents available versions and lets an operator choose one
interactively. Use it from a terminal; it intentionally refuses to guess when
standard input is not interactive.

These automatic listings and `latest` selectors are scoped to the configured
`settings.host_id`. That makes one shared bucket safe for multiple servers
using the same job name. To recover a reviewed copy from another host, pass
its full backup ID explicitly.

## Verify before an incident

Run a quick check after every important backup and schedule deeper checks for
critical jobs:

```bash
# Check the latest or selected version's manifest, completion marker and hashes.
backfort.sh -c /etc/backfort/config.yaml verify web-20260926T020000Z

# Request full verification when the job/configuration supports it.
backfort.sh -c /etc/backfort/config.yaml verify web-20260926T020000Z --full

# Verify a remote copy, rather than the local primary destination.
backfort.sh -c /etc/backfort/config.yaml verify web-20260926T020000Z --from r2-archive
```

Quick verification checks the published payload checksum and any configured
signature. Full verification also decrypts and reads the archive, confirms its
safe layout and matching internal manifest, then recomputes SHA-256 for every
regular `data/` file against the manifest. It is the check to run before a
recovery drill and is automatically part of a normal restore.

New backups record `file_hash_algorithm: sha256` and a `sha256` value for each
regular manifest entry. Directories, symlinks, and hard links have no
file-content hash. This catches a changed or truncated archived file even if a
damaged payload has been given a new outer checksum. It does not replace a
signature: an attacker who can replace both payload and manifest needs to be
stopped by Minisign or immutable storage. Older backups without this manifest
field remain recoverable with the archive-level checks available at the time.

Verification detects a missing completion marker, manifest mismatch, corrupt
archive, signature failure where configured, and unavailable storage. A version
without `.complete` is incomplete and must never be selected for recovery.

## Restore a normal file job

```bash
# Restore using the paths recorded by the backup job.
backfort.sh -c /etc/backfort/config.yaml restore web-20260926T020000Z --to /srv/recovery/web

# Restore an off-site copy.
backfort.sh -c /etc/backfort/config.yaml restore web-20260926T020000Z --from s3-primary --to /srv/recovery/web
```

Restore targets are intentionally controlled by the job configuration. Test on
a disposable host or an explicit recovery directory first. Never overwrite a
live deployment until the recovered files, ownership and application start-up
have been checked.

New file-source backups preserve symbolic-link target text rather than
prefixing it with the archive's internal `data/` path. Relative, absolute and
dangling links are preserved when `follow_symlinks: false`; explicit
dereferencing instead captures readable target data. Hard-link relationships
remain intact. Absolute links can still point outside the staging directory:
inspect their targets before following them on a recovery host. Bundles created
before this fix are not automatically rewritten—review their links and create
a fresh recovery point. `tests/symlinks.sh` covers both policies.

For PVC-file recovery Jobs, see [Kubernetes Deployment](Kubernetes-Deployment):
use the same host/config/lock, a separate recovery claim and a new or empty
target beneath `/restore`.

Backfort restores numeric owners, POSIX ACLs, extended attributes (including
Linux file capabilities), sparse extents, and timestamps. Use a privileged
recovery account when owner fidelity is required; an unprivileged account may
be unable to recreate another UID/GID. The destination must still be new or
empty—fidelity never authorizes an in-place overwrite.

The automated fidelity check runs this privileged recovery path from a
non-root CI worker and asserts the recovered owner, ACL, extended attribute
and sparse-file layout. This guards against a future change silently replacing
preserved ownership with the account that performs the restore.

## Restore a Compose project

First restore the Compose version. Its contents are organised in familiar
directories:

```text
compose/       project files selected by source.files
bind-mounts/   archived bind-mounted host paths
volumes/       named-volume archives
databases/     logical database dumps
```

To load a named-volume archive, stop the workload and use a temporary helper
container suitable for your platform. This illustrative command restores an
archive to `postgres_data`; adjust the archive path and inspect it first:

```bash
docker compose -f /recovery/crm/compose/compose.yaml down
docker volume create postgres_data
docker run --rm \
  -v postgres_data:/target \
  -v /recovery/crm/volumes/postgres_data:/backup:ro \
  alpine:3.20 sh -c 'cd /target && tar xf /backup/data.tar'
```

Use the recovery assistant for PostgreSQL, MySQL, and MariaDB after creating
the target project and starting only its database containers. It re-stages the
verified backup into the named, empty staging directory before the import:

```bash
backfort.sh -c /etc/backfort/config.yaml \
  restore-compose latest --job crm --to /recovery/crm-import \
  --project-dir /srv/crm-recovery --apply --confirm
```

It will not copy recovered Compose files, unpack a volume, or start Compose.
PostgreSQL global-role dumps remain manual because role changes have a broader
security impact. If you need a fully manual drill, the equivalent database
commands are:

```bash
# PostgreSQL custom format
docker compose exec -T db createdb -U postgres crm
docker compose exec -T db pg_restore -U postgres -d crm --clean --if-exists \
  < /recovery/crm/databases/crm-postgres/crm.dump

# PostgreSQL plain SQL
docker compose exec -T db psql -U postgres -d crm \
  < /recovery/crm/databases/crm-postgres/crm.sql

# MySQL or MariaDB
docker compose exec -T db mysql -u root -p crm \
  < /recovery/crm/databases/crm-mysql/crm.sql
```

For MS SQL Server and Oracle, import the retained database export using the
vendor-supported tool and a target instance with a compatible version. The
assistant deliberately refuses `--apply` for a job containing either engine,
so it cannot perform a partial multi-engine recovery. Review the dump type,
engine version and user privileges before running it.

## A recovery drill

### Asymmetric GPG recovery boundary

An asymmetric-GPG writer has only the recipient public key in its GnuPG
keyring. Keep the corresponding private key on a separate, access-controlled
recovery host. Before a full verification or restore, import that private key
there and use the same Backfort configuration that created the copy. If the
private key has a passphrase, provide the value through the configured
`identity_password_env` using your secret manager, or unlock it with the local
GnuPG agent first. Backfort passes that value to GnuPG through a pipe-backed
file descriptor rather than a command-line argument or Bash here-string
temporary file. Never move the private key or its passphrase to the backup
writer.

`doctor` on the writer verifies that every configured public recipient is an
exact fingerprint already present in its keyring. It does not fetch keys from
the network. See [Configuration](Configuration#compression-encryption-and-signing)
for the recipient configuration and public-key import procedure.

At least quarterly, choose a recent off-site backup and prove that it works:

1. Provision an isolated host or test environment.
2. Run `verify --full` against the remote copy.
3. Restore files and data without touching production.
4. Import a database dump and start the service.
5. Perform a real application-level check: login, representative report,
   object count, or another meaningful operation.
6. Record the backup ID, duration and gaps found.

The best backup is a backup with a successful recovery drill.
