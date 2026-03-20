# FortiAIGate on Amazon EKS

This directory contains FortiAIGate container image archives, a packaged Helm chart, and a patched local Helm chart. This README explains what the files appear to be, what was patched in the chart for EKS, and a practical deployment path using `eksctl`.

This guidance is based on local inspection of the files in this directory and AWS documentation current on March 20, 2026.

## What Is In This Folder

### Product image archives

These tar files are saved OCI or Docker image archives:

| File | Image inside archive | Notes |
| --- | --- | --- |
| `FAIG_api-V8.0.0-build0021-FORTINET.tar` | `api:V8.0.0-build0021` | FortiAIGate API service |
| `FAIG_core-V8.0.0-build0021-FORTINET.tar` | `core:V8.0.0-build0021` | Main backend service |
| `FAIG_webui-V8.0.0-build0021-FORTINET.tar` | `webui:V8.0.0-build0021` | Web UI |
| `FAIG_logd-V8.0.0-build0021-FORTINET.tar` | `logd:V8.0.0-build0021` | Logging service |
| `FAIG_license_manager-V8.0.0-build0021-FORTINET.tar` | `license_manager:V8.0.0-build0021` | License manager |
| `FAIG_scanner-V8.0.0-build0021-FORTINET.tar` | `scanner:V8.0.0-build0021` | Shared image used by all scanner Deployments |
| `FAIG_custom-triton-V8.0.0-build0021-FORTINET.tar` | `custom-triton:25.11-onnx-trt-agt` | Triton inference server image |
| `FAIG_triton-models-V8.0.0-build0021-FORTINET.tar` | `triton-models:0.1.4` | Model repository image loaded by Triton init container |

Approximate archive sizes:

| File | Size |
| --- | --- |
| `FAIG_api-V8.0.0-build0021-FORTINET.tar` | 2.11 GB |
| `FAIG_core-V8.0.0-build0021-FORTINET.tar` | 2.17 GB |
| `FAIG_custom-triton-V8.0.0-build0021-FORTINET.tar` | 9.68 GB |
| `FAIG_license_manager-V8.0.0-build0021-FORTINET.tar` | 737 MB |
| `FAIG_logd-V8.0.0-build0021-FORTINET.tar` | 1.48 GB |
| `FAIG_scanner-V8.0.0-build0021-FORTINET.tar` | 5.68 GB |
| `FAIG_triton-models-V8.0.0-build0021-FORTINET.tar` | 3.63 GB |
| `FAIG_webui-V8.0.0-build0021-FORTINET.tar` | 267 MB |

The total compressed footprint is about 25.8 GB, so give the GPU node a large root volume.

### Helm chart artifacts

| File or directory | What it is |
| --- | --- |
| `FAIG_helm_chart-V8.0.0-build0021-FORTINET.tar` | Original packaged Helm chart from Fortinet |
| `fortiaigate/` | Patched local Helm chart. I copied the packaged chart's vendored `charts/` and `files/` into this directory and then patched the templates for EKS use. |

## What Was Patched In The Local Chart

The local `fortiaigate/` chart is the recommended deployment artifact now. It has these EKS-oriented changes:

1. Scheduling is label-based instead of hostname-based.
   The original chart tied workloads to `global.licenses` and `kubernetes.io/hostname`. The patched chart adds placement blocks so you can target stable node labels instead.

2. TLS is injectable.
   You can now use an existing Kubernetes TLS Secret with `tls.existingSecret`, or inline PEM material with `tls.certData` and `tls.keyData`.

3. Licenses are injectable.
   You can now use an existing ConfigMap with `license.existingConfigMap`, inline license text with `license.data`, or the old file-based method for compatibility.

4. External PostgreSQL and Redis are supported.
   The chart now has `externalDatabase` and `externalRedis` blocks, plus Secret-backed TLS bundle mounts for external CA and optional client certificates.

