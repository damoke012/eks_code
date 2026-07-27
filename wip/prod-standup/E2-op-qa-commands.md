# E2 — fix foreign-env literals on op-qa (RUN ON WSL)

Must run where the repo lives (corp GHE on WSL). The codespace can't reach variant-inc
and its token must never touch these repos. Do this BEFORE cutting op-prod from op-qa —
every literal left here is inherited by prod.

## 1. Find every hit

```bash
cd ~/work/iaac-talos-flux-platform     # or wherever the platform repo is checked out
git fetch origin
git grep -nE "op-usxpress-dev|10\.10\.82\.50" origin/op-qa
```

Known from the prod-automation doc (verify against live grep — do not trust this list):

| File:line | Literal | Fix |
|---|---|---|
| `arc-runner-rw-pipeline/externalsecret.yaml:20` | `op-usxpress-dev` in remoteRef key | → `${cluster_name}` (E3) or `op-usxpress-qa` |
| `ecr-credentials/rbac.yaml:7` | `op-usxpress-dev` | → same |
| `octopus-worker/release.yaml:77,81` | `op-usxpress-dev` | → same |
| external-dns values | `txtOwnerId=op-usxpress-dev` | → `${cluster_name}` — **QA is claiming DNS ownership as dev RIGHT NOW**, live blast radius, do this one first |

## 2. Two ways to fix — prefer the E3 way

- **Quick fix:** replace `op-usxpress-dev` → `op-usxpress-qa`. Corrects the instance,
  leaves the class (prod will need the same fix again).
- **Durable fix (preferred):** replace with `${cluster_name}` and wire the Kustomization
  to `substituteFrom` per `E3-substitutefrom.md`. One pass, drift-proof, and prod inherits
  a correct manifest instead of another literal to chase.

## 3. external-dns first — it has live blast radius

QA's external-dns writing TXT records owned by `op-usxpress-dev` means QA and dev are
fighting over DNS ownership. Everything else here is latent; this one is active. Fix,
PR to `op-qa`, reconcile, and confirm:

```bash
kubectl -n external-dns logs deploy/external-dns | grep -i "txt-owner\|ownerId"
# should show op-usxpress-qa, not op-usxpress-dev
```

## 4. Verify clean

```bash
git grep -nE "op-usxpress-dev|10\.10\.82\.50" origin/op-qa   # zero hits = B5 passes for QA
```
