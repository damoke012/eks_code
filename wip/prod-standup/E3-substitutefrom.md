# E3 — postBuild.substituteFrom: kill branch-per-env drift

**The single highest-value prod-insurance item.** It removes the *class* of bug that
branch-per-env keeps generating (dev VIP in QA's CronJob, grafana ES pointing at dev,
external-dns claiming dev's ownership) instead of fixing instances one incident at a time.

End state: **one branch for all clusters**, differing only by a per-cluster ConfigMap.
Then B5 ("no foreign-env strings") is trivially true because there are no env literals
left to be wrong.

**Roll out on QA FIRST** (not torn down, safe), verify byte-identical rendered output,
then dev, then cut op-prod from the unified branch. This is NOT a prod-day task — it's
the thing that makes prod-day safe. Do it per-Kustomization, never repo-wide in one PR.

---

## 1. The per-cluster ConfigMap (in iaac-talos-flux-cluster)

```yaml
# clusters/op-usxpress-qa/flux-system/cluster-vars.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: cluster-vars
  namespace: flux-system
data:
  cluster_name: op-usxpress-qa
  cluster_vip:  "10.10.82.51"
  env:          qa
  aws_account:  "527101283767"
  oidc_issuer:  "d2t7d36wmf0hbm.cloudfront.net"
```

```yaml
# clusters/op-usxpress-prod/flux-system/cluster-vars.yaml  (when prod is cut)
data:
  cluster_name: op-usxpress-prod
  cluster_vip:  "TBD-PROD-VIP"          # from §1 register
  env:          prod
  aws_account:  "937464026810"
  oidc_issuer:  "TBD-PROD-CLOUDFRONT"
```

## 2. Wire each Kustomization

```yaml
spec:
  postBuild:
    substituteFrom:
      - kind: ConfigMap
        name: cluster-vars
```

## 3. Manifests become env-agnostic

```yaml
# etcd-backup CronJob — the INFRA-1623 field
- --endpoints=${cluster_vip}
- --nodes=${cluster_vip}
# external-dns — the still-open txtOwnerId bug
- --txt-owner-id=${cluster_name}
# any ExternalSecret path
remoteRef:
  key: ${cluster_name}/platform/grafana
```

---

## ⚠️ The landmine — read before touching any dashboard Kustomization

`postBuild` substitutes `${...}` across the **whole** built manifest. Grafana dashboard
ConfigMaps are full of `${datasource}`, `${interval}`, `${__rate_interval}` — Flux will
happily blank every one of them, breaking the dashboards silently (green reconcile, dead
panels — the exact failure shape we're trying to eliminate).

**Two options, per Kustomization:**
- Escape dashboard vars as `$${datasource}` (Flux emits a literal `${datasource}`), OR
- Leave dashboard Kustomizations **off** `substituteFrom` entirely (simpler, safer).

**Verification per Kustomization (do NOT skip):**
```bash
flux build kustomization <name> --path <path> \
  --kustomization-file <file> > /tmp/after.yaml
# diff against the pre-change render — the ONLY change should be the intended
# literal → ${var} substitution. Any blanked dashboard var = stop and escape it.
```

---

## Rollout checklist (QA first)

- [ ] Add `cluster-vars` ConfigMap to `clusters/op-usxpress-qa/flux-system/`
- [ ] Convert etcd-backup Kustomization → `${cluster_vip}`, verify render
- [ ] Convert external-dns → `${cluster_name}` (fixes the open txtOwnerId bug too)
- [ ] Convert remaining foreign-env refs one Kustomization at a time
- [ ] Confirm dashboards untouched (escaped or excluded)
- [ ] Repeat on dev
- [ ] Only then: cut op-prod from the unified branch, add its cluster-vars

**Sequencing note:** E2 (fix the literals) and E3 (parameterise them) overlap. Cleanest
is to do E3's conversion AS the E2 fix — replace each `op-usxpress-dev` literal with the
`${cluster_name}` var rather than with the hardcoded QA value. One pass, and the result
is drift-proof instead of drift-corrected.
