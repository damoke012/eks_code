# Making op-usxpress-prod production-ready — Sprint 7

**2026-10-20.** The sprint ask is **AWS SSO on prod**, plus everything else prod needs to be
genuinely production-ready.

**Published page:** https://claude.ai/artifact/PtHGTNEjhcrEaYpJRrcJHS
("Prod Readiness Plan" — plain language, with the order-of-work diagram)

**The shape of the work:** QA already has all of this and it is written down. So this is a
**delta against QA**, not a design — and QA is the right reference because it holds the
proven configuration ([[compare-against-the-governed-env]]).

⚠️ **Most of the gap list below comes from notes between six and twelve weeks old.** Three of
them have been wrong before. **Measure first** (§5), then size the work.

---

## 1. AWS SSO on prod — ⚠️ MEASURED 2026-10-20: three of seven pieces are already done

**Correction to everything below.** The original delta assumed prod had none of this. It has
most of it:

| Piece | Where it lives | op-qa | op-prod |
|---|---|---|---|
| `aws-iam-authenticator` DaemonSet | Flux, platform repo | ✅ 3/3 ready | ✅ **3/3 ready** |
| `aws-auth` ConfigMap | Flux, platform repo | ✅ admin tier only | ✅ **admin tier only** |
| Three ClusterRoleBindings | Flux, platform repo | ✅ | ✅ |
| **kube-apiserver webhook flag** | **Terraform, via Octopus** | ✅ | ⛔ **absent — the one real gap** |

**The split is the repository boundary.** Everything in the platform **Git** repo was copied
to the `op-prod` branch and reconciled. The piece that lives in **Terraform** was applied to
QA only, because it is enabled by an Octopus variable that was never scoped to production.

**This shrinks the risky step rather than removing it.** The documented hazard is that the API
server will not start if the webhook file is missing — and the DaemonSet that writes it has
been running 3/3 on prod for some time. The prerequisite is **already satisfied**. Verify the
file on each control-plane node anyway (a Ready pod is not a written file), then land the
flag.

**The prod admin role already exists:**
`arn:aws:iam::937464026810:role/AWSReservedSSO_usx-on-prem-admins_837df2a43495aaf1` — that
suffix cannot be invented, so the permission set was created. **Who is assigned to it is
unknown.**

### ⛔ New defect found by the same check — and it affects QA too

**Four of six `aws-auth` mappings name a role that cannot exist**, because the ARN contains a
literal placeholder:

| Cluster | operator | reader |
|---|---|---|
| op-qa | `…op-qa-platform-operator_<FILL>` | `…op-qa-platform-reader_<FILL>` |
| op-prod | `…usx-on-prem-operators_FILL_FROM_LIST_ROLES` | `…usx-on-prem-readers_FILL_FROM_LIST_ROLES` |

**Only the admin tier works, on either cluster.** An operator or reader would authenticate and
arrive with no groups — which presents as "SSO is broken" and is an unfinished mapping. It has
been this way for months and nobody noticed, because only admins have used it.

**One line would have caught it:** grep the rendered `aws-auth` for `FILL`, `<`, `TBD` or
`CHANGEME` and fail.

⚠️ **And it is worse than a lookup.** Listing the SSO roles in both accounts on 2026-10-20
returned **no operator or reader permission set in either one**:

| Account | Matching roles |
|---|---|
| 527101283767 (QA) | `op-qa-platform-admin_f8b5c3ff8895fdf6`, `usx-on-prem-admins_8c7f139e431625e0` |
| 937464026810 (prod) | `usx-on-prem-admins_837df2a43495aaf1` |

So the two broken tiers cannot be fixed by substitution — **the permission sets must be
created and assigned in Identity Center first**. Console work, and its own ticket.

⚠️ **QA carries a second admin role it does not map.** `usx-on-prem-admins` exists in the QA
account too, but QA's `aws-auth` maps only `op-qa-platform-admin`. Anyone granted the former
on QA lands with no groups. QA looks mid-rename toward the `usx-on-prem-*` scheme and the map
was never finished.

✅ **Prod's admin mapping is exact** — the ARN in `aws-auth` matches a role that exists, suffix
and all. **Prod admin sign-in works the moment the API server flag is on, with no AWS work.**

