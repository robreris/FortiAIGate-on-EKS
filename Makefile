# =============================================================================
# FortiAIGate EKS Deployment
# =============================================================================
#
# Test setup  — 1 app node, self-signed TLS, kubectl port-forward access:
#   make deploy-test
#
# Scanner test  — 1 GPU-backed node, Triton enabled, kubectl port-forward access:
#   make deploy-test-gpu
#
# Full setup  — 2 app nodes + GPU node, ALB ingress with ACM certificate:
#   ACM_CERT_ARN=arn:aws:acm:... INGRESS_HOST=fortiaigate.example.com make deploy-full
#
# Individual steps can be run on their own; run `make help` for the full list.
#
# NOTE: The cluster name is embedded in deploy/eksctl/*.yaml. If you change
# CLUSTER_NAME here, also update those files to match.
# =============================================================================

# ── Configuration ─────────────────────────────────────────────────────────────
AWS_REGION     ?= us-east-1
CLUSTER_NAME   ?= fortiaigate-eks
NAMESPACE      ?= fortiaigate
IMAGE_TAG      ?= V8.0.0-build0021

AWS_ACCOUNT_ID ?= $(shell aws sts get-caller-identity --query Account --output text 2>/dev/null)
ECR_REGISTRY   := $(AWS_ACCOUNT_ID).dkr.ecr.$(AWS_REGION).amazonaws.com
ECR_PREFIX     := $(ECR_REGISTRY)/fortiaigate

# Full setup only — required by deploy-full / helm-install-full
ACM_CERT_ARN   ?=
INGRESS_HOST   ?= fortiaigate.example.com

# Supply these when using the tls-from-files target instead of tls-self-signed
TLS_CERT       ?= certs/tls.crt
TLS_KEY        ?= certs/tls.key

# License file used by license-configmap; node name is auto-detected from the cluster
LICENSE_FILE   ?= FAIGCNSD26000146.lic

# ── Internal ──────────────────────────────────────────────────────────────────
HELM_RELEASE    := fortiaigate
CHART_DIR       := ./fortiaigate
EKSCTL_TEST     := deploy/eksctl/fortiaigate-eksctl.yaml
EKSCTL_TEST_GPU := deploy/eksctl/fortiaigate-eksctl-single-gpu.yaml
EKSCTL_FULL     := deploy/eksctl/fortiaigate-eksctl-full.yaml
VALUES_TEST     := deploy/helm/values-eks.yaml
VALUES_TEST_GPU := deploy/helm/values-eks-single-gpu-overlay.yaml
VALUES_FULL_OVR := deploy/helm/values-eks-full-overlay.yaml

FORTINET_REGISTRY := dops-jfrog.fortinet-us.com/docker-fortiaigate-local

ARCHIVES := \
  FAIG_api-V8.0.0-build0021-FORTINET.tar \
  FAIG_core-V8.0.0-build0021-FORTINET.tar \
  FAIG_webui-V8.0.0-build0021-FORTINET.tar \
  FAIG_logd-V8.0.0-build0021-FORTINET.tar \
  FAIG_license_manager-V8.0.0-build0021-FORTINET.tar \
  FAIG_scanner-V8.0.0-build0021-FORTINET.tar \
  FAIG_custom-triton-V8.0.0-build0021-FORTINET.tar \
  FAIG_triton-models-V8.0.0-build0021-FORTINET.tar

.PHONY: help \
        deploy-test deploy-test-gpu deploy-full \
        cluster-test cluster-test-gpu cluster-full \
        ecr-repos \
        images-load images-push \
        alb-controller \
        efs efs-delete namespace \
        tls-self-signed tls-from-files \
        license-configmap \
        helm-render helm-render-test-gpu helm-install-test helm-install-test-gpu helm-install-full \
        port-forwards local-proxy admin-password \
        helm-uninstall cluster-delete \
        check-env check-env-full

