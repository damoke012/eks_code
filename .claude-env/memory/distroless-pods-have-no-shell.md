---
name: distroless-pods-have-no-shell
description: "kubectl exec <pod> -- ls returns 'executable file not found in $PATH' on distroless images; it means the check cannot run, NOT that the file is missing. Hit on op-prod's aws-iam-authenticator 2026-10-26, the fourth absent binary in a week to read as a system fault."
metadata:
  type: feedback
---

2026-10-26, verifying the prerequisite for the op-prod apiserver webhook flag. Exec into
all three `aws-iam-authenticator` pods to list the webhook kubeconfig returned:

    OCI runtime exec failed: exec: "ls": executable file not found in $PATH

The image is distroless. **Nothing was learned about the file.** Read as ABSENT, this would
have blocked INFRA-1661 on a finding that did not exist; read as PRESENT it would have
authorised a change that can stop a production API server.

**Why:** this is the fourth absent binary in one week to present as a fact about the system
— `wget` missing in the RisingWave console gave four empty probes that read as 404s;
`kustomize`, `dig` and `flux` are absent on the WSL box and their `||` branches reported
build and DNS failures; now `ls`. The instrument's silence is not the system's answer.

**How to apply:** test for the binary before trusting its failure, and print NOT MEASURED
naming the missing tool. On prod, `kubectl debug` is forbidden (CLAUDE.md rule 3), so the
host filesystem is read through Talos's own API instead — see
[[prod-talosconfig-lives-in-secrets-manager]]. And pair any such check with a **positive
control**: `scripts/check-authenticator-webhook-file.sh` runs QA first, because QA already
carries the flag with a healthy API server and therefore MUST show the file. If the control
fails, the method is wrong and the real target's answer means nothing.

Related: [[prod-incident-instrument-check]], [[transport-failure-not-a-verdict]],
[[proxy-is-not-the-property]], [[a-guard-can-measure-the-wrong-thing]].
