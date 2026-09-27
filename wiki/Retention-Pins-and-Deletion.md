# Retention, pins and deletion

Backfort treats each completed copy independently: a local backup and its S3
copy can have different availability, and retention is evaluated for each job
and destination. A backup is eligible only after its `.complete` marker exists.
When a destination is shared, retention and date-range deletion are also
scoped to the configured `host_id`; copies made by another host are skipped
before validation or removal.

## GFS retention, a recovery floor, and an expiry

```yaml
retention:
  keep_last: 3
  keep_daily: 7
  keep_weekly: 4
  keep_monthly: 6
  min_keep: 1
  max_age_days: 90
```

The retained set is the union of the newest `keep_last` versions, newest
version for the newest represented UTC days, ISO weeks and UTC months.
`min_keep` is an independent positive safety floor (default `1`): the newest N
ordinary, unpinned completed versions remain recoverable even if every newer
backup attempt has failed. It applies before both GFS pruning and age expiry.

The optional `max_age_days` expires an *unpinned* copy older than that many
full 24-hour periods even if a GFS slot would otherwise keep it, but it never
removes a `min_keep` copy. Both `keep_last` and `min_keep` must be at least
one.

Prune is deliberately a separate operation. Preview it before scheduling:

```bash
backfort.sh -c /etc/backfort/config.yaml prune --dry-run
backfort.sh -c /etc/backfort/config.yaml prune

# Limit the normal policy to one job during an investigation.
backfort.sh -c /etc/backfort/config.yaml prune --job crm-production --dry-run
```

This works for local and rclone destinations, including S3-compatible storage.
Backfort validates the current host's complete backup bundle before deleting
it; malformed completed bundles stop pruning instead of being guessed at.
Foreign-host objects are deliberately out of scope and cannot block this
host's retention run.

## Pin a recovery point

Pin immediately before a migration, an operating-system upgrade, or a
destructive manual operation:

```bash
# Protect all completed copies with this backup ID.
backfort.sh -c /etc/backfort/config.yaml pin server-01_crm_20260926T020000Z_a91f3c2d \
  --reason 'before PostgreSQL 17 upgrade'

# Protect only the off-site copy.
backfort.sh -c /etc/backfort/config.yaml pin server-01_crm_20260926T020000Z_a91f3c2d \
  --from r2-archive --reason 'release rollback point'

# Remove the protection when the agreed retention period has elapsed.
backfort.sh -c /etc/backfort/config.yaml unpin server-01_crm_20260926T020000Z_a91f3c2d
```

A pin is a marker beside the complete backup. It survives GFS rotation and
`max_age_days`; pins can therefore grow storage indefinitely. `list` shows
the pin and its reason, and `prune --dry-run` reports skipped copies.

## Delete a defined UTC period

`delete` is for a deliberate one-off purge outside the regular retention
policy. It requires one job, both date boundaries, and either dry-run mode or
an explicit `--confirm`. `--until` includes its whole UTC calendar day.

```bash
# See exactly which January versions would be removed from every destination.
backfort.sh -c /etc/backfort/config.yaml delete \
  --job important-files --since 2025-01-01 --until 2025-01-31 --dry-run

# Repeat the inspected command with explicit confirmation.
backfort.sh -c /etc/backfort/config.yaml delete \
  --job important-files --since 2025-01-01 --until 2025-01-31 --confirm

# Purge just one remote copy, leaving local and other cloud copies intact.
backfort.sh -c /etc/backfort/config.yaml delete \
  --job important-files --since 2025-01-01 --until 2025-01-31 \
  --from s3-offsite --confirm
```

Pinned copies are reported as retained and are never removed by `delete`.
Unpin first only after an intentional review. On local destinations and
remotes, Backfort removes the completion marker before the rest of the bundle,
so an interrupted deletion can never leave a partial backup looking
recoverable. An interrupted removal may leave harmless orphan objects that no
Backfort command treats as a completed copy.
