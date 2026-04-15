# =============================================================================
# FortiAIGate EKS Deployment
# =============================================================================
#
# Select a build with BUILD=<build> (default: build0024):
#   BUILD=build0021  — single-node (legacy)
#   BUILD=build0024  — multi-node
#
# Test setup  — 1 app node, self-signed TLS, kubectl port-forward access:
#   make deploy-test
#
# Scanner test  — single-node GPU (build0021), Triton enabled, port-forward access:
#   BUILD=build0021 make deploy-test-gpu
#
# Two-node test  — 2 app nodes + GPU (build0024), port-forward access:
#   BUILD=build0024 make deploy-two-node
#
# Two-node full  — 2 app nodes + GPU (build0024), ALB ingress (fortiaigate.fortinetcloudcse.com):
#   ACM_CERT_ARN=arn:aws:acm:... make deploy-two-node-full
#
# Individual steps can be run on their own; run `make help` for the full list.
#
# NOTE: Each concurrent cluster must use a distinct CLUSTER_NAME. The eksctl
# YAMLs use REPLACE_CLUSTER_NAME as a placeholder; the Makefile injects
# CLUSTER_NAME at cluster-create time, so no manual YAML edits are needed.
# =============================================================================

# ── Build selection ───────────────────────────────────────────────────────────
# BUILD selects which build directory is active.
# build0021 is the legacy single-node build.
# build0024 and later are multi-node builds.
BUILD ?= build0024

BUILD_NUM  := $(patsubst build%,%,$(BUILD))
IMAGE_TAG  ?= V8.0.0-build$(BUILD_NUM)
IMAGES_DIR ?= $(BUILD)/images
CHART_DIR  ?= $(BUILD)/deployment/fortiaigate
DEPLOY_DIR ?= $(BUILD)/deployment/deploy

# ── Configuration ─────────────────────────────────────────────────────────────
AWS_REGION     ?= us-east-1
CLUSTER_NAME   ?= fortiaigate-eks
NAMESPACE      ?= fortiaigate

AWS_ACCOUNT_ID ?= $(shell aws sts get-caller-identity --query Account --output text 2>/dev/null)
ECR_REGISTRY   := $(AWS_ACCOUNT_ID).dkr.ecr.$(AWS_REGION).amazonaws.com
ECR_PREFIX     := $(ECR_REGISTRY)/fortiaigate

# Required by deploy-full / deploy-two-node-full / helm-install-full
ACM_CERT_ARN   ?= 
INGRESS_HOST   ?= fortiaigate.fortinetcloudcse.com

# Supply these when using the tls-from-files target instead of tls-self-signed
TLS_CERT       ?= certs/tls.crt
TLS_KEY        ?= certs/tls.key

# License file used by license-configmap (single-node, build0021); node name is auto-detected
LICENSE_FILE   ?= testing-licenses/FAIGCNSD26000146.lic

# License files for license-configmap-two-node (build0024); assigned in kubectl node-listing order
LICENSE_FILE_1 ?= testing-licenses/FAIGCNSD26000146.lic
LICENSE_FILE_2 ?= testing-licenses/FAIGCNSD26000198.lic

# Triton image tags — may differ between builds; override on the command line as needed
TRITON_TAG        ?= 25.11-onnx-trt-agt
TRITON_MODELS_TAG ?= 0.1.4

# ── Internal ──────────────────────────────────────────────────────────────────
HELM_RELEASE    := fortiaigate
EKSCTL_TEST     := $(DEPLOY_DIR)/eksctl/fortiaigate-eksctl.yaml
EKSCTL_TEST_GPU := $(DEPLOY_DIR)/eksctl/fortiaigate-eksctl-single-gpu.yaml
EKSCTL_FULL     := $(DEPLOY_DIR)/eksctl/fortiaigate-eksctl-full.yaml
VALUES_TEST     := $(DEPLOY_DIR)/helm/values-eks.yaml
VALUES_TEST_GPU := $(DEPLOY_DIR)/helm/values-eks-single-gpu-overlay.yaml
VALUES_FULL_OVR     := $(DEPLOY_DIR)/helm/values-eks-full-overlay.yaml
VALUES_TWO_NODE_OVR := $(DEPLOY_DIR)/helm/values-eks-two-node-overlay.yaml

FORTINET_REGISTRY := dops-jfrog.fortinet-us.com/docker-fortiaigate-local

# build0024+ requires global.licenses to be populated with actual node names so
# the per-node hostname nodeAffinity in the chart templates resolves correctly.
# `make license-values` generates this file from the live cluster.
LICENSE_VALUES_FILE := /tmp/fortiaigate-licenses.yaml

ARCHIVES := \
  FAIG_api-$(IMAGE_TAG)-FORTINET.tar \
  FAIG_core-$(IMAGE_TAG)-FORTINET.tar \
  FAIG_webui-$(IMAGE_TAG)-FORTINET.tar \
  FAIG_logd-$(IMAGE_TAG)-FORTINET.tar \
  FAIG_license_manager-$(IMAGE_TAG)-FORTINET.tar \
  FAIG_scanner-$(IMAGE_TAG)-FORTINET.tar \
  FAIG_custom-triton-$(IMAGE_TAG)-FORTINET.tar \
  FAIG_triton-models-$(IMAGE_TAG)-FORTINET.tar

.PHONY: help \
        deploy-test deploy-test-gpu deploy-two-node deploy-two-node-full deploy-full \
        cluster-test cluster-test-gpu cluster-full \
        ecr-repos \
        images-load images-push \
        alb-controller \
        nvidia-device-plugin \
        efs efs-delete namespace \
        tls-self-signed tls-from-files \
        license-configmap license-configmap-two-node license-values \
        helm-render helm-render-test-gpu \
        helm-install-test helm-install-test-gpu helm-install-two-node helm-install-full \
        port-forwards local-proxy admin-password \
        route53-alias \
        helm-uninstall cluster-delete \
        check-env check-env-full