5. Release-name fragility is reduced.
   The main chart now computes its own storage claim and secret names consistently. The bundled PostgreSQL and Redis subcharts still need matching `existingClaim` values, so the example keeps `fullnameOverride: fortiaigate` and `storage.claimName: fortiaigate-storage`.

6. TLS handling is cleaner.
   The chart only creates its own TLS Secret when the release actually needs one.

## Generated Deployment Assets

This directory now includes:

- `deploy/eksctl/fortiaigate-eksctl.yaml`
- `deploy/helm/values-eks.yaml`
- `deploy/helm/values-eks-external-services.yaml`
- `deploy/helm/aws-load-balancer-controller-values.yaml`
- `deploy/manifests/fortiaigate-namespace.yaml`
- `deploy/manifests/efs-storageclass.yaml`
- `deploy/manifests/fortiaigate-tls-secret.yaml`
- `deploy/manifests/fortiaigate-license-config.yaml`
- `deploy/manifests/fortiaigate-external-postgres.yaml`
- `deploy/manifests/fortiaigate-external-redis.yaml`

## Recommended First Deployment Shape

Use this layout for the initial deployment:

- One EKS cluster created by `eksctl`
- One fixed-size app node group for FortiAIGate CPU services, PostgreSQL, Redis, and cluster add-ons
- One fixed-size GPU node group for Triton
- A taint on the GPU node group so only explicitly tolerated workloads land there
- Amazon EFS for the shared RWX storage claim
- AWS Load Balancer Controller for the Ingress
- Amazon ECR repositories holding the FortiAIGate images
- TLS injected from a Kubernetes Secret
- Licenses injected from a Kubernetes ConfigMap

Keep the node groups fixed until you understand the product's node-to-license mapping. The current best guess is that license files are selected by node name via the `license-manager` DaemonSet.

## First Test Checklist

Use this order for the first end-to-end test:

1. Update [fortiaigate-eksctl.yaml](/home/robert/cFOS/FortiAIGate/images/deploy/eksctl/fortiaigate-eksctl.yaml) with your Region, cluster name, and preferred instance sizes.
2. Create the EKS cluster with `eksctl create cluster -f deploy/eksctl/fortiaigate-eksctl.yaml`.
3. Create the ECR repositories, `docker load` the FortiAIGate image archives, retag them, and push them to ECR.
4. Install the AWS Load Balancer Controller using [aws-load-balancer-controller-values.yaml](/home/robert/cFOS/FortiAIGate/images/deploy/helm/aws-load-balancer-controller-values.yaml).
5. Create EFS, update [efs-storageclass.yaml](/home/robert/cFOS/FortiAIGate/images/deploy/manifests/efs-storageclass.yaml) with the real file system ID, and apply the namespace and StorageClass manifests.
6. Get the real node names with `kubectl get nodes -o custom-columns=NAME:.metadata.name` and build the license ConfigMap from those names.
7. Create the FortiAIGate TLS Secret and license ConfigMap.
8. Update [values-eks.yaml](/home/robert/cFOS/FortiAIGate/images/deploy/helm/values-eks.yaml) with your ECR prefix, hostname, and ACM certificate ARN.
9. If you want RDS and ElastiCache for the first test, also apply [fortiaigate-external-postgres.yaml](/home/robert/cFOS/FortiAIGate/images/deploy/manifests/fortiaigate-external-postgres.yaml), [fortiaigate-external-redis.yaml](/home/robert/cFOS/FortiAIGate/images/deploy/manifests/fortiaigate-external-redis.yaml), and install with [values-eks-external-services.yaml](/home/robert/cFOS/FortiAIGate/images/deploy/helm/values-eks-external-services.yaml).
10. Run a final dry render with `helm template`, then install with `helm upgrade --install`.
11. Validate pod placement, PVC binding, ALB creation, and license-manager behavior before changing node counts.

## Prerequisites

Install or verify:

- `aws` CLI
- `eksctl`
- `kubectl`
- `helm`
- `docker`

Verify AWS identity and Region:

```bash
aws sts get-caller-identity
aws configure list
```

Export a few shell variables used throughout the steps:

```bash
export AWS_REGION=us-west-2
export CLUSTER_NAME=fortiaigate-eks
export NAMESPACE=fortiaigate
export AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
export ECR_REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
export ECR_PREFIX="${ECR_REGISTRY}/fortiaigate"
```

## Step 1: Review The `eksctl` Cluster Config

Start with `deploy/eksctl/fortiaigate-eksctl.yaml`.

Update at least:

- cluster name
- Region
- VPC/subnet settings if you aren't letting `eksctl` create the VPC
- instance types
- node counts

The sample config uses:

- Kubernetes `1.35`
- two fixed app nodes labeled `fortiaigate-role=app`
- one fixed GPU node labeled `fortiaigate-role=gpu`
- a GPU taint `fortiaigate-gpu=true:NoSchedule`
- the EFS CSI add-on

Create the cluster:

```bash
eksctl create cluster -f deploy/eksctl/fortiaigate-eksctl.yaml
```

Check nodes after creation:

```bash
kubectl get nodes -o wide
kubectl get nodes --show-labels
```

## Step 2: Create ECR Repositories

The chart expects a shared repository prefix and appends image names like `/api`, `/core`, and `/scanner`.

Create the repositories:

```bash
for repo in \
  fortiaigate/api \
  fortiaigate/core \
  fortiaigate/webui \
  fortiaigate/logd \
  fortiaigate/license_manager \
  fortiaigate/scanner \
  fortiaigate/custom-triton \
  fortiaigate/triton-models

do
  aws ecr create-repository --repository-name "${repo}" --region "${AWS_REGION}" >/dev/null || true
done
```

## Step 3: Load The Image Archives And Push Them To ECR

Authenticate Docker to ECR:

```bash
aws ecr get-login-password --region "${AWS_REGION}" | \
  docker login --username AWS --password-stdin "${ECR_REGISTRY}"
```

Load the archives:

```bash
docker load -i FAIG_api-V8.0.0-build0021-FORTINET.tar
docker load -i FAIG_core-V8.0.0-build0021-FORTINET.tar
docker load -i FAIG_webui-V8.0.0-build0021-FORTINET.tar
docker load -i FAIG_logd-V8.0.0-build0021-FORTINET.tar
docker load -i FAIG_license_manager-V8.0.0-build0021-FORTINET.tar
docker load -i FAIG_scanner-V8.0.0-build0021-FORTINET.tar
docker load -i FAIG_custom-triton-V8.0.0-build0021-FORTINET.tar
docker load -i FAIG_triton-models-V8.0.0-build0021-FORTINET.tar
```

Retag and push:

