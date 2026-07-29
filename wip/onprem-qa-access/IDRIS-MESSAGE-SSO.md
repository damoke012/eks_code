# Message to Idris — op-usxpress-qa access via AWS SSO

⚠️ **Do not send until the QA Octopus deploy has landed and your own
`kubectl auth whoami` returns `sso:doke@usxpress.com`.** Until the apiserver has the webhook flag, every
step below fails with `Unauthorized` and he'll (reasonably) think it's broken.

Attach `wip/onprem-qa-access/aws-sso-webhook/client-kubeconfig-template.yaml`. Nothing in it is secret — no
key, no cert, no token — so Teams/Slack/email are all fine.

---

Hey Idris,

You've got **Platform Admin on the on-prem QA cluster** (`op-usxpress-qa`).

It works through **AWS SSO** rather than the per-user certificate flow we used on dev — same way you reach
the cloud EKS clusters. Nothing for you to generate: no CSR, no private key, no cert to renew every year.
Under the hood the cluster now runs `aws-iam-authenticator`, which is the same component EKS runs for you;
your SSO role is mapped to a Kubernetes group, and the group grants the access.

## One-time setup (~5 minutes, on WSL)

**1. Install the client plugin**

```bash
curl -Lo /tmp/aws-iam-authenticator \
  https://github.com/kubernetes-sigs/aws-iam-authenticator/releases/download/v0.7.18/aws-iam-authenticator_0.7.18_linux_amd64
chmod +x /tmp/aws-iam-authenticator && sudo mv /tmp/aws-iam-authenticator /usr/local/bin/
aws-iam-authenticator version
```

**2. Add the AWS profile** — append to `~/.aws/config`:

```ini
[profile usx-qa]
sso_start_url  = https://usxpress.awsapps.com/start
sso_region     = us-east-1
sso_account_id = 527101283767
sso_role_name  = op-qa-platform-admin
region         = us-east-2
```

⚠️ **`sso_role_name` must be exactly `op-qa-platform-admin`.** The cluster maps *that specific role*, not
your user. If you sign in under a different permission set (AWSAdministratorAccess, v-dev, whatever) the
cluster won't recognise you, and the error looks like a permissions bug rather than a wrong-profile problem.
If you already have a `usx-qa` profile pointing at a different role, add this one under a new name
(e.g. `op-qa`) and use that instead.

**3. Save the kubeconfig** I've attached to `~/.kube/op-usxpress-qa-sso.yaml`, then:

```bash
export KUBECONFIG=~/.kube/op-usxpress-qa-sso.yaml
echo 'export KUBECONFIG=~/.kube/op-usxpress-qa-sso.yaml' >> ~/.bashrc
```

If you're already juggling kubeconfigs, keep it as its own file and colon-join rather than merging.

## Daily use

```bash
aws sso login --profile usx-qa    # once per 8 hours
kubectl get pods -A
```

That's it. No renewals, ever.

## Validate it (run these in order)

```bash
# 1. Corp VPN reaches the cluster
nc -vz -w 5 10.10.82.51 6443

# 2. You're pointed at on-prem QA — read this, don't skim it
kubectl cluster-info | head -1              # https://10.10.82.51:6443

# 3. Who the cluster thinks you are
kubectl auth whoami
#    Username: sso:<your email>
#    Groups:   [onprem-platform-admins system:authenticated]

# 4. What you can do
kubectl auth can-i '*' '*'                  # yes
kubectl get nodes                           # 13 Ready (3 CP + 5 app + 3 platform + 2 system)
kubectl -n risingwave get pods              # your namespace
```

If step 3 shows the right username but step 4 denies things, the mapping worked and it's an RBAC question —
send me the output. If step 3 says `system:anonymous`, or you get `Unauthorized`, **don't re-run the setup**
— send me what you see. Both have specific causes on our side and re-installing won't touch either.

## Worth knowing

- **Three different things are called "QA".** `10.10.82.51` is on-prem QA. `10.10.82.50` is on-prem **dev** —
  one digit apart, so read the endpoint before you act. `qa-one` is the cloud EKS QA cluster, unrelated.
- **This is cluster-admin**, including read on every secret in the cluster. QA is a deliberate Prod-standard
  mirror, so treat it like prod for anything destructive.
- **Your dev access is unchanged.** Keep using the cert there for now; dev moves to SSO next.
- **Access is revoked by unassigning the permission set in Identity Center**, and takes effect within your
  8-hour session. That's a real improvement on the cert flow, where revocation meant editing the cluster.
- Corp VPN is required, same as everything else on-prem.

Any problems, send me the exact command and output rather than a description — most failure modes here look
identical from the outside.
