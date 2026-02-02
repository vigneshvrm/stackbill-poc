#!/bin/bash
# ============================================
# STACKBILL POC - FULL AUTOMATION INSTALLER
# ============================================
# This script performs a COMPLETE automated deployment on a fresh server:
# 1. Installs K3s Kubernetes (if not present)
# 2. Installs Helm and kubectl
# 3. Installs Istio service mesh
# 4. Installs MySQL, MongoDB, RabbitMQ on the host
# 5. Sets up NFS storage
# 6. Deploys sb-deployment-controller to Kubernetes
# 7. Auto-configures with all credentials
#
# Usage:
#   ./install-full-auto.sh --domain DOMAIN --ssl-cert CERT_FILE --ssl-key KEY_FILE
#
# Example:
#   ./install-full-auto.sh --domain stackbill.example.com \
#     --ssl-cert /path/to/fullchain.pem \
#     --ssl-key /path/to/privatekey.pem
# ============================================

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Default passwords
MYSQL_PASSWORD="StackB1ll2024Mysql"
MONGODB_PASSWORD="StackB1ll2024Mongo"
RABBITMQ_PASSWORD="StackB1ll2024Rmq"

# Versions
K3S_VERSION="v1.29.0+k3s1"
ISTIO_VERSION="1.20.3"

# Namespace
NAMESPACE="sb-system"

# Banner
print_banner() {
    echo -e "${CYAN}"
    echo "==============================================================================="
    echo "                                                                               "
    echo "     StackBill POC - Full Automation Installer                                 "
    echo "                                                                               "
    echo "     This script will:                                                         "
    echo "       1. Install K3s Kubernetes (if needed)                                   "
    echo "       2. Install kubectl, Helm, Istio                                         "
    echo "       3. Install MySQL, MongoDB, RabbitMQ on host                             "
    echo "       4. Setup NFS storage                                                    "
    echo "       5. Deploy StackBill deployment controller                               "
    echo "                                                                               "
    echo "==============================================================================="
    echo -e "${NC}"
}

# Logging functions
log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() {
    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}  STEP: $1${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

# Parse arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --domain)
                DOMAIN="$2"
                shift 2
                ;;
            --ssl-cert)
                SSL_CERT="$2"
                shift 2
                ;;
            --ssl-key)
                SSL_KEY="$2"
                shift 2
                ;;
            --mysql-password)
                MYSQL_PASSWORD="$2"
                shift 2
                ;;
            --mongodb-password)
                MONGODB_PASSWORD="$2"
                shift 2
                ;;
            --rabbitmq-password)
                RABBITMQ_PASSWORD="$2"
                shift 2
                ;;
            --skip-db-install)
                SKIP_DB_INSTALL=true
                shift
                ;;
            --skip-k8s-install)
                SKIP_K8S_INSTALL=true
                shift
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                log_error "Unknown argument: $1"
                show_help
                exit 1
                ;;
        esac
    done
}

show_help() {
    echo "Usage: $0 --domain DOMAIN --ssl-cert CERT_FILE --ssl-key KEY_FILE [OPTIONS]"
    echo ""
    echo "Required:"
    echo "  --domain        Domain name for StackBill portal"
    echo "  --ssl-cert      Path to SSL certificate file (fullchain.pem)"
    echo "  --ssl-key       Path to SSL private key file"
    echo ""
    echo "Optional:"
    echo "  --mysql-password     MySQL password (default: StackB1ll2024Mysql)"
    echo "  --mongodb-password   MongoDB password (default: StackB1ll2024Mongo)"
    echo "  --rabbitmq-password  RabbitMQ password (default: StackB1ll2024Rmq)"
    echo "  --skip-db-install    Skip database installation (use existing)"
    echo "  --skip-k8s-install   Skip Kubernetes/Istio installation (use existing)"
    echo "  -h, --help           Show this help message"
}

