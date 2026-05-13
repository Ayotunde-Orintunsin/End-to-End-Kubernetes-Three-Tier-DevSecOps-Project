# Three-Tier DevSecOps Application on AWS EKS

End-to-end deployment of a containerised React + Node.js + MongoDB application on Amazon EKS, with a full Jenkins-driven DevSecOps CI pipeline, ArgoCD-powered GitOps continuous delivery, EBS-backed stateful storage, and Prometheus + Grafana observability.

> **Live URL during build:** [https://app.ecodeepzone.com](https://app.ecodeepzone.com)
> *(Cluster torn down outside active build windows to control AWS costs.)*

---

## Architecture

![Architecture Diagram](./assets/architecture.png)

### Request flow
1. Browser opens `https://app.ecodeepzone.com`
2. DNS query → **Route 53 ALIAS** → returns ALB DNS
3. Browser establishes TLS to the **AWS ALB** (cert from **ACM**, free DV)
4. ALB terminates TLS, evaluates Ingress path rules
5. Path `/` → **frontend Service** (ClusterIP) → **frontend Pod** (React, port 3000)
6. JS bundle calls `/api/tasks`
7. Path `/api` → **api Service** (ClusterIP) → **backend Pod** (Node, port 3500)
8. Backend connects to `mongodb-svc:27017` (headless) → **mongodb-0** (StatefulSet) → EBS-backed PV
9. Response flows back through ALB to the browser

### GitOps flow
1. Developer pushes code to the application repo on GitHub
2. **Jenkins** webhook / poll triggers the pipeline:
   - Workspace clean → Git checkout
   - **SonarQube** static analysis → Quality Gate
   - **OWASP Dependency-Check** scan
   - **Trivy** filesystem scan (secrets + misconfig)
   - **Docker** build → push to **Amazon ECR**
   - **Trivy** image vulnerability scan
   - Update manifest's image tag → commit & push to GitOps repo as `Jenkins CI Bot`
3. **ArgoCD** auto-syncs the cluster within ~3 min (auto-poll) or instantly via webhook
4. Cluster state matches git → new pod rolls out → zero-downtime deploy

---

## Tech Stack

| Layer | Tool / Service |
|-------|----------------|
| Cloud | AWS — eu-west-2 (London) |
| Cluster | Amazon EKS, 2× t3.medium worker nodes |
| Infrastructure as Code | Terraform (S3 remote state + DynamoDB lock) for Jenkins VPC/EC2; `eksctl` for EKS |
| Registry | Amazon ECR (private repos for frontend + backend) |
| Ingress | AWS Application Load Balancer via AWS Load Balancer Controller |
| DNS | Amazon Route 53 (ALIAS records, ACM-validated cert) |
| TLS | AWS Certificate Manager (free public cert) |
| Storage | Amazon EBS via in-tree provisioner (`gp2`), dynamic PVC provisioning |
| CI controller | Jenkins (Docker container on EC2, IAM role via IMDSv2) |
| CI security | SonarQube, OWASP Dependency-Check, Trivy (fs + image) |
| CD | Argo CD (auto-sync, prune, self-heal) |
| Observability | kube-prometheus-stack (Prometheus, Grafana, Alertmanager, Node Exporter, kube-state-metrics) |
| Source control | GitHub (single fork for app + Kubernetes manifests) |

---

## Repository Layout

```
.
├── Application-Code/
│   ├── backend/                       # Node.js + Express API
│   │   └── Dockerfile
│   └── frontend/                      # React (CRA) app
│       └── Dockerfile
├── Jenkins-Pipeline-Code/
│   ├── Jenkinsfile-Frontend           # Frontend DevSecOps pipeline (11 stages)
│   └── Jenkinsfile-Backend            # Backend DevSecOps pipeline (11 stages)
├── Jenkins-Server-TF/                 # Terraform for Jenkins VPC + EC2
│   ├── backend.tf                     # S3 remote state config
│   ├── ec2.tf                         # t3.large with IMDSv2 hop=2
│   ├── vpc.tf                         # Dedicated VPC, public subnet, SG
│   ├── iam-*.tf                       # IAM role + policy + instance profile
│   ├── provider.tf
│   ├── variables.tf
│   ├── terraform.tfvars               # Auto-loaded
│   └── tools-install.sh               # User-data: Docker → Jenkins container → AWS CLI, Trivy, Helm, etc.
└── Kubernetes-Manifests-file/
    ├── Database/
    │   ├── secrets.yaml               # MongoDB credentials
    │   ├── service.yaml               # Headless service (clusterIP: None)
    │   └── statefulset.yaml           # StatefulSet + volumeClaimTemplate (EBS gp2)
    ├── Backend/
    │   ├── deployment.yaml
    │   └── service.yaml
    ├── Frontend/
    │   ├── deployment.yaml
    │   └── service.yaml
    └── ingress.yaml                   # ALB ingress with ACM cert, HTTP→HTTPS redirect
```

---

## How To Run It (Fresh Setup)

### Prerequisites
- AWS account with admin IAM user
- Tools installed locally: `aws`, `kubectl`, `eksctl`, `helm`, `terraform`, `docker`, `git`
- Registered domain (or use the raw ALB DNS without custom hostname)
- A GitHub PAT with `repo` + `workflow` scopes

### 1. Provision the cluster (~14 min)
```bash
eksctl create cluster \
  --name three-tier-cluster \
  --region eu-west-2 \
  --node-type t3.medium \
  --nodes 2 --nodes-min 1 --nodes-max 2 \
  --managed

eksctl utils associate-iam-oidc-provider \
  --region eu-west-2 --cluster three-tier-cluster --approve
```

### 2. Install AWS Load Balancer Controller (~3 min)
```bash
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

curl -O https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json
aws iam create-policy --policy-name AWSLoadBalancerControllerIAMPolicy --policy-document file://iam_policy.json

eksctl create iamserviceaccount \
  --cluster=three-tier-cluster --region=eu-west-2 \
  --namespace=kube-system --name=aws-load-balancer-controller \
  --role-name=AmazonEKSLoadBalancerControllerRole \
  --attach-policy-arn=arn:aws:iam::$AWS_ACCOUNT_ID:policy/AWSLoadBalancerControllerIAMPolicy --approve

helm repo add eks https://aws.github.io/eks-charts && helm repo update eks
helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system --set clusterName=three-tier-cluster \
  --set serviceAccount.create=false --set serviceAccount.name=aws-load-balancer-controller \
  --set region=eu-west-2 \
  --set vpcId=$(aws eks describe-cluster --name three-tier-cluster --region eu-west-2 --query "cluster.resourcesVpcConfig.vpcId" --output text)
```

### 3. Push images to ECR (~5 min)
```bash
aws ecr create-repository --repository-name three-tier-frontend --region eu-west-2
aws ecr create-repository --repository-name three-tier-backend --region eu-west-2

aws ecr get-login-password --region eu-west-2 | \
  docker login --username AWS --password-stdin $AWS_ACCOUNT_ID.dkr.ecr.eu-west-2.amazonaws.com

# build + tag + push frontend
cd Application-Code/frontend
docker build -t three-tier-frontend:v1 .
docker tag three-tier-frontend:v1 $AWS_ACCOUNT_ID.dkr.ecr.eu-west-2.amazonaws.com/three-tier-frontend:v1
docker push $AWS_ACCOUNT_ID.dkr.ecr.eu-west-2.amazonaws.com/three-tier-frontend:v1

# repeat for backend
```

### 4. Deploy the app (~2 min)
```bash
kubectl create namespace three-tier
kubectl apply -f Kubernetes-Manifests-file/Database/
kubectl apply -f Kubernetes-Manifests-file/Backend/
kubectl apply -f Kubernetes-Manifests-file/Frontend/
kubectl apply -f Kubernetes-Manifests-file/ingress.yaml
```

### 5. Provision Jenkins (~15 min — fully automated via Terraform)
```bash
cd Jenkins-Server-TF
terraform init    # uses S3 backend
terraform apply -auto-approve
```

The user-data script installs: Docker → Jenkins container → SonarQube container → AWS CLI v2 → kubectl → eksctl → Terraform → Trivy → Helm. All logs at `/var/log/tools-install.log`.

### 6. Install ArgoCD (~3 min)
```bash
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl patch svc argocd-server -n argocd -p '{"spec": {"type": "LoadBalancer"}}'

kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d
```

### 7. Install monitoring stack (~5 min)
```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts && helm repo update
kubectl create namespace monitoring
helm install monitoring prometheus-community/kube-prometheus-stack -n monitoring \
  --set prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.storageClassName=gp2 \
  --set prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.resources.requests.storage=10Gi \
  --set grafana.persistence.enabled=true \
  --set grafana.persistence.storageClassName=gp2 --set grafana.persistence.size=2Gi
kubectl patch svc monitoring-grafana -n monitoring -p '{"spec": {"type": "LoadBalancer"}}'
```

---

## Screenshots

### 1. Live app (HTTPS)
![App live](./assets/screenshots/app-live-https.png)

### 2. Jenkins pipeline — 11 stages green
![Jenkins stages](./assets/screenshots/jenkins-pipeline-stages.png)

### 3. SonarQube quality gate passed
![SonarQube](./assets/screenshots/sonarqube-quality-gate.png)

### 4. ArgoCD GitOps sync
![ArgoCD healthy](./assets/screenshots/argocd-healthy-synced.png)

### 5. Grafana — Cluster compute resources
![Grafana cluster](./assets/screenshots/grafana-cluster.png)

### 6. Grafana — three-tier namespace pod metrics
![Grafana namespace](./assets/screenshots/grafana-namespace.png)

### 7. Custom PromQL panel — three-tier CPU per pod
![Custom panel](./assets/screenshots/grafana-custom-panel.png)

### 8. GitHub commit history (Jenkins CI Bot vs me)
![GitHub commits](./assets/screenshots/github-commits-mixed-authors.png)

---

## Challenges & Solutions

Three production-class bugs were caught and resolved end-to-end (full write-ups in [Project1_Debug_Log.md](./Project1_Debug_Log.md)):

### 1. Frontend POSTing to the wrong domain
The deployed React app was sending API requests to the original tutorial author's domain because `REACT_APP_BACKEND_URL` was hardcoded in the Kubernetes deployment manifest's env. Diagnosed via DevTools Network tab → `kubectl exec env` on the running pod → deployment manifest. Fixed with a zero-downtime `kubectl set env` rolling update, then committed the permanent fix to the manifests repo for GitOps reconciliation.

### 2. Jenkins LTS apt repo GPG key drift
The upstream `tools-install.sh` silently failed at the Jenkins package install step because the documented `jenkins.io-2023.key` doesn't contain the key currently signing the LTS Release file. Pivoted the user-data to run Jenkins as a **Docker container** (mounting the host's Docker socket and binary so the controller can still build images). Rewrote the entire script with `set -e` and log piping to `/var/log/tools-install.log`. Reproducible across any fresh EC2.

