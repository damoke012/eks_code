#!/usr/bin/env bash
# postCreateCommand — rebuild everything that lives OUTSIDE the repo.
# In a codespace only /workspaces survives a rebuild. Skills, the router and the MEMORY
# DIRECTORY live in container home and are destroyed by one. Memory is the half you
# cannot reinstall, which is why it is backed up into the repo.
set -uo pipefail
cd "$(dirname "$0")/.."
echo "== restoring claude env"
bash scripts/claude-env-restore.sh
echo "== done"
