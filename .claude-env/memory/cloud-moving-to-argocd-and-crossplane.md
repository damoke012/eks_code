---
name: cloud-moving-to-argocd-and-crossplane
description: "Parul's POC (2026-10-20): cloud leaves Mage for Argo CD app deployment and Terraform for Crossplane AWS resources, in phases, with a long observe-only stage; MongoDB is the gap and DPL is the test environment"
metadata:
  type: project
---

**Presented 2026-10-20**, POC complete, Confluence page + ticket circulated for team review.
This is the cloud counterpart to what on-prem already does, and it means "cloud Argo CD is a
POC" is now out of date as a blanket statement — app deployment is the first thing moving.

**The phases as Parul described them:**

1. Deploy **Argo CD on EKS as proper IaC** — tested in **DPL** first.
2. Remove **application deployment** from **Mage**; app deployment moves to Argo CD.
3. Deploy **Crossplane** (a step missing from the written doc — she flagged it live).
4. Crossplane **providers**, then AWS resources created in **observe-only mode**: Crossplane
   watches what exists in AWS and pulls it into state while **Terraform still performs every
   apply**.
5. After validating the observed resources, switch to managing mode; Crossplane then creates
   AWS resources.

**Two routes for the resources:** Terraform modules wrapped inside Crossplane, or
Crossplane's **native providers**. She tested the native providers against S3 and others
successfully. **MongoDB is the known gap**; Azure has a provider, untested.

Doke wants a **separate meeting before stage 1** and the document reviewed first.

⚠️ **Observe-only is not a dry run.** In phase 4 two systems hold state for one resource while
only one applies. That is the configuration [[two-projects-one-resource]] warns about — where
a reconciliation or a `destroy` can delete a live object. The validation gate before switching
modes is the entire safety margin, and it is the thing to ask about.

The shape is right and worth copying: new machinery lands inert, observes, and is promoted by
a flag — [[promotion-order-qa2-dev-qa-prod]].