# ── Help ──────────────────────────────────────────────────────────────────────
help:
	@printf '\nFortiAIGate EKS Deployment\n\n'
	@printf 'Composite targets:\n'
	@printf '  deploy-test          Full test setup: 1 app node, self-signed TLS, port-forward\n'
	@printf '  deploy-test-gpu      Single-node GPU test setup: Triton/scanners enabled, port-forward\n'
	@printf '  deploy-full          Full setup: 2 app nodes + GPU, ALB ingress (needs ACM_CERT_ARN)\n'
	@printf '\nCluster:\n'
	@printf '  cluster-test         Create single app-node cluster ($(EKSCTL_TEST))\n'
	@printf '  cluster-test-gpu     Create single GPU-backed app-node cluster ($(EKSCTL_TEST_GPU))\n'
	@printf '  cluster-full         Create full cluster — 2 app + 1 GPU node ($(EKSCTL_FULL))\n'
	@printf '\nImages:\n'
	@printf '  ecr-repos            Create ECR repositories\n'
	@printf '  images-load          docker load all .tar archives\n'
	@printf '  images-push          Retag and push images to ECR\n'
	@printf '\nCluster resources:\n'
	@printf '  alb-controller       Install AWS Load Balancer Controller + IAM service account\n'
	@printf '  efs                  Create EFS filesystem, security group, mount targets, StorageClass\n'
	@printf '  namespace            Create the $(NAMESPACE) namespace\n'
	@printf '\nSecrets and config:\n'
	@printf '  tls-self-signed      Generate self-signed cert and create K8s TLS secret\n'
	@printf '  tls-from-files       Create K8s TLS secret from TLS_CERT / TLS_KEY files\n'
	@printf '  license-configmap    Create license ConfigMap keyed to first auto-detected node name\n'
	@printf '\nHelm:\n'
	@printf '  helm-render          Dry-run render to /tmp/fortiaigate-render.yaml\n'
	@printf '  helm-render-test-gpu Dry-run render to /tmp/fortiaigate-render-test-gpu.yaml\n'
	@printf '  helm-install-test    Install/upgrade with test values (ingress disabled)\n'
	@printf '  helm-install-test-gpu Install/upgrade with test values + single-GPU overlay\n'
	@printf '  helm-install-full    Install/upgrade with test + full-overlay values (ALB ingress)\n'
	@printf '  port-forwards        Start webui (8443), API (18443), and core (28443) port-forwards in background\n'
	@printf '  local-proxy          Extract TLS cert and start reverse proxy at https://localhost:9443\n'
	@printf '  admin-password       Reset the admin user password (prompts interactively)\n'
	@printf '\nTeardown:\n'
	@printf '  helm-uninstall       Helm uninstall the release\n'
	@printf '  efs-delete           Delete EFS mount targets, filesystem, and security group\n'
	@printf '  cluster-delete       Delete the EKS cluster (asks for confirmation)\n'
	@printf '\nVariables (override with VAR=value on the command line):\n'
	@printf '  AWS_REGION           %s\n' "$(AWS_REGION)"
	@printf '  CLUSTER_NAME         %s\n' "$(CLUSTER_NAME)"
	@printf '  NAMESPACE            %s\n' "$(NAMESPACE)"
	@printf '  IMAGE_TAG            %s\n' "$(IMAGE_TAG)"
	@printf '  AWS_ACCOUNT_ID       %s\n' "$(AWS_ACCOUNT_ID)"
	@printf '  ECR_PREFIX           %s\n' "$(ECR_PREFIX)"
	@printf '  ACM_CERT_ARN         %s  (required for deploy-full)\n' "$(ACM_CERT_ARN)"
	@printf '  INGRESS_HOST         %s\n' "$(INGRESS_HOST)"
	@printf '  TLS_CERT / TLS_KEY   %s / %s  (for tls-from-files)\n' "$(TLS_CERT)" "$(TLS_KEY)"
	@printf '  LICENSE_FILE         %s\n' "$(LICENSE_FILE)"
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
#deploy-test: check-env \
#             cluster-test \
#             ecr-repos \
#             images-load \
#             images-push \
#             alb-controller \
#             efs \
#             namespace \
#             tls-self-signed \
#             license-configmap \
#             helm-install-test
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
             efs \
             namespace \
             tls-self-signed \
             license-configmap \
             helm-install-full
	@printf '\nFull deployment complete.\n'
	@printf 'Point DNS for %s at the ALB shown by:\n' "$(INGRESS_HOST)"
	@printf '  kubectl get ingress -n %s\n\n' "$(NAMESPACE)"

# ── Cluster ───────────────────────────────────────────────────────────────────
cluster-test: check-env
	eksctl create cluster -f $(EKSCTL_TEST)

cluster-test-gpu: check-env
	eksctl create cluster -f $(EKSCTL_TEST_GPU)

