---
name: usx-github-enterprise-not-personal
description: "All USX repo work lives in USX GitHub Enterprise (Doke's corp identity, on WSL); the codespace's damoke012 personal GitHub is unrelated and must NEVER be used to reach USX/variant-inc repos"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 161fed6b-7af8-49e8-9abf-c06ed6494c28
---

All real infra work — `variant-inc/iaac-talos-flux-platform`, `iaac-talos-flux-cluster`, `iaac-eks`, `iaac-eks-bootstrap`, `mage-runner`, `terraform-variant-apps`, etc. — lives in **USX GitHub Enterprise**, accessed only from Doke's **WSL** box under his corp identity. The codespace's `GITHUB_TOKEN` is the **personal `damoke012`** account and has NO access (404) to variant-inc / USX org repos — and it must stay that way.

**Why:** conflating personal GitHub with corp GHE is wrong on both counts — correctness (404s, wrong identity) and separation-of-concerns (a personal account should never touch corp work). I did exactly this on 2026-07-20, running `gh api repos/variant-inc/iaac-talos-flux-platform/...` from the codespace and getting 404s; Doke flagged it as a line never to cross.

**How to apply:** any repo read/verify for USX work (PR diffs, manifest headers like `infrastructure/wiz-sensor/externalsecrets.yaml`, branch state) → **hand Doke the commands to run on WSL**; never run `gh`/git against variant-inc or USX repos from this codespace. The codespace is only for the local `eks_code` scratchpad + scripts (Jira/Confluence Atlassian API, memory). Same identity-separation principle as [[wsl-kubeconfig-churn]] (cluster access is WSL + corp VPN, not here).

Related: [[wsl-kubeconfig-churn]], [[user-doke-onprem-platform]], [[wiz-sensor-onprem-dev]].

**It bites in BOTH directions (2026-08-20).** WSL had `dare-x` as gh's active account and a
push to the *personal* notes repo failed: `remote: Permission to damoke012/eks_code.git denied
to dare-x` (403). The rule is usually stated as "don't let the personal token reach a USX
repo"; the corp identity reaching the personal repo is the same fault line and just as likely,
because WSL does both kinds of work in one shell.

`gh auth status` on WSL holds BOTH accounts. Do **not** fix it with a bare `gh auth switch` and
rely on remembering to switch back — forgetting is the failure this rule exists to prevent.
Scope the credential to the single command instead:

    GH_TOKEN=$(gh auth token --hostname github.com --user damoke012) \
      git -c credential.helper='!f(){ echo username=damoke012; echo password=$GH_TOKEN; };f' \
      push origin main

The active account never changes, so the next `variant-inc` command is still `dare-x`.
Adding `damoke012@` to the remote URL does NOT fix it — git still asks the credential helper,
and GitHub rejects passwords for git operations regardless.
