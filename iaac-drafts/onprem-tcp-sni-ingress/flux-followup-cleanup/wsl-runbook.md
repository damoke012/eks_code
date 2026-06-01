# WSL runbook — Phase 1 followup PR

**Prereq**: WSL has push access to `variant-inc/iaac-talos-flux-platform`.
**Branch base**: `op-dev`.
**One PR for both cleanups.** ~10 min wall-clock.

---

## 0. Pre-flight (no changes)

```bash
# Sanity — RW-2 still healthy before we touch GitOps source
kubectl get rw -A
# Both ns should be Running=True (NB: risingwave ns may still be down on Idris's track — only risingwave-2 needs to be green for our work)

# Pull worker IP list (verify it matches external-dns-release-delta.md)
kubectl get nodes -l '!node-role.kubernetes.io/control-plane' \
  -o jsonpath='{range .items[*]}{.status.addresses[?(@.type=="InternalIP")].address}{"\n"}{end}'

# Refresh local clone
cd ~/repos/iaac-talos-flux-platform  # or wherever
git fetch origin
git checkout op-dev
git pull --ff-only origin op-dev
git checkout -b feat/persist-phase1-tcp-sni-listeners
```

## 1. Drop in the Gateway + VS files

```bash
# Inspect layout — flat dir or kustomization-based?
ls infrastructure/istio-ingress/
test -f infrastructure/istio-ingress/kustomization.yaml \
  && echo "NEED kustomization update" \
  || echo "flat dir — drop YAMLs directly"

# Copy from codespace (assumes you've synced eks_code to WSL or scp'd)
cp ~/eks_code/iaac-drafts/onprem-tcp-sni-ingress/flux-followup-cleanup/gateway-tcp-passthrough.yaml \
   infrastructure/istio-ingress/

cp ~/eks_code/iaac-drafts/onprem-tcp-sni-ingress/flux-followup-cleanup/virtualservice-rw2-sql.yaml \
   infrastructure/istio-ingress/
```

If `kustomization.yaml` exists, add the two filenames under `resources:`:

```yaml
resources:
  # ... existing ...
  - gateway-tcp-passthrough.yaml
  - virtualservice-rw2-sql.yaml
```

## 2. Patch external-dns release.yaml

Edit `infrastructure/external-dns/release.yaml`. Under `values.extraArgs`, append 7 `--default-targets=...` lines per the delta doc.

```bash
# Quick sanity diff against what's there
git diff infrastructure/external-dns/release.yaml
```

## 3. Commit + push + PR

```bash
git add infrastructure/istio-ingress/gateway-tcp-passthrough.yaml \
        infrastructure/istio-ingress/virtualservice-rw2-sql.yaml \
        infrastructure/external-dns/release.yaml \
        infrastructure/istio-ingress/kustomization.yaml  # only if you edited it

# If kustomization.yaml wasn't touched, drop it from the git-add line.

git commit -m "Persist Phase 1 TCP/SNI listeners to GitOps; move external-dns target to --default-targets

INFRA-1494 followup:
- Gateway tcp-passthrough + VirtualService rw2-sql-passthrough now in source
  (previously kubectl-applied at Phase 1 closure 2026-06-01)
- external-dns --default-targets=<7 worker IPs> replaces per-VS annotation;
  applies to all istio-virtualservice sources, drift-resistant"

git push -u origin feat/persist-phase1-tcp-sni-listeners

gh pr create --base op-dev --title "Persist Phase 1 TCP/SNI listeners + move external-dns target to --default-targets" --body-file ~/eks_code/iaac-drafts/onprem-tcp-sni-ingress/flux-followup-cleanup/pr-body.md
```

## 4. Watch reconcile after squash-merge

```bash
flux reconcile source git infra --timeout 2m
flux reconcile kustomization infrastructure --timeout 5m

kubectl -n istio-ingress get gateway tcp-passthrough
kubectl -n istio-ingress get virtualservice rw2-sql-passthrough
# These should now show ownership/labels from Flux (kustomize.toolkit.fluxcd.io/name).

flux reconcile helmrelease -n flux-system extd-usxpress-io --timeout 5m
kubectl -n external-dns logs -l app.kubernetes.io/name=external-dns --tail=80 | grep -iE "default-target|rw2-sql"
```

## 5. Drop the per-VS target annotation (post-merge only!)

```bash
# Only AFTER Step 4 confirms external-dns is using --default-targets:
kubectl -n istio-ingress annotate virtualservice rw2-sql-passthrough \
  external-dns.alpha.kubernetes.io/target-

# Confirm A-record still resolves to the same 7 IPs:
sleep 90  # external-dns interval
getent hosts rw2-sql.op-dev.usxpress.io
```

## 6. Smoke test (post-cleanup)

```bash
openssl s_client -servername rw2-sql.op-dev.usxpress.io \
  -connect rw2-sql.op-dev.usxpress.io:4567 </dev/null 2>&1 | head -10
# Expect same result as Phase 1 closure: CONNECTED + errno=104 (gateway accepted,
# backend RSTs pre-Phase-2). If you get "connection refused" instead, something
# in this followup broke the listener — roll back the PR.
```

## Rollback

```bash
git revert <commit-sha>
git push origin op-dev
# Flux re-reconciles → removes Gateway+VS from source → BUT the live resources
# stay because they were originally kubectl-applied (no Flux-inventory link
# until the merge here). After merge they GAIN an inventory link, so a revert
# WILL prune them. Pre-revert: kubectl apply -f locally first to re-orphan them,
# then revert in source.
```

## Closure

- Closing comment on INFRA-1494 referencing this PR (per "follow-ups completed" line)
- Mark the two cleanup todos in eks_code done
- This unblocks Phase 2 with no drift risk