# Validate inputs
validate_inputs() {
    log_step "Validating inputs..."

    if [[ -z "$DOMAIN" ]]; then
        log_error "Domain name is required. Use --domain"
        exit 1
    fi

    if [[ -z "$SSL_CERT" || ! -f "$SSL_CERT" ]]; then
        log_error "SSL certificate file not found: $SSL_CERT"
        exit 1
    fi

    if [[ -z "$SSL_KEY" || ! -f "$SSL_KEY" ]]; then
        log_error "SSL private key file not found: $SSL_KEY"
        exit 1
    fi

    log_info "Domain: $DOMAIN"
    log_info "SSL Certificate: $SSL_CERT"
    log_info "SSL Key: $SSL_KEY"
}

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root (sudo)"
        exit 1
    fi
}

# Check system requirements
check_system_requirements() {
    log_step "Checking System Requirements"

    # Check OS
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        log_info "OS: $NAME $VERSION"
        if [[ "$ID" != "ubuntu" ]]; then
            log_warn "Recommended OS is Ubuntu 22.04. Current: $ID"
        fi
    fi

    # Check CPU
    CPU_CORES=$(nproc)
    log_info "CPU Cores: $CPU_CORES"
    if [ "$CPU_CORES" -lt 4 ]; then
        log_warn "Minimum 4 CPU cores recommended. Current: $CPU_CORES"
    else
        log_info "CPU cores OK"
    fi

    # Check RAM
    TOTAL_RAM=$(free -g | awk '/^Mem:/{print $2}')
    log_info "Total RAM: ${TOTAL_RAM}GB"
    if [ "$TOTAL_RAM" -lt 8 ]; then
        log_warn "Minimum 8GB RAM recommended. Current: ${TOTAL_RAM}GB"
    else
        log_info "RAM OK"
    fi

    # Check Disk
    DISK_FREE=$(df -BG / | awk 'NR==2 {print $4}' | tr -d 'G')
    log_info "Free Disk: ${DISK_FREE}GB"
    if [ "$DISK_FREE" -lt 50 ]; then
        log_warn "Minimum 50GB free disk recommended. Current: ${DISK_FREE}GB"
    else
        log_info "Disk space OK"
    fi
}

# Get server IP
get_server_ip() {
    SERVER_IP=$(hostname -I | awk '{print $1}')
    log_info "Server IP detected: $SERVER_IP"
}

# ============================================
# KUBERNETES INFRASTRUCTURE
# ============================================

# Install kubectl
install_kubectl() {
    log_step "Installing kubectl"

    if command -v kubectl &> /dev/null; then
        KUBECTL_VER=$(kubectl version --client --short 2>/dev/null || kubectl version --client 2>/dev/null | head -1)
        log_info "kubectl already installed: $KUBECTL_VER"
        return 0
    fi

    log_info "Downloading kubectl..."
    curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
    chmod +x kubectl
    mv kubectl /usr/local/bin/

    log_info "kubectl installed successfully"
}

# Install K3s
install_k3s() {
    log_step "Installing K3s Kubernetes"

    if [[ "$SKIP_K8S_INSTALL" == "true" ]]; then
        log_info "Skipping K3s installation (--skip-k8s-install)"
        return
    fi

    # Check if K3s already installed
    if command -v k3s &> /dev/null; then
        K3S_VER=$(k3s --version | head -1)
        log_info "K3s already installed: $K3S_VER"

        # Make sure kubeconfig is set up
        if [[ -f /etc/rancher/k3s/k3s.yaml ]]; then
            mkdir -p ~/.kube
            cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
            chmod 600 ~/.kube/config
            export KUBECONFIG=~/.kube/config
        fi
        return 0
    fi

    # Check if kubectl can connect to existing cluster
    if kubectl cluster-info &> /dev/null 2>&1; then
        log_info "Existing Kubernetes cluster found, skipping K3s installation"
        return 0
    fi

    log_info "Installing K3s version: $K3S_VERSION"
    log_info "This may take a few minutes..."

    # Install K3s with required features
    curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="$K3S_VERSION" sh -s - \
        --write-kubeconfig-mode 644 \
        --disable traefik \
        --disable servicelb

    # Wait for K3s to start
    log_info "Waiting for K3s to start..."
    sleep 15

    # Setup kubeconfig
    mkdir -p ~/.kube
    cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
    chmod 600 ~/.kube/config
    export KUBECONFIG=~/.kube/config

    # Wait for node to be ready
    log_info "Waiting for node to be ready..."
    kubectl wait --for=condition=ready node --all --timeout=120s

    kubectl get nodes
    log_info "K3s installed successfully"
}

