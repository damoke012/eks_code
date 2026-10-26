# RisingWave sync — Console orgs, DBeaver access, alert routing

**2026-10-26, 18:33–18:55.** Tim Preble, Idris Fagbemi, Dare Oke, Michael.
Transcript below; the analysis is the part worth reading.

---

## Decisions

**PR #59 wins — one shared organisation.** Tim, asked to choose between a single shared org
and a private org per person: *"Let's go with the easiest thing for right now."* And on the
alternative, where each new person gets their own copy: *"Yeah, no, we don't want that."*
PR #60 is closed by this.

**Tim is admin; everyone else is operator.** Stated on the call and accepted. *"For you
specifically you get admin privileges. Everyone else, they act as an operator. That is baked
into your access right now, and if we need to expand who has admin in the future we can."*

**Alerts go to Teams, filtered to RisingWave, prod and non-prod separate.** Tim already has
`RisingWave developer support` and `RisingWave production support` channels but will create a
new prod / non-prod pair rather than reuse them. Alerts are filtered by namespace in Grafana
so the RisingWave signal is separable from everything else on-prem. The standard is
deliberately low-noise: *"it shouldn't be like we're getting every single thing — let's define
the SLO, let's create a confidence space for what we are watching."*

Application and platform alerts share one channel for now, and split once QA and production
arrive, at which point platform moves toward email and an escalation process.

## Action items

| Who | What |
|---|---|
| **Tim** | Raise the ticket for DBeaver SSO (said on the call he was creating it) |
| **Tim** | Create the prod / non-prod RisingWave Teams channels and send the links |
| **Tim** | Review the monitoring and observability work and give feedback — no rush |
| **Tim** | Exercise QA this week so we know it works before anyone depends on it |
| **Tim** | Confirm Zach's site visit on **9 November** — no reply from him yet |
| **Idris** | Wire alerts to the new channels, filtered by namespace |
| **Doke** | Finish the production work |
| **Doke/Idris** | Define the SLOs that decide what is worth alerting on |

## Open questions

**How does DBeaver authenticate?** This is the live one. Today people connect with the
**root credentials**, which Tim wants to stop: *"we need to find a way to use the SSO as a
login into DBeaver without having to use the root credentials."* He notes DBeaver's SSO path
is Kerberos v5 over SSPI, and asked whether we are on Azure AD. Nobody on the call knew
whether this has ever been connected — *"I don't think we've tested the connection."*

**Scope is wider than one person.** *"All users will probably need to be able to connect via
DBeaver, and through the SQL Console."* Driven by QA testing, so this lands before QA is
useful to his team.

**Tool choice is open.** *"If there's a better tool to use I'm open to it — they're already
all using DBeaver so I just adopted that."*

## Tim's status, in his words

Leadership meeting held last week. He is waiting on a couple of people to review how the
project is laid out — the flow and the workflows. Once those approvals land: developer
kickoff, then launch, then people onto the platform. *"All this work is culminating, so it's
good."*

## What this contradicts, and what it confirms

