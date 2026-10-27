# op-usxpress-prod: production readiness, measured 2026-10-27

All numbers below were measured today against the live clusters, not recalled.
Where a belief was disproven it is corrected in place rather than deleted.

## Landed today

**INFRA-1661 — AWS SSO on the prod API server. DONE, mechanism proven.**

* Release `0.5.0` deployed to Production 2026-10-27, 21 minutes, no incident.
* Both flags present on all three control-plane nodes:
  * `--authentication-token-webhook-config-file=/var/lib/aws-iam-authenticator/kubeconfig.yaml`
  * `--authentication-token-webhook-cache-ttl=2m0s`
* 13/13 nodes Ready afterwards. `kube-apiserver-talos-cp-op-prod-{1,2,3}` all Ready, 0 restarts.
* `[HEALTH] Waiting for istiod` burned its full 1200s and continued — the known defect, not a fault.

## The one thing blocking a human SSO login

Not a cluster problem. Measured in Identity Center (`usx-mgmt`, instance
`ssoins-7223eb10c0b8ac39`, store `d-90676260a8`):

| | permission set | assigned to |
|---|---|---|
| prod 937464026810 | `usx-on-prem-admins` | GROUP `usx-aws-admin` |
| qa 527101283767 | `op-qa-platform-admin` | **USER** doke@, **USER** ifagbemi@ |

`doke@usxpress.com` is in `usx-technology`, `usx-cloud-admin`,
`usx-technology-lead`, `usx-engineering` — **not** `usx-aws-admin`. So the login
fails with `GetRoleCredentials ForbiddenException`, which is Identity Center
refusing an unassigned principal, not the cluster refusing an unauthorised one.

⚠️ **Do not "make prod identical to QA" here.** Prod's group-based grant is the
better model; QA's two named-user grants are standing personal exceptions.
Recommended: assign `usx-on-prem-admins` to `usx-cloud-admin` on prod, and
migrate QA off per-user grants to the same group.

## The RisingWave blocker

`risingwave-onprem` Kustomization has been **Ready=False for 55 days** on prod.
Every other RW piece is healthy (`risingwave-operator` Ready,
`risingwave-routes` Ready). One Deployment holds it:

```
health check failed: stalled resources: [Deployment/risingwave/risingwave-console status: 'Failed']
```

**Root cause, measured:**

| | |
|---|---|
| strategy | `RollingUpdate` (maxSurge 25%, maxUnavailable 25%) |
| volume | PVC `risingwave-console-data`, **ReadWriteOnce**, ceph-block |
| old pod | `risingwave-console-5b678c59c4-lbzps` on `talos-wk-op-prod-platform-2`, Running since 2026-09-01 |
| new pod | `risingwave-console-6ffc5644d9-x4bmp` on `talos-wk-op-prod-platform-3`, **Pending since 2026-10-13** |

A ReadWriteOnce volume attaches to one node. RollingUpdate starts the new pod
before stopping the old one, the scheduler places it on a different node, and it
waits for a volume that is only released when the rollout completes — which it
cannot. Both ReplicaSets carry the **same image** (`v0.7.4`), so this was not an
upgrade; something merely triggered a rollout on 2026-10-13.

All five init containers show `started=false` — even `fix-data-dir`, a busybox
`mkdir`. Nothing ran. The pod never got as far as a container, which is the tell
that it is a volume problem and not a script problem. Events are long expired.

**Masked by `Available=True`:** the old pod keeps serving, so every dashboard
reads healthy. Related: [[helmrelease-ready-hides-failed-history]].

**Fix, two parts:**

1. `strategy: {type: Recreate}` on the console Deployment — PR to
   `iaac-risingwave-onprem`, all three environments.
2. The live object keeps its `rollingUpdate` block and the API rejects a
   Deployment carrying both, so a plain Flux apply fails. Needs `force: true`
   on the Kustomization or a one-time delete so Flux recreates it.
   Consequence: the console UI restarts. The RW cluster itself is untouched.

## Parity: prod vs QA, measured

