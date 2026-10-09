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

**On-prem QA `op-usxpress-qa`** — ✅ **verified 2026-08-20**: `~/.kube/op-usxpress-qa-sso.yaml`,
context **`op-usxpress-qa-sso`**, serving `https://10.10.82.51:6443`. (Superseded the earlier note
that it had no kubeconfig at all — that predated the SSO path going live 2026-07-28.)

⚠️ **TWO AWS profiles, two independent SSO sessions, and a green one tells you nothing about the
other.** The cluster authenticates through the `aws-iam-authenticator` exec plugin with
`AWS_PROFILE=op-qa`; Secrets Manager, S3 and the rest of the AWS API use `usx-qa`. On 2026-08-20
`aws --profile usx-qa sts get-caller-identity` succeeded while every `kubectl` failed, and the
symptom is an STS `SSO session has expired` buried inside an exec-plugin stack trace — which reads
like an unreachable cluster, not a login. Log in to **both**:
```
aws sso login --profile usx-qa    # AWS API
aws sso login --profile op-qa     # the cluster
```
Read the exec block rather than guessing which profile a kubeconfig uses:
```
kubectl --kubeconfig=$HOME/.kube/op-usxpress-qa-sso.yaml config view --raw \
  -o jsonpath='{.users[*].user.exec}{"\n"}'
```

If the file is ever lost, derive it again — it is not in the default config: Derive it from the Terraform state's `kubeconfig` output (there is **no** `talosconfig` output — see [[qa-cluster-standup]]):
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

**On-prem PROD `op-usxpress-prod` (10.10.82.52) has NO kubeconfig on this machine** — verified
2026-08-24 by scanning every `~/.kube/*.yaml` for that server address: zero matches. The prod
verification done earlier that day was break-glass and was not persisted. Reaching prod means
regenerating credentials first. Use `scripts/onprem-ingress-audit.sh --cluster op-prod`, which
resolves by endpoint and says so plainly rather than falling back to another cluster.

⚠️ A pasted `export KUBECONFIG=$HOME/.kube/<placeholder>` dies on a bash syntax error and
leaves KUBECONFIG at its PREVIOUS value — on 2026-08-24 four commands labelled "prod" ran
against op-dev. Same trap as 2026-07-24. Resolve by endpoint with a script, never by pasting
a path.



**op-prod recovered 2026-08-25 (INFRA-1663).** It had no persisted kubeconfig since at least
2026-08-24, which forced every prod fact to be inferred from Git. The credentials were in
Secrets Manager the whole time: `op-usxpress-prod/talosconfig`, readable with the
`ops-controller` profile (account 937464026810, us-east-2). `talosctl kubeconfig` mints a real
one — correct CA, correct endpoint, nothing inferred.

    scripts/onprem-prod-kubeconfig.sh ops-controller   ->  ~/.kube/op-usxpress-prod.yaml

Verified against live node names: **13 nodes** — `talos-cp-op-prod-1..3`,
`talos-wk-op-prod-application-1..5`, `talos-wk-op-prod-platform-1..3`,
`talos-wk-op-prod-system-1..2`. Endpoint 10.10.82.52:6443, context `admin@op-usxpress-prod`.
The same route should work for any cluster whose talosconfig is in Secrets Manager.

⚠️ **Third recurrence 2026-08-28 — and this time the "resolve by endpoint" loop CAUSED it.**
Matching on `{.clusters[*].cluster.server}` returns **every** server in a file, so a merged
multi-cluster file matches on merely *containing* dev. A loop that keeps iterating then lets the
LAST match win: `~/.kube/config` (current context **prod EKS BF7BD089**) was selected while the
output said `MATCH .../op-usxpress-dev-fresh.yaml` three lines earlier. Only an expired SSO token
stopped a prod query. **Resolving by endpoint is not enough — it must break on first match, and
must select a CONTEXT, not a file.** Both `qa-one-eks.yaml` and `config` are merged and contain
dev; `op-usxpress-dev-fresh.yaml` is the only single-cluster dev file. For op-dev just:
```
export KUBECONFIG=$HOME/.kube/op-usxpress-dev-fresh.yaml
kubectl cluster-info | head -1     # must say 10.10.82.50 — READ it
```
op-dev is **cert-based**: an `aws`/SSO error in the output means you are on an EKS context, not dev.


## 2026-08-31 — fourth recurrence: `kubectl config get-contexts` returned NOTHING

Not a wrong context — **no contexts at all**. Every cluster command failed with
`context "op-usxpress-qa" does not exist` while `~/.kube/` held eleven kubeconfig files.
The context names are not the cluster names:

| Cluster | File | Context |
|---|---|---|
| op-usxpress-dev | `~/.kube/op-usxpress-dev-fresh.yaml` | (cert-based) |
| op-usxpress-qa | `~/.kube/op-usxpress-qa.yaml` | `admin@op-usxpress-qa` |
| op-usxpress-prod | `~/.kube/op-usxpress-prod.yaml` | `admin@op-usxpress-prod` |

`scripts/onprem-prod-kubeconfig.sh ops-controller` rebuilt prod cleanly — 13 nodes,
3 control plane + 10 workers. Set `KUBECONFIG` to the single file and pass `--context`;
do not rely on a merged `~/.kube/config`.

## 2026-10-09 — WSL resolves corp names it cannot reach, and that reads as "cluster down"

Both on-prem control planes timed out all morning while AWS SSO and `gh` worked perfectly.
Diagnosed as a cluster or QA problem twice before measuring properly. It was neither.

    ip route    -> default via 172.27.240.1 dev eth0   (NAT, no tunnel interface)
    ip -brief addr -> eth0 172.27.248.61/20 only
    /etc/resolv.conf -> nameserver 10.255.255.254, search usxpress.com
    getent hosts argocd.op-dev.usxpress.io -> 10.10.82.28     RESOLVES
    nc -z 10.10.82.50 6443                 -> no route        UNREACHABLE

**WSL2 in default NAT mode has its own network namespace and does not inherit the Windows
VPN adapter's routes.** DNS still works, because WSL forwards queries to the Windows
resolver — so corp hostnames resolve to private addresses that WSL then cannot reach. The
split between a working name and a dead packet is the whole tell.

**Why it looks like the cluster:** every internet-facing tool keeps working (`gh`,
`aws sso`, `aws sts`), so the session feels healthy and only the clusters appear dead. On
2026-10-08 op-dev was reachable at 23:20Z and unreachable at 09:00Z the next morning with
nothing changed on the cluster — the VPN had reconnected after WSL was already running.

**Discriminate in one line before blaming anything:** `nc -z -w 4 <cp-ip> 6443` against a
cluster KNOWN to be healthy. Both dev and QA failing together is a route problem; one
failing alone is a cluster problem. [[transport-failure-not-a-verdict]].

**Fix, least disruptive first (run in PowerShell, not WSL):**

1. `wsl --shutdown`, reopen the terminal. WSL re-reads the host's routes at boot, which is
   usually enough when the VPN connected after WSL started.
2. If not, `%USERPROFILE%\.wslconfig` with `[wsl2]` / `networkingMode=mirrored`, then
   `wsl --shutdown`. WSL shares the Windows network stack and VPN routes apply directly.
   Windows 11 22H2+.

**Do not** re-run the same kubectl and hope; and do not report `i/o timeout` to a cluster IP
as a finding about that cluster.

### ⛔ CORRECTION, same day: NAT mode was NOT the cause

Switched WSL to `networkingMode=mirrored` and the interfaces duly changed (`eth0` DOWN,
Windows adapters appeared as `eth1`/`eth2`) — **and the route still did not exist.** Then
measured the host instead of the guest:

    powershell.exe -c "(Test-NetConnection 10.10.82.50 -Port 6443).TcpTestSucceeded"
      -> False
    powershell.exe -c "Get-NetRoute -DestinationPrefix 10.10.*"
      -> nothing at all
    adapters up: Wi-Fi, vEthernet (FSE HostVnic), vEthernet (WSL), auraclient

**Windows had no route to 10.10.0.0/16 either.** No corporate VPN adapter was present — the
only overlay was `auraclient` (Aurascape, a ZTNA agent; `aurascape.local` was already in
`/etc/resolv.conf`'s search list and `eth1` held a `100.64/10` CGNAT address).

ZTNA brokers named applications rather than routing subnets, so it answers DNS for corp names
while a raw `IP:6443` falls outside policy — which produces exactly the resolve-but-no-route
signature that the section above attributes to WSL NAT. **The signature is shared by two
different causes, and I diagnosed the wrong one.**

**Discriminate at the HOST before touching the guest:**

    powershell.exe -NoProfile -Command \
      "(Test-NetConnection <cp-ip> -Port 6443 -WarningAction SilentlyContinue).TcpTestSucceeded"

`False` means stop — nothing inside WSL can fix it. `True` while WSL fails is the NAT problem
the section above describes. One command, and it separates them.

The mirrored-networking change is worth keeping regardless: it removes WSL-vs-Windows
divergence as a variable permanently. It just was not the fix today.

**Same family as [[proxy-is-not-the-property]]:** I measured the guest and reported it as a
fact about the network. The guest was downstream of the real answer the whole time.
