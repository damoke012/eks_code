# iaac-drafts/ — our own IaC artifacts (not-yet-shipped or transfer-staged)

This is where IaC artifacts we author live BEFORE they're pushed to the canonical repos (`iaac-talos`, `iaac-talos-flux-platform`, etc.), and where transfer bundles to/from other machines are staged.

| Folder | What | Shipped to |
|--------|------|-----------|
| `arc-deploy/` | ARC controller + runner manifests for the RW-2 SQL CICD pipeline. | `iaac-talos-flux-platform` PR #8 (commit `11437db`) + `iaac-talos-flux-cluster` PR #4 + #5. Historical record of the transfer. |
| `risingwave/` | RisingWave Phase 1 IaC artifacts (was `risingwave_iaac_artifacts/`). | Various — see folder. |
| `onprem-external-dns/` | Drafted external-dns IaC. | Shipped into `iaac-talos-flux-platform` op-dev (HTTP DNS path). |
| `onprem-gha-oidc/` | Drafted GHA OIDC IaC. | Shipped via `iaac-talos` PR #30. |
| `onprem-istio-ingress/` | Drafted Istio ingress IaC. | Shipped via `iaac-talos-flux-platform` op-dev `8b0fac3` (HTTP DNS proven 2026-05-19). |

## Conventions

- Once an artifact ships to a canonical repo, leave a `SHIPPED.md` in its subdir with the target repo + PR/commit + date — don't delete the draft, it's the history.
- New drafts: create `iaac-drafts/<kebab-name>/` with a short README explaining what's being authored and the target repo.
- For transfer bundles to WSL → use the `damoke012/eks_code` `arc-deploy-transfer` branch flow (codespace push → WSL pull → `gh api -X PUT` to target repo).
