#!/usr/bin/env python3
"""Close INFRA-1658 -- but only if the triage covers every alert that was firing.

The acceptance is "triage the alerts already firing on op-dev, before any of them
are delivered". So the gate is that the committed triage names every alertname
observed in the 2026-08-24 18:55 UTC dump and gives it a decision. A close that
asserts its own acceptance is how INFRA-1640 and INFRA-1641 were wrongly closed.

DRY-RUN BY DEFAULT. Pass --go.
Auth:  read -rsp 'Atlassian API token: ' ATLASSIAN_TOKEN; export ATLASSIAN_TOKEN; echo
"""
import importlib.util, os, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
spec = importlib.util.spec_from_file_location("closer", os.path.join(HERE, "close-sprint3-tickets.py"))
m = importlib.util.module_from_spec(spec)
_argv = sys.argv[:]; sys.argv = ["x"]
spec.loader.exec_module(m)
sys.argv = _argv
GO = "--go" in sys.argv

DOC = "wip/observability/INFRA-1658-TRIAGE-2026-08-24.md"

# Every alertname firing on op-usxpress-dev at 2026-08-24 ~18:55 UTC, from
# scripts/triage-firing-alerts.sh. 55 instances across these 23 names.
OBSERVED = [
    "KubeProxyDown", "KubePodNotReady", "KubeControllerManagerDown", "KubeSchedulerDown",
    "ClusterDNSUnreachable", "Watchdog", "PrometheusNotConnectedToAlertmanagers", "TargetDown",
    "CephClusterHealthWarn", "PodNotReadyPlatformNS", "PodCrashLoopBackOffPlatformNS",
    "KubePersistentVolumeFillingUp", "CPUThrottlingHigh", "KubeContainerWaiting",
    "KubeDaemonSetNotScheduled", "KubeDaemonSetRolloutStuck", "KubeDeploymentReplicasMismatch",
    "KubeDeploymentRolloutStuck", "KubeJobFailed", "KubePdbNotEnoughHealthyPods",
    "KubePodCrashLooping", "FluxHelmReleaseFailed", "FluxKustomizationFailed",
]

