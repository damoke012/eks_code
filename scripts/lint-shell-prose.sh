#!/usr/bin/env bash
# Thin wrapper -- the logic is Python because it has to track quote/escape state.
# See wip/tooling/FINDINGS-2026-08-24-pr-body-executed.md for why this exists.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
exec python3 scripts/lint-shell-prose.py "$@"
