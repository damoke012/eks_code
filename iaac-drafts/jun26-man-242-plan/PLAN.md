# MAN-242 — Plan: Service-level GitHub identity for ADO pipeline to on-prem Manhattan VM

| Field | Value |
|---|---|
| Jira | [MAN-242](https://usxpress.atlassian.net/browse/MAN-242) |
| Type | Story |
| Reporter | Sreekanth Ande |
| Assignee | Matthew B. Higdon |
| Co-owner (anticipated) | Doke |
| Deadline | 2026-07-03 (QA-ready per Shannon Jernigan) |
| Today | 2026-06-26 |
| Time remaining | ~7 days |
| Memory ref | [[cloud-gha-pat-jeff-shaw-jun19]] (anticipated this work; pre-staged questions + recommendation) |

## Why this exists

Sender + Handler are Manhattan integration components (TCP socket-based) that deploy to an on-prem Windows VM ending in `2P`. The deployment pipeline today uses **Jeff Shaw's personal GitHub PAT** to bridge GitHub Actions (build) → Azure DevOps Artifact Feed (broker) → ADO Release Pipeline (deploy to VM). Personal PAT in a production pipeline is the same offboarding risk Vibin's departure exposed on 2026-06-03. The ticket replaces the personal PAT with a service identity.

## What's actually being asked (mapping to the 5 ACs)

| AC | Restated in plain language | Implementation surface |
|---|---|---|
| AC1 | A non-human GitHub identity exists | GitHub App or service user account |
| AC2 | That identity has a token with least-privilege scopes | App installation token (short-lived) OR fine-grained PAT |
| AC3 | ADO pipeline auths against GitHub using that token | ADO service connection |
| AC4 | GitHub Actions uploads artifacts to ADO Artifact Feed | GHA workflow + curl/ADO REST |
| AC5 | ADO release pipeline deploys to the on-prem VM from the feed | ADO release pipeline + agent on the `2P` VM |

## The identity choice (the core decision)

This is the same decision pre-staged in [[cloud-gha-pat-jeff-shaw-jun19]]. Three options, ordered by security posture:

### Option A — GitHub user/bot account + fine-grained PAT
- **Setup:** ~30 min
- **Maintenance:** PAT rotation cadence (90 days for fine-grained); manual rotation work
- **Security posture:** Static credential, token-leak risk. Better than "Jeff's personal" because account isn't tied to a human's lifecycle, but still has all the static-token risks (theft, shoulder-surfing of secrets UI, mis-set scopes).
- **Verdict:** The "PAT for a service account" option Jeff floated in the original meeting. **Memory flagged this as the worst path** — same rotation problem, just renamed. Avoid unless time genuinely forces it.

### Option B — GitHub App (org-level)
- **Setup:** ~2 hr
- **Maintenance:** App-level audit; installation tokens auto-rotate every ~1 hour; only the app private key needs rotation (yearly is typical)
- **Security posture:** Short-lived installation tokens, scoped per-repo by installation, no human dependency, organisation-owned
- **Verdict:** **Recommended v0.1 ship** for the 2026-07-03 deadline. Fits a week, eliminates the personal-PAT problem cleanly.

### Option C — GitHub OIDC federation → Azure AD workload identity → ADO
- **Setup:** ~4-6 hr (more if your ADO instance hasn't seen federation; possibly requires ADO admin involvement)
- **Maintenance:** None — no static credentials at all
- **Security posture:** Federated trust; GitHub Actions presents an OIDC token; Azure trusts it; ADO trusts Azure; no secrets stored anywhere
- **Verdict:** **The prod-ready answer** per the memory recommendation. Fits if we have ADO admin coordination + an Azure AD App Registration for the federation. **May not fit a week alongside everything else.**

### Decision matrix for THIS deadline

| If we have | Choose |
|---|---|
| Full Cloud Platform week + ADO admin available | **C (OIDC federation)** — do it right the first time |
| Reasonable but constrained time + Matt H. available for the ADO side | **B (GitHub App)** — ships in time, replaces personal-PAT cleanly, leaves OIDC as v0.2 |
| Crunch time + need to land Monday | **A (PAT for service account)** as a temporary measure with a hard commitment to migrate to B or C within 30 days | 

**Recommendation: B (GitHub App) for v0.1, file v0.2 ticket to migrate to C (OIDC federation) within the next sprint.**

This matches what we'd tell Matt + Steve if they kicked off the conversation today: "PAT for a service account is the wrong destination; let's do B now and C next."

## What the credential lifecycle looks like (Option B detail)

1. **GitHub App registration** — created under `variant-inc` org (Matt H. + Doke have org admin; Steve V. is also an org owner)
2. **App permissions** — minimum: `Contents: Read`, `Metadata: Read`, `Actions: Read`. NO write to repo contents; NO admin permissions.
3. **App installation** — scoped to the specific repo(s) holding Sender + Handler code, NOT org-wide
4. **App private key** — generated at app creation; downloaded once, stored in a secure secret manager (see below)
5. **In each GHA workflow:**
   - Use `actions/create-github-app-token@v1` to exchange the App private key for a short-lived installation token (1 hour lifetime)
   - That token authenticates the curl-to-ADO call
6. **App private key storage** — TWO options:
   - **B.1 — GitHub org secret** (`MANHATTAN_GH_APP_PRIVATE_KEY`) — simplest, key visible in GitHub admin UI to org owners
   - **B.2 — Azure Key Vault, retrieved via `azure/login` step using ADO service connection** — more complex setup but matches the existing Manhattan ADO security model

For v0.1 deadline, **B.1** is simpler. Migrate to B.2 with the v0.2 OIDC federation work.

## The artifact upload flow

```
GitHub repo (sender + handler)
  ↓ push to main
GitHub Actions workflow
  ↓ build .NET artifact + zip
  ↓ exchange App private key → installation token
  ↓ curl ADO REST: POST https://feeds.dev.azure.com/<org>/<project>/_apis/packaging/feeds/<feed>/upload?api-version=6.0-preview.1
  ↓ artifact lands in Manhattan ADO Artifact Feed
ADO Artifact Feed (new artifact published)
  ↓ ADO release pipeline trigger (continuous deployment)
  ↓ pulls latest artifact from feed
  ↓ deploys to on-prem `2P` VM
```

**Open question on the deploy mechanism (right side of the arrow):** does the `2P` VM run an ADO build agent already, or does the ADO release pipeline use a remote-exec pattern (SSH / WinRM / PowerShell remoting)? Memory has it as "PowerShell installer + Windows service" so likely WinRM or a self-hosted agent on the VM. **Sub-ticket: confirm with Jeff.**

## Sub-tickets to file under MAN-242

To file once Doke confirms his role + Matt H. is briefed (see "Open question on ownership" below).

| # | Sub-ticket | Story points | Owner candidate |
|---|---|---|---|
| MAN-XXX | Create GitHub App in variant-inc org with minimum scopes + install on Sender/Handler repos | 3 | Doke or Matt (whoever has GH org admin time first) |
| MAN-XXX | Store GitHub App private key in chosen secret store (B.1 GitHub org secret for v0.1) | 1 | Doke |
| MAN-XXX | Write GHA workflow: build → install-token exchange → curl ADO Artifact Feed upload | 5 | Doke (or Jeff if more familiar with the Sender/Handler build) |
| MAN-XXX | Configure ADO release pipeline to point at the real artifact + deploy to `2P` VM (CONFIRM deploy mechanism first) | 5 | Matt H. (ADO-side expertise) + Jeff (VM-side) |
| MAN-XXX | End-to-end test against German Higuera's testing requirement (target 2026-07-03) | 2 | All three (Jeff drives, Doke + Matt monitor) |
| MAN-XXX | Documentation: GitHub App lifecycle (creation, install, rotation, off-boarding) | 2 | Doke |
| MAN-XXX | v0.2 follow-up — migrate to OIDC federation (Option C); file as a separate parent ticket linking back to MAN-242 | 8 | Doke + Matt H. + ADO admin |
| **Total v0.1** | | **18 points** |  |
| **+ v0.2** | | **+8 points** |  |

18 points across 7 days with 2-3 people working in parallel is achievable. The OIDC follow-up is **explicitly NOT** in the 7-day window.

## Risk register

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| ADO Artifact Feed auth quirks on first upload | Medium | Half a day burned | Test with a hello-world artifact early in the week, before Sender/Handler is wired |
| Deploy mechanism on `2P` VM is more complex than assumed (custom installer, dependencies) | Medium | 1-2 days | Jeff has done the manual deploy already; ask him to share the PowerShell script + confirm it's reusable |
| ADO permissions Matt or Doke don't currently hold | Low-Medium | Same-day blocker | Confirm Matt's ADO role early; if there's a gap, escalate to Sreekanth/Shannon early in the week |
| Time-pressured Option A regression — someone insists on "PAT for service account" because B is too much for the deadline | Medium | Architectural debt; same problem in 90 days | Lead with B; if forced to A, file the migration ticket SAME DAY |
| Personal-PAT-shaped accountability creep — the GH App ends up with one person's name on it informally | Low | Same offboarding hole as today | App ownership formally on `variant-inc` org admin; rotation/audit owner named in the documentation sub-ticket |

## What we need to know from Matt + Jeff + Sreekanth (the 10 questions from memory, trimmed)

The memory had 10 pre-staged questions. These are the ones still open after reading the ticket body:

1. **Does `variant-inc` already own a GitHub service identity (App / bot user)?** Reuse beats create. (Memory question #3)
2. **The `2P` VM deploy mechanism** — ADO agent installed, or remote-exec? (Memory question #5)
3. **GitHub repo names + paths** for Sender + Handler (Memory question #6)
4. **The ADO org + project Jeff is using** — Manhattan ADO project under which ADO org? Knight-Swift? USX-Production? (Memory question #7)
5. **Build artifact shape** — .NET assemblies + PowerShell installer in .zip, or NuGet .nupkg? (Memory question #8)
6. **Vibin offboarding precedent** — were any of his PATs in CI? If so, what runbook? (Memory question #10)

## Open question on ownership

**The ticket assignee is Matt Higdon. Doke received the assignment notification.** Is Doke:
- Taking over as primary owner from Matt?
- Co-owning with Matt (split workload)?
- Consulted for the on-prem VM piece while Matt drives the ADO + GitHub piece?

The plan above splits work between Doke + Matt + Jeff naturally, but actual assignment depends on Doke's answer.

## Next steps if Doke confirms ownership

1. **Brief Matt H.** with this plan (15 min Teams call); align on Option B for v0.1
2. **File the sub-tickets** under MAN-242 with story points
3. **Schedule a 30-min kickoff** with Matt + Jeff + Sreekanth (drive the 6 open questions above)
4. **Start the GitHub App creation TODAY** if green-lit — it's the longest blocker and gates everything else
5. **Send Shannon Jernigan a confidence-and-risk update** on the 2026-07-03 deadline by EOD 2026-06-27

## Related

- [[cloud-gha-pat-jeff-shaw-jun19]] — pre-staged design + questions
- [[reference-jira-doke-displayname]] — clarifies "Matt Dare" was actually `dare` = Doke
- [[secure-token-ingress-pattern]] — same principle in a different stack (we're applying it to GitHub Apps + ADO here)
- [[feedback-never-accept-pasted-secrets]] — if anyone proposes sending the App private key via Teams/email, refuse
- [[reference-usx-azure-ad-tenant]] — tenant ID for the v0.2 OIDC federation work
