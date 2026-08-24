#!/usr/bin/env python3
"""Close INFRA-1657, and correct the record on INFRA-1656.

INFRA-1657 is closed ONLY IF all three cluster branches can be PROVEN to carry
the aggregated expression, read out of git. The ticket's whole subject is alerts
that reported success about the step next to the one that mattered; closing it
on an assertion would be the same mistake one more time.

INFRA-1656 was closed on 2026-08-21 on a premise that was never checked and was
false. That correction is posted whether or not the 1657 gate passes.

DRY-RUN BY DEFAULT. Pass --go.
Auth:  read -rsp 'Atlassian API token: ' ATLASSIAN_TOKEN; export ATLASSIAN_TOKEN; echo
Run from WSL, against the corporate checkout (CLAUDE.md rule 10).
"""
import importlib.util, os, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("closer", os.path.join(HERE, "close-sprint3-tickets.py"))
m = importlib.util.module_from_spec(spec)
_argv = sys.argv[:]; sys.argv = ["x"]
spec.loader.exec_module(m)
sys.argv = _argv
m.GO = "--go" in sys.argv
GO = m.GO

WORK = os.environ.get("WORK", os.path.expanduser("~/pr-work/iaac-talos-flux-platform"))
BRANCHES = ["op-dev", "op-qa", "op-prod"]
NEEDLE = "max by (customresource_kind, exported_namespace, name)"
OLD = ['ready="False"', "gotk_reconcile_condition"]


def git(*args):
    return subprocess.run(["git", "-C", WORK, *args],
                          capture_output=True, text=True)


def verify_branches():
    """Read platform-alerts.yaml out of each branch and check the expression.

    Returns (ok, lines). Discovers the path per branch -- op-qa keeps it under
    infrastructure/prometheus-rules/ where dev and prod use prometheus/.
    """
    out, ok = [], True
    if not os.path.isdir(os.path.join(WORK, ".git")):
        return False, [f"  !! no checkout at {WORK}"]
    if git("fetch", "-q", "origin").returncode != 0:
        return False, ["  !! git fetch failed"]

    for b in BRANCHES:
        r = git("ls-tree", "-r", "--name-only", f"origin/{b}")
        if r.returncode != 0:
            out.append(f"  !! {b}: no such branch"); ok = False; continue
        paths = [l for l in r.stdout.splitlines() if l.endswith("platform-alerts.yaml")]
        if len(paths) != 1:
            out.append(f"  !! {b}: found {len(paths)} platform-alerts.yaml, expected 1")
            ok = False; continue
        body = git("show", f"origin/{b}:{paths[0]}")
        if body.returncode != 0:
            out.append(f"  !! {b}: could not read {paths[0]}"); ok = False; continue
        text = body.stdout
        # Guard on expressions, never the whole file -- the comment block
        # documents the old forms by name, and a naive search matches the
        # documentation rather than the code. That bug shipped twice today.
        code = "\n".join(l for l in text.splitlines() if not l.lstrip().startswith("#"))
        n = code.count(NEEDLE)
        stale = [o for o in OLD if o in code]
        if n == 3 and not stale:
            out.append(f"  OK  {b}: {paths[0]} -- 3 aggregated expressions, no stale forms")
        else:
            out.append(f"  !! {b}: {paths[0]} -- {n} aggregated (want 3)"
                       f"{', stale: ' + ', '.join(stale) if stale else ''}")
            ok = False
    return ok, out


