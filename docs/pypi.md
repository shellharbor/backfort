# Backfort for Python

Recovery-first Linux backups for files, Docker Compose applications and databases.
This distribution bundles Backfort's canonical Bash engine and example YAML;
it is a Python launcher, **not a Python rewrite** or a new backup format.

## Requirements

- Python 3.11+ and Linux. Use WSL or the existing Docker image on Windows.
- Bash 4.3+, GNU tar, coreutils, findutils, util-linux and gzip.
- Mike Farah `yq` v4. The Python package named `yq` is not compatible.
- Feature-specific tools such as rclone, age, GPG, Minisign or Docker Compose
  when the job enables them. Python installation does not install system tools.

## Install and run

Install Backfort with pipx, keeping the launcher isolated:

```bash
pipx install backfort
backfort --version
```

Or install inside a virtual environment:

```bash
python3 -m venv .venv
.venv/bin/python -m pip install backfort
.venv/bin/backfort --version
.venv/bin/python -m backfort --help
```

From a trusted source checkout, replace the install target with `.`.
Do not install into a system-managed Python. For privileged backups, use a
protected installation, never a user-writable environment executed as root.
No package is downloaded, published or installed system-wide by the Backfort
launcher itself.

The installed `backfort` command and `python -m backfort` accept the same
arguments as `backfort.sh`. From a checkout, `python3 run_backfort.py` works
without installing the package, including from another working directory.
The launcher replaces itself with Bash, preserving arguments, environment,
terminal I/O, signals and the engine's exit status. It does not invoke a shell
command string, download a script, install dependencies or elevate privileges.

## First configuration

Print the bundled reference config to stdout. Choose a new filename: shell
redirection overwrites an existing file.

```bash
.venv/bin/backfort --print-example-config > backfort.example.yaml
```

Edit its host ID, source paths, destination paths, encryption and retention
before use. Paths are absolute, and backup/state/work directories must stay
outside the source tree. Then validate the plan:

```bash
.venv/bin/backfort -c "$PWD/backfort.example.yaml" doctor
.venv/bin/backfort -c "$PWD/backfort.example.yaml" --dry-run run
.venv/bin/backfort -c "$PWD/backfort.example.yaml" run
.venv/bin/backfort -c "$PWD/backfort.example.yaml" list
```

The sole launcher-specific flag is `--print-example-config`, used alone. All
other argument parsing and validation belong to the existing Bash CLI.

## Quick backup

```bash
.venv/bin/backfort quick /srv/application \
  --name before-upgrade \
  --to /srv/backups/backfort \
  --state-directory /var/lib/backfort \
  --exclude '*.log'
```

The execution account needs access to those paths. Quick mode saves a
non-secret recovery config in the chosen state directory. Use a saved YAML
job for encryption, signing, lifecycle hooks and Prometheus textfile metrics.

## Verify and recover

```bash
.venv/bin/backfort -c /etc/backfort/config.yaml \
  verify latest --job application --full
.venv/bin/backfort -c /etc/backfort/config.yaml \
  restore latest --job application --to /srv/empty-recovery
```

Adapt the job name. Recovery requires a new or empty target and the necessary
keys. Preserve the original `host_id` for automatic `latest` discovery, or
deliberately select a full backup ID. Full ownership/ACL/xattr recovery needs
the same privileges and filesystem support as the native Bash installation.

Exit codes remain `0` success, `1` partial copies, `2` invalid input or
prerequisites, and `3` an operational/copy-policy failure. Launcher errors also
return `2`. Pruning is a separate command; backup creation does not prune.

## Learn more

- [Repository and full documentation](https://github.com/shellharbor/backfort)
- [Python installation and publishing](https://github.com/shellharbor/backfort/blob/main/wiki/Python-and-PyPI.md)
- [Examples](https://github.com/shellharbor/backfort/tree/main/examples)
- [Security policy](https://github.com/shellharbor/backfort/blob/main/SECURITY.md)
- [MIT License](https://github.com/shellharbor/backfort/blob/main/LICENSE)
