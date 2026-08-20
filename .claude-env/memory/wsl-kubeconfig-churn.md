---
name: wsl-kubeconfig-churn
description: "Doke's WSL ~/.kube/config repeatedly loses its EKS contexts (config.bak rotations) — how to reconnect + cluster-endpoint fingerprints to verify you're on the right one"
metadata: 
  node_type: memory
  type: reference
  originSessionId: 161fed6b-7af8-49e8-9abf-c06ed6494c28
  modified: 2026-07-24T00:17:01.839Z
---

On Doke's WSL, the default `~/.kube/config` keeps **losing its EKS contexts** (qa-one / usxpress-dev / usxpress-prod vanish; leftover `config.bak.*` rotations clobber it). Repeatedly bit us during the 2026-07-17 prod incident + Wiz review.

**Reconnect any cloud cluster** (regenerates the context into the default config):
```
aws sso login --profile <usx-dev|usx-qa|ops-controller>
aws eks update-kubeconfig --profile <profile> --region us-east-2 --name <cluster> --alias <cluster>
```
- dev → profile `usx-dev`, cluster `usxpress-dev`, acct 700736442855
- qa  → profile `usx-qa`, cluster `qa-one`, acct 527101283767
- prod→ profile `ops-controller`, cluster `usxpress-prod`, acct 937464026810

**On-prem op-dev** is a SEPARATE kubeconfig file, NOT in the default:
`export KUBECONFIG=~/.kube/op-usxpress-dev-fresh.yaml` — **VERIFIED 2026-07-24** as the only
file serving `https://10.10.82.50:6443`.
⚠️ This line previously said `op-usxpress-dev.yaml` and told you to delete `-fresh.yaml`.
**Both halves were wrong.** There is no `op-usxpress-dev.yaml` — that file pointed at *QA EKS*
and was renamed `qa-one-eks.yaml`. Needs corp VPN (`nc -vz -w 5 10.10.82.50 6443`).

⚠️ **`qa-one-eks.yaml` is a MERGED multi-cluster file** — four servers including **prod
`BF7BD089`** plus on-prem dev. Sourcing it puts prod one `use-context` away. Don't.

**Never trust a kubeconfig filename — resolve by endpoint:**
```
for f in ~/.kube/*.yaml; do printf '%-45s %s\n' "$(basename $f)" \
  "$(kubectl --kubeconfig=$f config view -o jsonpath='{.clusters[*].cluster.server}')"; done
```
⚠️ A failed `export` (e.g. pasting a literal `<placeholder>` → bash syntax error) leaves
KUBECONFIG at its PREVIOUS value, so the next command silently runs against the old cluster.
Bit us 2026-07-24: a dev CRD query actually returned QA's. **Always `kubectl cluster-info |
head -1` after export, and read the result — not just run it.**

**On-prem QA `op-usxpress-qa` has NO kubeconfig in `~/.kube` and no context** — it is not in the default config at all. Derive it from the Terraform state's `kubeconfig` output (there is **no** `talosconfig` output — see [[qa-cluster-standup]]):
```
aws s3 cp s3://lazy-tf-state-425rbol87rmn6c7m/iaac/talos/op-usxpress-qa.tfstate - --profile usx-qa \
  | jq -r '.outputs.kubeconfig.value' > ~/.kube/op-usxpress-qa.yaml && chmod 600 ~/.kube/op-usxpress-qa.yaml
```
Stream the tfstate (`cp ... -`), never save it — it holds every secret in plaintext. Same state also has `control_plane_ips` / `worker_ips`.

**Always verify the endpoint before running — API-endpoint fingerprints:**
- prod `usxpress-prod` (EKS) → `BF7BD0896246A3AA0A5DF5C9D8200E8A.gr7.us-east-2.eks…`
- qa `qa-one` (EKS, cloud — NOT the on-prem QA) → `D0E66CB972CBA06A671417F398880660.gr7.us-east-2.eks…`
- on-prem **op-dev** → `https://10.10.82.50:6443`
- on-prem **op-qa** → `https://10.10.82.51:6443` ⚠️ **one digit from dev — read it twice.** QA = 3 CPs (10.10.82.25/.24/.177) + 10 workers (.138/.30/.107/.182/.184/.106/.139/.23/.105/.183) = 13 nodes.

⚠️ Two different things are called "QA": **`qa-one`** = AWS EKS cloud QA (acct 527101283767); **`op-usxpress-qa`** = on-prem Talos QA (uses that same AWS account for SM/S3/IRSA). Don't conflate.

⚠️ Prod was Doke's accidental default context earlier; an expired SSO token was the only thing that stopped commands hitting prod. Always `kubectl cluster-info | head -1` first. Related: [[user-doke-onprem-platform]].
