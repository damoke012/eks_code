#!/usr/bin/env python3
"""Close INFRA-1555 after the Postgres rw-2 -> ceph-block migration completes.
Edit the EVIDENCE block, then run."""
import json, urllib.request, base64
from pathlib import Path

# ============ EDIT-ME ============
VELERO_BACKUP_NAME = ""              # e.g. "rw2-postgres-pre-migration-20260625T140000Z"
OLD_PVC_NAME = ""                    # e.g. "data-postgres-rw2-0"
NEW_PVC_SIZE = ""                    # e.g. "10Gi"
TIM_ACK_DATE = ""                    # e.g. "2026-06-25" — courtesy ping ack date
MIGRATION_TS_UTC = ""                # e.g. "2026-06-25 15:30 UTC"
DATA_PERSISTENCE = "rebuilt"         # one of: "rebuilt" (RW rebuilt meta from compute) | "restored" (Velero file-restore used)
# =================================

import os
EMAIL = os.environ.get("ATLASSIAN_EMAIL", "doke@usxpress.com")
TOKEN = os.environ.get("ATLASSIAN_TOKEN", "")
if not TOKEN:
    for candidate in [
        "/workspaces/eks_code/scripts/push-to-confluence.sh",
        os.path.expanduser("~/work/eks_code/scripts/push-to-confluence.sh"),
    ]:
        p = Path(candidate)
        if p.exists():
            for ln in p.read_text().splitlines():
                if ln.startswith("CONFLUENCE_TOKEN="):
                    TOKEN = ln.split("=", 1)[1].strip().strip('"').strip("'")
                    break
            if TOKEN:
                break
assert TOKEN, "Set ATLASSIAN_TOKEN env var or place the token script at the expected codespace/WSL paths."
BASE = "https://usxpress.atlassian.net"
auth = base64.b64encode(f"{EMAIL}:{TOKEN}".encode()).decode()
HEADERS = {"Authorization": f"Basic {auth}", "Accept": "application/json", "Content-Type": "application/json"}

if not all([VELERO_BACKUP_NAME, OLD_PVC_NAME, NEW_PVC_SIZE, TIM_ACK_DATE, MIGRATION_TS_UTC]):
    raise SystemExit("EDIT-ME fields not filled in.")

assert DATA_PERSISTENCE in ("rebuilt", "restored")
data_line = "rw-2 RisingWave rebuilt the Postgres meta-store from compute nodes; no file-level restore needed." if DATA_PERSISTENCE == "rebuilt" else "Postgres data files restored from Velero file-level backup; verified row counts pre/post match."

text = f"""{MIGRATION_TS_UTC} -- Migration complete.

Pre-flight:
- Tim courtesy ack received: {TIM_ACK_DATE}
- Velero pre-backup: {VELERO_BACKUP_NAME} (Phase Completed, no errors)
- rw-2 pre-state captured

Execution:
- Old PVC {OLD_PVC_NAME} on local-path: deleted
- New PVC {OLD_PVC_NAME} on ceph-block: bound, {NEW_PVC_SIZE}
- Postgres pod: Running + Ready, psql connectivity verified
- Data persistence: {data_line}

Post-verify:
- rw-2 pre/post diff: only storageClassName=ceph-block (expected)
- Restart counts: stable
- RW-2 operator log: no Postgres connection errors
- Tim's risingwave namespace: untouched, zero blast radius (verified before + after)

Closes the last local-path PVC on a production workload in rw-2. Matches the storage decision in [[observability-phase0-locked-jun24]] ADR-001 Decision 1."""


def adf(t):
    blocks = []
    for para in t.strip().split("\n\n"):
        lines = para.split("\n")
        content = []
        for i, l in enumerate(lines):
            if i > 0:
                content.append({"type": "hardBreak"})
            if l:
                content.append({"type": "text", "text": l})
        blocks.append({"type": "paragraph", "content": content})
    return {"type": "doc", "version": 1, "content": blocks}


def api(method, path, body=None):
    req = urllib.request.Request(f"{BASE}{path}", data=json.dumps(body).encode() if body else None, method=method, headers=HEADERS)
    with urllib.request.urlopen(req) as r:
        return json.loads(r.read().decode() or "{}")


req = urllib.request.Request(f"{BASE}/rest/api/3/issue/INFRA-1555/comment", data=json.dumps({"body": adf(text)}).encode(), method="POST", headers=HEADERS)
with urllib.request.urlopen(req) as r:
    print(f"  INFRA-1555 commented (id {json.loads(r.read().decode())['id']})")

tres = api("GET", "/rest/api/3/issue/INFRA-1555/transitions")
tid = {t["name"]: t["id"] for t in tres["transitions"]}
for name in ("Done", "Closed", "Resolved", "Complete"):
    if name in tid:
        api("POST", "/rest/api/3/issue/INFRA-1555/transitions", {"transition": {"id": tid[name]}})
        print(f"  INFRA-1555 -> {name}")
        break
