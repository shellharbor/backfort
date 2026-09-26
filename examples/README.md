# Backfort examples

Each top-level YAML file is valid Backfort 0.3 configuration after you replace
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
| [docker-compose-postgres.yaml](docker-compose-postgres.yaml) | Compose project with PostgreSQL, a selected named volume, bind mount and rclone copy |

Never put passwords, tokens or private keys into these YAML files. Backfort
references only the names of environment variables. Configure rclone itself
with `rclone config` or rclone's environment-based configuration.

For S3-compatible storage—the AWS S3, DigitalOcean Spaces, Vultr Object
Storage, and Cloudflare R2 remotes commonly used with Backfort—the first
component of an rclone destination path is normally the bucket name. For
Dropbox, Yandex Disk and pCloud it is simply a folder path.
