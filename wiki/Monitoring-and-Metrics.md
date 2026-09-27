# Monitoring and Metrics

Backfort offers two complementary monitoring paths without starting a resident
daemon: `watchdog` checks the freshness of completed backups, while the optional
Prometheus textfile collector records the outcome of each real `run` job.

## Enable Prometheus textfile output

Install and configure node_exporter with its textfile collector, then create a
directory that the Backfort execution account can write and node_exporter can
read. The exact owner/group depends on the service accounts used on the host;
do not make a protected backup or state directory world-writable just to make
metrics work.

```yaml
metrics:
  prometheus:
    textfile_directory: /var/lib/node_exporter/textfile_collector
```

Run the normal readiness check before scheduling the job:

```bash
sudo /opt/backfort/backfort.sh -c /etc/backfort/config.yaml doctor
sudo /opt/backfort/backfort.sh -c /etc/backfort/config.yaml --dry-run run
sudo /opt/backfort/backfort.sh -c /etc/backfort/config.yaml run
```

The directory must already exist, be writable, and not be a symlink. `doctor`
rejects a bad configuration before the scheduled backup window. Backfort never
creates it automatically.

## File lifecycle and safety

After each non-dry-run `run`, Backfort writes and atomically renames one file
per saved job:

```text
/var/lib/node_exporter/textfile_collector/backfort_application.prom
```

The filename uses the validated job name, so separate `run --job` calls do not
erase metrics for other jobs. Node_exporter sees either the previous complete
file or the replacement—not a partially written file.

Metrics are intentionally not written by `--dry-run run`, `quick`,
`quick-compose`, restore, prune, deletion, verification, or `watchdog`. They
describe an attempted persistent backup job only. A metrics write failure after
the backup begins emits a structured `kind=metrics` warning and does not alter
the backup's exit code; a recoverable backup must not become a failure because
observability had an outage.

The files are mode `0644` so node_exporter can read them. They contain only the
validated `host` and `job` labels plus numeric values. They never include
backup IDs, source paths, destination paths, error messages, tokens, passwords,
or key material.

## Metric contract

Every metric below is a gauge labelled `host` and `job`.

| Metric | Meaning |
| --- | --- |
| `backfort_last_run_success` | `1` when the latest job run fully succeeded; `0` for partial or failed runs. |
| `backfort_last_run_exit_code` | Latest Backfort job result: `0` success, `1` partial, or `3` failure. |
| `backfort_last_run_timestamp_seconds` | UTC Unix timestamp recorded when the job run ended. |
| `backfort_last_run_duration_seconds` | Latest run duration in seconds. |
| `backfort_last_backup_size_bytes` | Payload size in bytes, or `0` when no payload was created. |
| `backfort_last_successful_copies` | Number of configured destinations that accepted the latest bundle. |
| `backfort_last_failed_copies` | Number of configured destinations that rejected the latest bundle. |

A partial run has `success = 0`, `exit_code = 1`, and nonzero successful and
failed copy counts. A policy failure has `exit_code = 3`; a complete copy may
still exist when a required `success.min_copies` threshold was not reached.

## PromQL examples

Alert whenever a latest run was not complete:

```promql
backfort_last_run_success == 0
```

Alert when a job has not completed in 26 hours. Adjust the threshold to the
job's actual schedule and expected execution time:

```promql
time() - backfort_last_run_timestamp_seconds > 26 * 60 * 60
```

Show jobs that published a usable copy but lost one or more destinations:

```promql
backfort_last_successful_copies > 0
and backfort_last_failed_copies > 0
```

Use `watchdog` as the independent recovery freshness check: it inspects the
latest completed bundle across destinations, whereas the metrics record only
the last attempted `run` observed on this host.
