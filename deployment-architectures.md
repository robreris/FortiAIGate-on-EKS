# FortiAIGate Deployment Architectures

## 1. Single-Node GPU Test Cluster (`helm-install-test-gpu`)

```
                        kubectl port-forward
                       +--------------------+
Your machine           |                    |         Single EKS Node
                       |                    |         (fortiaigate-role: app)
 make local-proxy      |                    |        +----------------------+
 localhost:9443  ------+---> webui  :8443   |------> | webui               |
   /api/*        ------+---> api    :18443  |------> | api                 |
   /v1/*         ------+---> core   :28443  |------> | core                |
                       |                    |        | logd                |
                       +--------------------+        | license-manager     |
                                                     | scanners (x8)       |
                                                     | triton-server (GPU) |
                                                     |                     |
                                                     | postgresql (EFS)    |
                                                     | redis      (EFS)    |
                                                     +----------------------+
```

All workloads — CPU services, Triton, and the stateful dependencies — share a single
GPU-capable node. Triton and the app services use the same `fortiaigate-role: app`
node selector so everything collocates. Access is via `make port-forwards` +
`make local-proxy`; there is no ingress. This is the current configuration and is
suited for development and functional testing. A single Fortinet license is required,
with the license key set to the Kubernetes node name it is assigned to.

---

## 2. Multi-Node GPU Cluster (`helm-install-full`)

```
                                              EKS Cluster
                        +--------------------------------------------------+
                        |                                                  |
Internet                |   App Node Group (fortiaigate-role: app)         |
                        |  +--------------------------------------------+ |
  HTTPS :443            |  | webui  api  core  logd                     | |
    |                   |  | license-manager  scanners (x8)             | |
    v                   |  | postgresql (EFS)  redis (EFS)              | |
  ALB (ACM cert)        |  +--------------------------------------------+ |
    |                   |                                                  |
    | path-based        |   GPU Node Group (fortiaigate-role: gpu)         |
    | routing           |  +--------------------------------------------+ |
    +---> /api/*  ------+->| api                                        | |
    +---> /v1/*   ------+->| core                                       | |
    +---> /*      ------+->| webui                                      | |
                        |  | triton-server  (taint: fortiaigate-gpu)    | |
                        |  | license-manager (DaemonSet on both groups) | |
                        |  +--------------------------------------------+ |
                        +--------------------------------------------------+
```

CPU services run on the app node group and Triton is isolated to a dedicated GPU node
group (tainted `fortiaigate-gpu=true:NoSchedule`). The license-manager DaemonSet spans
both groups. An internet-facing ALB with an ACM certificate provides public HTTPS access
with the same `/api/`, `/v1/`, `/*` path routing that the local proxy mimics. License
activation is keyed to the Kubernetes node name via the ConfigMap, but whether per-node
enforcement applies (i.e., one license per node) is unconfirmed — see the Licensing
section in README.md.

---

## 3. External Stateful Services (`values-eks-external-services.yaml`)

```
                                              EKS Cluster
                        +----------------------------------+
                        |                                  |      AWS Managed Services
  ALB / port-forward    |  App / GPU Nodes                 |
         |              |  +----------------------------+  |   +------------------+
         |              |  | webui  api  core  logd     |  |-->| RDS (PostgreSQL) |
         +------------->|  | license-manager            |  |   +------------------+
                        |  | scanners  triton-server    |  |
                        |  +----------------------------+  |   +------------------+
                        |                                  |-->| ElastiCache      |
                        +----------------------------------+   | (Redis)          |
                                                               +------------------+
```

Identical to architecture 2 in terms of cluster topology, but the bundled PostgreSQL
and Redis subcharts are disabled and replaced with AWS-managed RDS and ElastiCache
instances. This is the production-recommended approach: it offloads persistence
durability, backups, and failover to managed services, leaving only stateless (or
Triton's ephemeral model-volume) workloads inside the cluster.
