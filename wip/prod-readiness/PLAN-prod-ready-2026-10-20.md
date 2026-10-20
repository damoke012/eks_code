# Making op-usxpress-prod production-ready — Sprint 7

**2026-10-20.** The sprint ask is **AWS SSO on prod**, plus everything else prod needs to be
genuinely production-ready.

**The shape of the work:** QA already has all of this and it is written down. So this is a
**delta against QA**, not a design — and QA is the right reference because it holds the
proven configuration ([[compare-against-the-governed-env]]).

⚠️ **Most of the gap list below comes from notes between six and twelve weeks old.** Three of
them have been wrong before. **Measure first** (§5), then size the work.

---

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
| Alerting actually delivered | ⚠️ dev and QA fixed 2026-08-24, **prod pending**. Rules fire into nothing | land the same fix on `op-prod` |
| Dashboards | ✅ Grafana runs | confirm the prod data sources resolve |
| Log retention | ⚠️ unknown on-prem, and unknown in cloud too | decide it; nobody owns it today |

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
| Kubernetes / Talos version | ❌ **not known on any on-prem cluster** | measure, then apply the N-1-and-support-window rule |
| RisingWave console version | ⚠️ displays a stale version on prod | cosmetic; low priority |

---

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