# ── Help ──────────────────────────────────────────────────────────────────────
help:
	@printf '\nFortiAIGate EKS Deployment\n\n'
	@printf 'Active build: BUILD=%s  IMAGE_TAG=%s\n' "$(BUILD)" "$(IMAGE_TAG)"
	@printf '  IMAGES_DIR: %s\n' "$(IMAGES_DIR)"
	@printf '  CHART_DIR:  %s\n' "$(CHART_DIR)"
	@printf '  DEPLOY_DIR: %s\n\n' "$(DEPLOY_DIR)"
	@printf 'Composite targets:\n'
	@printf '  deploy-test          Full test setup: 1 app node, self-signed TLS, port-forward\n'
	@printf '  deploy-test-gpu      Single-node GPU test setup (build0021): Triton/scanners enabled, port-forward\n'
	@printf '  deploy-two-node      Two-node GPU deployment (build0024): 2 app nodes + GPU, port-forward\n'
	@printf '  deploy-two-node-full Two-node + ALB (build0024): 2 app nodes + GPU, ALB ingress (needs ACM_CERT_ARN)\n'
	@printf '  deploy-full          Full setup: 2 app nodes + GPU, ALB ingress (needs ACM_CERT_ARN)\n'
	@printf '\nCluster:\n'
	@printf '  cluster-test         Create single app-node cluster (%s)\n' "$(EKSCTL_TEST)"
	@printf '  cluster-test-gpu     Create single GPU-backed app-node cluster (%s)\n' "$(EKSCTL_TEST_GPU)"
	@printf '  cluster-full         Create full cluster — 2 app + 1 GPU node (%s)\n' "$(EKSCTL_FULL)"
	@printf '\nImages:\n'
	@printf '  ecr-repos            Create ECR repositories\n'
	@printf '  images-load          docker load all .tar archives from $(IMAGES_DIR)/\n'
	@printf '  images-push          Retag and push images to ECR\n'
	@printf '\nCluster resources:\n'
	@printf '  alb-controller       Install AWS Load Balancer Controller + IAM service account\n'
	@printf '  nvidia-device-plugin Install NVIDIA device plugin DaemonSet (exposes nvidia.com/gpu)\n'
	@printf '  efs                  Create EFS filesystem, security group, mount targets, StorageClass\n'
	@printf '  namespace            Create the $(NAMESPACE) namespace\n'
	@printf '\nSecrets and config:\n'
	@printf '  tls-self-signed      Generate self-signed cert and create K8s TLS secret\n'
	@printf '  tls-from-files       Create K8s TLS secret from TLS_CERT / TLS_KEY files\n'
	@printf '  license-configmap    Create license ConfigMap for single node (build0021)\n'
	@printf '  license-configmap-two-node  Create license ConfigMap for 2 app nodes (build0024)\n'
	@printf '  license-values       Generate %s with global.licenses from app nodes\n' "$(LICENSE_VALUES_FILE)"
	@printf '\nHelm:\n'
	@printf '  helm-render          Dry-run render to /tmp/fortiaigate-render.yaml\n'
	@printf '  helm-render-test-gpu Dry-run render to /tmp/fortiaigate-render-test-gpu.yaml\n'
	@printf '  helm-install-test    Install/upgrade with test values (ingress disabled)\n'
	@printf '  helm-install-test-gpu Install/upgrade with test values + single-GPU overlay (build0021)\n'
	@printf '  helm-install-two-node Install/upgrade with test values + two-node GPU overlay (build0024)\n'
	@printf '  helm-install-full    Install/upgrade with test + full-overlay values (ALB ingress)\n'
	@printf '  port-forwards        Start webui (8443), API (18443), and core (28443) port-forwards in background\n'
	@printf '  local-proxy          Extract TLS cert and start reverse proxy at https://localhost:9443\n'
	@printf '  admin-password       Reset the admin user password (prompts interactively)\n'
	@printf '  route53-alias        Create/update Route 53 alias A record for INGRESS_HOST -> ALB (ALB deploy only)\n'
	@printf '\nTeardown:\n'
	@printf '  helm-uninstall       Helm uninstall the release\n'
	@printf '  efs-delete           Delete EFS mount targets, filesystem, and security group\n'
	@printf '  cluster-delete       Delete the EKS cluster (asks for confirmation)\n'
	@printf '\nVariables (override with VAR=value on the command line):\n'
	@printf '  BUILD                %s\n' "$(BUILD)"
	@printf '  AWS_REGION           %s\n' "$(AWS_REGION)"
	@printf '  CLUSTER_NAME         %s\n' "$(CLUSTER_NAME)"
	@printf '  NAMESPACE            %s\n' "$(NAMESPACE)"
	@printf '  IMAGE_TAG            %s\n' "$(IMAGE_TAG)"
	@printf '  TRITON_TAG           %s\n' "$(TRITON_TAG)"
	@printf '  TRITON_MODELS_TAG    %s\n' "$(TRITON_MODELS_TAG)"
	@printf '  AWS_ACCOUNT_ID       %s\n' "$(AWS_ACCOUNT_ID)"
	@printf '  ECR_PREFIX           %s\n' "$(ECR_PREFIX)"
	@printf '  ACM_CERT_ARN         %s  (required for deploy-full)\n' "$(ACM_CERT_ARN)"
	@printf '  INGRESS_HOST         %s\n' "$(INGRESS_HOST)"
	@printf '  TLS_CERT / TLS_KEY   %s / %s  (for tls-from-files)\n' "$(TLS_CERT)" "$(TLS_KEY)"
	@printf '  LICENSE_FILE         %s  (single-node)\n' "$(LICENSE_FILE)"
	@printf '  LICENSE_FILE_1       %s  (two-node, node 1)\n' "$(LICENSE_FILE_1)"
	@printf '  LICENSE_FILE_2       %s  (two-node, node 2)\n' "$(LICENSE_FILE_2)"
	@printf '\n'

# ── Guards ────────────────────────────────────────────────────────────────────
check-env:
	@test -n "$(AWS_ACCOUNT_ID)" || \
	  (echo "ERROR: cannot detect AWS_ACCOUNT_ID — verify 'aws sts get-caller-identity' works"; exit 1)
	@test -n "$(AWS_REGION)" || \
	  (echo "ERROR: AWS_REGION is not set"; exit 1)

