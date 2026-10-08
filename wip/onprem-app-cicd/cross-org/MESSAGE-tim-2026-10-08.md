Hi Tim — three answers, and two things to check before your next push.

**The console URL you asked for on Tuesday.** It exists now, and it didn't when you asked:

- Dev — https://risingwave-console.op-dev.usxpress.io
- QA — https://risingwave-console.op-qa.usxpress.io

Sign in with SSO there. We fixed the naming today: `risingwave-dashboard.op-dev` had been
serving the **Console** since Phase 1, which is why nothing lined up with its name. It now
shows the actual Dashboard, and `risingwave-overview` shows the same thing.

**How code gets to the dev cluster.** Today, it doesn't — PR #5 deploys to **QA**. Dev is a
separate path we haven't wired to your repo. If you'd rather dev were the first stop, say so;
it's a small change and probably the right one for a POC.

**Two things that would make your next push look fine and deploy nothing.**

1. Your files are `.rw`, not `.sql` — `pipelines/Brand/300-transform-flat.rw`. I'm confirming
   our applier picks those up and doesn't only match `*.sql`. If it doesn't, the image builds
   green and applies zero files. I'll have an answer before you need it.
2. The workflow triggers on **master** only. `f/Brand_Employee` won't build anything until it
   merges. Tell me if you want it to build from your branch as well — easy either way, but
   worth deciding before you rely on it.

**On the version.** v3.1.0 is RisingWave itself; we're on v2.8.2, with the Console at v0.7.4
(a separate product with its own numbering, which is why it looked odd). The constraint Idris
mentioned is about the `latest` **tag**, not about staying on an old version — we pin an exact
digest, and pinning a newer one is completely fine. Upgrading is a scheduling question, not a
policy one. Want me to put a plan together?

**CDC.** Idris found `wal_level=replica` and has a change open to set it to `logical`. One
thing to confirm first: the PostgreSQL in that namespace is RisingWave's own **meta store** —
internal bookkeeping, no business data. If you want to CDC *from* a database, that's your
source system, which I believe is SQL Server. Can you confirm which database you need change
capture from? It changes what we build, and it's a five-minute conversation versus a wrong
restart on three clusters.

Thanks for the Brand diff — `f/Brand_Employee` as the single source of truth works for us.
