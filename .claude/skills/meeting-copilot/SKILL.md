---
name: meeting-copilot
description: Start, stop, check, or tune the live Meeting Copilot for this project, and process a finished meeting into repo knowledge (meeting note, brief, gaps, decisions, project skill, memory). Use when the user mentions a meeting, the meeting copilot, starting/stopping the listener, the brief, a transcript, or says "process the last meeting".
---

# Meeting Copilot

A live meeting assistant installed in this repo. It is served from `meeting-copilot/`, and its settings and data live in `.meeting-copilot/`.

## Start before a meeting
Run `meeting-copilot/up.sh`, then give the user the URL it prints. The user opens it in Chrome, leaves **+ my mic (Dare)** ticked (headphones recommended), and clicks **Capture meeting tab** (or **Capture input** for desktop apps with BlackHole / VB-Cable).

Before starting, check that `meeting-brief.md` reflects the latest status. If it is more than a few days old, offer to refresh it first.

## How it tells voices apart
By **source**, not by voiceprint. The meeting tab and the user's mic go to the server as separate streams (`/ws/audio?src=them` / `?src=me`). Mic lines are labelled **Dare** (`MY_LABEL`), meeting lines **Them**. Only **Them** lines can trigger answers. With speakers instead of headphones, other people can leak into the mic; Chrome's echo cancellation removes most of it.

## On an answer card
- **Dig deeper** — full repo lookup (read-only).
- **Refine** — re-answer using context the user types (e.g. "RHEL 8.6, Windows Server 2016").
- **Research** — repo + web (WebSearch/WebFetch), up to 4 min, cites sources. The card shows "⚠ Needs research" when the deep answer ends with `RESEARCH_NEEDED:`.

## Stop
Run `meeting-copilot/down.sh`.

## Check status or debug
- `curl -s localhost:8765/api/health`
- `tail -50 .meeting-copilot/server.log` (lines read `stt [them|me] Xs audio -> Ys: text`)

Common fixes:
- Slow transcription → set `WHISPER_MODEL=base.en` in `.meeting-copilot/config.env`, then restart.
- No answers → check `DETECT_MODE` (the user prefers `all`) in the same file, and the page dropdown.
- Fast path errors → run `claude update`.
- Invented names in the transcript → the glossary has people's names in it. It must hold technical terms only.

## After a meeting: "process the last meeting"
This is the learning loop. Run every step, in order, and follow CLAUDE.md house style.

1. **Read** the newest file in `.meeting-copilot/transcripts/`. Lines are `**Dare:**` (the user) and `**Them:**` (everyone else). Attribute by content where "Them" covers several people; transcripts mishear names (the user is often written as Derek/Darek/Daray/There).
2. **Meeting note** → `meetings/YYYY-MM-DD-<short-topic>.md`: analysis on top (decisions, action items with owners, open questions, anything that contradicts the repo), then the verbatim transcript below. Ask the user for the meeting name/attendees if not clear.
3. **Brief** → update `meeting-brief.md`: status, numbers, decisions, owners, dates, risks. Add answers for every question that hit `NEED_LOOKUP`, a deep, refine or research answer, so they're instant next time. Under 1,500 words (the fast path reads 12,000 chars). Remove stale lines. Never invent facts; write "unknown — confirm".
4. **Gaps / decisions** → `notes/gaps/README.md` for gaps opened or closed; `notes/decisions/` for decisions, with what was rejected and why.
5. **Project skill** → update `.claude/skills/central-hudson-obs/SKILL.md` if anything changes how we work.
6. **Memory** → write or update a memory file for durable facts (people, constraints, decisions), and add its line to MEMORY.md.
7. **Glossary** → add new technical terms/acronyms to `.meeting-copilot/glossary.txt`. Never people's names (they make Whisper hallucinate them).
8. **Report** to the user: decisions, action items with owners, open questions, and the list of files changed. Do not commit unless asked.

## Rules
- Never make port 8765 Public.
- Never commit `.meeting-copilot/`; it holds raw transcripts. The curated copy goes into `meetings/`.
- Check the meeting is allowed to be recorded (InfoSec / participants) before treating its transcript as repo content.
- The fast path answers only from `meeting-brief.md`, so keeping it accurate is the main job.