# Install Helm
install_helm() {
    log_step "Installing Helm"

    if command -v helm &> /dev/null; then
        HELM_VER=$(helm version --short 2>/dev/null)
        log_info "Helm already installed: $HELM_VER"
        return 0
    fi

    log_info "Downloading and installing Helm..."
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

    log_info "Helm installed successfully"
    helm version --short
}

# Install Istio
install_istio() {
    log_step "Installing Istio Service Mesh"

    if [[ "$SKIP_K8S_INSTALL" == "true" ]]; then
        log_info "Skipping Istio installation (--skip-k8s-install)"
        return
    fi

    # Check if Istio already installed
    if kubectl get namespace istio-system &> /dev/null 2>&1; then
        if kubectl get pods -n istio-system -l app=istiod --no-headers 2>/dev/null | grep -q "Running"; then
            log_info "Istio is already installed and running"
            kubectl get pods -n istio-system
            return 0
        fi
    fi

    log_info "Installing Istio version: $ISTIO_VERSION"

    # Download istioctl if not present
    if ! command -v istioctl &> /dev/null; then
        log_info "Downloading istioctl..."
        cd /tmp
        curl -L https://istio.io/downloadIstio | ISTIO_VERSION=$ISTIO_VERSION sh -
        mv istio-$ISTIO_VERSION/bin/istioctl /usr/local/bin/
        rm -rf istio-$ISTIO_VERSION
        cd -
    fi

    # Install Istio with demo profile
    log_info "Installing Istio with demo profile..."
    istioctl install --set profile=demo -y

    # Wait for Istio to be ready
    log_info "Waiting for Istio pods to be ready..."
    kubectl wait --for=condition=ready pod -l app=istiod -n istio-system --timeout=300s
    kubectl wait --for=condition=ready pod -l app=istio-ingressgateway -n istio-system --timeout=300s

    log_info "Istio Ingress Gateway:"
    kubectl get svc istio-ingressgateway -n istio-system

    log_info "Istio installed successfully"
}

# Setup storage class
setup_storage_class() {
    log_step "Setting Up Storage Class"

    # Check existing storage classes
    log_info "Existing storage classes:"
    kubectl get storageclass || true

    # Check for default storage class
    DEFAULT_SC=$(kubectl get storageclass -o jsonpath='{.items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")].metadata.name}' 2>/dev/null || echo "")

    if [ -n "$DEFAULT_SC" ]; then
        log_info "Default storage class found: $DEFAULT_SC"
    else
        log_warn "No default storage class found"

        # For K3s, local-path is usually available
        if kubectl get storageclass local-path &> /dev/null 2>&1; then
            log_info "Setting local-path as default storage class..."
            kubectl patch storageclass local-path -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
            log_info "local-path set as default"
        else
            log_warn "Please configure a default storage class manually"
        fi
    fi
}

# Verify Kubernetes is ready
verify_kubernetes() {
    log_step "Verifying Kubernetes Setup"

    local all_ok=true

    # Check kubectl
    if command -v kubectl &> /dev/null && kubectl cluster-info &> /dev/null 2>&1; then
        echo -e "  Kubernetes Cluster:  ${GREEN}OK${NC}"
    else
        echo -e "  Kubernetes Cluster:  ${RED}FAILED${NC}"
        all_ok=false
    fi

    # Check Helm
    if command -v helm &> /dev/null; then
        echo -e "  Helm:                ${GREEN}OK${NC}"
    else
        echo -e "  Helm:                ${RED}FAILED${NC}"
        all_ok=false
    fi

    # Check Istio
    if kubectl get namespace istio-system &> /dev/null 2>&1; then
        if kubectl get pods -n istio-system -l app=istiod --no-headers 2>/dev/null | grep -q "Running"; then
            echo -e "  Istio:               ${GREEN}OK${NC}"
        else
            echo -e "  Istio:               ${YELLOW}Pods not ready${NC}"
            all_ok=false
        fi
    else
        echo -e "  Istio:               ${RED}NOT INSTALLED${NC}"
        all_ok=false
    fi

    if ! $all_ok; then
        log_error "Kubernetes infrastructure setup failed"
        exit 1
    fi

    log_info "Kubernetes infrastructure is ready"
}

