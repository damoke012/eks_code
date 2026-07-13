Round 1 — verified against WSL (cluster + PR branch `chore/flux-argocd-repo-sync`).

Thanks Idris. I dug into this and I'm going to ask that we **not merge #73** — the RW repo-sync it adds is already done by Flux, and as written this would collide in Tim's namespace. Details:

**Blockers (all verified)**

1. (BLOCKER — direct collision) This Argo CD app points at `git@github.com:variant-inc/iaac-risingwave-onprem.git` → destination ns `risingwave`. But Flux **already** reconciles exactly that: `flux get kustomizations -A` shows `risingwave-onprem` (Ready=True, `iaac-risingwave-onprem` @ main) plus `risingwave` and `risingwave-routes`. Two controllers on the same source + same namespace = split-brain in Tim's prod ns. There's nothing for Argo CD to add here.

2. (BLOCKER — secret in git) `infrastructure/argocd/argocd_git_secret.yaml` commits a real `sshPrivateKey`. That key must be treated as compromised → **rotate the deploy key now** (independent of this PR) and deliver it via ExternalSecret from Secrets Manager, per our secrets model. Never commit key material.

3. (BLOCKER — coord) Destination is `risingwave` = Tim's namespace. Any change there needs Tim's sign-off first.

**If the goal is INFRA-1487-style anchoring** — it's already live: `risingwave-onprem` Kustomization is the Flux equivalent, working today. If you need to sync additional paths/repos, add a Flux `GitRepository` + `Kustomization` (SSH key via ESO) in `iaac-talos-flux-cluster`, mirroring `risingwave-onprem`. Happy to pair on it.

**Don't lose the good part:** the Grafana "No Data" fix (`9953ad1`) + RW streaming dashboards (`76c50b5`) look independently useful — please split those into their own small PR and I'll review/merge that quickly.

Proposing we **close #73** in favor of the above. If there's a specific reason you want Argo CD as a second controller (app-team self-service UI, etc.), let's talk — that's a real option but it needs its own design + non-overlapping ownership, not a chore PR over a workload Flux already owns.
