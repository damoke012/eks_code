# ArgoCD dev adoption — execution runbook (INFRA-1622, Steps 2+3)

Adopt the 49-day raw ArgoCD install on op-usxpress-dev into the Flux platform
stack (`infrastructure/argocd/`), chart 10.2.0 (v3.4.5). Method: **delete-and-
reinstall preserving `argocd-secret`** (so `server.secretkey` survives → sessions
+ admin login unbroken). RW is Flux-served throughout — zero workload impact.

ALWAYS: `export KUBECONFIG=~/.kube/op-usxpress-dev-fresh.yaml` and confirm
`kubectl cluster-info | head -1` == 10.10.82.50 before every phase.

## PHASE A — BACKUP (makes everything reversible; do not skip)
```bash
mkdir -p /tmp/argocd-dev-backup && cd /tmp/argocd-dev-backup
# the whole namespace, and the one secret that matters, separately
kubectl -n argocd get all,cm,secret,sa,role,rolebinding,networkpolicy,appproject -o yaml > argocd-ns-full.yaml
kubectl -n argocd get secret argocd-secret -o yaml > argocd-secret.yaml
kubectl -n argocd get secret argocd-secret -o jsonpath='{.data.server\.secretkey}' > server.secretkey.b64
kubectl get crd -o name | grep argoproj > argocd-crds.txt
wc -l argocd-ns-full.yaml argocd-secret.yaml; echo "server.secretkey bytes:"; wc -c server.secretkey.b64
```
GATE: `argocd-secret.yaml` non-empty and `server.secretkey.b64` non-zero. If not, STOP.

## PHASE B — LAND THE MANIFESTS (safe; nothing deleted yet)
```bash
cd ~/work/eks_code && git pull --ff-only
cd ~/work/iaac-talos-flux-platform && git fetch origin
git checkout -B feat/argocd-platform-stack origin/op-dev
mkdir -p infrastructure/argocd
cp ~/work/eks_code/wip/argocd-dev-adoption/infrastructure-argocd/*.yaml infrastructure/argocd/

# verify the chart renders with these values (proves server.insecure, no NodePort, secret not created)
helm repo add argo https://argoproj.github.io/argo-helm 2>/dev/null; helm repo update argo
python3 -c "import yaml; d=[x for x in yaml.safe_load_all(open('infrastructure/argocd/helmrelease.yaml')) if x][0]; yaml.safe_dump(d['spec']['values'], open('/tmp/argo-vals.yaml','w'))"
helm template argocd argo/argo-cd --version 10.2.0 -n argocd -f /tmp/argo-vals.yaml > /tmp/argo-render.yaml
echo "NodePort (want 0):"; grep -c NodePort /tmp/argo-render.yaml
echo "creates argocd-secret? (want 0 — createSecret:false):"; grep -c 'kind: Secret' /tmp/argo-render.yaml
echo "server.insecure present (want 1):"; grep -c 'server.insecure' /tmp/argo-render.yaml

git add infrastructure/argocd && git commit -m "feat(argocd): platform stack for op-dev — adopt the raw install (INFRA-1622)

Populates the infrastructure/argocd path the 'argocd' Flux Kustomization has
been failing on for 17 days. Chart 10.2.0 (v3.4.5), configs.secret.createSecret
false to preserve the live argocd-secret (server.secretkey), app-* AppProject,
default project neutered, ClusterIP + no NodePort, dex/notifications off. Admin
password via ExternalSecret (existing op-usxpress-dev/risingwave/argocd path;
SM migration is a follow-up)."
git push -u origin feat/argocd-platform-stack && gh pr create --base op-dev --fill
```
GATE: render shows **0 NodePort, 0 Secret, 1 server.insecure**. Merge the PR.
Do NOT reconcile yet — the raw install still occupies the namespace.

## PHASE C — CUTOVER (the one destructive step; argocd-secret is PRESERVED)
```bash
# 1. delete the raw-installed workloads + config, KEEPING secrets + CRDs + appprojects
kubectl -n argocd delete deploy,statefulset,service,configmap,serviceaccount,role,rolebinding,networkpolicy \
  -l app.kubernetes.io/part-of=argocd
# also drop the hand-made NodePort service if it wasn't labelled
kubectl -n argocd delete service argocd-server-nodeport --ignore-not-found
# dex was disabled in our values — remove its orphaned workload if present
kubectl -n argocd delete deploy argocd-dex-server --ignore-not-found

# 2. confirm argocd-secret SURVIVED (this is the whole safety premise)
kubectl -n argocd get secret argocd-secret -o jsonpath='{.data.server\.secretkey}' | head -c 12; echo "  <- must be non-empty, matches backup"

# 3. let Flux install the chart into the now-clean namespace
flux reconcile kustomization argocd --with-source
kubectl -n argocd get helmrelease argocd
```
GATE: `argocd-secret` still present with the SAME server.secretkey as the backup.
If it's gone, restore immediately: `kubectl apply -f /tmp/argocd-dev-backup/argocd-secret.yaml`

## PHASE D — VERIFY
```bash
kubectl -n argocd get pods                              # server/controller/repo/redis Running
kubectl -n argocd get svc                               # ClusterIP only, NO NodePort
kubectl -n argocd get appproject default -o jsonpath='{.spec.destinations}'; echo   # []
# server.secretkey unchanged vs backup:
diff <(kubectl -n argocd get secret argocd-secret -o jsonpath='{.data.server\.secretkey}') \
     /tmp/argocd-dev-backup/server.secretkey.b64 && echo "server.secretkey PRESERVED"
# guardrail: an app targeting a Flux ns must be REFUSED
argocd login <server> --username admin --grpc-web 2>/dev/null || echo "(login via UI/port-forward)"
```
GATE: pods Running, no NodePort, default project destinations `[]`, server.secretkey
matches backup. Then the adoption is complete.

## ROLLBACK (any phase)
```bash
kubectl -n argocd apply -f /tmp/argocd-dev-backup/argocd-ns-full.yaml
# and revert the Flux Kustomization by removing infrastructure/argocd or suspending:
flux suspend kustomization argocd
```

## STEP 3 — SM PATH MIGRATION (after Phase D is green, separate change)
```bash
# copy the value to the platform path, repoint the ExternalSecret, verify, delete old
aws secretsmanager get-secret-value --profile usx-dev --secret-id op-usxpress-dev/risingwave/argocd \
  --query SecretString --output text > /tmp/argocd-admin.json
aws secretsmanager create-secret --profile usx-dev --name op-usxpress-dev/platform/argocd \
  --secret-string file:///tmp/argocd-admin.json
# edit admin-externalsecret.yaml remoteRef.key -> op-usxpress-dev/platform/argocd, commit/push/merge, reconcile
# confirm argocd-secret still has admin.password, then:
# aws secretsmanager delete-secret --profile usx-dev --secret-id op-usxpress-dev/risingwave/argocd --recovery-window-in-days 7
rm -f /tmp/argocd-admin.json
```
