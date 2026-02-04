#!/bin/bash
# ============================================
# STACKBILL POC INSTALLER - FULLY AUTOMATED
# ============================================
# Installs StackBill directly from AWS ECR
# NO UI wizard required - completely automated
#
# REQUIRED: Set AWS_ECR_TOKEN environment variable before running:
#   export AWS_ECR_TOKEN="your-ecr-token-here"
#
# Usage:
#   export AWS_ECR_TOKEN="eyJwYXlsb2..."
#   sudo -E ./install-stackbill-poc.sh --domain DOMAIN --ssl-cert CERT --ssl-key KEY
# ============================================

set -e
trap 'echo "ERROR: Script failed at line $LINENO with exit code $?" >&2' ERR

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Configuration
STACKBILL_NAMESPACE="sb-apps"
K3S_VERSION="v1.29.0+k3s1"
ISTIO_VERSION="1.20.3"
STACKBILL_CHART="oci://public.ecr.aws/p0g2c5k8/stackbill"
ECR_REGISTRY="730335576030.dkr.ecr.ap-south-1.amazonaws.com"

# User inputs
DOMAIN=""
SSL_CERT=""
SSL_KEY=""
EMAIL="admin@stackbill.local"

# Auto-generated passwords
MYSQL_PASSWORD=""
MONGODB_PASSWORD=""
RABBITMQ_PASSWORD=""
SERVER_IP=""

# Flags
SKIP_INFRA=false
SKIP_DB=false

# Logging
log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() {
    echo ""
    echo -e "${BLUE}════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}════════════════════════════════════════════════════════════════${NC}"
}

print_banner() {
    echo -e "${CYAN}"
    echo "╔═══════════════════════════════════════════════════════════════╗"
    echo "║         STACKBILL POC INSTALLER - FULLY AUTOMATED            ║"
    echo "╠═══════════════════════════════════════════════════════════════╣"
    echo "║  This script installs StackBill automatically:               ║"
    echo "║    - K3s Kubernetes with Istio service mesh                  ║"
    echo "║    - MySQL, MongoDB, RabbitMQ on host                        ║"
    echo "║    - StackBill from AWS ECR (no UI wizard needed)            ║"
    echo "║                                                               ║"
    echo "║  REQUIRED: Set AWS_ECR_TOKEN env variable before running!    ║"
    echo "╚═══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

generate_password() {
    openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 16
}

CREDENTIALS_FILE="$HOME/stackbill-credentials.txt"

load_or_generate_passwords() {
    # Check if credentials file exists from a previous installation
    if [[ -f "$CREDENTIALS_FILE" ]]; then
        log_info "Found existing credentials file: $CREDENTIALS_FILE"

        # Extract passwords from credentials file
        local mysql_pw=$(grep -A5 "^MYSQL:" "$CREDENTIALS_FILE" | grep "Password:" | awk '{print $2}')
        local mongo_pw=$(grep -A5 "^MONGODB:" "$CREDENTIALS_FILE" | grep "Password:" | awk '{print $2}')
        local rabbit_pw=$(grep -A5 "^RABBITMQ:" "$CREDENTIALS_FILE" | grep "Password:" | awk '{print $2}')

        # Use existing passwords if found, otherwise generate new
        if [[ -n "$mysql_pw" && -n "$mongo_pw" && -n "$rabbit_pw" ]]; then
            MYSQL_PASSWORD="$mysql_pw"
            MONGODB_PASSWORD="$mongo_pw"
            RABBITMQ_PASSWORD="$rabbit_pw"
            log_info "Loaded existing passwords from credentials file"
            log_info "  (To generate new passwords, delete $CREDENTIALS_FILE and re-run)"
            return 0
        else
            log_warn "Credentials file incomplete, generating new passwords"
        fi
    fi

    # Generate new passwords
    log_info "Generating new passwords..."
    MYSQL_PASSWORD=$(generate_password)
    MONGODB_PASSWORD=$(generate_password)
    RABBITMQ_PASSWORD=$(generate_password)
    log_info "New passwords generated"
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --domain) DOMAIN="$2"; shift 2 ;;
            --ssl-cert) SSL_CERT="$2"; shift 2 ;;
            --ssl-key) SSL_KEY="$2"; shift 2 ;;
            --email) EMAIL="$2"; shift 2 ;;
            --skip-infra) SKIP_INFRA=true; shift ;;
            --skip-db) SKIP_DB=true; shift ;;
            -h|--help) show_help; exit 0 ;;
            *) log_error "Unknown option: $1"; exit 1 ;;
        esac
    done
    return 0
}

