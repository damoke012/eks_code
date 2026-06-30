# MAN-242 — Service identity for the Manhattan deployment pipeline

| Field | Value |
|---|---|
| Jira | [MAN-242](https://usxpress.atlassian.net/browse/MAN-242) |
| Reporter | Sreekanth Ande |
| Assignee on file | Matthew B. Higdon |
| Co-owner (proposed) | Doke |
| Deadline | 2026-07-03 (QA-ready per Shannon Jernigan) |
| Today | 2026-06-26 |
| Time remaining | ~7 days |
| Design source | Memory file [[cloud-gha-pat-jeff-shaw-jun19]] |

---

## What we are changing — in one paragraph anyone can follow

Today the automated deployment of the Manhattan Sender and Handler components depends on **Jeff Shaw's personal GitHub login**. If Jeff is on vacation, out sick, or leaves the company, the deployment quietly breaks the next time someone tries to ship a change. The ticket replaces Jeff's personal login with a **cryptographic trust between GitHub and Microsoft**. Nothing is tied to a specific person. There is no password to share, nothing to rotate by hand, and the trust survives any personnel change. Microsoft and GitHub already support this pattern out of the box; we are just turning it on for our pipeline.

---

## The decision — Option C (OIDC federation). Locked.

We are not splitting this into "easy version now, real version later." The easy versions (`Personal Access Token` and `GitHub App with a stored private key`) still have something a person has to remember to rotate, something that lives in a secret store, and something that can be leaked. The whole point of this ticket is to eliminate that class of risk, not to defer it. We do it once, correctly.

| Option | What it is | Why we are NOT picking it |
|---|---|---|
| A | A non-human GitHub user with a Personal Access Token | Still a password. Still needs manual rotation. Still tied to one secret store. Just renames the problem we are fixing today. |
| B | A GitHub App with a stored private key | Better than A, but the private key still lives somewhere as a secret. Someone has to manage that secret's lifecycle. |
| **C** | **GitHub OIDC federation → Azure AD → Azure DevOps** | **No secret stored anywhere. No rotation. Microsoft and GitHub verify each request cryptographically. This is the correct prod pattern; doing it once now is cheaper than doing it twice.** |

The 2026-07-03 deadline is real but achievable. The longest part of Option C is getting an IT-side App Registration provisioned in the USXpress Azure tenant (~24-48 hours typical). We file that request **today** and the rest of the work runs in parallel.

---

## How it works — the flow

```
   ┌──────────────────────────────────────────────────────────────┐
   │                                                              │
   │   An engineer commits Sender or Handler code to GitHub.      │
   │                                                              │
   └────────────────────────────┬─────────────────────────────────┘
                                │
                                ▼
   ┌──────────────────────────────────────────────────────────────┐
   │                                                              │
   │   GitHub Actions runs automatically.                         │
   │                                                              │
   │   No passwords are stored anywhere in this step.             │
   │                                                              │
   │     1. Build the Sender or Handler application.              │
   │     2. Ask Microsoft: "Am I who I say I am?"                 │
   │        (using a cryptographic proof, not a password)         │
   │     3. Microsoft replies:                                    │
   │        "Yes, you are the trusted USXpress build pipeline."   │
   │                                                              │
   └────────────────────────────┬─────────────────────────────────┘
                                │
                                ▼

                Microsoft hands GitHub a short-lived
              digital access pass valid for about 1 hour.

                                │
                                ▼
   ┌──────────────────────────────────────────────────────────────┐
   │                                                              │
   │   GitHub Actions uses that pass to upload the new build      │
   │   to the Azure DevOps Artifact Feed.                         │
   │                                                              │
   │   The pass expires automatically; nothing remains on disk.   │
   │                                                              │
   └────────────────────────────┬─────────────────────────────────┘
                                │
                                ▼
   ┌──────────────────────────────────────────────────────────────┐
   │                                                              │
   │   Azure DevOps sees the new build land in the feed and       │
   │   automatically triggers the release pipeline.               │
   │                                                              │
   └────────────────────────────┬─────────────────────────────────┘
                                │
                                ▼
   ┌──────────────────────────────────────────────────────────────┐
   │                                                              │
   │   The release pipeline copies the build files to the on-prem │
   │   Windows VM (the one ending in "2P") and starts or restarts │
   │   the Windows service.                                       │
   │                                                              │
   └────────────────────────────┬─────────────────────────────────┘
                                │
                                ▼

                    ✓  Sender or Handler is live
                    ✓  Nobody's personal login was used
                    ✓  Nothing to rotate by hand later
```

---

## Today vs after the change — side-by-side

```
   TODAY                                  AFTER THIS CHANGE

   ┌─────────────────────────┐            ┌─────────────────────────┐
   │  Jeff's personal        │            │  GitHub and Microsoft   │
   │  GitHub login           │            │  trust each other       │
   │                         │            │  cryptographically      │
   └────────────┬────────────┘            └────────────┬────────────┘
                │                                       │
                ▼                                       ▼
   ┌─────────────────────────┐            ┌─────────────────────────┐
   │  Personal access token  │            │  Short-lived digital    │
   │  pasted into secrets    │            │  passes (~1 hour each)  │
   │                         │            │                         │
   │  Must be rotated by     │            │  Issued automatically   │
   │  Jeff manually          │            │  on every pipeline run  │
   └────────────┬────────────┘            └────────────┬────────────┘
                │                                       │
                ▼                                       ▼
   ┌─────────────────────────┐            ┌─────────────────────────┐
   │  Pipeline depends on    │            │  Pipeline depends only  │
   │  Jeff staying at the    │            │  on the company's       │
   │  company and being      │            │  GitHub and Microsoft   │
   │  available              │            │  accounts existing      │
   └─────────────────────────┘            └─────────────────────────┘

   If Jeff leaves: BROKEN                  If Jeff leaves: KEEPS RUNNING
   If Jeff is on PTO: AT RISK              If Jeff is on PTO: KEEPS RUNNING
   Audit asks "who deployed?": Jeff        Audit asks "who deployed?": Pipeline
```

---

## What needs to happen — sub-tickets

All sized for the 2026-07-03 deadline. IT App Registration is the long pole; we file it **first**, today.

| # | Sub-ticket | Story points | Owner | Sequence |
|---|---|---|---|---|
| MAN-XXX | **File Freshservice ticket** to IT requesting an Azure AD App Registration with federated credentials for GitHub OIDC. Include the GitHub repo path, federation subject pattern (`repo:variant-inc/<sender-handler-repo>:ref:refs/heads/main`), and required Azure DevOps role assignment | 2 | Doke | **Day 1 — TODAY** |
| MAN-XXX | Confirm with Jeff: deploy mechanism on the `2P` VM. ADO agent installed? WinRM-based remote-exec? PowerShell-over-SSH? Specifically: what does the existing manual deploy look like, and can we automate exactly that? | 1 | Jeff + Doke | Day 1 |
| MAN-XXX | Once IT provisions the App Reg, configure the ADO **service connection** to trust the federated identity. Test by triggering a dummy upload from a sandbox GHA workflow | 5 | Matt H. (ADO-side expertise) | Day 2-3 |
| MAN-XXX | Write the GHA workflow for Sender + Handler: `actions/checkout@v4` → build → `azure/login@v2` (federated) → `az artifacts universal publish` to upload the build to the ADO Artifact Feed | 5 | Doke or Jeff (whoever knows the build steps) | Day 2-4 |
| MAN-XXX | Configure the ADO release pipeline to pull the latest artifact from the feed and run the existing PowerShell installer on the `2P` VM. Migrate from "dummy source" to the real artifact reference | 5 | Matt H. + Jeff (Jeff knows the VM, Matt knows the pipeline) | Day 3-5 |
| MAN-XXX | End-to-end test: commit to a test branch → GHA builds → ADO receives artifact → release deploys to `2P` → Sender/Handler service runs cleanly. Target German Higuera's testing window on 2026-07-03 | 3 | All three | Day 5-6 |
| MAN-XXX | Documentation runbook: how the federation is configured, how to add a new repo to the trust, what to do if the App Reg is ever revoked, who owns rotation (answer: nobody — there is nothing to rotate) | 3 | Doke | Day 6 |
| **Total** | | **24 points** | | **6 working days** |

24 points across 7 calendar days (5 working days plus weekend buffer) with three people sharing the load is achievable. The IT App Reg request goes in today so it does not become the constraint.

---

## What we need to learn in the kickoff (6 open questions)

The pre-staged questions from [[cloud-gha-pat-jeff-shaw-jun19]] that are still open:

1. **Does `variant-inc` already own a GitHub App or service identity for CI?** If yes, can we extend its installation to the Sender + Handler repos instead of creating a new one? (Reuse beats create.)
2. **What is the `2P` VM deploy mechanism today?** ADO build agent installed on the VM, or WinRM remote-exec from an ADO-hosted agent?
3. **Exact GitHub repo names + paths** for Sender and Handler.
4. **The ADO organization + project** Jeff is using for the Manhattan project. (Knight-Swift, USX-Production, or its own?)
5. **Build artifact shape** — .NET assemblies + PowerShell installer in a .zip, or a NuGet `.nupkg`?
6. **Were any of Vibin's personal tokens used in CI?** Same risk shape; if there is a known runbook from that offboarding we reuse it.

---

## Risks and mitigations

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| IT App Reg provisioning takes longer than 48 hours | Medium | Day-of-deadline slip | File the IT ticket on Day 1 today; escalate via Shannon or Sreekanth on Day 3 if no movement |
| ADO service connection federated trust has setup quirks the team has not seen | Medium | Half a day burned | Build a hello-world workflow in a sandbox repo to prove the federation before wiring Sender/Handler |
| `2P` VM deploy mechanism is non-standard (custom installer, dependencies, drift from prod state) | Medium | 1-2 day delay | Jeff has manually deployed already; reuse his PowerShell exactly, do not re-derive |
| Someone pushes back arguing PAT is faster | Medium | Architectural regression | Lead with this plan; the cost of doing C now is the same time as doing B and then C; do not negotiate |
| Doke's bandwidth — already running QA design + Wiz + Postgres window | Medium | Quality of attention | Frame work split so Matt H. owns the ADO side, Jeff owns the VM side, Doke owns IT coordination + documentation |

---

## Open question on ownership — needed before sub-tickets are filed

The Jira ticket assignee is Matt Higdon. Doke received the assignment notification. Three possibilities:

1. **Doke takes over as primary owner** — sub-tickets assign predominantly to Doke; Matt drops to consulted; Jeff stays on the VM piece
2. **Doke and Matt co-own** — the work splits along the lines in the table above (Matt owns ADO, Doke owns IT coordination + GHA, Jeff owns the VM); this is the structure the table is already designed for
3. **Doke consulted, Matt drives** — Matt stays primary; Doke advises on the federation pattern; sub-tickets predominantly Matt-owned

Confirm which, and the sub-tickets file the same day.

---

## Why this matters beyond MAN-242

The pattern shipped here — federated identity in place of stored credentials — is the same pattern we want for every USXpress CI/CD pipeline that touches an external system. Doing it cleanly for Manhattan establishes the template. Subsequent pipelines (any future on-prem deployments, cloud deployments that need ADO crossover, etc.) copy this exact setup with just a different App Registration. The 24-point cost here is one-time; the per-pipeline cost after this is closer to 5 points.

This also closes the same offboarding hole exposed by Vibin's departure on 2026-06-03 — and unlike the cluster-side hole (which we already addressed via separate IRSA roles), the CI/CD hole has been quietly open in every Jeff-tied pipeline.

---

## Related

- [[cloud-gha-pat-jeff-shaw-jun19]] — pre-staged design + open questions
- [[reference-jira-doke-displayname]] — clarifies "Matt Dare" in original transcript was actually `dare` = Doke
- [[secure-token-ingress-pattern]] — same principle in a different stack (Wiz token onboarding); we are applying federation here, scoped IAM role there
- [[feedback-never-accept-pasted-secrets]] — if anyone proposes pasting the App private key or PAT in chat, refuse
- [[reference-usx-azure-ad-tenant]] — tenant ID `bbb5a66d-5c9f-482a-969a-a40304b6bc8d` for the App Reg
- [[onprem-aad-identity-strategy-jun25]] — INFRA-1559; this work is the same family of "identity right, not identity convenient"
