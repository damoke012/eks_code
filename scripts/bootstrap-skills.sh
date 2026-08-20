#!/usr/bin/env bash
# SELF-CONTAINED bootstrap for mattpocock/skills + the five fixes that make them fire.
#
# Needs only: bash, git, python3, and network access to github.com. The files that cannot be
# fetched from upstream are embedded below, in full, readable. Read them before you run this;
# that is the point of shipping it this way.
#
#   bash scripts/bootstrap-skills.sh            install
#   bash scripts/bootstrap-skills.sh --force    reinstall over an existing set
#   bash scripts/bootstrap-skills.sh --dry-run  print what it would do, touch nothing
#
# WHAT IT WRITES — all under ~/.claude, nothing in this repo:
#   ~/.claude/skills/*                    28 skill directories
#   ~/.claude/skills-router/inject.sh     the router hook
#   ~/.claude/settings.json               appends a UserPromptSubmit hook (other keys preserved)
#
# Lives in the repo rather than a scratch dir because /tmp does not survive a session boundary
# and this file has already evaporated three times.
set -uo pipefail

PIN="0ab1b63a"   # bumped 2026-08-20 after diffing 885e2ca4..0ab1b63a: 2 commits, grilling formatting only
SKILLS="$HOME/.claude/skills"
ROUTER="$HOME/.claude/skills-router"
MODE="${1:-}"

say() { printf '\n== %s\n' "$1"; }

if [ "$MODE" = "--dry-run" ]; then
  echo "DRY RUN — would install 25 upstream skills at pin $PIN, apply 5 deltas,"
  echo "write $SKILLS, $ROUTER/inject.sh, and append a UserPromptSubmit hook to ~/.claude/settings.json."
  echo "Nothing in your repository is touched."
  exit 0
fi

for bin in git python3; do
  command -v "$bin" >/dev/null 2>&1 || { echo "ERROR: $bin is required"; exit 1; }
done

# ---------------------------------------------------------------- upstream + deltas
say "mattpocock/skills"
if [ -f "$SKILLS/.mattpocock-skills.install.json" ] && [ -d "$SKILLS/mp-code-review" ] && [ "$MODE" != "--force" ]; then
  echo "  already installed with deltas applied — skipping (pass --force to reinstall)"
else
  TMP="$(mktemp -d)"
  if git clone -q https://github.com/mattpocock/skills.git "$TMP/skills" 2>/dev/null \
     && git -C "$TMP/skills" checkout -q "$PIN" 2>/dev/null; then
    mkdir -p "$SKILLS"
    python3 - "$TMP/skills" "$SKILLS" <<'PY_COPY'
import json, os, shutil, sys
src, dest = sys.argv[1], sys.argv[2]
man = json.load(open(os.path.join(src, ".claude-plugin/plugin.json")))["skills"]
for rel in man:
    s = os.path.normpath(os.path.join(src, rel))
    d = os.path.join(dest, os.path.basename(s))
    if os.path.exists(d):
        shutil.rmtree(d)
    shutil.copytree(s, d)
print(f"  installed {len(man)} upstream skills")
PY_COPY

    # DELTA 1 — keep /code-review pointing at Claude Code's built-in review
    if [ -d "$SKILLS/code-review" ]; then
      rm -rf "$SKILLS/mp-code-review"; mv "$SKILLS/code-review" "$SKILLS/mp-code-review"
      sed -i 's/^name: code-review$/name: mp-code-review/' "$SKILLS/mp-code-review/SKILL.md"
      sed -i 's|/code-review|/mp-code-review|g; s|`code-review` skill|`mp-code-review` skill|g' \
        "$SKILLS/ask-matt/SKILL.md" "$SKILLS/tdd/SKILL.md" "$SKILLS/implement/SKILL.md"
      echo "  delta 1: code-review -> mp-code-review (+3 cross-refs)"
    fi

    # DELTA 5 — upstream ships these as slash-command-only; let the workflow ones fire unprompted.
    # Verified against 0ab1b63a: all twelve still carry disable-model-invocation upstream, and
    # setup-matt-pocock-skills / wait-what are correctly left alone.
    for s in ask-matt grill-with-docs improve-codebase-architecture to-spec triage wayfinder \
             grill-me handoff implement teach to-questionnaire to-tickets; do
      [ -f "$SKILLS/$s/SKILL.md" ] &&
        sed -i '/^disable-model-invocation:[[:space:]]*true[[:space:]]*$/d' "$SKILLS/$s/SKILL.md"
    done
    echo "  delta 5: 12 workflow skills made auto-invocable"

    cat > "$SKILLS/.mattpocock-skills.install.json" <<EOF_MANIFEST
{
  "source": "https://github.com/mattpocock/skills",
  "method": "scripts/bootstrap-skills.sh (self-contained)",
  "commit": "$PIN",
  "local_deltas": 5
}
EOF_MANIFEST
  else
    echo "  ERROR: clone failed (no network?) — skills NOT installed."
    rm -rf "$TMP"
    exit 1
  fi
  rm -rf "$TMP"
fi

# ---------------------------------------------------------------- embedded files
say "embedded files"
mkdir -p "$SKILLS/caveman" "$SKILLS/diagnose" "$SKILLS/to-issues" "$ROUTER"