show_help() {
    echo "Usage: $0 --domain DOMAIN --ssl-cert CERT --ssl-key KEY [OPTIONS]"
    echo ""
    echo "IMPORTANT: Set AWS_ECR_TOKEN environment variable before running!"
    echo ""
    echo "Example:"
    echo "  export AWS_ECR_TOKEN=\"your-ecr-token-here\""
    echo "  sudo -E $0 --domain stackbill.example.com --ssl-cert /path/to/cert.pem --ssl-key /path/to/key.pem"
    echo ""
    echo "Required:"
    echo "  AWS_ECR_TOKEN  Environment variable with ECR authentication token"
    echo "  --domain       Domain name for StackBill (e.g., stackbill.example.com)"
    echo "  --ssl-cert     Path to SSL certificate file (fullchain.pem)"
    echo "  --ssl-key      Path to SSL private key file (privatekey.pem)"
    echo ""
    echo "Optional:"
    echo "  --email        Email for notifications (default: admin@stackbill.local)"
    echo "  --skip-infra   Skip K3s/Istio installation (use existing cluster)"
    echo "  --skip-db      Skip database installation (use existing databases)"
    echo "  -h, --help     Show this help message"
}

validate_inputs() {
    log_info "Validating inputs..."

    # Check AWS ECR token
    if [[ -z "$AWS_ECR_TOKEN" ]]; then
        log_error "AWS_ECR_TOKEN environment variable is required"
        echo ""
        echo "Please set the ECR token before running:"
        echo "  export AWS_ECR_TOKEN=\"your-token-here\""
        echo "  sudo -E $0 --domain DOMAIN --ssl-cert CERT --ssl-key KEY"
        echo ""
        echo "Note: Use 'sudo -E' to preserve environment variables"
        exit 1
    fi
    log_info "  AWS ECR Token: [set]"

    if [[ -z "$DOMAIN" ]]; then
        log_error "Domain required (--domain)"
        exit 1
    fi
    log_info "  Domain: $DOMAIN"

    if [[ -z "$SSL_CERT" || ! -f "$SSL_CERT" ]]; then
        log_error "SSL certificate file not found: $SSL_CERT"
        exit 1
    fi
    log_info "  SSL Cert: $SSL_CERT"

    if [[ -z "$SSL_KEY" || ! -f "$SSL_KEY" ]]; then
        log_error "SSL key file not found: $SSL_KEY"
        exit 1
    fi
    log_info "  SSL Key: $SSL_KEY"

    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root (use sudo)"
        exit 1
    fi
    log_info "  Running as root: yes"

    log_info "Validation passed!"
    return 0
}

get_server_ip() {
    SERVER_IP=$(hostname -I | awk '{print $1}')
    log_info "Server IP: $SERVER_IP"
}

# ============================================
# INFRASTRUCTURE
# ============================================

install_k3s() {
    log_step "Installing K3s Kubernetes"

    if command -v k3s &>/dev/null && kubectl cluster-info &>/dev/null 2>&1; then
        log_info "K3s already installed and running"
        return 0
    fi

    curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="$K3S_VERSION" sh -s - \
        --write-kubeconfig-mode 644 \
        --disable traefik \
        --disable servicelb

    sleep 10
    mkdir -p ~/.kube
    cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
    chmod 600 ~/.kube/config
    export KUBECONFIG=~/.kube/config

    kubectl wait --for=condition=ready node --all --timeout=120s
    log_info "K3s installed successfully"
}

