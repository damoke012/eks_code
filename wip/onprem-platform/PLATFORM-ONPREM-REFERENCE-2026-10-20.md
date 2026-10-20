# The on-prem platform — how it is built, what runs on it, how it reaches everything else

**2026-10-20.** For anyone who has to build, extend, debug or explain the on-prem Talos
platform. Each fact is marked **measured** (we read it), **recorded** (from an earlier
verified note) or **⚠️ unverified** (believed, never checked). Nothing here is inferred and
presented as fact.

**Published page:** https://claude.ai/artifact/CduE9WmBzQvsXXRxyjd9rv

---

## 1. What it is, in one line

Three self-managed **Talos Linux** Kubernetes clusters in the US Xpress datacenter, built by
Terraform through Octopus, configured entirely by **Flux** from Git, running applications
through **Argo CD**, and joined to AWS by a **VPN and transit gateway** that already carries
traffic.

## 2. The three clusters

| | dev | QA | prod |
|---|---|---|---|
| Cluster name | `op-usxpress-dev` | `op-usxpress-qa` | `op-usxpress-prod` |
| API endpoint | `10.10.82.50:6443` | `10.10.82.51:6443` | `10.10.82.52:6443` |
| AWS account it uses | 700736442855 | 527101283767 | 937464026810 |
| Flux cluster directory | **`bm-dev`** | `op-usxpress-qa` | `op-usxpress-prod` |
| Platform branch | `op-dev` | `op-qa` | `op-prod` |
| Human kubectl | certificates (break-glass) | **AWS SSO**, live since 2026-07-28 | certificates (break-glass) |
| Argo CD sync | automatic | automatic + self-heal | **manual only** |

**Measured 2026-10-20:** every node of op-qa sits in **10.10.82.0/24** — 3 control plane, 5
application workers, 3 platform workers, 2 system workers, 13 in total. dev (.50) and prod
(.52) are in the same /24, so **one address range covers all three clusters**.

**Pod network: 10.244.0.0/16**, allocated as a /24 per node. Pods leave the cluster
masqueraded to their node's address, so **10.244.x.x is never what a remote service sees**.

**Kubernetes `v1.32.0` on every node of BOTH op-qa and op-prod, measured 2026-10-20**, OS
Talos, built 2024-12-11. Both clusters have the same 13-node layout.

⛔ **That version left upstream support on 2026-02-28**, and the line's final patch was
**1.32.13** — so op-qa is running the *initial* release of a line that ended eight months ago,
having never taken a single patch. Self-managed Talos means **no vendor extended support
applies**. Cloud EKS, for contrast, runs 1.35 and 1.36.

⚠️ **dev is not measured.**

## 3. How a cluster gets created

```
Octopus project "iaac-talos"
      │  runs Terraform on an Octopus worker
      ▼
vSphere  ──  VMs from a content-library image
      │
      ▼
Talos Linux  ──  control plane + worker pools
      │
      ▼
Flux bootstrapped  ──  everything else arrives from Git
```

**Deployed through Octopus only.** A local `terraform apply` is never the answer, for any
environment.

⚠️ **The cluster's entire specification lives in an Octopus web form.** 121 `TF_VAR_*`
project variables on the `iaac-talos` project — VIPs, cluster names, vSphere placement, node
sizes — **in no repository and under no review**. `iaac-octopus-config` manages spaces,
environments, worker pools and lifecycles, and creates **no project variables at all**.

Three consequences that have each cost real time:

* **`TfApply=false` is the default**, so a deploy prints the full plan, skips the apply and
  reports Success. Grep the task log for `Apply complete!`. **QA has been `true` since July**,
  so QA deploys apply for real.
* **A variable scoped `[ALL]` is invisible to anything that copies scoped values.** A
  generator built that way planned 13 VMs for a 4-VM cluster, because it never saw the
  inherited defaults.
* **A release freezes its variable snapshot.** Correcting a variable does nothing to a release
  that already exists; refresh the snapshot or create a new release.
* **An environment missing from a lifecycle phase can never receive a deployment**, and adding
  it to the environment list alone gives a green pull request and a dead environment.

**The seven vSphere placement values** — datacenter, datastore, vm_cluster_name, vm_folder,
network_name, content_library_name, content_library_item_name — exist **only** in Octopus.
A new environment cannot be built without them, and they are not in Git.

## 4. What is installed, and what installs it

Flux reads two repositories, in order:

