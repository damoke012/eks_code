# eks_code

The operator's working repo for the USX cloud + on-prem platform. See `CLAUDE.md` for the rules.

## Meeting Copilot

A live meeting assistant that runs in this Codespace (setup and design: `meeting-copilot/skill/SKILL.md`).

- Start: `meeting-copilot/up.sh`, then open the printed URL in Chrome on the laptop running the meeting.
- Stop: `meeting-copilot/down.sh`. Wait a few seconds before running `up.sh` again.
- After a meeting, tell Claude: "process the last meeting".
- It answers live questions from `meeting-brief.md`, so keep that file current.
