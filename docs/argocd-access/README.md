# Argo CD on-prem — who gets access, and how

**Granting someone Argo CD access is adding them to a group. That is the whole procedure.**
Nobody edits Entra, nobody raises a PR, nobody touches the clusters.

Applies to all three on-prem Talos clusters — `op-usxpress-dev`, `-qa`, `-prod`.
Last verified 2026-09-02.

| | |
|---|---|
| Argo CD | `argocd.op-dev.usxpress.io` · `argocd.op-qa.usxpress.io` · `argocd.op-prod.usxpress.io` |
| Entra app registration | `Argo CD On-Prem` — `42dc0c33-4c56-47a5-b207-d119272997aa` |
| Service principal | `b20084ae-9f13-4ca7-961c-b05f023fa2c2` |
| Tenant | `bbb5a66d-5c9f-482a-969a-a40304b6bc8d` |

## The three tiers

| Group | Object ID | Can do | Members (2026-09-02) |
|---|---|---|---|
| `usx-argocd-admin` | `6c23655c-8080-4991-a67f-293cfb0a597b` | everything, all clusters | Idris Fagbemi |
| `usx-argocd-operator` | `984faf3e-e280-490e-8ff4-a71101a73a95` | see, sync, restart pods — **including prod** | Timothy Preble, Pujit Koirala |
| `usx-argocd-viewer` | `6bd52028-9105-4bdf-a39a-0d31a57ae53b` | see Applications and logs; sync on dev/QA only | Jenni Ray |

`usx-cloud-admin` (`b9a1ff74-…`) also maps to full access and predates this model. It has
**no owners**, so nobody can manage its membership — use `usx-argocd-admin` instead.

Operator and viewer are scoped to the `apps` AppProject. They see their own Applications
and nothing else on the cluster.

## Where this lives in the portal

Entra deep-links, for when you want to look rather than run a command.

| What | Link |
|---|---|
| **Add someone** — `usx-argocd-admin` members | https://portal.azure.com/#view/Microsoft_AAD_IAM/GroupDetailsMenuBlade/~/Members/groupId/6c23655c-8080-4991-a67f-293cfb0a597b |
| **Add someone** — `usx-argocd-operator` members | https://portal.azure.com/#view/Microsoft_AAD_IAM/GroupDetailsMenuBlade/~/Members/groupId/984faf3e-e280-490e-8ff4-a71101a73a95 |
| **Add someone** — `usx-argocd-viewer` members | https://portal.azure.com/#view/Microsoft_AAD_IAM/GroupDetailsMenuBlade/~/Members/groupId/6bd52028-9105-4bdf-a39a-0d31a57ae53b |
| Which group holds which tier | https://portal.azure.com/#view/Microsoft_AAD_IAM/ManagedAppMenuBlade/~/Users/objectId/b20084ae-9f13-4ca7-961c-b05f023fa2c2/appId/42dc0c33-4c56-47a5-b207-d119272997aa |
| The app roles themselves | https://portal.azure.com/#view/Microsoft_AAD_RegisteredApps/ApplicationMenuBlade/~/AppRoles/appId/42dc0c33-4c56-47a5-b207-d119272997aa |
| Consent state | https://portal.azure.com/#view/Microsoft_AAD_IAM/ManagedAppMenuBlade/~/Permissions/objectId/b20084ae-9f13-4ca7-961c-b05f023fa2c2/appId/42dc0c33-4c56-47a5-b207-d119272997aa |

### Clicking there instead

All four start at `portal.azure.com` -> **Microsoft Entra ID**.

**Give someone access** — the only path you need regularly:

```
Entra ID -> Groups -> All groups
  -> search: usx-argocd-operator
  -> click the group name
  -> Members
  -> + Add members -> type their name -> Select
```

**See which group holds which tier:**

```
Entra ID -> Enterprise applications -> All applications
  -> clear the "Application ID starts with" filter chip
  -> search: Argo CD On-Prem
  -> Users and groups
```

That filter chip is applied by default in some views and will hide the app from a search
that is otherwise correct. The search also matches display names from the **start** only.

**See the role definitions:**

```
Entra ID -> App registrations -> All applications
  -> search: Argo CD On-Prem
  -> App roles
```