| GitRepository | Repository | Ref | Supplies |
|---|---|---|---|
| `flux-system` | `iaac-talos-flux-cluster` | branch `master` | the Kustomization definitions themselves — the wiring |
| `infra` | `iaac-talos-flux-platform` | branch `op-<env>` | every `infrastructure/*` component |
| `gateway-api-upstream` | `kubernetes-sigs/gateway-api` | tag **v1.4.0** | the Gateway API CRDs |

⚠️ **`flux reconcile source git flux-system` fetches the *cluster* repo, not the platform
one.** Kustomizations whose `sourceRef` is `infra` stay on their cached revision and still
print `✔ applied revision op-prod@sha1:<old>`, which reads as success. Use
`flux reconcile kustomization <name> --with-source`, and confirm the revision actually moved.

**Running on op-qa, measured 2026-10-20** — 183 pods. The platform components:

| Component | Namespace | What it does |
|---|---|---|
| **Flux** (4 controllers) | `flux-system` | source, kustomize, helm, notification |
| **Argo CD** (5 pods) | `argocd` | deploys applications; SSO through Entra |
| **cert-manager** + cainjector + webhook | `cert-manager` | certificates |
| **trust-manager** | `cert-manager` | distributes trust bundles |
| **cert-manager-istio-csr** | `cert-manager` | issues Istio workload certificates |
| **External Secrets** (3 pods) | `external-secrets` | AWS Secrets Manager → Kubernetes Secrets |
| **external-dns** | `external-dns` | writes DNS records into Route 53 |
| **Istio ingress gateway** (6 pods, one per node) | `istio-ingress` | all inbound traffic |
| **Grafana** | `grafana` | dashboards — and the only pod we found carrying `curl` |

**Measured 2026-10-20 on op-qa — 183 pods across 20 namespaces:** `rook-ceph` **62**,
`velero` **44**, `kube-system` 32, `istio-system` 28, `risingwave` 13, `prometheus` 13,
`istio-ingress` 10, `cert-manager` 6, `kyverno` 5, `argocd` 5, `flux-system` 4, and `keda`,
`external-secrets`, `etcd-backup` 3 each, `pod-identity-webhook` and `ecr-credentials` 2 each,
`reloader`, `local-path-storage`, `grafana`, `external-dns` 1 each.

**Three corrections to what this document assumed:**

* **The CNI is Cilium** — `cilium-lb` and `cilium-hygiene` Kustomizations, 105 days old. The
  per-node /24 out of `10.244.0.0/16` is Cilium's allocation.
* **Istio runs in ambient mode** — there is an `istio-ztunnel` Kustomization, so workloads are
  meshed without a per-pod sidecar.
* **KEDA is installed** and appeared in none of our notes.

**Rook-Ceph is live**, not merely stood up once. **`aws-iam-authenticator` is a Flux
Kustomization** on QA, 83 days old — which is what makes it a clean copy for another cluster.

**All 30 Kustomizations reported `True`**, and the two-source model is visible in one
listing: every entry reports `op-qa@sha1:625b1cc9…` except `flux-system`, which reports
`master@sha1:db4812ce…`.

✅ **Prod returns the same counts in 19 of 20 namespaces** — the only difference is
`risingwave`, 14 pods against QA's 13. So **prod is not missing platform components**; the
readiness gaps are configuration and behaviour, not presence.

⚠️ **kube-system is 32 on both**, and QA's `aws-iam-authenticator` lives there — so **prod may
already be running it**. Equal counts are a hint, never a finding: check with
`kubectl -n kube-system get ds,deploy -o name | grep -i auth`.

⚠️ **dev is not measured**, and differs at least in Flux version.

**Flux versions drift:** `bm-dev` runs **v2.8.8** while QA and prod run **v2.7.5**. So
"prove it on dev first" is invalid for anything Flux-behavioural — dev is ahead.

## 5. Networking inside the cluster

**Two Istio gateways**, and which one a service needs depends on its protocol:

| Gateway | Ports | For |
|---|---|---|
| `shared-http` | 80, 443 | ordinary HTTP and HTTPS |
| `tcp-passthrough` | 4567, 5432 | protocols that are not HTTP — RisingWave's SQL frontend, Postgres |

**DNS is ours and automatic.** external-dns reads the annotations on a `VirtualService` and
writes the record into Route 53. The zone lives in the **network account, 155768531003**, and
each cluster has its own owner id so one cluster cannot overwrite another's records. The
record targets **that cluster's own worker addresses** — dev 7, QA 3, prod 10, and the counts
differ per cluster.

