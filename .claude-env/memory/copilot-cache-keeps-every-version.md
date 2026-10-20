---
name: copilot-cache-keeps-every-version
description: The codespace low-disk warning is ~/.cache/copilot keeping every CLI version ever downloaded (27 = 4.8G of 20G); prune with scripts/prune-codespace-cache.sh
metadata:
  type: project
---

When the eks_code codespace raises a low-disk warning, the cause is
**`~/.cache/copilot/pkg/linux-x64`**, which holds every GitHub Copilot CLI version ever
downloaded. Measured 2026-10-16 at 90% full: 27 versions (1.0.67 … 1.0.98) at ~180M each =
**4.8G, 28% of everything used**, while the repo itself was 74M. `copilot update` adds a
version and never removes the one it superseded, so it refills at roughly **1.6G/month**.

Pruning to the two newest freed 4.4G (90% → 67%).

**Why:** the instinct is to look in the repo or the git objects. Both are trivial here —
`/workspaces` is 74M of a 20G volume. The disk is consumed by the container's tool caches
under `/home/codespace`, which `du -xhd1 /` makes visible in one command.

**How to apply:**
- `bash scripts/prune-codespace-cache.sh` reports, `--apply` deletes. Tested both directions
  by `scripts/prune-codespace-cache.test.sh`; weekly-maintenance section 13 reports it and
  raises a finding at ≥80%.
- The cache is update **staging**, not running code: `/usr/local/bin/copilot` is a standalone
  ELF binary, the live VS Code process runs `@github/copilot-sdk-linux-x64` from `/vscode/bin`,
  and `lsof +D` shows no open handles under `pkg/`. Verify those three before deleting.
- **Sort these by version, never by mtime** — the archives carry a fixed `1985-10-26` build
  timestamp, so the oldest and newest look identical to `ls -t`. Lexical sort is also wrong
  (`1.0.9` vs `1.0.10`); use `sort -V`.
- `/tmp` is a separate 118G volume with ~109G free, so large scratch work belongs there, not
  under `/home` or `/workspaces`. Related: [[policy-cannot-fix-what-stops-it-running]].