install_helm() {
    log_step "Installing Helm"

    if command -v helm &>/dev/null; then
        log_info "Helm already installed"
        return 0
    fi

    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
    log_info "Helm installed successfully"
}

install_istio() {
    log_step "Installing Istio Service Mesh"

    if kubectl get namespace istio-system &>/dev/null 2>&1; then
        if kubectl get pods -n istio-system -l app=istiod --no-headers 2>/dev/null | grep -q Running; then
            log_info "Istio already running"
            return 0
        fi
    fi

    if ! command -v istioctl &>/dev/null; then
        pushd /tmp > /dev/null
        curl -L https://istio.io/downloadIstio | ISTIO_VERSION=$ISTIO_VERSION sh -
        mv istio-$ISTIO_VERSION/bin/istioctl /usr/local/bin/
        rm -rf istio-$ISTIO_VERSION
        popd > /dev/null
    fi

    istioctl install --set profile=demo -y
    kubectl wait --for=condition=ready pod -l app=istiod -n istio-system --timeout=300s
    log_info "Istio installed successfully"
}

# ============================================
# DATABASES ON HOST
# ============================================

install_mysql() {
    log_step "Installing MySQL"

    if systemctl is-active --quiet mysql 2>/dev/null; then
        log_info "MySQL already running"
        # Update user with native password authentication
        mysql -u root <<EOF || true
ALTER USER 'stackbill'@'%' IDENTIFIED WITH mysql_native_password BY '${MYSQL_PASSWORD}';
ALTER USER 'stackbill'@'localhost' IDENTIFIED WITH mysql_native_password BY '${MYSQL_PASSWORD}';
GRANT ALL PRIVILEGES ON *.* TO 'stackbill'@'%' WITH GRANT OPTION;
GRANT ALL PRIVILEGES ON *.* TO 'stackbill'@'localhost' WITH GRANT OPTION;
FLUSH PRIVILEGES;
EOF
        return 0
    fi

    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq mysql-server mysql-client

    systemctl start mysql
    systemctl enable mysql

    for i in {1..30}; do
        mysqladmin ping -h localhost --silent 2>/dev/null && break
        sleep 2
    done

    # Configure MySQL for StackBill
    cat > /etc/mysql/mysql.conf.d/stackbill.cnf <<'MYSQLCONF'
[mysqld]
bind-address = 0.0.0.0
sql_mode = NO_ENGINE_SUBSTITUTION,STRICT_TRANS_TABLES
wait_timeout = 28800
interactive_timeout = 230400
connect_timeout = 36000
max_connections = 1000
max_connect_errors = 100000
skip-host-cache
skip-name-resolve
log_bin_trust_function_creators = 1
MYSQLCONF

    systemctl restart mysql

    for i in {1..30}; do
        mysqladmin ping -h localhost --silent 2>/dev/null && break
        sleep 2
    done

    # Create databases and users with native password authentication
    mysql -u root <<EOF
CREATE DATABASE IF NOT EXISTS stackbill;
CREATE DATABASE IF NOT EXISTS feature_configuration;
CREATE USER IF NOT EXISTS 'stackbill'@'%' IDENTIFIED WITH mysql_native_password BY '${MYSQL_PASSWORD}';
CREATE USER IF NOT EXISTS 'stackbill'@'localhost' IDENTIFIED WITH mysql_native_password BY '${MYSQL_PASSWORD}';
GRANT ALL PRIVILEGES ON *.* TO 'stackbill'@'%' WITH GRANT OPTION;
GRANT ALL PRIVILEGES ON *.* TO 'stackbill'@'localhost' WITH GRANT OPTION;
SET GLOBAL log_bin_trust_function_creators = 1;
SET GLOBAL max_connect_errors = 100000;
FLUSH PRIVILEGES;
EOF

    log_info "MySQL installed with StackBill configuration - User: stackbill"
}

