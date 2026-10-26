# Meeting brief — USX cloud + on-prem platform (eks_code)

Owner of this repo: Dare Oke (Doke), cloud/platform engineer, owns the on-prem Talos clusters.
This repo is the operator's notes, drafts and automation. Nothing is deployed from it.
Last refreshed: 2026-10-26 (evening, after measuring op-prod for SSO readiness).

## Current status
- Sprint 7 (Jira board 322, sprint id 6296) opened 2026-10-19 with 13 issues; Sprint 6 closed 8 of 8.
- Sprint 7 headline ask: make on-prem prod (op-usxpress-prod) production-ready, starting with AWS SSO.
- Prod SSO is about three-quarters landed: authenticator 3/3, aws-auth and role bindings are live. Only the kube-apiserver webhook flag is missing (it lives in Terraform via Octopus, never scoped to prod).
- Office access to on-prem apps: was blocked by our own Cilium ingress policy. Fixed on dev and QA 2026-10-20, and prod measured 22 CIDRs 2026-10-26 — all three clusters now admit corporate space. The prod PR reference is not recorded.
- RisingWave: new canonical repo usxpressinc/risingwave (branch master) proven end to end to the cluster 2026-10-21. Runbook published to Confluence 2026-10-23.
- Pricing app (pricing-rfp-handler) is the prototype for onboarding cloud apps to on-prem; Idris owns it. INFRA-1719 to 1724 assigned to Idris.
- Argo CD with Entra SSO is live on all three on-prem clusters (dev, QA, prod) since 2026-08-25.
- RisingWave Console: each SSO user got a private organisation, and the cluster is registered per organisation, so anyone whose org was created after 2026-10-06 logged in and saw nothing. Fixed on dev 2026-10-26 (PR #59, iaac-risingwave-onprem): the governance job is now a CronJob every 15 min and puts everyone in org 1. QA and prod still carry the one-shot Job.
- Tim Preble is admin in the Console; everyone else is operator. The admin list is console_admins in the rw-user-definitions ConfigMap, not a hand-made row.
- DBeaver access works today on dev over the NodePort (worker:32567, database dev) but only as root with no password. SSO for DBeaver has never been connected or tested — ticket with Tim.

## Key numbers
- On-prem clusters: three — op-dev, op-qa, op-prod (Talos, self-managed).
- On-prem Kubernetes: v1.32.0 on every node. Upstream end of life was 2026-02-28. No extended support.
- op-qa: 183 pods, 20 namespaces, 30 Flux Kustomizations, all Ready (measured 2026-10-20).
- Cloud EKS: on 1.36 with 1.37 available, held deliberately at N-1.
- RisingWave engine: v3.0.5 on dev, QA and prod; only dev's risingwave-2 namespace is v2.8.2.
- Shared ECR: 515 of 517 repos grant org-wide push; no registry policy.
- Flux versions: dev v2.8.8, QA/prod v2.7.5.

## Decisions (and why)
- Promotion order is QA2 → dev → QA → prod, one at a time. New behaviour defaults OFF behind a per-environment flag, because every environment shares one branch.
- iaac-talos deploys through Octopus only, never a local terraform apply. Octopus green does not mean applied (TfApply gate).
- Human kubectl access is AWS SSO via aws-iam-authenticator. Client certs are break-glass only.
- RisingWave going forward lives in usxpressinc/risingwave; the poc repo and the variant-inc fork are legacy.
- On-prem apps are delivered GHA build → ECR → Argo CD. The app's existing ECR repo is reused.
- On-prem logging parity is ClickHouse (OTEL), not Loki.
- Cloud is moving to Argo CD plus Crossplane, with a long observe-only phase.
- Stay N-1 on versions, but move inside the support window.
- RisingWave Console uses ONE shared organisation, not an organisation per person (Tim, 2026-10-26: "let's go with the easiest thing"). One cluster registration to maintain rather than one per user.
- RisingWave alerts go to dedicated Teams channels, prod and non-prod, filtered by namespace in Grafana. Low-noise by design: define the SLO first, alert only on what matters. App and platform share a channel until QA and prod, then split.

## Risks and blockers
- The iaac-talos Octopus project is DISABLED (seen 2026-10-26). Releases cannot be created and deploys cannot run, which blocks the prod SSO cutover and any other Terraform change to the on-prem clusters. Who disabled it and why is unknown. TfApply is true for production on this project, so disabling it is a plausible deliberate safety catch — re-enabling makes every future prod deploy apply for real.
- There is no permission set named op-prod-platform-admin. The belief that it exists and holds only sts:GetCallerIdentity was measured on QA and assumed symmetric; prod uses the usx-on-prem-* naming instead. Three profiles point at the prod account — ops-controller, usx-prod, op-prod — and only ops-controller can read prod's Secrets Manager.
- On-prem Kubernetes 1.32.0 is out of support and was never patched past .0. Upgrade plan: unknown — confirm.
- aws-auth on QA and prod maps the operator and reader tiers to ARNs with literal FILL placeholders. Only admins can log in usefully. The roles themselves do not exist yet.
- op-prod SSO: the kube-apiserver webhook flag is confirmed ABSENT (measured 2026-10-26). The authenticator DaemonSet is 3/3 and 62 days old, but whether it has written the webhook kubeconfig to each control-plane node is UNMEASURED — the container has no shell, so the usual check cannot run.
- The service CIDR overlaps four registered corporate subnets. Open, ticketed in Sprint 7.
- Pricing app: MongoDB Atlas is reached over AWS PrivateLink (10.16.x.x). The on-prem route to it goes via the transit gateway; one firewall rule and one /24 are needed.
- RisingWave on-prem has no promotion gate: every cluster tracks main, so merging is deploying to prod.
- Alerts on-prem reach nobody, on all three clusters. Measured 2026-10-05: zero Alertmanager and zero Flux notification Providers/Alerts on dev, QA and prod (INFRA-1659). Separately, INFRA-1657 made the Flux rules able to fire on dev and QA; prod is still pending that. The design input for delivery arrived in the 2026-10-26 sync, so 1659 is now build work, not a decision.
- etcd snapshots are PROVEN on all three clusters (2026-10-26), bucket side as well as cluster side: hourly at :17, zero failed jobs, and 742-744 objects in each of etcd-snapshots-op-usxpress-{dev,qa,prod}. That count is 31 days x 24 hours with the oldest key 2026-09-25 on all three, so retention is 31 days and we can restore to any hour within it. The September EtcdSnapshotJobFailing alerts are resolved.
- No etcd snapshot has ever been restored, on any cluster. That is now the open question, not whether backups exist.
- op-dev's snapshot has been 359,747,616 bytes to the byte for 31 days — 3x prod's for a comparable key count. That is free pages, so op-dev's etcd wants a defrag; until then every hourly snapshot carries ~240MB of nothing.
- onprem-build.yml NuGet failure: open, ticketed.
- RisingWave on dev is reachable as superuser with NO password from any corporate machine (NodePort 32567, user root, plaintext). QA and prod declare the identical NodePort; whether their root has a password is UNMEASURED. Raised 2026-10-26.
- Tim's team cannot use DBeaver with their own identity yet. The only known login is shared root credentials, which Tim wants replaced.

## Next milestones
- Create the operator and reader SSO roles, then fix the aws-auth placeholders on QA and prod.
- Land the kube-apiserver webhook flag on prod (INFRA-1661). The prerequisite is PROVEN as of 2026-10-26: the webhook kubeconfig is present on all three prod control-plane nodes at 1909 bytes, the same size as QA's. BLOCKED on Octopus: the iaac-talos project is DISABLED, so no release can be created and no deploy can run.
- Pricing app Stage 1 onboarding to on-prem (Idris).
- Kubernetes upgrade plan for on-prem 1.32. Date: unknown — confirm.

## Owners
- Dare Oke (Doke): on-prem platform, Talos clusters, SSO, Argo CD, RisingWave platform side.
- Idris: pricing app onboarding (INFRA-1719 to 1724) and the onboarding guide.
- Tim: reported and re-tested the office-access block; role otherwise unknown — confirm.
- Network team: owns the corporate firewall; the office block turned out to be ours, not theirs.
- RisingWave data pipeline owners: unknown — confirm.

## Architecture in brief
- On-prem: Talos Kubernetes on Nutanix. Cilium CNI, Istio ambient, Rook-Ceph storage, Flux for the platform, Argo CD for apps.
- Four GitOps repos: iaac-talos (Terraform, via Octopus), iaac-talos-flux-cluster, iaac-talos-flux-platform (op-dev/op-qa/op-prod branches), and the app repos.
- Identity: Entra ID for app SSO (Argo CD uses app roles, the tenant never sends a groups claim). AWS IAM Identity Center for kubectl.
- Secrets: External Secrets Operator from AWS Secrets Manager. A green sync does not prove the value works.
- DNS: external-dns from VirtualService annotations into the network account (155768531003), zone usxpress.io.
- Cloud: EKS clusters dev, QA, prod (usxpress-prod), apps deployed by Octopus/DX today.
- AWS and on-prem are joined by a transit gateway (tgw-09c7b37043d31e43a) with a live VPN.

## Likely questions
- What's the status of prod readiness? SSO is mostly there; the one missing piece is the API server webhook flag, which goes through Octopus. Then we fix the operator and reader role mappings.
- Can people log in to prod with SSO today? Admins can. Operators and readers cannot yet; their roles do not exist and the mappings hold placeholders.
- Why couldn't the office reach on-prem apps? Our own Cilium ingress policy only allowed the VPN pool. Fixed on dev and QA on 2026-10-20; prod is next.
- What Kubernetes version is on-prem on? 1.32.0 everywhere. It left upstream support in February, so an upgrade plan is needed.
- What version is EKS on? 1.36, one behind the latest 1.37, on purpose.
- Where does RisingWave live now? usxpressinc/risingwave, branch master. It is proven end to end to the cluster, and the runbook is on Confluence.
- What RisingWave version runs? v3.0.5 on dev, QA and prod.
- How does an app get to on-prem? Build in GitHub Actions, push to its existing ECR repo, Argo CD deploys it. The pricing app is the first through the full onboarding.
- Who owns the pricing app move? Idris, tickets INFRA-1719 to 1724.
- Can the pricing app reach its MongoDB from on-prem? Not yet: Atlas is on PrivateLink inside AWS. The route via the transit gateway needs one firewall rule and one /24.
- How do we deploy to prod safely? QA2, then dev, then QA, then prod, with new behaviour off by default and switched on per environment.
- Do we ever apply Terraform by hand? No. iaac-talos goes through Octopus only, and a green Octopus run is checked for an actual apply.
- Are on-prem alerts working? Not reliably: rules fire but there is no delivery path on dev, and prod is pending.
- What's in Sprint 7? Prod readiness led by AWS SSO, the office-access fix, the RisingWave cutover and runbook, the service CIDR collision, and the pricing tickets.
