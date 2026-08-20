#!/usr/bin/env bash
# UserPromptSubmit hook — injects a catalog of EVERY installed skill so every prompt is
# evaluated against all of them, instead of relying on one description happening to match
# the user's phrasing. stdout on exit 0 is added to the turn's context.
#
# Scans live (user scope + the current project), so adding or renaming a skill needs no rebuild.
# Preview what it emits:  bash ~/.claude/skills-router/inject.sh
#
# v1 dropped unloadable skills SILENTLY (`if not m: continue`), so a SKILL.md with no YAML
# frontmatter vanished from the catalog and the whole set looked healthy. That is exactly how
# two skills in this repo were invisible. Broken skills are now REPORTED, not hidden.
set -uo pipefail

python3 - "${CLAUDE_PROJECT_DIR:-$PWD}" <<'PY'
import os, re, sys

project = sys.argv[1]
roots = [
    (os.path.expanduser("~/.claude/skills"), ""),
    (os.path.join(project, ".claude", "skills"), " [repo]"),
]
auto, manual, broken, seen = [], [], [], set()

for root, tag in roots:
    if not os.path.isdir(root):
        continue
    for name in sorted(os.listdir(root)):
        if name in seen or name.startswith("."):
            continue
        d = os.path.join(root, name)
        if not os.path.isdir(d):
            continue
        f = os.path.join(d, "SKILL.md")
        seen.add(name)
        if not os.path.isfile(f):
            broken.append((name + tag, "no SKILL.md"))
            continue
        try:
            head = open(f, encoding="utf-8", errors="replace").read(4000)
        except OSError as e:
            broken.append((name + tag, f"unreadable: {e.strerror}"))
            continue
        m = re.match(r"^---\n(.*?)\n---", head, re.S)
        if not m:
            broken.append((name + tag, "no YAML frontmatter — cannot be invoked"))
            continue
        fm = m.group(1)
        d_ = re.search(r"^description:\s*[\"']?(.+?)[\"']?\s*$", fm, re.M)
        if not d_:
            broken.append((name + tag, "frontmatter has no description"))
            continue
        desc = re.split(r"(?<=[.!?])\s", d_.group(1).strip())[0]
        if len(desc) > 110:
            desc = desc[:107].rstrip() + "..."
        (manual if "disable-model-invocation" in fm else auto).append((name + tag, desc))

if not auto and not manual and not broken:
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
if broken:
    print()
    print("BROKEN — present on disk but NOT loadable, so they cannot be invoked. "
          "Mention this to the user; do not silently work around it:")
    for n, why in broken:
        print(f"- {n}: {why}")
print("</skill-router>")
PY
exit 0