```bash
docker tag dops-jfrog.fortinet-us.com/docker-fortiaigate-local/api:V8.0.0-build0021 \
  "${ECR_PREFIX}/api:V8.0.0-build0021"
docker push "${ECR_PREFIX}/api:V8.0.0-build0021"

docker tag dops-jfrog.fortinet-us.com/docker-fortiaigate-local/core:V8.0.0-build0021 \
  "${ECR_PREFIX}/core:V8.0.0-build0021"
docker push "${ECR_PREFIX}/core:V8.0.0-build0021"

docker tag dops-jfrog.fortinet-us.com/docker-fortiaigate-local/webui:V8.0.0-build0021 \
  "${ECR_PREFIX}/webui:V8.0.0-build0021"
docker push "${ECR_PREFIX}/webui:V8.0.0-build0021"

docker tag dops-jfrog.fortinet-us.com/docker-fortiaigate-local/logd:V8.0.0-build0021 \
  "${ECR_PREFIX}/logd:V8.0.0-build0021"
docker push "${ECR_PREFIX}/logd:V8.0.0-build0021"

docker tag dops-jfrog.fortinet-us.com/docker-fortiaigate-local/license_manager:V8.0.0-build0021 \
  "${ECR_PREFIX}/license_manager:V8.0.0-build0021"
docker push "${ECR_PREFIX}/license_manager:V8.0.0-build0021"

docker tag dops-jfrog.fortinet-us.com/docker-fortiaigate-local/scanner:V8.0.0-build0021 \
  "${ECR_PREFIX}/scanner:V8.0.0-build0021"
docker push "${ECR_PREFIX}/scanner:V8.0.0-build0021"

docker tag dops-jfrog.fortinet-us.com/docker-fortiaigate-local/custom-triton:25.11-onnx-trt-agt \
  "${ECR_PREFIX}/custom-triton:25.11-onnx-trt-agt"
docker push "${ECR_PREFIX}/custom-triton:25.11-onnx-trt-agt"

docker tag dops-jfrog.fortinet-us.com/docker-fortiaigate-local/triton-models:0.1.4 \
  "${ECR_PREFIX}/triton-models:0.1.4"
docker push "${ECR_PREFIX}/triton-models:0.1.4"
```

Because your cluster has outbound internet access, the first deployment can continue pulling the bundled PostgreSQL and Redis images from Docker Hub.

## Step 4: Install The AWS Load Balancer Controller

AWS's current EKS guide still uses a Helm install and a dedicated IAM service account.

Create the IAM policy:

```bash
curl -O https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.14.1/docs/install/iam_policy.json

aws iam create-policy \
  --policy-name AWSLoadBalancerControllerIAMPolicy \
  --policy-document file://iam_policy.json
```

Create the IAM service account:

```bash
eksctl create iamserviceaccount \
  --cluster "${CLUSTER_NAME}" \
  --namespace kube-system \
  --name aws-load-balancer-controller \
  --attach-policy-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:policy/AWSLoadBalancerControllerIAMPolicy" \
  --override-existing-serviceaccounts \
  --region "${AWS_REGION}" \
  --approve
```

Review `deploy/helm/aws-load-balancer-controller-values.yaml` and update:

- `clusterName`
- `region`
- `vpcId`

Install the controller:

```bash
helm repo add eks https://aws.github.io/eks-charts
helm repo update eks

helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  -f deploy/helm/aws-load-balancer-controller-values.yaml \
  --version 1.14.0
```

If you later upgrade this chart with `helm upgrade`, apply the CRDs first:

```bash
wget https://raw.githubusercontent.com/aws/eks-charts/master/stable/aws-load-balancer-controller/crds/crds.yaml
kubectl apply -f crds.yaml
```

Verify the controller:

```bash
kubectl get deployment -n kube-system aws-load-balancer-controller
```

## Step 5: Create EFS And The StorageClass

Get the VPC and subnet information:

```bash
export VPC_ID="$(aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${AWS_REGION}" --query 'cluster.resourcesVpcConfig.vpcId' --output text)"
export VPC_CIDR="$(aws ec2 describe-vpcs --vpc-ids "${VPC_ID}" --region "${AWS_REGION}" --query 'Vpcs[0].CidrBlock' --output text)"
```

Create a security group for EFS:

```bash
export EFS_SG_ID="$(aws ec2 create-security-group \
  --group-name "${CLUSTER_NAME}-efs" \
  --description "EFS for ${CLUSTER_NAME}" \
  --vpc-id "${VPC_ID}" \
  --region "${AWS_REGION}" \
  --query GroupId --output text)"

aws ec2 authorize-security-group-ingress \
  --group-id "${EFS_SG_ID}" \
  --protocol tcp \
  --port 2049 \
  --cidr "${VPC_CIDR}" \
  --region "${AWS_REGION}"
```

Create the EFS file system:

```bash
export EFS_FS_ID="$(aws efs create-file-system \
  --region "${AWS_REGION}" \
  --encrypted \
  --performance-mode generalPurpose \
  --throughput-mode elastic \
  --tags Key=Name,Value=${CLUSTER_NAME}-fortiaigate \
  --query FileSystemId --output text)"
```

Create mount targets in the private subnets used by your nodes:

```bash
for subnet in $(aws eks describe-cluster \
  --name "${CLUSTER_NAME}" \
  --region "${AWS_REGION}" \
  --query 'cluster.resourcesVpcConfig.subnetIds[]' \
  --output text)
do
  aws efs create-mount-target \
    --file-system-id "${EFS_FS_ID}" \
    --subnet-id "${subnet}" \
    --security-groups "${EFS_SG_ID}" \
    --region "${AWS_REGION}"
done
```

Update `deploy/manifests/efs-storageclass.yaml` and replace `fs-REPLACE_ME` with your real file system ID.

Create the namespace and StorageClass:

```bash
kubectl apply -f deploy/manifests/fortiaigate-namespace.yaml
kubectl apply -f deploy/manifests/efs-storageclass.yaml
```

## Step 6: Inject TLS And Licensing

### Option A: Use the example manifest files

Edit these files:

- `deploy/manifests/fortiaigate-tls-secret.yaml`
- `deploy/manifests/fortiaigate-license-config.yaml`

Then apply them:

```bash
kubectl apply -f deploy/manifests/fortiaigate-tls-secret.yaml
kubectl apply -f deploy/manifests/fortiaigate-license-config.yaml
```

### Option B: Create them directly from your real files

Create the TLS Secret from PEM files:

```bash
kubectl create secret tls fortiaigate-tls-secret \
  --namespace "${NAMESPACE}" \
  --cert /path/to/tls.crt \
  --key /path/to/tls.key \
  --dry-run=client -o yaml | kubectl apply -f -
```

Create the license ConfigMap from license files. The filename on the left side of each `--from-file` must be the Kubernetes node name that should consume that license:

```bash
kubectl create configmap fortiaigate-license-config \
  --namespace "${NAMESPACE}" \
  --from-file=ip-10-0-1-10.us-west-2.compute.internal=/path/to/app-node-1.lic \
  --from-file=ip-10-0-2-10.us-west-2.compute.internal=/path/to/app-node-2.lic \
  --from-file=ip-10-0-3-10.us-west-2.compute.internal=/path/to/gpu-node-1.lic \
  --dry-run=client -o yaml | kubectl apply -f -
```

List the actual node names with:

```bash
kubectl get nodes -o custom-columns=NAME:.metadata.name
```

Current best guess on licensing behavior:

- `license-manager` runs as a DaemonSet
- it exports `NODE_NAME` from `spec.nodeName`
- license files are mounted from a ConfigMap into `/etc/licenses`
- the ConfigMap keys probably need to match Kubernetes node names for every node that runs a `license-manager` pod

Because the Service uses `internalTrafficPolicy: Local`, keep `license_manager.placement` wide enough that every node running FortiAIGate pods also runs `license-manager`.

## Step 7: Review Helm Values

Edit `deploy/helm/values-eks.yaml` and replace at least:

- ECR repository prefix
- ALB host name
- ACM certificate ARN
- storage sizing if needed
- any placement labels or tolerations if you change the node group labels

This values file is already aligned to the patched chart and does these things:

- sends CPU workloads to nodes labeled `fortiaigate-role=app`
- sends Triton to nodes labeled `fortiaigate-role=gpu`
- tolerates the GPU taint only where needed
- mounts a pre-created TLS Secret
- mounts a pre-created license ConfigMap
- keeps PostgreSQL and Redis on the app node group
- uses the EFS-backed shared claim `fortiaigate-storage`

## Step 8: Install FortiAIGate

Render the chart once before applying it:

```bash
helm template fortiaigate ./fortiaigate \
  --namespace "${NAMESPACE}" \
  -f deploy/helm/values-eks.yaml >/tmp/fortiaigate-render.yaml
```

