# StackBill POC Installer

Fully automated single-command deployment for StackBill Cloud Management Portal.

## Overview

This installer provides a **completely automated POC installation**:

- **User provides**: Domain name + SSL certificate
- **Auto-provisioned**: K3s, Istio, MySQL, MongoDB, RabbitMQ, NFS storage, StackBill

**No UI wizard required** - everything is configured automatically.

## Requirements

| Component | Requirement |
|-----------|-------------|
| OS | Ubuntu 22.04+ |
| CPU | 8+ vCPU |
| RAM | 16GB+ |
| Storage | 100GB+ |
| Network | Public IP with ports 80, 443 open |

## Quick Start

### Step 1: Get ECR Token

First, get the AWS ECR authentication token (requires AWS CLI configured with valid credentials):

```bash
export AWS_ECR_TOKEN=$(aws ecr get-login-password --region ap-south-1)
```

### Step 2: Run Installer

**One-Line Install:**

```bash
export AWS_ECR_TOKEN=$(aws ecr get-login-password --region ap-south-1)
curl -sfL https://raw.githubusercontent.com/vigneshvrm/stackbill-poc/main/scripts/install-stackbill-poc.sh -o /tmp/stackbill-install.sh && sudo -E bash /tmp/stackbill-install.sh
```

**Or Clone and Install:**

```bash
git clone https://github.com/vigneshvrm/stackbill-poc.git
cd stackbill-poc
export AWS_ECR_TOKEN=$(aws ecr get-login-password --region ap-south-1)
sudo -E ./scripts/install-stackbill-poc.sh
```

> **Important:** Use `sudo -E` to preserve the `AWS_ECR_TOKEN` environment variable.

The installer will prompt you for:
1. **Domain name** - Your StackBill portal domain (e.g., `stackbill.example.com`)
2. **SSL Certificate** - Choose one:
   - **Let's Encrypt** (recommended) - Free, automatic certificate
   - **Custom Certificate** - Provide your own fullchain.pem and privatekey.pem

That's it! The script will install everything automatically:
- K3s Kubernetes cluster
- Istio service mesh
- MySQL, MongoDB, RabbitMQ databases
- StackBill application

## What Gets Installed

| Component | Version | Location |
|-----------|---------|----------|
| K3s | v1.29.0 | Kubernetes cluster |
| Istio | 1.20.3 | Service mesh |
| MySQL | 8.0 | Host (systemd) |
| MongoDB | 7.0 | Host (systemd) |
| RabbitMQ | 3.13 | Host (systemd) |
| NFS | - | Host (/data/stackbill) |
| StackBill | 4.6.7 | Kubernetes (sb-apps namespace) |

## Command Line Options

Run without arguments for interactive mode, or use these options for non-interactive installation:

| Option | Description |
|--------|-------------|
| `--domain` | Domain name for StackBill portal |
| `--letsencrypt` | Use Let's Encrypt for SSL (requires --email) |
| `--email` | Email for Let's Encrypt certificate notifications |
| `--ssl-cert` | Path to custom SSL certificate (fullchain.pem) |
| `--ssl-key` | Path to custom SSL private key (privatekey.pem) |
| `--skip-infra` | Skip K3s/Istio installation |
| `--skip-db` | Skip database installation |

### Examples

```bash
# First, always get the ECR token
export AWS_ECR_TOKEN=$(aws ecr get-login-password --region ap-south-1)

# Interactive mode (recommended)
sudo -E ./scripts/install-stackbill-poc.sh

# With Let's Encrypt SSL
sudo -E ./scripts/install-stackbill-poc.sh \
    --domain stackbill.example.com \
    --letsencrypt \
    --email admin@example.com

# With custom certificate
sudo -E ./scripts/install-stackbill-poc.sh \
    --domain stackbill.example.com \
    --ssl-cert /path/to/fullchain.pem \
    --ssl-key /path/to/privatekey.pem
```

## Post-Installation

### Access StackBill

1. **Configure DNS**: Point your domain to the server IP
2. **Access Portal**: `https://your-domain.com`

If DNS is not configured, use direct IP access:
- HTTP: `http://<server-ip>:31080`
- HTTPS: `https://<server-ip>:31443`

### View Credentials

```bash
cat ~/stackbill-credentials.txt
```

### Check Status

```bash
# View all pods
kubectl get pods -n sb-apps

# View logs
kubectl logs -f <pod-name> -n sb-apps

# Check services
kubectl get svc -n sb-apps
```

## Uninstall

```bash
# Basic uninstall (preserves data)
./scripts/uninstall.sh

# Complete cleanup (deletes all data)
./scripts/uninstall.sh --delete-pvc --delete-namespace --force
```

## Troubleshooting

### Pods not starting

```bash
kubectl describe pod <pod-name> -n sb-apps
kubectl logs <pod-name> -n sb-apps
```

### Database connection issues

```bash
# Test MySQL
mysql -u stackbill -p -h localhost

# Test MongoDB
mongosh -u stackbill -p --authenticationDatabase admin

# Test RabbitMQ
rabbitmqctl status
```

### Check Istio Gateway

```bash
kubectl get gateway -n sb-apps
kubectl get virtualservice -n sb-apps
```

## Project Structure

```
stackbill-poc/
├── README.md
├── .gitattributes
└── scripts/
    ├── install-stackbill-poc.sh    # Main installer
    └── uninstall.sh                # Uninstaller
```

## Support

- Documentation: https://docs.stackbill.com
- Email: support@stackbill.com