Identical: 13 nodes each, same namespaces, all `v1.32.0`, IRSA role ARNs 0/7
wrong on both, 41 of 42 Kustomizations Ready on prod vs 42/42 on QA.

⛔ **Disproven today:** I expected prod to carry dev role ARNs in IRSA
annotations (platform branches are copies of one another). It does not — 0 of 7
wrong. [[manifests-copied-across-branches]] still holds for other fields but not
for these.

### Gaps, worst first

**1. Prod's Helm charts float; QA's are pinned.** Backwards.

| chart | QA | prod |
|---|---|---|
| external-secrets | `2.2.0` | `2.2.x` |
| grafana | `8.15.0` | `8.x` |
| keda | `2.19.0` | `2.19.x` |
| kyverno | `3.3.9` | `3.3.x` |
| prometheus-stack | `72.9.1` | `72.x` |
| velero | `8.7.2` | `8.x` |

Production is the only environment permitted to float, and it is the only one
that does. `grafana: 8.x` means a minor chart bump reaches prod unattended,
without ever being seen in QA. That inverts the promotion model.

**2. `argocd-apps` Kustomization exists on QA, not prod.** 41 vs 42.

**3. `risingwave-console.op-prod.usxpress.io` has no route.** QA serves 7
hostnames, prod 6; the console is the missing one — consistent with the
Deployment above.

## Not parity gaps — QA has these too, so copying QA will not fix them

* **No alert delivery on ANY cluster** (INFRA-1659). Prod fails silently.
* **No promotion gate for RisingWave**: every cluster tracks `branch: main` at
  5m, so merging **is** deploying to production.
* **Kubernetes 1.32 EOL** since 2026-02-28, never patched past `.0`, all three.
* **etcd restore never tested** on any cluster, though snapshots are proven.

## Not a problem

56 (qa) / 57 (prod) pods "not Running" are all `Succeeded` — completed Velero
kopia maintenance and Rook OSD prepare jobs. Hourly Velero backups are running
on prod across argocd, cert-manager, grafana, istio, kyverno, prometheus,
reloader, risingwave, rook-ceph and velero itself.

---

## The delivery chain, mapped (added after the RW console fix)

Chasing a three-line YAML change to production took us through five repos. The map, read from
op-usxpress-prod's own Flux objects — the only authoritative source, since the pin is in no
repo that names the application:

| GitRepository | repo | ref |
|---|---|---|
| `flux-system` | **`iaac-talos-flux-cluster`** | branch `master`, path `./clusters/op-usxpress-prod` |
| `infra` | `iaac-talos-flux-platform` | branch `op-prod` |
| `iaac-risingwave-onprem` | `iaac-risingwave-onprem` | **`tag: v0.11.3`** |
| `gateway-api-upstream` | kubernetes-sigs/gateway-api | `tag: v1.4.0` |

The pin is at `clusters/op-usxpress-prod/flux-system/infra.yaml`, in a 700+ line monolith
holding every GitRepository and Kustomization for the cluster. `iaac-talos-flux-cluster` is
path-based on one branch, so a PR there moves ONE cluster without touching the others.

**Delivery is four steps; three are invisible from the PR:**

```
merge to main  ->  a tag is cut  ->  SOMEONE EDITS THE PIN  ->  Flux reconciles
```

That is why merging PR #61 looked like it should have fixed prod and did not.

## Proven

* **INFRA-1661's mechanism is live on production.** Both apiserver webhook flags on all three
  control planes, 13/13 nodes Ready, 3 apiserver pods Ready with 0 restarts, deploy clean in
  21 minutes.
* **The RW console failure is a RollingUpdate/ReadWriteOnce deadlock**, not a crash. Old pod
  Running on platform-2 since 2026-09-01, replacement Pending on platform-3 since 2026-10-13,
  all five init containers unstarted. Fixed by PR #61, tagged `v0.13.3`.
* **QA already carried the fix** (`strategy: {type: Recreate}`, with a comment saying why) and
  its live Deployment shows `{"type":"Recreate"}` with no `rollingUpdate` block — so applying
  it needs no `force: true` and no manual delete.
* **Prod ran `v0.11.3` while main was at `v0.13.3`** — six merged, tagged commits on no
  cluster, every Flux object green.
