# How Argo CD is deployed on-prem, and what to copy for cloud

**Written for Parul**, to compare against the Argo CD deployment on EKS. Everything here is
measured on the three on-prem Talos clusters (`op-dev`, `op-qa`, `op-prod`) between
2026-07-22 and 2026-08-25, with dates on anything that could have moved since.

**Argo CD on-prem deploys applications only. It does not install itself, it does not manage
the platform, and it has no password of its own — Flux installs it, Entra logs you in, and
AWS Secrets Manager holds every credential.**

**If you read one section, read §8.** It is about an app registration the cloud fleet already
uses, and it can sign out two production clusters.

---

## 1. Start here

| If you want | Go to |
|---|---|
| The one warning that affects cloud today | §8 |
| The shape in one picture | §2 |
| Which repo owns what | §3 |
| How people sign in | §4 |
| How permissions are decided | §5 |
| Where secrets come from | §6 |
| The guardrails that stop Argo touching the platform | §7 |
| What cost us time | §9 |
| What you have to decide | §10 |

---

## 2. The shape: who installs what

Two GitOps controllers run on each on-prem cluster, and they are **deliberately** layered:

```
Flux  ──installs──►  Argo CD  ──deploys──►  applications
 │                                          (namespaces app-*)
 └──manages──►  the platform
                (istio, kyverno, prometheus, velero, rook-ceph, cert-manager)
```

**Flux owns the platform. Argo CD owns applications. Neither touches the other's objects.**