---

## 1c. Re-measured on op-prod 2026-10-26 — the gap narrowed to one flag

Read live from `op-usxpress-prod` (10.10.82.52:6443), read-only:

| Check | Result | Reading |
|---|---|---|
| `aws-iam-authenticator` DaemonSet | **3/3 ready, 62 days old**, nodeSelector `control-plane` | prerequisite's writer is in place |
| kube-apiserver `--authentication-token-webhook-*` | **ABSENT** | the gap is real, as recorded |
| `cnp/allow-corp-vpn-to-ingressgateway` ingress[0] | **22 CIDRs** | ✅ office access on prod is **already fixed** |
| webhook kubeconfig on each control-plane node | **NOT MEASURED** | the container has no `ls` |

✅ **One row of §2 closes itself.** Prod carries the same 22 CIDRs as dev and QA, so the
office-access promotion is done. The PR reference was never recorded — find it before
closing INFRA-1730.

⛔ **And the prerequisite check failed as an instrument, not as a finding.** `kubectl exec`
into all three authenticator pods returned:

    exec: "ls": executable file not found in $PATH

The image is distroless. **This is not evidence the file is missing** — it is evidence the
check cannot run this way ([[transport-failure-not-a-verdict]], and the fourth instance of
an absent binary reading as a system fault in one week: `wget` in the RisingWave console,
`kustomize`/`dig`/`flux` on WSL, now `ls` here).

`kubectl debug` would answer it and is **forbidden on prod** (CLAUDE.md rule 3). The
remaining routes are `talosctl list` against each control-plane node — Talos's own
read-only API — or the authenticator's own log line `writing webhook kubeconfig file`,
which is a proxy for the write and not for the file's presence now.

### ✅ The prerequisite check is PROVEN on QA — 2026-10-26

`scripts/check-authenticator-webhook-file.sh qa` returned PASS on all three
control-plane nodes:

| Node | File | Size | Written |
|---|---|---|---|
| 10.10.82.25 | `kubeconfig.yaml` | 1909 | Jul 28 22:47:32 |
| 10.10.82.24 | `kubeconfig.yaml` | 1909 | Jul 28 22:46:25 |
| 10.10.82.177 | `kubeconfig.yaml` | 1909 | Jul 28 22:46:59 |

**Why this matters more than the result itself.** QA is the positive control: it
already carries the apiserver flag with a healthy API server, so the file MUST be
there. It is, at identical size on all three nodes, timestamped within 67 seconds of
each other on **the day QA's SSO went live**. So the method reads the real host
filesystem — and prod's answer, whatever it is, can be believed.

### ✅ AND PROD PASSES — 2026-10-26

| Node | File | Size | Written |
|---|---|---|---|
| 10.10.82.187 | `kubeconfig.yaml` | 1909 | Aug 24 16:20:52 |
| 10.10.82.186 | `kubeconfig.yaml` | 1909 | Aug 24 16:20:52 |
| 10.10.82.188 | `kubeconfig.yaml` | 1909 | Aug 24 16:20:51 |

**Six nodes across two clusters, all 1909 bytes.** Prod's timestamps match the
DaemonSet's 62-day age. **The prerequisite for the apiserver flag is MET** and the
dangerous step is safe to attempt. INFRA-1661 is now only the Octopus variable, the
release snapshot and a watched node-by-node rollout.

⚠️ **THREE profiles are configured for account 937464026810** — `ops-controller`,
`usx-prod`, `op-prod` — and they are different permission sets, not aliases.
`op-prod` is `op-prod-platform-admin`, which holds only `sts:GetCallerIdentity`: it
authenticates and is then refused the talosconfig. **`ops-controller` is the one that
can read it.**

So "the first profile that resolves to the account" is a coin toss decided by the
order of `~/.aws/config`, and `breakglass-prod-kubeconfig.sh` had exactly that bug —
it would have died on a bare AccessDeniedException partway through stage 2. Both
scripts now resolve by **capability**: the first profile that can perform the read.
Authentication is not authorisation.

