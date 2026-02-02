#!/bin/bash
# ============================================
# STACKBILL POC - FULL AUTOMATION INSTALLER
# ============================================
# This script performs a COMPLETE automated deployment on a fresh server:
# 1. Installs K3s Kubernetes (if not present)
# 2. Installs Helm and kubectl
# 3. Installs Istio service mesh
# 4. Installs MySQL, MongoDB, RabbitMQ on the host (with auto-generated passwords)
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

# Passwords will be auto-generated if not provided
MYSQL_PASSWORD=""
MONGODB_PASSWORD=""
RABBITMQ_PASSWORD=""

# Versions
K3S_VERSION="v1.29.0+k3s1"
ISTIO_VERSION="1.20.3"

# Namespace
NAMESPACE="sb-system"

# Save original directory (before any cd commands)
ORIGINAL_DIR="$(pwd)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART_DIR="$(dirname "$SCRIPT_DIR")"

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
    echo "     Passwords will be auto-generated and saved to credentials file.          "
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

# Generate secure random password
generate_password() {
    # Generate 16 character alphanumeric password
    if command -v openssl &> /dev/null; then
        openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 16
    else
        cat /dev/urandom | tr -dc 'a-zA-Z0-9' | head -c 16
    fi
}

# Generate all passwords
generate_passwords() {
    log_step "Generating secure passwords"

    if [[ -z "$MYSQL_PASSWORD" ]]; then
        MYSQL_PASSWORD=$(generate_password)
        log_info "MySQL password: [auto-generated]"
    else
        log_info "MySQL password: [user-provided]"
    fi

    if [[ -z "$MONGODB_PASSWORD" ]]; then
        MONGODB_PASSWORD=$(generate_password)
        log_info "MongoDB password: [auto-generated]"
    else
        log_info "MongoDB password: [user-provided]"
    fi

    if [[ -z "$RABBITMQ_PASSWORD" ]]; then
        RABBITMQ_PASSWORD=$(generate_password)
        log_info "RabbitMQ password: [auto-generated]"
    else
        log_info "RabbitMQ password: [user-provided]"
    fi
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
    echo "  --mysql-password     MySQL password (auto-generated if not provided)"
    echo "  --mongodb-password   MongoDB password (auto-generated if not provided)"
    echo "  --rabbitmq-password  RabbitMQ password (auto-generated if not provided)"
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

# Install expect for automation
install_expect() {
    if ! command -v expect &> /dev/null; then
        log_info "Installing expect for automation..."
        apt-get update -qq
        apt-get install -y -qq expect
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

    # Install expect for database automation
    install_expect
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
        pushd /tmp > /dev/null
        curl -L https://istio.io/downloadIstio | ISTIO_VERSION=$ISTIO_VERSION sh -
        mv istio-$ISTIO_VERSION/bin/istioctl /usr/local/bin/
        rm -rf istio-$ISTIO_VERSION
        popd > /dev/null
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
# DATABASE INSTALLATION (with auto-input)
# ============================================

# Wait for apt locks to be released
wait_for_apt_lock() {
    local max_wait=300  # 5 minutes max
    local waited=0

    log_info "Checking for apt locks..."

    while [[ $waited -lt $max_wait ]]; do
        # Check if any apt/dpkg processes are running
        if ! fuser /var/lib/dpkg/lock-frontend &>/dev/null && \
           ! fuser /var/lib/apt/lists/lock &>/dev/null && \
           ! fuser /var/cache/apt/archives/lock &>/dev/null; then
            log_info "No apt locks detected, proceeding..."
            return 0
        fi

        if [[ $waited -eq 0 ]]; then
            log_warn "Waiting for apt locks to be released (another package manager is running)..."
        fi

        sleep 5
        waited=$((waited + 5))
        printf "\r${YELLOW}[WAIT]${NC} Waiting for apt lock... (%ds)" "$waited"
    done

    echo ""
    log_error "Timeout waiting for apt locks. Try: sudo killall apt apt-get dpkg"
    return 1
}

# Install MySQL with expect automation
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

    # Wait for any apt locks to be released
    wait_for_apt_lock || return 1

    pushd /usr/local/src > /dev/null

    # Download StackBill MySQL script
    if [[ ! -f "Mysql.sh" ]]; then
        log_info "Downloading MySQL installation script..."
        wget -q https://stacbilldeploy.s3.us-east-1.amazonaws.com/Mysql/Mysql.sh
        chmod +x Mysql.sh
    fi

    # Run MySQL installation with expect for automation
    log_info "Running MySQL installation with auto-configuration..."
    log_info "Username: stackbill, Password: [auto-generated]"

    expect << EXPECT_EOF
set timeout 600
spawn ./Mysql.sh
expect {
    "Do you want to proceed*" { send "Y\r"; exp_continue }
    "Enter username*" { send "stackbill\r"; exp_continue }
    "Enter password*" { send "${MYSQL_PASSWORD}\r"; exp_continue }
    "press any key*" { send "\r"; exp_continue }
    "Press any key*" { send "\r"; exp_continue }
    eof
}
EXPECT_EOF

    popd > /dev/null

    # Wait for installation to complete and apt to be released
    log_info "Waiting for MySQL installation to complete..."
    sleep 10

    # Verify MySQL is running
    if systemctl is-active --quiet mysql 2>/dev/null || systemctl is-active --quiet mysqld 2>/dev/null; then
        log_info "MySQL installed successfully"
    else
        log_warn "MySQL may need manual verification. Check: systemctl status mysql"
    fi
}

# Install MongoDB with expect automation
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

    # Wait for any apt locks to be released
    wait_for_apt_lock || return 1

    pushd /usr/local/src > /dev/null

    # Download StackBill MongoDB script
    if [[ ! -f "Mongodb.sh" ]]; then
        log_info "Downloading MongoDB installation script..."
        wget -q https://stacbilldeploy.s3.us-east-1.amazonaws.com/MongoDB/Mongodb.sh
        chmod +x Mongodb.sh
    fi

    # Run MongoDB installation with expect for automation
    log_info "Running MongoDB installation with auto-configuration..."
    log_info "Username: stackbill, Password: [auto-generated]"

    expect << EXPECT_EOF
set timeout 600
spawn ./Mongodb.sh
expect {
    "Enter username*" { send "stackbill\r"; exp_continue }
    "Enter password*" { send "${MONGODB_PASSWORD}\r"; exp_continue }
    "press any key*" { send "\r"; exp_continue }
    "Press any key*" { send "\r"; exp_continue }
    eof
}
EXPECT_EOF

    popd > /dev/null

    # Wait for installation to complete and apt to be released
    log_info "Waiting for MongoDB installation to complete..."
    sleep 10

    # Verify MongoDB is running
    if systemctl is-active --quiet mongod 2>/dev/null; then
        log_info "MongoDB installed successfully"
    else
        log_warn "MongoDB may need manual verification. Check: systemctl status mongod"
    fi
}