That separation is the whole design, and it was not free — it came out of a rejected pull
request (`iaac-talos-flux-platform` #73) in which an Argo CD Application was pointed at a
repository and namespace Flux was already reconciling. Two controllers with `selfHeal: true`
on the same objects fight indefinitely, and `prune: true` can delete in another team's
namespace.

**Argo CD is installed by Flux from a pinned Helm chart.** Not `kubectl apply -f` from a URL,
and not by itself. A `resources:` entry fetching an upstream `install.yaml` inside a reconcile
path was proposed and rejected: it makes the cluster's content depend on a live internet fetch
at every reconcile.

Argo CD **v3.4.5**, ClusterIP service, fronted by Istio. No NodePort.

---

## 3. Four repos, and the one that surprises people

| Repo | Branch model | Owns |
|---|---|---|
| `iaac-talos-flux-cluster` | single `master` | the Flux `GitRepository` and `Kustomization` objects that point at everything else — the wiring, not the content |
| `iaac-talos-flux-platform` | **per-cluster branches** `op-dev` / `op-qa` / `op-prod` | `infrastructure/*` — routes, namespaces, kyverno, prometheus, rbac, velero, **and argocd itself** |
| `iaac-argocd-onprem` | `base/` + overlays | the Argo CD **Applications and AppProjects** |
| `iaac-risingwave-onprem` | `manifests/<cluster>/` | the RisingWave product |

⚠️ **Two different branch models in two repos.** `op-qa` and `op-prod` are real refs in the
platform repo and **do not exist** in the cluster repo. A `git fetch origin op-qa` there fails
with "couldn't find remote ref", which reads like a permissions problem and is not.

⚠️ **The on-prem dev cluster's directory is `bm-dev`**, not `op-usxpress-dev`. QA and prod use
their full names. One inconsistency, and it is load-bearing.

**Applications use kustomize base + overlays, deliberately not branch-per-environment.** The
platform repo uses branches and we live with it; the Argo repo does not, because a change you
want in three environments should be one commit and three overlay values, not three
cherry-picks. Branch-per-env is why some `op-qa` and `op-prod` manifests still carry dev role
ARNs.

---

## 4. Identity: Entra directly, no Dex

**People sign in with their normal USX account, and Argo talks to Entra ID itself.** Dex is
not installed — `argocd-dex-server` returns NotFound, not `enabled: false`.

The chain: browser → Argo CD → Entra ID → on-prem ADFS (`usxfs.usxpress.com/adfs/ls`) → MFA →
back to Argo with a token.

**The client must be a confidential (web) client, not a SPA.** `argocd-server` redeems the
authorization code server-side. A Single-Page-Application registration fails at the callback
with `AADSTS9002327` — *"a code issued to a SPA client may only be redeemed cross-origin"*.
That kills the attractive no-client-secret PKCE design before you start.

On-prem uses its own registration, **`Argo CD On-Prem`**:

| | |
|---|---|
| App ID | `42dc0c33-4c56-47a5-b207-d119272997aa` |
| Service principal | `b20084ae-9f13-4ca7-961c-b05f023fa2c2` |
| Tenant | `bbb5a66d-5c9f-482a-969a-a40304b6bc8d` |
| Callbacks | all three clusters registered **up front** |

Registering all three callbacks at creation meant QA and prod needed **no Entra work at all** —
only a pull request on their branch. Worth copying.

⚠️ **`configs.cm.url` must be set, and it was not.** Argo builds every link it emits — and,
once SSO exists, its OIDC `redirect_uri` — from that one value. Both on-prem branches carried
the chart default `https://argocd.example.com`, so **no OIDC provider could have worked until
that was fixed**. Check this first on any cluster; the symptom is a login that redirects
somewhere that does not exist.

---

## 5. Permissions: nothing by default

**`policy.default` is `""`. Authenticating grants nothing at all.** Every permission is
granted explicitly, and an unassigned user who signs in successfully sees an empty Argo with
no error — which is correct, and which looks exactly like a broken login.

### The part that will not match the documentation

**Authorisation comes from the `roles` claim, not `groups`.** Entra would not emit a `groups`
claim for this application under any configuration tried: `SecurityGroup`, `ApplicationGroup`,
`groups` in `optionalClaims.idToken`, no claims-mapping policy, the user in 42 groups so
nowhere near the ~200 overage threshold, and `emit_as_roles` unset. The cause is above cluster
visibility — a tenant token-issuance policy, Conditional Access, or the ADFS federation — and
it is still open.

**`roles` is issued from appRoleAssignments on the service principal.** That is a different
issuance path, entirely inside the registration we own, and it works. Proven on `op-dev`
2026-08-25 at 19:18:27Z: `roles → platform-admin`. The control that makes it conclusive came
free six minutes earlier — a user holding only default access signed in against the identical
config and received **no `roles` claim at all**. Same app, same tenant, same federation; the
assignment was the only variable.

**Groups can still be assigned to app roles**, so teams are granted as groups with no
per-person administration and no extra licence. You get the convenience of groups through a
mechanism that actually emits.

### The roles

| App role | Argo role | Can |
|---|---|---|
| `platform-admin` | `role:admin` | everything |
| `app-viewer` | `role:app-viewer` | `get` on applications and logs; `sync` on dev and QA; **no sync on prod** |

`app-viewer` is scoped to the `apps` AppProject. **Production sync stays human-initiated by
the platform team, by design** — a deliberate brake, not an oversight.

⚠️ **`policy.csv` must carry group GUIDs, never display names.** `usx-cloud-admin` is a
cloud-only group (`onPremisesSyncEnabled: null`), and Entra can only ever emit its object ID.
A display name is available only for AD-synced groups. This is the third system in which an
identity name failed to cross a boundary.

---

## 6. Secrets: nothing is typed in

**Every credential reaches Argo CD from AWS Secrets Manager through External Secrets. Nothing
is pasted into the UI and nothing is committed.**

Path convention, which mirrors Grafana's:

```
op-usxpress-<env>/platform/argocd/azure-ad      keys: client_id, client_secret
```

Region **us-east-2**, read through the cluster's own `ClusterSecretStore`.

The OIDC client secret needed **no new machinery**: `admin-externalsecret.yaml` already
targeted `argocd-secret` with `creationPolicy: Merge`, so one extra `data` entry delivers it
and Argo resolves `$oidc.entra.clientSecret` natively. No new file, no kustomization change.

⚠️ **Who owns `argocd-secret` is not uniform, and it decides the mechanics.**

| Cluster | `configs.secret` | Owner |
|---|---|---|
| op-dev | `createSecret: false` | a pre-existing secret, preserved |
| op-qa | absent | Helm |

Dev's Argo adopted a 49-day-old raw install whose `argocd-secret` already held
`server.secretkey`. Letting Helm create it would have regenerated that key and **ended every
session on the cluster**. Same feature, two mechanics, because of history.

⚠️ **A committed SSH key.** The rejected PR #73 contained a real `sshPrivateKey` in
`argocd_git_secret.yaml`. It was rotated. Repository credentials belong in Secrets Manager and
reach Argo through External Secrets, the same way everything else does.

---

## 7. Guardrails: what Argo is not allowed to touch

These are the manifests that stop an app-layer controller becoming a cluster-layer one. All
are asserted by the repo's own verify pass.

**`AppProject/apps` destinations are limited to namespaces matching `app-*`.** It cannot match
`risingwave`, `flux-system`, `velero`, `rook-ceph` or `istio-system`.

**The built-in `default` AppProject is overwritten with empty allow-lists.** It ships
permissive (`'*'`), and **without this override every other guardrail is decorative** — anyone
can create an Application in `default` and bypass the lot. This is the single highest-value
line in the whole setup.

**Flux's toolkit CRDs are in `resource.exclusions`.** Argo CD must never act on the controller
that installed it. Eight groups excluded, plus eight `ignoreResourceUpdates` keys for
high-churn kinds.

**Production Applications sync manually.** No `automated` block on prod.

---

## 8. The one that can break your production clusters

⚠️ **There is an existing Entra registration called `Argo CD` —
`56078536-f4a3-4f92-810e-5106787019a8` — which already carries four `/auth/callback` URIs
across the cloud EKS fleet. Two of them are production. It has zero registered owners.**

**`az ad app update --web-redirect-uris` replaces the list wholesale.** It is not additive.
Adding one callback with that flag, without listing the existing four, signs out two
production clusters, and there is no owner to notice.

On-prem deliberately created a separate registration rather than adding callbacks to that one.
**For cloud, if you must edit it: read the current list, append, and write back the full set —
and add owners before you touch it at all.**

This also means the cloud fleet has been on Entra OIDC natively all along. On-prem's old
Dex + SAML build was the outlier, not the standard.

---

## 9. Nine things that cost us time

Each was measured, not guessed, and each produced a green status while being wrong.

1. **Two GitOps controllers on one source.** Argo pointed at a repo Flux already reconciled.
   Both self-heal, so they fight indefinitely; `prune` can delete in another team's namespace.
   Decide the boundary before installing, not after.
2. **A permissive `default` AppProject** makes every other restriction cosmetic.
3. **`configs.cm.url` unset** means the chart default is used for every emitted link and for
   the OIDC `redirect_uri`. Nothing SSO-related can work until it is right.
4. **A SPA registration cannot work.** `AADSTS9002327` at the callback. Argo needs a
   confidential client with a secret.
5. **No `groups` claim, with no error anywhere.** The login succeeds, `policy.csv` never
   matches, and the user sees an empty screen. Use the `roles` claim.
6. **Zero Applications makes the UI useless as an RBAC test.** An admin and an unauthorised
   user see the identical empty screen. Ask the server for the decision instead —
   `scripts/argocd-can-i.sh <cluster> --role <role>` — and **check allow and deny together**,
   because a policy that granted everything would pass every allow-check and still be wrong.
7. **DNS targets are not uniform.** op-dev lists all 7 worker IPs; op-qa lists 3, the
   `platform` workers only. There is no rule to generalise — derive the list from a route
   already serving on that same cluster.
8. **Querying a hostname before you create it poisons your own verification.** `usxpress.io`
   caches NXDOMAIN for 86400 seconds. Verify with `curl --resolve <host>:443:<node-ip>`, which
   sends the real SNI to a real ingress node and bypasses the resolver entirely.
9. **A green Flux sync, a healthy HelmRelease and a successful login can all be true while the
   feature is broken.** Check the value, not the status.

---

## 10. What to decide for cloud

These are the choices, not instructions. Match them or differ deliberately.

| Decision | On-prem | Worth matching? |
|---|---|---|
| Who installs Argo CD | Flux, pinned chart | Yes — something must own it, and it must not be itself |
| Argo's scope | applications only, `app-*` namespaces | Yes |
| `default` AppProject | overwritten, empty allow-lists | **Yes, unconditionally** |
| Identity | Entra OIDC direct, no Dex | Cloud already does this |
| Authorisation claim | `roles` | Test yours — `groups` may work on a different registration |
| `policy.default` | `""` | Yes |
| Prod sync | manual only | Your call; it is a brake with a cost |
| Secrets | External Secrets from Secrets Manager | Yes |
| Env layout | kustomize base + overlays | Yes — branch-per-env has cost us drift repeatedly |
| Registration | its own, all callbacks up front | Yes, and see §8 |

**The honest cost.** `policy.default: ""` plus manual prod sync means a new team member who
signs in successfully sees nothing until someone assigns them an app role, and a production
release needs a human to click sync. Both will generate "is it broken?" messages in the first
month. That is the point, and it is slower.

---

## Proven

* Argo CD v3.4.5 on all three on-prem clusters, installed by Flux, Dex removed entirely.
* Entra OIDC authentication live on dev, QA and prod since 2026-08-25.
* Authorisation from the `roles` claim, proven on op-dev with a negative control.
* `scripts/close-argocd-sso.sh` passes every machine-checkable criterion on all three: DNS
  resolving to the nodes actually running each cluster's ingressgateway (7 / 3 / 10), HTTPS
  200 against that cluster's own certificate, the Entra issuer in `/api/v1/settings`, a
  40-byte client secret, and a policy whose subjects can match.

## Tested and killed

* **AWS Identity Center SAML + Dex** — stalled on console-only state with no readback.
* **SPA client with PKCE and no secret** — `AADSTS9002327`.
* **`groupMembershipClaims: SecurityGroup`** and **`ApplicationGroup`** — no claim emitted.
* **`groups` in `requestedScopes`** — Entra's v2.0 endpoint rejects it; it is not a scope.
* **`requestedIDTokenClaims`** — an Okta pattern; removing it changed nothing.

## Open

* **Why Entra emits no `groups` claim for this app.** Tenant-level, owned by the directory
  team. The `roles` route works, so this is a question rather than a blocker.
* **op-dev and op-prod carry no Applications** (INFRA-1650), so only op-qa can prove anything
  through the UI.

---

**Next action: Parul compares the EKS setup against §10 and flags any row she differs on.**
The two worth an answer first are the `default` AppProject override (§7) and whether anyone
owns the `Argo CD` registration (§8).

Questions on anything on-prem: Dare Oke.