check-env-full: check-env
	@test -n "$(ACM_CERT_ARN)" || \
	  (echo "ERROR: ACM_CERT_ARN is required for the full setup"; exit 1)

# ── Composite targets ─────────────────────────────────────────────────────────
deploy-test: cluster-test \
             efs \
             namespace \
             tls-from-files \
             license-configmap \
             helm-install-test
	@printf '\nTest deployment complete.\n'
	@printf 'Run  make port-forwards  then  make local-proxy  to access the UI at https://localhost:9443\n'
	@printf 'Run  make admin-password  to set the admin password on first login.\n\n'

deploy-test-gpu: cluster-test-gpu \
                 efs \
                 namespace \
                 tls-from-files \
                 license-configmap \
                 helm-install-test-gpu
	@printf '\nSingle-node GPU test deployment complete.\n'
	@printf 'Run  make port-forwards  then  make local-proxy  to access the UI at https://localhost:9443\n'
	@printf 'Run  make admin-password  to set the admin password on first login.\n\n'

deploy-full: check-env-full \
             cluster-full \
             ecr-repos \
             images-load \
             images-push \
             alb-controller \
             nvidia-device-plugin \
             efs \
             namespace \
             tls-self-signed \
             license-configmap \
             license-values \
             helm-install-full
	@printf '\nFull deployment complete.\n'
	@printf 'Point DNS for %s at the ALB shown by:\n' "$(INGRESS_HOST)"
	@printf '  kubectl get ingress -n %s\n\n' "$(NAMESPACE)"

deploy-two-node: check-env \
                 cluster-full \
                 ecr-repos \
                 images-load \
                 images-push \
                 nvidia-device-plugin \
                 efs \
                 namespace \
                 tls-self-signed \
                 license-configmap-two-node \
                 license-values \
                 helm-install-two-node
	@printf '\nTwo-node deployment complete (build0024).\n'
	@printf 'Run  make port-forwards  then  make local-proxy  to access the UI at https://localhost:9443\n'
	@printf 'Run  make admin-password  to set the admin password on first login.\n\n'

deploy-two-node-full: check-env-full \
                      cluster-full \
                      alb-controller \
                      nvidia-device-plugin \
                      efs \
                      namespace \
                      tls-self-signed \
                      license-configmap-two-node \
                      license-values \
                      helm-install-full
	@printf '\nTwo-node full deployment complete (build0024).\n'
	@printf 'Point DNS for %s at the ALB shown by:\n' "$(INGRESS_HOST)"
	@printf '  kubectl get ingress -n %s\n\n' "$(NAMESPACE)"

deploy-two-node-full-images: check-env-full \
                      cluster-full \
                      ecr-repos \
                      images-load \
                      images-push \
                      alb-controller \
                      nvidia-device-plugin \
                      efs \
                      namespace \
                      tls-self-signed \
                      license-configmap-two-node \
                      license-values \
                      helm-install-full
	@printf '\nTwo-node full deployment complete (build0024).\n'
	@printf 'Point DNS for %s at the ALB shown by:\n' "$(INGRESS_HOST)"
	@printf '  kubectl get ingress -n %s\n\n' "$(NAMESPACE)"

# ── Cluster ───────────────────────────────────────────────────────────────────
cluster-test: check-env
	sed "s/REPLACE_CLUSTER_NAME/$(CLUSTER_NAME)/g" $(EKSCTL_TEST) | eksctl create cluster -f -

cluster-test-gpu: check-env
	sed "s/REPLACE_CLUSTER_NAME/$(CLUSTER_NAME)/g" $(EKSCTL_TEST_GPU) | eksctl create cluster -f -

cluster-full: check-env
	sed "s/REPLACE_CLUSTER_NAME/$(CLUSTER_NAME)/g" $(EKSCTL_FULL) | eksctl create cluster -f -

# ── ECR ───────────────────────────────────────────────────────────────────────
ecr-repos: check-env
	@for repo in \
	  fortiaigate/api \
	  fortiaigate/core \
	  fortiaigate/webui \
	  fortiaigate/logd \
	  fortiaigate/license_manager \
	  fortiaigate/scanner \
	  fortiaigate/custom-triton \
	  fortiaigate/triton-models; do \
	    aws ecr create-repository \
	      --repository-name "$$repo" \
	      --region "$(AWS_REGION)" > /dev/null 2>&1 \
	    && echo "Created $$repo" \
	    || echo "$$repo already exists, skipping."; \
	done

# ── Images ────────────────────────────────────────────────────────────────────
images-load:
	@for archive in $(ARCHIVES); do \
	  if [ ! -f "$(IMAGES_DIR)/$$archive" ]; then \
	    echo "WARNING: $(IMAGES_DIR)/$$archive not found, skipping."; \
	  else \
	    echo "Loading $(IMAGES_DIR)/$$archive ..."; \
	    docker load -i "$(IMAGES_DIR)/$$archive"; \
	  fi; \
	done

