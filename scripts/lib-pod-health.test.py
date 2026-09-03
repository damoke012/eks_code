#!/usr/bin/env python3
"""Tests for lib-pod-health.classify — the logic rw-prod-status and the fleet check share.

They had a copy each, and on 2026-09-03 they disagreed about op-prod risingwave-console in
front of the operator. These cases pin the three distinctions that disagreement was about.
"""
import datetime, importlib.util, json, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("lph", os.path.join(HERE, "lib-pod-health.py"))
lph = importlib.util.module_from_spec(spec); spec.loader.exec_module(lph)

NOW = datetime.datetime(2026, 9, 3, 20, 0, tzinfo=datetime.timezone.utc)
def ago(minutes): return (NOW - datetime.timedelta(minutes=minutes)).strftime("%Y-%m-%dT%H:%M:%SZ")

def pod(name, phase="Running", containers=()):
    return {"metadata": {"name": name}, "status": {"phase": phase, "containerStatuses": list(containers)}}

def running(restarts=0, up_min=1000):  return {"restartCount": restarts, "state": {"running": {"startedAt": ago(up_min)}}}
def looping(restarts, died_min):
    return {"restartCount": restarts, "state": {"waiting": {"reason": "CrashLoopBackOff"}},
            "lastState": {"terminated": {"finishedAt": ago(died_min)}}}

fails = []
def check(name, doc, want):
    got = lph.classify({"items": doc}, 10, now=NOW)
    trimmed = {k: got[k] for k in want}
    if trimmed == want: print("  PASS  %s" % name)
    else: print("  FAIL  %s\n        want %s\n        got  %s" % (name, want, trimmed)); fails.append(name)

print("== lib-pod-health.classify")

check("steady pods are neither churn nor healed",
      [pod("a", containers=[running()]), pod("b", containers=[running()])],
      {"notready": [], "churn": [], "healed": []})

check("not-Running is reported by phase",
      [pod("a", phase="Pending", containers=[running()])],
      {"notready": ["a(Pending)"], "churn": []})

# The op-prod console: many restarts, long settled. History, not a live fault.
check("532 restarts but stable 3h -> healed, not churn",
      [pod("console", containers=[running(restarts=532, up_min=180)])],
      {"churn": [], "healed": ["console(532 restarts, stable 3h)"]})

# The op-dev prometheus: crashlooping container beside a healthy 133h sidecar.
check("CrashLoopBackOff behind a healthy sidecar -> churn, sidecar does not mask it",
      [pod("prom", containers=[running(up_min=133 * 60), looping(1566, 4)])],
      {"churn": ["prom(1566 restarts, in CrashLoopBackOff NOW)"], "healed": []})

# Restarts under the limit are noise, not signal.
check("restarts at or below the limit are ignored",
      [pod("a", containers=[running(restarts=10, up_min=5)])],
      {"churn": [], "healed": []})

# A recent restart with no CrashLoopBackOff yet is still a live fault.
check("restarted 4 minutes ago -> churn even without a waiting state",
      [pod("a", containers=[running(restarts=50, up_min=4)])],
      {"churn": ["a(50 restarts, last 4m ago)"], "healed": []})

print("\n  %s" % ("all passed" if not fails else "FAILED: %s" % ", ".join(fails)))
sys.exit(1 if fails else 0)
