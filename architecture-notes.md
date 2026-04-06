# FortiAIGate Architecture Notes

## API and Core: Control Plane vs Data Plane

**core** is the AI gateway data plane. It handles live LLM traffic — proxying requests,
applying scanning policies, and enforcing flow rules. Requests to `/v1/*` (the
OpenAI-compatible path) route here. This is what you hit when running curl tests.

**api** is the management/admin control plane backend. It serves the web UI's
configuration and observability needs — for example `/api/ai-flow` (flow management)
and `/api/summary/all?timeRange=24h` (dashboard metrics). It is not in the path of
live LLM traffic.

This maps to a standard data plane / control plane split: core does the work, api
manages how core is configured and reports on what it has done.

## PostgreSQL

Used for durable relational storage by the **core**, **api**, and **logd** services.
Likely holds scan results, request logs, user/configuration data, and audit records.

Deployed as the Bitnami PostgreSQL subchart (standalone primary) with TLS enabled.
On EKS it uses its own `ReadWriteOnce` PVC backed by `efs-sc-stateful` (20 Gi).
The stateful storage class is distinct from the shared application one: it enforces
UID/GID 1001 at the EFS access point level to match the Bitnami container's user,
avoiding `initdb` ownership check failures that would occur with the app storage class.

An external database (e.g. RDS) can be substituted by disabling the subchart and
configuring `externalDatabase`.

## Redis

Used by the **core**, **api**, **logd**, and **license-manager** services.
The license-manager is the only component that uses Redis but *not* Postgres,
suggesting Redis carries distributed coordination state — likely license token
presence/validity across nodes — in addition to whatever caching or job-queue
duties it serves for the other three services.

Deployed as the Bitnami Redis subchart (standalone) with TLS enabled.
On EKS it uses its own `ReadWriteOnce` PVC backed by `efs-sc-stateful` (8 Gi).
Connection pool size is set to 10 (`REDIS_POOL_SIZE`).

An external Redis (e.g. ElastiCache) can be substituted by disabling the subchart
and configuring `externalRedis`.

## Triton Inference Server

NVIDIA Triton Inference Server is the GPU-accelerated inference backend for all
AI content-scanning capabilities. It is only deployed when `fortiaigate.gpu.enabled: true`.

An init container (`triton-models`) copies ONNX model files into a shared `emptyDir`
volume at pod startup. Triton then serves those models from `/models`.

The scanner services connect to Triton via gRPC using the internal cluster address
`dns:///triton-server:8001`. The Triton Service is headless (`clusterIP: None`) so
DNS resolves directly to pod IPs, enabling client-side load balancing.

**Models served:**

| Model | Scanner pod | User-facing feature |
|---|---|---|
| `prompt_injection_model` | promptinjection-scanner | Prompt Injection detection |
| `toxicity_model` | toxicity-scanner | Toxicity prevention |
| `sensitive_model` | sensitive-scanner | Data Leak Prevention (DLP) |
| `language_model` | language-scanner | (underlying DLP/content analysis) |
| `code_model` | code-scanner | (underlying DLP/content analysis) |

Note: the chart also deploys `anonymize`, `deanonymize`, and `customrule` scanner pods
which do not have corresponding Triton models — these run without GPU inference.

All models use the ONNX Runtime platform. The prompt injection model additionally
uses TensorRT acceleration (FP32 precision) with dynamic batching (preferred batch
sizes 8 and 16, max queue delay 2 ms) and cached engine builds. The remaining models
have simpler configurations (max batch size 16, no explicit batching tuning).

Triton has a dedicated `gpuWorkloadPlacement` so it can be scheduled onto GPU nodes
separately from the CPU-only workloads. Resources default to 1 `nvidia.com/gpu`,
2 CPU cores, and 20 Gi RAM. `CUDA_VISIBLE_DEVICES=0` pins it to a single GPU.
Supported GPU models per Fortinet documentation: NVIDIA L4, A10, A100 (driver 535+).
GPU support is optional — if disabled the scanners fall back to CPU inference, with
significantly reduced throughput.

All inference is performed entirely within the cluster. No data is sent to external
Fortinet APIs for AI processing.

## EFS Mounts (AWS EKS)

Two EFS-backed StorageClasses are defined:

**`efs-sc`** — used for the shared application PVC (`fortiaigate-storage`, default 100 Gi).
This volume is mounted at `/etc/fortiaigate/` by **core**, **api**, **logd**, and
**license-manager**. `ReadWriteMany` access mode means all pods share the same
volume simultaneously — appropriate for shared configuration, license files, and
any other runtime data that needs to be accessible across multiple replicas.
Permissions are enforced via a GID range (10001–20000) matching the application
containers' `fsGroup`.

**`efs-sc-stateful`** — used for the PostgreSQL and Redis PVCs (`ReadWriteOnce`).
This storage class enforces UID/GID 1001 at the EFS access point, matching the
Bitnami container user. This is necessary because the EFS CSI driver squashes root
`chown` calls (the `volumePermissions` init container cannot change ownership), so
correct ownership must be established at the access point level instead.
