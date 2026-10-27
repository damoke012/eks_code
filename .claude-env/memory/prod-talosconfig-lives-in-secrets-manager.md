---
name: prod-talosconfig-lives-in-secrets-manager
description: "~/.talos/config on Doke's WSL does NOT carry op-prod's CA; talosctl fails the TLS handshake with an x509 'unknown authority (talos)' error that reads like a broken cluster. The authoritative prod talosconfig is in Secrets Manager at op-usxpress-prod/talosconfig."
metadata:
  type: reference
---

Measured 2026-10-26. `talosctl -n 10.10.82.187 list ...` against op-prod's control-plane
nodes returned, on all three:

    x509: certificate signed by unknown authority (possibly because of
    "x509: Ed25519 verification failure" while trying to verify candidate
    authority certificate "talos")

**This is not a prod fault and not an expired session.** The local `~/.talos/config`
simply is not prod's. The authoritative one lives in **Secrets Manager**,
`op-usxpress-prod/talosconfig` in account **937464026810**, region us-east-2, and
`scripts/breakglass-prod-kubeconfig.sh` is what fetches it. Pass both `-n` and `-e`.

**Why:** prod was torn down and rebuilt, which regenerates the Talos PKI, so any
talosconfig captured before that rebuild fails exactly this way. The error names a
certificate problem, so it reads as "the cluster is broken" rather than "you are holding
the wrong key" — the same shape as [[transport-failure-not-a-verdict]].

**How to apply:** never reach for `~/.talos/config` for prod. Use the break-glass script,
or `scripts/check-authenticator-webhook-file.sh` which fetches the secret itself and
guards it against the literal placeholder the secret once held. A green fetch is not a
usable value — see [[eso-secretsynced-not-content-check.md]]. And a Talos API refusal must
print NOT MEASURED, never ABSENT, or it becomes a finding about a file nobody read.

Related: [[prod-standup]], [[wsl-kubeconfig-churn]], [[onprem-prod-sso-is-half-landed]].
