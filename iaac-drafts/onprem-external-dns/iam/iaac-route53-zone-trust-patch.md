# iaac-route53-zone trust patch — SUPERSEDED 2026-05-18

> **STATUS: NO PATCH NEEDED.**
>
> The trust policy on `iaac-route53-zone` in account 155768531003 already
> permits any role in the USXpress AWS Org matching `extd-usxpress-io-*` (or
> `cert-manager-*`) to assume it.
>
> Our source role is named `extd-usxpress-io-op-usxpress-dev` — which matches
> the existing pattern. No modification to the network-team-owned target role
> is required.
>
> See `network-team-ask-trust-extension.md` (in the parent directory) for the
> full context and the actual existing trust policy.
