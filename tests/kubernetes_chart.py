#!/usr/bin/env python3
"""Render the Helm contract and exercise its safety gates (no cluster needed)."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[1]
CHART = ROOT / "charts" / "backfort"
HELM = os.environ.get("HELM", "helm")


def render(values=None, release="backfort", version="1.34.0", only=None):
    with tempfile.TemporaryDirectory(prefix="backfort-chart-") as directory:
        arguments = [HELM, "template", release, str(CHART), "--kube-version", version]
        if values is not None:
            path = Path(directory) / "values.yaml"
            path.write_text(yaml.safe_dump(values), encoding="utf-8")
            arguments += ["-f", str(path)]
        if only:
            arguments += ["--show-only", only]
        return subprocess.run(arguments, text=True, capture_output=True, check=False)


def documents(values=None, **kwargs):
    result = render(values, **kwargs)
    if result.returncode:
        raise AssertionError(result.stderr)
    return [item for item in yaml.safe_load_all(result.stdout) if item]


def pod_specs(items):
    for item in items:
        if item["kind"] == "CronJob":
            yield item["spec"]["jobTemplate"]["spec"]["template"]["spec"]
        elif item["kind"] == "Job":
            yield item["spec"]["template"]["spec"]


class ChartContract(unittest.TestCase):
    def reject(self, values, fragment, **kwargs):
        result = render(values, **kwargs)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn(fragment, result.stderr)

    def test_version_and_supported_kubernetes(self):
        chart = yaml.safe_load((CHART / "Chart.yaml").read_text(encoding="utf-8"))
        self.assertIn(f'readonly BACKFORT_VERSION="{chart["appVersion"]}"',
                      (ROOT / "backfort.sh").read_text(encoding="utf-8"))
        for version in ("1.31.0", "1.34.0"):
            with self.subTest(version=version):
                self.assertTrue(documents(version=version))
        self.reject({}, "kubeVersion", version="1.30.0")

    def test_default_lifecycle_and_security(self):
        items = documents()
        self.assertEqual([item["kind"] for item in items].count("CronJob"), 2)
        self.assertFalse(any(item["kind"] in ("Role", "RoleBinding", "Secret", "Deployment")
                             for item in items))
        for item in items:
            if item["kind"] != "CronJob":
                continue
            spec = item["spec"]
            self.assertTrue(spec["suspend"])
            self.assertEqual(spec["concurrencyPolicy"], "Forbid")
            job = spec["jobTemplate"]["spec"]
            self.assertEqual((job["backoffLimit"], job["parallelism"], job["completions"]), (0, 1, 1))
            self.assertGreater(job["activeDeadlineSeconds"], 0)
        for pod in pod_specs(items):
            self.assertFalse(pod["automountServiceAccountToken"])
            self.assertEqual(pod["restartPolicy"], "Never")
            self.assertNotIn("fsGroup", pod["securityContext"])
            container = pod["containers"][0]
            self.assertNotIn("command", container)
            self.assertTrue(container["securityContext"]["readOnlyRootFilesystem"])
            self.assertFalse(container["securityContext"]["allowPrivilegeEscalation"])
            self.assertEqual(container["securityContext"]["capabilities"]["drop"], ["ALL"])
            self.assertEqual(container["securityContext"]["capabilities"]["add"], ["CHOWN", "DAC_OVERRIDE", "FOWNER", "FSETID", "SETFCAP"])
            self.assertNotIn("privileged", container["securityContext"])
            self.assertTrue(container["resources"]["limits"])
            self.assertFalse(any("hostPath" in volume for volume in pod["volumes"]))
            mounts = {mount["name"]: mount for mount in container["volumeMounts"]}
            self.assertTrue(mounts["source-application"]["readOnly"])
            self.assertTrue(mounts["config"]["readOnly"])
            self.assertNotIn("restore", mounts)
        for pvc in (item for item in items if item["kind"] == "PersistentVolumeClaim"):
            self.assertEqual(pvc["metadata"]["annotations"]["helm.sh/resource-policy"], "keep")
            self.assertNotIn("storageClassName", pvc["spec"])

    def test_manual_literal_arguments_and_recovery_isolation(self):
        args = ["restore", "latest", "--job", "application-files", "--to", "/restore"]
        items = documents({"manual": {"enabled": True, "name": "restore-01", "args": args,
                                       "restoreClaim": "empty-recovery"}})
        job = next(item for item in items if item["kind"] == "Job")
        pod = job["spec"]["template"]["spec"]
        self.assertEqual(pod["containers"][0]["args"][2:], args)
        self.assertIn({"name": "restore", "persistentVolumeClaim": {"claimName": "empty-recovery"}}, pod["volumes"])
        for item in (item for item in items if item["kind"] == "CronJob"):
            self.assertFalse(any(volume["name"] == "restore"
                                 for volume in item["spec"]["jobTemplate"]["spec"]["template"]["spec"]["volumes"]))
        literal = ["doctor", "$(touch /tmp/not-a-shell)", "{{ not_a_template }}"]
        pod = next(pod_specs(documents({"backup": {"enabled": False}, "prune": {"enabled": False},
                                        "manual": {"enabled": True, "args": literal}})))
        self.assertEqual(pod["containers"][0]["args"][2:], literal)

    def test_existing_storage_and_service_account(self):
        values = {"serviceAccount": {"create": False, "name": "existing-account"},
                  "storage": {"state": {"existingClaim": "state-existing"},
                              "backups": {"existingClaim": "backup-existing"}}}
        items = documents(values)
        self.assertFalse(any(item["kind"] in ("ServiceAccount", "PersistentVolumeClaim") for item in items))
        for pod in pod_specs(items):
            self.assertEqual(pod["serviceAccountName"], "existing-account")
            claims = {v["name"]: v["persistentVolumeClaim"]["claimName"]
                      for v in pod["volumes"] if "persistentVolumeClaim" in v}
            self.assertEqual(claims["state"], "state-existing")
            self.assertEqual(claims["backups"], "backup-existing")
        self.reject({"serviceAccount": {"create": False}}, "serviceAccount.name")
        named = documents({"serviceAccount": {"name": "named-account"}})
        self.assertEqual(next(i for i in named if i["kind"] == "ServiceAccount")["metadata"]["name"], "named-account")

    def test_custom_storage_classes_and_schedules(self):
        items = documents({"storage": {"state": {"storageClass": "", "accessModes": ["ReadWriteMany"]},
                                       "backups": {"storageClass": "fast-csi"}},
                           "backup": {"suspend": False, "schedule": "0 * * * *", "timeZone": "Europe/Moscow"},
                           "prune": {"enabled": False}})
        pvcs = {item["metadata"]["name"]: item for item in items if item["kind"] == "PersistentVolumeClaim"}
        self.assertEqual(pvcs["backfort-state"]["spec"]["storageClassName"], "")
        self.assertEqual(pvcs["backfort-state"]["spec"]["accessModes"], ["ReadWriteMany"])
        self.assertEqual(pvcs["backfort-backups"]["spec"]["storageClassName"], "fast-csi")
        cron = next(item for item in items if item["kind"] == "CronJob")
        self.assertEqual(cron["spec"]["schedule"], "0 * * * *")
        self.assertFalse(cron["spec"]["suspend"])
        self.assertEqual(cron["spec"]["timeZone"], "Europe/Moscow")

    def test_rclone_secret_and_optional_pod_fields(self):
        values = yaml.safe_load((ROOT / "examples/kubernetes/rclone.values.yaml").read_text(encoding="utf-8"))
        values.update({"envFromSecret": "runtime-credentials", "env": {"COUNT": 3, "ENABLED": True},
                       "image": {"digest": "sha256:" + "a" * 64},
                       "imagePullSecrets": [{"name": "registry-auth"}],
                       "nodeSelector": {"kubernetes.io/os": "linux", "backup": "allowed"},
                       "affinity": {"nodeAffinity": {"preferredDuringSchedulingIgnoredDuringExecution": []}},
                       "tolerations": [{"key": "backup", "operator": "Exists"}]})
        items = documents(values)
        self.assertFalse(any(item["kind"] == "PersistentVolumeClaim" and item["metadata"]["name"].endswith("-backups") for item in items))
        for pod in pod_specs(items):
            container = pod["containers"][0]
            self.assertTrue(container["image"].endswith("@sha256:" + "a" * 64))
            self.assertEqual(container["envFrom"], [{"secretRef": {"name": "runtime-credentials"}}])
            self.assertTrue(all(isinstance(env["value"], str) for env in container["env"]))
            self.assertIn("affinity", pod)
            self.assertIn("tolerations", pod)
            self.assertEqual(pod["imagePullSecrets"], [{"name": "registry-auth"}])
            self.assertFalse(any(volume["name"] == "backups" for volume in pod["volumes"]))
            secret = next(volume["secret"] for volume in pod["volumes"] if "secret" in volume)
            self.assertEqual(secret, {"secretName": "backfort-rclone", "defaultMode": 0o440})

    def test_nonroot_and_examples(self):
        for path in sorted((ROOT / "examples/kubernetes").glob("*.values.yaml")):
            with self.subTest(path=path.name):
                self.assertTrue(documents(yaml.safe_load(path.read_text(encoding="utf-8"))))
        values = yaml.safe_load((ROOT / "examples/kubernetes/nonroot.values.yaml").read_text(encoding="utf-8"))
        for pod in pod_specs(documents(values)):
            self.assertTrue(pod["securityContext"]["runAsNonRoot"])
            self.assertEqual(pod["securityContext"]["runAsUser"], 1000)
            self.assertEqual(pod["containers"][0]["securityContext"]["capabilities"]["add"], [])

    def test_multiple_source_and_secret_mounts(self):
        sources = [{"name": "one", "claimName": "one", "mountPath": "/source/one"},
                   {"name": "two", "claimName": "two", "mountPath": "/source/two"}]
        secrets = [{"name": "age", "secretName": "age-key", "mountPath": "/run/secrets/age"},
                   {"name": "rclone", "secretName": "rclone", "mountPath": "/run/secrets/rclone"}]
        for pod in pod_specs(documents({"sources": sources, "secretMounts": secrets})):
            self.assertEqual(sum(v["name"].startswith("source-") for v in pod["volumes"]), 2)
            self.assertEqual(sum(v["name"].startswith("secret-") for v in pod["volumes"]), 2)

    def test_invalid_schema(self):
        invalid = [{"unknown": True}, {"config": {"version": 2}}, {"image": {"digest": "sha256:wrong"}},
                   {"manual": {"args": []}}, {"manual": {"name": "UPPER"}},
                   {"job": {"startingDeadlineSeconds": 1}}, {"workSizeLimit": ""},
                   {"sources": [{"name": "bad", "claimName": "app", "mountPath": "/source/../backups"}]},
                   {"storage": {"state": {"accessModes": ["ReadOnlyMany"]}}},
                   {"secretMounts": [{"name": "key", "secretName": "key", "mountPath": "/etc/backfort"}]}]
        for values in invalid:
            with self.subTest(values=values):
                self.reject(values, "schema")

    def test_invalid_runtime_paths_and_compose(self):
        self.reject({"config": {"jobs": [{"source": {"type": "docker_compose"}}]}}, "source.type=files")
        for key, values in {"state_directory": ["/tmp/state", "/var/lib/backfort/../outside"],
                            "lock_file": ["/tmp/lock", "/var/lib/backfort/../lock"],
                            "temp_directory": ["/tmp/work", "/var/tmp/backfort/../outside"]}.items():
            for value in values:
                with self.subTest(key=key, value=value):
                    self.reject({"config": {"settings": {key: value}}}, key)

    def test_duplicate_mounts(self):
        for key, field in (("sources", "claimName"), ("secretMounts", "secretName")):
            base = "/source" if key == "sources" else "/run/secrets"
            first = {"name": "one", field: "one", "mountPath": base + "/one"}
            for duplicate in (dict(first, mountPath=base + "/two"), dict(first, name="two")):
                self.reject({key: [first, duplicate]}, "unique")

    def test_reject_live_recovery_and_recursive_sources(self):
        self.reject({"storage": {"state": {"existingClaim": "same"}, "backups": {"existingClaim": "same"}}}, "separate PVCs")
        for claim in ("backfort-state", "backfort-backups"):
            self.reject({"sources": [{"name": "application", "claimName": claim, "mountPath": "/source"}]}, "source PVC")
            self.reject({"manual": {"enabled": True, "restoreClaim": claim}}, "must differ")
        self.reject({"manual": {"enabled": True, "restoreClaim": "application-data"}}, "live source PVC")
        # A disabled local backup PVC is not part of the workload's claim set.
        self.assertTrue(documents({"storage": {"backups": {"enabled": False}},
                                   "manual": {"enabled": True, "restoreClaim": "backfort-backups"}}))

    def test_restore_requires_isolated_target_and_explicit_command(self):
        self.reject({"manual": {"enabled": True, "args": ["restore", "latest", "--to", "/restore"]}}, "requires an isolated")
        for args in (["restore", "latest"], ["restore", "latest", "--to"],
                     ["restore", "latest", "--to", "/backups/recovery"],
                     ["restore", "latest", "--to", "/restore/../source"],
                     ["restore", "latest", "--to", "/restore/result", "--to", "/restore/other"]):
            with self.subTest(args=args):
                self.reject({"manual": {"enabled": True, "args": args, "restoreClaim": "empty-recovery"}}, "manual restore requires")
        for prefix in ([], ["--dry-run"], ["-n"]):
            self.assertTrue(documents({"manual": {"enabled": True, "restoreClaim": "empty-recovery",
                                                 "args": prefix + ["restore", "latest", "--to", "/restore/result-01"]}}))
        for args in (["--dry-run"], ["-n"], ["-c", "/tmp/other.yaml", "run"], ["quick", "/source"]):
            self.reject({"manual": {"enabled": True, "args": args}}, "manual.args")


if __name__ == "__main__":
    unittest.main(verbosity=2)
