# Mimicking the cloud access model on-prem — aws-iam-authenticator on Talos

**Goal:** grant on-prem cluster access the same way Tim was granted prod EKS access — assign an AWS SSO
permission set in Identity Center, done. No CSR, no cert, no per-user cluster change.

**Mechanism:** the component EKS runs for you. Step 7 of the cloud chain (validating the token) is
`kubernetes-sigs/aws-iam-authenticator`; EKS operates it as part of the managed control plane. On Talos we
own the control plane, so we run it ourselves. Its `EKSConfigMap` backend reads `kube-system/aws-auth` in
*exactly* the EKS format — the mapping artifact is the same one you already read on prod.

**Order:** dev (`10.10.82.50`) → QA (`10.10.82.51`) → prod (`10.10.82.52`), same as everything else.

---

## The chain, and what we build

| # | Cloud prod (Tim) | On-prem | Artifact |
|---|---|---|---|
| 1 | Entra → SCIM → Identity Center | unchanged | — |
| 2 | `v-prod` permission set on `937464026810` | new permission set on the cluster's AWS acct | § A |
| 3 | AWS auto-creates `AWSReservedSSO_<ps>_<hash>` | automatic | — |
| 4 | `kube-system/aws-auth` maps role ARN → group | same ConfigMap, same format | `aws-auth-configmap.yaml` |
| 5 | ClusterRoleBindings bind the group | **already written** | `../rbac/` |
| 6 | client exec plugin fetches a token | `aws-iam-authenticator token` | `client-kubeconfig-template.yaml` |
| 7 | **EKS validates the token** | **we run the authenticator** | `daemonset.yaml` + `talos-machineconfig-patch.yaml` |

Steps 1, 3, 5 need no work. The whole project is 2, 4, 6, 7.

**AWS account:** QA uses `527101283767` (the same account QA already uses for SM/S3/IRSA — see
[[qa-vs-dev-delta]]); dev uses `700736442855`. The permission set is assigned **on that account**, not on
the management account.

---

## Two values must be discovered — do not guess either

**1. The SSO role ARN** (after § A, once the permission set is assigned so AWS has provisioned the role):

```bash
aws iam list-roles --profile usx-qa \
  --query "Roles[?starts_with(RoleName,'AWSReservedSSO_op-qa-platform-admin')].Arn" --output text
```

⚠️ **Strip the path.** That returns
`arn:aws:iam::527101283767:role/aws-reserved/sso.amazonaws.com/us-east-2/AWSReservedSSO_op-qa-platform-admin_abc123`.
The authenticator canonicalises assumed-role ARNs with the path removed, so `aws-auth` must say
`arn:aws:iam::527101283767:role/AWSReservedSSO_op-qa-platform-admin_abc123`. Leaving the path in is the
single most common reason this silently fails to match — the request authenticates as anonymous and you get
a `forbidden` that looks like an RBAC problem.

**2. The image tag.** Pin it; don't float. Check the releases and the EKS-distro mirror:

```bash
gh release list --repo kubernetes-sigs/aws-iam-authenticator --limit 5
# public.ecr.aws/eks-distro/kubernetes-sigs/aws-iam-authenticator:<TAG>
```

`{{SessionNameRaw}}` (used in `aws-auth-configmap.yaml`) needs **>= v0.5.0**.

Both are marked `<FILL>` in the manifests. Nothing applies cleanly until they're replaced — deliberately.

---

## A. Identity Center — the permission set

Doke has `AWSAdministratorAccess` on the Variant mgmt account `660075424663`; Identity Center is
**us-east-1**, instance `ssoins-7223eb10c0b8ac39`.

1. Create permission set **`op-qa-platform-admin`**.
2. **It needs almost no AWS permissions.** This is the part that surprises people: the K8s grant comes from
   *which role you assumed*, not from any IAM policy on it. An inline policy allowing only
   `sts:GetCallerIdentity` is sufficient. Do not attach admin policies to make it "work".
3. Assign it on account **`527101283767`** to Idris — a direct **user** assignment, not a group, for the
   same reason Tim's was direct: SCIM sync is stale (the dashboard still warns about an expiring SCIM
   token — see [[eks-human-access-model]], the follow-up to rotate it is still open).
4. Session duration: 8h is reasonable. This is the access window before re-login, and with no OIDC-style
   refresh it is also the revocation lag.

Later tiers reuse this shape: `op-qa-platform-operator`, `op-qa-platform-reader` → the operator/reader
groups already bound in `../rbac/`.

---

## B. Rollout order — this is the part that can take the apiserver down

kube-apiserver will **fail to start** if `--authentication-token-webhook-config-file` points at a file that
does not exist. On an immutable OS that file has to get onto the host before the flag does. So:

**B1. Deploy the authenticator first, with no apiserver flag set.**

