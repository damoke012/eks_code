---
name: mic-echo-doubles-the-transcript
description: "Without headphones the Meeting Copilot transcribes every line twice -- once as Them, then ~3s later under the user's own name -- so the transcript attributes other people's words, including their sign-off, to Doke"
metadata:
  type: feedback
---

**Measured on `meeting_2026-10-26_1833`:** 151 lines attributed to **Dare**, 106 to **Them**,
and roughly **63 of the Dare lines were echo** — the meeting audio coming back through the mic
about three seconds late. Tim's words appeared under Doke's name, including Tim's own closing
"appreciate y'all".

**Why it matters:** anyone reading the transcript raw mis-attributes decisions, and the
answerer does double work on every sentence.

**How to apply.** The copilot now drops a mic line that repeats a recent meeting line
(`is_echo_of_meeting` in `meeting-copilot/server.py`, `ECHO_RATIO=0.60`, `ECHO_WINDOW_S=12`).
The threshold was chosen by replaying that transcript: 0.80 caught 53, 0.70 caught 57, 0.60
caught 63, 0.55 added one more — and every line 0.60 caught that 0.80 missed was read and
confirmed to be echo. Headphones still beat the filter; the filter is for when they are not on.

**Every transcript before 2026-10-26 carries this flaw.** When reading an older one, treat a
Dare line that repeats a Them line within a few seconds as the other person speaking.

Also: mis-transcriptions to expect — Kiwi/QWave/QM Prod = QA and prod, eBeaver/DBV = DBeaver,
awgs = orgs. The glossary holds technical terms only; **never put people's names in it**, they
make Whisper hallucinate them.

Related: [[dokes-own-voice-is-plain]], [[transport-failure-not-a-verdict]].