**App registrations and Enterprise applications are the same app in two blades**, and the
distinction matters: the registration is where roles are *defined*, the enterprise
application is where they are *assigned*. Looking for one in the other is the usual reason
someone concludes the app does not exist.

**Consent state:**

```
Entra ID -> Enterprise applications -> All applications -> Argo CD On-Prem
  -> Security -> Permissions
```

The *Granted for* column should read **All users**.

The **Users and groups** page is the readable summary: three rows, each a group, with a
*Role assigned* column carrying `platform-admin`, `app-operator` or `app-viewer`.

The consent page should show `openid profile email` granted for **All users**. A person's
name there instead means only that person consented, and everyone else still hits the
approval screen.

**What the portal cannot show you is what a tier is allowed to do.** The app role is only a
label; the verbs behind it (sync, restart, delete a pod) are `policy.csv` in the platform
Git repo. Widening a tier is a PR — `scripts/pr-argocd-rbac-operator.sh` is the worked
example — never a portal edit.

## Granting access

```bash
az login --tenant bbb5a66d-5c9f-482a-969a-a40304b6bc8d
OID=$(az ad user show --id someone@usxpress.com --query id -o tsv)
az ad group member add --group usx-argocd-operator --member-id "$OID"
```

Look a person up first rather than guessing their name — directory names are not
predictable ("Tim Wolfe" and "Jenny Ray" were both wrong; the real users are Timothy Preble
and Jenni Ray):

```bash
bash scripts/entra-argocd-access-groups.sh --find <surname>
```

Removing access is `az ad group member remove --group <group> --member-id "$OID"`. It takes
effect on their next sign-in, not immediately — the role is carried in an issued token.

## Why it works — read this before changing anything

**This tenant never emits a `groups` claim.** Three `groupMembershipClaims` configurations
were tried in August and none produced one; the cause is above our level (token issuance
policy, Conditional Access, or the ADFS federation).

So authorisation runs on the **`roles` claim** instead, which is issued from
`appRoleAssignments` on the service principal — a different path that the group-claim
suppression does not touch. A group assigned to an app role puts that role's *value* in
every member's token.

```
person -> Entra group -> app role -> roles claim -> policy.csv subject
```

Consequences, all of them load-bearing:

- **`policy.csv` subjects are role VALUES, not group object IDs.** `g, app-operator,
  role:app-operator`, never `g, 984faf3e-…, role:app-operator`.
- **Every `g,` subject must be the same kind.** A file mixing a GUID and a role value has
  one subject that silently matches nothing, and the file does not say which.
- **`configs.rbac.scopes` must be `[roles, groups]`.** Argo only searches the claims named
  there. Without `roles`, every policy line is dead and the symptom is an empty
  Applications screen, not an error.

App roles are defined on the registration by `scripts/entra-argocd-app-roles.sh --define`
(deterministic uuid5 IDs, so re-running is safe).

| Role value | Argo CD role | Permissions |
|---|---|---|
| `platform-admin` | `role:admin` | everything |
| `app-operator` | `role:app-operator` | `applications get/sync/action/*/delete`, `logs get` on `apps/*` |
| `app-viewer` | `role:app-viewer` | `applications get`, `logs get` on `apps/*`; `sync` on dev/QA only |

`action/*` is the Restart button. The `delete` on the operator role is **resource** delete
— a Pod — scoped to the project; it cannot delete an Application.

## Consent

User consent is disabled tenant-wide, so before 2026-09-02 the first sign-in by anyone who
had not personally consented landed on Entra's approval screen ("Request sent, your admin
has been notified"). **Tenant-wide consent is now granted** (`consentType: AllPrincipals`,
scope `openid profile email`) and nobody should see it again.

⚠️ **`az ad app permission admin-consent` does not do this and exits 0 regardless.** It
grants what the registration declares in `requiredResourceAccess`; this app declares none,
because `openid profile email` are implicit. The working route is a direct Graph POST to
`/v1.0/oauth2PermissionGrants`. Always read the grants back:

```bash
az rest --method GET \
  --url "https://graph.microsoft.com/v1.0/servicePrincipals/b20084ae-9f13-4ca7-961c-b05f023fa2c2/oauth2PermissionGrants" \
  --query "value[].{consentType:consentType,scope:scope}" -o json
```