install_mongodb() {
    log_step "Installing MongoDB"

    if systemctl is-active --quiet mongod 2>/dev/null; then
        log_info "MongoDB already running"
        return 0
    fi

    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y -qq gnupg curl

    curl -fsSL https://www.mongodb.org/static/pgp/server-7.0.asc | gpg --dearmor -o /usr/share/keyrings/mongodb-server-7.0.gpg 2>/dev/null || true
    echo "deb [ arch=amd64,arm64 signed-by=/usr/share/keyrings/mongodb-server-7.0.gpg ] https://repo.mongodb.org/apt/ubuntu jammy/mongodb-org/7.0 multiverse" | tee /etc/apt/sources.list.d/mongodb-org-7.0.list

    apt-get update -qq
    apt-get install -y -qq mongodb-org

    # Create directories
    mkdir -p /var/lib/mongodb
    mkdir -p /var/log/mongodb
    chown -R mongodb:mongodb /var/lib/mongodb
    chown -R mongodb:mongodb /var/log/mongodb

    # Generate encryption keyFile
    log_info "Generating MongoDB encryption keyFile..."
    openssl rand -base64 32 | head -c 64 > /var/lib/mongodb/encryption
    chown mongodb:mongodb /var/lib/mongodb/encryption
    chmod 600 /var/lib/mongodb/encryption

    # Create MongoDB configuration
    cat > /etc/mongod.conf <<'EOF'
storage:
  dbPath: /var/lib/mongodb
systemLog:
  destination: file
  logAppend: true
  path: /var/log/mongodb/mongod.log
net:
  port: 27017
  bindIp: 0.0.0.0
processManagement:
  timeZoneInfo: /usr/share/zoneinfo
EOF

    systemctl start mongod
    systemctl enable mongod

    for i in {1..30}; do
        mongosh --quiet --eval "db.runCommand('ping').ok" 2>/dev/null && break
        sleep 2
    done

    # Create admin user
    mongosh --quiet <<EOF || true
use admin
db.createUser({
  user: "stackbill",
  pwd: "${MONGODB_PASSWORD}",
  roles: [
    { role: "root", db: "admin" },
    { role: "readWriteAnyDatabase", db: "admin" }
  ]
})
EOF

    # Enable security settings
    cat >> /etc/mongod.conf <<'EOF'

# Security settings
security:
  authorization: enabled
EOF

    systemctl restart mongod

    for i in {1..30}; do
        mongosh --quiet -u stackbill -p "${MONGODB_PASSWORD}" --authenticationDatabase admin --eval "db.runCommand('ping').ok" 2>/dev/null && break
        sleep 2
    done

    log_info "MongoDB installed with security enabled - User: stackbill"
}

install_rabbitmq() {
    log_step "Installing RabbitMQ"

    if systemctl is-active --quiet rabbitmq-server 2>/dev/null; then
        log_info "RabbitMQ already running"
        rabbitmqctl add_user stackbill "${RABBITMQ_PASSWORD}" 2>/dev/null || \
            rabbitmqctl change_password stackbill "${RABBITMQ_PASSWORD}" 2>/dev/null || true
        rabbitmqctl set_user_tags stackbill administrator 2>/dev/null || true
        rabbitmqctl set_permissions -p / stackbill ".*" ".*" ".*" 2>/dev/null || true
        return 0
    fi

    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq rabbitmq-server

    systemctl start rabbitmq-server
    systemctl enable rabbitmq-server

    for i in {1..30}; do
        rabbitmqctl status &>/dev/null && break
        sleep 2
    done

    rabbitmq-plugins enable rabbitmq_management
    rabbitmqctl add_user stackbill "${RABBITMQ_PASSWORD}" 2>/dev/null || \
        rabbitmqctl change_password stackbill "${RABBITMQ_PASSWORD}"
    rabbitmqctl set_user_tags stackbill administrator
    rabbitmqctl set_permissions -p / stackbill ".*" ".*" ".*"
    rabbitmqctl delete_user guest 2>/dev/null || true

    log_info "RabbitMQ installed - User: stackbill"
}

setup_nfs() {
    log_step "Setting up NFS Storage"

    apt-get install -y -qq nfs-kernel-server nfs-common
    mkdir -p /data/stackbill
    chmod 777 /data/stackbill

    if ! grep -q "/data/stackbill" /etc/exports 2>/dev/null; then
        echo "/data/stackbill *(rw,sync,no_subtree_check,no_root_squash)" >> /etc/exports
    fi

    exportfs -a
    systemctl restart nfs-kernel-server
    log_info "NFS configured at /data/stackbill"
}