images-push: check-env
	aws ecr get-login-password --region "$(AWS_REGION)" | \
	  docker login --username AWS --password-stdin "$(ECR_REGISTRY)"
	docker tag $(FORTINET_REGISTRY)/api:$(IMAGE_TAG) \
	  $(ECR_PREFIX)/api:$(IMAGE_TAG)
	docker push $(ECR_PREFIX)/api:$(IMAGE_TAG)
	docker tag $(FORTINET_REGISTRY)/core:$(IMAGE_TAG) \
	  $(ECR_PREFIX)/core:$(IMAGE_TAG)
	docker push $(ECR_PREFIX)/core:$(IMAGE_TAG)
	docker tag $(FORTINET_REGISTRY)/webui:$(IMAGE_TAG) \
	  $(ECR_PREFIX)/webui:$(IMAGE_TAG)
	docker push $(ECR_PREFIX)/webui:$(IMAGE_TAG)
	docker tag $(FORTINET_REGISTRY)/logd:$(IMAGE_TAG) \
	  $(ECR_PREFIX)/logd:$(IMAGE_TAG)
	docker push $(ECR_PREFIX)/logd:$(IMAGE_TAG)
	docker tag $(FORTINET_REGISTRY)/license_manager:$(IMAGE_TAG) \
	  $(ECR_PREFIX)/license_manager:$(IMAGE_TAG)
	docker push $(ECR_PREFIX)/license_manager:$(IMAGE_TAG)
	docker tag $(FORTINET_REGISTRY)/scanner:$(IMAGE_TAG) \
	  $(ECR_PREFIX)/scanner:$(IMAGE_TAG)
	docker push $(ECR_PREFIX)/scanner:$(IMAGE_TAG)
	docker tag $(FORTINET_REGISTRY)/custom-triton:$(TRITON_TAG) \
	  $(ECR_PREFIX)/custom-triton:$(TRITON_TAG)
	docker push $(ECR_PREFIX)/custom-triton:$(TRITON_TAG)
	docker tag $(FORTINET_REGISTRY)/triton-models:$(TRITON_MODELS_TAG) \
	  $(ECR_PREFIX)/triton-models:$(TRITON_MODELS_TAG)
	docker push $(ECR_PREFIX)/triton-models:$(TRITON_MODELS_TAG)

# ── ALB Controller ────────────────────────────────────────────────────────────
alb-controller: check-env
	@# Detect VPC ID and patch the controller values file
	$(eval VPC_ID := $(shell aws eks describe-cluster \
	  --name "$(CLUSTER_NAME)" --region "$(AWS_REGION)" \
	  --query 'cluster.resourcesVpcConfig.vpcId' --output text))
	@test -n "$(VPC_ID)" || (echo "ERROR: could not detect VPC ID for cluster $(CLUSTER_NAME)"; exit 1)
	@# Fetch and create IAM policy (idempotent)
	curl -fsSL \
	  https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.14.1/docs/install/iam_policy.json \
	  -o /tmp/alb-iam-policy.json
	aws iam create-policy \
	  --policy-name AWSLoadBalancerControllerIAMPolicy \
	  --policy-document file:///tmp/alb-iam-policy.json 2>/dev/null \
	|| echo "IAM policy already exists, continuing."
	eksctl create iamserviceaccount \
	  --cluster "$(CLUSTER_NAME)" \
	  --namespace kube-system \
	  --name aws-load-balancer-controller \
	  --attach-policy-arn "arn:aws:iam::$(AWS_ACCOUNT_ID):policy/AWSLoadBalancerControllerIAMPolicy" \
	  --override-existing-serviceaccounts \
	  --region "$(AWS_REGION)" \
	  --approve
	helm repo add eks https://aws.github.io/eks-charts 2>/dev/null || true
	helm repo update eks
	@# Pre-install CRDs so the API server recognises them before the chart's templates run
	helm show crds eks/aws-load-balancer-controller --version 1.14.0 | kubectl apply -f -
	kubectl wait --for=condition=established --timeout=60s \
	  crd/ingressclassparams.elbv2.k8s.aws \
	  crd/targetgroupbindings.elbv2.k8s.aws
	helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
	  -n kube-system \
	  -f $(DEPLOY_DIR)/helm/aws-load-balancer-controller-values.yaml \
	  --set clusterName="$(CLUSTER_NAME)" \
	  --set region="$(AWS_REGION)" \
	  --set vpcId="$(VPC_ID)" \
	  --version 1.14.0
	kubectl rollout status deployment/aws-load-balancer-controller -n kube-system --timeout=120s

# ── NVIDIA Device Plugin ──────────────────────────────────────────────────────
# Installs the NVIDIA k8s device plugin DaemonSet, which registers nvidia.com/gpu
# as a schedulable resource on GPU nodes. The GPU node group carries a
# fortiaigate-gpu=true:NoSchedule taint, so the DaemonSet must tolerate it —
# otherwise the plugin never runs on the GPU node and the resource goes unregistered.
nvidia-device-plugin: check-env
	helm repo add nvdp https://nvidia.github.io/k8s-device-plugin 2>/dev/null || true
	helm repo update nvdp
	helm upgrade --install nvidia-device-plugin nvdp/nvidia-device-plugin \
	  --namespace kube-system \
	  --set tolerations[0].key=fortiaigate-gpu \
	  --set tolerations[0].operator=Equal \
	  --set tolerations[0].value=true \
	  --set tolerations[0].effect=NoSchedule
	kubectl rollout status ds/nvidia-device-plugin-daemonset -n kube-system --timeout=120s

