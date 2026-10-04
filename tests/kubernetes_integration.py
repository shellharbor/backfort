#!/usr/bin/env python3
"""Real image/PVC recovery in a disposable kind cluster, never the user's context."""

import copy
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import uuid

from kubernetes_chart import documents

KIND = os.environ.get("KIND", "kind")
KUBECTL = os.environ.get("KUBECTL", "kubectl")
IMAGE = os.environ.get("BACKFORT_KUBERNETES_IMAGE", "backfort:kubernetes-test")
NODE_IMAGE = os.environ.get("KIND_NODE_IMAGE", "kindest/node:v1.34.0@sha256:7416a61b42b1662ca6ca89f02028ac133a309a2a30ba309614e8ec94d976dc5a")


class Integration:
    def __init__(self, directory):
        self.name = "backfort-test-" + uuid.uuid4().hex[:10]
        self.context = "kind-" + self.name
        self.env = dict(os.environ, KUBECONFIG=str(Path(directory) / "kubeconfig"))
        repository, tag = IMAGE.rsplit(":", 1)
        self.values = {"image": {"repository": repository, "tag": tag, "pullPolicy": "Never"},
                       "config": {"settings": {"host_id": "kubernetes-test", "min_free_mb": 1}},
                       "storage": {"backups": {"size": "1Gi"}},
                       "job": {"activeDeadlineSeconds": 180}, "workSizeLimit": "256Mi",
                       "resources": {"requests": {"cpu": "50m", "memory": "64Mi", "ephemeral-storage": "256Mi"},
                                     "limits": {"cpu": "1", "memory": "512Mi", "ephemeral-storage": "1Gi"}}}

    def run(self, args, data=None, check=True, timeout=240):
        result = subprocess.run(args, input=data, text=True, encoding="utf-8", errors="replace",
                                capture_output=True, env=self.env, timeout=timeout, check=False)
        if check and result.returncode:
            raise AssertionError(f'{" ".join(args)} failed:\n{result.stdout}\n{result.stderr}')
        return result

    def kubectl(self, *args, **kwargs):
        # An explicit context AND a private kubeconfig protect other clusters.
        return self.run([KUBECTL, "--context", self.context, "--namespace", "default", "--request-timeout=20s", *args], **kwargs)

    def apply(self, items):
        self.kubectl("apply", "-f", "-", data=json.dumps({"apiVersion": "v1", "kind": "List", "items": items}))

    def pvc(self, name):
        return {"apiVersion": "v1", "kind": "PersistentVolumeClaim", "metadata": {"name": name},
                "spec": {"accessModes": ["ReadWriteOnce"], "resources": {"requests": {"storage": "1Gi"}}}}

    def job(self, name, args, restore="", values=None, release="backfort"):
        settings = copy.deepcopy(self.values if values is None else values)
        settings["manual"] = {"enabled": True, "name": name, "args": args, "restoreClaim": restore}
        items = documents(settings, release=release, only="templates/manual-job.yaml")
        return items[0]

    def shell_job(self, name, script, restore="", values=None, release="backfort"):
        job = self.job(name, ["doctor"], restore, values, release)
        container = job["spec"]["template"]["spec"]["containers"][0]
        container["command"] = ["/bin/sh", "-ec"]
        container["args"] = [script]
        return job

    def finish(self, name, expected=0, timeout=180):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            job = json.loads(self.kubectl("get", "job", name, "-o", "json").stdout)
            conditions = job.get("status", {}).get("conditions", [])
            if any(c["type"] in ("Complete", "Failed") and c["status"] == "True" for c in conditions):
                break
            time.sleep(2)
        else:
            raise AssertionError(f"job {name} did not finish within {timeout}s")
        pods = json.loads(self.kubectl("get", "pods", "-l", f"job-name={name}", "-o", "json").stdout)["items"]
        statuses = [s.get("state", {}).get("terminated", {}) for p in pods
                    for s in p.get("status", {}).get("containerStatuses", [])]
        if len(statuses) != 1 or statuses[0].get("exitCode") != expected:
            logs = self.kubectl("logs", "job/" + name, check=False).stdout
            raise AssertionError(f"{name}: expected exit {expected}, got {statuses}\n{logs}")
        logs = self.kubectl("logs", "job/" + name).stdout
        print(f"PASS {name} (exit {expected})", flush=True)
        return logs

    def execute(self, job, expected=0):
        self.apply([job])
        return self.finish(job["metadata"]["name"], expected)

    def test(self):
        print("Creating isolated cluster " + self.name, flush=True)
        result = self.run([KIND, "create", "cluster", "--name", self.name, "--kubeconfig", self.env["KUBECONFIG"],
                           "--image", NODE_IMAGE, "--wait", "180s"], timeout=600)
        print(result.stderr, flush=True)
        self.run([KIND, "load", "docker-image", IMAGE, "--name", self.name], timeout=300)
        self.apply([self.pvc("application-data"), self.pvc("empty-recovery")])
        self.apply(documents(self.values))
        self.execute(self.seed_job())
        self.execute(self.job("doctor", ["doctor"]))
        self.execute(self.shell_job("readonly", "test -f /source/private/probe.txt; if touch /source/forbidden-write; then exit 1; fi"))
        self.kubectl("create", "job", "backfort-backup-01", "--from=cronjob/backfort-backup")
        self.finish("backfort-backup-01")
        self.execute(self.job("verify", ["verify", "latest", "--job", "application-files", "--full"]))
        self.execute(self.job("restore", ["restore", "latest", "--job", "application-files", "--to", "/restore"], "empty-recovery"))
        self.execute(self.shell_job("evidence", """
            set -x
            grep -qx 'PVC recovery evidence' /restore/source/private/probe.txt
            test "$(stat -c %u:%g:%a /restore/source/private/probe.txt)" = 1234:1234:640
            test "$(stat -c %u:%g:%a /restore/source/private)" = 1234:1234:700
            test "$(getfattr --only-values -n user.backfort /restore/source/private/probe.txt)" = verified
            getfacl -n /restore/source/private/probe.txt | grep -qx 'user:1235:r--'
            test "$(readlink /restore/source/link)" = private/probe.txt
            test "$(stat -c %u:%g:%a /restore/source/sgid)" = 1234:1234:2750
            test ! -e /restore/source/cache/ignored.txt
            test ! -e /restore/source/ignored.log
            test "$(find /backups -maxdepth 1 -type f -name '*.complete' | wc -l)" -eq 1
            test "$(stat -c %u:%g:%a /source/private/probe.txt)" = 1234:1234:640
        """, "empty-recovery"))
        logs = self.execute(self.job("nonempty", ["restore", "latest", "--job", "application-files", "--to", "/restore"], "empty-recovery"), expected=2)
        assert "restore-target-must-be-empty" in logs, logs
        # A lock held by a separate Job must reject a concurrent backup, even
        # though CronJob concurrencyPolicy cannot coordinate those two Jobs.
        holder = self.shell_job("hold-lock", "mkdir -p /var/lib/backfort/state; exec 9>/var/lib/backfort/state/backfort.lock; flock -x 9; echo LOCK-READY; exec sleep 600")
        holder["spec"]["activeDeadlineSeconds"] = 600
        holder["spec"]["template"]["spec"]["terminationGracePeriodSeconds"] = 1
        self.apply([holder])
        for _ in range(40):
            if "LOCK-READY" in self.kubectl("logs", "job/backfort-hold-lock", check=False).stdout:
                break
            time.sleep(1)
        else:
            raise AssertionError("lock holder did not start")
        logs = self.execute(self.job("contender", ["run"]), expected=3)
        assert "kind=lock" in logs, logs
        self.kubectl("delete", "job", "backfort-hold-lock", "--wait=true", "--timeout=90s")
        self.execute(self.shell_job("one-copy", "test \"$(find /backups -maxdepth 1 -type f -name '*.complete' | wc -l)\" -eq 1"))
        bad_config = {"apiVersion": "v1", "kind": "ConfigMap", "metadata": {"name": "bad-config"},
                      "data": {"config.yaml": "version: 1\nunexpected: true\n"}}
        invalid = self.job("invalid", ["doctor"])
        invalid["spec"]["template"]["spec"]["volumes"][0]["configMap"]["name"] = "bad-config"
        self.apply([bad_config])
        logs = self.execute(invalid, expected=2)
        assert "kind=config" in logs, logs
        self.kubectl("create", "job", "backfort-prune-01", "--from=cronjob/backfort-prune")
        self.finish("backfort-prune-01")
        self.nonroot_test()
        print("Backfort Kubernetes integration passed: real PVC backup, full verification, metadata recovery, readonly sources, lock, invalid config, prune and nonroot profile.", flush=True)

    def seed_job(self):
        job = self.shell_job("seed", """
            mkdir -p /source/private /source/cache
            printf 'PVC recovery evidence\n' >/source/private/probe.txt
            chmod 600 /source/private/probe.txt
            chown -R 1234:1234 /source/private
            chmod 700 /source/private
            setfattr -n user.backfort -v verified /source/private/probe.txt
            setfacl -m u:1235:r /source/private/probe.txt
            ln -s private/probe.txt /source/link
            printf 'excluded\n' >/source/cache/ignored.txt
            printf 'excluded\n' >/source/ignored.log
            printf 'SGID metadata evidence\n' >/source/sgid
            chown 1234:1234 /source/sgid
            chmod 2750 /source/sgid
            test "$(stat -c %a /source/sgid)" = 2750
        """, "empty-recovery")
        pod = job["spec"]["template"]["spec"]
        for mount in pod["containers"][0]["volumeMounts"]:
            if mount["name"] == "source-application":
                mount["readOnly"] = False
        for volume in pod["volumes"]:
            if volume["name"] == "source-application":
                volume["persistentVolumeClaim"]["readOnly"] = False
        return job

    def nonroot_test(self):
        self.apply([self.pvc("nr-source"), self.pvc("nr-recovery")])
        values = copy.deepcopy(self.values)
        values.update({"sources": [{"name": "application", "claimName": "nr-source", "mountPath": "/source"}],
                       "podSecurityContext": {"runAsNonRoot": True, "runAsUser": 1000, "runAsGroup": 1000, "fsGroup": 1000},
                       "securityContext": {"capabilities": {"drop": ["ALL"], "add": []}}})
        values["config"]["settings"]["host_id"] = "kubernetes-nonroot"
        self.apply(documents(values, release="nonroot"))
        seed = self.shell_job("seed", "chown 1000:1000 /source; printf 'nonroot evidence\n' >/source/probe.txt; chown 1000:1000 /source/probe.txt; chmod 600 /source/probe.txt",
                              "nr-recovery", values, "nonroot")
        pod = seed["spec"]["template"]["spec"]
        pod["securityContext"] = {"runAsUser": 0, "runAsGroup": 0}
        pod["containers"][0]["securityContext"]["capabilities"]["add"] = ["CHOWN", "DAC_OVERRIDE", "FOWNER"]
        for mount in pod["containers"][0]["volumeMounts"]:
            if mount["name"] == "source-application":
                mount["readOnly"] = False
        for volume in pod["volumes"]:
            if volume["name"] == "source-application":
                volume["persistentVolumeClaim"]["readOnly"] = False
        self.execute(seed)
        self.execute(self.job("doctor", ["doctor"], values=values, release="nonroot"))
        self.execute(self.job("backup", ["run"], values=values, release="nonroot"))
        self.execute(self.job("verify", ["verify", "latest", "--job", "application-files", "--full"], values=values, release="nonroot"))
        # Use an owned child, not the fsGroup-owned PVC root, as restore target.
        self.execute(self.job("restore", ["restore", "latest", "--job", "application-files", "--to", "/restore/result"], "nr-recovery", values, "nonroot"))
        self.execute(self.shell_job("evidence", "grep -qx 'nonroot evidence' /restore/result/source/probe.txt", "nr-recovery", values, "nonroot"))

    def diagnostics(self):
        print(self.kubectl("get", "pods,jobs,pvc", "-o", "wide", check=False).stdout, flush=True)
        pods = self.kubectl("get", "pods", "-o", "json", check=False)
        if pods.returncode == 0:
            for pod in json.loads(pods.stdout)["items"]:
                name = pod["metadata"]["name"]
                print(f"--- {name} ---\n" + self.kubectl("logs", name, check=False).stdout, flush=True)
        print(self.kubectl("get", "events", "--sort-by=.lastTimestamp", check=False).stdout, flush=True)


def main():
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")
    with tempfile.TemporaryDirectory(prefix="backfort-kubernetes-") as directory:
        test = Integration(directory)
        try:
            test.test()
        except Exception:
            test.diagnostics()
            raise
        finally:
            # Only this randomly named test cluster is removed. No global prune
            # and no reads/writes of the user's normal kubeconfig/context.
            result = test.run([KIND, "delete", "cluster", "--name", test.name], check=False, timeout=180)
            print(result.stderr, flush=True)
            if result.returncode:
                raise RuntimeError("Test cluster cleanup failed: " + test.name)


if __name__ == "__main__":
    main()
