# FortiAIGate EKS Cost Notes

## FortiAIGate 8.0.0 Hardware Prerequisites

From the [FortiAIGate 8.0.0 Administration Guide](https://docs.fortinet.com/document/fortiaigate/8.0.0/fortiaigate-administration-guide/512071/fortiaigate-deployment):

| | Minimum | Recommended |
|---|---|---|
| vCPU | 4 | 24 |
| RAM | 25 GB | 70 GB |
| GPU | 1× 24 GB VRAM | 2× 24 GB VRAM |
| Storage | 250 GB NVMe | — |
| Kubernetes | 1.25.0+ | — |

Supported GPU models: NVIDIA L4, A10, A100 (driver 535+). Note: NVIDIA T4 (16 GB VRAM) does **not** meet the 24 GB minimum and is not listed as supported.

---

## Current Deployment (build0024)

Defined in `build0024/deployment/deploy/eksctl/fortiaigate-eksctl-full.yaml`.

| Node group | Instance | Count | vCPU | RAM | GPU | Storage |
|---|---|---|---|---|---|---|
| fortiaigate-app-ng | m7i.4xlarge | 2 | 16 | 64 GB | — | 120 GB |
| fortiaigate-gpu-ng | g5.4xlarge | 1 | 16 | 64 GB | 1× A10G 24 GB | 350 GB |

The two app nodes run all CPU services (api, core, webui, logd, scanners, license-manager, PostgreSQL, Redis). The GPU node runs Triton exclusively. Each app node requires its own FortiAIGate license; the GPU node does not.

---

## Cost Optimisation Analysis

### GPU node — safe to downsize

All three single-GPU g5 variants carry the same A10G (24 GB VRAM). The current g5.4xlarge is significantly over-provisioned for Triton, whose resource limits in `build0024/deployment/fortiaigate/values.yaml` are 2 CPU / 20 Gi RAM:

| Instance | vCPU | RAM | Approx. on-demand (us-east-1) | Notes |
|---|---|---|---|---|
| g5.xlarge | 4 | 16 GB | ~$1.01/hr | RAM below Triton's 20 Gi limit — avoid |
| **g5.2xlarge** | **8** | **32 GB** | **~$1.21/hr** | **Fits Triton comfortably — recommended** |
| g5.4xlarge *(current)* | 16 | 64 GB | ~$1.62/hr | Over-provisioned for Triton |

**Recommendation:** replace g5.4xlarge with g5.2xlarge. Same GPU, same storage, ~$0.41/hr saving (~$300/month). No application changes required — only update `instanceType` in the eksctl config and rebuild the GPU node group.

### App nodes — leave as-is pending load testing

The docs' minimum specs (4 vCPU / 25 GB RAM) describe a single-node all-in-one deployment, making it difficult to determine how headroom divides across two nodes without real traffic data. The m7i.2xlarge (8 vCPU / 32 GB) is a plausible downsize candidate but should only be considered after validating the deployment under representative load.

---

## To Apply the GPU Node Downsize

1. Update `instanceType` in `build0024/deployment/deploy/eksctl/fortiaigate-eksctl-full.yaml`:
   ```yaml
   - name: fortiaigate-gpu-ng
     instanceType: g5.2xlarge   # was g5.4xlarge
   ```
2. Drain and delete the existing GPU node group, then recreate it:
   ```bash
   eksctl delete nodegroup --cluster fortiaigate-eks --name fortiaigate-gpu-ng --region us-east-1
   eksctl create nodegroup --config-file build0024/deployment/deploy/eksctl/fortiaigate-eksctl-full.yaml --include fortiaigate-gpu-ng
   ```
3. Re-run `make nvidia-device-plugin` to ensure the device plugin rolls out onto the new node.
4. Triton will reschedule automatically once the node is ready.
