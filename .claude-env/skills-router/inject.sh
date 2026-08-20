#!/usr/bin/env bash
# UserPromptSubmit hook — injects a catalog of EVERY installed skill so every prompt is
# evaluated against all of them, instead of relying on one description happening to match
# the user's phrasing. stdout on exit 0 is added to the turn's context.
#
# Scans live (user scope + the current project), so adding or renaming a skill needs no rebuild.
# Preview what it emits:  bash ~/.claude/skills-router/inject.sh
set -uo pipefail

python3 - "${CLAUDE_PROJECT_DIR:-$PWD}" <<'PY'
import os, re, sys

project = sys.argv[1]
roots = [
    (os.path.expanduser("~/.claude/skills"), ""),
    (os.path.join(project, ".claude", "skills"), " [repo]"),
]
auto, manual, seen = [], [], set()

for root, tag in roots:
    if not os.path.isdir(root):
        continue
    for name in sorted(os.listdir(root)):
        f = os.path.join(root, name, "SKILL.md")
        if not os.path.isfile(f) or name in seen:
            continue
        seen.add(name)
        m = re.match(r"^---\n(.*?)\n---", open(f).read(4000), re.S)
        if not m:
            continue
        fm = m.group(1)
        d = re.search(r"^description:\s*[\"']?(.+?)[\"']?\s*$", fm, re.M)
        desc = re.split(r"(?<=[.!?])\s", (d.group(1) if d else "").strip())[0]
        if len(desc) > 110:
            desc = desc[:107].rstrip() + "..."
        (manual if "disable-model-invocation" in fm else auto).append((name + tag, desc))

if not auto and not manual:
    sys.exit(0)

print("<skill-router>")
print(
    "Before answering, check this catalog and load every skill that fits the request (Skill tool). "
    "Several may apply; a skill beats improvising. If none fit, proceed normally and never mention "
    "the catalog."
)
print()
for n, d in auto:
    print(f"- {n}: {d}")
if manual:
    print()
    print("Type-only — you cannot invoke these; tell the user to type it: "
          + ", ".join(f"/{n.split(' ')[0]}" for n, _ in manual))
print("</skill-router>")
PY
exit 0