* **For prod, those two minor versions carry exactly three lines** (`git diff --stat
  v0.11.3..origin/main -- manifests/op-usxpress-prod/`). QA's section is empty.
* **Prod's SSO is blocked on group membership, not on anything in Kubernetes.** The role
  exists, aws-auth maps it, the permission set is assigned — to `usx-aws-admin`, which the
  platform team is not in.
* **IRSA role ARNs are correct on both clusters**, 0 of 7 wrong.
* **The 56/57 "not Running" pods are all `Succeeded`** — Velero kopia maintenance and Rook OSD
  prepare jobs. Hourly Velero backups run on prod across ten namespaces.

## Tested and killed

* ⛔ **"Prod carries dev role ARNs in IRSA annotations."** Predicted from
  [[manifests-copied-across-branches]]; measured 0 of 7 wrong on both clusters.
* ⛔ **"RisingWave has no promotion gate; merging deploys straight to prod."** Said twice.
  False for the manifests — they are tag-pinned per cluster. The belief came from
  `risingwave-routes`, which genuinely is branch-tracking. Two Kustomizations, two models.
* ⛔ **"The webhook kubeconfig is ABSENT on prod."** The node was unreachable; a dead VPN.
* ⛔ **"No signed-in profile has `usx-on-prem-admins`, so it is a permission-set problem."**
  `op-prod` is configured for exactly that role; nobody had logged into it.
* ⛔ **"No permission set named `usx-on-prem-admins` exists in this Identity Center."** The
  lookup had passed a two-line string as the instance ARN and never queried the directory.
* ⛔ **"The merge did not tag, because the commit lacks a conventional prefix."** It tagged
  `v0.13.3` regardless.

## Traps

* **A failure arrives dressed as a finding.** Four times today: a dead VPN read as a missing
  file, a wrong kubeconfig read as an unreadable cluster, an unused profile read as a missing
  grant, a malformed ARN read as an empty directory. Each would have sent us somewhere wrong.
  Every one was fixed in the instrument, not worked around.
* **A green Kustomization means the PINNED revision applied**, not that your change is there.
* **Compare tags with `sort -V`.** Lexically `v0.9.0` beats `v0.13.3`.
* **`Available=True` survives a permanently stuck rollout** when the old pod keeps serving.
* **Prod is NOT to be made identical to QA** on two counts: QA pins Helm charts where prod
  floats (prod is worse), and QA grants cluster access to named users where prod uses a group
  (QA is worse). Copying either direction blindly degrades something.

---

## Outcome, same day

**`risingwave-onprem` on op-usxpress-prod: `v0.13.3@299c64f` Ready=True at 18:34:59Z.**
First time Ready since early September.

Delivered, in order:

| | |
|---|---|
| PR #61 `iaac-risingwave-onprem` | `strategy: {type: Recreate}` on dev and prod consoles; tagged `v0.13.3` |
| dev | live field repaired, applied `299c64f`, all pods healthy |
| PR #49 `iaac-talos-flux-cluster` | QA pin `v0.11.3` → `v0.13.3`; no pod disturbed, as predicted |
| PR #50 `iaac-talos-flux-cluster` | prod pin `v0.11.3` → `v0.13.3` |
| prod | live field repaired AFTER the pin moved; console rolled, Kustomization Ready |

All three clusters now on the same tag for the first time since 2026-10-13.

**The ordering correction is the finding worth keeping.** The first prod repair was reverted
within minutes by a reconcile of the old pinned manifest — `managedFields` showed
`kustomize-controller Apply` and `kube-controller-manager Update` in the same second. The
repair only holds once the pin already carries the fix. Recorded in
[[server-side-apply-keeps-dropped-fields]].

## Still open after today

* **prod SSO login** — Identity Center group membership, not a cluster problem
* **prod's Helm charts float** on `.x` while QA pins exact versions
* **`Terraform Validate`** in `iaac-risingwave-onprem` points at `terraform/`; the code is in
  `deploy/terraform/`. It has never passed on any PR — a permanently red required check
