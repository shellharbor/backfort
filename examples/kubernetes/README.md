# Kubernetes values examples

These files are **Helm values**, not files to pass directly to `backfort -c`.
Use them with `charts/backfort` in the same namespace as the existing source
PVCs. Edit the host ID, claim names, capacity and provider paths before use.

| Example | Purpose |
| --- | --- |
| [pvc-local.values.yaml](pvc-local.values.yaml) | Read-only application PVC with separate persistent state and backup PVCs; schedules suspended. |
| [rclone.values.yaml](rclone.values.yaml) | Rclone-only offsite copies using an already-existing mounted Secret; no local backup PVC. |
| [nonroot.values.yaml](nonroot.values.yaml) | Optional UID/GID 1000 files-only profile, no capabilities; narrower metadata recovery. |
| [restore.values.yaml](restore.values.yaml) | Manual verified restore to an existing isolated recovery PVC, mounted only for that Job. |

```bash
helm upgrade --install backfort ./charts/backfort -n application \
  -f examples/kubernetes/pvc-local.values.yaml

# Add offsite storage only after editing its host ID, remote and bucket/path.
helm upgrade --install backfort ./charts/backfort -n application \
  -f examples/kubernetes/pvc-local.values.yaml \
  -f examples/kubernetes/rclone.values.yaml
```

Helm replaces lists, rather than merging jobs/destinations/mounts item by item.
Keep one reviewed values file for the deployed release. Do not use a live
database PVC as a substitute for a consistent logical export; source preparation
belongs to the application/operator. The complete manual doctor, first backup,
verification and recovery sequence is in
[Kubernetes Deployment](../../wiki/Kubernetes-Deployment.md).