# ============================================
# DATABASE INSTALLATION
# ============================================

# Install MySQL
install_mysql() {
    if [[ "$SKIP_DB_INSTALL" == "true" ]]; then
        log_info "Skipping MySQL installation (--skip-db-install)"
        return
    fi

    log_step "Installing MySQL"

    # Check if MySQL already running
    if systemctl is-active --quiet mysql 2>/dev/null || systemctl is-active --quiet mysqld 2>/dev/null; then
        log_info "MySQL is already running"
        return 0
    fi

    cd /usr/local/src

    # Download StackBill MySQL script
    if [[ ! -f "Mysql.sh" ]]; then
        log_info "Downloading MySQL installation script..."
        wget -q https://stacbilldeploy.s3.us-east-1.amazonaws.com/Mysql/Mysql.sh
        chmod +x Mysql.sh
    fi

    # Run MySQL installation
    log_warn "Running MySQL installation..."
    log_warn "When prompted, use username: stackbill, password: $MYSQL_PASSWORD"

    # Try to run with expect if available, otherwise interactive
    if command -v expect &> /dev/null; then
        log_info "Using automated installation..."
        expect << EOF
spawn ./Mysql.sh
expect "Do you want to proceed*" { send "Y\r" }
expect "Enter username*" { send "stackbill\r" }
expect "Enter password*" { send "$MYSQL_PASSWORD\r" }
expect eof
EOF
    else
        ./Mysql.sh || true
    fi

    # Verify MySQL is running
    sleep 5
    if systemctl is-active --quiet mysql 2>/dev/null || systemctl is-active --quiet mysqld 2>/dev/null; then
        log_info "MySQL installed successfully"
    else
        log_warn "MySQL may need manual verification. Check: systemctl status mysql"
    fi
}

# Install MongoDB
install_mongodb() {
    if [[ "$SKIP_DB_INSTALL" == "true" ]]; then
        log_info "Skipping MongoDB installation (--skip-db-install)"
        return
    fi

    log_step "Installing MongoDB"

    # Check if MongoDB already running
    if systemctl is-active --quiet mongod 2>/dev/null; then
        log_info "MongoDB is already running"
        return 0
    fi

    cd /usr/local/src

    # Download StackBill MongoDB script
    if [[ ! -f "Mongodb.sh" ]]; then
        log_info "Downloading MongoDB installation script..."
        wget -q https://stacbilldeploy.s3.us-east-1.amazonaws.com/MongoDB/Mongodb.sh
        chmod +x Mongodb.sh
    fi

    # Run MongoDB installation
    log_warn "Running MongoDB installation..."
    log_warn "When prompted, use username: stackbill, password: $MONGODB_PASSWORD"

    ./Mongodb.sh || true

    # Verify MongoDB is running
    sleep 5
    if systemctl is-active --quiet mongod 2>/dev/null; then
        log_info "MongoDB installed successfully"
    else
        log_warn "MongoDB may need manual verification. Check: systemctl status mongod"
    fi
}

