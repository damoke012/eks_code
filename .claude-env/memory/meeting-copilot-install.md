---
name: meeting-copilot-install
description: "Meeting Copilot v2.2 installed in this codespace 2026-10-26 — claude CLI is a symlink to the VS Code extension binary, down.sh→up.sh races, Mic label by design"
metadata:
  node_type: memory
  type: project
  originSessionId: 85a57e2a-2bd3-4ab8-9134-120c829e6c0c
  modified: 2026-10-26T13:19:05.609Z
---

Meeting Copilot v2.2 (from "MEETING COPILOT SETUP v2.pdf") was installed and tested in the eks_code codespace on 2026-10-26. It lives in `meeting-copilot/`, and its config and transcripts are in `.meeting-copilot/` (gitignored). Nothing has been committed yet.

**Traps found during install:**
- The codespace had no `claude` on PATH. `~/.local/bin/claude` is a symlink to `~/.vscode-remote/extensions/anthropic.claude-code-2.1.310-linux-x64/resources/native-binary/claude`. **It breaks when the extension updates** (the path is versioned). If the fast path shows "No such file", re-point the symlink.
- `down.sh` then `up.sh` back to back leaves NOTHING running. down.sh returns before uvicorn exits, up.sh sees health 200 and says "already running", then the old server dies. Wait for the port to free up between the two.
- The Step 7 speaker test predates v2.2. If the meeting (`them`) socket is not connected, or has never carried speech, the mic line is labelled **Mic**, not Dare. It shows **Dare** only while a meeting stream with speech stays connected.
- The 4-core box means REFINE_MODEL=off (no large-v3-turbo second pass).
- SKILL.md step 5 names `.claude/skills/central-hudson-obs/SKILL.md`, a skill from another project that does not exist here. Steps 4 and 6 name `notes/gaps/` and `notes/decisions/`, which do not exist either.

**Why:** these took real time to diagnose, and each one looks like a broken install.
**How to apply:** for "start the meeting copilot", check `claude --version` first. Restart with down, wait, then up.