# Install RabbitMQ with expect automation
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

    # Wait for any apt locks to be released
    wait_for_apt_lock || return 1

    pushd /usr/local/src > /dev/null

    # Download StackBill RabbitMQ script
    if [[ ! -f "rabbitmq.sh" ]]; then
        log_info "Downloading RabbitMQ installation script..."
        wget -q https://stacbilldeploy.s3.us-east-1.amazonaws.com/RabbitMQ/rabbitmq.sh
        chmod +x rabbitmq.sh
    fi

    # Run RabbitMQ installation with expect for automation
    log_info "Running RabbitMQ installation with auto-configuration..."
    log_info "Username: stackbill, Password: [auto-generated]"

    expect << EXPECT_EOF
set timeout 600
spawn ./rabbitmq.sh
expect {
    "Daemons using outdated*" { send "\r"; exp_continue }
    "Which services should*" { send "\r"; exp_continue }
    "Enter username*" { send "stackbill\r"; exp_continue }
    "Enter password*" { send "${RABBITMQ_PASSWORD}\r"; exp_continue }
    "press any key*" { send "\r"; exp_continue }
    "Press any key*" { send "\r"; exp_continue }
    "q" { send "q"; exp_continue }
    eof
}
EXPECT_EOF

    popd > /dev/null

    # Wait for installation to complete
    log_info "Waiting for RabbitMQ installation to complete..."
    sleep 10

    # Verify RabbitMQ is running
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

    # Change to chart directory (CHART_DIR computed at script start)
    cd "$CHART_DIR"
    log_info "Working from chart directory: $CHART_DIR"

    # Build dependencies first
    log_info "Building Helm dependencies..."
    helm dependency build . 2>/dev/null || helm dependency update . 2>/dev/null || true

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
        # Get ready count - handle multiple values by taking first number
        local ready_output=$(kubectl get pods -n $NAMESPACE -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
        local ready=$(echo "$ready_output" | tr ' ' '\n' | grep -c "True" 2>/dev/null || echo "0")

        # Get total count - trim whitespace
        local total=$(kubectl get pods -n $NAMESPACE --no-headers 2>/dev/null | wc -l | tr -d ' ' || echo "0")

        # Ensure we have numeric values
        ready=${ready:-0}
        total=${total:-0}

        if [[ "$total" =~ ^[0-9]+$ ]] && [[ "$ready" =~ ^[0-9]+$ ]] && [[ $total -gt 0 ]] && [[ $ready -eq $total ]]; then
            echo ""
            log_info "All pods are ready ($ready/$total)"
            return 0
        fi

        printf "\r${YELLOW}[WAIT]${NC} Pods ready: %s/%s (%ds)" "$ready" "$total" "$elapsed"
        sleep 5
        elapsed=$((elapsed + 5))
    done

    echo ""
    log_warn "Timeout waiting for pods. Check: kubectl get pods -n $NAMESPACE"
}

