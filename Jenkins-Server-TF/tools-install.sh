#!/bin/bash
set -e
exec > >(tee -a /var/log/tools-install.log) 2>&1
echo "===== Starting tools install at $(date) ====="

# System prereqs
apt-get update -y
apt-get install -y curl wget gnupg lsb-release apt-transport-https \
  ca-certificates software-properties-common unzip fontconfig

# Java 17 (still install for any host-side jobs / debugging)
apt-get install -y openjdk-17-jre openjdk-17-jdk
java --version

# Docker (must come BEFORE Jenkins container)
apt-get install -y docker.io
systemctl enable docker
systemctl start docker
usermod -aG docker ubuntu
chmod 666 /var/run/docker.sock

# Jenkins as a Docker container (reliable, no apt repo headaches)
# - Mounts docker socket + binary so Jenkins can build/push images
# - Persistent volume for Jenkins home
# - Restarts automatically
docker volume create jenkins_home
docker run -d \
  --name jenkins \
  --restart unless-stopped \
  -p 8080:8080 -p 50000:50000 \
  -v jenkins_home:/var/jenkins_home \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v /usr/bin/docker:/usr/bin/docker \
  --user root \
  jenkins/jenkins:lts

# SonarQube as Docker container
docker run -d --name sonar --restart unless-stopped -p 9000:9000 sonarqube:lts-community

# AWS CLI v2
curl -s "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o awscliv2.zip
unzip -q awscliv2.zip
./aws/install
rm -rf awscliv2.zip aws/

# kubectl (latest stable)
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
rm kubectl

# eksctl
PLATFORM=$(uname -s)_amd64
curl -sLO "https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_$PLATFORM.tar.gz"
tar -xzf eksctl_$PLATFORM.tar.gz -C /tmp
mv /tmp/eksctl /usr/local/bin
rm eksctl_$PLATFORM.tar.gz

# Terraform
wget -qO- https://apt.releases.hashicorp.com/gpg | \
  gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | \
  tee /etc/apt/sources.list.d/hashicorp.list > /dev/null
apt-get update -y
apt-get install -y terraform

# Trivy
wget -qO- https://aquasecurity.github.io/trivy-repo/deb/public.key | \
  gpg --dearmor -o /usr/share/keyrings/trivy.gpg
echo "deb [signed-by=/usr/share/keyrings/trivy.gpg] https://aquasecurity.github.io/trivy-repo/deb $(lsb_release -sc) main" | \
  tee /etc/apt/sources.list.d/trivy.list > /dev/null
apt-get update -y
apt-get install -y trivy

# Helm
curl -s https://baltocdn.com/helm/signing.asc | \
  gpg --dearmor -o /usr/share/keyrings/helm.gpg
echo "deb [signed-by=/usr/share/keyrings/helm.gpg] https://baltocdn.com/helm/stable/debian/ all main" | \
  tee /etc/apt/sources.list.d/helm-stable-debian.list > /dev/null
apt-get update -y
apt-get install -y helm

echo "===== Tools install completed at $(date) ====="
