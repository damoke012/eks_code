#!/usr/bin/env python3
"""Record the INFRA-1642 findings. Comments only -- does NOT close.

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

BODY = (
 "Investigated on op-usxpress-qa 2026-08-20. NOT closing -- half of this is now answered and "
 "half is a design decision.\n\n"
 "STALE SOURCES: nothing is stale right now, and the way to know is new.\n"
 "  flux-system            master  48dfa1754df2  current\n"
 "  gateway-api-upstream   v1.4.0  5e5891a5adad  current\n"
 "  iaac-risingwave-onprem main    91a0ee28e28e  current\n"
 "  infra                  op-qa   f335b1f14d50  current\n\n"
 "flux-system last changed revision on 2026-08-18 and I nearly read that as stale. It is not: "
 "`.status.artifact.lastUpdateTime` is the last time the REVISION CHANGED, not the last "
 "successful fetch, so a correctly-pinned tag and a source that stopped fetching look "
 "identical. gateway-api-upstream sitting at 2026-07-07 is a pinned tag behaving correctly.\n\n"
 "The only test that settles it is comparing the held commit against the remote ref: "
 "scripts/check-flux-sources-current.sh --context <ctx>. Exit 0 all current, 1 something "
 "behind, 2 could not be checked -- 2 is distinct deliberately, because a source it could not "
 "reach must not read as a pass.\n\n"
 "TO TURN DETECTION INTO ALERTING: Flux exposes no 'behind remote' metric, so this needs "
 "either a PrometheusRule on gotk_reconcile_condition{type=\"Ready\",status=\"False\"} (catches "
 "a source that fails outright, not one silently behind) or a small exporter running the "
 "comparison above. Scoped but not yet built.\n\n"
 "THE TOKEN AT SOURCE -- and the reason I did not just fix it. flux-system holds a hand-made "
 "Opaque secret; there is NO ExternalSecret in the flux-system namespace (verified, not "
 "inferred from an error). It is the only credential on this cluster not coming from Secrets "
 "Manager.\n\n"
 "The obvious fix is an ExternalSecret, and it is circular: External Secrets Operator is "
 "reconciled BY Flux from this very repository. If ESO breaks, Flux cannot fetch the manifests "
 "that would repair ESO, and the cluster has no way back without manual intervention. The "
 "standard answer is that a bootstrap credential stays out-of-band and gets rotation plus "
 "EXPIRY ALERTING rather than ESO management -- which changes this ticket from 'move the token' "
 "to 'decide where the bootstrap trust anchor lives, then alert on it'.\n\n"
 "Worth deciding explicitly before implementing either way. Related: the same question will "
 "apply to op-usxpress-prod, which has no Git credential at all yet (INFRA-1650)."
)

def main():
    print(f"== comment-1642  [{'EXECUTING' if m.GO else 'DRY RUN (pass --go)'}]\n")
    m.preflight()
    print("INFRA-1642")
    m.do_comment("INFRA-1642", BODY)
    print("\n(deliberately not transitioned -- the token half is undecided)")

if __name__ == "__main__":
    main()
