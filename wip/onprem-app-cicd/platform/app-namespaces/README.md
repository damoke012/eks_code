# app-* namespaces

The platform owns these, not Argo CD. Every `Application` sets
`CreateNamespace=false`, so an app team cannot conjure a namespace by editing a
manifest — quota, PodSecurity and Istio enrolment are decided here.

**To onboard an app:** copy `_template.yaml` to `app-<name>.yaml`, replace
`APPNAME`, adjust the quota if the defaults don't fit, and add the filename to
`kustomization.yaml`. One PR, three lines changed.

The label `platform.usxpress.io/delivery: argocd` is load-bearing: the Kyverno
supply-chain policies select on it, so a namespace without it is exempt from the
registry and digest rules. Don't drop it.
