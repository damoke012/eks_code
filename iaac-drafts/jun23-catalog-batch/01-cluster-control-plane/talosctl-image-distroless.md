# `ghcr.io/siderolabs/talosctl:*` image is DISTROLESS — no shell

**Category**: 01-cluster-control-plane
**First seen**: 2026-06-23 op-usxpress-dev etcd-backup CronJob
**Severity**: pod creates then dies at container init — high churn until detected

## Symptom

Pod starts then immediately fails with status `Error` and goes into `BackOff`:

```
Events:
  Warning  Failed  Error: failed to create containerd task:
                   failed to create shim task: OCI runtime create failed:
                   runc create failed: unable to start container process:
                   error during container init: exec: "/bin/sh":
                   stat /bin/sh: no such file or directory
```

The image was `ghcr.io/siderolabs/talosctl:v1.10.4` (or similar version) and the pod spec used `command: ["/bin/sh", "-c", "<script>"]`.

## Why

Sidero Labs ships the talosctl image as **distroless** — the Dockerfile uses `FROM scratch` (or `FROM gcr.io/distroless/static`) and copies only the `talosctl` binary. The image's entrypoint IS the binary at `/talosctl`. There is no shell, no package manager, no `cat`, no `aws` CLI, nothing else.

Pod specs that wrap the binary in a shell script fail at container init because the runtime can't find `/bin/sh` (or `sh` in PATH).

## Fix patterns

### Pattern A — Multi-container pod (recommended for snapshot + upload to S3)

```yaml
spec:
  template:
    spec:
      securityContext:
        seccompProfile: {type: RuntimeDefault}
        runAsNonRoot: true
        runAsUser: 1000
        fsGroup: 1000   # so emptyDir is writable by both containers
      initContainers:
        - name: snapshot
          image: ghcr.io/siderolabs/talosctl:v1.10.4
          command:
            - /talosctl
            - --talosconfig=/etc/talos/config
            - --endpoints=10.10.82.50
            - --nodes=10.10.82.50
            - etcd
            - snapshot
            - /work/snapshot.db
          volumeMounts:
            - {name: talosconfig, mountPath: /etc/talos, readOnly: true}
            - {name: workdir, mountPath: /work}
          securityContext:
            allowPrivilegeEscalation: false
            capabilities: {drop: ["ALL"]}
      containers:
        - name: upload
          image: amazon/aws-cli:2.17.0   # has bash + aws CLI
          command:
            - bash
            - -c
            - |
              set -euo pipefail
              TS=$(date -u +%Y%m%dT%H%M%SZ)
              aws s3 cp /work/snapshot.db s3://${S3_BUCKET}/<cluster>/${TS}/snapshot.db
          env:
            - {name: AWS_REGION, value: us-east-2}
            - {name: S3_BUCKET, value: <bucket-name>}
          volumeMounts:
            - {name: workdir, mountPath: /work, readOnly: true}
          securityContext:
            allowPrivilegeEscalation: false
            capabilities: {drop: ["ALL"]}
      volumes:
        - name: talosconfig
          secret:
            secretName: talosconfig
            items: [{key: config, path: config, mode: 0400}]
        - name: workdir
          emptyDir: {}
```

The initContainer runs `talosctl etcd snapshot` writing to a shared emptyDir. When it exits, the main container starts and uploads to S3.

### Pattern B — Fat image (single container, more upfront work)

Build your own image off `amazonlinux:2023` or `alpine:3.18`:

```dockerfile
FROM amazonlinux:2023
RUN yum install -y curl unzip ca-certificates && \
    curl -sL -o /tmp/aws.zip https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip && \
    unzip -q /tmp/aws.zip -d /tmp && /tmp/aws/install && rm -rf /tmp/aws* && \
    curl -sL -o /usr/local/bin/talosctl https://github.com/siderolabs/talos/releases/download/v1.10.4/talosctl-linux-amd64 && \
    chmod +x /usr/local/bin/talosctl && \
    useradd -u 1000 -s /bin/bash talos
USER 1000
ENTRYPOINT ["/bin/bash"]
```

Push to ECR, reference in pod spec. Simpler runtime spec but requires CI to build/maintain the image.

## Detection

Reveal distrolessness without deploying:

```bash
# This errors out → image is distroless (no shell)
docker run --rm --entrypoint=/bin/sh ghcr.io/siderolabs/talosctl:v1.10.4 -c "echo hi" 2>&1
# Output: stat /bin/sh: no such file or directory
```

Or after a pod fails:

```bash
kubectl describe pod <pod> | grep -A 2 "no such file or directory"
```

## How to apply to QA / PROD

- Don't use `ghcr.io/siderolabs/talosctl:*` directly in pod specs that need shell wrapping
- For etcd snapshot CronJobs: use Pattern A (multi-container) — simplest, no image build
- For QA cluster bring-up: bake the multi-container CronJob into the platform Flux Kustomization from day one
- Test the pod spec with `kubectl --dry-run=server` AND deploy a one-off Job to verify before relying on a CronJob

## Reference incident

op-usxpress-dev etcd-backup CronJob 2026-06-23:
- 4 scheduled CronJob runs failed silently (PSA seccomp issue, see [`psa-restricted-seccomp-required.md`](../04-secrets-credentials/psa-restricted-seccomp-required.md))
- After PSA fix (PR #58), pod CREATED but died at container init → distroless image discovered
- Filed as INFRA-1547 for proper multi-container restructure
- Velero (the bigger restore-readiness win) was prioritized for tonight; etcd-backup deferred

## Related

- [`psa-restricted-seccomp-required.md`](../04-secrets-credentials/psa-restricted-seccomp-required.md) — the OTHER blocker on the same CronJob
- Sidero docs: https://www.talos.dev/v1.10/talos-guides/howto/snapshots/
- INFRA-1547 (Knight-Swift Jira) — etcd-backup multi-container restructure
