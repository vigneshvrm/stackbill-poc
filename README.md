# StackBill POC Installer

All-in-one Kubernetes deployment for StackBill Cloud Management Portal.

## Overview

This Helm chart provides a **simplified POC/Sandbox installation** where:

- **User provides**: Domain name + SSL certificate only
- **Auto-provisioned**: MySQL, MongoDB, RabbitMQ, NFS storage

## Quick Start

### Prerequisites

| Component | Requirement |
|-----------|-------------|
| Kubernetes | 1.29+ |
| Helm | 3.12+ |
| Istio | 1.20+ (installed) |
| Storage | Default StorageClass |

### Minimum Hardware (POC)

- 8 vCPU, 16GB RAM, 100GB storage

### Installation

#### Linux/Mac

```bash
# Make executable
chmod +x scripts/*.sh

# Install with domain + SSL
./scripts/install-poc.sh \
  --domain portal.example.com \
  --ssl-cert /path/to/cert.pem \
  --ssl-key /path/to/key.pem
```

#### Windows

```cmd
scripts\install-poc.bat ^
  --domain portal.example.com ^
  --ssl-cert C:\path\to\cert.pem ^
  --ssl-key C:\path\to\key.pem
```

### What Gets Installed

| Component | Version | Purpose |
|-----------|---------|---------|
| MySQL | 8.0 | Application data |
| MongoDB | 7.0 | Usage statistics |
| RabbitMQ | 3.13 | CloudStack messaging |
| NFS Storage | - | Shared files |
| Deployment Controller | v1.1.7 | Setup wizard UI |

## Installation Flow

```
┌─────────────────────────────────────────────────────────────────┐
│                     POC INSTALLATION FLOW                        │
└─────────────────────────────────────────────────────────────────┘

    User Input                    Auto-Provisioned
    ──────────                    ────────────────
    ┌──────────────┐
    │ Domain Name  │──────┐
    └──────────────┘      │       ┌─────────────────┐
                          │       │  MySQL 8.0      │
    ┌──────────────┐      │       ├─────────────────┤
    │ SSL Cert     │──────┼──────▶│  MongoDB 7.0    │
    └──────────────┘      │       ├─────────────────┤
                          │       │  RabbitMQ 3.13  │
    ┌──────────────┐      │       ├─────────────────┤
    │ SSL Key      │──────┘       │  NFS Storage    │
    └──────────────┘              ├─────────────────┤
                                  │  Deployment     │
                                  │  Controller     │
                                  └─────────────────┘
                                         │
                                         ▼
                                  ┌─────────────────┐
                                  │  StackBill UI   │
                                  │  Wizard         │
                                  └─────────────────┘
```

## Configuration

### Command Line Options

| Option | Required | Description |
|--------|----------|-------------|
| `--domain` | Yes | Domain name for portal |
| `--ssl-cert` | Yes | Path to SSL certificate |
| `--ssl-key` | Yes | Path to SSL private key |
| `--ssl-ca` | No | Path to CA bundle |
| `-n, --namespace` | No | Kubernetes namespace (default: sb-system) |

### Manual Helm Install

```bash
# Add repos
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo update

# Update dependencies
helm dependency update .

# Install
helm install stackbill . \
  --namespace sb-system \
  --create-namespace \
  --set domain.name=portal.example.com \
  --set-file ssl.certificate=./cert.pem \
  --set-file ssl.privateKey=./key.pem \
  --set mysql.auth.rootPassword=SecurePass123 \
  --set mongodb.auth.rootPassword=SecurePass456 \
  --set rabbitmq.auth.password=SecurePass789
```

## Post-Installation

### Access the Portal

1. **Configure DNS**: Point your domain to the Istio Ingress Gateway IP
   ```bash
   kubectl get svc istio-ingressgateway -n istio-system
   ```

2. **Open Browser**: Navigate to `https://your-domain.com`

3. **Complete Setup**: Follow the on-screen wizard

### Retrieve Credentials

Credentials are saved locally during installation:
- Linux/Mac: `~/stackbill-poc-credentials.txt`
- Windows: `%USERPROFILE%\stackbill-poc-credentials.txt`

Or from Kubernetes:
```bash
kubectl get secret stackbill-auto-credentials -n sb-system -o yaml
```

### Verify Installation

```bash
# Check pods
kubectl get pods -n sb-system

# Expected output:
# NAME                                      READY   STATUS
# stackbill-mysql-0                         1/1     Running
# stackbill-mongodb-0                       1/1     Running
# stackbill-rabbitmq-0                      1/1     Running
# sb-deployment-controller-xxx              1/1     Running

# Check services
kubectl get svc -n sb-system
```

## Uninstall

```bash
# Basic uninstall (preserves data)
./scripts/uninstall.sh

# Complete cleanup (deletes all data)
./scripts/uninstall.sh --delete-pvc --delete-namespace
```

## Directory Structure

```
stackbill-helm/
├── Chart.yaml                 # Chart with dependencies
├── values.yaml                # POC configuration
├── README.md
│
├── charts/
│   └── sb-deployment-controller/   # UI wizard
│
├── templates/
│   ├── _helpers.tpl
│   ├── ssl-secret.yaml             # SSL certificate
│   ├── auto-credentials-secret.yaml # Auto-generated creds
│   ├── poc-configmap.yaml          # POC config
│   ├── poc-nfs-pvc.yaml            # Storage
│   └── NOTES.txt
│
└── scripts/
    ├── install-poc.sh         # Linux/Mac POC installer
    ├── install-poc.bat        # Windows POC installer
    ├── install.sh             # Full installer
    ├── install.bat            # Windows full installer
    ├── uninstall.sh           # Uninstaller
    ├── uninstall.bat          # Windows uninstaller
    └── package.sh             # Distribution packager
```

## Troubleshooting

### Pods not starting

```bash
# Check pod events
kubectl describe pod -n sb-system <pod-name>

# Check logs
kubectl logs -n sb-system <pod-name>
```

### SSL Issues

```bash
# Verify certificate is loaded
kubectl get secret stackbill-tls-secret -n sb-system

# Check certificate details
kubectl get secret stackbill-tls-secret -n sb-system -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -text -noout
```

### Database Connection Issues

```bash
# Check MySQL
kubectl exec -it stackbill-mysql-0 -n sb-system -- mysql -u stackbill -p

# Check MongoDB
kubectl exec -it stackbill-mongodb-0 -n sb-system -- mongosh
```

## Support

- Documentation: https://docs.stackbill.com
- Email: support@stackbill.com
