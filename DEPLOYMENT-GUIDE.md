# StackBill POC Deployment Guide

Complete guide for deploying StackBill Cloud Management Portal using the Helm chart.

---

## Table of Contents

1. [System Requirements](#system-requirements)
2. [Prerequisites](#prerequisites)
3. [Pre-Deployment Checklist](#pre-deployment-checklist)
4. [Deployment Steps](#deployment-steps)
5. [Post-Deployment Verification](#post-deployment-verification)
6. [Accessing StackBill](#accessing-stackbill)
7. [Troubleshooting](#troubleshooting)

---

## System Requirements

### POC / Small-Scale Environment

For proof of concept or limited users (< 1,000 users):

| Component | VMs | vCPU | RAM | Disk |
|-----------|-----|------|-----|------|
| Kubernetes Master + HAProxy | 1 | 2 | 4 GB | 50 GB |
| Kubernetes Worker | 1 | 8 | 16 GB | 50 GB |
| MySQL + MongoDB + RabbitMQ | 1 | 4 | 8 GB | 50 GB |
| NFS Server | 1 | 2 | 4 GB | 50 GB + 100 GB |
| **TOTAL** | **4** | **16** | **32 GB** | **300 GB** |

**Single VM Option (All-in-One POC):**

| Component | vCPU | RAM | Disk |
|-----------|------|-----|------|
| All-in-One K8s + DBs | 8 | 16 GB | 200 GB |

### Production / Large-Scale Environment

For production deployments (50,000+ users):

| Component | VMs | vCPU | RAM | Disk |
|-----------|-----|------|-----|------|
| Kubernetes Master (HA) | 3 | 2 each | 4 GB each | 50 GB each |
| Kubernetes Worker | 2 | 2 each | 24 GB each | 50 GB each |
| MySQL Cluster | 2 | 4 each | 8 GB each | 50 GB each |
| MongoDB Cluster | 3 | 4 each | 8 GB each | 75 GB each |
| RabbitMQ | 1 | 2 | 4 GB | 30 GB |
| NFS Server | 1 | 4 | 8 GB | 30 GB + 500 GB |
| HAProxy Cluster | 2 | 2 each | 4 GB each | 30 GB each |
| **TOTAL** | **14** | **36** | **112 GB** | **1.2 TB** |

---

## Prerequisites

### Software Versions

| Software | Minimum Version | Notes |
|----------|-----------------|-------|
| **Operating System** | Ubuntu 22.04 LTS | All VMs |
| **Kubernetes** | 1.29+ | Previous minor of latest stable |
| **Helm** | 3.12+ | Latest recommended |
| **kubectl** | Latest | Match K8s version |
| **Istio** | 1.20.3+ | Service mesh |
| **MySQL** | 8.0+ | Auto-installed by Helm |
| **MongoDB** | 7.0+ | Auto-installed by Helm |
| **RabbitMQ** | 3.13.7+ | Auto-installed by Helm |

### Required Information (User Provides)

| Item | Description | Example |
|------|-------------|---------|
| **Domain Name** | FQDN for StackBill portal | `stackbill.example.com` |
| **SSL Certificate** | Valid certificate file (PEM) | `certificate.pem` |
| **SSL Private Key** | Private key file (PEM) | `private-key.pem` |
| **CA Bundle** (optional) | CA certificate chain | `ca-bundle.pem` |

---

## Pre-Deployment Checklist

### 1. Network Requirements

```
✅ All VMs in same network/subnet
✅ VMs can ping each other
✅ No firewall blocking inter-VM traffic
✅ Unrestricted internet access for package downloads
✅ DNS configured for domain name
```

### 2. Required Ports

| Port | Service | Direction |
|------|---------|-----------|
| 22 | SSH | Inbound |
| 80 | HTTP | Inbound |
| 443 | HTTPS | Inbound |
| 3306 | MySQL | Internal |
| 5672 | RabbitMQ | Internal |
| 15672 | RabbitMQ Management | Internal |
| 27017 | MongoDB | Internal |
| 6443 | Kubernetes API | Internal |
| 10250 | Kubelet | Internal |
| 2379-2380 | etcd | Internal |

### 3. Kubernetes Cluster Ready

```bash
# Verify cluster is running
kubectl cluster-info

# Check nodes are ready
kubectl get nodes

# Verify storage class exists
kubectl get storageclass
```

### 4. Istio Installed

```bash
# Check Istio installation
kubectl get namespace istio-system

# Verify Istio pods
kubectl get pods -n istio-system

# Get Istio ingress gateway IP
kubectl get svc istio-ingressgateway -n istio-system
```

---

## Deployment Steps

### Step 1: Download the Helm Chart

```bash
# Option A: If you have the packaged chart
tar -xzf stackbill-installer-1.0.0.tar.gz
cd stackbill-installer-1.0.0

# Option B: Clone/copy the helm chart directory
cd /path/to/stackbill-helm
```

### Step 2: Prepare SSL Certificates

```bash
# Verify your certificate files exist
ls -la /path/to/certificate.pem
ls -la /path/to/private-key.pem

# Verify certificate is valid
openssl x509 -in /path/to/certificate.pem -text -noout

# Verify key matches certificate
openssl x509 -noout -modulus -in certificate.pem | openssl md5
openssl rsa -noout -modulus -in private-key.pem | openssl md5
# (Both should show same hash)
```

### Step 3: Run POC Installer

#### Linux/Mac:

```bash
# Make scripts executable
chmod +x scripts/*.sh

# Run POC installer
./scripts/install-poc.sh \
  --domain stackbill.example.com \
  --ssl-cert /path/to/certificate.pem \
  --ssl-key /path/to/private-key.pem
```

#### Windows:

```cmd
scripts\install-poc.bat ^
  --domain stackbill.example.com ^
  --ssl-cert C:\path\to\certificate.pem ^
  --ssl-key C:\path\to\private-key.pem
```

#### Manual Helm Install (Alternative):

```bash
# Add Helm repositories
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo update

# Update chart dependencies
helm dependency update .

# Install StackBill POC
helm install stackbill . \
  --namespace sb-system \
  --create-namespace \
  --timeout 15m \
  --wait \
  --set domain.name=stackbill.example.com \
  --set-file ssl.certificate=/path/to/certificate.pem \
  --set-file ssl.privateKey=/path/to/private-key.pem \
  --set mysql.auth.rootPassword=YourSecurePassword123 \
  --set mysql.auth.password=YourSecurePassword123 \
  --set mongodb.auth.rootPassword=YourSecurePassword456 \
  --set mongodb.auth.password=YourSecurePassword456 \
  --set rabbitmq.auth.password=YourSecurePassword789
```

### Step 4: Wait for Deployment

The installation takes approximately **5-10 minutes**. Monitor progress:

```bash
# Watch pod creation
kubectl get pods -n sb-system -w

# Or check status periodically
watch kubectl get pods -n sb-system
```

---

## Post-Deployment Verification

### 1. Check All Pods Running

```bash
kubectl get pods -n sb-system
```

**Expected Output:**
```
NAME                                      READY   STATUS    RESTARTS   AGE
stackbill-mysql-0                         1/1     Running   0          5m
stackbill-mongodb-0                       1/1     Running   0          5m
stackbill-rabbitmq-0                      1/1     Running   0          5m
sb-deployment-controller-xxxxx            1/1     Running   0          5m
```

### 2. Check Services

```bash
kubectl get svc -n sb-system
```

**Expected Output:**
```
NAME                        TYPE        CLUSTER-IP       PORT(S)
stackbill-mysql             ClusterIP   10.96.x.x        3306/TCP
stackbill-mongodb           ClusterIP   10.96.x.x        27017/TCP
stackbill-rabbitmq          ClusterIP   10.96.x.x        5672/TCP,15672/TCP
sb-deployment-controller    ClusterIP   10.96.x.x        80/TCP
```

### 3. Verify Database Connections

```bash
# Test MySQL
kubectl exec -it stackbill-mysql-0 -n sb-system -- \
  mysql -u stackbill -p -e "SHOW DATABASES;"

# Test MongoDB
kubectl exec -it stackbill-mongodb-0 -n sb-system -- \
  mongosh --username stackbill --authenticationDatabase admin --eval "db.adminCommand('listDatabases')"

# Test RabbitMQ
kubectl exec -it stackbill-rabbitmq-0 -n sb-system -- \
  rabbitmqctl list_users
```

### 4. Check Logs

```bash
# Deployment controller logs
kubectl logs -f -l app=sb-deployment-controller -n sb-system

# MySQL logs
kubectl logs -f stackbill-mysql-0 -n sb-system

# MongoDB logs
kubectl logs -f stackbill-mongodb-0 -n sb-system

# RabbitMQ logs
kubectl logs -f stackbill-rabbitmq-0 -n sb-system
```

---

## Accessing StackBill

### 1. Configure DNS

Point your domain to the Istio Ingress Gateway:

```bash
# Get the external IP
kubectl get svc istio-ingressgateway -n istio-system

# Add DNS A record:
# stackbill.example.com -> <EXTERNAL-IP>
```

### 2. Access via Browser

```
https://stackbill.example.com
```

### 3. Local Access (Port Forward)

For testing without DNS:

```bash
# Port forward deployment controller
kubectl port-forward svc/sb-deployment-controller 8080:80 -n sb-system

# Access at
http://localhost:8080
```

### 4. Retrieve Credentials

Credentials are saved during installation:

```bash
# Linux/Mac
cat ~/stackbill-poc-credentials.txt

# Windows
type %USERPROFILE%\stackbill-poc-credentials.txt

# Or from Kubernetes secret
kubectl get secret stackbill-auto-credentials -n sb-system -o yaml
```

---

## Troubleshooting

### Pods Not Starting

```bash
# Check pod status
kubectl describe pod <pod-name> -n sb-system

# Check events
kubectl get events -n sb-system --sort-by='.lastTimestamp'
```

### Database Connection Failed

```bash
# Check if MySQL is ready
kubectl logs stackbill-mysql-0 -n sb-system | tail -50

# Check MySQL init scripts ran
kubectl exec -it stackbill-mysql-0 -n sb-system -- \
  mysql -u root -p -e "SELECT user, host FROM mysql.user;"
```

### RabbitMQ Issues

```bash
# Check RabbitMQ status
kubectl exec -it stackbill-rabbitmq-0 -n sb-system -- \
  rabbitmqctl status

# Check users and permissions
kubectl exec -it stackbill-rabbitmq-0 -n sb-system -- \
  rabbitmqctl list_users

kubectl exec -it stackbill-rabbitmq-0 -n sb-system -- \
  rabbitmqctl list_permissions
```

### Storage Issues

```bash
# Check PVCs
kubectl get pvc -n sb-system

# Check PVs
kubectl get pv

# Describe failing PVC
kubectl describe pvc <pvc-name> -n sb-system
```

### Istio/Ingress Issues

```bash
# Check Istio gateway
kubectl get gateway -n sb-system

# Check virtual service
kubectl get virtualservice -n sb-system

# Check Istio ingress logs
kubectl logs -l app=istio-ingressgateway -n istio-system
```

---

## Uninstall

### Keep Data (PVCs preserved)

```bash
./scripts/uninstall.sh
# or
helm uninstall stackbill -n sb-system
```

### Complete Cleanup (Deletes ALL data)

```bash
./scripts/uninstall.sh --delete-pvc --delete-namespace
# or
helm uninstall stackbill -n sb-system
kubectl delete pvc --all -n sb-system
kubectl delete namespace sb-system
```

---

## Support

- **Documentation:** https://docs.stackbill.com
- **Support Email:** support@stackbill.com

---

## Quick Reference Commands

```bash
# Check status
kubectl get pods -n sb-system

# View logs
kubectl logs -f -l app=sb-deployment-controller -n sb-system

# Port forward
kubectl port-forward svc/sb-deployment-controller 8080:80 -n sb-system

# Get credentials
kubectl get secret stackbill-auto-credentials -n sb-system -o jsonpath='{.data}' | base64 -d

# Restart deployment
kubectl rollout restart deployment sb-deployment-controller -n sb-system

# Scale up
kubectl scale deployment sb-deployment-controller --replicas=2 -n sb-system
```
