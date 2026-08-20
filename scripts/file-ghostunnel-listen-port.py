#!/usr/bin/env python3
"""File the ghostunnel-rw-postgres listen-port defect found 2026-08-20.

Two clusters, eleven weeks, invisible. Separate from INFRA-1645, which is done:
the ingress work is correct and rw-sql serves. This is a defect in
variant-inc/iaac-risingwave-onprem.

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

CREATE = [
    {"summary": "ghostunnel-rw-postgres listens on 4567, not 5432 -- rw-postgres has never "
                "served on op-dev or op-qa",
     "desc":
        "FOUND 2026-08-20 while verifying INFRA-1645 on op-usxpress-qa. INFRA-1645 itself is "
        "done and correct -- rw-sql.op-qa.usxpress.io completes a TLS handshake on all three "
        "gateway addresses and presents CN = rw-sql.op-qa.usxpress.io. rw-postgres fails on all "
        "three, and the fault is not in the ingress.\n\n"
        "THE DEFECT\n"
        "variant-inc/iaac-risingwave-onprem, both cluster paths:\n"
        "  manifests/op-usxpress-dev/ghostunnel-rw-postgres.yaml:93  --listen=:4567\n"
        "  manifests/op-usxpress-qa/ghostunnel-rw-postgres.yaml:69   --listen=:4567\n"
        "Both target pg-postgresql.risingwave.svc.cluster.local:5432, which is right. The "
        "listen port is a copy of the rw-sql tunnel's. The Service in front of it is "
        "port 5432 -> targetPort 5432, so nothing has ever been listening where the Service "
        "sends traffic.\n\n"
        "WHY IT SURVIVED\n"
        "The readiness probe is tcpSocket on port 'status' (9090), the ghostunnel status "
        "listener. It cannot observe the data port. Both pods report READY true with 0 "
        "restarts while serving nothing. This is the same shape as ExternalSecret SecretSynced "
        "and Argo CD Synced Healthy: a true statement about a step adjacent to the one that "
        "matters. It is why nine days on QA and eleven weeks on dev produced no signal.\n\n"
        "SCOPE\n"
        "op-usxpress-dev is affected too. rw-postgres.op-dev.usxpress.io resolves to dev's "
        "seven workers and has done since Phase 1 (INFRA-1494) closed 2026-06-01, so anyone "
        "who tried the dev Postgres endpoint in the last eleven weeks got a connection that "
        "went nowhere. Verified from the manifests, not from dev's live cluster -- confirm "
        "against dev before closing.\n\n"
        "FIX (per cluster path)\n"
        "  --listen=:4567  ->  --listen=:5432\n"
        "  readinessProbe.tcpSocket.port: status  ->  the data port\n"
        "The probe change is not optional. Without it the next copy of this manifest will also "
        "report Ready while dead, which is the entire reason this lasted.\n\n"
        "VERIFY\n"
        "  scripts/check-onprem-route.sh rw-postgres.op-qa.usxpress.io --tls-port 5432 \\\n"
        "      --kubeconfig ~/.kube/op-usxpress-qa-sso.yaml --context op-usxpress-qa-sso\n"
        "Expect a certificate subject from each gateway address. The same script covers dev "
        "with the dev hostname and context.\n\n"
        "Namespace risingwave, repo not owned by platform -- goes through the RW review path.",
     "labels": ["onprem", "risingwave", "networking"]},
]


def main():
    print(f"== file-ghostunnel-listen-port  [{'EXECUTING' if m.GO else 'DRY RUN (pass --go)'}]\n")
    m.preflight()
    for spec in CREATE:
        m.do_create(spec)


if __name__ == "__main__":
    main()