⚠️ **The check's own first version collapsed three faults into one message** ("no
configured profile resolves to the account"), which cannot distinguish an unconfigured
profile from an expired session — and only one of those is fixed by logging in. Fixed
by reading `sso_account_id` from `~/.aws/config`, which needs no session.

## 1b. The original delta, for reference

## 1. AWS SSO on prod — the delta

QA went live 2026-07-28 and the account is in
`wip/onprem-qa-access/aws-sso-webhook/FINDINGS-2026-07-28.md`. Result there:
`kubectl auth whoami` → `sso:doke@usxpress.com`, groups `[onprem-platform-admins
system:authenticated]`, no certificate involved.

Seven pieces. Five are copies of QA's; two are prod-specific.

| # | Piece | Where it lands | Prod-specific? |
|---|---|---|---|
| 1 | `aws-iam-authenticator` DaemonSet on the control plane | Flux, `iaac-talos-flux-platform` branch **`op-prod`** | copy of QA's, with prod's cluster id |
| 2 | Its server RBAC | same | copy |
| 3 | `kube-system/aws-auth` mapping the SSO role ARN → `onprem-platform-admins` | same | **the role ARN is prod's** |
| 4 | The three group-keyed ClusterRoleBindings | same (`wip/onprem-qa-access/rbac/`) | copy |
| 5 | **kube-apiserver webhook flag + hostPath volume** | **the Terraform module, deployed by Octopus** | copy, but see the risk below |
| 6 | `TF_VAR_enable_aws_iam_authenticator = true` scoped to **production** | **an Octopus project variable** | **yes** |
| 7 | An AWS SSO permission set in **937464026810**, assigned to the people who need it | AWS Identity Center | **yes** |

### ⛔ The one genuinely dangerous step

