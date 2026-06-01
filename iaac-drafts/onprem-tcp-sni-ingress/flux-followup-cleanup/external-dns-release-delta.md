# external-dns release.yaml delta — add `--default-targets`

File in upstream: `repos/iaac-talos-flux-platform/infrastructure/external-dns/release.yaml`

## What changes

In the `extraArgs:` block (currently 2 args), add **one** new arg `--default-targets` repeated 7 times — one per worker IP. external-dns parses each `--default-targets=<ip>` instance independently and unions the IPs into the A-record target list.

## Worker IPs (snapshot 2026-06-01)

Captured from the per-VS annotation we hand-applied during Phase 1:

```
10.10.82.21
10.10.82.22
10.10.82.26
10.10.82.27
10.10.82.28
10.10.82.178
10.10.82.180
```

**Re-verify on WSL before commit** — if the worker fleet changed since Phase 1, refresh:

```bash
kubectl get nodes -l '!node-role.kubernetes.io/control-plane' \
  -o jsonpath='{range .items[*]}{.status.addresses[?(@.type=="InternalIP")].address}{"\n"}{end}'
```

## Diff (paste-friendly)

```diff
     extraArgs:
       # Same target role cloud uses. Trust already permits any role named
       # `extd-usxpress-io-*` in the USXpress AWS Org — no patch needed.
       - --aws-assume-role=arn:aws:iam::155768531003:role/iaac-route53-zone
       - --dynamodb-region=us-east-2
+      # Default A-record targets for all istio-virtualservice sources where
+      # the parent Service is ClusterIP (no external-IP for external-dns to
+      # auto-derive). Re-verify list when the worker fleet changes.
+      - --default-targets=10.10.82.21
+      - --default-targets=10.10.82.22
+      - --default-targets=10.10.82.26
+      - --default-targets=10.10.82.27
+      - --default-targets=10.10.82.28
+      - --default-targets=10.10.82.178
+      - --default-targets=10.10.82.180
```

## After merge — drift cleanup on the live VS

After Flux reconciles external-dns with the new flags, remove the per-VS annotation so future drift comparisons don't flag it:

```bash
kubectl -n istio-ingress annotate virtualservice rw2-sql-passthrough \
  external-dns.alpha.kubernetes.io/target-
```

Then watch external-dns re-emit the A-record from the chart-level default-targets and confirm no flap in `getent hosts rw2-sql.op-dev.usxpress.io`.

## Pre-flight check

Before the PR, sanity-test that we don't have a Service-level external-dns annotation already supplying the targets (would be redundant but harmless; just want to know):

```bash
kubectl -n istio-ingress get svc istio-ingressgateway -o yaml \
  | grep -E "external-dns|annotations" | head
```

## Worth knowing

`--default-targets` is a top-level external-dns flag; it doesn't override per-resource target annotations (those win). So if anyone re-adds the per-VS annotation, that wins and the default is ignored. Pattern is forward-safe.
