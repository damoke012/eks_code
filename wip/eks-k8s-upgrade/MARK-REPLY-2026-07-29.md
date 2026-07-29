# Reply to Mark Lashore — repos, doc ownership, INFRA-1594 head start

**Context:** Mark is ramping on the cloud EKS estate and drives INFRA-1594 (K8s version upgrade), with Rohit
and Parul guiding. He asked about missing/archived repos, self-answered most of it, and is now asking whether
he may edit the Confluence reference doc directly.

⚠️ Verify the two flagged items before sending — they're from notes dated 2026-07-15 and Mark's own findings
suggest the addon story has moved since.

---

Hi Mark,

Good digging — and you're right on both counts.

**Repos**

- `iaac-eks-manifests` is a typo in the doc. The live repo is **`iaac-flux-manifests`**. I'll fix the
  reference (or you can — see below).
- `observability-stack` — correct, superseded by **`iaac-monitoring`**, which does the observability
  infrastructure. Archived deliberately.
- `iaac-eks-bootstrap` being archived is the one that matters, because the doc still says platform addons
  (cilium, cert-manager, external-dns, external-secrets, flux, karpenter, aws-load-balancer, reloader, vpa)
  are authored there as Helmfile. If that repo is archived, those addons have moved — most likely into the
  Flux repo, which would also explain the naming confusion. **Please confirm with Rohit or Parul where addon
  manifests are authored today** rather than trusting the doc; that's a load-bearing detail for the upgrade
  work, since addon versions are what you'll be bumping.
- `terraform-eksctl-nodegroup` — expected to be dead: **Karpenter owns the entire fleet** now (NodePools
  `iaac`, `apps`, `ingressgateway`), so eksctl-managed nodegroups aren't in the path any more. Worth
  confirming, not assuming.
- `prowler-sechub-app` — check with Rohit; security tooling has moved around and I don't want to guess.

**On the doc — please just update it.** It's a wiki, not a spec; you're finding real errors and the fastest
path is you fixing them as you go. Two asks: leave a short comment on the page for anything structural (so
Rohit/Parul see the change rather than discover it), and don't delete content you think is wrong — mark it
and we'll confirm. A fair amount of the KT material was written from repo trees that no longer match reality,
so expect more of this.

**Head start on INFRA-1594** — as of mid-July, verified against the live clusters:

- All three (`usxpress-dev`, `qa-one`, `usxpress-prod`) are on **K8s 1.35**; newest EKS-available is **1.36**.
  So we're exactly one minor behind, which already meets the "never on latest" rule. **There's no urgency
  fire here** — the value of this ticket is the repeatable, automated path, not the jump itself.
- Three things that *are* due and worth folding in:
  - **kube-proxy version skew** — managed addon at v1.34.1 against a 1.35 cluster; AWS upgrade-readiness
    flags it. Everything else passes.
  - **`upgradePolicy.supportType = EXTENDED`** on all three clusters. That's a paid support tier. Decide
    keep-vs-STANDARD deliberately before moving to 1.36 — it's a cost line, so it connects to the SHI/cost
    conversation.
  - **cluster-autoscaler is still installed** (v1.26.2, nine minors stale) but vestigial since Karpenter owns
    every node. Confirm idle, then remove — dead components make upgrades harder to reason about.
- Addon targets for 1.36 (current → target): kube-proxy v1.34.1 → v1.36.0-eksbuild.7, coredns 1.13.1 →
  v1.14.2, ebs 1.58.0 → v1.62.0, efs 3.0.0 → v3.3.0, vpc-cni 1.21.1 → v1.21.2. Only kube-proxy is a managed
  addon; the rest are Helm/Flux.
- **Talk to Parul first.** She's done EKS upgrades here before and has end-to-end documentation that mostly
  works. Start from hers, compare with the Confluence upgrade page, and reconcile the two — that comparison
  is explicitly part of the ticket, and it's better than writing a third procedure from scratch.
- On approach: I'd rather we didn't hand-run `cordon`/`drain`. Look at what AWS gives us natively first, and
  note the fleet is Bottlerocket on Graviton under Karpenter, so node replacement is largely a drift/rollout
  problem rather than a manual one. Your call on the mechanism — bring a recommendation.
- Flow is **dev → stage/QA → prod**, with app health verified at each stop before promoting.

Adjacent but related, so it doesn't get lost: **RDS PostgreSQL is on 14.22** across all envs and PG14 is near
EOL. That's a separate major upgrade due in the same window.

Thanks,
Dare

---

## Not yet answered in the thread (Doke's side)

- Ping Steve re: adding us to the monthly SHI/USX call.
- New ticket for the **$40k DPL cost** and any other high-cost concerns — still to be filed.
- INFRA-1594 board move: resolved, Parul moved it to CloudOps (board 379).