# ============================================
# DEPLOY STACKBILL DIRECTLY FROM ECR
# ============================================

setup_namespace() {
    log_step "Setting up Kubernetes Namespace"

    if ! kubectl get namespace $STACKBILL_NAMESPACE &>/dev/null; then
        kubectl create namespace $STACKBILL_NAMESPACE
    fi
    kubectl label namespace $STACKBILL_NAMESPACE istio-injection=enabled --overwrite

    log_info "Namespace $STACKBILL_NAMESPACE ready"
}

setup_ecr_credentials() {
    log_step "Setting up AWS ECR Credentials"

    # Delete existing secret if present
    kubectl delete secret awscred -n $STACKBILL_NAMESPACE 2>/dev/null || true

    # Create docker-registry secret for AWS ECR
    kubectl create secret docker-registry awscred \
        --docker-server="$ECR_REGISTRY" \
        --docker-username=AWS \
        --docker-password="$AWS_ECR_TOKEN" \
        -n $STACKBILL_NAMESPACE

    log_info "ECR credentials secret 'awscred' created"
}

setup_tls_secret() {
    log_step "Setting up TLS Secret"

    kubectl create secret tls istio-ingressgateway-certs \
        --cert="$SSL_CERT" \
        --key="$SSL_KEY" \
        -n istio-system \
        --dry-run=client -o yaml | kubectl apply -f -

    log_info "TLS secret created in istio-system"
}

deploy_stackbill() {
    log_step "Deploying StackBill from ECR"

    log_info "Pulling chart from: $STACKBILL_CHART"

    # Install StackBill directly from ECR
    helm upgrade --install stackbill "$STACKBILL_CHART" \
        --namespace $STACKBILL_NAMESPACE \
        --set global.domain="$DOMAIN" \
        --set global.nfs.server="$SERVER_IP" \
        --set global.nfs.path="/data/stackbill" \
        --set global.mysql.ip="$SERVER_IP" \
        --set global.mysql.username="stackbill" \
        --set global.mysql.password="$MYSQL_PASSWORD" \
        --set global.mongo.ip="$SERVER_IP" \
        --set global.mongo.username="stackbill" \
        --set global.mongo.password="$MONGODB_PASSWORD" \
        --set global.rabbitmq.ip="$SERVER_IP" \
        --set global.rabbitmq.username="stackbill" \
        --set global.rabbitmq.password="$RABBITMQ_PASSWORD" \
        --timeout 600s \
        --wait

    log_info "StackBill deployed successfully!"
}

setup_istio_gateway() {
    log_step "Setting up Istio Gateway"

    # Create Gateway for HTTPS
    kubectl apply -f - <<EOF
apiVersion: networking.istio.io/v1beta1
kind: Gateway
metadata:
  name: stackbill-gateway
  namespace: $STACKBILL_NAMESPACE
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
      credentialName: istio-ingressgateway-certs
    hosts:
    - "$DOMAIN"
  - port:
      number: 80
      name: http
      protocol: HTTP
    tls:
      httpsRedirect: true
    hosts:
    - "$DOMAIN"
EOF

    # Patch Istio ingress gateway to use NodePort
    kubectl patch svc istio-ingressgateway -n istio-system --type='json' -p='[
        {"op": "replace", "path": "/spec/type", "value": "NodePort"},
        {"op": "replace", "path": "/spec/ports/0/nodePort", "value": 31080},
        {"op": "replace", "path": "/spec/ports/1/nodePort", "value": 31443}
    ]' 2>/dev/null || log_warn "Could not patch ingress gateway ports"

    log_info "Istio Gateway configured"
}