* **`dpl`** Octopus environment fails every PR and has been Failed in `iaac-talos` since March
* **QA's console has 18 restarts**, last 12 days ago, noticed by nobody
* **`fix-data-dir` violates PodSecurity restricted** (runAsUser=0) on every cluster — a
  warning today, a scheduling failure if that policy ever enforces
* **`argocd-apps`** on QA, absent on prod
* **No alert delivery anywhere** — the thread running through every item above

---

## Velero on prod, measured 2026-10-27 evening

**The RisingWave backups were never broken.** `rw-prod-status.sh` gate 7 reported "no COMPLETED
risingwave backup yet" while 29 days of six-hourly backups sat there `Completed` with zero
errors. The gate ran `awk '$2=="Completed"'` over `kubectl get backups --no-headers`, which on
these clusters prints only NAME and AGE — so it was comparing `13h`, `93m` and `29d` against
`Completed`. It could never have passed on any cluster. Fixed to read `.status.phase` by name.

**The real finding, which that gate never looked at:** `velero-daily-full` has been
**PartiallyFailed every night since at least 2026-10-14** — 14 consecutive days.

```
phase: PartiallyFailed   errors: 3   warnings: 101   items: 4549/4549
error="daemonset pod not found in running state in node talos-cp-op-prod-{1,2,3}"
name=ztunnel-{p6wwp,jh2cb,97lsc}
```

Three errors, three control planes, one `ztunnel` pod each. Velero's node-agent DaemonSet does
not run on control-plane nodes (deliberately — see the Wiz CP exclusion), so there is no agent
to file-system-backup the ztunnel pods scheduled there.

**Not data loss.** ztunnel is Istio's stateless node proxy; it is recreated on restore. All
4549 items are backed up.

**The consequence is the problem.** `PartiallyFailed` is now the normal nightly state of
prod's whole-cluster backup, so a genuine failure is indistinguishable from the standing one.
Fix by excluding those volumes from the backup so `Completed` means something again.

⚠️ Note what made this findable: the RisingWave namespace backup completes four times a day.
Any dashboard showing "RisingWave backups: healthy" was true and irrelevant. The broken thing
was one row above it. [[adjacent-step-green-signals]]

## Four permanently-failing signals found today

Each one trains a reader to ignore it, and each hides whatever fails next:

| signal | state | since |
|---|---|---|
| `velero-daily-full` | PartiallyFailed nightly | ≥ 2026-10-14 |
| `Terraform Validate` (iaac-risingwave-onprem) | fails on every PR — wrong working-directory | unknown |
| `dpl` Octopus deploy | fails on every PR; also Failed in iaac-talos since 2026-03-30 | ≥ 7 months |
| `rw-prod-status.sh` gate 7 | could never pass — tested the AGE column | since written |

The last one was ours. The other three are not, and all four have the same effect.

---

## The security finding, found and closed the same day

**RisingWave answered `psql -U root` with an empty password on every node of all three
clusters** — 106 node/port pairs. Raised by Idris Fagbemi from dev and QA; confirmed on
op-usxpress-prod once the SSO kubeconfig from INFRA-1661 existed to test it.

Closed by `v0.13.4` (PR #62, the `-ext` services → ClusterIP) plus the pin promotion
(PR #51), verified by probe at 20:35Z on dev, QA, two prod workers and a prod control plane:
all `Connection refused`. Full detail in [[risingwave-nodeport-unauthenticated]].

**Two things this changes about the rest of this document.**

The prod-readiness list above is hygiene — floating charts, a cosmetic backup failure, a
missing hostname. None of it was the most serious thing on the estate, and none of it would
ever have surfaced this. It took someone outside the list looking at something nobody had
asked about.

And it is the same shape as everything else found today: **a control that was never wrong,
guarding a door the traffic did not use.** The CiliumNetworkPolicy restricting corp VLANs to
the ingressgateway works exactly as designed. A NodePort does not pass through the
ingressgateway.

**The access work paid for itself within hours.** Idris could not confirm prod because he had
no prod kubeconfig. The SSO login delivered that morning is what turned "likely prod" into a
measurement — and then into a fix.
