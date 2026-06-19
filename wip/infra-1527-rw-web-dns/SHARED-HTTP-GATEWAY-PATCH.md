# shared-http Gateway patch — apply by hand

The Gateway resource `istio-ingress/shared-http` lives at
`infrastructure/istio-ingress/gateway/shared-http.yaml` (or similar) in this
repo and needs two new `server` entries appended to `spec.servers` —
**alongside** the existing `*.op-dev.usxpress.io` server blocks. Don't replace
anything that's already there.

Paste these two entries at the end of `spec.servers`:

```yaml
    - port:
        number: 443
        name: https-rw-dashboard
        protocol: HTTPS
      hosts:
        - risingwave-dashboard.usxpress.io
      tls:
        mode: SIMPLE
        credentialName: risingwave-dashboard-usxpress-io-tls

    - port:
        number: 443
        name: https-rw-overview
        protocol: HTTPS
      hosts:
        - risingwave-overview.usxpress.io
      tls:
        mode: SIMPLE
        credentialName: risingwave-overview-usxpress-io-tls
```

Notes:
- Indentation matches a `spec.servers` list item (4-space outer indent assumed)
- `credentialName` names match the `secretName` from the two Certificate
  resources in `infrastructure/risingwave-routes/certificate-*.yaml`
- Both server blocks listen on 443; SNI routes by `hosts:` value

## Parent kustomization

The parent kustomization that includes everything under `infrastructure/` needs
one new entry pointing at the new directory. Find the relevant
`kustomization.yaml` (probably `infrastructure/kustomization.yaml` in this
repo, or the cluster-level Kustomization on iaac-talos-flux-cluster) and add:

```yaml
resources:
  # ... existing entries
  - risingwave-routes
```