# ── EFS ───────────────────────────────────────────────────────────────────────
efs: check-env
	@set -e; \
	echo "--- EFS setup ---"; \
	VPC_ID=$$(aws eks describe-cluster \
	  --name "$(CLUSTER_NAME)" --region "$(AWS_REGION)" \
	  --query 'cluster.resourcesVpcConfig.vpcId' --output text); \
	VPC_CIDR=$$(aws ec2 describe-vpcs \
	  --vpc-ids "$$VPC_ID" --region "$(AWS_REGION)" \
	  --query 'Vpcs[0].CidrBlock' --output text); \
	echo "VPC $$VPC_ID  CIDR $$VPC_CIDR"; \
	EFS_SG_ID=$$(aws ec2 describe-security-groups \
	  --filters "Name=group-name,Values=$(CLUSTER_NAME)-efs" "Name=vpc-id,Values=$$VPC_ID" \
	  --region "$(AWS_REGION)" \
	  --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null); \
	if [ "$$EFS_SG_ID" = "None" ] || [ -z "$$EFS_SG_ID" ]; then \
	  EFS_SG_ID=$$(aws ec2 create-security-group \
	    --group-name "$(CLUSTER_NAME)-efs" \
	    --description "EFS for $(CLUSTER_NAME)" \
	    --vpc-id "$$VPC_ID" --region "$(AWS_REGION)" \
	    --query GroupId --output text); \
	  echo "Created security group $$EFS_SG_ID"; \
	  aws ec2 authorize-security-group-ingress \
	    --group-id "$$EFS_SG_ID" --protocol tcp --port 2049 \
	    --cidr "$$VPC_CIDR" --region "$(AWS_REGION)"; \
	else \
	  echo "Security group $$EFS_SG_ID already exists, skipping."; \
	fi; \
	EFS_FS_ID=$$(aws efs describe-file-systems \
	  --query "FileSystems[?Tags[?Key=='Name'&&Value=='$(CLUSTER_NAME)-fortiaigate']].FileSystemId | [0]" \
	  --region "$(AWS_REGION)" --output text 2>/dev/null); \
	if [ "$$EFS_FS_ID" = "None" ] || [ -z "$$EFS_FS_ID" ]; then \
	  EFS_FS_ID=$$(aws efs create-file-system \
	    --region "$(AWS_REGION)" --encrypted \
	    --performance-mode generalPurpose --throughput-mode elastic \
	    --tags "Key=Name,Value=$(CLUSTER_NAME)-fortiaigate" \
	    --query FileSystemId --output text); \
	  echo "Created EFS filesystem $$EFS_FS_ID; waiting for it to become available..."; \
	  aws efs describe-file-systems \
	    --file-system-id "$$EFS_FS_ID" --region "$(AWS_REGION)" \
	    --query 'FileSystems[0].LifeCycleState' --output text; \
	  for i in 1 2 3 4 5 6 7 8 9 10; do \
	    STATE=$$(aws efs describe-file-systems \
	      --file-system-id "$$EFS_FS_ID" --region "$(AWS_REGION)" \
	      --query 'FileSystems[0].LifeCycleState' --output text); \
	    [ "$$STATE" = "available" ] && break; \
	    echo "  state=$$STATE, waiting 10s..."; sleep 10; \
	  done; \
	  for subnet in $$(aws eks describe-cluster \
	    --name "$(CLUSTER_NAME)" --region "$(AWS_REGION)" \
	    --query 'cluster.resourcesVpcConfig.subnetIds[]' --output text); do \
	      aws efs create-mount-target \
	        --file-system-id "$$EFS_FS_ID" \
	        --subnet-id "$$subnet" \
	        --security-groups "$$EFS_SG_ID" \
	        --region "$(AWS_REGION)" 2>/dev/null || true; \
	  done; \
	else \
	  echo "EFS filesystem $$EFS_FS_ID already exists, skipping creation."; \
	fi; \
	echo "Applying StorageClasses with filesystem ID $$EFS_FS_ID ..."; \
	sed "s|fileSystemId:.*|fileSystemId: $$EFS_FS_ID|" \
	  $(DEPLOY_DIR)/manifests/efs-storageclass.yaml | kubectl apply -f -; \
	sed "s|fileSystemId:.*|fileSystemId: $$EFS_FS_ID|" \
	  $(DEPLOY_DIR)/manifests/efs-storageclass-stateful.yaml | kubectl apply -f -; \
	echo "EFS ready: $$EFS_FS_ID"

efs-delete: check-env
	@set -e; \
	echo "--- EFS teardown ---"; \
	VPC_ID=$$(aws eks describe-cluster \
	  --name "$(CLUSTER_NAME)" --region "$(AWS_REGION)" \
	  --query 'cluster.resourcesVpcConfig.vpcId' --output text 2>/dev/null || true); \
	EFS_FS_ID=$$(aws efs describe-file-systems \
	  --query "FileSystems[?Tags[?Key=='Name'&&Value=='$(CLUSTER_NAME)-fortiaigate']].FileSystemId | [0]" \
	  --region "$(AWS_REGION)" --output text 2>/dev/null || true); \
	if [ "$$EFS_FS_ID" != "None" ] && [ -n "$$EFS_FS_ID" ]; then \
	  MOUNT_TARGETS=$$(aws efs describe-mount-targets \
	    --file-system-id "$$EFS_FS_ID" --region "$(AWS_REGION)" \
	    --query 'MountTargets[].MountTargetId' --output text 2>/dev/null || true); \
	  if [ -n "$$MOUNT_TARGETS" ]; then \
	    for mt in $$MOUNT_TARGETS; do \
	      echo "Deleting EFS mount target $$mt"; \
	      aws efs delete-mount-target --mount-target-id "$$mt" --region "$(AWS_REGION)" || true; \
	    done; \
	    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18; do \
	      REMAINING=$$(aws efs describe-mount-targets \
	        --file-system-id "$$EFS_FS_ID" --region "$(AWS_REGION)" \
	        --query 'length(MountTargets)' --output text 2>/dev/null || echo 0); \
	      if [ "$$REMAINING" = "0" ]; then \
	        break; \
	      fi; \
	      echo "  mount targets remaining=$$REMAINING, waiting 10s..."; \
	      sleep 10; \
	    done; \
	  else \
	    echo "No EFS mount targets found for $$EFS_FS_ID"; \
	  fi; \
	  echo "Deleting EFS filesystem $$EFS_FS_ID"; \
	  aws efs delete-file-system --file-system-id "$$EFS_FS_ID" --region "$(AWS_REGION)" || true; \
	  for i in 1 2 3 4 5 6 7 8 9 10 11 12; do \
	    if ! aws efs describe-file-systems --file-system-id "$$EFS_FS_ID" --region "$(AWS_REGION)" >/dev/null 2>&1; then \
	      break; \
	    fi; \
	    echo "  filesystem still deleting, waiting 10s..."; \
	    sleep 10; \
	  done; \
	else \
	  echo "No tagged EFS filesystem found for $(CLUSTER_NAME)-fortiaigate"; \
	fi; \
	EFS_SG_ID=$$(aws ec2 describe-security-groups \
	  --filters "Name=group-name,Values=$(CLUSTER_NAME)-efs" \
	            "Name=vpc-id,Values=$$VPC_ID" \
	  --region "$(AWS_REGION)" \
	  --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || true); \
	if [ "$$EFS_SG_ID" != "None" ] && [ -n "$$EFS_SG_ID" ]; then \
	  echo "Deleting EFS security group $$EFS_SG_ID"; \
	  aws ec2 delete-security-group --group-id "$$EFS_SG_ID" --region "$(AWS_REGION)" || true; \
	else \
	  echo "No EFS security group found for $(CLUSTER_NAME)-efs"; \
	fi