Install the release:

```bash
helm upgrade --install fortiaigate ./fortiaigate \
  --namespace "${NAMESPACE}" \
  --create-namespace \
  -f deploy/helm/values-eks.yaml
```

## Step 9: Validate The Deployment

Check the pods and where they landed:

```bash
kubectl get pods -n "${NAMESPACE}" -o wide
kubectl get daemonset -n "${NAMESPACE}" license-manager
kubectl get pvc -n "${NAMESPACE}"
kubectl get ingress -n "${NAMESPACE}"
```

Useful focused checks:

```bash
kubectl describe pod -n "${NAMESPACE}" deploy/triton-server
kubectl logs -n "${NAMESPACE}" deploy/api
kubectl logs -n "${NAMESPACE}" deploy/core
kubectl logs -n "${NAMESPACE}" daemonset/license-manager
```

## Optional Next Step: Move PostgreSQL And Redis Out Of Cluster

For a production layout, I would move the stateful dependencies out of EKS.

The repository now includes an overlay and example Secrets for that path:

- `deploy/helm/values-eks-external-services.yaml`
- `deploy/manifests/fortiaigate-external-postgres.yaml`
- `deploy/manifests/fortiaigate-external-redis.yaml`

The overlay does these things:

1. Sets `postgresql.enabled: false`.
2. Sets `redis.enabled: false`.
3. Enables `externalDatabase` with an RDS-style endpoint and password Secret.
4. Enables `externalRedis` with an ElastiCache-style endpoint and password Secret.
5. Mounts CA bundles for both services from Kubernetes Secrets.

Apply the example Secrets after replacing the placeholders:

```bash
kubectl apply -f deploy/manifests/fortiaigate-external-postgres.yaml
kubectl apply -f deploy/manifests/fortiaigate-external-redis.yaml
```

Install or upgrade using both values files:

```bash
helm upgrade --install fortiaigate ./fortiaigate \
  --namespace "${NAMESPACE}" \
  --create-namespace \
  -f deploy/helm/values-eks.yaml \
  -f deploy/helm/values-eks-external-services.yaml
```

This external-services path should work adequately if these assumptions hold:

1. RDS is presented as a single reachable host and port.
2. ElastiCache is used in a simple single-endpoint mode rather than a topology that requires Sentinel or Redis Cluster discovery.
3. The FortiAIGate containers either trust the mounted CA bundle path or do not require mutual TLS unless you provide optional `tls.crt` and `tls.key` entries in the external TLS Secrets.

Operational note:

- Changing `fortiaigate-external-postgres-tls` or `fortiaigate-external-redis-tls` will not automatically restart the FortiAIGate pods. After rotating those Secrets, run a `helm upgrade` again or restart the affected Deployments and the `license-manager` DaemonSet.

## Remaining Risks And Assumptions

1. Licensing is still the least certain part.
   The chart is now more flexible, but the underlying application logic still appears to care about node names.

2. Fixed node counts are safer until licensing is confirmed.
   If an app or GPU node is replaced and its name changes, you may need to update the license ConfigMap.

3. The bundled PostgreSQL and Redis are good for bring-up, not my preferred production shape.
   External RDS and ElastiCache are cleaner operationally.

4. The image set is large.
   Slow pulls and node disk pressure are real risks if root volumes are too small.

## AWS References Used

- EKS GPU support with `eksctl`: https://docs.aws.amazon.com/eks/latest/eksctl/gpu-support.html
- EFS CSI driver on EKS: https://docs.aws.amazon.com/eks/latest/userguide/efs-csi.html
- Install AWS Load Balancer Controller with Helm: https://docs.aws.amazon.com/eks/latest/userguide/lbc-helm.html
- Push images to ECR: https://docs.aws.amazon.com/AmazonECR/latest/userguide/image-push.html
