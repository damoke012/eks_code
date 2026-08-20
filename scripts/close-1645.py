#!/usr/bin/env python3
"""Close INFRA-1645, verified on op-usxpress-qa 2026-08-20.

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

CLOSE = [
    ("INFRA-1645",
     "DONE on op-usxpress-qa 2026-08-20, merged as iaac-talos-flux-platform#102.\n\n"
     "The ticket's premise was right but incomplete. Three defects were stacked, each of which "
     "alone produces 'resolves but does not serve':\n\n"
     "1. Gateway `tcp-passthrough` was never ported to the op-qa branch, so both L4 "
     "VirtualServices had bound to nothing since the branch was created. Silent on both "
     "objects -- no error, no status condition, no event. It also cost the DNS records: "
     "external-dns's istio-virtualservice source resolves a VirtualService's gateways first and "
     "skips the whole object when one is missing, annotation or not.\n"
     "2. Both routes were verbatim dev copies -- they advertised the DEV hostnames against "
     "dev's seven worker addresses. Only the destinations were ever QA-correct, which is why "
     "nothing looked wrong from inside the cluster. Ninth instance of the copied-identifier "
     "class; check-foreign-cluster-ids.sh passes the new files as op-qa and flags them as "
     "op-prod.\n"
     "3. ghostunnel-rw-postgres listens on the wrong port -- INFRA-1654, a different repo, not "
     "reopened here.\n\n"
     "VERIFIED: rw-sql.op-qa.usxpress.io completes a TLS handshake on all three gateway "
     "addresses (10.10.82.23 / .106 / .139), presenting CN = rw-sql.op-qa.usxpress.io. "
     "Authoritative DNS and the local resolver agree. Gateway present, sniHosts matches, "
     "backend has two endpoints.\n\n"
     "ORDERING WAS A CORRECTNESS PROPERTY, NOT A PREFERENCE. Gateway and rename shipped in ONE "
     "PR deliberately. Adding the Gateway alone would have activated two routes still carrying "
     "dev hostnames, QA's external-dns (--policy=sync, zone-wide --domain-filter) would have "
     "adopted them, and the later rename would then have DELETED dev's live records. Confirmed "
     "after the merge: rw-sql.op-dev and rw-postgres.op-dev still return all seven dev workers.\n\n"
     "Ports 4567/5432 needed no other change -- allow-corp-vpn-to-ingressgateway already "
     "admitted both from the corp VPN pool and internal CIDRs only (INFRA-1496), and the "
     "ingress DaemonSet already bound both hostPorts.\n\n"
     "New check: scripts/check-onprem-route.sh --tls-port N verifies an L4 route link by link, "
     "including that the Gateway exists. Review record: wip/onprem-qa-ingress/"
     "pr-1645-review-2026-08-20.md."),
]


def main():
    print(f"== close-1645  [{'EXECUTING' if m.GO else 'DRY RUN (pass --go)'}]\n")
    m.preflight()
    for issue, comment in CLOSE:
        print(issue)
        m.do_comment(issue, comment)
        m.do_close(issue)


if __name__ == "__main__":
    main()
