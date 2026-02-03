#!/bin/bash
# ============================================
# STACKBILL POC INSTALLER - CLEAN VERSION
# ============================================
# Uses the OFFICIAL sb-deployment-controller chart
#
# This script:
# 1. Installs K3s, Helm, Istio (if needed)
# 2. Installs MySQL, MongoDB, RabbitMQ on HOST
# 3. Deploys official sb-deployment-controller
# 4. Tries to auto-configure via API
# 5. Falls back to manual UI if needed
#
# Usage:
#   sudo ./install-stackbill-poc.sh --domain DOMAIN --ssl-cert CERT --ssl-key KEY
# ============================================

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Configuration
NAMESPACE="sb-system"
K3S_VERSION="v1.29.0+k3s1"
ISTIO_VERSION="1.20.3"

# Script location
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART_DIR="$(dirname "$SCRIPT_DIR")"
CONTROLLER_CHART="$CHART_DIR/sb-deployment-controller"

# User inputs
DOMAIN=""
SSL_CERT=""
SSL_KEY=""
EMAIL="admin@stackbill.local"

# Auto-generated passwords
MYSQL_PASSWORD=""
MONGODB_PASSWORD=""
RABBITMQ_PASSWORD=""

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

# Banner
print_banner() {
    echo -e "${CYAN}"
    echo "╔═══════════════════════════════════════════════════════════════╗"
    echo "║           STACKBILL POC INSTALLER (Clean Version)            ║"
    echo "╠═══════════════════════════════════════════════════════════════╣"
    echo "║  This script installs StackBill using:                       ║"
    echo "║    - Official sb-deployment-controller Helm chart            ║"
    echo "║    - Host-installed MySQL, MongoDB, RabbitMQ                 ║"
    echo "║    - K3s Kubernetes with Istio service mesh                  ║"
    echo "╚═══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

# Generate password
generate_password() {
    openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 16
}

# Parse arguments
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
            *) log_error "Unknown: $1"; exit 1 ;;
        esac
    done
}

show_help() {
    echo "Usage: $0 --domain DOMAIN --ssl-cert CERT --ssl-key KEY [OPTIONS]"
    echo ""
    echo "Required:"
    echo "  --domain      Domain name for StackBill"
    echo "  --ssl-cert    Path to SSL certificate file"
    echo "  --ssl-key     Path to SSL private key file"
    echo ""
    echo "Optional:"
    echo "  --email       Email for notifications (default: admin@stackbill.local)"
    echo "  --skip-infra  Skip K3s/Istio installation"
    echo "  --skip-db     Skip database installation"
}

validate_inputs() {
    [[ -z "$DOMAIN" ]] && { log_error "Domain required (--domain)"; exit 1; }
    [[ -z "$SSL_CERT" || ! -f "$SSL_CERT" ]] && { log_error "SSL cert not found: $SSL_CERT"; exit 1; }
    [[ -z "$SSL_KEY" || ! -f "$SSL_KEY" ]] && { log_error "SSL key not found: $SSL_KEY"; exit 1; }
    [[ ! -d "$CONTROLLER_CHART" ]] && { log_error "Controller chart not found at: $CONTROLLER_CHART"; exit 1; }
    [[ $EUID -ne 0 ]] && { log_error "Run as root (sudo)"; exit 1; }
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
    log_info "K3s installed"
}

install_helm() {
    log_step "Installing Helm"

    if command -v helm &>/dev/null; then
        log_info "Helm already installed"
        return 0
    fi

    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
    log_info "Helm installed"
}

install_istio() {
    log_step "Installing Istio"

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
    log_info "Istio installed"
}

# ============================================
# DATABASES ON HOST
# ============================================