⚠️ **A copied VirtualService fails silently.** It will carry the source cluster's hostname or
targets, external-dns will do exactly what it is told, and nothing reports a problem.

⚠️ **`usxpress.io` caches a negative answer for 86400 seconds.** Resolving a name to check
whether it exists is what hides it for the next 24 hours. Read the Route 53 API; resolve only
names you have already confirmed exist.

**Corporate DNS and AD are reachable:** CoreDNS forwards `usxpress.com`, and LDAPS on 636 is
open from inside the cluster.

## 6. The connection to AWS — measured in full on 2026-10-20

This is the part most people assume is missing. **It is not.**

```
  datacenter 10.10.82.0/24
        │
        │  site-to-site VPN  (two connections, both up, BGP — no static routes)
        ▼
  tgw-09c7b37043d31e43a   "USX Infrastructure Transit Gateway"
  owned by the network account 155768531003
        │
        ├── 7 VPC attachments — including all three EKS accounts
        │     700736442855 (dev) · 527101283767 (QA) · 937464026810 (prod)
        ├── 2 peering attachments
        └── 1 VPN attachment  (tgw-attach-02049e22560f04685)
```

**All eight of the transit gateway's route tables carry `10.0.0.0/8`, propagated from the VPN
attachment.** The datacenter advertises that range by BGP; AWS advertises its VPC ranges back,
and longest-prefix match decides. **No Direct Connect was found** in us-east-1 or us-east-2 in
either the network or management account.

**What this means in practice:** on-prem and AWS are not separate islands. A private address
in an attached VPC is reachable in principle, and what stops a particular connection is
usually a **security group**, not the network.

⚠️ **Read a transit gateway route table by the attachment's association, never by index.**
Asking for route table `[0]` returns a table the VPC in question may not use. On 2026-10-20
every table happened to agree, so the shortcut gave the right answer for the wrong reason.

**Egress to the public internet works and the public CA bundle is trusted** — proven from a
pod: two external partner endpoints answered with a valid certificate chain and no extra
configuration.

## 7. Secrets and the registry

**External Secrets Operator → AWS Secrets Manager**, per cluster, into its own AWS account.

⚠️ **A green `ExternalSecret` is not a valid value.** On an error ESO still writes the keys it
*could* resolve, reports `SecretSyncedError`, and the pod then dies at container creation with
**RESTARTS 0** — invisible to every restart alert. Count the keys and assert none is empty.

⚠️ **A `secretKeyRef` resolves at pod creation.** A container restart replays the old value,
so a rotated secret can take months to actually arrive.

⚠️ **`op-*-platform-admin` had only `sts:GetCallerIdentity`** — it could not write its own
secrets. **op-qa was fixed 2026-08-25; dev and prod are still open.**

**Registry access:** a CronJob, `ecr-credentials-sync`, writes `ecr-pull-secret` into every
namespace every five minutes and patches every ServiceAccount. So **a pull secret's
`creationTimestamp` is not the age of its data** — a seven-week-old Secret can hold a fresh
token.

**The registry itself** is shared: `064859874041`, us-east-2. Repository policies grant pull
**and push** to any principal in the AWS Organization — 515 of 517 repositories. The on-prem
defence is **digest pinning**, enforced by policy, not trusting a tag.

## 8. Identity and access

| | How |
|---|---|
| **Human kubectl, QA** | AWS SSO through a self-hosted `aws-iam-authenticator`, live since 2026-07-28 |
| **Human kubectl, dev and prod** | client certificates, demoted to break-glass |
| **Argo CD sign-in** | Entra OIDC, live on all three clusters since 2026-08-25 |

⚠️ **The Entra `groups` claim never arrives; application roles do.** `policy.csv` subjects
must be the **role values**, with scopes `[roles, groups]`. A login that succeeds and lands on
an empty Applications list is an authorisation problem, not a broken sign-in.

⚠️ **One Entra app registration is shared across dev, QA and prod** (client id `e112d6ce…`);
only the redirect URI differs. A new environment is a URI addition, and the secret is a
**copy** — not a new identity request.

⚠️ **`onprem-platform-admins` is a Kubernetes and aws-auth name, never a directory group.**
Argo CD uses `usx-cloud-admin`. Identity names do not cross systems.

## 9. Certificates, policy, storage, backup

