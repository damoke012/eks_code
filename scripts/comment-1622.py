#!/usr/bin/env python3
"""INFRA-1622 stays open: record what is done and what the single remainder is.

DRY-RUN BY DEFAULT. Pass --go.  Auth: export ATLASSIAN_TOKEN=...
"""
import importlib.util, sys, os
spec = importlib.util.spec_from_file_location(
    "closer", os.path.join(os.path.dirname(os.path.abspath(__file__)), "close-sprint3-tickets.py"))
m = importlib.util.module_from_spec(spec)
_argv = sys.argv[:]; sys.argv = ["x"]
spec.loader.exec_module(m)
sys.argv = _argv
m.GO = "--go" in sys.argv

BODY = (
 "Status 2026-08-20 — staying open on ONE remainder: the Argo CD UI is not reachable.\n\n"
 "Verified on op-usxpress-qa today: no VirtualService and no Gateway exist in the argocd "
 "namespace, and argocd-server has been ClusterIP-only for 27 days. Nobody outside the "
 "cluster has ever been able to open Argo CD.\n\n"
 "Everything else this ticket covers is done: the chart is installed on op-usxpress-dev and "
 "op-usxpress-qa (chart 10.2.0 / Argo CD v3.4.5); the built-in permissive 'default' "
 "AppProject is neutered and an 'apps' project restricts destinations to app-* namespaces; "
 "the admin credential comes from Secrets Manager via ESO; an ApplicationSet generates one "
 "Application per app; and as of today Argo CD has delivered an application end to end "
 "(INFRA-1648) using a repository deploy key (INFRA-1647).\n\n"
 "The remaining work is an Istio VirtualService plus a Gateway binding for argocd-server. "
 "Note the HelmRelease sets server.insecure: true, so TLS terminates at the gateway rather "
 "than in argocd-server -- the route has to carry it.\n\n"
 "Ordering note for INFRA-1639 (Argo CD SSO for app teams, blocked on an Entra app "
 "registration): SSO is moot until this route exists. App teams cannot reach the UI to log in "
 "either way, so this ticket is the prerequisite, not the parallel work."
)

def main():
    print(f"== comment-1622  [{'EXECUTING' if m.GO else 'DRY RUN (pass --go)'}]\n")
    m.preflight()
    m.do_comment("INFRA-1622", BODY)

if __name__ == "__main__":
    main()