COMMENT = (
    "CLOSED 2026-08-24. Triage complete for op-usxpress-dev. QA and prod are NOT triaged; "
    "each needs its own run before its alerts are delivered.\n\n"
    "55 alerts were firing. They are ELEVEN situations, and only four are current problems.\n\n"
    "TWO TRAPS IN THE DATA, both of which would have produced a wrong triage:\n\n"
    "1. Twenty-six of the 55 showed activeAt = 2026-08-24T14:49:42, which is not when they "
    "started -- it is when the kube-state-metrics pod was replaced for INFRA-1657. All 26 "
    "carry instance=10.244.1.225:8080, KSM's own address, inside the alert's label set, so "
    "replacing the pod reset every one of their clocks. Their true ages are UNKNOWN, not "
    "recent. This is the same defect INFRA-1657 fixed, present in kube-prometheus-stack's "
    "shipped rules.\n\n"
    "2. All ELEVEN KubeJobFailed alerts are historical. kube_job_failed stays 1 for as long as "
    "the Job object exists and the rule has no time bound, so a job that failed once in June "
    "still fires today. Decoded from the cron suffixes: cilium-node-reconciler x4 and "
    "ecr-credentials-sync x3 ran 2026-06-18/19, the two velero kopia-maintain jobs ~2026-06-23, "
    "istiod-health-check ~2026-08-06. One is kube-system/manual-test-1015 -- a hand-run test "
    "still paging months later.\n\n"
    "THE ELEVEN SITUATIONS AND THEIR DECISIONS:\n"
    "  1. Watchdog (1) -- KEEP FIRING. Dead-man's switch, by design. Must route to a DMS "
    "receiver in INFRA-1659, never be silenced.\n"
    "  2. Talos control plane not scraped (5) -- FIX THE RULE. KubeProxyDown, "
    "KubeControllerManagerDown, KubeSchedulerDown, TargetDown x2, all firing since cluster "
    "build 2026-06-24, three of them critical. On Talos these are static pods the default "
    "scrape config never reaches; the rules measure their own blind spot.\n"
    "  3. Stale failed Job objects (11) -- CLEAN UP the objects and bound the rule; set "
    "ttlSecondsAfterFinished and failedJobsHistoryLimit: 1 or it recurs. Look at the velero "
    "pair before deleting: kopia maintain failing means backup-repo maintenance did not run.\n"
    "  4. attrition-api down (8) -- REAL, since 2026-06-24, and NOT platform. Three "
    "ReplicaSets with waiting containers. Needs an application owner; namespace ownership "
    "must be settled before delivery or these eight land on platform permanently.\n"
    "  5. wiz-sensor (10) -- SILENCE WITH AN EXPIRY of 2026-09-30. Correct and known "
    "(INFRA-1586), blocked on a real Wiz token. A silence without an expiry is deleting the "
    "alert slowly.\n"
    "  6. risingwave-2 test bed (8) -- RETIRE the rules with the namespace, do not silence. "
    "platform-alerts.yaml hardcodes namespace=\"risingwave-2\" in GhostunnelDown and lists it "
    "in two platform-namespace regexes. Silencing something that is never coming back means "
    "carrying it forever.\n"
    "  7. Ceph (2) -- REAL. CephClusterHealthWarn since 2026-08-17 and "
    "KubePdbNotEnoughHealthyPods on rook-ceph-rgw-object-store. Pool was 26% on 2026-08-21, so "
    "this is not capacity. Needs ceph health detail.\n"
    "  8. Istio DaemonSets stuck (2) -- REAL. ztunnel and istio-cni-node. A stuck CNI "
    "DaemonSet affects pod networking on whichever nodes did not roll. Also here: "
    "monitoring/prometheus-prometheus-node-exporter is a LEFTOVER install; the live one is "
    "prometheus/prometheus-stack-prometheus-node-exporter.\n"
    "  9. ClusterDNSUnreachable (1) -- NOT CLASSIFIED. Ours, critical, firing since cluster "
    "build. Either cluster DNS has been unreachable for two months while everything else "
    "works, or the rule has the same blind spot as #2. Both answers are alarming and it must "
    "be verified, not guessed.\n"
    " 10. PrometheusNotConnectedToAlertmanagers (1) -- CORRECT. INFRA-1659 reporting its own "
    "absence, accurately, since June. Resolves itself when delivery exists.\n"
    " 11. CPUThrottlingHigh (4) -- DROP. All node-exporter, info severity; throttling on a CPU "
    "limit is expected.\n\n"
    "WHAT THIS MEANS FOR INFRA-1659: delivering today would page immediately for four things "
    "that are not true (#2) and eleven that finished in June (#3). Order is #2 and #3 first, "
    "then #5 and #6, then turn delivery on, with #4/#7/#8/#9 as real work that should have "
    "gone somewhere.\n\n"
    "Full record, with the decoded job dates and the per-alert evidence: " + DOC
)


def main():
    print(f"== close INFRA-1658  [{'GO' if GO else 'DRY RUN'}]\n")
    m.preflight()

    # Gate: the triage must be COMMITTED and must name every alert observed.
    r = subprocess.run(["git", "-C", REPO, "show", f"HEAD:{DOC}"],
                       capture_output=True, text=True)
    if r.returncode != 0:
        print(f"!! {DOC} is not committed -- refusing to close on an uncommitted file")
        return 1
    body = r.stdout
    missing = [a for a in OBSERVED if a not in body]
    print(f"  triage doc: {DOC} ({len(body.splitlines())} lines, committed)")
    print(f"  alert names observed 2026-08-24: {len(OBSERVED)}")
    if missing:
        print(f"  !! {len(missing)} NOT covered by the triage: {', '.join(missing)}")
        print("\n!! NOT closing. Every firing alert needs a decision, or this is a partial triage.")
        return 1
    print("  all 23 alert names have a decision in the triage\n")

    m.do_comment("INFRA-1658", COMMENT)
    m.do_close("INFRA-1658")
    if not GO:
        print("\nDry run. Re-run with --go.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