# ============================================
# AUTO-CONFIGURE DEPLOYMENT CONTROLLER
# ============================================

# Auto-configure the deployment controller via API
auto_configure_controller() {
    log_step "Auto-configuring StackBill Deployment Controller"

    # Wait for pod to be fully ready
    log_info "Waiting for sb-deployment-controller to be fully ready..."
    kubectl wait --for=condition=ready pod -l app=sb-deployment-controller -n $NAMESPACE --timeout=120s

    # Get pod name
    local POD_NAME=$(kubectl get pods -n $NAMESPACE -l app=sb-deployment-controller -o jsonpath='{.items[0].metadata.name}')
    log_info "Pod: $POD_NAME"

    # Start port-forward in background
    log_info "Setting up port-forward..."
    kubectl port-forward "pod/$POD_NAME" 8888:3000 -n $NAMESPACE &
    local PF_PID=$!
    sleep 5

    # Try to configure via API
    log_info "Attempting auto-configuration via API..."

    # Prepare configuration payload
    local CONFIG_PAYLOAD=$(cat <<EOF
{
    "mysql": {
        "host": "$SERVER_IP",
        "port": 3306,
        "database": "stackbill",
        "username": "stackbill",
        "password": "$MYSQL_PASSWORD"
    },
    "mongodb": {
        "host": "$SERVER_IP",
        "port": 27017,
        "database": "stackbill_usage",
        "username": "stackbill",
        "password": "$MONGODB_PASSWORD"
    },
    "rabbitmq": {
        "host": "$SERVER_IP",
        "port": 5672,
        "username": "stackbill",
        "password": "$RABBITMQ_PASSWORD"
    },
    "nfs": {
        "server": "$SERVER_IP",
        "path": "/data/stackbill"
    },
    "domain": "$DOMAIN"
}
EOF
)

    # Try common API endpoints
    local ENDPOINTS=(
        "/api/setup"
        "/api/config"
        "/api/v1/setup"
        "/api/v1/config"
        "/api/configuration"
        "/api/init"
        "/setup"
        "/config"
    )

    local CONFIG_SUCCESS=false

    for endpoint in "${ENDPOINTS[@]}"; do
        log_info "Trying endpoint: $endpoint"

        local response=$(curl -s -o /dev/null -w "%{http_code}" \
            -X POST "http://localhost:8888$endpoint" \
            -H "Content-Type: application/json" \
            -d "$CONFIG_PAYLOAD" 2>/dev/null || echo "000")

        if [[ "$response" == "200" || "$response" == "201" ]]; then
            log_info "Configuration successful via $endpoint (HTTP $response)"
            CONFIG_SUCCESS=true
            break
        elif [[ "$response" != "404" && "$response" != "000" ]]; then
            log_info "Endpoint $endpoint returned HTTP $response"
        fi
    done

    # Try GET to discover API routes
    if [[ "$CONFIG_SUCCESS" == "false" ]]; then
        log_info "Probing API discovery endpoints..."
        for probe in "/api" "/api/v1" "/swagger" "/openapi" "/health" "/"; do
            local probe_response=$(curl -s "http://localhost:8888$probe" 2>/dev/null | head -c 500)
            if [[ -n "$probe_response" && "$probe_response" != *"<!DOCTYPE"* ]]; then
                log_info "API response from $probe: ${probe_response:0:200}..."
            fi
        done
    fi

    # Stop port-forward
    kill $PF_PID 2>/dev/null || true

    if [[ "$CONFIG_SUCCESS" == "true" ]]; then
        log_info "Auto-configuration completed successfully!"
    else
        log_warn "Auto-configuration via API was not successful."
        log_warn "The application may require manual configuration through the UI."
        log_info ""
        log_info "Access the UI to configure manually:"
        log_info "  NodePort: http://$SERVER_IP:31331"
        log_info "  Or use: kubectl port-forward svc/sb-deployment-controller 8080:80 -n $NAMESPACE"
        log_info ""
        log_info "Enter these credentials in the configuration wizard:"
        log_info "  MySQL: $SERVER_IP:3306 | stackbill | $MYSQL_PASSWORD"
        log_info "  MongoDB: $SERVER_IP:27017 | stackbill | $MONGODB_PASSWORD"
        log_info "  RabbitMQ: $SERVER_IP:5672 | stackbill | $RABBITMQ_PASSWORD"
        log_info "  NFS: $SERVER_IP | /data/stackbill"
    fi
}

