# Networking + CySec call review — 2026-05-29

## TL;DR

Phase 1 (INFRA-1494 — TCP/SNI listeners) is **not gated** by anything from this call. Let's Encrypt was reaffirmed as the CA, on-prem subzone ownership was verbally cleared by Steve Duck, and the existing wildcard cert already works end-to-end. Everything else surfaced (CAA record, Wiz eBPF onboarding, LE auto-rotation, etcd encryption-at-rest, DR/Vault) is **QA/staging promotion work** that the lead should track but not let block Monday's execution.

Headcount on the call: Steve Duck (Networking), Brendan Buschel (CySec), Steve Vives (Wiz/security tooling), Doke.

## Decisions out of the call

- **LE remains the on-prem CA** — Brendan reaffirmed in-call ("Let's Encrypt is fine"), Steve Vives explicitly endorsed ("I love Let's Encrypt") [5:16]. No change to Phase 0 wiring.
- **On-prem owns `on-prem-dev.usxpress.io` and `op-dev.usxpress.io` subzones** — Steve Duck: "we won't have to argue anybody to take that" [2:09]. Registrar console to be confirmed with John Quick Griffin, but ownership question is settled.
- **CAA record will be added at the parent zone** — Brendan + Duck, pinning LE (and possibly GoDaddy) as authorized issuers. Placement (parent vs subzone) and CA list left open pending John Griffin loop-in [0:01].
- **LE cert rotation will be automated, not manual** — Doke agreed after Vives flagged manual rotation as the #1 ops risk ("Mount Everest of expired certs") [5:45]. Prometheus expiry alerting still required as the safety net.
- **Wiz replaces Orca for on-prem; eBPF sensor model** — Wiz will be onboarded onto top-3 crown-jewel hosts on op-usxpress-dev. Steve Vives is build-out lead (~1.5 weeks in). Sensor needs egress to wiz.io [7:00, 12:40].
- **AWS Secrets Manager stays as source of truth (not Vault)** — Doke locked this on portability/DR grounds: SM is global, apps lift-and-shift between cloud↔on-prem without helm rewrites [22:47]. Vault acknowledged as technically right but rejected for now (operational uplift, no in-house expertise).
- **etcd encryption-at-rest is a QA-promotion gate, NOT a dev gate** — Doke: "doesn't have to be solved in dev. Definitely not. But as we go into QA and we want to move into stages, we do have to have encryption" [23:30]. Doke to research SELinux / KMS provider / Vault-as-KMS options before QA buildout.
- **Hybrid platform vision locked in** — Duck framed AWS + on-prem as a hybrid (not intermingled), with workload placement by performance/proximity and DR failover capability [16:14]. Every on-prem design decision now carries a portability constraint. Doke's 90% on-prem-readiness claim (~157 apps, 10-12 archetypes, 2-3 validated) was stated as the current baseline [17:25].

## Action items (prioritized)

### P0 — this week

- **Proceed with Phase 1 (INFRA-1494) TCP/SNI listener build as designed.** Nothing from the call gates it. (Doke)
- **Send curated repo pointer to Brendan + Steve Vives + Steve Duck** — short README pointing them at networking + security-relevant areas in iaac-talos / iaac-talos-flux-platform so they can review BEFORE QA buildout. (Doke)
- **Pick top-3 crown-jewel hosts for Wiz eBPF sensor and DM the list to Steve Vives** — RisingWave host(s) likely #1 candidate; Talos worker bare-metal as candidates too. Triggers walking session. (Doke)

### P1 — next 2 weeks (parallel with Phase 1, don't block it)

- **Implement automated LE cert rotation** (cert-manager driven, hands-off). Verify Brendan/Vives have no security objection before flipping on in dev. (Doke)
- **Wire Prometheus cert-expiry alerts** for `*.op-dev.usxpress.io` and per-team certs — additive, retained even after auto-rotation. (Doke)
- **Generate post-rotation report/notification** so team has visibility on auto-rotation events. (Doke)
- **Schedule working session with Steve Vives** to drop Wiz eBPF sensors on the top-3 hosts together. (Doke initiates, Vives executes)

### P2 — before QA cluster buildout

