# Published page sources

The HTML behind each published page, kept here because the session scratchpad is cleared
without warning — twice on 2026-10-20, losing a page mid-edit and costing a full recovery
read each time.

| File | Page | URL |
|---|---|---|
| `prod-readiness-plan.html` | Prod Readiness Plan | https://claude.ai/artifact/PtHGTNEjhcrEaYpJRrcJHS |
| `onprem-platform-reference.html` | On-Prem Platform Reference | https://claude.ai/artifact/CduE9WmBzQvsXXRxyjd9rv |
| *(recover on next edit)* | On-Prem Delivery Setup | https://claude.ai/artifact/KFcUymxTX3W7gw1MYfXoCt |
| *(recover on next edit)* | Pricing App On-Prem Move | https://claude.ai/artifact/1R9Qbe1K5ex9jnZg7u3Hxc |
| *(recover on next edit)* | App Onboarding Intake | https://claude.ai/artifact/AzVn5mJEnzaQspnKuE3UPV |

**To edit a page whose source is not here:** read it back from its URL with the Artifact
tool's read action, save it here, then edit and republish. A published page is always
recoverable; the scratchpad is not.

⚠️ **These are page sources, not deployment manifests.** Rule 7 still applies — nothing in
`wip/` is applied anywhere.

## Recovering a page whose source was lost

Read it **to disk**, not into the conversation, then strip the publish skeleton:

```
Artifact action=read url=<the url> path=index.html out_dir=wip/pages
```

The saved copy is the *published* form — it carries the `<!doctype html>…<body>` wrapper the
publish step adds. Cut everything up to `<body>` and from `</body>`, or the next publish
nests one skeleton inside another.

⚠️ A `path=` read does **not** count as having viewed the artifact for a republish. It works
here only because this session published these pages; from a fresh session, read the url
without `path` first.
