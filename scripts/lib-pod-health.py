#!/usr/bin/env python3
"""Classify the pods in a `kubectl get pods -o json` document. Reads stdin, writes JSON.

    kubectl -n ns get pods -o json | RESTART_LIMIT=10 python3 scripts/lib-pod-health.py
    -> {"total": 12, "notready": [...], "churn": [...], "healed": [...]}

ONE implementation, used by rw-prod-status.sh gate 3 and rw-fleet-licence-status.sh. They
had two, and on 2026-09-03 they disagreed about the same pod in front of the operator: the
fleet check called op-prod risingwave-console "stable 3h" while gate 3 called it
"crashlooping", because only one of them had been taught the difference.

Three facts this encodes, each of which cost a wrong answer today:

  * A crashlooping pod shows STATUS Running between backoffs. op-prod's console read as
    "12/12 Running" for two days that way.
  * A restart count is CUMULATIVE and never falls, so 532 restarts cannot distinguish
    crashing-now from settled-hours-ago. Time since the last restart is the discriminator.
  * A container in CrashLoopBackOff is in state.WAITING and has no running.startedAt, so a
    healthy sidecar in the same pod masks it. lastState.terminated.finishedAt is when a
    container actually last died, and it survives the restart.
"""
import datetime
import json
import os
import sys

HEALED_AFTER_MIN = 60   # stable this long => history, not a live fault


def classify(doc, limit, now=None):
    now = now or datetime.datetime.now(datetime.timezone.utc)
    items = doc.get("items", [])
    notready, churn, healed = [], [], []

    for pod in items:
        name = pod.get("metadata", {}).get("name", "?")
        status = pod.get("status") or {}
        phase = status.get("phase", "?")
        statuses = status.get("containerStatuses") or []
        restarts = max([c.get("restartCount", 0) for c in statuses], default=0)

        since, looping = None, False
        for c in statuses:
            state = c.get("state") or {}
            if "CrashLoopBackOff" in str((state.get("waiting") or {}).get("reason", "")):
                looping = True
            stamp = (((c.get("lastState") or {}).get("terminated") or {}).get("finishedAt")
                     or (state.get("running") or {}).get("startedAt"))
            if stamp:
                t = datetime.datetime.fromisoformat(stamp.replace("Z", "+00:00"))
                mins = (now - t).total_seconds() / 60
                since = mins if since is None else min(since, mins)

        if phase not in ("Running", "Succeeded"):
            notready.append("%s(%s)" % (name, phase))
        elif restarts > limit:
            if looping:
                churn.append("%s(%d restarts, in CrashLoopBackOff NOW)" % (name, restarts))
            elif since is not None and since >= HEALED_AFTER_MIN:
                healed.append("%s(%d restarts, stable %dh)" % (name, restarts, since // 60))
            else:
                ago = "just now" if since is None else "%dm ago" % since
                churn.append("%s(%d restarts, last %s)" % (name, restarts, ago))

    return {"total": len(items), "notready": notready, "churn": churn, "healed": healed}


if __name__ == "__main__":
    try:
        document = json.load(sys.stdin)
    except Exception:
        # Unreadable input is NOT an empty namespace. Say so rather than reporting 0 pods,
        # which reads as "nothing deployed here".
        print(json.dumps({"total": -1, "notready": [], "churn": [], "healed": [],
                          "error": "could not parse kubectl output as JSON"}))
        raise SystemExit(0)
    print(json.dumps(classify(document, int(os.environ.get("RESTART_LIMIT", "10")))))