install_mysql() {
    log_step "Installing MySQL"

    if systemctl is-active --quiet mysql 2>/dev/null; then
        log_info "MySQL already running"
        mysql -u root -e "CREATE USER IF NOT EXISTS 'stackbill'@'%' IDENTIFIED BY '${MYSQL_PASSWORD}';" 2>/dev/null || true
        mysql -u root -e "GRANT ALL PRIVILEGES ON *.* TO 'stackbill'@'%' WITH GRANT OPTION; FLUSH PRIVILEGES;" 2>/dev/null || true
        return 0
    fi

    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq mysql-server mysql-client

    systemctl start mysql
    systemctl enable mysql

    # Wait for MySQL
    for i in {1..30}; do
        mysqladmin ping -h localhost --silent 2>/dev/null && break
        sleep 2
    done

    # Configure
    mysql -u root <<EOF
CREATE DATABASE IF NOT EXISTS stackbill;
CREATE USER IF NOT EXISTS 'stackbill'@'%' IDENTIFIED BY '${MYSQL_PASSWORD}';
CREATE USER IF NOT EXISTS 'stackbill'@'localhost' IDENTIFIED BY '${MYSQL_PASSWORD}';
GRANT ALL PRIVILEGES ON *.* TO 'stackbill'@'%' WITH GRANT OPTION;
GRANT ALL PRIVILEGES ON *.* TO 'stackbill'@'localhost' WITH GRANT OPTION;
FLUSH PRIVILEGES;
EOF

    # Allow remote connections
    sed -i 's/bind-address\s*=\s*127.0.0.1/bind-address = 0.0.0.0/' /etc/mysql/mysql.conf.d/mysqld.cnf 2>/dev/null || true
    systemctl restart mysql

    log_info "MySQL installed - User: stackbill"
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

    # Configure for remote access (no auth first)
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

    mkdir -p /var/lib/mongodb
    chown -R mongodb:mongodb /var/lib/mongodb
    systemctl start mongod
    systemctl enable mongod

    # Wait for MongoDB
    for i in {1..30}; do
        mongosh --quiet --eval "db.runCommand('ping').ok" 2>/dev/null && break
        sleep 2
    done

    # Create user
    mongosh --quiet <<EOF
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

    # Enable auth and restart
    cat >> /etc/mongod.conf <<'EOF'
security:
  authorization: enabled
EOF
    systemctl restart mongod

    log_info "MongoDB installed - User: stackbill"
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

    # Wait for RabbitMQ
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

    log_info "RabbitMQ installed - User: stackbill, Management: http://$SERVER_IP:15672"
}

setup_nfs() {
    log_step "Setting up NFS Storage"

    apt-get install -y -qq nfs-kernel-server
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
# DEPLOY CONTROLLER
# ============================================

deploy_controller() {
    log_step "Deploying sb-deployment-controller"

    # Create namespace
    kubectl create namespace $NAMESPACE 2>/dev/null || true
    kubectl label namespace $NAMESPACE istio-injection=enabled --overwrite 2>/dev/null || true

    # Create sb-apps namespace for StackBill pods
    kubectl create namespace sb-apps 2>/dev/null || true
    kubectl label namespace sb-apps istio-injection=enabled --overwrite 2>/dev/null || true

    # Deploy official controller chart
    log_info "Deploying from: $CONTROLLER_CHART"

    cd "$CONTROLLER_CHART"
    helm dependency update . 2>/dev/null || helm dependency build . 2>/dev/null || true

    helm upgrade --install sb-deployment-controller . \
        --namespace $NAMESPACE \
        --timeout 300s \
        --wait

    log_info "Controller deployed"

    # Wait for pod
    log_info "Waiting for controller pod..."
    kubectl wait --for=condition=ready pod -l app=sb-deployment-controller -n $NAMESPACE --timeout=180s

    kubectl get pods -n $NAMESPACE
}

setup_ingress() {
    log_step "Setting up Ingress Access"

    # Patch Istio ingress gateway to NodePort
    kubectl patch svc istio-ingressgateway -n istio-system --type='json' -p='[
        {"op": "replace", "path": "/spec/type", "value": "NodePort"},
        {"op": "add", "path": "/spec/ports/0/nodePort", "value": 31080},
        {"op": "add", "path": "/spec/ports/1/nodePort", "value": 31443}
    ]' 2>/dev/null || log_warn "Could not patch ingress gateway"

    log_info "Access controller at: http://$SERVER_IP:31080"
}

# ============================================
# AUTO-CONFIGURE VIA API
# ============================================

try_auto_configure() {
    log_step "Attempting Auto-Configuration via API"

    local POD_NAME=$(kubectl get pods -n $NAMESPACE -l app=sb-deployment-controller -o jsonpath='{.items[0].metadata.name}')
    log_info "Controller pod: $POD_NAME"

    # Discover what's inside the container
    log_info "Inspecting controller container..."
    kubectl exec -n $NAMESPACE "$POD_NAME" -- ls -la /app/ 2>/dev/null | head -10 || true
    kubectl exec -n $NAMESPACE "$POD_NAME" -- cat /app/package.json 2>/dev/null | head -20 || true

    # Port-forward
    log_info "Setting up port-forward..."
    kubectl port-forward "pod/$POD_NAME" 8888:3000 -n $NAMESPACE &
    local PF_PID=$!
    sleep 5

    # Probe endpoints
    log_info "Probing API endpoints..."
    for endpoint in "/" "/api" "/health" "/api/health" "/api/status"; do
        local code=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:8888$endpoint" 2>/dev/null || echo "000")
        [[ "$code" != "000" ]] && log_info "  $endpoint -> HTTP $code"
    done

    # Try to find API routes by checking common patterns
    log_info "Trying POST endpoints..."

    local PAYLOAD=$(cat <<EOF
{
    "mysql": {"host": "$SERVER_IP", "port": 3306, "database": "stackbill", "username": "stackbill", "password": "$MYSQL_PASSWORD"},
    "mongodb": {"host": "$SERVER_IP", "port": 27017, "database": "stackbill_usage", "username": "stackbill", "password": "$MONGODB_PASSWORD"},
    "rabbitmq": {"host": "$SERVER_IP", "port": 5672, "username": "stackbill", "password": "$RABBITMQ_PASSWORD"},
    "nfs": {"server": "$SERVER_IP", "path": "/data/stackbill"},
    "domain": "$DOMAIN",
    "email": "$EMAIL",
    "ssl": {"certificate": "$(base64 -w0 < "$SSL_CERT")", "privateKey": "$(base64 -w0 < "$SSL_KEY")"}
}
EOF
)

    local CONFIG_SUCCESS=false
    for endpoint in "/api/configure" "/api/setup" "/api/deploy" "/api/install" "/configure" "/setup" "/deploy"; do
        local response=$(curl -s -w "\n%{http_code}" -X POST "http://localhost:8888$endpoint" \
            -H "Content-Type: application/json" -d "$PAYLOAD" 2>/dev/null || echo -e "\n000")
        local code=$(echo "$response" | tail -n1)

        if [[ "$code" == "200" || "$code" == "201" || "$code" == "202" ]]; then
            log_info "SUCCESS via $endpoint (HTTP $code)"
            CONFIG_SUCCESS=true
            break
        elif [[ "$code" != "404" && "$code" != "000" ]]; then
            log_info "  $endpoint -> HTTP $code"
        fi
    done

    kill $PF_PID 2>/dev/null || true

    if [[ "$CONFIG_SUCCESS" == "true" ]]; then
        log_info "Auto-configuration successful!"
        sleep 30
        kubectl get pods -n sb-apps 2>/dev/null || true
    else
        log_warn "Auto-configuration via API not available"
        log_info "Please use the UI to complete configuration"
    fi
}

