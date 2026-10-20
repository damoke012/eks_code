# Platform Delivery and Reliability Review — 2026-10-20

Source: AI note-taker transcript, forwarded by email. "Host" is Dare (Doke). Present: Rohit,
Parul, Steve, Mark, Idris, Darian (late). Speaker labels are unreliable — Parul appears as
"Pearl"/"Peru"/"Parool", Dare as "Derry"/"Terry"/"Dara". Verify before quoting anyone.

## 1. Kafka dev deployment failure — AWS provider 6.69.1 breaks a Lambda read

The only incident of the week, Thursday, on `ix-kafka-topics-users`. Full write-up:
`FINDINGS-2026-10-20-aws-provider-lambda-listversions.md`. In one line: the newest
`hashicorp/aws` provider, released that same day, made the **read** of
`aws_lambda_function` call `ListVersionsByFunction`, which errored and blocked the deploy.
Parul pinned the provider below it; the fix propagated to every environment in one merge.

**Doke's instruction, twice: open a ticket and document it in the SOP** — *"there is no fix
right now other than to just retain the older version … I am afraid that we might see this
in a different environment"* and *"anything that impacts Kafka is something we should
document."* A placeholder ticket is acceptable; the document is the point.

⚠️ **This touches our own work.** `iac-tf-manual-runs/apps/common/gha_ecr_push_roles`
(PR #39, merged) declares `aws = "~> 6.69"`, which means `>= 6.69, < 7.0` — it **admits the
versions the team has just pinned away from**. The module holds only IAM, so the Lambda bug
cannot bite it, but the constraint disagrees with the fleet's and nothing says why. Bring it
into line, or write the reason it differs next to it.

Worth noting, because it is the second time this reasoning has paid: that file's own comment
already said *"a major bump can add an API call the deploy role was never granted, which
fails at READ with nothing applied."* That is this incident, written down before we heard
about it. The failure class is real; treat an unpinned provider as an ungated change.

## 2. EKS version policy, stated out loud

Rohit has upgraded **dev, QA and staging to 1.36**; ops and prod go Monday. Latest available
is **1.37**, and the team is deliberately not taking it.

Doke: *"we shouldn't be chasing the latest version. We should be making sure that the version
we are on is not about to lose support. So it's the other way around."* And: *"if we go to
1.37, we'll be doing a test for them."*
Mark: *"we want to stay N minus 1 to the current latest."*
Rohit: 1.35 is what is going out of support; 1.36 is not.

So the rule is **two conditions, not one**: stay at N-1 of the latest, *and* move when the
support window is closing. "A newer version exists" is not a reason.

Also agreed: the **cluster upgrade documentation is stale** — it describes an older process
than the one Rohit now follows, and he will update it. Doke asked for a scheduled 10–15
minute walkthrough of the upgrade for the whole team.

## 3. API Gateway engagement (Mark) — blocked on someone else's decision

The gateway cannot handle secrets or tokens itself, so a component has to sit behind it:
**Lambda** (maximum flexibility, which is what they say they want) or **a container in EKS**
(simpler for the platform). The decision belongs to **Roger and Ross**; Mark is waiting, and
is recording the decisions and who made them in a table so the wait is visible.

**New input: Salt Security.** Steve — the cyber team is onboarding a product called **Salt**
(the company name; there is no "AWS Salt") which does API security, via **Brendan Bouchelle**.
Steve expects it to carry requirements the way **Wiz** did, and it may change the Lambda vs
EKS answer. Mark to research; Steve to send links and expedite the conversation.

**Doke's principle, which is the same one the variable contract is built on:** anything that
**expires or is short-lived**, and anything that is a managed **AWS service**, is platform-
owned, abstracted away from the application, and **created as infrastructure as code**. The
application artifact must be **identical from environment to environment**. The open question
he wants asked more often: *"what should be purely handled by the platform versus what should
be a total application call."*

## 4. Cloud direction — Mage out, Argo CD and Crossplane in (Parul)

POC complete, documented in Confluence with a ticket, and circulated for review. The phased
plan as she described it:

1. Deploy **Argo CD on EKS as proper IaC** — tested in **DPL** first.
2. Remove **application deployment** from **Mage**; application deployment moves to Argo CD.
3. Deploy **Crossplane** (she noted this step was missing from the written doc).
4. Crossplane **providers**, then the AWS resources — created but in **observe-only mode**:
   Crossplane watches what exists in AWS and pulls it into state while **Terraform still
   performs every deployment**.
5. Once the observed files are validated, switch to managing mode and Crossplane becomes
   responsible for creating AWS resources.

Two routes exist for the AWS resources — **Terraform modules inside Crossplane**, or
**Crossplane's own providers**. She tested the native providers against S3 and others
successfully. **MongoDB is the known gap**; Azure has a provider but is untested.

Doke wants a **separate meeting before stage 1** begins, and the document reviewed by
everyone first. Observe-only-before-managing is the shape of a safe migration and matches our
own rule: new behaviour lands off, one environment at a time.

## 5. RisingWave / Tim — dev landed, QA ready, and the disagreement is about ownership

Doke's summary to the team: *"we at least got Tim to successfully deploy his RisingWave code
into the dev environment … right now I think QA is good to go,"* with the dev changes being
converted to IaC so the next environment is a replication rather than a rebuild. Sprint 6
closes today and Sprint 7 opens for cloud and on-prem.

The honest part, and it is the part to keep: *"he is not liking how we have created it … he
wants to have a lot of control within his repo, but they don't own CI/CD. That's a platform
thing."* The named disagreements are exactly the four the variable contract addresses — which
variables each side controls, how that control is isolated so an app team cannot edit platform
variables, what is secret versus non-sensitive, and **not putting configuration variables into
the image**.

PR status given on the call: **Parul approved the Trivy pin (actions-collection #99)**; the
**IAM role import PR (iac-tf-manual-runs #39) is the one still to send her**.

## 6. Idris owns the pricing-app engagement outright

Doke, explicitly: Idris runs the whole engagement with Shrikant, talks to him directly, and
*"you don't need anybody's approval to do anything on this."* Expect pushback; pull the team
into calls when an opinion is wanted. Steve: *"it's onboarding an app … we want it to feel
like a very standard thing, even though it's the second one, there's — it's never too early
to standardize."*

**The deliverables Doke named for it**, and they are the onboarding product, not this one app:

* an **epic** for the engagement, and a **discovery form** — *"whatever you have in a form
  right now is totally fine"*;
* an **architecture diagram that separates platform from application**;
* a **repo for their work**, as we did for RisingWave, **with a README** saying what the
  engagement is, what is application, what is infrastructure, and what the onboarding
  process is;
* a **Confluence page for this engagement and a Confluence page for onboarding in general**;
* **example files for everything an application has to produce** — what a pod, a deployment,
  a replica set look like, how Helm is used, the values file — so a team arriving later has
  a template rather than a conversation;
* a high-level phase walkthrough to the team, the way Parul presented hers.

And the reason, said plainly: *"this should be our prototype — our test case — for onboarding
as a platform, most of which we didn't do with Tim. We just brought him into the environment.
Going forward, any application that wants to onboard on-prem has to follow this procedure."*

## 7. Elevated admin accounts already exist

Steve: every member of the team **already has an elevated AD account** created — `_elevated`
or `_ELEV`, alongside the `_admin` ones visible in Active Directory — and nobody has been
onboarded onto them. The practice is that **admin-level logins to AWS, Azure or anywhere else
use the separate elevated account**. **Chris** on the cyber team runs the onboarding; Mark is
to pick it up, explicitly **not urgent**.

This is the answer to the standing "I should be AWS admin" question: the account exists, the
onboarding does not.

## 8. Also raised

* **Nutanix transition** — Doke wants a ticket opened; no work has started.
* Doke's own next focus: finish cleaning up **production for Tim** and finalise each
  environment.
* **Central Hudson / application monitoring** (Darian) — their EA believes our monitoring
  effort will demand a lot of their application; Darian has reassured them the effort is
  minimal. The transcript cuts off mid-question, so the actual ask is unknown.

## Proven

* AWS provider **6.69.1** (released 2026-10-15/16) fails reading `aws_lambda_function`
  through an internal `ListVersionsByFunction` call; pinning below it unblocks the deploy and
  one merge fixed every environment. Newer **Lambda** versions are fine — what is blocked is
  newer **provider** versions.
* Octopus **publishes a new Lambda version on every deploy**, so these functions accumulate
  versions. That is the state the provider's read was walking.
* EKS: dev, QA and staging on **1.36** as of 2026-10-20; ops and prod pending. Latest 1.37,
  deliberately skipped. 1.35 is the version losing support.
* Fleet upgrade policy: **N-1 and support-window driven**, stated by both Doke and Mark.
* The cluster upgrade runbook is **stale** relative to the process actually used.
* Every team member has an unused **elevated AD account**; cyber (Chris) onboards.
* Cloud is moving **Mage → Argo CD** for app deployment and **Terraform → Crossplane** for
  AWS resources, via an observe-only phase. MongoDB is the gap.
* The pricing-app onboarding is **Idris's engagement end to end**, with no approval gate.
* Parul approved **actions-collection #99**; **iac-tf-manual-runs #39** still needs her.

## Tested and killed

* **Chasing the latest Kubernetes version.** Killed on the call: 1.37 exists and is not
  being taken, because being early is doing someone else's testing.
* **"Upgrade the provider and move on."** Killed by the incident; the pin stays until a patch
  release is shown to fix it. Parul will re-test the patch version and remove the constraint
  only then.
* **"AWS Salt."** There is no such product. It is **Salt Security**, a vendor.

## Traps

* **The AWS provider is an ungated change in any repo that gitignores
  `.terraform.lock.hcl`.** Every fresh init takes whatever shipped that day, and the failure
  arrives at **read** time, with nothing applied and nothing in our code to point at. Our own
  `gha_ecr_push_roles` constraint currently admits the blocked range.
* **"The Lambda version" and "the provider version" are different things** and the transcript
  uses them interchangeably. The blocked upgrade is the provider's.
* **Nothing in our Terraform calls `ListVersionsByFunction`.** Searching our code for the
  failing API finds nothing and reads as "not us". The call is made inside the provider.
* **A stale runbook is more dangerous than a missing one**, because the upgrade appears
  documented. Rohit's is being followed from memory, not from the page.
* **Observe-only mode is not a dry run.** In Parul's phase 4, Crossplane pulls real AWS state
  into its own state file while Terraform still owns the apply — two systems holding state
  for one resource. That is the configuration `two-projects-one-resource` warns about, so the
  validation gate before switching modes is the whole safety margin.
