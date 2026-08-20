#!/usr/bin/env python3
"""Close the four Sprint 3 tickets finished on 2026-08-20 after the app path proof.

INFRA-1640, 1652 and 1653 are verified and close unconditionally.
INFRA-1622 closes only with --ui-verified, which you pass after seeing
`curl -sk https://argocd.op-qa.usxpress.io/` return 200 -- a merged
VirtualService and a green Flux Kustomization are exactly the evidence that
misled us on this ticket once already.

DRY-RUN BY DEFAULT. Pass --go to execute.
Auth:  read -rsp 'Atlassian API token: ' ATLASSIAN_TOKEN; export ATLASSIAN_TOKEN; echo
"""
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location(
    "closer", os.path.join(os.path.dirname(os.path.abspath(__file__)), "close-sprint3-tickets.py"))
m = importlib.util.module_from_spec(spec)
_argv = sys.argv[:]; sys.argv = ["x"]
spec.loader.exec_module(m)
sys.argv = _argv
m.GO = "--go" in sys.argv
UI_VERIFIED = "--ui-verified" in sys.argv

CLOSE = [
    ("INFRA-1640",
     "DONE on op-usxpress-qa 2026-08-20, merged as iaac-talos-flux-platform#100 and confirmed "
     "in-cluster after reconcile:\n\n"
     "  require-approved-registry      Enforce\n"
     "  require-image-digest           Enforce\n\n"
     "Both were validationFailureAction: Audit, so a workload violating either was admitted and "
     "the only trace was a PolicyReport nobody reads. They now reject at admission. The two "
     "unrelated policies on the cluster (auto-grafana-folder-label, mongo-atlas-envfrom-and-cert) "
     "are left on Audit deliberately -- neither is in this ticket's scope and both mutate rather "
     "than gate.\n\n"
     "Ordering mattered: this was flipped only after the delivery path was proven end to end "
     "(INFRA-1648), so the first workload to meet Enforce was already known to be digest-pinned "
     "and pulling from the approved registry."),

    ("INFRA-1652",
     "DONE 2026-08-20. risingwave-meta-default-0 was recreated and came back clean -- "
     "'recovery success' in the log and 0 restarts, against 238 before.\n\n"
     "Root cause, which is the part worth keeping: QA's Postgres password was rotated in Secrets "
     "Manager on 2026-08-12 13:35 UTC, but the database was initdb'd on 2026-08-11 19:20 UTC and "
     "POSTGRES_PASSWORD only applies at initdb -- the DB never learned the new value. That alone "
     "would have been caught in a day; what hid it for eight was the meta pod. A secretKeyRef "
     "env var resolves at POD creation, so the pod kept replaying the pre-rotation password "
     "through every one of its 238 container restarts and stayed connected. The ExternalSecret "
     "reported SecretSynced the whole time, because it was: the sync ran, the content just did "
     "not work anywhere.\n\n"
     "Fixed by ALTER USER to match Secrets Manager (not by rewriting the secret to match the DB "
     "-- the rotated value is the source of truth), then recreating the pod so its env picked up "
     "the current secret. Check added: scripts/check-postgres-secret-usable.sh compares the "
     "initdb timestamp against the secret's LastChangedDate and then actually authenticates over "
     "TCP, password on stdin."),

    ("INFRA-1653",
     "DONE 2026-08-20, two halves both merged and verified.\n\n"
     "ApplicationSet (iaac-talos-flux-platform#100), confirmed live on op-usxpress-qa:\n"
     "  retry: {\"backoff\":{\"duration\":\"30s\",\"maxDuration\":\"2m\"},\"limit\":1}\n"
     "Argo CD's default is unlimited retries with backoff, so a failing sync hook Job was "
     "recreated indefinitely and each attempt destroyed the previous one's logs.\n\n"
     "Sync hook (risingwave-pipeline#15): hook-delete-policy is now "
     "BeforeHookCreation,HookSucceeded. A failed hook Job now survives until the next deliberate "
     "sync, so its pod logs can be read. Previously HookSucceeded alone was not the problem -- "
     "the retry loop was -- but the pair is what makes a failure diagnosable.\n\n"
     "This ticket exists because six sequential value-mismatch failures on 2026-08-20 each cost "
     "a re-run to see the error at all."),
]

C1622 = (
    "INFRA-1622",
    "DONE on op-usxpress-qa 2026-08-20. Argo CD's UI is reachable at "
    "https://argocd.op-qa.usxpress.io/ through the shared Istio ingress.\n\n"
    "Shipped as a VirtualService on istio-ingress/shared-http routing to "
    "argocd-server.argocd.svc.cluster.local:80 -- port 80, not 443, because the chart runs with "
    "server.insecure: true and TLS terminates at the gateway. Merged as "
    "iaac-talos-flux-platform#99, then #101.\n\n"
    "#101 is the ticket's real lesson. After #99 the VirtualService existed, Flux reported the "
    "Kustomization Ready, and the hostname did not resolve at all -- curl returned 000 for "
    "another hour. external-dns derives a record's target from the ingress gateway's "
    "LoadBalancer address, and this gateway is ClusterIP with hostNetwork: true, so there is "
    "none. Every route on this cluster that works supplies the target by hand; the working "
    "risingwave-dashboard route carries "
    "external-dns.alpha.kubernetes.io/target: 10.10.82.106,10.10.82.139,10.10.82.23 and mine "
    "carried no annotations, because I copied the spec and left the metadata behind. #101 adds "
    "it. Documented in ONPREM-CICD.md so the next on-prem route starts with the annotation.\n\n"
    "Also corrected in passing: an earlier note on this cluster claimed QA had Istio ingress "
    "installed with nothing routing through it. That was wrong -- it came from querying the "
    "wrong API group for Gateways. QA's ingress works and always did.\n\n"
    "PROD IS NOT DONE: op-usxpress-prod has neither this route nor the Git credential."
)


def main():
    mode = "EXECUTING" if m.GO else "DRY RUN (pass --go)"
    print(f"== close-1622-1640-1652-1653  [{mode}]\n")
    m.preflight()

    todo = list(CLOSE)
    if UI_VERIFIED:
        todo.insert(0, C1622)
    else:
        print("INFRA-1622  SKIPPED -- pass --ui-verified once you have seen")
        print("            curl -sk https://argocd.op-qa.usxpress.io/  ->  200")
        print("            (a merged VirtualService is not the same claim)\n")

    for issue, comment in todo:
        print(issue)
        m.do_comment(issue, comment)
        m.do_close(issue)


if __name__ == "__main__":
    main()
