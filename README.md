# StackBill POC Installer

Fully automated single-command deployment for StackBill Cloud Management Portal.

## Overview

This installer provides a **completely automated POC installation**:

- **User provides**: Domain name + SSL certificate + ECR token
- **Auto-provisioned**: K3s, Istio, MariaDB, MongoDB, RabbitMQ, NFS storage, StackBill
- **Optional**: CloudStack Simulator for POC/testing environments

**No UI wizard required** - everything is configured automatically.

## Requirements

| Component | Requirement |
|-----------|-------------|
| OS | Ubuntu 22.04+ |
| CPU | 8+ vCPU |
| RAM | 16GB+ |
| Storage | 100GB+ |
| Network | Public IP with ports 80, 443 open |
| AWS ECR Token | Required for pulling StackBill images |

## Quick Start

### Run the Installer

```bash
# Clone and install (fully interactive)
git clone https://github.com/vigneshvrm/stackbill-poc.git
cd stackbill-poc
sudo ./scripts/install-stackbill-poc.sh
```

The installer will prompt you for:
1. **Domain name** - Your StackBill portal domain (e.g., `stackbill.example.com`)
2. **SSL Certificate** - Choose one:
   - **Let's Encrypt** (recommended) - Free, automatic certificate
   - **Custom Certificate** - Provide your own fullchain.pem and privatekey.pem
3. **CloudStack** - Choose one:
   - **Existing CloudStack** - Use your own CloudStack deployment
   - **CloudStack Simulator** - Deploy Apache CloudStack Simulator for POC/testing
4. **AWS ECR Token** - Required for pulling StackBill images
   - Get it with: `aws ecr get-login-password --region ap-south-1`

The script will then install everything automatically:
- K3s Kubernetes cluster
- Istio service mesh
- MariaDB, MongoDB, RabbitMQ databases
- StackBill application
- CloudStack Simulator (if selected)

## What Gets Installed

| Component | Version | Location |
|-----------|---------|----------|
| K3s | v1.29.0 | Kubernetes cluster |
| Istio | 1.20.3 | Service mesh |
| MariaDB | 10.11 | Host (systemd) |
| MongoDB | 7.0 | Host (systemd) |
| RabbitMQ | 3.13 | Host (systemd) |
| NFS | - | Host (/data/stackbill) |
| StackBill | 4.6.7 | Kubernetes (sb-apps namespace) |
| CloudStack Simulator | 4.x | Podman container (optional) |

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

**Note:** CloudStack configuration is always prompted interactively during installation.

### Examples

```bash
# Fully interactive mode (recommended)
sudo ./scripts/install-stackbill-poc.sh

# With Let's Encrypt SSL (CloudStack and ECR token will be prompted)
sudo ./scripts/install-stackbill-poc.sh \
    --domain stackbill.example.com \
    --letsencrypt \
    --email admin@example.com

# With custom certificate (CloudStack and ECR token will be prompted)
sudo ./scripts/install-stackbill-poc.sh \
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

### Configure CloudStack Integration

After installation, configure StackBill to connect to CloudStack:

1. **If using CloudStack Simulator**:
   - Access CloudStack UI: `http://<server-ip>:8080/client`
   - Default admin: `admin` / `password`
   - StackBill user credentials are in `/root/stackbill-credentials.txt`

2. **Configure StackBill with CloudStack**:
   - Follow: https://docs.stackbill.com/docs/deployment/integrating-stackbill-with-cloudstack

3. **Complete StackBill Setup**:
   - Follow: https://docs.stackbill.com/docs/deployment/configuring-stackbill

### View Credentials

```bash
cat /root/stackbill-credentials.txt
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

### CloudStack Simulator issues

```bash
# Check container status
podman ps -a | grep cloudstack

# View logs
podman logs cloudstack-simulator

# Restart simulator
podman restart cloudstack-simulator

# Access CloudStack UI
# http://<server-ip>:8080/client
# Default: admin / password
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
