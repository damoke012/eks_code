# Message to Idris — feedback on the Stage 1 plan (INFRA-1715)

Plain lines, Doke's voice. Send as a Teams message or a comment on the Confluence page.

---

Idris - read the Stage 1 plan. It's good, more detail than I expected. The geoservices catch
is one we would have missed completely, it only exists in appsettings.json so it shows up in
no configmap and no Octopus variable.

Three things to fix before the app team sees it.

1. Production is on 0.1.39, not 0.1.38. The image was pushed 8 Oct and the deployment is 11
days old. Matt said the same on the call. Question 1's default of "use 0.1.38 stable" would
put a year old build on prem.

2. Mongo is not port 27017 and not an external host. It goes through an AWS PrivateLink
endpoint on ports 1024-1026, at 10.16.6.113. A firewall request for 27017 gets approved and
does nothing. The real blocker is a security group, sg-0c8f8db29b16a1477, which only allows
10.16.0.0/20. The network from the datacenter into that VPC already exists and is routed, I
traced every hop. It needs one rule - TCP 1024-1026 from 10.10.82.0/24. The group belongs to
the Octopus project tagged mongodb in the USXpress space, so it is not ours to change.

3. Section 4a has the Octopus variable names, not the names the app reads. Octopus holds
usx_db_bmd_server, the container receives UsXpressSqlConfiguration__Bmd__Server. The DX chart
renders them. If the values file uses the Octopus names the pod starts, passes its probes and
runs entirely on its defaults, with no error anywhere. Same for the password keys in the
ExternalSecret.

Four of your open questions I can answer from prod.

Q3 - the Mongo cert secret is pricing-rfp-handler-m-u. Your guess was right. It holds ca.crt,
tls.crt, tls.key and tls-combined.pem.

Q4 - the Kafka creds are created by DX. On the api side they still carry the dx-- prefix in
the name. You plan to seed 2 keys, the app receives 10, and the three schema registry ones
are missing from the plan. Worth getting right - a partial secret syncs green and the pod
dies at container creation with zero restarts, so nothing alerts.

Q6 - yes. About 25 variables come from the DX chart and exist in no Octopus project. That
includes the health check port 13372 your own success criteria need, a prometheus endpoint on
12342, and pyroscope, which isn't in the plan at all.

Q8 - prod has no separate knxapi_domain, only the base address.

Two things you can take off the list. ECR already grants pull to anything in the AWS org, so
there is no pull grant to build. And the service account has no IRSA annotation, so there is
no AWS role to recreate.

One to think about rather than answer. Q10 on the consumer group isn't a config preference.
Same group means Kafka splits the partitions and half the work quietly moves on prem. New
group means both clusters process every message, so the Mongo writes and the Knight Swift
calls happen twice. The app team should pick knowing that. Also the prod consumer group
literal is dx__pricing_pricing_rfp_handler_knx_pricing - prefixed. Read the rendered
configmap in dev before writing the ACL, not the Octopus variable, or the grant won't match
the group the app joins.

All of that is measured on prod, read only. Dev may differ legitimately so check dev's own
configmap. Full detail and the commands are written up, I'll share the link.