# ============================================
# SAVE & SUMMARY
# ============================================

save_credentials() {
    local CREDS_FILE="$HOME/stackbill-credentials.txt"

    cat > "$CREDS_FILE" <<EOF
================================================================================
STACKBILL POC CREDENTIALS
Generated: $(date)
================================================================================

DOMAIN: https://$DOMAIN

MYSQL:
  Host: $SERVER_IP
  Port: 3306
  Database: stackbill
  Username: stackbill
  Password: $MYSQL_PASSWORD

MONGODB:
  Host: $SERVER_IP
  Port: 27017
  Database: stackbill_usage
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
    chmod 600 "$CREDS_FILE"
    log_info "Credentials saved to: $CREDS_FILE"
}

print_summary() {
    echo ""
    echo -e "${GREEN}════════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}                    INSTALLATION COMPLETE                        ${NC}"
    echo -e "${GREEN}════════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${CYAN}ACCESS THE CONTROLLER UI:${NC}"
    echo "  http://$SERVER_IP:31080"
    echo ""
    echo -e "${CYAN}ENTER THESE CREDENTIALS IN THE UI:${NC}"
    echo ""
    echo "  MySQL:"
    echo "    Server IP: $SERVER_IP"
    echo "    Username:  stackbill"
    echo "    Password:  $MYSQL_PASSWORD"
    echo ""
    echo "  MongoDB:"
    echo "    Server IP: $SERVER_IP"
    echo "    Username:  stackbill"
    echo "    Password:  $MONGODB_PASSWORD"
    echo ""
    echo "  RabbitMQ:"
    echo "    Server IP: $SERVER_IP"
    echo "    Username:  stackbill"
    echo "    Password:  $RABBITMQ_PASSWORD"
    echo ""
    echo "  NFS Storage:"
    echo "    Server:    $SERVER_IP"
    echo "    Path:      /data/stackbill"
    echo ""
    echo "  Domain:      $DOMAIN"
    echo "  SSL Cert:    $SSL_CERT"
    echo "  SSL Key:     $SSL_KEY"
    echo "  Email:       $EMAIL"
    echo ""
    echo -e "${YELLOW}Credentials saved to: $HOME/stackbill-credentials.txt${NC}"
    echo ""
    echo "Useful commands:"
    echo "  kubectl get pods -n $NAMESPACE"
    echo "  kubectl get pods -n sb-apps"
    echo "  kubectl logs -f -l app=sb-deployment-controller -n $NAMESPACE"
    echo ""
}

# ============================================
# MAIN
# ============================================

main() {
    print_banner
    parse_args "$@"
    validate_inputs
    get_server_ip

    # Generate passwords
    MYSQL_PASSWORD=$(generate_password)
    MONGODB_PASSWORD=$(generate_password)
    RABBITMQ_PASSWORD=$(generate_password)
    log_info "Passwords generated"

    # Infrastructure
    if [[ "$SKIP_INFRA" != "true" ]]; then
        install_k3s
        install_helm
        install_istio
    fi

    # Databases
    if [[ "$SKIP_DB" != "true" ]]; then
        install_mysql
        install_mongodb
        install_rabbitmq
        setup_nfs
    fi

    # Deploy controller
    deploy_controller
    setup_ingress

    # Try auto-configure
    try_auto_configure

    # Save and summarize
    save_credentials
    print_summary
}

main "$@"