* **cert-manager reporting `Ready: True` is not a valid certificate.** op-dev served an
  **expired** certificate on every hostname for 41 days while everything was green.
  `.status.notAfter` is the only answer, and `curl -k` hides it — use
  `%{ssl_verify_result}`: 0 trusted, 10 expired.
* **Kyverno** enforces the registry and digest rules, and **refuses an unpinned tag** — which
  also means a debug pod needs a digest.
* **Storage:** `local-path` PVCs are in use. Rook-Ceph was stood up under INFRA-1532.
  ⚠️ **current state unverified.**
* **Velero** handles backup. ⚠️ Its Flux directory **enumerates** its resources, so a file
  dropped in without being listed in `kustomization.yaml` is silently ignored.
* **Alerting was dead for four separate reasons in series** — fixed on dev and QA on
  2026-08-24. ⚠️ **prod still pending.**

## 10. The traps, collected

| Trap | Why it bites |
|---|---|
| `TfApply=false` | a green Octopus deploy printed a plan and applied nothing |
| `[ALL]`-scoped Octopus variables | invisible to anything copying scoped values |
| A release's frozen variable snapshot | the fix never reaches the existing release |
| `flux reconcile source git flux-system` | reconciles the **cluster** repo and prints success for the platform one |
| Bare `dev`/`qa`/`prod` branches beside `op-*` | GitHub offers the wrong base; a push to `qa/...` is rejected outright |
| Manifests copied between platform branches | arrive carrying the wrong environment's identifiers |
| A copied VirtualService | external-dns obeys it exactly, and nothing reports the mistake |
| Resolving an `usxpress.io` name to test existence | caches the negative answer for 24 hours |
| A green `ExternalSecret` | writes partial content and kills the pod with 0 restarts |
| `cert-manager` `Ready: True` | served an expired certificate for 41 days |
| Transit gateway route table `[0]` | may not be the table that VPC actually uses |
| Istio gateway pods | carry neither `curl` nor `getent`; most platform images are distroless. **Grafana has curl** |

## 11. What is not measured, and how to measure it

Run on WSL. Read-only.

```bash
KQ=$HOME/.kube/op-usxpress-qa-sso.yaml
kubectl --kubeconfig=$KQ get --raw /version | head -c 200; echo
kubectl --kubeconfig=$KQ get nodes -o wide --no-headers | awk '{print $1"  "$5"  "$8}'
```

```bash
kubectl --kubeconfig=$KQ get pods -A --no-headers | awk '{print $1}' | sort | uniq -c | sort -rn
```

```bash
kubectl --kubeconfig=$KQ get kustomizations -A --no-headers 2>/dev/null | head -30
kubectl --kubeconfig=$KQ get helmreleases -A --no-headers 2>/dev/null | head -30
```

The first gives the Kubernetes version and each node's OS image, which is the Talos version.
The second lists every namespace with a pod count, which settles what is actually installed.
The third names each Flux component and whether it is Ready.

## Proven

* Three clusters, all nodes in **10.10.82.0/24**, pod network **10.244.0.0/16**.
* The clusters are built by **Terraform through Octopus**, and their full specification lives
  in **121 Octopus variables held in a web form, in no repository**.
* Flux reads **two** repositories; the cluster repo supplies the wiring, the platform repo the
  content, and reconciling the first does not reconcile the second.
* **The datacenter and AWS are already joined** by a transit gateway with a live VPN, and all
  eight route tables carry the datacenter's range.
* **Egress to the public internet works** from a pod, with the public CA bundle trusted.
* Argo CD SSO works through Entra **app roles**; the groups claim never arrives.

## Tested and killed

* **"On-prem and AWS only meet over the public internet."** Disproven by tracing the transit
  gateway — a live VPN attachment advertises the datacenter's range into every route table.
* **"Prove it on dev first" for Flux behaviour.** Dev runs a newer Flux than QA and prod.

## Not measured

**dev** — it is the only cluster not measured. Also: whether prod's alerting was ever
completed; the dev and prod `op-*-platform-admin` IAM fixes; whether the Wiz sensor is still
running; and whether any certificate is expired behind a Ready status on any cluster.

## The finding that outranks everything else here

**Kubernetes 1.32 left support in February 2026, and both op-qa and op-prod run v1.32.0.** An upgrade is
control-plane work on three clusters with no written Talos upgrade path, so it is
sprint-sized on its own — larger than the human-access work that prompted the measurement.