- **Research etcd encryption-at-rest options** (native k8s EncryptionConfiguration with aescbc/secretbox, KMS provider plugin, Vault-as-KMS, or disk-level via SELinux/LUKS/Talos disk encryption). Draft options doc, circulate to Brendan + Vives + Duck. (Doke)
- **Document EKS cloud-side etcd encryption posture** so on-prem can mirror it (currently opaque to on-prem team since AWS abstracts the control plane). (Doke; consult cloud platform team)
- **Confirm parent zone (usxpress.io) registrar with John Quick Griffin** so CAA record can be added. Decide CA list (LE only vs LE + GoDaddy) once registrar is known. (Steve Duck owns; Doke + Brandon consult)
- **Confirm CAA record placement** — parent zone vs subzones — and publish. (Brandon + Duck)
- **Verify egress from op-usxpress-dev hosts to wiz.io endpoints exists** or file firewall ask with Networking. (Steve Vives + Steve Duck; Doke surface)

### P3 — design / forward-looking

- **DR bootstrap design for cross-cluster failover** — Vives flagged the chicken-and-egg of SM-as-source-of-truth ("everything exists here, how does that work?" [24:33]). Schedule a working session with Vives once Phase 1 ships. (Doke + Vives)
- **Apply TDD / work-backwards design discipline** (Vives's recommendation [25:47]) to QA/PROD TCP/SNI scale-out pattern — define the final outcome first, iterate the path backwards 2-3 times before locking pattern. (Doke)
- **Evaluate Wiz security-gate pattern** (admission control / PR check) and how it composes with existing Flux + Kyverno on op-usxpress-dev. (Doke + Brendan + Vives)

## New Jira tickets to file

Filed conservatively — only items that don't already have a home under INFRA-472 / INFRA-1492 / INFRA-1494 / INFRA-1496 / INFRA-1497.

| # | Title | Assignee | Parent / Link | Est. | Rationale |
|---|---|---|---|---|---|
| 1 | Automate LE cert rotation on op-usxpress-dev | Doke | INFRA-1492 | M | Vives flagged manual rotation as #1 ops risk. Needs Brendan + Vives sec sign-off before enabling. Not a Phase 1 blocker but required pre-QA. |
| 2 | Prometheus cert-expiry alerting (`*.op-dev` + per-team certs) | Doke | INFRA-1492 | S | Additive observability; safety net per Vives. |
| 3 | Publish CAA record on usxpress.io / on-prem subzones (LE-pinned) | Doke (driver), Steve Duck (registrar action) | INFRA-1492 | S | Hardening per Brendan. Blocked on Duck confirming registrar with John Griffin. |
| 4 | Wiz eBPF onboarding for op-usxpress-dev (top-3 crown jewels) | Doke + Steve Vives co-owned | INFRA-472 | M | Replaces Orca. Sensor model is per-host eBPF. Parallel to Phase 1. |
| 5 | Research + recommend etcd encryption-at-rest pattern (QA gate) | Doke | INFRA-472, label `qa-readiness` | L | Explicit QA-promotion gate. Covers EncryptionConfig, KMS provider, Vault-as-KMS, disk-level. Output is recommendation doc, not implementation. |
| 6 | Document EKS cloud-side etcd encryption posture (mirror target) | Doke | sub-task of #5 | S | Currently opaque since AWS abstracts the control plane. Consult cloud team. |
| 7 | Cross-cluster DR bootstrap design (SM source-of-truth chicken-and-egg) | Doke + Steve Vives | INFRA-472 | L | Forward-looking design; defer to post-Phase-1. |

## Existing tickets to update

- **INFRA-1493 (Phase 0, DONE)** — Closing comment: LE CA reaffirmed by Brendan + Vives in-call; wildcard cert validated end-to-end; no CySec objection.
- **INFRA-1494 (Phase 1)** — Comment: 2026-05-29 call cleared all open dependencies. Proceed. CAA / auto-rotation / Prometheus / Wiz / etcd-at-rest tracked as parallel new tickets, NOT Phase 1 gates.
- **INFRA-1492 (TCP/SNI umbrella)** — Comment linking new sub-tasks (#1, #2, #3 above) + summary of call outcomes.
- **INFRA-1497 (Phase 4 audit)** — Comment: scope expands to include CAA record audit + Wiz coverage audit + cert-rotation alert verification + etcd-at-rest verification (QA-onwards).
- **INFRA-472 (initiative umbrella)** — Comment summarizing call outcomes: LE confirmed, subzone ownership cleared, Wiz path opened, etcd-at-rest scoped as QA gate, AWS SM-as-source-of-truth locked in, hybrid-platform portability constraint formalized.
- **INFRA-1496 (Phase 3, NetworkPolicy + CIDR)** — No direct impact from call. NetworkPolicy + CIDR work stands as scoped.
- **INFRA-1500 / INFRA-1501** — No impact (Idris RW onprem PR #7 follow-ups, separate track).

## Follow-up coordination

| With | Channel | Ask |
|---|---|---|
| **Steve Duck** | Teams DM / standing chat | Confirm registrar console for usxpress.io (GoDaddy vs John Griffin umbrella). Gates CAA record + NS delegation formalization. |
| **John Quick Griffin** (via Duck) | Email / Duck-relay | Where is usxpress.io registered today? What CA standard does the org want long-term (LE only, LE + GoDaddy, other)? |
| **Brendan Buschel** | Teams chat | Security sign-off on enabling automated LE rotation in dev. Optional: weigh in on CA list for CAA record. Invite to review on-prem IaC repos before QA. |
| **Steve Vives** | Teams DM + calendar | (1) Receive top-3 crown-jewel host list for Wiz eBPF; schedule walking session. (2) Working session for cross-cluster DR bootstrap design (post-Phase 1). (3) Modern SELinux / disk-encryption alternatives input for etcd-at-rest research. (4) Confirm Wiz cert-expiry notification vs Prometheus dedup. |
| **Cloud platform team** | TBD (Slack/Teams) | Surface how EKS handles etcd secrets encryption today so on-prem can mirror the posture. Feeds the etcd-at-rest research. |

## Does this gate Phase 1 (INFRA-1494)?

**No.** Phase 1 is cleared to ship. The honest list of what does NOT gate Phase 1:

- CAA record (LE already issues fine without it; hardening only)
- LE auto-rotation (cert is freshly issued, ~88 days runway; manual works in dev short-term)
- Prometheus cert-expiry alerts (additive observability)
- Wiz eBPF onboarding (parallel security workstream)
- etcd encryption-at-rest (explicit deferral to QA-promotion gate)
- DR bootstrap / Vault discussion (forward-looking design)
- Hybrid-platform portability constraint (already aligned with current SM-based pattern)

**The only thing that would gate Phase 1 from this call is if CySec retracted LE approval or Duck reversed the subzone ownership OK.** Neither happened — both were affirmed.

## Notable quotes (handoff context)

- Brendan [0:01]: "Let's encrypt is fine... but if we are going to standardize, I think we want to talk to John."
- Steve Duck [2:09]: "John may have taken it over at some point recently. So let me check with John Quick Griffin... we won't have to argue anybody to take that."
- Steve Vives [5:16]: "Let's Encrypt lends itself to automation... that is the biggest workflow operational item that I've seen because it ends up backing up into the Mount Everest of expired certs."
- Doke [5:45]: "Maybe some trust issues, but if there's no security risk with automating that process, then I'm totally in favor of it."
- Steve Vives [10:59]: "If you have like maybe your top three crown jewels... I can drop a sensor on them and we can walk through it together."
- Steve Vives [12:40]: "It's an eBPF sensor... binds a preload bootloader which is eBPF and that runs on the kernel. So if it's running on the kernel, it has visibility into everything as long as it has access to the Internet."
- Steve Duck [16:14, 16:31]: "Part of Dare's long term vision is to make AWS platform and this on PREM platform hybrid to some degree... hybrid means a very, very specific definition because they will never just intermingle perfectly."
- Doke [17:25]: "About 90% of ensuring that we can move all those workloads into on PREM has already been solutioned. So there's a 10% which is really just picking different flavors of the 157 different applications that we have. I think we have about 10 to 12 unique flavors that needs to be tested. We've tested about two or three right now."
- Doke [22:47]: "How convenient would it be to move application workloads from cloud to on Prem if they are leveraging Secret Manager? That's the reason why we stuck to... make it easy for the lift and shift."
- Doke [23:30]: "It doesn't have to be solved in dev. Definitely not. But as we go into QA and we want to move into stages, we do have to have encryption for our ETCDs."
- Steve Vives [24:33]: "That sucks because then you got like the chicken and the egg. That's the recovery from one end to the other — secrets manager, everything exists here, like how does that work?"
- Steve Vives [25:47]: "I use test driven development... I want the outcome to be. But then I use, there's so many ways to get to that outcome... I would work backwards maybe twice, three times."

## Apply

- This document is the authoritative record of the 2026-05-29 networking/CySec call. Quote it when asked "what was decided."
- Phase 1 (INFRA-1494) is unblocked. Action items #1–#3 P0 are the Monday-morning queue.
- New Jira tickets above are RECOMMENDATIONS — pending user sign-off before filing.
