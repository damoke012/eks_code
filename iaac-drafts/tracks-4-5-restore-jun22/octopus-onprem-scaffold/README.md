# INFRA-1535 — OnPremise Octopus space IaC scaffold (DRAFT)

**Target repo:** `variant-inc/iaac-octopus-onprem` (team-owned per memory `[On-prem Octopus repo]`).

**Status:** Scaffold only. Standing it up live requires:
1. Octopus admin API token (rotate fresh; do not paste into repo)
2. Verification of the source-cluster service account on the cloud EKS where `cloud-eks-reader-token` originates
3. Test run against op-usxpress-dev as target

## Architecture

```
┌──────────────────┐                ┌──────────────────┐
│  Cloud EKS (src) │                │  op-usxpress-dev │
│                  │                │  (target)         │
│  cloud-eks-      │                │                  │
│  reader-sa       │                │  ns external-    │
│  ↓ token + ca    │                │  secrets         │
│                  │                │                  │
└──────┬───────────┘                └─────────┬────────┘
       │                                      │
       │  ┌──────────────────────────────┐    │
       │  │  Octopus (OnPremise space)  │    │
       │  │                              │    │
       └──┤  Seed-Cross-Cluster-ESO-     ├────┘
          │  Token runbook               │
          │                              │
          │  Steps:                      │
          │  1. Pull SA token from src   │
          │  2. Pull CA cert             │
          │  3. Create Secret in target  │
          │     (cloud-eks-reader-token) │
          │  4. Verify CSS Ready=True    │
          └──────────────────────────────┘
```

## Files in this scaffold

| File | Purpose |
|---|---|
| `terraform/octopus-space.tf` | OnPremise space + project + environment definitions |
| `terraform/runbook-seed-cross-cluster-eso-token.tf` | The runbook + step body |
| `terraform/variables.tf` | Input variables (source cluster ARN, target cluster name, etc.) |
| `terraform/providers.tf` | Octopus + AWS providers |
| `runbook-scripts/seed-cross-cluster-eso-token.ps1` | The runbook script body |

## Provider versions

- octopusdeploy/octopusdeploy ≥ 0.30
- hashicorp/aws ≥ 5.0
- hashicorp/kubernetes ≥ 2.27

## Apply sequence (when ready to stand up)

```bash
# 1. Get Octopus admin token (rotate fresh; never commit)
export OCTOPUS_API_KEY=<paste-rotated-token>

# 2. Initialize and plan
cd terraform/
terraform init
terraform plan -out=tfplan

# 3. Review the plan carefully:
#    - 1 space added (OnPremise)
#    - 1 environment added (op-usxpress-dev-target)
#    - 1 project added (onprem-platform-bootstrap)
#    - 1 runbook added (Seed-Cross-Cluster-ESO-Token)

# 4. Apply
terraform apply tfplan
```

After apply, navigate to Octopus UI:
- Switch to OnPremise space
- onprem-platform-bootstrap project → Runbooks
- Run "Seed Cross-Cluster ESO Token" → select op-usxpress-dev as target
- Verify completion: `kubectl -n external-secrets get secret cloud-eks-reader-token`

## Why scaffold-only tonight

- Don't have rotated Octopus admin token in this session
- Don't have verified source SA on cloud EKS
- Runbook script needs end-to-end test against a known-good cloud cluster before going live on op-usxpress-dev

These are all 30-60 minute tasks but require fresh auth + verification. Scheduling for next session.
