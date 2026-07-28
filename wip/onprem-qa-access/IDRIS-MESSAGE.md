# Messages to send Idris

Two blocks, sent at different times. Everything in both is **public** — a CSR, a signed cert, a cluster CA
and a URL. Teams/Slack/email is fine. No 1Password, no GPG. His private key never leaves his laptop; if at
any point you find yourself holding a `.key` file, something has gone wrong — stop and re-read
`docs/runbooks/onprem_cluster_access_runbook.md` § The principle.

---

## Block 1 — send now (he generates key + CSR)

> Setting you up with Platform Admin (cluster-admin) on the on-prem QA cluster, `op-usxpress-qa`.
>
> Same split-provisioning flow as dev: you generate the key, I only ever see the CSR and hand back a signed
> cert. Your dev cert won't work on QA — QA is a separate Talos cluster with its own CA — but **you can reuse
> the same private key**, only the cert has to be re-issued.
>
> Run this on WSL:
>
> ```bash
> mkdir -p ~/.kube/keys && chmod 700 ~/.kube/keys
>
> # Reuse your existing key if you already have one from dev; otherwise generate:
> [ -f ~/.kube/keys/idris-fagbemi.key ] || {
>   openssl genrsa -out ~/.kube/keys/idris-fagbemi.key 4096
>   chmod 600 ~/.kube/keys/idris-fagbemi.key
> }
>
> # QA CSR — the two O= values are what grant the access, so they have to be exact
> openssl req -new -key ~/.kube/keys/idris-fagbemi.key \
>   -subj "/CN=idris-fagbemi/O=onprem-platform-admins/O=onprem-platform-users" \
>   -out /tmp/idris-fagbemi-qa.csr
>
> openssl req -in /tmp/idris-fagbemi-qa.csr -noout -subject   # sanity check
> cat /tmp/idris-fagbemi-qa.csr                               # send me this whole block
> ```
>
> Paste me the entire `-----BEGIN CERTIFICATE REQUEST-----` … `-----END CERTIFICATE REQUEST-----` block.
> It's public, so however is convenient.
>
> One thing worth knowing: the QA bindings are keyed on the **group** (`O=onprem-platform-admins`), not on
> your username — so this is the same cert flow but the cluster side is now group-based, matching how AWS SSO
> maps a permission set to an aws-auth group. Admin certs are issued for **90 days** rather than a year,
> because until we have OIDC there's no per-person revocation on a group binding, so expiry is the control.
> I'll ping you ~2 weeks before it lapses; renewal reuses the same key.

---

## Block 2 — send after signing (he assembles the kubeconfig)

Run `./sign-csr-qa.sh idris-fagbemi <csr-path> admin` first; it prints the cert + CA to paste into the
placeholders below.

> Signed. Three things, all public:
>
> **Server:** `https://10.10.82.51:6443` (needs corp VPN — `nc -vz 10.10.82.51 6443` to confirm)
>
> Save the two blocks I'm pasting below into files, then assemble:
>
> ```bash
> # Paste the SIGNED CERT block into this file:
> nano ~/.kube/keys/idris-fagbemi-qa.crt
> # Paste the CLUSTER CA block into this file:
> nano ~/.kube/keys/op-usxpress-qa-ca.crt
> chmod 600 ~/.kube/keys/idris-fagbemi-qa.crt ~/.kube/keys/op-usxpress-qa-ca.crt
>
> mkdir -p ~/.kube/configs
> CA_DATA=$(base64 -w 0 < ~/.kube/keys/op-usxpress-qa-ca.crt)
> CERT_DATA=$(base64 -w 0 < ~/.kube/keys/idris-fagbemi-qa.crt)
> KEY_DATA=$(base64 -w 0 < ~/.kube/keys/idris-fagbemi.key)
>
> cat > ~/.kube/configs/op-usxpress-qa <<EOF
> apiVersion: v1
> kind: Config
> clusters:
> - name: op-usxpress-qa
>   cluster:
>     server: https://10.10.82.51:6443
>     certificate-authority-data: ${CA_DATA}
> contexts:
> - name: op-usxpress-qa
>   context:
>     cluster: op-usxpress-qa
>     user: idris-fagbemi
> current-context: op-usxpress-qa
> users:
> - name: idris-fagbemi
>   user:
>     client-certificate-data: ${CERT_DATA}
>     client-key-data: ${KEY_DATA}
> EOF
> chmod 600 ~/.kube/configs/op-usxpress-qa
> ```
>
> Keep it as a separate file rather than merging into dev's — then you can hold both and switch:
>
> ```bash
> export KUBECONFIG=~/.kube/configs/op-usxpress-dev:~/.kube/configs/op-usxpress-qa
> echo 'export KUBECONFIG=~/.kube/configs/op-usxpress-dev:~/.kube/configs/op-usxpress-qa' >> ~/.bashrc
> kubectl config get-contexts
> kubectl config use-context op-usxpress-qa
> ```
>
> Smoke tests:
>
> ```bash
> kubectl config current-context     # op-usxpress-qa  <- check this every time before you touch anything
> kubectl auth whoami                # idris-fagbemi, groups include onprem-platform-admins
> kubectl get nodes                  # 13 Ready (3 CP + 5 app + 3 platform + 2 system)
> kubectl auth can-i '*' '*'         # yes
> kubectl get kustomization -n flux-system   # the platform stack
> ```
>
> If `auth whoami` shows the username but `can-i` says no, the group didn't come through — send me the
> `whoami` output rather than re-running anything.
>
> This is **cluster-admin on QA**, so it includes read on every secret in the cluster, including the
> SM-sourced ones. Flagging it rather than burying it. Dev stays whatever tier you had there; this changes
> nothing about dev.