```bash
kubectl apply -f rbac-server.yaml -f aws-auth-configmap.yaml -f daemonset.yaml
kubectl -n kube-system rollout status ds/aws-iam-authenticator
```

The DaemonSet's `init` container generates the server cert and writes the webhook kubeconfig to
`/var/lib/aws-iam-authenticator/` on each control-plane node.

**B2. Verify the file exists on *every* control-plane node.** QA has 3 (`10.10.82.25/.24/.177`). If it is
missing on one, that node's apiserver will not come back in B3.

```bash
for n in 10.10.82.25 10.10.82.24 10.10.82.177; do
  echo "== $n"; talosctl -n $n ls /var/lib/aws-iam-authenticator/
done
```

**B3. Only then** apply `talos-machineconfig-patch.yaml` (adds the flag + the hostPath mount) and let the
control plane roll. Watch node-by-node; stop if the first apiserver does not come back.

**Why this is survivable:** the flag needs the **file**, not a reachable server. If the authenticator is
down, webhook auth fails and **x509 cert auth is unaffected** — your tfstate-derived `system:masters`
kubeconfig keeps working throughout. Keep it open in a second terminal for the entire rollout.

**Rollback**, fastest first:
1. `kubectl delete ds -n kube-system aws-iam-authenticator` — SSO auth stops, certs unaffected, apiserver
   untouched. Use this if the *mapping* is wrong.
2. Revert the machineconfig patch + rolling apply — if the *flag* is the problem.

---

## C. No AWS credentials are needed on the cluster

Worth stating because it removes a whole class of plumbing people expect: the token is a **presigned
`sts:GetCallerIdentity` URL**. The server executes the caller's own signed request — it does not need its
own IAM identity, so **no IRSA, no node role, no secret**. It only needs egress to STS.

```bash
# from a CP node, before B3
curl -sS -o /dev/null -w '%{http_code}\n' https://sts.us-east-2.amazonaws.com/
```

(The `{{EC2PrivateDNSName}}` template *would* need credentials. We don't use it — these are vSphere nodes.)

---

## D. Idris's side — what "mimic Tim" actually costs him

One binary install, once:

```bash
# WSL
curl -Lo aws-iam-authenticator https://github.com/kubernetes-sigs/aws-iam-authenticator/releases/download/<FILL>/aws-iam-authenticator_<FILL>_linux_amd64
chmod +x aws-iam-authenticator && sudo mv aws-iam-authenticator /usr/local/bin/
```

Then `client-kubeconfig-template.yaml` with no edits, and from then on it is Tim's flow exactly:

```bash
aws sso login --profile usx-qa
kubectl get nodes
```

Unlike EKS there is no `aws eks update-kubeconfig`, so we hand him the kubeconfig once. That is the only
residual difference from the cloud experience, and it is a file we can send in a message — no key, no cert,
nothing secret in it.

---

## E. Verification

```bash
# The token resolves and carries the right identity
aws-iam-authenticator token -i op-usxpress-qa | jq -r '.status.token' | head -c 40

# Server-side: the mapping matched
kubectl auth whoami
#   Username: sso:idris.fagbemi@usxpress.com
#   Groups:   [onprem-platform-admins system:authenticated]

kubectl auth can-i '*' '*'          # yes
kubectl get nodes                   # 13 Ready

# Server logs show the match — check here first when it says forbidden
kubectl -n kube-system logs ds/aws-iam-authenticator | grep -i "access granted\|no mapping"
```

**If it says `forbidden`:** the failure is almost always the ARN path (§ Discovery, item 1), not RBAC.
`kubectl auth whoami` returning `system:anonymous` means the mapping did not match; returning the right
username but denying the action means it did match and the problem is genuinely RBAC.

---

## F. What this retires

- The per-user cert flow becomes **break-glass only** — one cert-based admin kubeconfig, offline, per the
  runbook's break-glass plan. Everyone else goes through SSO.
- **The 90-day admin cert expiry hack goes away.** Its only purpose was compensating for the fact that a
  group binding has no per-person revocation. With SSO, revocation is unassigning the permission set, and
  it takes effect within the session duration set in § A4.
- The [[rw-platform-sso-entra]] Entra-OIDC work (INFRA-1591) is **not** made redundant — it is the better
  answer for app-level SSO and for anything non-AWS. This closes the *cluster-access* gap without waiting on
  Azure access we don't have.

## G. Open

- Prod: same build, but do **not** assign a standing admin permission set. Reader by default, admin via
  a separate permission set with a short session duration (the PIM-equivalent we can actually implement).
- Dev already has cert users; they keep working through the transition (both auth paths are live at once).
- Rotate the Identity Center SCIM token — still open from Tim's ticket, and it will cause phantom
  "no access" reports here too.