### 3. Jenkinsfile sed no-op when BUILD_NUMBER == existing image tag
Pipeline failed at the manifest-update stage because `sed` had nothing to change (build #1, existing tag `:1`), then `git commit` errored on no-op. Documented three permanent fixes: `--allow-empty`, a `git diff --staged --quiet ||` guard, or using a non-numeric tag prefix. For learning, re-running the pipeline (BUILD_NUMBER=2) sidesteps the collision.

### 4. ArgoCD won't prune externally-created resources + Service immutability
After a manifest refactor, ArgoCD reported "Synced + Healthy" but the cluster still ran the old workload. Root cause: the old resources were created via `kubectl apply` before ArgoCD existed, so they lacked the `app.kubernetes.io/instance` tracking label. ArgoCD won't prune what it doesn't own. Compounded by `Service.spec.clusterIP` being immutable — the headless conversion silently failed. Fixed by manually deleting the orphaned resources, letting ArgoCD recreate them under proper ownership. Pattern documented for brownfield-to-GitOps migrations.

---

## Skills Demonstrated

**Cloud:** AWS (EKS, EC2, ECR, ALB, ACM, Route 53, IAM, CloudFormation, EBS, VPC, S3, DynamoDB)
**Containers:** Docker (multi-app build, ECR, mounted socket pattern)
**Orchestration:** Kubernetes (Deployments, StatefulSets, Services headless + ClusterIP, Ingress, PV/PVC, ConfigMaps/Secrets, namespaces, OIDC service accounts)
**IaC:** Terraform (S3 remote state, DynamoDB locking, modular VPC/EC2/IAM), `eksctl`, Helm
**CI/CD:** Jenkins (Pipeline-as-Code, credentials management, tool installations, webhook integrations)
**DevSecOps:** SonarQube static analysis + quality gates, OWASP Dependency-Check, Trivy filesystem + image scans, IRSA (IAM Roles for Service Accounts via OIDC)
**GitOps:** ArgoCD (auto-sync, prune, self-heal, manifest-driven reconciliation)
**Observability:** Prometheus, Grafana, kube-state-metrics, node-exporter, Alertmanager, PromQL
**Networking & TLS:** Custom domain via Route 53 ALIAS, ACM cert, HTTP→HTTPS redirect at ALB, path-based routing
**Debugging:** DevTools Network analysis, `kubectl exec`, log inspection, rolling updates, root cause analysis

---

## Cost

Estimated AWS cost while the platform is running: **~$0.35/hour** (EKS + 2x t3.medium + Jenkins t3.large + 2× ALB).

This is torn down outside active build windows. Persistent low-cost resources kept: ECR images (free under 500MB), Route 53 hosted zone (~$0.50/mo), S3 + DynamoDB for Terraform state (~$0.10/mo total), ACM cert (free).

---

## Acknowledgements

This project is built on top of [AmanPathak-DevOps's End-to-End Kubernetes Three-Tier DevSecOps Project](https://github.com/AmanPathak-DevOps/End-to-End-Kubernetes-Three-Tier-DevSecOps-Project) as a starting framework. Key improvements made in this fork:

- Containerised Jenkins (Docker) instead of apt-installed — resilient to Jenkins LTS apt repo signing key drift
- Rewrote `tools-install.sh` with `set -e`, log piping, and `gpg --dearmor` for every apt repo
- Migrated Terraform to **S3 remote state with DynamoDB locking** instead of local state
- Adapted region (us-east-1 → eu-west-2), repo URLs, branch (master), and identity throughout
- **MongoDB refactor:** Deployment + manual hostPath PV → StatefulSet + EBS-backed `volumeClaimTemplates` + headless Service
- Set EC2 IMDSv2 hop limit to 2 so containerised Jenkins can use the host's instance role
- Pipeline-generated commits attributed to **"Jenkins CI Bot"** for visual distinction from human commits in `git log`
- Comprehensive debug log documenting every production-class bug encountered

---

## Author

**Ayotunde Orintunsin** — DevOps engineer | [GitHub](https://github.com/Ayotunde-Orintunsin) | idowuorintunsin@outlook.com