cluster-full: check-env
	eksctl create cluster -f $(EKSCTL_FULL)

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
	  if [ ! -f "$$archive" ]; then \
	    echo "WARNING: $$archive not found, skipping."; \
	  else \
	    echo "Loading $$archive ..."; \
	    docker load -i "$$archive"; \
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
	docker tag $(FORTINET_REGISTRY)/custom-triton:25.11-onnx-trt-agt \
	  $(ECR_PREFIX)/custom-triton:25.11-onnx-trt-agt
	docker push $(ECR_PREFIX)/custom-triton:25.11-onnx-trt-agt
	docker tag $(FORTINET_REGISTRY)/triton-models:0.1.4 \
	  $(ECR_PREFIX)/triton-models:0.1.4
	docker push $(ECR_PREFIX)/triton-models:0.1.4

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
	helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
	  -n kube-system \
	  -f deploy/helm/aws-load-balancer-controller-values.yaml \
	  --set clusterName="$(CLUSTER_NAME)" \
	  --set region="$(AWS_REGION)" \
	  --set vpcId="$(VPC_ID)" \
	  --version 1.14.0
	kubectl rollout status deployment/aws-load-balancer-controller -n kube-system --timeout=120s

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
	  deploy/manifests/efs-storageclass.yaml | kubectl apply -f -; \
	sed "s|fileSystemId:.*|fileSystemId: $$EFS_FS_ID|" \
	  deploy/manifests/efs-storageclass-stateful.yaml | kubectl apply -f -; \
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
	kubectl apply -f deploy/manifests/fortiaigate-namespace.yaml

# ── TLS ───────────────────────────────────────────────────────────────────────
tls-self-signed:
	@mkdir -p deploy/tls
	openssl req -x509 -newkey rsa:4096 -nodes \
	  -keyout deploy/tls/tls.key \
	  -out deploy/tls/tls.crt \
	  -days 3650 \
	  -subj "/CN=fortiaigate.$(NAMESPACE).svc.cluster.local" \
	  -addext "subjectAltName=DNS:fortiaigate,DNS:fortiaigate.$(NAMESPACE).svc.cluster.local,DNS:localhost"
	kubectl create secret tls fortiaigate-tls-secret \
	  --namespace "$(NAMESPACE)" \
	  --cert deploy/tls/tls.crt \
	  --key deploy/tls/tls.key \
	  --dry-run=client -o yaml | kubectl apply -f -
	@printf '\nTLS secret created. Files are in deploy/tls/ — do not commit them.\n'

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

# ── Helm ──────────────────────────────────────────────────────────────────────
helm-render:
	helm template $(HELM_RELEASE) $(CHART_DIR) \
	  --namespace "$(NAMESPACE)" \
	  --set fortiaigate.image.repository="$(ECR_PREFIX)" \
	  --set fortiaigate.image.tag="$(IMAGE_TAG)" \
	  -f $(VALUES_TEST) \
	  > /tmp/fortiaigate-render.yaml
	@echo "Rendered to /tmp/fortiaigate-render.yaml"

helm-render-test-gpu:
	helm template $(HELM_RELEASE) $(CHART_DIR) \
	  --namespace "$(NAMESPACE)" \
	  --set fortiaigate.image.repository="$(ECR_PREFIX)" \
	  --set fortiaigate.image.tag="$(IMAGE_TAG)" \
	  -f $(VALUES_TEST) \
	  -f $(VALUES_TEST_GPU) \
	  > /tmp/fortiaigate-render-test-gpu.yaml
	@echo "Rendered to /tmp/fortiaigate-render-test-gpu.yaml"

helm-install-test: check-env
	helm upgrade --install $(HELM_RELEASE) $(CHART_DIR) \
	  --namespace "$(NAMESPACE)" \
	  --create-namespace \
	  --set fortiaigate.image.repository="$(ECR_PREFIX)" \
	  --set fortiaigate.image.tag="$(IMAGE_TAG)" \
	  -f $(VALUES_TEST)

helm-install-test-gpu: check-env
	helm upgrade --install $(HELM_RELEASE) $(CHART_DIR) \
	  --namespace "$(NAMESPACE)" \
	  --create-namespace \
	  --set fortiaigate.image.repository="$(ECR_PREFIX)" \
	  --set fortiaigate.image.tag="$(IMAGE_TAG)" \
	  -f $(VALUES_TEST) \
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
	  -f $(VALUES_TEST) \
	  -f /tmp/fortiaigate-full-overlay.yaml

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
	printf 'Done. Login at https://localhost:9443 with: admin / <your password>\n'

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
