---
name: eks-k8s-upgrade
description: "New initiative (2026-07-13) — assess AWS EKS K8s version, plan an automated fleet-style upgrade dev→QA/staging→prod"
metadata: 
  node_type: memory
  type: project
  originSessionId: 161fed6b-7af8-49e8-9abf-c06ed6494c28
---

New initiative from the 2026-07-13 standup: review the AWS **EKS Kubernetes version** and plan an upgrade.

- **CONFIRMED live 2026-07-15**: all three clusters (usxpress-dev, qa-one, usxpress-prod) on **K8s 1.35**; newest EKS-available is 1.36 → one minor behind (healthy). Nodes = **Bottlerocket 1.62.1 / Graviton ARM64** (m7g/m6g.xlarge), kubelet v1.35.4. AWS upgrade-readiness insights all PASSING except **kube-proxy version skew WARNING** (managed addon at v1.34.1 vs cluster 1.35 — bump to clear). Cluster **upgradePolicy.supportType = EXTENDED** on all three (cost/governance choice; decide keep vs STANDARD before 1.36). Only kube-proxy is an aws_eks_addon; vpc-cni/coredns/ebs are Helm/Flux. Both Karpenter 1.11.1 AND cluster-autoscaler still installed. ~7 failed Helm releases (legacy variant-* charts mid-migration to dx-*).
- **Karpenter owns the whole fleet** (NodePools iaac/apps/ingressgateway); cluster-autoscaler IS deployed (cluster-autoscaler-aws-cluster-autoscaler, image v1.26.2 — 9 minors stale) but vestigial since Karpenter owns every node — confirm idle then remove. kube-system also has: VPA 1.5.1 (admission/recommender/updater), aws-network-policy-agent v1.3.1 (w/ vpc-cni), headroom DaemonSet (pause/overprovision), Windows EBS-CSI node DS, and homegrown ops controllers (cleanup-oomkilled/pending/stuck-resize-pods, bump-vpa-on-oom, service-topology) on UNPINNED chainguard/kubectl:latest-dev (pin these). **Data layer**: Postgres=CloudNativePG operator on-cluster (0 Cluster CRs in dev — some may be RDS), Kafka brokers=Confluent Cloud SaaS + Strimzi runs Kafka *Connect* on-cluster (connect-connect ×3, not brokers), Mongo=Atlas SaaS, RabbitMQ=operator on-cluster (0 CRs in dev). None are AWS-managed (no MSK/DocumentDB/ElastiCache). **Addon 1.36 targets** (current→target): kube-proxy v1.34.1→v1.36.0-eksbuild.7 (2 behind), coredns 1.13.1→v1.14.2, ebs 1.58.0→v1.62.0, efs 3.0.0→v3.3.0, vpc-cni 1.21.1→v1.21.2 (patch). Only kube-proxy is a managed addon; rest are Helm via iaac-eks-manifests.
- **App Postgres = RDS PostgreSQL 14.22** (AWS-managed), one instance per env: dev `usxpress-dev`/qa `qa-one` db.t4g.small single-AZ, prod `usxpress-prod` db.r6g.large Multi-AZ. PG14 nears EOL → RDS major upgrade (→16/17) is a due item alongside K8s. CNPG + RabbitMQ operators installed but 0 clusters in ALL envs (unused).
- **iaac-eks repo topology** (default branch `master`, internal): root = `deploy` + `apps` (NOT `deploy/terraform` — KT doc tree was wrong; `deploy/terraform` and `modules` both 404). Platform addons/bootstrap live in a SEPARATE repo **iaac-eks-bootstrap** ("networking, security, DNS, cert management"). Related cloud repos: terraform-eksctl-nodegroup, sre-iaac, eks-auth-sync, observability-stack, prowler-sechub-app, iac-eks-bootstrap. **Real layout**: iaac-eks `deploy/` = orchestration (config.yaml, secrets.yaml, deploy.ps1); `apps/` = IaC → `apps/terragrunt` (root.hcl, _envcommon, modules/, live/) is Terragrunt, `apps/charts` is Helmfile. **Platform addons authored as Helmfile in iaac-eks-bootstrap/apps** (dirs: cilium, cert-manager, external-dns, external-secrets, flux, karpenter, aws-load-balancer, reloader, vpa, kube-system, pre_helm, common). Artifact §3 now fully rewritten — doc verified top-to-bottom 2026-07-15.
- Full cloud EKS reference-architecture artifact built 2026-07-15: https://claude.ai/code/artifact/8fbc2338-45dc-4b9b-a796-05e626c11c30
- **Parul has done EKS upgrades before and has full end-to-end documentation** (works mostly, minor hiccups) — build on it.
- Goal: make it **more automated (fleet-style)**, not hand-run. Flow **dev → QA/staging → prod**.
- Owner: the new team member **Mark** ramps up + drives (learning the cluster), with Rohit + Parul guiding. Set up a call depending on upgrade urgency.

Filed as **INFRA-1594** (2026-07-13). Related: [[user-doke-onprem-platform]].
