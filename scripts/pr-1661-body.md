Rebases `feat/aws-iam-authenticator` onto master and enables the webhook for **op-usxpress-dev**.

### This also fixes a live risk (INFRA-1662)

`op-usxpress-qa` has had working AWS SSO since **2026-07-28**. The flag that makes it work — `enable_aws_iam_authenticator = true` in `envs/qa.tfvars`, plus the module change — exists **only on the unmerged branch**:

```
git branch -r --merged origin/master | grep -c aws-iam-authenticator   ->  0
grep -rn 'authentication-token-webhook-config-file' on master          ->  nothing
```

A QA deploy from master today would silently drop the flag and remove SSO, with every status field green and x509 still working — so it would present as "SSO stopped" with no recent change to point at. Merging this puts the running configuration back in the mainline.

### The rebase

master's 4 extra commits touch `modules/irsa/` only; the branch touches `modules/talos/`, `envs/` and `main.tf`. **Zero file overlap.** The script aborts rather than resolving anything if that stops being true.

### The flag takes the HOST path

`/var/lib/aws-iam-authenticator/kubeconfig.yaml`. Three paths appear in this system and only that one is right — the init container's log says `/etc/kubernetes/...` (upstream generic, wrong on Talos, OS-managed) and the server's says `/var/aws-iam-authenticator/...` (in-container). The module already says so: `# HOST path. The authenticator's own log prints the in-container path; not this one.`

### Ordering — the precondition is not optional

kube-apiserver **will not start** if the webhook config file is missing. The DaemonSet must already be Running and have written the file on **every** control-plane node. Verified on op-usxpress-dev 2026-08-24 20:04 UTC: 3/3 pods on `talos-cp-op-dev-1/2/3`, `RESTARTS 0`. x509 auth is unaffected either way, so the admin kubeconfig stays as break-glass.

### Prod is not in this PR

There is no `envs/prod.tfvars`, and `op-usxpress-prod` appears nowhere in this repository on any branch — `git log --all -S 'op-usxpress-prod' -- deploy/` returns nothing. Prod's authenticator is running (INFRA-1638) but there is no file here to set its flag in. **INFRA-1663** must answer where prod's machine config comes from first; the likely answer is Octopus variables, and that should be confirmed rather than assumed.

### ⚠️ This PR is bigger than its title — read the whole diff

Rebasing the branch brings **everything else on it** too. All of it has been running on op-usxpress-qa since 2026-07-28, so this brings master in line with reality rather than introducing anything new — but it should be reviewed, not waved through:

| Change | Why it matters |
|---|---|
| `deploy.ps1` +91 lines | SM secret-wrapper seeding before the first `enable_irsa` apply, and a **two-pass Flux bootstrap** (CRDs must be Established before the CRs apply) plus seeding the `flux-system` git secret. Greenfield deploys behave differently after this. |
| `octopus/bento-import.py` | **Removes a hardcoded password** from the repo and requires `BENTO_PASSWORD` from the environment. Good change; note it fails closed if the secret is missing. |
| `.github/workflows/onboard-app.yaml` | Passes `BENTO_PASSWORD` through, paired with the above. |
| `octopus/apply-bootstrap-perms.sh` | **Widens an IAM policy** from `role/iaac-octopus-worker-${CLUSTER_NAME}` to `role/*-${CLUSTER_NAME}` and `role/*-${CLUSTER_NAME}-*`. This is a permissions broadening on the bootstrap role and is the one item here that deserves a deliberate yes or no. |

If any of that should land separately, say so and it can be split — but note that leaving it unmerged is what created INFRA-1662 in the first place.

### Acceptance

Not "the plan applied". On op-usxpress-dev, after Octopus promotes:
```
aws sso login --profile usx-dev
kubectl auth whoami     # expect sso:<email>, group onprem-platform-admins
```
A wrong ARN does not error — the caller becomes `system:anonymous` and everything returns `forbidden`.

**Apply is Octopus only.** Nothing was applied to build this PR.