# ── Namespace ─────────────────────────────────────────────────────────────────
namespace:
	kubectl apply -f $(DEPLOY_DIR)/manifests/fortiaigate-namespace.yaml

# ── TLS ───────────────────────────────────────────────────────────────────────
tls-self-signed:
	@mkdir -p certs
	openssl req -x509 -newkey rsa:4096 -nodes \
	  -keyout $(TLS_KEY) \
	  -out $(TLS_CERT) \
	  -days 3650 \
	  -subj "/CN=fortiaigate.$(NAMESPACE).svc.cluster.local" \
	  -addext "subjectAltName=DNS:fortiaigate,DNS:fortiaigate.$(NAMESPACE).svc.cluster.local,DNS:localhost"
	kubectl create secret tls fortiaigate-tls-secret \
	  --namespace "$(NAMESPACE)" \
	  --cert $(TLS_CERT) \
	  --key $(TLS_KEY) \
	  --dry-run=client -o yaml | kubectl apply -f -
	@printf '\nTLS secret created. Files are in certs/ — do not commit them.\n'

tls-from-files:
	@test -f "$(TLS_CERT)" || (echo "ERROR: TLS_CERT not found: $(TLS_CERT)"; exit 1)
	@test -f "$(TLS_KEY)"  || (echo "ERROR: TLS_KEY not found: $(TLS_KEY)"; exit 1)
	kubectl create secret tls fortiaigate-tls-secret \
	  --namespace "$(NAMESPACE)" \
	  --cert "$(TLS_CERT)" \
	  --key "$(TLS_KEY)" \
	  --dry-run=client -o yaml | kubectl apply -f -

# ── License ConfigMap ─────────────────────────────────────────────────────────
# The ConfigMap key must match the Kubernetes node name. The node name is
# auto-detected from the cluster (first node returned). Override LICENSE_FILE
# to point at your actual license file.
license-configmap:
	@test -f "$(LICENSE_FILE)" || \
	  (echo "ERROR: LICENSE_FILE not found: $(LICENSE_FILE)"; exit 1)
	@NODE_NAME=$$(kubectl get nodes \
	  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null); \
	test -n "$$NODE_NAME" || \
	  (echo "ERROR: could not detect node name — is the cluster up?"; exit 1); \
	echo "Creating license ConfigMap: key=$$NODE_NAME file=$(LICENSE_FILE)"; \
	kubectl create configmap fortiaigate-license-config \
	  --namespace "$(NAMESPACE)" \
	  --from-file="$$NODE_NAME=$(LICENSE_FILE)" \
	  --dry-run=client -o yaml | kubectl apply -f -

# ── License ConfigMap (two-node, build0024) ───────────────────────────────────
# Creates a ConfigMap with two entries — one per app node — keyed to the node
# names reported by the live cluster. Nodes are assigned in kubectl listing order:
# first app node gets LICENSE_FILE_1, second gets LICENSE_FILE_2.
license-configmap-two-node:
	@test -f "$(LICENSE_FILE_1)" || \
	  (echo "ERROR: LICENSE_FILE_1 not found: $(LICENSE_FILE_1)"; exit 1)
	@test -f "$(LICENSE_FILE_2)" || \
	  (echo "ERROR: LICENSE_FILE_2 not found: $(LICENSE_FILE_2)"; exit 1)
	@APP_NODES=$$(kubectl get nodes -l fortiaigate-role=app \
	  -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); \
	NODE_COUNT=$$(echo $$APP_NODES | wc -w | tr -d ' '); \
	test "$$NODE_COUNT" -ge 2 || \
	  (echo "ERROR: expected at least 2 app nodes (fortiaigate-role=app), found $$NODE_COUNT — is the cluster up?"; exit 1); \
	NODE1=$$(echo $$APP_NODES | awk '{print $$1}'); \
	NODE2=$$(echo $$APP_NODES | awk '{print $$2}'); \
	echo "Creating two-node license ConfigMap:"; \
	echo "  $$NODE1 -> $(LICENSE_FILE_1)"; \
	echo "  $$NODE2 -> $(LICENSE_FILE_2)"; \
	kubectl create configmap fortiaigate-license-config \
	  --namespace "$(NAMESPACE)" \
	  --from-file="$$NODE1=$(LICENSE_FILE_1)" \
	  --from-file="$$NODE2=$(LICENSE_FILE_2)" \
	  --dry-run=client -o yaml | kubectl apply -f -

# ── License values (build0024+) ───────────────────────────────────────────────
# build0024+ uses global.licenses hostname nodeAffinity in all workload templates.
# This target generates a values file from live cluster nodes so node names do
# not need to be hardcoded. Pass the generated file to every helm install call:
#   helm upgrade --install ... -f $(LICENSE_VALUES_FILE)
license-values:
	@APP_NODES=$$(kubectl get nodes -l fortiaigate-role=app \
	  -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); \
	test -n "$$APP_NODES" || \
	  (echo "ERROR: no app nodes found (label fortiaigate-role=app) — is the cluster up?"; exit 1); \
	{ \
	  printf 'global:\n'; \
	  printf '  licenses:\n'; \
	  for name in $$APP_NODES; do \
	    printf '    "%s": null\n' "$$name"; \
	  done; \
	} > $(LICENSE_VALUES_FILE)
	@echo "Generated $(LICENSE_VALUES_FILE):"
	@cat $(LICENSE_VALUES_FILE)