**Confirms** the diagnosis from earlier the same day: the Console organisation decides which
cluster you can see, and it is not a permissions problem. Tim understood it as a team
boundary — he reached for *"you could call it a project"* — and the model only needs splitting
if another team (his example: a second team alongside Jenni's) takes on RisingWave later.

**Contradicts nothing in the repo**, but it does move DBeaver from "documentation request" to
"untested integration". The morning's position was that INFRA-1654 blocked it; by the evening
we had proved a NodePort route works with root and no password, so the blocker is not
connectivity — it is that the only known way in is a shared superuser credential.

## Traps

**The transcript is half echo.** 151 lines are attributed to Dare and roughly 63 of those are
the meeting audio coming back through the mic three seconds late. Several put Tim's words
under Doke's name, including Tim's own sign-off. Anyone reading this file raw will
mis-attribute decisions. Fixed in the server on the same day — see the echo suppression in
`meeting-copilot/server.py` — but every transcript before 2026-10-26 has this flaw.

**"Kiwi", "QWave", "QM Prod", "eBeaver", "DBV", "awgs"** are all mis-transcriptions — QA,
QA/prod, DBeaver and orgs. The glossary has been extended, but treat any unfamiliar proper
noun in a transcript as suspect rather than as a fact.
# Meeting transcript 2026-10-26_1833

- [18:33:30] **Them:** Um...
- [18:33:33] **Dare:** Um...
- [18:33:35] **Them:** So with PR59, guys, the cluster database...
- [18:33:38] **Dare:** So with PR59, guys, the cluster database...
- [18:33:41] **Them:** What does that mean? It says it's really just which cluster database config you see, what are the...

**Q1:** What does that mean? It says it's really just which cluster database config you see, what are the...
(compressed: What does that mean? It says it's really just which cluster database config you see, what are the)
- [18:33:44] **Dare:** What does that mean? It's really just which cluster database config you see, what are the...
**A1 fast** (4087 ms, first token 3900 ms):
SAY: Good question — let me confirm and come back to you on that.
NEED_LOOKUP: PR59 cluster database config meaning, in the repo

- [18:33:47] **Them:** Different clusters and databases.
- [18:33:49] **Dare:** Different clusters and databases.
- [18:33:52] **Them:** So you're talking about dev and QA?

**Q2:** So you're talking about dev and QA?
(compressed: You're talking about dev and QA?)
- [18:33:56] **Dare:** So you're talking about dev and QA?
**A2 fast** (3881 ms, first token 3720 ms):
SAY: Good question — let me confirm and come back to you on that.
NEED_LOOKUP: which clusters PR59 changes, dev, QA or both

- [18:34:07] **Mic:** So let me...where are we?

**Q3:** So let me...where are we?
(compressed: Let me...where are we?)
**A1 deep** (17711 ms):
SAY: It's about which organisation you land in when you sign in to the RisingWave Console. Each SSO user gets their own private organisation the first time they log in, and the cluster connection is stored per organisation. So if your organisation was created after the cluster was registered, you log in fine but see no databases. It's not a permissions problem.

DETAIL:
- The table `public.cluster_connection_info` is keyed by org_id. It only has rows for orgs 1–8, written in one batch on 2026-10-06 at 19:02.
- Tim's org (created 17:21) has the cluster. Mine (21:43 that day) and Jenni's (23 Oct) don't.
- Idris works in org 1, which is why he never hit this.
- The fix is a shared organisation that people get added to, starting with org 1 on op-usxpress-dev.

Not verified: that PR59 is this fix. The repo notes don't link it to a PR number, so check the PR title before you confirm.

**A3 fast** (2821 ms, first token 2153 ms):
SAY: We're in Sprint 7, and prod is about three-quarters ready. SSO is live on all three authenticators, and the only missing piece is the kube-apiserver webhook flag, which goes through Octopus.
DETAIL:
- Office access to on-prem apps is fixed on dev and QA (2026-10-20); prod is still blocked.
- RisingWave is proven end to end at usxpressinc/risingwave, with the runbook on Confluence.
- Argo CD with Entra SSO has been live on dev, QA and prod since 2026-08-25.

- [18:34:14] **Mic:** Okay, so let me go back to the notes.
**A1 deep** (32429 ms):
SAY: In the RisingWave Console, which cluster you see depends on your Console organisation, not on your RisingWave permissions. Each new SSO user gets their own private org, and only orgs that existed on October 6th were given the cluster's connection details. I'll confirm exactly what PR59 changes after the call.

DETAIL:
- The connection details live in the Console's `cluster_connection_info` table, one row per org. There are 8 rows, for orgs 1 to 8. Later runs only updated those rows and never added new ones.
- Jenni and I see an empty Console. Tim and Idris don't, because their orgs have a cluster (Idris is in org 1).
- For now, a SQL script adds affected users to org 1. The lasting fix is a shared org that `risingwave-console-init` sets up automatically.
- I couldn't find a PR59 about this in my repo. The only #59 there is an old Velero PR.

RESEARCH_NEEDED: Find PR59 in usxpressinc/risingwave or iaac-risingwave-onprem.

- [18:34:17] **Mic:** It's okay.
**A2 deep** (25892 ms):
SAY: The only PR 59 I have on record is a dev-only change. It went to op-dev in June. If you mean a newer PR 59 in the RisingWave repo, let me check that and get back to you before I say dev, QA or both.

DETAIL:
- The PR 59 I found is variant-inc/iaac-talos-flux-platform #59, from 2026-06-23. It added `AWS_REGION=us-east-2` to Velero on **op-usxpress-dev**. It caused a helm rollback, and the fix landed in #60.
- The repo notes say nothing about a PR 59 in usxpressinc/risingwave or iaac-risingwave-onprem.
- Watch out: RisingWave on-prem has no promotion gate. Every cluster tracks `main`, so a merge there reaches dev, QA and prod.
- To check: `gh pr view 59 --repo usxpressinc/risingwave --json files` on WSL.

**A1 refine** (37208 ms) — context: is it dev and QA:
SAY: It decides which RisingWave Console organisation you land in, and the cluster connection is stored per organisation. If your org was created after the cluster was registered, you can log in but you see no databases. So far that's only been worked on in dev. QA isn't done yet, and I'll confirm exactly what PR 59 covers after the call.

DETAIL:
- `cluster_connection_info` has 8 rows, one each for orgs 1 to 8, written in a single batch on 2026-10-06. Later runs never added rows for new orgs.
- The interim fix is SQL that adds Jenni and me to org 1, where Idris already is. It's marked "DEV ONLY" until the bootstrap change lands.
- The lasting fix is a shared org that `risingwave-console-init` seeds.
- I couldn't find this PR 59 in my repo. The only #59 I have is an old Velero PR.

RESEARCH_NEEDED: Run `gh pr view 59 --json files` on the RisingWave repo to see which clusters it touches.

- [18:34:38] **Mic:** I can't get it.
- [18:34:52] **Mic:** Okay, so you are talking about...
- [18:35:01] **Them:** So the last thing Idris sent at 12.45, I was really just reading the last paragraph there.
- [18:35:04] **Dare:** So the last thing Idris sent at 12.45, I was really just reading the last paragraph.
- [18:35:06] **Dare:** BR, Tim keeps his privileges, Wilder State operators, no one sees each other's worries.
- [18:35:11] **Them:** With PR, Tim keeps his privileges while they stay operators, no one sees each other's queries. The org is really just which cluster database config you see.
- [18:35:13] **Dare:** The org is really just which cluster database config you see.
- [18:35:16] **Them:** What does that mean?

**Q4:** What does that mean?
(compressed: What does that mean?)
**A4 fast** (2366 ms, first token 2194 ms):
SAY: Good question — let me confirm and come back to you on that.
NEED_LOOKUP: what "PR" and "org" mean in the cluster database config discussion

- [18:35:18] **Dare:** What does that mean?
- [18:35:21] **Dare:** With cluster, so cluster meaning that would be dev QA production.
- [18:35:24] **Dare:** Umm...
- [18:35:29] **Dare:** And yeah, that would pretty much follow the same pattern for database.
**A4 deep** (14874 ms):
SAY: In the RisingWave Console, an "org" is just a folder that decides which cluster connection you see. It has nothing to do with database permissions. Everyone keeps their own RisingWave privileges, and putting people in the same org only means they all see the same cluster.

DETAIL:
- The Console gives each SSO user their own private org the first time they sign in. Cluster connections are stored per org (`cluster_connection_info`).
- One batch on 2026-10-06 at 19:02 registered the cluster for orgs 1–8 only, and it doesn't add anyone later. Tim's org got a cluster; mine and Jenni's didn't, so we log in fine and see an empty Console.
- For now we add the people affected to org 1, where Idris already is (`wip/rw-console-org/add-users-to-platform-org.sql`). The lasting fix is a shared org that the console-init job creates.
- I'm not sure what "PR" meant in the transcript; it may have been "per org". I'd ask them to repeat it.

- [18:35:36] **Them:** What's the benefit in PR60? Is there any?

**Q5:** What's the benefit in PR60? Is there any?
(compressed: What's the benefit in PR60? Is there any?)
**A5 fast** (1955 ms, first token 1686 ms):
SAY: Good question — let me confirm and come back to you on that.
NEED_LOOKUP: PR60 purpose and expected benefit, from the repo or ticket

- [18:35:39] **Dare:** What's the benefit in PR60? Is there any?
- [18:35:42] **Them:** And for orgs.
- [18:35:44] **Dare:** It's every time a new user...
- [18:35:47] **Dare:** Onboards into your system.
- [18:35:51] **Dare:** They're automatically created into, a separate org is created for them.
**A5 deep** (13796 ms):
SAY: Honestly, not much. PR 60 added the RisingWave storage bucket and its AWS role to iaac-talos, but the RisingWave repo already manages those same two resources. Now two projects own one thing, and that is a risk we still need to clean up.

DETAIL:
- iaac-talos #60, "add RisingWave on-prem IRSA role and S3 state bucket", by Idris; I reviewed it 2026-08-11.
- The same bucket and role are already in `iaac-risingwave-onprem/terraform/main.tf`.
- My notes disagree on its fate: the 08-12 note says it was closed as a duplicate, and a later note says it was merged. I'd check on GitHub before quoting either.
- If it merged, the fix is four `terraform state rm` steps. They're planned but no PR exists yet.

If they meant platform-repo #60 instead: that one removed a duplicate Velero setting (June 23).

- [18:35:55] **Dare:** So that's the default behavior.
- [18:36:01] **Mic:** Now, what 59 does is it's...

**Q6:** Now, what 59 does is it's...
(compressed: What 59 does is it's)
**A6 fast** (1739 ms, first token 1473 ms):
SAY: Good question — let me confirm and come back to you on that.
NEED_LOOKUP: what PR 59 changes about per-user org creation, from the repo

- [18:36:08] **Mic:** It brings them into the org that you're in, but it doesn't give them real privilege.
- [18:36:18] **Dare:** What 60 does is they stay within the org that they have, but it copies...
- [18:36:28] **Dare:** You're the one that doesn't have real privileges. It copies it into the org that they're in. So it kind of isolates everybody.
**A6 deep** (26453 ms):
SAY: I don't have PR 59 in my notes, so I won't guess what it does. What I can tell you is the problem it would need to fix: each new SSO user gets their own private Console organisation, but the cluster connection was only stored for the eight organisations that existed on October 6th. Anyone created after that logs in and sees an empty Console. I'll read 59 and come back to you today.

DETAIL:
- `public.cluster_connection_info` is keyed by org_id. It has 8 rows, for orgs 1 to 8, written at 2026-10-06 19:02.
- The bootstrap runs on Oct 13 and 15 updated those 8 rows and added none, so new users are never filled in.
- For now we're adding the affected users (me, Jenni) to org 1, where Idris already is (`wip/rw-console-org/add-users-to-platform-org.sql`).
- The lasting fix is a named shared org that `risingwave-console-init` creates, with membership that keeps itself up to date. The earlier org-sync change was iaac-risingwave-onprem #36, approved for QA only on 2026-09-15.

To check: open PR 59 in usxpressinc/risingwave and in iaac-risingwave-onprem.

- [18:36:33] **Dare:** At the end of the day, it's up to you how...
- [18:36:36] **Mic:** You know, you want things to be structured.
- [18:36:42] **Them:** Um...
- [18:36:45] **Them:** Tell me what an org is.

**Q7:** Tell me what an org is.
(compressed: Tell me what an org is)
- [18:36:47] **Dare:** Tell me what an org is.
**A7 fast** (3245 ms, first token 2994 ms):
SAY: Good question — let me confirm and come back to you on that.
NEED_LOOKUP: definition of "org" in the PR59/PR60 user-isolation discussion, from the repo

- [18:36:50] **Dare:** It's, ugh.
- [18:36:53] **Dare:** At this point, you know...
- [18:36:55] **Dare:** We are using the word odd because...
- [18:36:58] **Dare:** That's how.
**A7 deep** (12928 ms):
SAY: An org is a workspace inside the RisingWave Console. It owns its members and the clusters registered to it. Every new SSO user automatically gets their own private org, and a cluster only shows up in the org it was registered to. So a new person can log in fine and still see an empty Console.

DETAIL:
- The cluster connection rows exist only for orgs 1 to 8. They were created in one batch on 2026-10-06, so anyone whose org came later sees nothing.
- Org 1 is the shared platform org. Idris is the only person already in it, which is why he never hit this.
- The dev-only fix adds people to org 1 and makes it their default: `wip/rw-console-org/add-users-to-platform-org.sql`. It is not for QA or prod yet.
- I couldn't find PR59 or PR60 in the repo. I'd check the PR on GHE before saying what either one changes.

- [18:37:02] **Mic:** You know, but essentially it's a...
- [18:37:10] **Mic:** You could call it a project, you know, like, or, you, you in this case...
- [18:37:15] **Mic:** There wouldn't be separate awgs, right? Because they would all be under her.

**Q8:** There wouldn't be separate awgs, right? Because they would all be under her.
(compressed: There wouldn't be separate awgs, right? Because they would all be under her)
**A8 fast** (1943 ms, first token 1580 ms):
SAY: Good question — let me confirm and come back to you on that.
NEED_LOOKUP: whether PR59 or PR60 creates separate orgs per user, from the repo

- [18:37:18] **Mic:** Under your team, so it's like a team.
- [18:37:21] **Mic:** You know, but...
- [18:37:23] **Mic:** If RisingWave becomes something where...
- [18:37:31] **Mic:** You have sep, you know, the way we have different teams, right? Jenny's on your, she's your weak Jenny's team, then there's...

**Q9:** You have sep, you know, the way we have different teams, right? Jenny's on your, she's your weak Jenny's team, then there's...
(compressed: You have sep, the way we have different teams, right? Jenny's on your, she's your weak Jenny's team, then there's)
**A9 fast** (2591 ms, first token 2336 ms):
SAY: Good question — let me confirm and come back to you on that.
NEED_LOOKUP: team structure and Jenny's reporting line; brief lists owners only

- [18:37:38] **Dare:** There's Buddy that has another team. If they also want to be used in RisingWave, then we would have separate awgs.
- [18:37:41] **Them:** Gotcha.
**A8 deep** (24847 ms):
SAY: Right now each person does get their own org. The RisingWave Console creates a private organisation for every SSO user the first time they sign in, and the cluster is registered per organisation. The fix is to put everyone in one shared org, so it all sits under one place.

DETAIL:
- The cluster is registered in orgs 1–8 only, all done in one batch on 2026-10-06. Anyone whose org came later logs in fine but sees an empty Console.
- Idris is already in org 1, which is why he never hit this.
- The dev-only fix is `wip/rw-console-org/add-users-to-platform-org.sql`. It moves Doke and jlray into org 1. QA and prod wait until the bootstrap change lands.
- I couldn't find a Console-org PR #59 or #60 in the repo. Both numbers there are other work: #59/#60 on the platform repo were Velero, and iaac-talos #60 was a duplicate that got closed. I'd check the risingwave repo's PR list.

RESEARCH_NEEDED: whether the RisingWave Console can disable per-user org creation

**A9 deep** (9050 ms):
SAY: Right now I own the RisingWave platform side, which covers the cluster, the deploys and SSO. Nobody has been named as the owner of the data pipelines on top of it. If RisingWave becomes its own thing, it needs a named owning team like the others, and that's a decision for us to make here.

DETAIL:
- The brief lists the RisingWave data pipeline owners as "unknown — confirm".
- The repo has nothing on team structure or on Jenny's reporting line. Her only mention is as an Argo CD access user (Jenny Ray, viewer group).
- The ownership question matters because RisingWave has no promotion gate. Merging to main deploys to prod.
- The canonical repo is usxpressinc/risingwave, branch master, decided 2026-10-21.

To verify: ask who Jenny reports to, or check the org chart in Entra or Teams.

- [18:37:44] **Dare:** For things like that.
- [18:37:46] **Them:** Um...
- [18:37:48] **Dare:** Um...
- [18:37:51] **Them:** Let's go with the easiest thing for right now, I guess.
- [18:37:54] **Dare:** Let's start with the easiest thing for right now, I guess.
- [18:37:56] **Dare:** Yeah, and then we also kind of...
- [18:37:59] **Dare:** I think what Idris is saying is there is a particular...
- [18:38:01] **Dare:** Um...
- [18:38:04] **Dare:** I don't know, let me go back to this.
- [18:38:06] **Mic:** The nodes it creates.
- [18:38:10] **Dare:** Okay, so for you specifically, you get admin privileges, right?
- [18:38:15] **Dare:** So, but everyone else just, they act as an operator.
- [18:38:28] **Dare:** So that is baked into your access right now. And obviously if we need to expand on who has had been privileges in the future, we can. But for right now, we're just limiting it to you.
- [18:38:31] **Mic:** Right. Yeah. So...
- [18:38:40] **Mic:** And it just makes it easier because I think by default, you would think everybody that comes in automatically comes into the project that you've...
- [18:38:44] **Them:** Right.
- [18:38:49] **Dare:** Laid the foundations forward, right, as opposed to everybody's task waiting a new copy of their own.
- [18:38:51] **Them:** Yeah, no, we don't want that.
- [18:38:54] **Dare:** You know? Yeah, no, we don't want that. Right, right. Yeah, yeah, yeah. We don't wanna...
- [18:38:57] **Them:** Yeah, yeah, yeah. We don't want that. Boom.
- [18:38:59] **Dare:** Okay, okay, um...
- [18:39:02] **Them:** Okay.
- [18:39:04] **Them:** What do people...
- [18:39:07] **Dare:** What do people...
- [18:39:09] **Them:** Log in with...
- [18:39:11] **Dare:** Log in with...
- [18:39:14] **Them:** When using DBV.
- [18:39:16] **Dare:** When using DBeaver.
- [18:39:19] **Dare:** It's SSO, so it's just, I'm not, I don't really think I've, Idris, do you know how the SSO thing works?
- [18:39:22] **Mic:** Right now, I don't think we've connected the room.
- [18:39:26] **Them:** Right now, I don't think we've connected the, you know, like the connection, or we've tested the connection with...
- [18:39:29] **Dare:** You know, like the connection always tested the connection with...
- [18:39:32] **Them:** GBV, so that's something that we can kind of do a test.
- [18:39:34] **Dare:** DBverse, so that's something that we can kind of do a test.
- [18:39:37] **Them:** Thanks,
- [18:39:39] **Dare:** I don't think that
- [18:39:50] **Dare:** Because finally, what we did previously was to use the root credentials to connect to the beaver.
- [18:39:59] **Dare:** Well, right now, we need to kind of test or find a way to use the SSO as a login into the diva without having to...
- [18:40:02] **Them:** Because currently what we did previously was to use the root credentials to connect to the beaver. But right now we need to kind of test or find a way to use the SSO as a login into the beaaver without having to particularly use...
- [18:40:05] **Them:** The root credentials.
- [18:40:07] **Dare:** I totally used the root credentials.
- [18:40:10] **Them:** Yeah, I guess it does. It uses Kerberos version 5 for SSPI.
- [18:40:13] **Dare:** Yeah, I guess it does. It uses Kerberos version 5 for SSPI.
- [18:40:17] **Them:** Okay, yeah, we'll need to get that hooked up because we'll need to give people into.
- [18:40:20] **Dare:** Okay, yeah, we'll need to get that hooked up because we'll need to give people into.
- [18:40:23] **Them:** ...into the database.
- [18:40:25] **Dare:** I'm going to go into the database.
- [18:40:28] **Them:** Love it for QA testing.
- [18:40:30] **Dare:** Love it for QA testing.
- [18:40:33] **Them:** So all users will probably need to be able to connect via dbeaver.
- [18:40:36] **Dare:** So all users will probably need to be able to connect by a debeaver.
- [18:40:38] **Them:** And through the SQL Console.
- [18:40:40] **Dare:** And through the SQL Console.
- [18:40:43] **Them:** I'm a part of the RisingWave console.
- [18:40:46] **Dare:** For the RisingWave console.
- [18:40:48] **Dare:** O-ga.
- [18:40:50] **Dare:** Umm...
- [18:40:53] **Dare:** Can we create a ticket for that address?
- [18:40:55] **Dare:** Is that okay?
- [18:40:58] **Them:** So, alright.
- [18:41:02] **Them:** Sorry, I was on mute, I'm creating that now.
- [18:41:05] **Dare:** Sorry, I was not mean to say I'm creating that now.
- [18:41:08] **Dare:** Um...
- [18:41:10] **Them:** Are we on Azure AD? Is that where we are?

**Q10:** Are we on Azure AD? Is that where we are?
(compressed: Are we on Azure AD? Is that where we are?)
**A10 fast** (2510 ms, first token 1977 ms):
SAY: Yes, we're on Entra ID, which is Azure AD's current name. It handles app SSO, including Argo CD. Kubectl access goes through AWS IAM Identity Center instead.
DETAIL:
- Entra ID is used for app SSO; Argo CD uses app roles, and the tenant doesn't send a groups claim.
- Human kubectl access is AWS SSO via aws-iam-authenticator; client certs are break-glass only.

- [18:41:13] **Dare:** Are we on Azure AD? Is that where we are?
- [18:41:22] **Dare:** So outside of that, my update is we had our leadership meeting last week.
- [18:41:25] **Them:** Yeah, okay. So, outside of that, my update is we had our leadership meeting last week.
- [18:41:32] **Them:** I'm waiting for a couple of people to review the work that I've already done in terms of how the project's laid out and the flow and the...
- [18:41:35] **Dare:** I'm waiting for a couple of people to review the work that I've already done in terms of how the project's laid out and the flow and the...
- [18:41:38] **Dare:** Thought process, if you will, the workflows. As soon as we get some approvals on that.
- [18:41:42] **Dare:** Then we will do a developer kick-off and launch.
- [18:41:45] **Them:** Thought process, if you will, the workflows. As soon as we get some approvals on that, then we will do a developer kickoff and lunch.
- [18:41:48] **Them:** And then we'll actually get people into the platform.
- [18:41:51] **Dare:** And then we'll actually get people into the platform.
- [18:41:57] **Them:** So yeah, all this work is culminating, so it's good.
- [18:42:02] **Dare:** Sounds good. All this work is culminating. All this is work is dominating. All this stuff. All this, all this work, all of this work is culminating, so that's good. All this. All this All this
- [18:42:05] **Dare:** That's good. For me, I'm going to...
- [18:42:07] **Dare:** Finish up by the dev, sorry, the prod.
- [18:42:10] **Dare:** The prod work.
- [18:42:13] **Dare:** You know, I would like if maybe sometime this week you can kick off the wheels on Kiwi.
- [18:42:17] **Mic:** Just to see if everything is good.
- [18:42:19] **Mic:** And, uh...
- [18:42:35] **Mic:** Besides that, there's some other onboarding work that ETRIS is doing, so everything at the end of the day starts aligning with what you're doing as well.
- [18:42:42] **Mic:** So, you know, we're following those both paths, or at least we have two different projects right now.
- [18:42:45] **Mic:** Um, yeah, so we kind of...
- [18:42:48] **Mic:** Both just...
- [18:42:52] **Mic:** Working on both projects.
- [18:42:54] **Mic:** Also, if...
- [18:43:00] **Mic:** No, not a rush, but when you get a chance, if you can confine me if you're...
- [18:43:07] **Mic:** Monitoring and observability looks good if there's any areas that you have some...
- [18:43:12] **Them:** Yep, I need...
- [18:43:15] **Dare:** Feedback on, let us know, okay? So that we can...
- [18:43:18] **Them:** I need to look at the monitoring, I haven't looked at that yet.
- [18:43:24] **Dare:** I need to look at the monitoring. I haven't looked at that yet. Yeah, no rush, but just something which should wrap up properly in, you know, I want...
- [18:43:32] **Dare:** The way I envision it is, you pretty much have a dedicated Slack channel for RisingWave.
- [18:43:40] **Mic:** And if something fires, you know, it comes there, which shouldn't be saying like lots of alerts, right?

**Q11:** And if something fires, you know, it comes there, which shouldn't be saying like lots of alerts, right?
(compressed: If something fires, it comes there, which shouldn't be saying like lots of alerts, right?)
- [18:43:43] **Mic:** We should just be seeing things that are very important.
**A11 fast** (2769 ms, first token 2082 ms):
SAY: Agreed, a dedicated RisingWave channel with tight routing is the right shape. Today our on-prem alerts don't reach anyone, so we're wiring receivers before we add more noise.
DETAIL:
- No Alertmanager receivers are wired on dev, and prod is still pending.
- RisingWave on-prem has no promotion gate, so alert routing matters more there.
- The Slack channel setup isn't in the brief; I'd confirm it before promising a date.

- [18:43:46] **Mic:** That comes in there and, you know...
- [18:43:49] **Mic:** Um...
- [18:44:09] **Mic:** Eventually, we'll get to the point where we would say certain things are purely applications, certain things that are purely infrastructure. But for now, we can use just one dedicated Teams chat that I see what you see, you see what I see kind of thing until we can decide which one needs to go to you. So it's a good way to...
- [18:44:12] **Mic:** Build up.
- [18:44:14] **Mic:** That's my charity on the availability for RisingWave in the dev environment.
- [18:44:18] **Them:** Okay, so I already have a Teams channel set up.
- [18:44:20] **Dare:** Okay, so I already have a Teams channel set up. Okay.
- [18:44:23] **Them:** Mm-mm.
- [18:44:25] **Them:** Yep.
- [18:44:28] **Dare:** So you can ping that into the chat. Let's write a ticket for this as well to wire it up.
- [18:44:36] **Them:** Check us off, teams. Stop being ugly.
- [18:44:38] **Dare:** At the soft teams, stop being ugly.
- [18:44:41] **Dare:** Oh.
- [18:44:43] **Them:** I have, let's see.
- [18:44:46] **Dare:** Bye, have, let's see.
- [18:44:50] **Dare:** Well, I'll just give you the...
- [18:44:53] **Them:** Well, I'll just give you the...
- [18:44:55] **Them:** I'll just give you the channel if we need to.
- [18:44:58] **Dare:** I'll just give you the channel. We need to see.
- [18:45:00] **Dare:** Create something new we can.
- [18:45:03] **Them:** Create something new we can.
- [18:45:06] **Them:** Manage team, I'm sure that you guys were on there. I'm I'm so sure you were.
- [18:45:09] **Dare:** Manage Team, I know that you guys were on there, I'm sure you were.
- [18:45:11] **Dare:** Idris, uh...
- [18:45:13] **Dare:** Do we currently have...
- [18:45:16] **Dare:** Team setup for RisingWave already.
- [18:45:21] **Them:** Here's the ray.
- [18:45:23] **Dare:** I'm sorry.
- [18:45:26] **Dare:** I need to add interest. Oh, sorry, I was on mute. So which part?
- [18:45:29] **Them:** I need to add interest. Oh, sorry, I was on mute. So which button?

**Q12:** I need to add interest. Oh, sorry, I was on mute. So which button?
(compressed: I need to add interest. Oh, sorry, I was on mute. So which button?)
**A12 fast** (2123 ms, first token 1822 ms):
SAY: Good question — let me confirm and come back to you on that.
NEED_LOOKUP: which meeting or Slack button adds the channel; not in brief

- [18:45:32] **Dare:** Do we have teams set up for RisingWave correctly?
- [18:45:34] **Them:** In terms of the alerts, right?
- [18:45:37] **Dare:** I think there was something that Steve- Because of that, right? Yes.
**A12 deep** (8109 ms):
SAY: Sorry, I lost you there for a second. Which button do you mean: adding the channel in Teams, or something in the app we're looking at? Tell me what's on your screen and I'll walk you through it.

DETAIL:
- The transcript is garbled. "Add interest" is probably "add this" or "add it", said right after someone offered to share "the channel".
- Nothing in the repo or the brief covers which button adds a channel or shares one.
- If it's Teams: go to Teams → the team's "…" menu → "Add channel". For a channel someone else shares, open the shared link, or go to "…" → "Manage team" → Channels → "Show".
- To confirm, ask them to share their screen. Don't guess.

- [18:45:40] **Them:** Yeah, I think we do have...
- [18:45:49] **Dare:** Yeah, I think we do have... Okay, so we need to reroute. Well, let me ask Steve on this one. So Steve, I know you were pinging me then that we were getting way too many alerts. That was RisingWave, if I remember correctly.
- [18:45:51] **Them:** Is it? I thought it was just...

**Q13:** Is it? I thought it was just...
(compressed: Is it? I thought it was just)
- [18:45:54] **Dare:** I thought it was just on-prem.
**A13 fast** (2925 ms, first token 2261 ms):
SAY: I can't confirm where the alert noise came from. Our brief says on-prem alerts reach nobody right now, so let me check what's actually firing before I say it was RisingWave.
DETAIL:
- On-prem alerts have no delivery path on dev, and prod is still pending.
- The brief doesn't record alert volume or which rules caused it.
- NEED_LOOKUP: RisingWave alert rules and firing counts in the repo.

- [18:45:57] **Them:** Let me, yeah, this is on-prem.
- [18:46:00] **Them:** So it may be a mix of everything, but I'm assuming obviously it is some rising wave.
**A13 deep** (11613 ms):
SAY: Not all of it was RisingWave. When we measured dev in August, 54 alerts were firing and only a few were RisingWave's. Most of the noise is old platform alerts nobody has sorted yet. I'll check which ones Steve is getting and confirm.

DETAIL:
- On 2026-08-21, op-dev had about 40 alert rules and 54 firing alerts. The oldest had been firing since 2026-06-24. There is no Alertmanager on dev.
- The RisingWave ones were in `risingwave-2`: a Prometheus pod crash-looping and a full volume. That volume really was full.
- As of 2026-10-12, 4 alert rules are labelled `team=risingwave`, 29 `team=platform`, and 177 have no team label.
- INFRA-1658 is the ticket to triage those 54 before alerts start getting sent to anyone.

Verify: these counts are from August and October, not today. Ask Steve which channel and which alert names he's seeing, then check what's firing on that cluster now.

- [18:46:13] **Dare:** Yeah, it was just on-prem. Oh, okay, okay. Then, then, you know... So, maybe a mix of everything, but... Yeah. I'm assuming, obviously, there's some rising wave. Yeah, no, then... So, Idris, just leave that for now. Let's just connect things so we can probably use some form of filter for anything that's rising wave, you now.
- [18:46:16] **Them:** Okay.
- [18:46:18] **Dare:** Um, you know, but let's, I think in the...
- [18:46:25] **Dare:** You know, if we use the namespace, we can use a namespace scope or something in Grafana to...
- [18:46:46] **Mic:** You know, to just filter it down to RisingWave implementation, anything that fires, and let's watch those particular things, send it to teams. We don't, you know, it shouldn't be like we're getting every single thing, right? So let's define the SLO, let's create a confidence space for what we are watching, you know.

**Q14:** You know, to just filter it down to RisingWave implementation, anything that fires, and let's watch those particular things, send it to teams. We don't, you know, it shouldn't be like we're getting every single thing, right? So let's define the SLO, let's create a confidence space for what we are watching, you know.
(compressed: … anything that fires, and let's watch those particular things, send it to teams. We don't, it shouldn't be like we're getting every single thing, right? So let's define the SLO, let's create a confidence space for what we are watching)
**A14 fast** (2488 ms, first token 1525 ms):
SAY: Agreed: route only RisingWave alerts to Teams, and set an SLO first so we know what's worth paging on. Scope by namespace in Grafana, so the filter is one rule, not a per-alert judgment.
DETAIL:
- Filter on the RisingWave namespace (risingwave-2 on dev is v2.8.2; all three clusters run v3.0.5).
- Define the SLO and alert set before wiring the Teams route, so the channel stays quiet.
- Dev has no Alertmanager receivers yet, so routing starts there.

- [18:46:49] **Mic:** And then everything goes to Teams for now.
- [18:46:52] **Mic:** You know, with time we'll decide.
- [18:47:02] **Mic:** What should go to, you know, we'll probably have a dedicated distribution list for application and dedicated distribution lists for platform.

**Q15:** What should go to, you know, we'll probably have a dedicated distribution list for application and dedicated distribution lists for platform.
(compressed: What should go to, we'll probably have a dedicated distribution list for application and dedicated distribution lists for platform)
**A15 fast** (2818 ms, first token 1893 ms):
SAY: Splitting by owner makes sense: platform alerts go to the platform list, and application or pipeline alerts go to the application list. Everything goes to Teams until we've set the SLO and the routing is stable.
DETAIL:
- Platform: cluster health, Flux, Argo CD, Cilium, storage, and RisingWave engine health, owned by Dare.
- Application: RisingWave pipeline and data alerts. The brief lists those owners as unknown, so confirm before routing.
- The brief doesn't name the distribution lists, so their addresses still need confirming.

- [18:47:18] **Mic:** You know, and that's how we would operate once we get into QA and production. But for now, we're just using the same channels. Everybody sees everything that's coming in for RisingWave. But at this point, you know, RisingWave should not go down without us.
- [18:47:22] **Mic:** Get in a lot for it. If we do catch those kinds of things, then we have to create in a lot for.
- [18:47:27] **Mic:** And it could be anything secret.
- [18:47:35] **Mic:** You know, it could be pretty much anything. We just want to be able to catch anything that matters to the team on this application.
- [18:47:42] **Them:** I don't know how we want to do this if it's...
- [18:47:45] **Dare:** I don't know how we want to do this, if it's...
- [18:47:47] **Them:** I have.
- [18:47:50] **Dare:** I have...
- [18:47:52] **Them:** I have channels out there already that are...
- [18:47:55] **Dare:** I have channels out there already that are...
- [18:47:57] **Them:** RisingWave developer support, RisingWave production support.
- [18:48:00] **Dare:** RisingWave developer support, RisingWave production support,
- [18:48:03] **Them:** Don't know that we should use those, maybe we create...
- [18:48:05] **Dare:** Don't know that we should use those, maybe we create...
- [18:48:08] **Them:** New channels.
- [18:48:10] **Dare:** New channels.
- [18:48:13] **Them:** Broad and non-prod.
- [18:48:15] **Dare:** Prod and non-prod.
- [18:48:17] **Them:** Okay, um...
- [18:48:20] **Dare:** Okay.
- [18:48:22] **Them:** Jira's or something?
- [18:48:25] **Mic:** Errors or something?
- [18:48:28] **Mic:** It's up to you, just give us what you want us to, where you want to push the notifications to, you know, no rush on that really.

**Q16:** It's up to you, just give us what you want us to, where you want to push the notifications to, you know, no rush on that really.
(compressed: It's up to you, just give us what you want us to, where you want to push the notifications to, no rush on that really)
- [18:48:30] **Mic:** And we'll just push it there.
**A16 fast** (3495 ms, first token 2676 ms):
SAY: My suggestion: Teams for the live alerts, and Jira for anything that needs follow-up. Start with Teams only, and add Jira once the alert set is settled.
DETAIL:
- Teams: RisingWave alerts that have passed the SLO filter, routed by namespace.
- Jira: tickets for alerts that need a fix, not just a notice; the Sprint 7 board is 322.
- Platform and application lists come later, once owners are confirmed.

- [18:48:33] **Mic:** I'm thinking once we get to QM Prod.
- [18:48:36] **Mic:** We probably would only use those channels for...
- [18:48:38] **Mic:** 3-Adj and those things, Talos, would mostly be for 3-Aj. So we would probably...
- [18:48:41] **Dare:** Send alerts via email at that point.
- [18:48:43] **Them:** Oh, so you're just gonna do emails?

**Q17:** Oh, so you're just gonna do emails?
(compressed: Oh, so you're just gonna do emails?)
**A17 fast** (2123 ms, first token 1486 ms):
SAY: Yes, for alerts on-prem we start with email, since the Alertmanager receivers aren't wired on dev yet and prod is pending. I'll confirm the full channel plan and come back to you on the rest.
NEED_LOOKUP: on-prem Alertmanager receivers and alert delivery plan

- [18:48:50] **Dare:** Oh, so you're just going to do emails? When we get to QM Prod, we'll probably set it up to some form of escalation process.
**A17 deep** (11065 ms):
SAY: Email is the first receiver because it needs nothing new to stand up, so alerts start reaching people quickly. It's step one, not the end state. Today the rules fire but go nowhere: there's no Alertmanager on-prem, so step one is turning it on and pointing it somewhere.

DETAIL:
- On op-dev (checked 2026-08-21): about 40 rules and 54 alerts firing, all with no Alertmanager. It's switched off in our Prometheus config (`alertmanager.enabled: false`). Prod is still pending.
- On dev and QA we fixed the Flux alert rules on 2026-08-24. Getting them to fire took four fixes, one after another.
- Tickets: INFRA-1658 and INFRA-1659.
- I can't find a decision on Teams or a paging tool in the repo. If they push, tell them the routing for critical alerts is still to be confirmed.

RESEARCH_NEEDED: Alertmanager receiver options for Teams/PagerDuty, and the USX SMTP relay

- [18:48:58] **Them:** I'll copy these. Copy link.
- [18:49:00] **Dare:** Yeah, I'll copy this, copy link.
- [18:49:03] **Them:** That one.
- [18:49:06] **Dare:** Back on.
- [18:49:12] **Them:** Let me have to add you guys to those.
- [18:49:15] **Dare:** I may have to add you guys to those.
- [18:49:19] **Dare:** Okay.
- [18:49:22] **Dare:** 911.
- [18:49:25] **Them:** Well, if we're doing a, if were streaming, right?

**Q18:** Well, if we're doing a, if were streaming, right?
(compressed: Well, if we're doing a, if were streaming, right?)
**A18 fast** (1708 ms, first token 1188 ms):
SAY: Yes, if we're streaming, the alerts can go to the same place. I'll confirm the exact delivery path and come back to you on that.
NEED_LOOKUP: on-prem alert streaming and delivery path, Alertmanager receivers

- [18:49:28] **Them:** And this is what's driving our platform.
- [18:49:31] **Dare:** So if we're streaming, right? Right. And this is what's driving our platform.
**A18 deep** (9629 ms):
SAY: If we're streaming alerts somewhere, there's nothing on the on-prem side to stream yet. The rules fire, but no cluster has an Alertmanager or any notification route, so before I add you to a channel we have to choose the destination and clean up the backlog.

DETAIL:
- On 2026-10-05 we checked dev, QA and prod: none of them has an Alertmanager, a Flux Provider or a Flux Alert.
- The "On-Prem Platform" Teams channel isn't fed by the on-prem clusters. Its noise comes from somewhere else, and we haven't found the source yet.
- QA had 22 alerts firing when we measured on 2026-09-18. Some are false alarms caused by how Talos runs the control plane. One is real: QA's etcd backups are failing.
- Tickets: INFRA-1658 (sort out the firing alerts first), then INFRA-1659 (decide where alerts get delivered).

- [18:49:37] **Them:** So, a quick one. So, production allows you to go here, all allow you to regards to the environment.
- [18:49:39] **Dare:** So, first one, so production, I'll ask you to go here. All I'd like to regards to the environment.
- [18:49:51] **Dare:** I think that would be, well, let Tim tell us, I think the question would be where do we send the alerts? What team's channel do we sent the alerts that is related to Dev for now?
- [18:49:56] **Them:** Yeah, like that in terms of applications and platform.
- [18:49:59] **Dare:** There are like, in terms of applications and platform. Yes.
- [18:50:04] **Dare:** And it's something we can come back to, Tim. You don't have to address that now.
- [18:50:07] **Them:** I thought you'd-
- [18:50:10] **Dare:** I thought you'd-
- [18:50:12] **Them:** Okay, so you wanna send...
- [18:50:15] **Dare:** OK, so you want to send.
- [18:50:17] **Them:** Ew
- [18:50:20] **Dare:** You want some platform?
- [18:50:22] **Dare:** No, no, no. We arrange to have a platform channel.
- [18:50:25] **Them:** No, no, no. We already have a platform channel that has all our live JavaScript.
- [18:50:29] **Dare:** That does on-prem. So we have our on-prim channel, but we are saying RisingWave also has a platform component.
- [18:50:32] **Them:** Mm-hmm.
- [18:50:35] **Dare:** Right? So, if something is wrong with the platform component of RisingWave,
- [18:50:39] **Dare:** If something is wrong with the RisingWave application...
- [18:50:44] **Dare:** You give us the dev teams channel we're gonna use for that.
- [18:50:55] **Them:** Sounds like a lot of channels.
- [18:50:57] **Dare:** Sounds like a lot of channels.
- [18:51:11] **Dare:** And you know, in the field, when we get to QWave, it's just, you know you want to separate those things. Yeah, so as you can see, like we've got a channel out there that's on our platform, but there are certain ones that are saying hey namespace, RisingWave.
- [18:51:20] **Dare:** Yeah. Just having, you know, high memory sounds to the opportunity to filter out those so we can know, because there's a lot more in here than just that. It's everything on-prem. So.
- [18:51:24] **Them:** Yeah, so as you can see, like, we've got a channel out there that's on-prem platform, but there are certain ones that are saying, hey, namespace, RisingWave, it's having, you know, high memory, so we'll just take the opportunity to filter out those so we can know, because there's a lot more in here than just that, it's everything on-prom, so, yeah.
- [18:51:29] **Them:** All right, I'll get those set up and send them to you.
- [18:51:31] **Dare:** All right, I'll get those set up and send them to you.
- [18:51:34] **Dare:** Sounds good.
- [18:51:36] **Dare:** General, yeah.
- [18:51:38] **Dare:** I'll trade that probably.
- [18:51:41] **Them:** General, yeah. I'm afraid of probably...
- [18:51:44] **Them:** I'll probably create a prod and non-prod for both of those.
- [18:51:46] **Dare:** I'll probably create a prod and non-prod for both of those.
- [18:51:49] **Them:** If that works.
- [18:51:51] **Dare:** If that works.
- [18:51:54] **Dare:** Yeah, well, as long as it works for you, it's okay with us.
- [18:51:56] **Them:** Sounds good.
- [18:51:59] **Dare:** Sounds good.
- [18:52:01] **Dare:** Um...
- [18:52:04] **Them:** Michael, you got anything, sir?

**Q19:** Michael, you got anything, sir?
(compressed: Michael, you got anything, sir?)
**A19 fast** (1889 ms, first token 1541 ms):
SAY: Michael, I don't have a confirmed answer on that one yet. Let me check and come back to you before we close this item.
NEED_LOOKUP: Michael's on-prem alerting ownership or open items

- [18:52:13] **Dare:** Michael, you got anything, sir? No, I'm just glad to know that I don't have to book a ballroom or, you know, engage the the vice president's office to come down and you know.
**A19 deep** (8330 ms):
SAY: Nothing from you here. The question was for Michael, so let him answer. If it turns to alerting, say: "On-prem alerts still don't reach anyone. Dev has no Alertmanager receivers, and prod is still pending."

DETAIL:
- Michael doesn't appear anywhere in the repo. Nothing records him owning on-prem alerting or any open item.
- Dev has 40 alert rules and 54 firing, with no Alertmanager to send them anywhere.
- The Flux alert rules were broken for four separate reasons, one after another. Fixed on dev and QA 2026-08-24; prod is still pending.
- If Michael takes on alerting, ask him to own wiring up Alertmanager receivers, starting with dev.

RESEARCH_NEEDED: Michael's role and whether he owns on-prem alerting

- [18:52:16] **Dare:** Be part of a rising wave on site.
- [18:52:19] **Them:** No, I'm just glad to know that I don't have to book a ballroom or, you know, engage the Vice President's office to come down and, you know, be part of a, be a part of the RisingWave onsite.
- [18:52:22] **Them:** Who said, who turned us down?

**Q20:** Who said, who turned us down?
(compressed: Who said, who turned us down?)
**A20 fast** (1585 ms, first token 1300 ms):
SAY: I don't have the record of who turned that down, so I won't guess. Let me confirm and come back to you on it.
NEED_LOOKUP: who declined the RisingWave onsite request and why

- [18:52:25] **Dare:** Who turned us down?
- [18:52:28] **Them:** No, no, there's no one turned us down, you know, I just...
- [18:52:30] **Dare:** No, no, there's no one turned us down. Yeah, I just...
**A20 deep** (8012 ms):
SAY: I don't have who declined it in front of me, so I won't guess a name. I'll check and come back to you after the call.

DETAIL:
- The brief and the repo notes don't mention a RisingWave onsite request or anyone turning one down.
- From the transcript, it sounds like we're handling RisingWave without an onsite. The new repo is usxpressinc/risingwave, proven end to end on 2026-10-21, with the runbook on Confluence since 2026-10-23.
- To verify: search your Teams/email for "RisingWave onsite" and whoever handles the RisingWave vendor relationship.
- Fallback: "Michael, do you remember who sent the reply?"

- [18:52:33] **Dare:** Trying to realize the proper scope of the visit, you know?
- [18:52:36] **Them:** Trying to realize the proper scope of the visit, you know?

**Q21:** Trying to realize the proper scope of the visit, you know?
(compressed: Trying to realize the proper scope of the visit, ?)
**A21 fast** (1698 ms, first token 1346 ms):
SAY: The brief doesn't set the scope of an onsite visit, so I don't want to guess at it. I'll confirm what's planned and come back to you on that.
NEED_LOOKUP: RisingWave onsite visit scope, attendees, and dates

- [18:52:39] **Them:** So what he's referring to is November 9th.
- [18:52:42] **Them:** I believe Zach from RisingWave is gonna come make a site visit to us.
- [18:52:45] **Dare:** So what he's referring to is November 9th. I believe Zach from RisingWave is going to come like a site visit to us.
- [18:52:47] **Dare:** Nice, but yeah.
**A21 deep** (10662 ms):
SAY: I'm still pinning down the scope. Nobody turned us down, and it doesn't need to be a big event. My view is a working session on what's actually in front of us: the RisingWave cutover to the new repo and prod readiness. I'll send round a short agenda and attendee list.

DETAIL:
- The repo and brief have nothing on the onsite's scope, who's coming or dates. This meeting is the first mention.
- Canonical repo is usxpressinc/risingwave (branch master), proven end to end 2026-10-21. The runbook went to Confluence 2026-10-23.
- RisingWave v3.0.5 runs on dev, QA and prod.
- To check: search Teams and email for "RisingWave onsite" and confirm the vendor contact. The RisingWave pipeline owners are still unconfirmed.

- [18:52:50] **Them:** See ya.
- [18:52:53] **Them:** But I'm trying to firm that up today.
- [18:52:55] **Dare:** But I'm trying to firm that up today.
- [18:52:58] **Them:** He hasn't responded to me yet.
- [18:53:00] **Dare:** You guys aren't responding to me yet.
- [18:53:03] **Them:** All right, guys. Well, thank you. I'll look through that. And let me know what questions you have with the DBVR stuff.
- [18:53:07] **Dare:** All right, guys, well, thank you. Thank you. Thank you, everybody. I'll look through that. And let me know what questions you have with the DBEaver stuff.
- [18:53:10] **Them:** And we'll work through it.
- [18:53:12] **Dare:** And we'll work through it.
- [18:53:15] **Them:** And if there's a better tool to use, like I'm open to it, but...
- [18:53:18] **Them:** Like, they're already all using dbeaver, so I just adopted that.
- [18:53:21] **Dare:** And if there's a better tool to use, like I'm open to it, but like they're already all using eBeaver, so I just adopted that.
- [18:53:23] **Dare:** Sounds good.
- [18:53:26] **Them:** All right, guys. Appreciate y'all.
- [18:53:28] **Them:** Thank you. Thanks, guys.
- [18:53:31] **Dare:** Alright guys, appreciate y'all. Thank you. Thanks guys. Bye.
- [18:55:18] **Mic:** All get in with.

