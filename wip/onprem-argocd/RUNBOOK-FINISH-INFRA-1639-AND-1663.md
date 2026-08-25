# Finishing INFRA-1639 (Argo SSO) and INFRA-1663 (prod ingress) — 2026-08-25

Everything below runs **on WSL**, where the platform repo (`~/pr-work/iaac-talos-flux-platform`),
`az`, `aws` and the kubeconfigs live. Nothing in this file runs from the codespace.

Steps are in dependency order. Step 3 is the one that may end the SSO blocker outright,
and it is cheap — do it early even if prod ingress is still moving.

---

## 0. Rotate the Atlassian API token — blocks every ticket action below

The token pasted earlier this month is still in a session transcript. Nothing else here
depends on it, but no ticket can be filed, split or closed until it is replaced.

https://id.atlassian.com/manage-profile/security/api-tokens — revoke, create, store.

---

## 1. op-prod ingress: the ACME solver zone (INFRA-1663)

The Gateway and Certificate now name op-prod (PR #137, merged). Two things still stand
between that and a working certificate. cert-manager's IRSA was the first and is **already
fixed** — `rollout restart` on 2026-08-25 put `AWS_ROLE_ARN` and
`AWS_WEB_IDENTITY_TOKEN_FILE` into the pod. The second is unshipped:

`letsencrypt-prod` on the op-prod branch solves only for `op-qa.usxpress.io`, so an Order
for `*.op-prod.usxpress.io` matches **no solver** and cert-manager creates **zero**
Challenges. The script is written, fixed and never pushed.

```bash
# op-prod branch, platform repo on WSL
bash ~/eks_code/scripts/pr-cert-issuer-op-prod.sh
```

Read the diff. Exactly one thing should change: the `dnsZones` list item, `op-qa.usxpress.io`
→ `op-prod.usxpress.io`. The cross-account `iaac-route53-zone` role (account 155768531003)
must be **untouched** — it is shared, not per-cluster — and no comment may be rewritten.
The script asserts both, after an earlier version corrupted a comment into
`(op-prod, op-prod) get their own selector blocks`.

```bash
bash ~/eks_code/scripts/pr-cert-issuer-op-prod.sh --push
```

Merge it, then watch for the milestone. **A Challenge existing at all has never happened on
this cluster** — that is the signal, before Ready:

```bash
kubectl --context op-usxpress-prod -n istio-ingress get challenges
kubectl --context op-usxpress-prod -n istio-ingress get certificate wildcard-op-prod
```

`READY=True` means op-prod can terminate HTTPS for its own hostnames for the first time
since the cluster came up 27 days ago.

## 2. Clear the dead QA leftovers on op-prod

These are copies of QA's, they can never issue on this cluster, and they retry forever.
**Prod mutation — yours to run, not mine.** Confirm the op-prod Certificate is Ready first,
so you are deleting the dead one and not the only one:

```bash
kubectl --context op-usxpress-prod -n istio-ingress delete certificate wildcard-op-qa
kubectl --context op-usxpress-prod -n istio-ingress delete secret wildcard-op-qa-k96jn
```

Then confirm `istio-ingress` finally reconciles, and `grafana` behind it:

```bash
kubectl --context op-usxpress-prod -n flux-system get kustomization istio-ingress grafana
```

`istio-ingress` has a **blank revision** — it has never successfully applied. A revision
appearing is the proof.

---

## 3. The `groups` claim — try the route we own before asking anyone

Entra emits no `groups` claim for `Argo CD On-Prem` under any setting tried. `roles` is a
different claim on a different issuance path — appRoleAssignments, not directory group
membership — so a tenant control that suppresses one need not touch the other. The whole
thing lives inside the app registration we created on 2026-08-25.

**Read first. This may end it in one command:**

```bash
az login --tenant bbb5a66d-5c9f-482a-969a-a40304b6bc8d
bash ~/eks_code/scripts/entra-argocd-app-roles.sh --inspect
```

Look at `optionalClaims` before anything else. If the `groups` claim carries
`additionalProperties: ["emit_as_roles"]`, then group values are being emitted **into the
`roles` claim on purpose** and there was never a missing claim — we have been reading the
wrong field. Skip to step 4 with the values you see.

Otherwise, define the roles and assign:

```bash
bash ~/eks_code/scripts/entra-argocd-app-roles.sh --define
bash ~/eks_code/scripts/entra-argocd-app-roles.sh --assign platform-admin b9a1ff74-efa1-4b20-be8a-8706a5ab2636
```

If that fails on a licence, assigning a **group** to an app role needs Entra ID P1.
Assigning yourself works on any tier and is enough to prove the claim arrives:

```bash
az ad signed-in-user show --query id --output tsv
# then, with the id that printed:
bash ~/eks_code/scripts/entra-argocd-app-roles.sh --assign platform-admin "$(az ad signed-in-user show --query id --output tsv)"
```

**Then prove it, and only this proves it:** sign out of Argo CD completely, sign in again
— a token minted before the change tests the old configuration, which has already cost
three runs — and read the claims:

```bash
bash ~/eks_code/scripts/argocd-token-claims.sh
```

`ROLES` present is the win. `GROUPS` may well still be absent; it stops mattering.

**In parallel, send the questionnaire** to whoever owns the tenant:
`wip/onprem-argocd/to-questionnaire-entra-groups-claim.md`. Question 1 — whether the cloud
fleet's Argo registration actually gets a groups claim today — is the control we do not
have, and may answer this on its own.

---

## 4. The application-team view

Needs one decision from Idris: **which Entra group is the RisingWave team**. Find it:

```bash
az ad group list --display-name 'RisingWave' \
  --query '[].{name:displayName,id:id,synced:onPremisesSyncEnabled}' --output table
```

Then, with the object ID that printed:

```bash
export RW_GROUP=00000000-0000-0000-0000-000000000000   # replace with the id from above
bash ~/eks_code/scripts/pr-argocd-rbac-app-viewer.sh --group "$RW_GROUP"
```

If step 3 landed on app roles instead of groups, the subject is the role value and the
script sets `scopes` to `[roles, groups]` for you:

```bash
bash ~/eks_code/scripts/entra-argocd-app-roles.sh --assign app-viewer "$RW_GROUP"
bash ~/eks_code/scripts/pr-argocd-rbac-app-viewer.sh --role-value app-viewer
```

Either way it grants, scoped to the `apps` AppProject and nothing else on the cluster:
`get` on applications and logs everywhere; `sync` on dev and QA; **no sync on prod** —
promotion to prod stays human-initiated by the platform, by design.

Dry run prints a full `git diff origin/<branch>` per cluster. Read all of it, including
lines you did not mean to change, then `--push`.

## 5. op-prod's Argo CD — blocked until step 1 lands

```bash
bash ~/eks_code/scripts/pr-argocd-entra-prod.sh
```

It refuses while `istio-ingress/shared-http` does not serve op-prod hostnames, which is
correct: the OIDC callback needs somewhere to land. It reads the route's gateway, DNS
targets and TLS wiring **from the live cluster**, never from the branch — every route on
the op-prod branch belongs to op-dev.

## 6. Sign in to op-qa in a browser

QA's login has only ever been verified with `curl` against `/api/v1/settings`. That proves
the config is served, not that a human can get in.

https://argocd.op-qa.usxpress.io

---

## 7. Then, and only then, the tickets

INFRA-1639 as written — "Argo CD SSO for application teams" — cannot close until an
application team member can see an Application. Split it:

* **INFRA-1639** narrows to *Entra OIDC authentication on op-dev / op-qa / op-prod*.
  Closes when step 5 merges. dev and QA are already done.
* **new** — *Argo CD authorisation: no subject claim reaches policy.csv*. Carries the
  ruled-out table so nobody repeats it. Closes when step 3 or the questionnaire resolves.
* **new** — *Application-team view in Argo CD (`role:app-viewer`)*. Blocked on the above
  and on Idris naming the group. Closes when step 4 merges and someone from the RW team
  confirms they can see `risingwave-etl`.
* **INFRA-1663** closes when step 1 and step 2 leave `istio-ingress` with a revision.

---

## Why the split, rather than closing 1639

The remaining blocker is a tenant-level claim behaviour owned by someone outside this
team. Holding the ticket open against that makes the sprint read as stalled on us, when
the authentication work is finished and provable on two clusters. The split states plainly
what we did, what we are waiting on, and who has it.