# ── Helm ──────────────────────────────────────────────────────────────────────
# build0024+ includes $(LICENSE_VALUES_FILE) so that global.licenses is populated
# with actual node names. Run `make license-values` before any helm install target
# when using BUILD=build0024 (or later).
helm-render:
	helm template $(HELM_RELEASE) $(CHART_DIR) \
	  --namespace "$(NAMESPACE)" \
	  --set fortiaigate.image.repository="$(ECR_PREFIX)" \
	  --set fortiaigate.image.tag="$(IMAGE_TAG)" \
	  -f $(VALUES_TEST) \
	  $(if $(wildcard $(LICENSE_VALUES_FILE)),-f $(LICENSE_VALUES_FILE),) \
	  > /tmp/fortiaigate-render.yaml
	@echo "Rendered to /tmp/fortiaigate-render.yaml"

helm-render-test-gpu:
	helm template $(HELM_RELEASE) $(CHART_DIR) \
	  --namespace "$(NAMESPACE)" \
	  --set fortiaigate.image.repository="$(ECR_PREFIX)" \
	  --set fortiaigate.image.tag="$(IMAGE_TAG)" \
	  -f $(VALUES_TEST) \
	  $(if $(wildcard $(LICENSE_VALUES_FILE)),-f $(LICENSE_VALUES_FILE),) \
	  -f $(VALUES_TEST_GPU) \
	  > /tmp/fortiaigate-render-test-gpu.yaml
	@echo "Rendered to /tmp/fortiaigate-render-test-gpu.yaml"

helm-install-test: check-env
	helm upgrade --install $(HELM_RELEASE) $(CHART_DIR) \
	  --namespace "$(NAMESPACE)" \
	  --create-namespace \
	  --set fortiaigate.image.repository="$(ECR_PREFIX)" \
	  --set fortiaigate.image.tag="$(IMAGE_TAG)" \
	  --set license.existingConfigMap=fortiaigate-license-config \
	  -f $(VALUES_TEST) \
	  $(if $(wildcard $(LICENSE_VALUES_FILE)),-f $(LICENSE_VALUES_FILE),)

helm-install-test-gpu: check-env
	helm upgrade --install $(HELM_RELEASE) $(CHART_DIR) \
	  --namespace "$(NAMESPACE)" \
	  --create-namespace \
	  --set fortiaigate.image.repository="$(ECR_PREFIX)" \
	  --set fortiaigate.image.tag="$(IMAGE_TAG)" \
	  --set license.existingConfigMap=fortiaigate-license-config \
	  -f $(VALUES_TEST) \
	  $(if $(wildcard $(LICENSE_VALUES_FILE)),-f $(LICENSE_VALUES_FILE),) \
	  -f $(VALUES_TEST_GPU)

helm-install-full: check-env-full
	@# Substitute INGRESS_HOST and ACM_CERT_ARN into a temp overlay file
	sed \
	  -e "s|REPLACE_HOST|$(INGRESS_HOST)|g" \
	  -e "s|REPLACE_ACM_ARN|$(ACM_CERT_ARN)|g" \
	  $(VALUES_FULL_OVR) > /tmp/fortiaigate-full-overlay.yaml
	helm upgrade --install $(HELM_RELEASE) $(CHART_DIR) \
	  --namespace "$(NAMESPACE)" \
	  --create-namespace \
	  --set fortiaigate.image.repository="$(ECR_PREFIX)" \
	  --set fortiaigate.image.tag="$(IMAGE_TAG)" \
	  --set license.existingConfigMap=fortiaigate-license-config \
	  -f $(VALUES_TEST) \
	  $(if $(wildcard $(LICENSE_VALUES_FILE)),-f $(LICENSE_VALUES_FILE),) \
	  -f /tmp/fortiaigate-full-overlay.yaml

helm-install-two-node: check-env
	helm upgrade --install $(HELM_RELEASE) $(CHART_DIR) \
	  --namespace "$(NAMESPACE)" \
	  --create-namespace \
	  --set fortiaigate.image.repository="$(ECR_PREFIX)" \
	  --set fortiaigate.image.tag="$(IMAGE_TAG)" \
	  --set license.existingConfigMap=fortiaigate-license-config \
	  -f $(VALUES_TEST) \
	  $(if $(wildcard $(LICENSE_VALUES_FILE)),-f $(LICENSE_VALUES_FILE),) \
	  -f $(VALUES_TWO_NODE_OVR)

# ── Access ────────────────────────────────────────────────────────────────────
# The webui calls /api/* relative to its own origin, and LLM gateway requests
# go to /v1/*. Without an ingress the browser/client has no route to those
# services, so a local reverse proxy is needed.
# Proxy routing mirrors the ingress rules:
#   /api/*  -> api:8000   (port-forward 18443)
#   /v1/*   -> core:8080  (port-forward 28443)
#   /*      -> webui:3000 (port-forward 8443)
# Use these three targets together: port-forwards, then local-proxy (and
# admin-password on the first run to set a known admin password).

port-forwards:
	@echo "Starting port-forwards in background..."
	@kubectl port-forward -n "$(NAMESPACE)" svc/webui 8443:3000 > /tmp/faig-pf-webui.log 2>&1 & \
	 kubectl port-forward -n "$(NAMESPACE)" svc/api 18443:8000 > /tmp/faig-pf-api.log 2>&1 & \
	 kubectl port-forward -n "$(NAMESPACE)" svc/core 28443:8080 > /tmp/faig-pf-core.log 2>&1 &
	@sleep 2
	@echo "webui  -> https://localhost:8443   (log: /tmp/faig-pf-webui.log)"
	@echo "api    -> https://localhost:18443  (log: /tmp/faig-pf-api.log)"
	@echo "core   -> https://localhost:28443  (log: /tmp/faig-pf-core.log)"