# Install RabbitMQ
install_rabbitmq() {
    if [[ "$SKIP_DB_INSTALL" == "true" ]]; then
        log_info "Skipping RabbitMQ installation (--skip-db-install)"
        return
    fi

    log_step "Installing RabbitMQ"

    # Check if RabbitMQ already running
    if systemctl is-active --quiet rabbitmq-server 2>/dev/null; then
        log_info "RabbitMQ is already running"
        return 0
    fi

    cd /usr/local/src

    # Download StackBill RabbitMQ script
    if [[ ! -f "rabbitmq.sh" ]]; then
        log_info "Downloading RabbitMQ installation script..."
        wget -q https://stacbilldeploy.s3.us-east-1.amazonaws.com/RabbitMQ/rabbitmq.sh
        chmod +x rabbitmq.sh
    fi

    # Run RabbitMQ installation
    log_warn "Running RabbitMQ installation..."
    log_warn "When prompted, use username: stackbill, password: $RABBITMQ_PASSWORD"

    ./rabbitmq.sh || true

    # Verify RabbitMQ is running
    sleep 5
    if systemctl is-active --quiet rabbitmq-server 2>/dev/null; then
        log_info "RabbitMQ installed successfully"
    else
        log_warn "RabbitMQ may need manual verification. Check: systemctl status rabbitmq-server"
    fi
}

# Setup NFS
setup_nfs() {
    log_step "Setting up NFS storage"

    # Install NFS server
    apt-get update -qq
    apt-get install -y -qq nfs-kernel-server

    # Create storage directory
    mkdir -p /data/stackbill
    chmod 777 /data/stackbill

    # Add export if not exists
    if ! grep -q "/data/stackbill" /etc/exports 2>/dev/null; then
        echo "/data/stackbill *(rw,sync,no_subtree_check,no_root_squash)" >> /etc/exports
    fi

    # Apply exports
    exportfs -a
    systemctl restart nfs-kernel-server

    log_info "NFS storage configured at /data/stackbill"
}

# ============================================
# KUBERNETES DEPLOYMENT
# ============================================

# Setup Kubernetes namespace
setup_namespace() {
    log_step "Setting up Kubernetes namespace"

    # Create namespace if not exists
    if ! kubectl get namespace $NAMESPACE &> /dev/null; then
        kubectl create namespace $NAMESPACE
        log_info "Namespace $NAMESPACE created"
    else
        log_info "Namespace $NAMESPACE already exists"
    fi

    # Add Istio injection label
    kubectl label namespace $NAMESPACE istio-injection=enabled --overwrite

    # Add Helm ownership labels
    kubectl label namespace $NAMESPACE app.kubernetes.io/managed-by=Helm --overwrite
    kubectl annotate namespace $NAMESPACE meta.helm.sh/release-name=stackbill --overwrite
    kubectl annotate namespace $NAMESPACE meta.helm.sh/release-namespace=$NAMESPACE --overwrite

    log_info "Namespace configured with Istio and Helm labels"
}

# Deploy Helm chart
deploy_helm() {
    log_step "Deploying StackBill Helm chart"

    # Get script directory
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    CHART_DIR="$(dirname "$SCRIPT_DIR")"

    cd "$CHART_DIR"

    # Update dependencies
    log_info "Updating Helm dependencies..."
    helm dependency update . 2>/dev/null || true

    # Deploy with external services configuration
    log_info "Deploying sb-deployment-controller..."

    helm upgrade --install stackbill . \
        --namespace $NAMESPACE \
        --timeout 600s \
        --set domain.name="$DOMAIN" \
        --set-file ssl.certificate="$SSL_CERT" \
        --set-file ssl.privateKey="$SSL_KEY" \
        --set mysql.enabled=false \
        --set mongodb.enabled=false \
        --set rabbitmq.enabled=false \
        --set external.mysql.host="$SERVER_IP" \
        --set external.mysql.password="$MYSQL_PASSWORD" \
        --set external.mongodb.host="$SERVER_IP" \
        --set external.mongodb.password="$MONGODB_PASSWORD" \
        --set external.rabbitmq.host="$SERVER_IP" \
        --set external.rabbitmq.password="$RABBITMQ_PASSWORD" \
        --set external.nfs.server="$SERVER_IP" \
        --set external.nfs.path="/data/stackbill"

    log_info "Helm deployment complete"
}

