# SOP — a DX deployment fails at DX-Apply

**Audience:** Application teams and Cloud/Platform · **Owner:** Cloud/Platform
**Version:** 1.0 (2026-08-13)

---

## ⚠️ Rule zero — a failed deploy is never a reason to Clean release

"Clean up entire project" destroys and recreates the app's resources, **including its Azure app
registration**. That mints a new client ID, and every service that calls this one fails
authentication until *it* gets a full release.

On 2026-08-10 three clean releases of `orders-api` produced four client IDs and left **15 services
unable to authenticate for over 16 hours**.

Every failure mode below has a fix that does not touch identity. Work through them first.

---

## Failure 1 — `no matches for kind` / `external-secrets.io/v1beta1`

```
Error: ... external-secrets.io/v1beta1 ... no matches for kind
```

**Cause:** the release pins old `mage-runner` / `terraform-variant-apps` versions that emit an API
version the cluster no longer serves. Any project that hasn't been released recently hits this.

**Fix:** push an **empty commit** to the repo and let CI cut a **new release**, which picks up
current tooling. Deploy that.

```bash
git commit --allow-empty -m "chore: refresh tf-apps/mage versions"
git push
```

Confirmed working 2026-08-13 on `trailer-validation-alert-api` and
`usx-orders-auto-booking-handler`.

---

## Failure 2 — `Error: <resource> already exists`

```
Error: configmaps "myapp-iaac-replicator" already exists
Error: configmaps "myapp-m-u"             already exists
Error: secrets    "myapp-m-i"             already exists
```

**Cause:** the object exists in the cluster but not in Terraform state, so the apply tries to
create it. Usually because a previous apply created it and then failed before writing state.

**First, check how old they are** — that decides whether deleting is trivial or delicate:

```bash
export KUBECONFIG=$HOME/.kube/prod.yaml
kubectl -n <ns> get cm,secret | grep <app>
kubectl -n <ns> get cm <name> -o custom-columns=NAME:.metadata.name,CREATED:.metadata.creationTimestamp
```

**Created minutes ago** → orphans from the failed apply. Nothing consumed them. Safe to delete.
**Long-standing** → check whether the running Deployment uses them before deleting:

```bash
kubectl -n <ns> get deploy <app> -o json | jq -r '.spec.template.spec |
  ((.volumes//[])[] | "vol      \(.configMap.name // .secret.secretName // "-")"),
  ((.containers[].envFrom//[])[] | "envFrom  \(.configMapRef.name // .secretRef.name)")'
```

**Then delete the named objects and re-run the deployment.** Terraform creates them and records
them in state.

> ⚠️ **Do not restart the pods between the delete and the re-run.** If an object is referenced by
> `envFrom`, running pods survive (env is read at container start) but any pod that stops **cannot
> restart** — `CreateContainerConfigError`. Until the apply completes, the service has no safety
> net against a node drain, eviction or Karpenter consolidation.

---

## Failure 3 — the deploy hangs, then `context deadline exceeded`

```
Error: context deadline exceeded
  with helm_release.api, on main.tf line 84
```

and in the cluster:

```
CreateContainerConfigError   Error: configmap "<app>-m-u" not found
```

**Cause:** a deadlock. Helm waits for the rollout; the new pod can't start because a ConfigMap or
Secret it needs via `envFrom` is missing; so the rollout never completes.

**Fix — restore the missing object from Terraform state, while the task is still waiting.** The
pod then starts, Helm's wait is satisfied, and the task completes on its own.

```bash
# find the state key
aws s3 ls s3://<tf-state-bucket>/USXpress/<app>/common/ --profile usx-prod

# read the exact content Terraform recorded
aws s3 cp s3://<tf-state-bucket>/USXpress/<app>/common/mongodb-user - --profile usx-prod \
  | jq -r '.resources[] | select(.type=="kubernetes_config_map_v1") |
           {name:.name, metadata:.instances[].attributes.metadata, data:.instances[].attributes.data}'
```

Recreate it with **identical content and labels** so state stays valid and the next apply sees no
drift. For a Secret, print `keys` only and never the values:

```bash
... | jq -r '.resources[] | select(.type=="kubernetes_secret_v1") | {name:.name, keys:(.instances[].attributes.data|keys)}'
```

If the task has already timed out, restore the object first and then re-run — it goes straight
through.

Worked example: `wip/incidents/2026-08-13-prod-missions-nre-and-tf-state-drift.md`.

---

## Confirming you have NOT broken identity

After any of the above, the app's client ID must be unchanged. The deploy log prints it:

```
Outputs: auth
client_id: dd0d634d-efef-4b13-b762-2e9cfd9745f8
```

And the secret's `CreatedDate` tells you which kind of deploy ran:

```bash
aws secretsmanager describe-secret --secret-id azure-app-dx-<env>-usxpress-<app> \
  --profile usx-prod --query '{Created:CreatedDate,LastChanged:LastChangedDate}'
```

| Shape | Meaning |
|---|---|
| `Created` old, `LastChanged` recent | **ordinary deploy** — secret rotated in place, registration untouched |
| `Created` == `LastChanged`, both recent | **destroyed and rebuilt** — new client ID, consumers will break |

---

## Prevention

Projects that don't deploy regularly are the ones that fail during incidents. `usx-missions-api`
had not deployed to prod since **May 2025**, which is why its state and the cluster had diverged.

Find the backlog before it finds you:

```bash
: "${O:?}"; : "${K:?}"; : "${SP:=Spaces-245}"
curl -s -H "X-Octopus-ApiKey: $K" "$O/api/$SP/projects/all" | jq -r '.[] | [.Id,.Name] | @tsv' > /tmp/projnames.txt
curl -s -H "X-Octopus-ApiKey: $K" "$O/api/$SP/deployments?environments=Environments-902&take=2000" \
  | jq -r '.Items[] | [.ProjectId,.Created] | @tsv' > /tmp/proddeps.txt
sort -k2,2r /tmp/proddeps.txt | awk -F'\t' '!seen[$1]++' \
  | awk -F'\t' 'NR==FNR{n[$1]=$2;next}{printf "%-45s %s\n", (n[$1]?n[$1]:$1), $2}' /tmp/projnames.txt - | sort -k2
```

Oldest first. Everything at the top will fail the next time it's deployed, and someone will reach
for a clean release under pressure.

---

## Quick reference

| | |
|---|---|
| **Never** | "Clean up entire project" to get past a failed deploy |
| `v1beta1` / `no matches for kind` | empty commit → new release |
| `already exists` | check timestamps → delete orphans → re-run |
| `context deadline exceeded` + `CreateContainerConfigError` | restore the object from Terraform state in S3 |
| **Between delete and re-run** | do not restart pods |
| **Confirm** | `client_id` unchanged in the deploy log |

Related: [SOP-mongo-connection-pool-paused](SOP-mongo-connection-pool-paused.md) ·
[SOP-spa-auth-client-id](SOP-spa-auth-client-id.md) · `/prod-auth-triage`
