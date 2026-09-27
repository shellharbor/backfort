# Backfort examples

Each top-level YAML file is valid Backfort 0.5 configuration after you replace
the example paths, host ID and rclone remote name. Run `doctor` before using a
configuration for the first time:

```bash
backfort.sh -c /etc/backfort/config.yaml doctor
backfort.sh -c /etc/backfort/config.yaml --dry-run run
```

| File | Use case |
| --- | --- |
| [files-local.yaml](files-local.yaml) | One server, one local recovery copy |
| [files-local-and-rclone.yaml](files-local-and-rclone.yaml) | Local recovery copy plus required offsite rclone copy |
| [files-age-rclone.yaml](files-age-rclone.yaml) | Encrypted offsite copy with age |
| [files-gpg-asymmetric.yaml](files-gpg-asymmetric.yaml) | GPG public-key backup with independent recovery recipients |
| [files-with-hooks.yaml](files-with-hooks.yaml) | Application maintenance-mode hook before and after an offsite backup |
| [files-prometheus.yaml](files-prometheus.yaml) | Local backup with node_exporter Prometheus textfile metrics |
| [docker-compose-postgres.yaml](docker-compose-postgres.yaml) | Compose project with PostgreSQL, a selected named volume, bind mount and rclone copy |
| [compose-migration.yaml](compose-migration.yaml) | Repeatable staged migration of a Compose project to a new server |

Never put passwords, tokens or private keys into these YAML files. Backfort
references only the names of environment variables. Configure rclone itself
with `rclone config` or rclone's environment-based configuration.

The hook example intentionally names a root-owned executable file and passes
only literal arguments. Create and test that script before enabling the job;
see [Lifecycle hooks](../README.md#lifecycle-hooks-safely-quiesce-an-application)
for the ownership, scrubbed environment, cleanup, and failure contract.

For S3-compatible storage—the AWS S3, DigitalOcean Spaces, Vultr Object
Storage, and Cloudflare R2 remotes commonly used with Backfort—the first
component of an rclone destination path is normally the bucket name. For
Dropbox, Yandex Disk and pCloud it is simply a folder path.

For a one-time move, see the source-side `quick-compose` command and target
recovery sequence in [Compose Migration](../wiki/Compose-Migration.md). The
`compose-migration.yaml` example is for a rehearsed or repeatable migration:
it requires both a local staging copy and an rclone transfer copy to complete.
After staging a Compose backup, use `restore-compose` to print its recovery
inventory. It can import supported logical database dumps only into a reviewed,
already-running target Compose project with the explicit `--apply --confirm`
boundary; see [Restore and Verification](../wiki/Restore-and-Verification.md).