wait_for_pods() {
    log_step "Waiting for StackBill Pods"

    log_info "Waiting for pods to be ready (this may take several minutes)..."

    # Wait up to 10 minutes for pods
    local timeout=600
    local elapsed=0
    local interval=10

    while [[ $elapsed -lt $timeout ]]; do
        local ready=$(kubectl get pods -n $STACKBILL_NAMESPACE --no-headers 2>/dev/null | grep -c "Running" || echo "0")
        local total=$(kubectl get pods -n $STACKBILL_NAMESPACE --no-headers 2>/dev/null | wc -l || echo "0")

        log_info "  Pods ready: $ready / $total"

        if [[ $total -gt 0 && $ready -eq $total ]]; then
            log_info "All pods are running!"
            break
        fi

        sleep $interval
        elapsed=$((elapsed + interval))
    done

    echo ""
    kubectl get pods -n $STACKBILL_NAMESPACE
}

# ============================================
# SAVE & SUMMARY
# ============================================

save_credentials() {
    cat > "$CREDENTIALS_FILE" <<EOF
================================================================================
STACKBILL POC CREDENTIALS
Generated: $(date)
================================================================================

PORTAL URL: https://$DOMAIN

SERVER IP: $SERVER_IP

MYSQL:
  Host: $SERVER_IP
  Port: 3306
  Database: stackbill
  Username: stackbill
  Password: $MYSQL_PASSWORD

MONGODB:
  Host: $SERVER_IP
  Port: 27017
  Database: admin
  Username: stackbill
  Password: $MONGODB_PASSWORD

RABBITMQ:
  Host: $SERVER_IP
  Port: 5672
  Username: stackbill
  Password: $RABBITMQ_PASSWORD
  Management: http://$SERVER_IP:15672

NFS:
  Server: $SERVER_IP
  Path: /data/stackbill

================================================================================
EOF
    chmod 600 "$CREDENTIALS_FILE"
    log_info "Credentials saved to: $CREDENTIALS_FILE"
}

print_summary() {
    echo ""
    echo -e "${GREEN}════════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}              STACKBILL INSTALLATION COMPLETE!                  ${NC}"
    echo -e "${GREEN}════════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${CYAN}ACCESS STACKBILL:${NC}"
    echo "  Portal: https://$DOMAIN"
    echo "  (Make sure DNS points $DOMAIN to $SERVER_IP)"
    echo ""
    echo -e "${CYAN}DIRECT ACCESS (if DNS not configured):${NC}"
    echo "  HTTP:  http://$SERVER_IP:31080"
    echo "  HTTPS: https://$SERVER_IP:31443"
    echo ""
    echo -e "${CYAN}SERVICE CREDENTIALS:${NC}"
    echo "  MySQL:    stackbill / $MYSQL_PASSWORD"
    echo "  MongoDB:  stackbill / $MONGODB_PASSWORD"
    echo "  RabbitMQ: stackbill / $RABBITMQ_PASSWORD"
    echo ""
    echo -e "${YELLOW}Credentials saved to: $HOME/stackbill-credentials.txt${NC}"
    echo ""
    echo -e "${CYAN}USEFUL COMMANDS:${NC}"
    echo "  kubectl get pods -n $STACKBILL_NAMESPACE"
    echo "  kubectl logs -f <pod-name> -n $STACKBILL_NAMESPACE"
    echo "  cat $HOME/stackbill-credentials.txt"
    echo ""
}

# ============================================
# MAIN
# ============================================

main() {
    print_banner
    log_info "Starting fully automated installation..."

    parse_args "$@"
    validate_inputs
    get_server_ip

    # Load existing or generate new passwords
    load_or_generate_passwords

    # Infrastructure
    if [[ "$SKIP_INFRA" != "true" ]]; then
        install_k3s
        install_helm
        install_istio
    fi

    # Databases on host
    if [[ "$SKIP_DB" != "true" ]]; then
        install_mysql
        install_mongodb
        install_rabbitmq
        setup_nfs
    fi

    # Deploy StackBill directly
    setup_namespace
    setup_ecr_credentials
    setup_tls_secret
    deploy_stackbill
    setup_istio_gateway
    wait_for_pods

    # Save and summarize
    save_credentials
    print_summary
}

main "$@"
