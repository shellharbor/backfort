# Backfort Helm chart

Run the existing Backfort image as explicit PVC-file backup and prune
CronJobs, or a manual doctor/verify/restore Job. Requires Helm 3 and Kubernetes
1.31+. Both schedules start **suspended**. No Kubernetes API access, Docker
socket, live-volume consistency guarantee or native database-Pod adapter is
provided.

The complete installation, storage, secret, scheduling and recovery runbook
is [Kubernetes Deployment](../../wiki/Kubernetes-Deployment.md).
Adapt [values.yaml](values.yaml) and the
[examples](../../examples/kubernetes/README.md), then run:

```bash
helm lint charts/backfort --strict -f values.yaml
helm upgrade --install backfort ./charts/backfort -n application -f values.yaml
```

Use the original release/config/state lock for manual Jobs, recover only to a
separate empty PVC, pin an available image and retain created state/backup PVCs
on uninstall. Full metadata fidelity uses the documented root profile; the
non-root profile is only for files owned/readable by its account. Local working
capacity and the real CSI/admission-policy contract must be tested before
enabling schedules.