# Wait for pods
wait_for_pods() {
    log_step "Waiting for pods to be ready"

    local timeout=300
    local elapsed=0

    while [[ $elapsed -lt $timeout ]]; do
        local ready=$(kubectl get pods -n $NAMESPACE -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | tr ' ' '\n' | grep -c "True" || echo "0")
        local total=$(kubectl get pods -n $NAMESPACE --no-headers 2>/dev/null | wc -l || echo "0")

        if [[ $total -gt 0 && $ready -eq $total ]]; then
            log_info "All pods are ready ($ready/$total)"
            return 0
        fi

        echo -ne "\r${YELLOW}[WAIT]${NC} Pods ready: $ready/$total (${elapsed}s)"
        sleep 5
        elapsed=$((elapsed + 5))
    done

    echo ""
    log_warn "Timeout waiting for pods. Check: kubectl get pods -n $NAMESPACE"
}

# Save credentials
save_credentials() {
    log_step "Saving credentials"

    CREDS_FILE="$HOME/stackbill-credentials.txt"

    cat > "$CREDS_FILE" << EOF
================================================================================
STACKBILL POC CREDENTIALS
Generated: $(date)
================================================================================

DOMAIN: https://$DOMAIN

MySQL:
  Host: $SERVER_IP
  Port: 3306
  Database: stackbill
  Username: stackbill
  Password: $MYSQL_PASSWORD

MongoDB:
  Host: $SERVER_IP
  Port: 27017
  Database: stackbill_usage
  Username: stackbill
  Password: $MONGODB_PASSWORD

RabbitMQ:
  Host: $SERVER_IP
  Port: 5672
  Username: stackbill
  Password: $RABBITMQ_PASSWORD
  Management UI: http://$SERVER_IP:15672

NFS:
  Server: $SERVER_IP
  Path: /data/stackbill

Kubernetes:
  Namespace: $NAMESPACE
  Check pods: kubectl get pods -n $NAMESPACE
  Check services: kubectl get svc -n $NAMESPACE

================================================================================
EOF

    chmod 600 "$CREDS_FILE"
    log_info "Credentials saved to: $CREDS_FILE"
}

# Print summary
print_summary() {
    echo ""
    echo -e "${GREEN}===============================================================================${NC}"
    echo -e "${GREEN}                      DEPLOYMENT COMPLETE!                                    ${NC}"
    echo -e "${GREEN}===============================================================================${NC}"
    echo ""
    echo -e "Access StackBill at: ${CYAN}https://$DOMAIN${NC}"
    echo ""
    echo "Credentials saved to: $HOME/stackbill-credentials.txt"
    echo ""
    echo "Useful commands:"
    echo "  kubectl get pods -n $NAMESPACE"
    echo "  kubectl logs -f deployment/sb-deployment-controller -n $NAMESPACE"
    echo ""
    echo "Database connection details:"
    echo "  MySQL:    $SERVER_IP:3306 (stackbill / $MYSQL_PASSWORD)"
    echo "  MongoDB:  $SERVER_IP:27017 (stackbill / $MONGODB_PASSWORD)"
    echo "  RabbitMQ: $SERVER_IP:5672 (stackbill / $RABBITMQ_PASSWORD)"
    echo ""
    echo "Istio Ingress Gateway (point your DNS here):"
    kubectl get svc istio-ingressgateway -n istio-system -o wide 2>/dev/null || true
    echo ""
}

# Main function
main() {
    print_banner
    parse_args "$@"
    check_root
    validate_inputs
    check_system_requirements
    get_server_ip

    # Phase 1: Kubernetes Infrastructure
    install_kubectl
    install_k3s
    install_helm
    install_istio
    setup_storage_class
    verify_kubernetes

    # Phase 2: Install databases on host
    install_mysql
    install_mongodb
    install_rabbitmq

    # Phase 3: Setup storage
    setup_nfs

    # Phase 4: Deploy to Kubernetes
    setup_namespace
    deploy_helm
    wait_for_pods

    # Finish
    save_credentials
    print_summary
}

# Run main
main "$@"
