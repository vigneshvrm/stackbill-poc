# StackBill POC - Architecture & Technical Documentation

## Table of Contents

1. [Overview](#overview)
2. [Architecture Diagram](#architecture-diagram)
3. [Component Stack](#component-stack)
4. [Installation Script Flow](#installation-script-flow)
5. [Kubernetes Architecture](#kubernetes-architecture)
6. [Database Configuration](#database-configuration)
7. [Networking & Istio Service Mesh](#networking--istio-service-mesh)
8. [Storage Architecture](#storage-architecture)
9. [Security Configuration](#security-configuration)
10. [Troubleshooting Guide](#troubleshooting-guide)

---

## Overview

StackBill POC Installer provides a **fully automated single-command deployment** for the StackBill Cloud Management Portal. The system uses a hybrid architecture where:

- **Databases** run on the host (systemd services)
- **Application services** run in Kubernetes (K3s)
- **Istio** handles ingress traffic and service mesh

### Key Design Principles

| Principle | Implementation |
|-----------|----------------|
| Single Command | One script installs everything |
| Idempotent | Safe to re-run without breaking |
| Password Persistence | Credentials saved and reused across runs |
| Production-Ready Config | MySQL, MongoDB, RabbitMQ tuned for StackBill |

---

## Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                            SINGLE SERVER (POC)                               │
│                                                                              │
│  ┌────────────────────────────────────────────────────────────────────────┐ │
│  │                     HOST SERVICES (systemd)                            │ │
│  │                                                                        │ │
│  │  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  ┌───────────┐  │ │
│  │  │    MySQL     │  │   MongoDB    │  │   RabbitMQ   │  │    NFS    │  │ │
│  │  │    :3306     │  │    :27017    │  │    :5672     │  │ /data/sb  │  │ │
│  │  │              │  │              │  │    :15672    │  │           │  │ │
│  │  │ Databases:   │  │ Database:    │  │              │  │ Shared    │  │ │
│  │  │ - stackbill  │  │ - admin      │  │ User:        │  │ Storage   │  │ │
│  │  │ - config     │  │              │  │ - stackbill  │  │ for Pods  │  │ │
│  │  └──────────────┘  └──────────────┘  └──────────────┘  └───────────┘  │ │
│  └────────────────────────────────────────────────────────────────────────┘ │
│                                    │                                         │
│                                    │ Internal Network (10.42.0.0/16)         │
│                                    ▼                                         │
│  ┌────────────────────────────────────────────────────────────────────────┐ │
│  │                    KUBERNETES (K3s v1.29.0)                            │ │
│  │                                                                        │ │
│  │  ┌──────────────────────────────────────────────────────────────────┐ │ │
│  │  │              ISTIO SERVICE MESH (1.20.3)                         │ │ │
│  │  │                                                                  │ │ │
│  │  │  ┌─────────────────┐    ┌─────────────────────────────────────┐ │ │ │
│  │  │  │ Ingress Gateway │───▶│         Virtual Services            │ │ │ │
│  │  │  │   :31443 (HTTP) │    │  - sb-admin     → sb-admin:80       │ │ │ │
│  │  │  │   :31882 (HTTPS)│    │  - sb-ui        → sb-ui:80          │ │ │ │
│  │  │  └─────────────────┘    │  - sb-core      → sb-core:8080      │ │ │ │
│  │  │                         │  - sb-kong      → sb-kong:8000      │ │ │ │
│  │  │                         └─────────────────────────────────────┘ │ │ │
│  │  └──────────────────────────────────────────────────────────────────┘ │ │
│  │                                                                        │ │
│  │  ┌──────────────────────────────────────────────────────────────────┐ │ │
│  │  │                  NAMESPACE: sb-apps                              │ │ │
│  │  │                  (Istio sidecar injection: enabled)              │ │ │
│  │  │                                                                  │ │ │
│  │  │  ┌────────────┐ ┌────────────┐ ┌────────────┐ ┌────────────┐   │ │ │
│  │  │  │  sb-admin  │ │   sb-ui    │ │  sb-core   │ │  sb-kong   │   │ │ │
│  │  │  │  (Admin UI)│ │ (User UI)  │ │ (Core API) │ │ (Gateway)  │   │ │ │
│  │  │  └────────────┘ └────────────┘ └────────────┘ └────────────┘   │ │ │
│  │  │                                                                  │ │ │
│  │  │  ┌────────────┐ ┌────────────┐ ┌────────────┐ ┌────────────┐   │ │ │
│  │  │  │sb-billing  │ │sb-email-svc│ │ sb-help    │ │sb-logstash │   │ │ │
│  │  │  │(Billing)   │ │  (Email)   │ │ (Help Docs)│ │  (Logs)    │   │ │ │
│  │  │  └────────────┘ └────────────┘ └────────────┘ └────────────┘   │ │ │
│  │  │                                                                  │ │ │
│  │  │  ┌────────────┐ ┌────────────┐                                  │ │ │
│  │  │  │sb-ui-gw    │ │ sb-kong-pg │                                  │ │ │
│  │  │  │(UI Gateway)│ │(Kong DB)   │                                  │ │ │
│  │  │  └────────────┘ └────────────┘                                  │ │ │
│  │  └──────────────────────────────────────────────────────────────────┘ │ │
│  └────────────────────────────────────────────────────────────────────────┘ │
│                                                                              │
│  ┌────────────────────────────────────────────────────────────────────────┐ │
│  │                         EXTERNAL ACCESS                                │ │
│  │                                                                        │ │
│  │   Internet ──▶ DNS (stackbill.example.com) ──▶ Server IP:31882        │ │
│  │                                                    │                   │ │
│  │                                                    ▼                   │ │
│  │                                          Istio Ingress Gateway        │ │
│  │                                                    │                   │ │
│  │                                                    ▼                   │ │
│  │                                          StackBill Services           │ │
│  └────────────────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Component Stack

### Infrastructure Layer

| Component | Version | Purpose |
|-----------|---------|---------|
| **K3s** | v1.29.0+k3s1 | Lightweight Kubernetes distribution |
| **Istio** | 1.20.3 | Service mesh, ingress, mTLS |
| **Helm** | 3.x | Kubernetes package manager |

### Database Layer (Host)

| Component | Version | Port | Purpose |
|-----------|---------|------|---------|
| **MySQL** | 8.0 | 3306 | Primary relational database |
| **MongoDB** | 7.0 | 27017 | Usage data, metrics storage |
| **RabbitMQ** | 3.13 | 5672, 15672 | Message queue, async processing |

### Application Layer (Kubernetes)

| Service | Description | Port |
|---------|-------------|------|
| **sb-admin** | Admin dashboard UI | 80 |
| **sb-ui** | User portal UI | 80 |
| **sb-core** | Core API service | 8080 |
| **sb-kong** | API Gateway | 8000 |
| **sb-billing** | Billing & invoicing | 8080 |
| **sb-email-svc** | Email notifications | 8080 |
| **sb-help** | Help documentation | 80 |
| **sb-logstash** | Log aggregation | 5044 |
| **sb-ui-gateway** | UI routing gateway | 80 |
| **sb-kong-pg** | Kong PostgreSQL DB | 5432 |

---

## Installation Script Flow

### Script: `install-stackbill-poc.sh`

```
┌─────────────────────────────────────────────────────────────────┐
│                    INSTALLATION FLOW                            │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│ 1. VALIDATION                                                   │
│    ├── Validate --domain, --ssl-cert, --ssl-key arguments       │
│    ├── Verify running as root                                   │
│    └── Get server IP address                                    │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│ 2. PASSWORD MANAGEMENT                                          │
│    ├── Check if ~/stackbill-credentials.txt exists              │
│    │   ├── YES: Load existing passwords (idempotent re-runs)    │
│    │   └── NO:  Generate new random 16-char passwords           │
│    └── Passwords for: MySQL, MongoDB, RabbitMQ                  │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│ 3. INFRASTRUCTURE (--skip-infra to bypass)                      │
│    ├── install_k3s()                                            │
│    │   ├── Download K3s v1.29.0+k3s1                            │
│    │   ├── Disable Traefik (using Istio instead)                │
│    │   ├── Disable ServiceLB                                    │
│    │   └── Configure kubeconfig                                 │
│    ├── install_helm()                                           │
│    │   └── Install Helm 3.x                                     │
│    └── install_istio()                                          │
│        ├── Download istioctl 1.20.3                             │
│        ├── Install with "demo" profile                          │
│        └── Wait for istiod to be ready                          │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│ 4. DATABASES (--skip-db to bypass)                              │
│    ├── install_mysql()                                          │
│    │   ├── Install mysql-server, mysql-client                   │
│    │   ├── Configure /etc/mysql/mysql.conf.d/stackbill.cnf      │
│    │   │   ├── bind-address = 0.0.0.0                           │
│    │   │   ├── sql_mode = NO_ENGINE_SUBSTITUTION,STRICT_...     │
│    │   │   ├── max_connections = 1000                           │
│    │   │   ├── log_bin_trust_function_creators = 1              │
│    │   │   └── skip-name-resolve                                │
│    │   ├── Create databases: stackbill, configuration           │
│    │   └── Create user with mysql_native_password               │
│    ├── install_mongodb()                                        │
│    │   ├── Install mongodb-org 7.0                              │
│    │   ├── Generate encryption keyFile                          │
│    │   ├── Configure /etc/mongod.conf                           │
│    │   ├── Enable authorization                                 │
│    │   └── Create admin user with root role                     │
│    ├── install_rabbitmq()                                       │
│    │   ├── Install rabbitmq-server                              │
│    │   ├── Enable management plugin                             │
│    │   └── Create user with administrator tag                   │
│    └── setup_nfs()                                              │
│        ├── Install nfs-kernel-server                            │
│        ├── Create /data/stackbill directory                     │
│        └── Export to K8s pod network (10.42.0.0/16)             │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│ 5. KUBERNETES DEPLOYMENT                                        │
│    ├── setup_namespace()                                        │
│    │   ├── Create sb-apps namespace                             │
│    │   ├── Enable Istio sidecar injection                       │
│    │   └── Add Helm ownership labels                            │
│    ├── setup_ecr_credentials()                                  │
│    │   └── Create 'awscred' docker-registry secret              │
│    ├── setup_tls_secret()                                       │
│    │   └── Create TLS secret from SSL cert/key                  │
│    ├── deploy_stackbill()                                       │
│    │   ├── helm upgrade --install stackbill                     │
│    │   ├── Pull chart from oci://public.ecr.aws/p0g2c5k8/...    │
│    │   └── Pass all credentials via --set flags                 │
│    └── setup_istio_gateway()                                    │
│        ├── Create Gateway resource                              │
│        └── Create VirtualService for routing                    │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│ 6. FINALIZATION                                                 │
│    ├── wait_for_pods()                                          │
│    │   └── Wait up to 10 minutes for all pods to be Ready       │
│    ├── save_credentials()                                       │
│    │   └── Write ~/stackbill-credentials.txt                    │
│    └── print_summary()                                          │
│        └── Display access URLs and credentials                  │
└─────────────────────────────────────────────────────────────────┘
```

### Password Persistence Flow

```
┌──────────────────────────────────────────────────────────────────┐
│                 PASSWORD HANDLING LOGIC                          │
└──────────────────────────────────────────────────────────────────┘

First Run:
  ~/stackbill-credentials.txt does NOT exist
       │
       ▼
  Generate random passwords:
    MYSQL_PASSWORD    = $(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9')
    MONGODB_PASSWORD  = $(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9')
    RABBITMQ_PASSWORD = $(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9')
       │
       ▼
  Install databases with these passwords
       │
       ▼
  Save to ~/stackbill-credentials.txt

─────────────────────────────────────────────────────────────────────

Subsequent Runs:
  ~/stackbill-credentials.txt EXISTS
       │
       ▼
  Parse and extract passwords:
    grep -A5 "^MYSQL:" | grep "Password:" | awk '{print $2}'
       │
       ▼
  Use SAME passwords (ensures consistency)
       │
       ▼
  Databases already have correct passwords ✓

─────────────────────────────────────────────────────────────────────

After Uninstall with --delete-db:
  ~/stackbill-credentials.txt is DELETED
       │
       ▼
  Next install generates NEW passwords
```

---

## Kubernetes Architecture

### K3s Single-Node Architecture

K3s is a lightweight, certified Kubernetes distribution. In POC mode, it runs as a single-node cluster where the same node acts as both **control plane** and **worker**.

```
┌─────────────────────────────────────────────────────────────────┐
│                    K3s SINGLE NODE                              │
│                                                                 │
│  ┌───────────────────────────────────────────────────────────┐ │
│  │                  CONTROL PLANE                            │ │
│  │                                                           │ │
│  │  ┌─────────────┐ ┌─────────────┐ ┌─────────────────────┐ │ │
│  │  │ API Server  │ │ Controller  │ │     Scheduler       │ │ │
│  │  │  (kube-api) │ │  Manager    │ │ (kube-scheduler)    │ │ │
│  │  └─────────────┘ └─────────────┘ └─────────────────────┘ │ │
│  │                                                           │ │
│  │  ┌─────────────────────────────────────────────────────┐ │ │
│  │  │              etcd (embedded SQLite)                 │ │ │
│  │  │         /var/lib/rancher/k3s/server/db              │ │ │
│  │  └─────────────────────────────────────────────────────┘ │ │
│  └───────────────────────────────────────────────────────────┘ │
│                                                                 │
│  ┌───────────────────────────────────────────────────────────┐ │
│  │                    WORKER NODE                            │ │
│  │                                                           │ │
│  │  ┌─────────────┐ ┌─────────────┐ ┌─────────────────────┐ │ │
│  │  │   Kubelet   │ │ Containerd  │ │    Flannel CNI      │ │ │
│  │  │             │ │  (runtime)  │ │  (10.42.0.0/16)     │ │ │
│  │  └─────────────┘ └─────────────┘ └─────────────────────┘ │ │
│  │                                                           │ │
│  │  ┌─────────────────────────────────────────────────────┐ │ │
│  │  │                     PODS                            │ │ │
│  │  │  ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌─────────┐   │ │ │
│  │  │  │sb-admin │ │ sb-ui   │ │sb-core  │ │sb-kong  │   │ │ │
│  │  │  └─────────┘ └─────────┘ └─────────┘ └─────────┘   │ │ │
│  │  └─────────────────────────────────────────────────────┘ │ │
│  └───────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────┘
```

### K3s vs Standard Kubernetes

| Feature | K3s (POC) | Standard K8s |
|---------|-----------|--------------|
| etcd | SQLite (embedded) | External etcd cluster |
| Container Runtime | containerd | containerd/docker |
| CNI | Flannel (default) | Configurable |
| Ingress | Disabled (using Istio) | Configurable |
| Binary Size | ~50MB | ~500MB+ |
| Memory | ~512MB | ~1GB+ |

### Multi-Node Expansion (Production)

For production, K3s can be expanded to multi-node:

```
                    ┌─────────────────┐
                    │   LOAD BALANCER │
                    │   (HAProxy/LB)  │
                    └────────┬────────┘
                             │
         ┌───────────────────┼───────────────────┐
         │                   │                   │
         ▼                   ▼                   ▼
┌─────────────────┐ ┌─────────────────┐ ┌─────────────────┐
│  MASTER NODE 1  │ │  MASTER NODE 2  │ │  MASTER NODE 3  │
│  (Control Plane)│ │  (Control Plane)│ │  (Control Plane)│
│                 │ │                 │ │                 │
│  - API Server   │ │  - API Server   │ │  - API Server   │
│  - Scheduler    │ │  - Scheduler    │ │  - Scheduler    │
│  - Controller   │ │  - Controller   │ │  - Controller   │
│  - etcd         │ │  - etcd         │ │  - etcd         │
└─────────────────┘ └─────────────────┘ └─────────────────┘
         │                   │                   │
         └───────────────────┼───────────────────┘
                             │
         ┌───────────────────┼───────────────────┐
         │                   │                   │
         ▼                   ▼                   ▼
┌─────────────────┐ ┌─────────────────┐ ┌─────────────────┐
│  WORKER NODE 1  │ │  WORKER NODE 2  │ │  WORKER NODE 3  │
│                 │ │                 │ │                 │
│  - Kubelet      │ │  - Kubelet      │ │  - Kubelet      │
│  - Pods         │ │  - Pods         │ │  - Pods         │
│  - Istio Proxy  │ │  - Istio Proxy  │ │  - Istio Proxy  │
└─────────────────┘ └─────────────────┘ └─────────────────┘
```

---

## Database Configuration

### MySQL Configuration

**File:** `/etc/mysql/mysql.conf.d/stackbill.cnf`

```ini
[mysqld]
# Allow connections from any IP (for K8s pods)
bind-address = 0.0.0.0

# SQL mode for StackBill compatibility
sql_mode = NO_ENGINE_SUBSTITUTION,STRICT_TRANS_TABLES

# Connection timeouts
wait_timeout = 28800           # 8 hours
interactive_timeout = 230400   # 64 hours
connect_timeout = 36000        # 10 hours

# Connection limits
max_connections = 1000
max_connect_errors = 100000

# Performance optimizations
skip-host-cache
skip-name-resolve

# Required for Flyway migrations
log_bin_trust_function_creators = 1
```

**Databases Created:**
- `stackbill` - Main application database
- `configuration` - Configuration storage

**User Configuration:**
```sql
CREATE USER 'stackbill'@'%'
  IDENTIFIED WITH mysql_native_password BY '<password>';
GRANT ALL PRIVILEGES ON *.* TO 'stackbill'@'%' WITH GRANT OPTION;
```

> **Note:** `mysql_native_password` is used instead of `caching_sha2_password` for compatibility with older MySQL connectors.

### MongoDB Configuration

**File:** `/etc/mongod.conf`

```yaml
storage:
  dbPath: /var/lib/mongodb

systemLog:
  destination: file
  logAppend: true
  path: /var/log/mongodb/mongod.log

net:
  port: 27017
  bindIp: 0.0.0.0    # Allow external connections

processManagement:
  timeZoneInfo: /usr/share/zoneinfo

security:
  authorization: enabled    # Require authentication
```

**Encryption KeyFile:**
```bash
# Generated for encryption at rest
/var/lib/mongodb/encryption
# Permissions: 600, Owner: mongodb:mongodb
```

**User Configuration:**
```javascript
db.createUser({
  user: "stackbill",
  pwd: "<password>",
  roles: [
    { role: "root", db: "admin" },
    { role: "readWriteAnyDatabase", db: "admin" }
  ]
})
```

### RabbitMQ Configuration

**Plugins Enabled:**
- `rabbitmq_management` - Web UI on port 15672

**User Configuration:**
```bash
rabbitmqctl add_user stackbill <password>
rabbitmqctl set_user_tags stackbill administrator
rabbitmqctl set_permissions -p / stackbill ".*" ".*" ".*"
```

---

## Networking & Istio Service Mesh

### Network Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                    NETWORK TOPOLOGY                             │
└─────────────────────────────────────────────────────────────────┘

External Traffic Flow:
  Internet
      │
      ▼
  DNS: stackbill.example.com → Server Public IP
      │
      ▼
  Server IP:31882 (HTTPS) or :31443 (HTTP)
      │
      ▼
  Istio Ingress Gateway (NodePort Service)
      │
      ▼
  Virtual Service Routing Rules
      │
      ├──▶ /admin/*     → sb-admin:80
      ├──▶ /portal/*    → sb-ui:80
      ├──▶ /api/*       → sb-kong:8000
      └──▶ /core/*      → sb-core:8080

Internal Pod-to-Pod:
  Pod A (10.42.0.x)
      │
      ▼
  Istio Sidecar (Envoy Proxy)
      │
      ▼
  Service Discovery (CoreDNS)
      │
      ▼
  Target Pod (10.42.0.y)

Pod-to-Host Database:
  Pod (10.42.0.x)
      │
      ▼
  Host IP (e.g., 192.168.1.100)
      │
      ├──▶ MySQL:3306
      ├──▶ MongoDB:27017
      └──▶ RabbitMQ:5672
```

### Istio Components

**Ingress Gateway:**
```yaml
apiVersion: networking.istio.io/v1beta1
kind: Gateway
metadata:
  name: stackbill-gateway
  namespace: sb-apps
spec:
  selector:
    istio: ingressgateway
  servers:
  - port:
      number: 443
      name: https
      protocol: HTTPS
    tls:
      mode: SIMPLE
      credentialName: stackbill-tls-secret
    hosts:
    - "stackbill.example.com"
  - port:
      number: 80
      name: http
      protocol: HTTP
    hosts:
    - "stackbill.example.com"
```

**Virtual Service:**
```yaml
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: stackbill-vs
  namespace: sb-apps
spec:
  hosts:
  - "stackbill.example.com"
  gateways:
  - stackbill-gateway
  http:
  - match:
    - uri:
        prefix: /admin
    route:
    - destination:
        host: sb-admin
        port:
          number: 80
  # ... additional routes
```

### Port Mappings

| External Port | Internal Port | Service |
|---------------|---------------|---------|
| 31443 | 80 | HTTP (redirects to HTTPS) |
| 31882 | 443 | HTTPS (TLS termination) |

---

## Storage Architecture

### NFS Provisioner

```
┌─────────────────────────────────────────────────────────────────┐
│                    NFS STORAGE FLOW                             │
└─────────────────────────────────────────────────────────────────┘

Host:
  /data/stackbill (NFS Export)
      │
      │ Exported to: 10.42.0.0/16 (K8s pod network)
      ▼
K8s:
  ┌─────────────────────────────────────────┐
  │      nfs-client-provisioner Pod         │
  │                                         │
  │  Watches for PVC requests               │
  │  Creates directories in /data/stackbill │
  │  Mounts volumes to pods                 │
  └─────────────────────────────────────────┘
      │
      ▼
  ┌─────────────────────────────────────────┐
  │         PersistentVolumeClaim           │
  │  storageClassName: nfs-client           │
  └─────────────────────────────────────────┘
      │
      ▼
  ┌─────────────────────────────────────────┐
  │              Pod Volume Mount           │
  │  /app/data → /data/stackbill/<pvc-id>   │
  └─────────────────────────────────────────┘
```

### Storage Classes

| Class Name | Provisioner | Purpose |
|------------|-------------|---------|
| `nfs-client` | nfs-subdir-external-provisioner | Dynamic PV provisioning |
| `local-path` | rancher.io/local-path | K3s default (node-local) |

---

## Security Configuration

### TLS/SSL

```
┌─────────────────────────────────────────────────────────────────┐
│                    TLS CONFIGURATION                            │
└─────────────────────────────────────────────────────────────────┘

Certificate Chain:
  fullchain.pem
      │
      ├── Server Certificate
      └── Intermediate CA Certificate(s)

Private Key:
  privatekey.pem
      │
      └── RSA/ECDSA Private Key

Storage in Kubernetes:
  Secret: stackbill-tls-secret (namespace: sb-apps)
  Secret: istio-ingressgateway-certs (namespace: istio-system)

TLS Termination:
  Istio Ingress Gateway terminates TLS
  Internal traffic uses mTLS (Istio automatic)
```

### AWS ECR Authentication

```
┌─────────────────────────────────────────────────────────────────┐
│                ECR AUTHENTICATION FLOW (AUTOMATIC)              │
└─────────────────────────────────────────────────────────────────┘

1. Script installs AWS CLI (if not present):
   install_aws_cli()
   └── Downloads and installs AWS CLI v2

2. Script fetches ECR token automatically:
   fetch_ecr_token()
   ├── Uses embedded IAM credentials (pull-only permissions)
   ├── export AWS_ACCESS_KEY_ID="..."
   ├── export AWS_SECRET_ACCESS_KEY="..."
   └── AWS_ECR_TOKEN=$(aws ecr get-login-password --region ap-south-1)

3. Script creates Kubernetes secret:
   kubectl create secret docker-registry awscred \
     --docker-server=730335576030.dkr.ecr.ap-south-1.amazonaws.com \
     --docker-username=AWS \
     --docker-password=$AWS_ECR_TOKEN

4. Helm chart references secret:
   imagePullSecrets:
     - name: awscred

5. Kubelet uses secret to pull images:
   730335576030.dkr.ecr.ap-south-1.amazonaws.com/sb-core:latest

Security Note:
- IAM user has ONLY AmazonEC2ContainerRegistryPullOnly policy
- Can pull images: YES
- Can push/delete images: NO
- Can access other AWS services: NO
```

### Database Security

| Database | Authentication | Encryption |
|----------|----------------|------------|
| MySQL | mysql_native_password | In-transit (optional) |
| MongoDB | SCRAM-SHA-256 | At-rest (keyFile) |
| RabbitMQ | PLAIN | In-transit (optional) |

---

## Troubleshooting Guide

### Common Issues and Solutions

#### 1. White Page / Blank Screen

**Symptoms:** Browser shows blank white page

**Diagnosis:**
```bash
# Check API response
curl -k https://localhost:31882/apidocs/api/cloudconfiguration/general

# Check pod logs
kubectl logs -n sb-apps <sb-core-pod> -c sb-core
```

**Common Causes:**
- Database connection failure
- Missing initial configuration
- Kong routing misconfiguration

#### 2. ImagePullBackOff

**Symptoms:** Pods stuck in ImagePullBackOff state

**Diagnosis:**
```bash
kubectl describe pod <pod-name> -n sb-apps | grep -A10 Events
```

**Solutions:**
```bash
# Verify ECR secret exists
kubectl get secret awscred -n sb-apps

# If secret is missing, re-run the installer (it will recreate it)
sudo ./scripts/install-stackbill-poc.sh --domain YOUR_DOMAIN \
  --ssl-cert /path/to/cert.pem --ssl-key /path/to/key.pem \
  --skip-infra --skip-db

# Or manually fetch token and recreate (requires AWS CLI configured)
AWS_ECR_TOKEN=$(aws ecr get-login-password --region ap-south-1)
kubectl delete secret awscred -n sb-apps
kubectl create secret docker-registry awscred \
  --docker-server=730335576030.dkr.ecr.ap-south-1.amazonaws.com \
  --docker-username=AWS \
  --docker-password=$AWS_ECR_TOKEN \
  -n sb-apps
```

#### 3. MySQL Connection Refused

**Symptoms:** "Connection refused" or "Host blocked"

**Diagnosis:**
```bash
# From host
mysql -u stackbill -p -h localhost

# From pod
kubectl exec -it <pod> -n sb-apps -- nc -zv <host-ip> 3306
```

**Solutions:**
```bash
# Reset blocked hosts
mysqladmin flush-hosts

# Check bind address
grep bind-address /etc/mysql/mysql.conf.d/*.cnf

# Verify user permissions
mysql -u root -e "SELECT user, host FROM mysql.user WHERE user='stackbill';"
```

#### 4. MongoDB Authentication Failed

**Symptoms:** "Authentication failed" errors

**Diagnosis:**
```bash
# Test connection
mongosh -u stackbill -p <password> --authenticationDatabase admin

# Check logs
journalctl -u mongod -f
```

**Solutions:**
```bash
# If user doesn't exist, recreate
mongosh admin --eval "db.dropUser('stackbill')"
mongosh admin --eval "db.createUser({user:'stackbill', pwd:'<password>', roles:[{role:'root',db:'admin'}]})"
```

#### 5. Istio Gateway Not Working

**Symptoms:** 503 errors or no response

**Diagnosis:**
```bash
# Check gateway
kubectl get gateway -n sb-apps

# Check virtual service
kubectl get virtualservice -n sb-apps

# Check ingress gateway logs
kubectl logs -n istio-system -l app=istio-ingressgateway
```

**Solutions:**
```bash
# Recreate gateway
kubectl delete gateway -n sb-apps --all
kubectl apply -f gateway.yaml
```

### Useful Debugging Commands

```bash
# All pods status
kubectl get pods -n sb-apps -o wide

# Pod logs (with sidecar)
kubectl logs <pod> -n sb-apps -c <container>
kubectl logs <pod> -n sb-apps -c istio-proxy

# Describe pod for events
kubectl describe pod <pod> -n sb-apps

# Service endpoints
kubectl get endpoints -n sb-apps

# Istio proxy status
istioctl proxy-status

# Test internal connectivity
kubectl exec -it <pod> -n sb-apps -- curl http://sb-core:8080/health
```

---

## Quick Reference

### File Locations

| File | Purpose |
|------|---------|
| `/etc/mysql/mysql.conf.d/stackbill.cnf` | MySQL StackBill config |
| `/etc/mongod.conf` | MongoDB config |
| `/var/lib/mongodb/encryption` | MongoDB encryption key |
| `/data/stackbill/` | NFS shared storage |
| `~/stackbill-credentials.txt` | Saved credentials |
| `~/.kube/config` | Kubernetes config |

### Important Commands

```bash
# Install (ECR auth handled automatically)
sudo ./scripts/install-stackbill-poc.sh \
  --domain example.com \
  --ssl-cert /path/to/fullchain.pem \
  --ssl-key /path/to/privatekey.pem

# Uninstall (keep data)
./scripts/uninstall.sh

# Uninstall (delete everything)
./scripts/uninstall.sh --delete-pvc --delete-namespace --delete-db --force

# View credentials
cat ~/stackbill-credentials.txt

# Check status
kubectl get pods -n sb-apps
kubectl get svc -n sb-apps
kubectl get gateway,virtualservice -n sb-apps
```

---

## Version History

| Version | Date | Changes |
|---------|------|---------|
| 1.0.0 | 2024 | Initial release |

---

**Document maintained by:** StackBill Team
**Last updated:** $(date +%Y-%m-%d)
