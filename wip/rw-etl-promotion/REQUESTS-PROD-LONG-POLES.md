# INFRA-1674 — the three requests to send today

None of these depend on us. They are the schedule for RisingWave on op-usxpress-prod;
everything else is a day or two of our own work that cannot start until they land.

---

## 1 — DNS (networking)

> We are standing RisingWave up on the on-prem prod cluster (op-usxpress-prod,
> `10.10.82.52`) and need three A records pointing at the prod ingress, matching the
> pattern already in place for dev and QA:
>
>     risingwave-dashboard.op-prod.usxpress.io
>     rw-sql.op-prod.usxpress.io
>     rw-postgres.op-prod.usxpress.io
>
> Same targets and TTLs as the equivalent `op-qa.usxpress.io` records. None of the three
> resolve today, which blocks the ingress routes from being wired.
>
> Ticket is INFRA-1674. What lead time should I plan for?

---

## 2 — Prod Entra app registration (identity)

> RisingWave's console on op-usxpress-prod authenticates through Dex against Entra, the
> same pattern already live on op-dev and op-qa. We need a **new app registration for the
> prod environment** — the dev and QA ones cannot be reused, since the redirect URI is
> per-cluster.
>
> What we need back:
>   * the client ID
>   * a client secret, which we will store at
>     `op-usxpress-prod/risingwave/dex_entra_client_secret` in Secrets Manager
>     (account 937464026810)
>   * the redirect URI registered as
>     `https://risingwave-dashboard.op-prod.usxpress.io/oauth2/callback`
>
> One thing worth flagging up front: our tenant does not emit a `groups` claim, so
> authorisation has to key on **app roles**. Please mirror whatever role definitions the
> op-qa registration carries, so the policy mapping transfers unchanged.
>
> This one is on the critical path — Terraform builds five of our six secrets, and this
> is the sixth. Ticket INFRA-1674.

---

## 3 — RisingWave licence (Steve, for Zach)

> The RisingWave console licence has lapsed, and we need a valid key for the prod
> stand-up on op-usxpress-prod. Could you pick this up with Zach?
>
> Terraform will create the secret at
> `op-usxpress-prod/risingwave/console_license_key` regardless, but it will hold a
> placeholder — the console will come up and refuse to serve until a real key is in
> there. So this does not block the platform stack, only the console.
>
> Ticket INFRA-1674. Timeline would help; if it is going to be weeks, I will land the
> stack without the console and add it after.
