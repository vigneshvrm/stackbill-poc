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

```bash
# Clone the repository
git clone https://github.com/vigneshvrm/stackbill-poc.git
cd stackbill-poc

# Run the installer
sudo ./scripts/install-stackbill-poc.sh \
    --domain your-domain.com \
    --ssl-cert /path/to/fullchain.pem \
    --ssl-key /path/to/privatekey.pem
```

That's it! The script will install everything automatically.

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

| Option | Required | Description |
|--------|----------|-------------|
| `--domain` | Yes | Domain name for StackBill portal |
| `--ssl-cert` | Yes | Path to SSL certificate (fullchain.pem) |
| `--ssl-key` | Yes | Path to SSL private key (privatekey.pem) |
| `--email` | No | Admin email (default: admin@stackbill.local) |
| `--skip-infra` | No | Skip K3s/Istio installation |
| `--skip-db` | No | Skip database installation |

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