CLOSE_1657 = (
    "CLOSED 2026-08-24. Shipped and verified on op-usxpress-dev; merged on op-qa and "
    "op-prod.\n\n"
    "PROBLEM. The three Flux alert rules shipped in INFRA-1503 had never been able to fire, "
    "for four independent reasons in series -- each one invisible until the reason above it "
    "was fixed -- so flux-system/risingwave and flux-system/wiz-sensor sat Ready=False for "
    "six days with every status field in the stack green.\n\n"
    "FIX. Added a PodMonitor for the Flux controllers (#114-#116); replaced "
    "gotk_reconcile_condition, which does not exist in this Flux version, with "
    "gotk_resource_info from kube-state-metrics CustomResourceState (#117-#119); widened the "
    "matcher to ready!=\"True\" so cycling failures count and not only stalled ones (#120); "
    "and aggregated the churning ready/revision labels out of the alert's identity with "
    "max by (customresource_kind, exported_namespace, name) so the for: 10m window can "
    "complete (#121, #122, #123). The same PR repointed the summaries at exported_namespace "
    "-- $labels.namespace on a kube-state-metrics CustomResourceState series is KSM's own "
    "namespace, so every Flux page would have named prometheus/<object> instead of "
    "flux-system/<object>.\n\n"
    "EVIDENCE, op-usxpress-dev 2026-08-24 17:16-17:27 UTC, sampled every 60s:\n"
    "  17:16-17:19  pending  flux-system/risingwave, flux-system/wiz-sensor\n"
    "  17:20-17:27  FIRING   flux-system/risingwave, flux-system/wiz-sensor\n"
    "risingwave held firing for seven consecutive minutes with no return to pending -- the "
    "thing it had never done. The namespace renders flux-system. Transient objects "
    "(trust-manager-bundle, gateway-api, risingwave-onprem) appeared as pending and expired "
    "without reaching firing, which is for: 10m behaving correctly.\n\n"
    "for: 10m is confirmed correctly sized against a dependsOn cascade: peak breadth 27 "
    "Kustomizations simultaneously not-Ready, decaying to 4 within three minutes; exactly 2 "
    "survive a full window, which are the two genuinely broken ones.\n\n"
    "SCOPE. The ticket was filed as \"scrape flux-system\" and described as the smallest of "
    "the three. It was neither. Re-scoped in place.\n\n"
    "STILL OPEN, and this ticket does not cover them: nothing delivers alerts (INFRA-1659, no "
    "Alertmanager -- these two now fire into a UI nobody watches), and the 54 pre-existing "
    "firing alerts are untriaged (INFRA-1658). op-qa and op-prod are merged but NOT observed "
    "firing; QA's Prometheus was not locatable at -n prometheus.\n\n"
    "Full record: wip/observability/FINDINGS-2026-08-21-alerts-reach-nobody.md"
)

CORRECT_1656 = (
    "CORRECTION 2026-08-24 -- this ticket was closed on 2026-08-21 on a premise I did not "
    "check, and the premise was false.\n\n"
    "The closing note said auto-merge had merged PR #109 into op-prod without review. That is "
    "not what happened. Checked properly:\n"
    "  - allow_auto_merge is FALSE at the repository level on variant-inc/iaac-talos-flux-platform, "
    "so no PR there has ever auto-merged;\n"
    "  - #109 was merged manually, by dare-x, at 2026-08-21T15:57:17Z.\n\n"
    "So the risk this ticket was raised against did not exist in the form described.\n\n"
    "What actually happened since: branch protection requiring one approving review was applied "
    "to op-prod on 2026-08-21, and DELETED on 2026-08-24 at the owner's direction, because it "
    "blocked the INFRA-1657 prod PR and GitHub does not let an author approve their own PR. With "
    "one platform engineer, a required-review gate is a gate against ourselves.\n\n"
    "CURRENT STATE: op-prod has NO branch protection. That is a deliberate choice, not an "
    "oversight, and it should be revisited when there is a second reviewer on the team -- not "
    "before, because the only available outcome today is a blocked queue.\n\n"
    "Leaving this closed. The outcome was right; the reasoning recorded against it was not, and "
    "the record should say so rather than quietly stand."
)


def main():
    print(f"=== {'GO' if GO else 'DRY RUN'} ===")
    if GO:
        m.preflight()

    print("\nINFRA-1656 -- correcting the record")
    m.do_comment("INFRA-1656", CORRECT_1656)

    print(f"\nINFRA-1657 -- verifying all three branches in {WORK}")
    ok, lines = verify_branches()
    for l in lines:
        print(l)
    if not ok:
        print("\n!! NOT closing INFRA-1657 -- the branches do not prove the fix is shipped.")
        print("   Posting no close comment either. Fix the branches, re-run.")
        return 1

    print("\n  all three branches carry the aggregated expression -- closing")
    m.do_comment("INFRA-1657", CLOSE_1657)
    m.do_close("INFRA-1657")
    if not GO:
        print("\nDry run. Re-run with --go.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
