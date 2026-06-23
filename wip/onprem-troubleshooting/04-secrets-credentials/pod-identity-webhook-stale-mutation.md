# Pod stuck in CrashLoopBackOff after pod-identity-webhook flaps — IRSA env never injected

## Symptom

A StatefulSet/Deployment pod that DEPENDS on IRSA (AWS_WEB_IDENTITY_TOKEN_FILE) is stuck in CrashLoopBackOff with logs showing:

```
ERROR opendal::services: service=s3 ... loading credential to sign http request
called: reqsign::LoadCredential
```

Or any other AWS SDK "credential load failure" or fallback-to-IMDS error. Yet:
- The ServiceAccount HAS the correct `eks.amazonaws.com/role-arn` annotation
- The IAM role exists with the right trust policy
- `pod-identity-webhook` Deployment is Running
- Other pods on the cluster (created at different times) DO have IRSA env vars injected

The container has been restarting hundreds or thousands of times. The age of the POD is days/weeks. The age of the SA is older than the pod (SA annotation was in place when pod was created).

## Root cause

`pod-identity-webhook` is a **mutating admission webhook** that fires at pod **CREATE** time. It injects:
- env vars `AWS_ROLE_ARN`, `AWS_WEB_IDENTITY_TOKEN_FILE`
- projected token volume `aws-iam-token` mounted at `/var/run/secrets/eks.amazonaws.com/serviceaccount`

If the webhook is **DOWN or flapping** when a pod is being created, the apiserver call to the webhook fails. Default `failurePolicy: Ignore` (set on the MutatingWebhookConfiguration) means: **proceed without mutation**. Pod is created with NO IRSA env vars / volume.

From that moment on, the kubelet keeps **restarting the CONTAINER inside that pod**. Restarts do NOT re-trigger admission. The pod permanently lacks IRSA injection until something deletes the pod itself.

For StatefulSets (e.g., `risingwave-meta-default-0`), the pod has a fixed name — kubelet just keeps restarting it. For Deployments, a ReplicaSet roll would create fresh pods, but if no roll is triggered, the original (un-mutated) ReplicaSet pod keeps restarting too.

## How this happens

- Cluster-wide kubelet/CP incident causes pod-identity-webhook to crashloop briefly (e.g., the 2026-06-17 CP OOM cascade on op-usxpress-dev)
- During the incident, OTHER controllers create new pods (e.g., StatefulSets recovering from a Node failure)
- These new pods miss admission mutation
- Webhook recovers, but the un-mutated pods persist + crashloop forever
- Days later, someone investigating an "IRSA broken" symptom finds the stuck pods

## Detection

```bash
# Pod has SA referenced
kubectl -n $NS get pod $POD -o jsonpath='{.spec.serviceAccountName}'

# SA has the IRSA annotation
kubectl -n $NS get sa $SA -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}'

# But pod does NOT have AWS_WEB_IDENTITY env or aws-iam-token volume
kubectl -n $NS get pod $POD -o yaml | grep -E "AWS_WEB_IDENTITY|aws-iam-token"
# Empty output = pod missed admission mutation
```

If SA has annotation AND pod lacks env vars → admission webhook didn't run for this pod.

## Resolution

**Delete the pod.** StatefulSet/Deployment will recreate. New pod goes through admission with healthy webhook → IRSA env vars injected → AWS SDK credential load succeeds → pod runs normally.

```bash
kubectl -n $NS delete pod $POD --grace-period=10
sleep 30

# Verify the NEW pod has IRSA env injected
kubectl -n $NS get pod $POD -o yaml | grep "AWS_WEB_IDENTITY"
# Should now have 1+ matches
```

For a whole namespace with several stuck pods (e.g., a RisingWave deployment with meta + compute + compactor + frontend + operator all stuck):

```bash
# Delete the StatefulSet pods (they get fixed names — recreated by StatefulSet)
kubectl -n $NS delete pod -l app.kubernetes.io/component=meta
kubectl -n $NS delete pod -l app.kubernetes.io/component=compute

# Delete Deployment-managed pods (they get new pod names — recreated by ReplicaSet)
kubectl -n $NS delete pod -l app.kubernetes.io/component=compactor
kubectl -n $NS delete pod -l app.kubernetes.io/component=frontend
kubectl -n $NS delete pod -l app.kubernetes.io/component=operator
```

## IaC coverage

⚠ **Detection is partial.** PromRule `irsa-health` (in `infrastructure/prometheus/irsa-health.yaml`, PR #50) has the `PodIdentityWebhookCAInvalid` alert which detects caBundle drift, but **does not detect missed mutations** (silent failures).

A `PodIRSAEnvMissing` PromRule could check: pods with a known IRSA SA (annotated with eks.amazonaws.com/role-arn) that lack AWS_WEB_IDENTITY env. Not implemented today.

**Manual remediation only.** Add to QA cluster bootstrap checklist as Phase 6 post-flight verification:
- After app deployment, scan all pods with IRSA SAs and confirm env vars are present
- If any pods missed mutation, delete them in a single batch

## Prevention

1. **Make pod-identity-webhook critical** by setting `failurePolicy: Fail` on the MutatingWebhookConfiguration. This means pod create REJECTED if webhook is down (better failure mode than silent missed mutation).
2. **Run pod-identity-webhook with 2+ replicas** so a single pod restart doesn't take it down (currently 1 replica per Helm chart default).
3. **Catalog this entry** so future incidents recognize the pattern faster.

## Related catalog entries

- [irsa-imds-fallback.md](irsa-imds-fallback.md) — generic IRSA-IMDS fallback pattern
- [cluster-dns-failure.md](../03-networking/cluster-dns-failure.md) — DNS issues from CiliumNode drift (similar incident pattern)
- [cp-capacity-exhaustion.md](../01-cluster-control-plane/cp-capacity-exhaustion.md) — the 2026-06-17 CP OOM cascade that likely caused the mutation miss

## Verified

2026-06-22 LATE PM. RW-2 namespace had 5 pods (meta + compute + compactor + frontend + operator) stuck in CrashLoopBackOff for 4 days. Root cause was missed mutation during 2026-06-17 CP OOM cascade. Fix was `kubectl delete pod` for each stuck pod — all came up clean within 60 seconds with IRSA env vars injected.