local-proxy:
	@mkdir -p /tmp/faig-proxy/certs
	@-fuser -k 9443/tcp 2>/dev/null; true
	kubectl get secret -n "$(NAMESPACE)" fortiaigate-tls-secret \
	  -o jsonpath='{.data.tls\.crt}' | base64 -d > /tmp/faig-proxy/certs/tls.crt
	kubectl get secret -n "$(NAMESPACE)" fortiaigate-tls-secret \
	  -o jsonpath='{.data.tls\.key}' | base64 -d > /tmp/faig-proxy/certs/tls.key
	@printf '\n  Web UI:  https://localhost:9443  (accept the self-signed cert warning)\n'
	@printf '  Login:   admin / <set with: make admin-password>\n'
	@printf '  API GW:  https://localhost:9443/v1/<your-flow-path>\n'
	@printf '  Ctrl+C to stop\n\n'
	node -e "\
	const https=require('https'),fs=require('fs');\
	const opts={key:fs.readFileSync('/tmp/faig-proxy/certs/tls.key'),cert:fs.readFileSync('/tmp/faig-proxy/certs/tls.crt')};\
	const agent=new https.Agent({rejectUnauthorized:false});\
	function fwd(req,res,port){\
	  const pr=https.request({hostname:'127.0.0.1',port,path:req.url,method:req.method,headers:req.headers,agent},\
	    r=>{res.writeHead(r.statusCode,r.headers);r.pipe(res,{end:true})});\
	  pr.on('error',e=>{res.writeHead(502);res.end('Bad Gateway: '+e.message)});\
	  req.pipe(pr,{end:true});}\
	https.createServer(opts,(req,res)=>fwd(req,res,req.url.startsWith('/api/')?18443:req.url.startsWith('/v1/')?28443:8443))\
	  .listen(9443,()=>console.log('Proxy: https://localhost:9443'));"

admin-password:
	@printf 'New admin password: '; \
	stty -echo; read -r pw; stty echo; printf '\n'; \
	hash=$$(python3 -c "import bcrypt,sys; print(bcrypt.hashpw(sys.argv[1].encode(),bcrypt.gensalt(12)).decode())" "$$pw"); \
	pgpass=$$(kubectl get secret -n "$(NAMESPACE)" fortiaigate-postgresql \
	  -o jsonpath='{.data.password}' | base64 -d); \
	pgpod=$$(kubectl get pod -n "$(NAMESPACE)" -l app.kubernetes.io/name=postgresql \
	  -o jsonpath='{.items[0].metadata.name}'); \
	printf '%s' "$$hash" | kubectl exec -i -n "$(NAMESPACE)" "$$pgpod" -- bash -c 'cat > /tmp/pwhash.txt'; \
	kubectl exec -n "$(NAMESPACE)" "$$pgpod" -- \
	  bash -c "PGPASSWORD=$$pgpass psql -U fortiaigate_postgres_user -d fortiaigate_db \
	    -c \"UPDATE \\\"AIGate_User\\\" SET password='\$$(cat /tmp/pwhash.txt)', \
	    failed_login_attempts=0, locked_until=NULL, login_required_password_change=false \
	    WHERE user_alias='admin';\""; \
	printf 'Done. Login at https://$(INGRESS_HOST) (or https://localhost:9443 via local-proxy) with: admin / <your password>\n'

# ── Route 53 ──────────────────────────────────────────────────────────────────
# Creates or updates an alias A record in Route 53 pointing INGRESS_HOST at the
# ALB provisioned by the ingress. Run once after helm-install-full when the ALB
# hostname has been assigned. Safe to rerun (UPSERT) if the ALB is replaced.
route53-alias: check-env
	@set -e; \
	echo "--- Route 53 alias record: $(INGRESS_HOST) ---"; \
	ALB_DNS=$$(kubectl get ingress -n "$(NAMESPACE)" \
	  -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}' 2>/dev/null); \
	test -n "$$ALB_DNS" || (echo "ERROR: no ALB hostname on the ingress — is the ALB up?"; exit 1); \
	echo "ALB DNS:    $$ALB_DNS"; \
	ALB_ZONE_ID=$$(aws elbv2 describe-load-balancers \
	  --region "$(AWS_REGION)" \
	  --query "LoadBalancers[?DNSName=='$$ALB_DNS'].CanonicalHostedZoneId" \
	  --output text); \
	test -n "$$ALB_ZONE_ID" || (echo "ERROR: could not look up ALB canonical hosted zone ID"; exit 1); \
	echo "ALB zone:   $$ALB_ZONE_ID"; \
	R53_DOMAIN=$$(echo "$(INGRESS_HOST)" | cut -d. -f2-); \
	R53_ZONE_ID=$$(aws route53 list-hosted-zones-by-name \
	  --dns-name "$$R53_DOMAIN" \
	  --query "HostedZones[0].Id" \
	  --output text | cut -d/ -f3); \
	test -n "$$R53_ZONE_ID" || (echo "ERROR: no Route 53 hosted zone found for $$R53_DOMAIN"; exit 1); \
	echo "R53 zone:   $$R53_ZONE_ID"; \
	printf '{"Changes":[{"Action":"UPSERT","ResourceRecordSet":{"Name":"%s","Type":"A","AliasTarget":{"HostedZoneId":"%s","DNSName":"%s","EvaluateTargetHealth":true}}}]}' \
	  "$(INGRESS_HOST)" "$$ALB_ZONE_ID" "$$ALB_DNS" > /tmp/r53-alias-change.json; \
	aws route53 change-resource-record-sets \
	  --hosted-zone-id "$$R53_ZONE_ID" \
	  --change-batch file:///tmp/r53-alias-change.json; \
	echo "Done. Verify with: dig $(INGRESS_HOST)"

# ── Teardown ──────────────────────────────────────────────────────────────────
helm-uninstall:
	helm uninstall $(HELM_RELEASE) --namespace "$(NAMESPACE)"

cluster-delete: check-env
	@printf '\nThis will permanently delete cluster %s in %s.\n' "$(CLUSTER_NAME)" "$(AWS_REGION)"
	@printf 'This also deletes the tagged EFS filesystem and mount targets created by this Makefile.\n'
	@printf 'Type the cluster name to confirm: '; \
	read -r name; \
	test "$$name" = "$(CLUSTER_NAME)" \
	  || (printf 'Aborted.\n'; exit 1)
	-$(MAKE) helm-uninstall
	$(MAKE) efs-delete
	eksctl delete cluster --name "$(CLUSTER_NAME)" --region "$(AWS_REGION)"
