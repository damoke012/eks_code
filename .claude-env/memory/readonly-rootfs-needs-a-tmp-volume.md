---
name: readonly-rootfs-needs-a-tmp-volume
description: readOnlyRootFilesystem with no emptyDir breaks anything calling mktemp; the ETL apply Job could not apply a single file for weeks
metadata:
  type: project
---

**`readOnlyRootFilesystem: true` with no volumes means the container cannot call
`mktemp`.** The ETL apply Job on op-usxpress-qa had exactly that, while `apply.sh` renders
every pipeline file to a temp file before applying it (the `%TOKEN%` substitution, and the
file it hashes into `pipeline_applied`):

    mktemp: Read-only file system

**No pipeline file could be applied on QA at all** — not Brand, not anything — from the
moment the render step was added until 2026-09-11. It stayed invisible because the only
prior run carried a smoke payload that never rendered.

Fix (#28), keeping the hardening: an `emptyDir` volume mounted at `/tmp`, plus
`TMPDIR=/tmp`. `readOnlyRootFilesystem`, `runAsNonRoot`, dropped capabilities and the
seccomp profile all stay.

**Why:** the manifest is correct, the security context is correct, the script is correct —
the defect exists only in their combination, so no diff review of any one of them finds
it.

**How to apply:** when a workload is hardened with a read-only root filesystem, grep the
image's entrypoint for `mktemp`, `>`, `tee`, cache directories or lock files, and give it
an `emptyDir`. And prove a delivery path with a payload that **depends on nothing** before
trusting it with a real one — see [[config-can-outrun-the-image]] and
[[adjacent-step-green-signals]].
