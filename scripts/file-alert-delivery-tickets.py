#!/usr/bin/env python3
"""File the alerting findings from 2026-08-21, and re-scope INFRA-1642.

op-usxpress-dev has ~40 alert rules, 54 firing alerts, no Alertmanager, and a
flux-system that is never scraped. Three tickets in dependency order, plus a
comment on INFRA-1642 whose "alert on stale sources" half turns out to be
already written and permanently dead.

DRY-RUN BY DEFAULT. Pass --go.
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

EVIDENCE = (
    "Measured on op-usxpress-dev 2026-08-21 ~16:40 UTC. QA and prod NOT measured -- QA has a "
    "prometheus-rules Kustomization dev does not, so its result cannot be assumed, and prod was "
    "not reachable. Reproduce per cluster with scripts/check-alert-delivery.sh --context <ctx>.\n"
    "Full record: wip/observability/FINDINGS-2026-08-21-alerts-reach-nobody.md"
)

COMMENT = [
    ("INFRA-1642",
     "2026-08-21 -- the 'alert on stale sources' half of this ticket is already written, and it "
     "has never been able to fire.\n\n"
     "platform-alerts.yaml (INFRA-1503) ships FluxKustomizationFailed, FluxHelmReleaseFailed and "
     "FluxGitRepositoryFailed, all keyed on gotk_reconcile_condition. On op-dev:\n"
     "  gotk_reconcile_condition series:  0\n"
     "  flux-system scrape targets:       0\n"
     "Nothing scrapes flux-system -- there is no ServiceMonitor or PodMonitor for it on branch "
     "op-dev. A PrometheusRule whose expression selects a metric that is never ingested is valid, "
     "healthy, permanently 'inactive', and dead. kubectl shows it present, the Kustomization "
     "shipping it is Ready=True, and Prometheus reports no rule error, because an expression "
     "matching zero series is a perfectly good expression that returns nothing.\n\n"
     "Proof it matters: flux-system/risingwave and flux-system/wiz-sensor were Ready=False on "
     "op-dev for 2d18h (since 2026-08-18T22:02). The rule written for exactly that case did not "
     "fire. It was found by hand on 2026-08-21 with scripts/check-onprem-platform-state.sh.\n\n"
     "So this ticket's remaining content is NOT 'write an alert'. It is two things that are now "
     "separate tickets, because they are independent and neither is a config tweak: scrape "
     "flux-system, and deliver alerts at all (there is no Alertmanager).\n\n"
     "What stays here: the OTHER half -- the Flux Git token at source. That is still an open "
     "design question. ESO is itself reconciled by Flux, so sourcing Flux's own Git credential "
     "from an ExternalSecret is circular at bootstrap. Unchanged by today.\n\n"
     "scripts/check-flux-sources-current.sh remains the working answer for staleness in the "
     "meantime -- it compares each source's held revision against git ls-remote and does not "
     "depend on any metric.\n\n" + EVIDENCE),
]

CREATE = [
    {"summary": "Scrape flux-system, so the Flux alert rules can fire at all",
     "desc":
        "Every Flux alert rule on-prem is permanently inactive because the metric behind it is "
        "never ingested.\n\n"
        "On op-usxpress-dev: gotk_reconcile_condition -> 0 series, flux-system -> 0 scrape "
        "targets. `git ls-tree -r --name-only origin/op-dev | grep -i 'servicemonitor\\|podmonitor'` "
        "returns nothing. The Flux controllers expose these metrics on their metrics port; nothing "
        "asks for them.\n\n"
        "Consequence, observed: flux-system/risingwave and flux-system/wiz-sensor held "
        "Ready=False for 2 days 18 hours and FluxKustomizationFailed never fired.\n\n"
        "SCOPE: a PodMonitor (or ServiceMonitor) for the Flux controllers in flux-system, on all "
        "three branches -- op-dev, op-qa and op-prod. All three, not one; INFRA-1640 and "
        "INFRA-1641 were both closed after fixing a single cluster and had to be reopened.\n\n"
        "ACCEPTANCE: on each cluster, `scripts/check-alert-delivery.sh --context <ctx>` reports a "
        "non-zero series count for gotk_reconcile_condition and lists no Flux rule under 'cannot "
        "fire'. Verify by making a Kustomization fail deliberately on dev and watching the alert "
        "reach the 'firing' state in the Prometheus UI -- a rule that has never been seen to go "
        "red is not a rule anyone should trust.\n\n"
        "This is the smallest of the three alerting tickets and blocks nothing else, but without "
        "it the Flux rules stay dead however good the delivery path becomes.\n\n" + EVIDENCE,
     "labels": ["onprem", "observability", "flux"]},

    {"summary": "Triage the 54 alerts already firing on op-dev, before any of them are delivered",
     "desc":
        "54 alerts are firing on op-usxpress-dev right now. Nobody has seen them, because there "
        "is no Alertmanager. The moment delivery is switched on, all 54 arrive at once.\n\n"
        "An unreviewed backlog delivered on day one is how an alerting channel dies: the "
        "recipients learn in the first week that the channel is noise, and then the real alert "
        "in week three is ignored too. Triage has to happen BEFORE delivery, not after.\n\n"
        "Oldest firing, with activeAt:\n"
        "  ClusterDNSUnreachable                             2026-06-24  (2 months)\n"
        "  KubeControllerManagerDown                         2026-06-24  (2 months)\n"
        "  KubePodNotReady attrition/attrition-api-*         2026-06-24  (2 months)\n"
        "  KubeJobFailed ecr-credentials, kube-system, velero 2026-06-24  (2 months)\n"
        "  KubePodNotReady io-curt/io-notifications-handler  2026-07-28  (3 weeks)\n"
        "  KubePodNotReady wiz/wiz-sensor-*                  2026-07-21  (1 month)\n"
        "  CephClusterHealthWarn                             2026-08-17  (mon a low on disk)\n"
        "  KubePodCrashLooping risingwave-2/prometheus-server 2026-08-18\n"
        "  KubePersistentVolumeFillingUp risingwave-2        2026-08-18\n\n"
        "Three of these are worth calling out now:\n"
        "  KubeControllerManagerDown is very likely a Talos FALSE POSITIVE -- the control-plane "
        "components are static pods that kube-prometheus-stack's default scrape config does not "
        "reach. If so the rule needs correcting, not silencing.\n"
        "  attrition/ and io-curt/ pods have been NotReady since 2026-06-24. Someone's "
        "applications have been down on dev for two months and no one knew.\n"
        "  KubePersistentVolumeFillingUp on risingwave-2 fired at 2026-08-18T22:08:52 -- 76 "
        "seconds after the pod began crashing, naming the pod and the cause. It was correct, and "
        "it was rediscovered by hand two and a half days later.\n\n"
        "SCOPE: a decision per firing alert -- real and to be fixed, real and to be silenced with "
        "a recorded reason and an expiry, or a false positive whose rule is wrong and gets "
        "corrected. Repeat on QA and prod once measured.\n\n"
        "ACCEPTANCE: every alert firing on op-dev has an owner and a disposition, and "
        "`scripts/check-alert-delivery.sh --context admin@op-usxpress-dev` reports zero alerts "
        "firing longer than a week.\n\n" + EVIDENCE,
     "labels": ["onprem", "observability"]},

    {"summary": "Deliver on-prem alerts to somewhere a human looks -- there is no Alertmanager",
     "desc":
        "op-usxpress-dev evaluates roughly 40 platform alert rules correctly and can tell nobody "
        "about any of them.\n\n"
        "  kubectl -n prometheus get prometheus -o json | jq '.items[].spec.alerting'  ->  null\n"
        "  kubectl -n prometheus get pods | grep -c alertmanager                       ->  0\n\n"
        "infrastructure/prometheus/helmrelease.yaml on branch op-dev sets "
        "alertmanager.enabled: false in the kube-prometheus-stack values. A firing alert is "
        "visible only to someone who opens the Prometheus UI and clicks Alerts. That is not a "
        "gap in the rules -- platform-alerts.yaml, rook-ceph-health.yaml, etcd-cluster-health.yaml, "
        "etcd-snapshot-age.yaml, dns-health.yaml, irsa-health.yaml, istio-cert-chain.yaml, "
        "cilium-node-divergence.yaml and control-plane-memory.yaml are all well written, "
        "correctly labelled and correctly selected. The authoring was never the problem.\n\n"
        "This is a DESIGN decision, not a values change, which is why it is its own ticket:\n"
        "  - Where do alerts go? Teams, PagerDuty, email, or an existing cloud Alertmanager.\n"
        "  - Who is on the other end, and during which hours?\n"
        "  - What routes by severity? The rules already carry severity warning/critical and "
        "team: platform / track: storage, so the routing tree has something to key on.\n"
        "  - Does on-prem run its own Alertmanager per cluster, or forward to a shared one? "
        "Three clusters on an isolated vLAN argues for per-cluster with an external receiver.\n"
        "  - Inhibition rules, so one node failure does not produce forty pages.\n\n"
        "DEPENDS ON the triage ticket. Do not enable delivery while 54 alerts are outstanding.\n\n"
        "ACCEPTANCE: on each of the three clusters, `scripts/check-alert-delivery.sh` reports a "
        "configured .spec.alerting and a running alertmanager, AND a deliberately-triggered test "
        "alert is received by a human at the destination. The second half is the acceptance that "
        "matters -- a configured Alertmanager that nobody has received a message from is the same "
        "class of green-but-unproven signal that produced this ticket.\n\n" + EVIDENCE,
     "labels": ["onprem", "observability", "design"]},
]


def main():
    print(f"== file-alert-delivery-tickets  [{'EXECUTING' if m.GO else 'DRY RUN (pass --go)'}]\n")
    m.preflight()
    print("-- commenting, staying open --")
    for issue, body in COMMENT:
        print(issue); m.do_comment(issue, body)
    print("\n-- creating --")
    for s in CREATE:
        m.do_create(s)


if __name__ == "__main__":
    main()