cat > "$SKILLS/caveman/SKILL.md" <<'CAVEMAN_SKILL'
---
name: caveman
description: Ultra-compressed communication mode — cuts token usage ~75% by dropping filler, articles, and pleasantries while keeping full technical accuracy.
disable-model-invocation: true
---

Respond terse like smart caveman. All technical substance stay. Only fluff die.

## Persistence

ACTIVE EVERY RESPONSE once triggered. No revert after many turns. No filler drift. Still active if unsure. Off only when user says "stop caveman" or "normal mode".

## Rules

Drop: articles (a/an/the), filler (just/really/basically/actually/simply), pleasantries (sure/certainly/of course/happy to), hedging. Fragments OK. Short synonyms (big not extensive, fix not "implement a solution for"). Abbreviate common terms (DB/auth/config/req/res/fn/impl). Strip conjunctions. Use arrows for causality (X -> Y). One word when one word enough.

Technical terms stay exact. Code blocks unchanged. Errors quoted exact.

Pattern: `[thing] [action] [reason]. [next step].`

Not: "Sure! I'd be happy to help you with that. The issue you're experiencing is likely caused by..."
Yes: "Bug in auth middleware. Token expiry check use `<` not `<=`. Fix:"

### Examples

**"Why React component re-render?"**

> Inline obj prop -> new ref -> re-render. `useMemo`.

**"Explain database connection pooling."**

> Pool = reuse DB conn. Skip handshake -> fast under load.

## Auto-Clarity Exception

Drop caveman temporarily for: security warnings, irreversible action confirmations, multi-step sequences where fragment order risks misread, user asks to clarify or repeats question. Resume caveman after clear part done.

Example -- destructive op:

> **Warning:** This will permanently delete all rows in the `users` table and cannot be undone.
>
> ```sql
> DROP TABLE users;
> ```
>
> Caveman resume. Verify backup exist first.
CAVEMAN_SKILL

cat > "$SKILLS/diagnose/SKILL.md" <<'DIAGNOSE_SKILL'
---
name: diagnose
description: Alias for the renamed `diagnosing-bugs` skill. Use when the user types /diagnose, or asks to diagnose a bug, a crashloop, a failing pipeline, or a performance regression.
disable-model-invocation: true
---

# /diagnose → `diagnosing-bugs`

Upstream renamed this skill: `caveman`-era `diagnose` became **`diagnosing-bugs`**
(mattpocock/skills commit `47bde84`). The old name is kept here so `/diagnose` never fails.

**Do this now:** invoke the **`diagnosing-bugs`** skill and follow it exactly. Everything you need is
there — this file holds no procedure of its own.
DIAGNOSE_SKILL

cat > "$SKILLS/to-issues/SKILL.md" <<'TOISSUES_SKILL'
---
name: to-issues
description: Alias for the merged `to-tickets` skill. Use when the user types /to-issues, or asks to turn a plan, spec, design or the current conversation into issues/tickets in the project's issue tracker.
disable-model-invocation: true
---

# /to-issues → `to-tickets`

Upstream merged `to-plan` and `to-issues` into a single **`to-tickets`** skill and deleted `to-issues`
(mattpocock/skills PR #464, commit `386d4ff`). The old name is kept here so `/to-issues` never fails.

**Do this now:** invoke the **`to-tickets`** skill and follow it exactly. It cuts tracer-bullet vertical
slices with explicit blocking edges, and writes them to whichever tracker
`/setup-matt-pocock-skills` configured. This file holds no procedure of its own.
TOISSUES_SKILL

# Router is written from the live copy at build time — see scripts/sync-router.sh
cat > "$ROUTER/inject.sh" <<'ROUTER_INJECT'
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
ROUTER_INJECT

chmod +x "$ROUTER/inject.sh"
echo "  caveman (upstream-deleted, recovered from history) + diagnose/to-issues aliases + router"

# ---------------------------------------------------------------- register the router hook
say "router hook"
python3 - "$HOME/.claude/settings.json" <<'PY_HOOK'
import json, os, sys
p = sys.argv[1]
os.makedirs(os.path.dirname(p), exist_ok=True)
d = json.load(open(p)) if os.path.exists(p) else {}
cmd = "bash %s/.claude/skills-router/inject.sh" % os.path.expanduser("~")
# APPEND, never replace: a bare assignment silently destroys any pre-existing
# UserPromptSubmit hook. Idempotent — re-running does not duplicate the entry.
entries = d.setdefault("hooks", {}).setdefault("UserPromptSubmit", [])
already = any(h.get("command") == cmd for e in entries for h in e.get("hooks", []))
if not already:
    entries.append({"hooks": [{"type": "command", "command": cmd}]})
json.dump(d, open(p, "w"), indent=2); open(p, "a").write("\n")
print("  UserPromptSubmit hook registered in", p)
PY_HOOK

# ---------------------------------------------------------------- report
say "result"
total=$(ls -d "$SKILLS"/*/ 2>/dev/null | wc -l)
auto=$(for d in "$SKILLS"/*/; do grep -q 'disable-model-invocation' "$d/SKILL.md" 2>/dev/null || echo x; done | wc -l)
echo "  $total skills, $auto auto-invocable, $((total-auto)) type-only (/caveman /diagnose /setup-matt-pocock-skills /to-issues /wait-what)"
echo "  preview the router:  bash ~/.claude/skills-router/inject.sh"
