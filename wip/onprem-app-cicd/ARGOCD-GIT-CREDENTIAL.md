# INFRA-1647 — the Argo CD Git credential

**Decided 2026-08-20:** GitHub App, not a PAT. QA first, prod after `risingwave-etl` is
green. `…-pat.yaml` stays in the pack as a documented fallback and is not kept in sync.

**Run it with the wizard:** [`wizard-argocd-git-credential-qa.sh`](wizard-argocd-git-credential-qa.sh)
walks all nine steps — it re-checks that the defect is still real before asking for
anything, validates the PEM with `openssl` before it can reach Secrets Manager, prints the
key list before and after the merge, runs the three document-count checks and the
foreign-identifier grep before the PR, and ends on `risingwave-etl`'s sync status rather
than on `SecretSynced`. It is hardcoded to QA, on purpose. Run it **on WSL** — this repo's
`guard-mutations.sh` blocks the AWS write, correctly, and the codespace GitHub token must
never touch a variant-inc repo.

**Status:** manifests drafted 2026-08-20, nothing applied. Blocks INFRA-1648 (smoke test),
INFRA-1635 (real pipeline tree) and INFRA-1636 (prod). Nothing else in the sprint depends
on it, and it depends on nothing.

## The defect

Argo CD on `op-usxpress-qa` holds **no Git credential at all** — not a wrong one, not an
expired one. No secret in the `argocd` namespace carries the
`argocd.argoproj.io/secret-type` label. `variant-inc/risingwave-pipeline` is INTERNAL, so
`risingwave-etl` cannot be compared and reports:

```
ComparisonError: authentication required
```

`op-usxpress-prod` is in the same state. Both clusters have the Argo CD stack and an
`argocd-config` Kustomization; neither ever needed to authenticate, because until
2026-08-19 no Application pointed at a path that existed.

