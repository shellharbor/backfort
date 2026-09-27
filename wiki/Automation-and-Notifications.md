# Automation and notifications

Backups need a scheduler outside the script. Backfort uses a non-blocking lock
for mutating commands, so overlapping scheduled runs exit safely rather than
creating concurrent backup pipelines.

## Cron example

This root crontab runs the backup every night, checks it every morning, and
applies retention after the backup window. Redirect logs to a protected,
rotated log destination appropriate for the host.

```cron
0 2 * * * root /opt/backfort/backfort.sh -c /etc/backfort/config.yaml run >>/var/log/backfort.log 2>&1
30 2 * * * root /opt/backfort/backfort.sh -c /etc/backfort/config.yaml verify latest --job important-files --quick >>/var/log/backfort.log 2>&1
0 3 * * * root /opt/backfort/backfort.sh -c /etc/backfort/config.yaml prune >>/var/log/backfort.log 2>&1
15 8 * * * root /opt/backfort/backfort.sh -c /etc/backfort/config.yaml watchdog >>/var/log/backfort.log 2>&1
```

Keep `prune` separate from `run`: the least-privilege account used for creation
need not automatically receive deletion rights for every cloud destination.

For Prometheus textfile metrics emitted by these runs, see [Monitoring and
Metrics](Monitoring-and-Metrics). The metric file is updated only after a real
job attempt; it does not replace the independent backup-freshness `watchdog`.

## Lifecycle-hook scheduling

`hooks.pre` and `hooks.post` belong to a saved job and run only with
`backfort.sh ... run`. They do not turn Backfort into a daemon and are not run
by `doctor`, verification, restore, retention, or the `quick` commands. Use a
hook for a bounded action such as putting an application into maintenance mode,
freezing a filesystem, or releasing it after the archive pipeline. See
[Configuration](Configuration#lifecycle-hooks) for the safe file, ownership,
environment, failure, and signal contract.

## systemd example

Create `/etc/systemd/system/backfort.service`:

```ini
[Unit]
Description=Backfort backup
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=root
EnvironmentFile=/etc/backfort/backfort.env
ExecStart=/opt/backfort/backfort.sh -c /etc/backfort/config.yaml run
```

Create `/etc/systemd/system/backfort.timer`:

```ini
[Unit]
Description=Nightly Backfort backup

[Timer]
OnCalendar=*-*-* 02:00:00
Persistent=true
RandomizedDelaySec=10m

[Install]
WantedBy=timers.target
```

Then enable it:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now backfort.timer
systemctl list-timers backfort.timer
```

Put secret values, not their names, in the root-readable environment file and
give it restrictive permissions:

```bash
sudo install -m 0600 -o root -g root /dev/null /etc/backfort/backfort.env
sudoedit /etc/backfort/backfort.env
```

For example, the file may define `BACKFORT_TG_TOKEN`, `BACKFORT_TG_CHAT`,
database password environment variables, and cloud credentials needed by its
dedicated rclone profile. Do not commit this file.

## Actionable notifications

Backfort can send events to Telegram, ntfy, webhooks, and a local
`msmtp`/`sendmail` SMTP-compatible sender. Values that are secret remain
environment-variable values; YAML records only their variable names.

```yaml
notifications:
  enabled: true
  defaults:
    events: [failure, partial, recovery, watchdog]
    antiflood_hours: 4
    digest: off
  channels:
    - name: ops-telegram
      type: telegram
      token_env: BACKFORT_TG_TOKEN
      chat_id_env: BACKFORT_TG_CHAT
      events: [failure, watchdog]
      templates:
        failure: "<b>Backup failed: {{job}}</b>\\n{{error}}\\n<code>{{restore_hint}}</code>"
    - name: monitoring-ntfy
      type: ntfy
      server: https://ntfy.example.net
      topic_env: BACKFORT_NTFY_TOPIC
      priority: urgent
    - name: incident-webhook
      type: webhook
      url_env: BACKFORT_WEBHOOK_URL
      headers_env: BACKFORT_WEBHOOK_HEADERS
      events: [success, failure, recovery]
```

The fixed events are `success`, `partial`, `failure`, `recovery`, `watchdog`,
`restore_success`, `restore_failure`, and `prune`. Delivery problems are
warnings: a notification outage does not replace the backup operation's result.
Run `backfort.sh doctor` to see channel readiness without exposing secret values.

Text templates can use `{{job}}`, `{{id}}`, `{{error}}`, `{{destinations}}`,
`{{failed_destinations}}`, `{{restore_hint}}`, `{{last_backup_age}}`,
`{{threshold}}`, and other documented event fields. Unknown placeholders reject
the configuration before an operation starts. Set `digest: daily` to collect
success and prune activity; the next Backfort event flushes the prior day's
digest without a resident daemon.