# Expose via NodePort for access without LoadBalancer
setup_nodeport_access() {
    log_step "Setting up NodePort access"

    # Patch istio-ingressgateway to use NodePort with fixed ports
    kubectl patch svc istio-ingressgateway -n istio-system --type='json' -p='[
        {"op": "replace", "path": "/spec/type", "value": "NodePort"},
        {"op": "add", "path": "/spec/ports/0/nodePort", "value": 31331},
        {"op": "add", "path": "/spec/ports/1/nodePort", "value": 31332}
    ]' 2>/dev/null || log_warn "Could not patch ingress gateway NodePorts"

    log_info "Istio Ingress Gateway exposed on NodePorts:"
    log_info "  HTTP:  $SERVER_IP:31331"
    log_info "  HTTPS: $SERVER_IP:31332"
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
    echo -e "${CYAN}ACCESS OPTIONS:${NC}"
    echo ""
    echo -e "  1. Via NodePort (works immediately):"
    echo -e "     ${CYAN}http://$SERVER_IP:31331${NC}"
    echo ""
    echo -e "  2. Via Domain (requires DNS pointing to this server):"
    echo -e "     ${CYAN}https://$DOMAIN${NC}"
    echo ""
    echo -e "${YELLOW}IMPORTANT: Save these auto-generated credentials!${NC}"
    echo "Credentials file: $HOME/stackbill-credentials.txt"
    echo ""
    echo "Database connection details:"
    echo "  MySQL:    $SERVER_IP:3306"
    echo "    Username: stackbill"
    echo "    Password: $MYSQL_PASSWORD"
    echo ""
    echo "  MongoDB:  $SERVER_IP:27017"
    echo "    Username: stackbill"
    echo "    Password: $MONGODB_PASSWORD"
    echo ""
    echo "  RabbitMQ: $SERVER_IP:5672"
    echo "    Username: stackbill"
    echo "    Password: $RABBITMQ_PASSWORD"
    echo "    Management UI: http://$SERVER_IP:15672"
    echo ""
    echo "Useful commands:"
    echo "  kubectl get pods -n $NAMESPACE"
    echo "  kubectl logs -f deployment/sb-deployment-controller -n $NAMESPACE"
    echo ""
    echo "Istio Ingress Gateway:"
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

    # Generate passwords if not provided
    generate_passwords

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

    # Phase 5: Auto-configure the application
    setup_nodeport_access
    auto_configure_controller

    # Finish
    save_credentials
    print_summary
}

# Run main
main "$@"
