# /azure-oidc-federation

Unblock and permanently fix GitHub Actions → Azure OIDC failures, where the error reads like
a permissions fault but is really an exact-string mismatch on the token's subject claim.

Built from `manhattan-dl-handler`, blocked three times: `whitelistFix` (2026-08-11),
`addCodesAndUpdateCols` (2026-08-19), and at least once before that.

## When to use

- `AADSTS700213: No matching federated identity record found for presented assertion subject`
- "Does my branch need to be whitelisted?"
- An `azure/login@v2` step failing with `The process '/usr/bin/az' failed with exit code 1`
- Anyone about to add one more branch to a federated credential list

## What the error actually means

Azure does an **exact string match** on the `sub` claim of the GitHub OIDC token against the
federated identity credentials (FICs) on the app registration. No match, no token. Nothing is
wrong with permissions, the app registration, or the workflow.

The subject depends on the **trigger**, not the branch alone:

| Trigger | Subject presented |
|---|---|
| `push` / `workflow_dispatch` on a branch | `repo:<org>/<repo>:ref:refs/heads/<branch>` |
| `pull_request` | `repo:<org>/<repo>:pull_request` |
| job with `environment:` | `repo:<org>/<repo>:environment:<name>` |
| tag | `repo:<org>/<repo>:ref:refs/tags/<tag>` |

This is why "re-run it" sometimes works and sometimes doesn't: a run from a PR event matches a
`pull_request` credential, while a manual dispatch of the same code does not.

## Triage — three commands

The failing run's log already prints the subject it presented. Read that first; do not guess.

```bash
# 1. what the workflow uses, and on which events
gh api repos/<org>/<repo>/contents/.github/workflows/<file>.yml --jq .content | base64 -d | sed -n '1,40p'

# 2. which app registration (often named in a header comment, or in vars/secrets)
az ad app list --display-name <app-name> --query '[].{appId:appId,objectId:id}' -o table

# 3. what is actually registered
az ad app federated-credential list --id <objectId> --query '[].{name:name,subject:subject}' -o table
```

Compare the subject in the error against column three. The mismatch is always obvious once both
are on screen — and is almost never what the person reported.

**Check whether the CI identity is the same registration the app uses at runtime.** If a DX/Octopus
deploy owns it, every release recreates it and drops the FICs — see [[dx-entra-app-recreation]].
Fixing FICs by hand on a DX-managed registration is undone on the next deploy. For
`manhattan-dl-handler` they are separate: CI is `usx-gha-manhattan-deploy`, runtime is a different
client ID from the `dx-handler` chart.

## Temporary unblock — one credential, one branch

Use when someone is blocked right now. Additive, no downtime, reversible.

```bash
OBJ=<objectId>
az ad app federated-credential create --id $OBJ --parameters '{
  "name": "gha-<branch-slug>",
  "issuer": "https://token.actions.githubusercontent.com",
  "subject": "repo:<org>/<repo>:ref:refs/heads/<branch>",
  "audiences": ["api://AzureADTokenExchange"],
  "description": "Temporary: manual dispatch from a feature branch. Remove once the wildcard lands."
}'
```

They re-run immediately — no PR merge needed.

**If you have no Azure access**, the workaround is the trigger, not the credential: a
`pull_request` credential is usually already registered, so merging (or running from) the PR
authenticates. Manual dispatch from an unregistered branch will not.

⚠️ **Azure caps FICs at 20 per app registration.** Adding one per developer per branch has a hard
ceiling as well as being toil. `usx-gha-manhattan-deploy` was at 9 before this was fixed, serving
two repos.

## Permanent fix, part 1 — a flexible credential

One credential per repo, matching every branch. Stops the toil permanently.

```bash
OBJ=<objectId>
cat > /tmp/fic.json <<'EOF'
{
  "name": "gha-<repo>-any-branch",
  "issuer": "https://token.actions.githubusercontent.com",
  "audiences": ["api://AzureADTokenExchange"],
  "description": "Any branch. Deploy gating is enforced downstream, not by this credential.",
  "claimsMatchingExpression": {
    "value": "claims['sub'] matches 'repo:<org>/<repo>:ref:refs/heads/*'",
    "languageVersion": 1
  }
}
EOF
az rest --method POST \
  --uri "https://graph.microsoft.com/v1.0/applications/$OBJ/federatedIdentityCredentials" \
  --headers 'Content-Type=application/json' --body @/tmp/fic.json
rm -f /tmp/fic.json
```

`subject` and `claimsMatchingExpression` are mutually exclusive — a flexible FIC has no `subject`.
Use `az rest` rather than `az ad app federated-credential create`; the CLI wrapper lags on this.

**Is a wildcard acceptable?** It depends where deployment is actually gated. For
`manhattan-dl-handler` the workflow deliberately builds per-branch artefacts
(`manhattan-dl-handler-<branchTag>.zip`) and **ADO release triggers and version filters decide what
deploys**. Gating the token on branch name adds no real control there — anyone can create a branch
— while costing a developer a morning each time. Where nothing downstream gates deployment, use an
environment-scoped FIC instead (`repo:<org>/<repo>:environment:<name>`) and pin the job to a GitHub
Environment with required reviewers. That is tighter, but needs a workflow change.

**Clean up only after a confirmed green run.** Delete the per-branch credentials, keep `master` and
`pull_request`. Deleting a credential someone is mid-release on makes this worse.

```bash
az ad app federated-credential delete --id $OBJ --federated-credential-id <credential-id>
```

## Permanent fix, part 2 — put it in IaC

The wildcard stops the toil. It does **not** make the configuration durable: it exists only in
Azure, in no repository, reviewed by nobody. If the registration is recreated or someone deletes
the credential, there is no record of what it should be. The nine credentials found on
`usx-gha-manhattan-deploy` are exactly that — sediment from repeated manual fixes.

Declare the app registration and its credentials with the `azuread` provider:

```hcl
resource "azuread_application" "gha_deploy" {
  display_name = "usx-gha-manhattan-deploy"
}

resource "azuread_application_federated_identity_credential" "handler_any_branch" {
  application_id = azuread_application.gha_deploy.id
  display_name   = "gha-handler-any-branch"
  issuer         = "https://token.actions.githubusercontent.com"
  audiences      = ["api://AzureADTokenExchange"]
  subject        = "repo:usxpressinc/manhattan-dl-handler:pull_request"
}
```

⚠️ The provider may not yet expose `claimsMatchingExpression`. Check before assuming; if it does
not, either keep the flexible FIC as a documented exception with an `ignore_changes` lifecycle, or
use environment-scoped subjects, which the provider does support.

**Import the existing registration rather than creating a second one.** Creating a new app
registration means a new client ID, which means every consumer needs updating — the failure mode in
[[dx-entra-app-recreation]].

## Known state — usx-gha-manhattan-deploy

```
appId      89e86365-dcfb-494a-a7e5-7b1d8bae2169
objectId   3ddc61b9-d96b-4ed1-85c2-efa1cfe3462d
tenant     bbb5a66d-5c9f-482a-969a-a40304b6bc8d
serves     usxpressinc/manhattan-dl-handler AND usxpressinc/manhattan-dl-sender
workflow   .github/workflows/release.yml — on: pull_request(master, closed), workflow_dispatch
```

Runtime identity is separate: the `dx-handler` chart injects `AUTH__ClientId` /
`AUTH__ClientSecret` into `manhattan/manhattan-dl-pipeline-azuread-secret` on EKS prod. Do not
confuse the two.

Tracked as INFRA-1649.
