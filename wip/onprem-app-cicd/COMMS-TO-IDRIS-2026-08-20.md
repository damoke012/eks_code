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
KUBECONFIG=$HOME/.kube/op-usxpress-dev-fresh.yaml \
  bash scripts/check-postgres-secret-usable.sh <dev-context> risingwave \
    op-usxpress-dev/risingwave/postgres usx-dev
```

⚠️ The dev context name is not assumed here — resolve it by endpoint first
(`https://10.10.82.50:6443`), the same way the wizard does, rather than trusting a filename.

**Prod has no routine access path** (INFRA-1638): checking it needs break-glass
`op-usxpress-prod/talosconfig` from Secrets Manager in 937464026810. Worth doing once the dev
result is known — if dev is also affected, that is a pattern rather than an accident and prod
should be checked immediately rather than opportunistically.
