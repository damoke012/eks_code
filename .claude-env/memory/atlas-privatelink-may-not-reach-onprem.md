---
name: atlas-privatelink-may-not-reach-onprem
description: "HYPOTHESIS 2026-10-20: a MongoDB Atlas host named mongodb-pl-N is the PrivateLink form, resolving to addresses inside the AWS VPC — so an app lifted on-prem may have no path to its database at all. Not yet measured"
metadata:
  type: project
---

⚠️ **This is a hypothesis, recorded as one.** It has not been measured, and a hypothesis
filed as a finding is how `green-hook-over-an-empty-cluster` survived weeks uncited but
believed.

**Measured part.** `pricing-rfp-handler` in cloud EKS prod connects to
`mongodb+srv://mongodb-pl-0.1cr18.mongodb.net/?authSource=$external&authMechanism=MONGODB-X509`
— X.509 client-certificate auth, no password in the URI, four TLS files delivered in the
secret `pricing-rfp-handler-m-u`.

**The inference.** In Atlas, a `-pl-` hostname is the **PrivateLink** connection form; it
resolves to private addresses inside the VPC that owns the endpoint. On-prem is not in that
VPC. If that holds, an application lifted on-prem **has no network path to its own database**,
and no amount of credential work fixes it.

**The test**, from an **op-dev** pod (never a prod cluster — no throwaway workloads there):
resolve the name, then attempt a TLS connection on 27017. `getent hosts` returning nothing for
an **SRV-only** name is expected and proves nothing by itself
([[risingwave-mongodb-sink-facts]]) — the connection attempt is the measurement.

**If confirmed**, the options are all decisions rather than configuration: a public Atlas
endpoint allow-listing the on-prem egress addresses, an Atlas PrivateLink into a network the
on-prem site reaches, or the application keeps using cloud for Mongo.

**How to apply.** When lifting any cloud app on-prem, read its datastore hostnames **before**
anything else and look for VPC-scoped forms — PrivateLink, VPC endpoints, internal Route 53
zones. A hostname that works everywhere in cloud can be unroutable from on-prem while every
credential is perfect.

Related: [[onprem-app-cicd]], [[envfrom-hides-the-inventory]], [[ask-the-registry-not-the-resolver]].
