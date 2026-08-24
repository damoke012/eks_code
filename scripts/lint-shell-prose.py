#!/usr/bin/env python3
"""Find prose that is about to be handed to a shell as a double-quoted string.

On 2026-08-24 scripts/pr-1661-apiserver-webhook.sh passed a PR body as
`gh pr create --body "..."`. The body's disclosure table used bare backticks, so
the shell command-substituted every cell: it executed octopus/bento-import.py and
octopus/apply-bootstrap-perms.sh (which calls `aws iam put-role-policy`), reaching
`aws sts get-caller-identity` before dying on absent credentials. gh then created
the PR anyway, with holes where the code spans had been, and exited 0.

Backticks and $( are NORMAL in a PR body -- every inline code span is one. So the
rule is not "escape them", it is "prose never transits a double-quoted shell
string". Use --body-file / -F with a file, or a <<'QUOTED' heredoc.

    python3 scripts/lint-shell-prose.py            # scan scripts/
    python3 scripts/lint-shell-prose.py path.sh    # scan specific files
"""
import pathlib
import re
import sys

# Flags whose value is human prose about code, and therefore full of backticks.
PROSE_FLAGS = re.compile(
    r"(--body|--description|--comment|--notes|--message|--title|-m|-F)\s+\"")
SAFE_FLAG = re.compile(r"--(body|notes)-file\b|--body-file\b")


def scan(text):
    """Yield (offset, flag, bad_token) for each risky double-quoted prose arg."""
    for m in PROSE_FLAGS.finditer(text):
        if SAFE_FLAG.search(text[max(0, m.start() - 4):m.end()]):
            continue
        i = m.end()                      # first char inside the opening quote
        while i < len(text):
            c = text[i]
            if c == "\\":
                i += 2
                continue
            if c == '"':
                break                    # closing quote: argument ended
            if c == "`":
                yield m.start(), m.group(1), "bare backtick"
                break
            if c == "$" and i + 1 < len(text) and text[i + 1] == "(":
                yield m.start(), m.group(1), "$( command substitution"
                break
            i += 1


def main(argv):
    targets = [pathlib.Path(a) for a in argv[1:]] or sorted(
        p for p in pathlib.Path("scripts").glob("*.sh"))
    bad = 0
    for path in targets:
        try:
            text = path.read_text()
        except (OSError, UnicodeDecodeError):
            continue
        for off, flag, why in scan(text):
            line = text.count("\n", 0, off) + 1
            print(f"{path}:{line}: {flag} \"...\" contains a {why}")
            bad += 1
    if bad:
        print()
        print(f"!! {bad} prose argument(s) will be evaluated by the shell.")
        print("   Write the text to a file and pass --body-file, or use <<'QUOTED'.")
        print("   See wip/tooling/FINDINGS-2026-08-24-pr-body-executed.md")
        return 1
    print(f"prose-in-shell-strings: clean ({len(targets)} file(s))")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