**Why it stayed invisible.** The `risingwave-etl` Application was generated on 2026-08-18
pointing at `deploy/overlays/qa`, which did not exist in the repository yet, and at
`targetRevision: main` in a repository whose default branch is `master`. Argo CD failed on
the revision before it ever got as far as authenticating, so the credential gap was masked
by two other faults that have since been fixed (platform#96, risingwave-pipeline#9).

This is the same family as `ESO SecretSynced ≠ valid content` and the QA Flux token: the
control plane reports a state that is not a statement about the thing you care about.

## The design

One **org-scoped** credential per cluster, not one per repository.

Argo CD matches a `repo-creds` secret to an Application by **longest URL prefix**. A single
secret with `url: https://github.com/variant-inc` therefore serves every current and future
`variant-inc` repository, which makes onboarding the next application a four-line
ApplicationSet entry with no credential work at all — the property `ONPREM-CICD.md` §4.2
already claims and could not previously deliver.

It deliberately mirrors the `apps` AppProject, which already restricts `sourceRepos` to
`https://github.com/variant-inc/*` and `ssh://git@github.com/variant-inc/*`. The credential
is not a second access-control surface; the AppProject remains the one that decides.

Delivered the same way every other secret on these clusters is: AWS Secrets Manager →
External Secrets (`ClusterSecretStore/default`) → Flux applies the ExternalSecret. Nothing
sensitive in git.

### Credential type — a decision, not a detail

| | GitHub App *(recommended)* | Machine-user PAT |
|---|---|---|
| Expiry | none to forget — Argo CD mints a short-lived installation token and renews it | fixed date; **this is the failure we already had** on the QA Flux token, silently, for two days |
| Identity | belongs to the org, survives leavers | belongs to a user account |
| Scope | selected repos or whole org, read-only contents | whatever the user can read, unless fine-grained |
| Cost to set up | org owner must create + install the App | minutes, if a machine user exists |
| Rotation | replace one private key | replace the token before every expiry, forever |

Both manifests are written. `platform/argocd-config/<branch>/repo-creds-externalsecret.yaml`
is the App; `…-pat.yaml` is the fallback. **Ship exactly one** — they target the same Secret
name and two ExternalSecrets owning one Secret fight over it indefinitely.

## What lands where

| # | Repo / system | Change |
|---|---|---|
| 1 | AWS Secrets Manager, account 527101283767 | add the credential properties to `op-usxpress-qa/platform/argocd` |
| 2 | `iaac-talos-flux-platform` branch `op-qa` | `infrastructure/argocd-config/repo-creds-externalsecret.yaml` + one line in that directory's `kustomization.yaml` |
| 3 | AWS Secrets Manager, account 937464026810 | the same, at `op-usxpress-prod/platform/argocd` |
| 4 | `iaac-talos-flux-platform` branch `op-prod` | the same two changes, from `argocd-config/op-prod/` |

No cluster Kustomization is added — `argocd-config` already exists and is wired on both
clusters. This is one file and one line inside a directory Flux already reconciles.

⚠️ **The `op-prod` copies of `appprojects.yaml` and `admin-externalsecret.yaml` in this pack
are references, not payloads.** Only the ExternalSecret is new. Add the `resources:` line to
the branch's own `kustomization.yaml`; do not overwrite the file with this one.

## Step 0 — before anything, check the reader can read

The ESO role in each account may be scoped to explicit secret ARNs rather than a prefix.
The manifests reuse the **existing** `…/platform/argocd` secret specifically so this cannot
bite — but confirm the policy shape, because if it is prefix-scoped, splitting the Git
credential into its own SM path is cleaner and a one-line change to the manifest.

```bash
# QA — account 527101283767
ESO_ROLE=$(aws --profile usx-qa iam list-roles \
  --query "Roles[?contains(RoleName,'external-secrets')].RoleName" --output text)
echo "eso role: $ESO_ROLE"
aws --profile usx-qa iam list-role-policies --role-name "$ESO_ROLE"
aws --profile usx-qa iam list-attached-role-policies --role-name "$ESO_ROLE"
```

Read the `Resource` list. If it names `arn:aws:secretsmanager:…:secret:op-usxpress-qa/*`,
a separate path works. If it enumerates individual secrets, keep the manifest as written.

## Step 1 — provision the credential (human, GitHub UI)

**GitHub App route.** On the `variant-inc` org → Settings → Developer settings → GitHub
Apps → New GitHub App:

* Name: `argocd-onprem`
* Permissions: **Repository → Contents: Read-only**. Nothing else. No webhook.
* Where can this App be installed: **Only on this account**
* Create, then **Generate a private key** (downloads a `.pem`), then **Install App** on the
  `variant-inc` org — All repositories, or select `risingwave-pipeline` plus whatever comes
  next.
* Record the **App ID** (App settings page) and the **Installation ID** (the number at the
  end of the install URL, `…/settings/installations/<id>`).

**PAT route**, only if the above is not possible: a fine-grained PAT on a machine user, with
`Contents: Read-only` on the `variant-inc` org, longest permitted expiry, and a calendar
entry for the renewal.

## Step 2 — put it in Secrets Manager

The QA secret already holds `admin.password` and `admin.passwordMtime`, and ESO reads them
to keep the Argo CD admin login working. `put-secret-value` **replaces the whole JSON
document** — writing only the new keys locks you out of Argo CD admin on the next refresh.
So read, merge, write back.

```bash
# ---------- QA · account 527101283767 · GitHub App ----------
read -rp  'App ID: '          APP_ID
read -rp  'Installation ID: ' INSTALL_ID
read -rp  'Path to the .pem private key: ' PEM

CUR=$(aws --profile usx-qa secretsmanager get-secret-value \
        --secret-id op-usxpress-qa/platform/argocd \
        --query SecretString --output text)

NEW=$(APP_ID="$APP_ID" INSTALL_ID="$INSTALL_ID" PEM="$PEM" CUR="$CUR" python3 - <<'PY'
import json, os
d = json.loads(os.environ["CUR"])
d["repo.githubAppID"] = os.environ["APP_ID"]
d["repo.githubAppInstallationID"] = os.environ["INSTALL_ID"]
d["repo.githubAppPrivateKey"] = open(os.path.expanduser(os.environ["PEM"])).read()
print(json.dumps(d))
PY
)

# prove the merge kept what was there BEFORE writing
python3 -c 'import json,sys; d=json.load(sys.stdin); print(sorted(d.keys()))' <<<"$NEW"
# expect: admin.password, admin.passwordMtime, repo.githubAppID,
#         repo.githubAppInstallationID, repo.githubAppPrivateKey

aws --profile usx-qa secretsmanager put-secret-value \
  --secret-id op-usxpress-qa/platform/argocd --secret-string "$NEW"
unset CUR NEW
```

The private key must keep its real newlines. Passing it through `json.dumps` escapes them as
`\n` inside the JSON document and ESO writes them back out as newlines — a PEM pasted into
the console by hand as a single line produces `could not parse private key` in the
repo-server, which reads like a permissions fault and is not one.

Prod is the same with `--profile usx-prod` and `op-usxpress-prod/platform/argocd`. Prod also
holds a live `admin.password` that must survive the merge.

## Step 3 — the manifest

```bash
# from this repo's pack, on WSL
SRC=~/onprem-app-cicd    # see PUSH-PATHS.md §0 for how this gets there
git -C ~/iaac-talos-flux-platform checkout op-qa && git -C ~/iaac-talos-flux-platform pull
cp "$SRC"/platform/argocd-config/op-qa/repo-creds-externalsecret.yaml \
   ~/iaac-talos-flux-platform/infrastructure/argocd-config/
```

Then add exactly one line to
`~/iaac-talos-flux-platform/infrastructure/argocd-config/kustomization.yaml`:

```yaml
  - repo-creds-externalsecret.yaml
```

Before raising the PR, check the document count three ways — the trailing-newline trap that
silently merged two documents on the prod `infra.yaml` on 2026-08-18 applies to any appended
YAML:

```bash
cd ~/iaac-talos-flux-platform/infrastructure/argocd-config
grep -c '^kind:' repo-creds-externalsecret.yaml          # 1
kubectl kustomize . | grep -c '^kind:'                   # 4
kubectl kustomize . | kubectl apply --dry-run=client -f - -o name | wc -l   # 4
```

All three must agree with each other. Then grep the file for foreign cluster identifiers —
this directory family has produced four copy defects already (INFRA-1646):

```bash
grep -n 'op-usxpress-dev\|op-usxpress-prod\|700736442855\|937464026810' \
  repo-creds-externalsecret.yaml    # must print nothing on op-qa
```

## Step 4 — verify, on QA

`SecretSynced` is not the check. It proves ESO wrote a secret, not that Argo CD can read
the repository.

```bash
export KUBECONFIG=$HOME/.kube/op-usxpress-qa-sso.yaml   # QA · SSO

flux -n flux-system reconcile kustomization argocd-config --with-source

# 1. ESO synced
kubectl --context op-usxpress-qa -n argocd get externalsecret argocd-repo-creds-variant-inc

# 2. the LABEL is on the Secret — without it the credential is invisible to Argo CD
kubectl --context op-usxpress-qa -n argocd get secret argocd-repo-creds-variant-inc \
  -o jsonpath='{.metadata.labels}{"\n"}'
# want: {"argocd.argoproj.io/secret-type":"repo-creds", ...}

# 3. the URL prefix is a prefix of the Application's repoURL, character for character
kubectl --context op-usxpress-qa -n argocd get secret argocd-repo-creds-variant-inc \
  -o jsonpath='{.data.url}' | base64 -d; echo
# want: https://github.com/variant-inc   (no trailing slash, no .git)

# 4. THE check — Argo CD actually reads the repository
kubectl --context op-usxpress-qa -n argocd get application risingwave-etl \
  -o jsonpath='{.status.sync.status}{"  "}{.status.health.status}{"  "}{.status.conditions}{"\n"}'
```

Want `Synced Healthy` with no conditions. `ComparisonError` still present means the
credential is not matching — check 3 first, then the repo-server:

```bash
kubectl --context op-usxpress-qa -n argocd logs deploy/argocd-repo-server --tail=50 \
  | grep -i 'auth\|credential\|github'
```

`authentication required` after this lands = the prefix does not match. `could not parse
private key` = the PEM lost its newlines in Step 2. `404` on the installation = the App was
created but never installed on the org.

## Rollback

Revert the PR. The ExternalSecret is `creationPolicy: Owner`, so Flux prune deletes the
Secret with it and Argo CD returns to exactly today's state — no Application is touched,
nothing that currently works depends on it.

## Proven / killed / traps

**Proven.** Nothing yet — this is drafted, not applied. Both directories build under
`kubectl kustomize` at 4 objects each and pass `apply --dry-run=client`.

**Killed.** Per-repository credentials: rejected. It makes every onboarding a credential
task and produces one secret per app to rotate. Prefix matching gives the same access with
one object.

**Traps.**
1. ESO does **not** copy labels from the ExternalSecret to the Secret it creates. The
   `argocd.argoproj.io/secret-type: repo-creds` label must be set under
   `spec.target.template.metadata.labels`, or the credential is created perfectly and
   ignored completely — with no error anywhere.
2. `url` is a **prefix**, matched literally. A trailing slash or a `.git` suffix makes it
   stop matching, and the symptom is `authentication required` — identical to having no
   credential at all.
3. `put-secret-value` replaces the entire JSON document. The QA and prod secrets already
   hold the Argo CD admin password.
4. A PEM that loses its newlines fails in the repo-server, not in ESO — the ExternalSecret
   reports `SecretSynced` throughout.
5. If the PAT variant ships, its expiry becomes a production dependency with no alert on it.
   INFRA-1642 then blocks this ticket instead of running beside it.