**`kube-apiserver will not start if the webhook config file does not exist.** The flag in
piece 5 names `/var/lib/aws-iam-authenticator/kubeconfig.yaml`, and the DaemonSet in piece 1
is what writes it — on **every** control-plane node.

So the order is not a preference:

1. Land the DaemonSet. **Verify the file exists on all three control-plane nodes.**
2. Only then land the apiserver flag, and watch the control plane roll **node by node**.
3. Keep the break-glass certificate kubeconfig **open in another terminal** throughout.

The safety property that makes this survivable: the flag needs the **file**, not a running
authenticator. If the authenticator is down, webhook authentication fails and **x509 still
works** — the certificate kubeconfig remains a way in. That is the escape hatch, and it only
exists if someone is already holding it.

**This needs a change window on prod.** It touches the control plane of a production cluster.

### Three traps QA already paid for

* **`TfApply` is `true` for production** (it is `false` for everything else). So a prod
  Octopus deploy **applies for real** — the opposite of the QA trap, and worth saying out loud
  before someone deploys to "see the plan".
* **Git tfvars are not what deploys read.** `enable_aws_iam_authenticator = true` in
  `deploy/terraform/envs/*.tfvars` was never read on QA; Octopus injects `TF_VAR_*` as
  `env.auto.tfvars` and `-var-file` is not used. Piece 6 is an **Octopus variable**, not a
  file in Git.
* **A release pins a variable snapshot.** Adding the variable does not reach an existing
  release — refresh it, or deploy a new one. Otherwise the deploy is another silent no-op.

---

## 2. What else "production-ready" means

Grouped by the question each answers. Every row is **recorded, not re-measured** — §5 first.

### Can we get in, and can we get back in?

| | State | Work |
|---|---|---|
| Human access by SSO | ❌ prod is certificates only | §1 |
| Break-glass certificate path | ✅ exists, rebuildable from the talosconfig | document it where someone panicking will find it |
| `op-prod-platform-admin` IAM role | ⚠️ held **only** `sts:GetCallerIdentity` — could not write its own secrets. **QA fixed 2026-08-25; prod never was** | copy QA's policy |

### Will we know when it breaks?

| | State | Work |
|---|---|---|
| Alerting actually delivered | ⛔ **CORRECTED 2026-10-26 — this row conflated two tickets.** What was fixed on dev+QA is **INFRA-1657**, making the Flux rules *able to fire*; prod is pending and that half IS a copy (PRs #114-#122). **Delivery itself — INFRA-1659 — is open on ALL THREE clusters**: measured 2026-10-05, zero Alertmanager and zero Flux notification Providers/Alerts on dev, QA and prod. There is no proven fix to copy | copy INFRA-1657 to `op-prod`; **build** INFRA-1659 |
| Dashboards | ✅ Grafana runs | confirm the prod data sources resolve |
| Log retention | ⚠️ unknown on-prem, and unknown in cloud too | decide it; nobody owns it today |

✅ **INFRA-1659's missing input arrived on 2026-10-26.** It was recorded as "a design
decision, not a values change", and the RisingWave sync made that decision: dedicated Teams
channels for prod and non-prod, filtered by namespace in Grafana, SLO defined first and
low-noise by design, app and platform sharing one channel until QA and prod then splitting.
So the blocker on 1659 is no longer a decision — it is build work.

⚠️ **And triage the backlog before switching delivery on.** 22 alerts are firing on QA, eight
for over a week, and several are Talos static-pod false positives. Delivering two months of
unreviewed backlog on day one teaches everyone to mute the channel.

🔴 **Found inside that record and still open: QA's etcd backups are failing** —
`EtcdSnapshotJobFailing` x5 and `KubeJobFailed` x5 in `etcd-backup`, undetected purely
because nothing delivers. That is a live data-loss exposure on the cluster running
RisingWave, and it outranks prod's alerting work. **Prod's snapshot state is unmeasured.**

### Can we recover it?

| | State | Work |
|---|---|---|
| Velero backup | ⚠️ installed; **never restore-tested on prod** | a restore test is the only proof a backup exists |
| etcd snapshots | ⚠️ QA's were stale for weeks behind a **green** ExternalSecret with an empty value | check prod's snapshot age and the secret's content, not its status |
| Rebuild from scratch | ⚠️ **never proven end to end** — prod was the first real teardown→rebuild attempt | out of scope this sprint; name it |

### Is it safe?

| | State | Work |
|---|---|---|
| Certificates actually valid | ⚠️ unverified. op-dev served **expired** certificates on every hostname for 41 days while reporting Ready | read `.status.notAfter`, not Ready |
| Duplicate resource declarations | ⚠️ the RisingWave object store is declared in **two** Terraform projects. A destroy in the wrong one deletes the bucket | resolve the duplicate before any prod Terraform work |
| Image policy | ✅ Kyverno enforces registry and digest | confirm it is enforcing, not auditing, on prod |
| Argo CD prod sync | ✅ manual only — correct for prod | leave it |

### Is it current?

| | State | Work |
|---|---|---|
| Flux | ⚠️ prod on **v2.7.5**, dev on **v2.8.8** | decide whether to align; dev is ahead, so dev is not a valid rehearsal for Flux behaviour |
| Kubernetes version | ⛔ **op-qa measured 2026-10-20: `v1.32.0`. Upstream support ended 2026-02-28** and the line's final patch was 1.32.13 — so it is the initial release of a dead line, never patched. Self-managed, so no extended support exists. **prod measured 2026-10-20: identical** | **its own sprint.** Control-plane work on three clusters, no written Talos upgrade path |
| RisingWave console version | ⚠️ displays a stale version on prod | cosmetic; low priority |

---

## 2b. Measured 2026-10-20 — prod is not missing anything

`op-usxpress-prod` returns **the same pod count as QA in 19 of 20 namespaces**, the same
13-node layout and the same Kubernetes version. The only difference is `risingwave`: 14 pods
against 13.

**So "is prod production-ready" is not a question about missing components.** Everything QA
has, prod has, in the same quantity. What remains is **configuration and behaviour** — whether
alerts are routed, whether an IAM role can write, how humans authenticate, and what version is
running. That deletes a whole category of imagined work from this plan.

⚠️ **And one hint worth chasing before sizing the SSO work:** `kube-system` is **32 pods on
both clusters**, and QA's `aws-iam-authenticator` DaemonSet lives in `kube-system`. If QA's
authenticator pods are inside that 32 and prod matches it, **prod may already be running the
authenticator** — leaving only the apiserver flag, the role mapping and the permission set.
Equal counts are a hint, never a finding:

```bash
for K in op-usxpress-qa-sso op-usxpress-prod; do echo "== $K"; \
  kubectl --kubeconfig=$HOME/.kube/$K.yaml -n kube-system get ds,deploy -o name | grep -i auth \
  || echo "   none"; done
```

## 3. What I would do in this sprint

1. **Measure (§5).** Half a day. Several rows above may already be closed, and two of these
   notes have been wrong before.
2. **AWS SSO on prod** — the ask. The Flux half is low-risk and can land first; the apiserver
   half needs a window.
3. **The prod IAM role fix** — small, isolated, and it is the thing that will silently break
   secret delivery later.
4. **Alerting on prod** — the same change already proven on dev and QA. Without it, everything
   else in this list is unobservable.
5. **A Velero restore test** — the only thing that converts "we have backups" into a fact.

Items 3 and 4 are copies of changes already proven in another environment, which makes them
the cheapest real risk reduction available.

**Explicitly not this sprint:** the rebuild-from-scratch proof, Flux alignment, log retention
policy. Each deserves its own ticket.

⛔ **And one that may outrank the whole list: the Kubernetes version.** op-qa runs v1.32.0,
out of upstream support since 2026-02-28. It cannot be a task inside this sprint — it is
control-plane work on three clusters with no written Talos upgrade path — but a cluster
eight months past end of life is a harder answer to "is it production-ready" than anything
else here. **Raise it as its own piece of work before this sprint's scope is agreed.**

---

## 4. The order, and why

```
measure  ─►  SSO: Flux half (DaemonSet, RBAC, aws-auth)
                      │
                      ├─► verify the file on all 3 control-plane nodes
                      │
                      └─►  SSO: apiserver flag   ◄── change window, break-glass open
                                   │
   IAM role fix ──┬── alerting ────┴──►  Velero restore test
                  │
                  └── (independent of SSO, can run in parallel)
```

The IAM fix and alerting do not touch the control plane and can proceed alongside. The
apiserver change is the only step that can take prod down, and it is the only one that needs
a window.

---

## 5. Measure first — read-only

**bash on WSL.** Nothing below changes anything.

```bash
KP=$HOME/.kube/op-usxpress-prod.yaml
kubectl --kubeconfig=$KP get --raw /version | head -c 200; echo
kubectl --kubeconfig=$KP get nodes -o wide --no-headers | awk '{print $1"  "$5"  "$8}'
```

```bash
kubectl --kubeconfig=$KP -n kube-system get ds,deploy -o name | grep -i auth || echo "NO authenticator on prod"
kubectl --kubeconfig=$KP -n kube-system get cm aws-auth -o yaml 2>&1 | head -20
```

```bash
kubectl --kubeconfig=$KP get pods -A --no-headers | awk '{print $1}' | sort | uniq -c | sort -rn | head -20
```

```bash
kubectl --kubeconfig=$KP get certificate -A -o custom-columns=NS:.metadata.namespace,N:.metadata.name,READY:.status.conditions[0].status,EXPIRES:.status.notAfter
```

```bash
kubectl --kubeconfig=$KP get externalsecrets -A -o custom-columns=NS:.metadata.namespace,N:.metadata.name,READY:.status.conditions[0].status | head -20
```

What each settles: the Kubernetes and Talos versions; whether any authenticator already
exists; what is actually installed; whether any certificate is expiring or expired behind a
Ready status; and whether secret delivery is healthy.

⚠️ **Prod access is certificate-based today**, so this needs the prod kubeconfig — which is
rebuildable from the talosconfig if it has drifted.

---

## Proven

* QA's AWS SSO implementation works and is fully documented, including what went wrong.
* The pieces are five copies and two prod-specific values.
* `TfApply` is **true** for production — a prod Octopus deploy applies for real.
* Octopus variables, not Git tfvars, are what a deploy reads.

## Traps

* **The apiserver flag without the file is a control-plane outage.** DaemonSet first, verified
  on every control-plane node, then the flag, with break-glass open.
* **A hand-applied `talosctl patch` is drift** and the next Octopus deploy reverts it. The
  change belongs in the Terraform module.
* **A release pins its variable snapshot** — adding a variable does not reach an existing one.
* **Everything in §2 is recorded, not measured.** Two of these notes have been wrong before.
