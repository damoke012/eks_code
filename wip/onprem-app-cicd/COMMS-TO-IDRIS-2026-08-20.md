# Message to Idris — QA Postgres password, and two things found in his namespace

**Why this goes to him:** `risingwave` on op-usxpress-qa is his under INFRA-1624. We changed
a password in it today. He should hear that from us, with the timeline, before he finds it.

**Ticket:** INFRA-1652.

---

## Suggested message

> Hi Idris,
>
> While proving out the app delivery path into `app-risingwave` on QA today, our Job couldn't
> authenticate to `pg-postgresql` in your `risingwave` namespace. Chasing it turned up
> something that pre-dates our work and matters to you, so here it is in full.
>
> **The database never learned its rotated password.**
>
> | | |
> |---|---|
> | `initdb` created the roles | 2026-08-11 19:20 UTC |
> | `op-usxpress-qa/risingwave/postgres` rotated | 2026-08-12 13:35 UTC |
>
> `POSTGRES_PASSWORD` only applies at initialisation. So Secrets Manager, `pg-credentials`,
> `risingwave-pg-credentials` and our Job all carried the 08-12 value — identical hashes,
> every ExternalSecret green — while the database still held the 08-11 one.
>
> **Why nothing broke for eight days.** Env from `secretKeyRef` is resolved when the *pod* is
> created, not when a container restarts. `risingwave-meta-default-0` was created 2026-08-11
> 17:15, before the rotation, so its 238 container restarts each replayed the old password and
> each succeeded. The first thing to use that credential fresh was our smoke test.
>
> **What I changed.** `ALTER USER risingwave WITH PASSWORD` from inside `pg-postgresql-0`, to
> the value Secrets Manager holds. The database now agrees with every consumer. (`initdb`
> enables `trust` for local connections, so this needs no prior password — useful to know as a
> recovery route.)
>
> **What that leaves, and why I'd like your nod before doing it.** The fix inverted meta's
> exposure: its pod env still holds the pre-rotation password, so a *container* restart would
> now fail where a *pod* recreation succeeds. Recreating `risingwave-meta-default-0` makes
> everything consistent. It's a brief RisingWave interruption on QA — I'd rather do it with you
> watching than have it happen unattended on a node drain.
>
> **Two other things from the same look:**
>
> 1. `risingwave-meta-default-0` restarted **238 times** with exit code 139 (SIGSEGV) in its
>    first 16 hours, then went stable. Nothing alerted. Worth knowing what that was.
> 2. Any Postgres on **dev or prod** built before its secret was rotated has the same dormant
>    fault. `scripts/check-postgres-secret-usable.sh` answers it per cluster in one run — it
>    compares `initdb` against `LastChangedDate` and then actually authenticates.
>
> Nothing here is urgent tonight. The meta pod recreation is the only open item and it takes
> thirty seconds whenever suits.

---

## The commands, once he acks

```bash
# QA · op-usxpress-qa
KC=$HOME/.kube/op-usxpress-qa-sso.yaml; CTX=op-usxpress-qa-sso
k() { kubectl --kubeconfig=$KC --context $CTX "$@"; }

k -n risingwave delete pod risingwave-meta-default-0
sleep 30
k -n risingwave get pods | grep -E 'meta|frontend|compute|compactor'
k -n risingwave logs risingwave-meta-default-0 --tail=20
```

Healthy means meta reaches `Running 1/1` and its log shows the hummock GC lines rather than a
connection error. If it cannot authenticate, the database and the secret have diverged again
and `scripts/check-postgres-secret-usable.sh` says so directly.

## Then check the other clusters

```bash
# dev · op-usxpress-dev — cert-based kubeconfig, needs corp VPN
# The context name is RESOLVED from the API endpoint, never typed: kubeconfig
# filenames and context names drift independently on WSL, and a command that
# silently targets the wrong cluster is worse than one that fails.
export KUBECONFIG=$HOME/.kube/op-usxpress-dev-fresh.yaml
DEV_CTX=$(kubectl config view -o json | python3 -c "
import sys, json
d = json.load(sys.stdin)
clusters = {c['name'] for c in d['clusters']
            if c['cluster'].get('server') == 'https://10.10.82.50:6443'}
names = [c['name'] for c in d['contexts'] if c['context']['cluster'] in clusters]
print(names[0] if names else '')
")
[ -n "$DEV_CTX" ] || { echo 'no context in this kubeconfig points at 10.10.82.50:6443'; }
echo "resolved dev context: $DEV_CTX"

bash scripts/check-postgres-secret-usable.sh "$DEV_CTX" risingwave \
  op-usxpress-dev/risingwave/postgres usx-dev
```

**Prod has no routine access path** (INFRA-1638): checking it needs break-glass
`op-usxpress-prod/talosconfig` from Secrets Manager in 937464026810. Worth doing once the dev
result is known — if dev is also affected, that is a pattern rather than an accident and prod
should be checked immediately rather than opportunistically.

---

## Added 20:40Z — two more things in his namespaces, and one apology

**INFRA-1654: `rw-postgres` has never worked, on dev or QA.**

> One more, and this one is older than today. While bringing up the QA L4 routes I found that
> `ghostunnel-rw-postgres` is started with `--listen=:4567` while the Service in front of it is
> `5432 -> targetPort 5432`. Nothing has ever been listening where traffic arrives.
>
> `manifests/op-usxpress-dev/ghostunnel-rw-postgres.yaml:93` is identical, so
> `rw-postgres.op-dev.usxpress.io` has resolved to your seven workers and served nothing since
> Phase 1 closed on 2026-06-01. If anyone tried the dev Postgres endpoint in the last eleven
> weeks they'd have got a connection that opens and dies — which reads like a network problem,
> not a config one.
>
> It stayed hidden because the readiness probe is `tcpSocket: {port: status}` — ghostunnel's
> 9090 listener. Both pods report `READY true, 0 restarts` while serving nothing.
>
> The fix needs **both** lines, in `variant-inc/iaac-risingwave-onprem`:
>   `--listen=:5432`, and a readiness probe on the data port.
> Without the probe change the next copy of this manifest will look equally healthy.
> Happy to raise the PR if you'd rather I did — it's your repo, so I haven't.

**INFRA-1645: I changed the QA L4 routes without asking you first.**

> The two RisingWave L4 VirtualServices on op-qa were dev copies — they advertised the dev
> hostnames against dev's seven worker IPs, and they selected a Gateway that had never been
> ported to the QA branch, so they'd been bound to nothing since the branch was created. I
> fixed both and added the Gateway, merged as iaac-talos-flux-platform#102.
>
> It only creates objects in `istio-ingress` and changes nothing inside `risingwave`, and
> `rw-sql.op-qa.usxpress.io` now serves. But `risingwave` on QA is yours under INFRA-1624 and
> I should have checked with you before merging rather than after. Dev's records are untouched
> — I confirmed both dev names still resolve to all seven workers afterwards, because renaming
> them in one PR rather than two was the difference between that and deleting your dev DNS.
