---
name: cloud-eks-platform-doc
description: "Cloud EKS reference architecture doc (Confluence + artifact) built 2026-07-15, and the KT-docs-are-stale correction for iaac-eks / terraform-variant-apps structure"
metadata: 
  node_type: memory
  type: project
  originSessionId: 161fed6b-7af8-49e8-9abf-c06ed6494c28
---

Built a full **AWS cloud EKS reference architecture** (2026-07-15), verified against live infra + repos.

- **Confluence (source of truth):** https://usxpress.atlassian.net/wiki/spaces/UI/pages/4627202050/ — space `UI`, child of **CloudOps Administration** (`3631775785`). Publish via `scratchpad/push-eks-confluence.sh` / `update-eks-confluence.sh` (body: `scratchpad/eks-confluence-body.xml`).
- **Styled artifact:** https://claude.ai/code/artifact/8fbc2338-45dc-4b9b-a796-05e626c11c30 (source `scratchpad/eks-cloud-platform.html`).
- Confluence + Jira use the **same** Atlassian token (`ATLASSIAN_TOKEN` env, or `CONFLUENCE_TOKEN=` in gitignored `scripts/push-to-confluence.sh`). It is NOT stored in the codespace — must be supplied per session.

**⚠️ The idris-kt KT docs are STALE — do not trust their repo trees:**
- `iaac-eks`: real layout is `deploy/` = orchestration only (config.yaml, secrets.yaml, deploy.ps1); `apps/` = the IaC → `apps/terragrunt` (root.hcl, _envcommon, modules/, live/) + `apps/charts` (Helmfile). There is **no** `deploy/terraform` or `modules/` at root. Default branch `master`. Platform addons live in a **separate repo `iaac-eks-bootstrap`** (Helmfile, dir per component).
- `terraform-variant-apps`: `modules/` has **only `common/` and `apps/`** — there is **no `modules/infrastructure`**. `common/` = eks-data, role, replicator, auth, buckets, kafka, postgres, dynamodb, mongodb-cluster, mongodb-user, mongodb-privatelink. **No `namespace` or `tags` module** — mage creates the namespace via the K8s SDK. `apps/` = api, cron, handler, ui.
- `mage-runner`: magefiles = common.go, github.go, octopus.go, terraform.go. `internal/terraform` also has interface.go, constants.go, script_run.go, terraform.go, terraform_helpers.go + a full unit-test suite.

Related: [[eks-k8s-upgrade]], [[user-doke-onprem-platform]].