`AllPrincipals` is the one that matters. `Principal` entries are individuals who consented
for themselves and mean nothing for anyone else.

## When someone says "I can't get in"

Work out which of the two gates it is before touching anything — they look similar and have
different fixes.

| Symptom | Gate | Fix |
|---|---|---|
| Redirected to a Microsoft "Request sent" / approval page | consent | should not happen now; check `AllPrincipals` above |
| `AADSTS50105` — not assigned to the application | app role | they are in no group; add them |
| Signs in fine, **empty Applications list** | claims or policy | below |
| Applications visible, buttons greyed out | policy | their role lacks that verb |

An empty list is authorisation, not authentication. Read what the token actually carried —
after a **complete** sign-out, since an old token tests the old configuration:

```bash
bash scripts/argocd-token-claims.sh op-prod
```

Then confirm the cluster agrees:

```bash
bash scripts/onprem-kubectl.sh op-prod -- -n argocd get cm argocd-rbac-cm \
  -o jsonpath='{.data.policy\.csv}'
bash scripts/onprem-kubectl.sh op-prod -- -n argocd get cm argocd-rbac-cm \
  -o jsonpath='{.data.scopes}'; echo
```

`argocd-server` watches that ConfigMap and reloads without a restart.

## Repository access

Argo CD reads `variant-inc` repositories with a **deploy key per repository**, not the org
GitHub App — the App needs a variant-inc owner we do not have, whereas a deploy key belongs
to the repository, never expires and survives offboarding.

The private half lives in Secrets Manager and reaches the cluster through an ExternalSecret
in `infrastructure/argocd-config/`. Adding a second repository means another key and another
file; the org App remains the target because it would collapse that back to one object.

```
op-usxpress-prod/platform/argocd
  repo.risingwave-pipeline.sshPrivateKey   -> argocd-repo-risingwave-pipeline
```

Two traps, both hit in practice:

- **That record also holds `admin.password`**, and `put-secret-value` replaces the whole
  JSON document. Writing a property naively locks you out of the console you are fixing.
  Use `scripts/argocd-repo-deploy-key.sh`, which merges and verifies.
- **The label `argocd.argoproj.io/secret-type: repository` must be set in the ExternalSecret
  `template`.** ESO does not copy labels from the ExternalSecret to the Secret it creates,
  and without the label Argo ignores a perfectly correct credential.

## Scripts

| Script | Does |
|---|---|
| `scripts/entra-argocd-access-groups.sh` | create/populate the tier groups and assign them to app roles. Dry-run by default; `--find <surname>` looks a person up |
| `scripts/entra-argocd-app-roles.sh` | `--inspect` / `--define` / `--assign <role> <objectId>` on the registration |
| `scripts/entra-find-team-group.sh` | which groups people share; `--members <group>` lists one |
| `scripts/entra-argocd-cli-redirect.sh` | register the `argocd login --sso` localhost callbacks |
| `scripts/entra-rw-dex-redirect.sh` | add a cluster's Dex callback to the shared RisingWave registration |
| `scripts/pr-argocd-rbac-operator.sh` | add `role:app-operator` to `policy.csv` on all three branches, as PRs |
| `scripts/argocd-repo-deploy-key.sh` | create a repository deploy key and merge it into Secrets Manager safely |
| `scripts/argocd-token-claims.sh <cluster>` | print the claim **values** a real sign-in produced |

Every one of them is read-only until told otherwise, and refuses rather than guessing when a
source does not load.

## Still open

- `role:app-operator` has **never been exercised by a real person**. Pujit Koirala's first
  sign-in is the acceptance test for INFRA-1639.
- Idris Fagbemi and Pujit Koirala still hold redundant per-user `app-viewer` assignments
  from before this model. Harmless; remove once group login is proven, so the groups are the
  only path.
- `usx-cloud-admin` has no owners and still maps to full access. Either give it an owner or
  retire it from this application.
- The `groups` optional claim carries an empty `additionalProperties`. That is where
  `emit_as_roles` would sit, and it is the untested explanation for why group claims never
  arrived. Not worth chasing while roles work.
