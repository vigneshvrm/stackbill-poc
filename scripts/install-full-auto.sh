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

# AWS ECR credentials (read from file)
AWS_ACCESS_KEY_ID=""
AWS_SECRET_ACCESS_KEY=""
AWS_REGION="ap-south-1"
AWS_ACCOUNT_ID="730335576030"
AWS_CREDS_FILE="/etc/stackbill/aws-credentials"
ECR_TOKEN_FILE="/etc/stackbill/ecr-token"
ECR_TOKEN=""

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
    echo "       3. Install MySQL, MongoDB, RabbitMQ on HOST (not in K8s)                "
    echo "       4. Setup NFS storage                                                    "
    echo "       5. Deploy sb-deployment-controller with AUTO_CONFIG                     "
    echo "                                                                               "
    echo "     The controller will be pre-configured with:                               "
    echo "       - Database connections pointing to host IP                              "
    echo "       - AUTO_CONFIG=true and SKIP_WIZARD=true                                 "
    echo "       - All credentials in ConfigMaps and Secrets                             "
    echo "                                                                               "
    echo "     Passwords are auto-generated and saved to credentials file.               "
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

# Load AWS credentials from file
load_aws_credentials() {
    log_step "Loading AWS ECR Credentials"

    # OPTION 1: Check for direct ECR token file first (simpler, no AWS CLI needed)
    local token_locations=(
        "$ECR_TOKEN_FILE"
        "/etc/stackbill/ecr-token"
        "$HOME/.stackbill/ecr-token"
        "./ecr-token"
    )

    for loc in "${token_locations[@]}"; do
        if [[ -f "$loc" ]]; then
            log_info "Found ECR token file: $loc"
            ECR_TOKEN=$(cat "$loc" | tr -d '\n\r ')
            if [[ -n "$ECR_TOKEN" ]]; then
                log_info "ECR token loaded directly (${#ECR_TOKEN} chars)"
                return 0
            fi
        fi
    done

    # OPTION 2: Check for AWS credentials file
    local creds_locations=(
        "$AWS_CREDS_FILE"
        "/etc/stackbill/aws-credentials"
        "$HOME/.stackbill/aws-credentials"
        "./aws-credentials"
    )

    local found_file=""
    for loc in "${creds_locations[@]}"; do
        if [[ -f "$loc" ]]; then
            found_file="$loc"
            break
        fi
    done

    if [[ -z "$found_file" ]]; then
        log_warn "No AWS credentials found"
        log_info "To enable ECR image pulling, create one of:"
        log_info "  /etc/stackbill/ecr-token - with ECR token"
        log_info "  /etc/stackbill/aws-credentials - with AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY"
        return 1
    fi

    log_info "Found credentials file: $found_file"

    # Read credentials from file
    while IFS='=' read -r key value; do
        # Skip empty lines and comments
        [[ -z "$key" || "$key" =~ ^[[:space:]]*# ]] && continue
        # Remove leading/trailing whitespace
        key=$(echo "$key" | xargs)
        value=$(echo "$value" | xargs)

        case "$key" in
            AWS_ACCESS_KEY_ID)
                AWS_ACCESS_KEY_ID="$value"
                ;;
            AWS_SECRET_ACCESS_KEY)
                AWS_SECRET_ACCESS_KEY="$value"
                ;;
            AWS_REGION)
                AWS_REGION="$value"
                ;;
            AWS_ACCOUNT_ID)
                AWS_ACCOUNT_ID="$value"
                ;;
            ECR_TOKEN)
                ECR_TOKEN="$value"
                ;;
        esac
    done < "$found_file"

    # If ECR_TOKEN was in credentials file, use it
    if [[ -n "$ECR_TOKEN" ]]; then
        log_info "ECR token loaded from credentials file"
        return 0
    fi

    # Validate AWS credentials
    if [[ -z "$AWS_ACCESS_KEY_ID" || -z "$AWS_SECRET_ACCESS_KEY" ]]; then
        log_error "AWS credentials incomplete in $found_file"
        log_error "Need either ECR_TOKEN or both AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY"
        exit 1
    fi

    log_info "AWS Access Key ID: ${AWS_ACCESS_KEY_ID:0:8}..."
    log_info "AWS Region: $AWS_REGION"
    log_info "AWS Account ID: $AWS_ACCOUNT_ID"
}

# Create ECR image pull secret
create_ecr_secret() {
    log_step "Creating AWS ECR Image Pull Secret"

    local ECR_REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
    local TOKEN_TO_USE=""

    # If we already have ECR_TOKEN from file, use it directly
    if [[ -n "$ECR_TOKEN" ]]; then
        log_info "Using ECR token from file (no AWS CLI needed)"
        TOKEN_TO_USE="$ECR_TOKEN"
    else
        # Need to get token via AWS CLI
        log_info "Getting ECR token via AWS CLI..."

        # Install AWS CLI if not present
        if ! command -v aws &> /dev/null; then
            log_info "Installing AWS CLI..."
            apt-get update -qq
            apt-get install -y -qq awscli
        fi

        # Configure AWS credentials
        export AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID"
        export AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY"
        export AWS_DEFAULT_REGION="$AWS_REGION"

        # Get ECR login token
        TOKEN_TO_USE=$(aws ecr get-login-password --region "$AWS_REGION" 2>/dev/null)

        if [[ -z "$TOKEN_TO_USE" ]]; then
            log_error "Failed to get ECR login token. Check your AWS credentials."
            exit 1
        fi

        log_info "ECR token obtained via AWS CLI"
    fi

    # Create secret in sb-apps namespace (where images are pulled)
    log_info "Creating imagePullSecret 'awscred' in sb-apps namespace..."

    kubectl create secret docker-registry awscred \
        --docker-server="$ECR_REGISTRY" \
        --docker-username=AWS \
        --docker-password="$TOKEN_TO_USE" \
        --namespace=sb-apps \
        --dry-run=client -o yaml | kubectl apply -f -

    # Also create in sb-system namespace
    kubectl create secret docker-registry awscred \
        --docker-server="$ECR_REGISTRY" \
        --docker-username=AWS \
        --docker-password="$TOKEN_TO_USE" \
        --namespace=sb-system \
        --dry-run=client -o yaml | kubectl apply -f -

    log_info "ECR image pull secret 'awscred' created in sb-apps and sb-system namespaces"
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
            --aws-creds-file)
                AWS_CREDS_FILE="$2"
                shift 2
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
    echo "  --aws-creds-file     Path to AWS credentials file (default: /etc/stackbill/aws-credentials)"
    echo "  --mysql-password     MySQL password (auto-generated if not provided)"
    echo "  --mongodb-password   MongoDB password (auto-generated if not provided)"
    echo "  --rabbitmq-password  RabbitMQ password (auto-generated if not provided)"
    echo "  --skip-db-install    Skip database installation (use existing)"
    echo "  --skip-k8s-install   Skip Kubernetes/Istio installation (use existing)"
    echo "  -h, --help           Show this help message"
    echo ""
    echo "AWS ECR Authentication (choose one method):"
    echo ""
    echo "  METHOD 1 - ECR Token file (simpler, recommended):"
    echo "    sudo mkdir -p /etc/stackbill"
    echo "    echo 'YOUR_ECR_TOKEN' | sudo tee /etc/stackbill/ecr-token"
    echo "    sudo chmod 600 /etc/stackbill/ecr-token"
    echo ""
    echo "  METHOD 2 - AWS Credentials file:"
    echo "    sudo nano /etc/stackbill/aws-credentials"
    echo "    # Add these lines:"
    echo "    AWS_ACCESS_KEY_ID=your_access_key"
    echo "    AWS_SECRET_ACCESS_KEY=your_secret_key"
    echo "    sudo chmod 600 /etc/stackbill/aws-credentials"
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

# Install MySQL - FULLY AUTOMATED (no interactive prompts)
install_mysql() {
    if [[ "$SKIP_DB_INSTALL" == "true" ]]; then
        log_info "Skipping MySQL installation (--skip-db-install)"
        return
    fi

    log_step "Installing MySQL (Fully Automated)"

    # Check if MySQL already running
    if systemctl is-active --quiet mysql 2>/dev/null || systemctl is-active --quiet mysqld 2>/dev/null; then
        log_info "MySQL is already running"
        # Ensure user exists
        mysql -u root -e "CREATE USER IF NOT EXISTS 'stackbill'@'%' IDENTIFIED BY '${MYSQL_PASSWORD}';" 2>/dev/null || true
        mysql -u root -e "GRANT ALL PRIVILEGES ON *.* TO 'stackbill'@'%' WITH GRANT OPTION;" 2>/dev/null || true
        mysql -u root -e "FLUSH PRIVILEGES;" 2>/dev/null || true
        return 0
    fi

    # Wait for any apt locks to be released
    wait_for_apt_lock || return 1

    log_info "Installing MySQL Server via apt (non-interactive)..."

    # Set non-interactive mode
    export DEBIAN_FRONTEND=noninteractive

    # Install MySQL
    apt-get update -qq
    apt-get install -y -qq mysql-server mysql-client

    # Start and enable MySQL
    systemctl start mysql
    systemctl enable mysql

    # Wait for MySQL to be ready
    log_info "Waiting for MySQL to be ready..."
    local retries=30
    while ! mysqladmin ping -h localhost --silent 2>/dev/null; do
        retries=$((retries - 1))
        if [[ $retries -le 0 ]]; then
            log_error "MySQL failed to start"
            return 1
        fi
        sleep 2
    done

    # Configure MySQL user
    log_info "Creating MySQL user: stackbill"
    mysql -u root << MYSQL_EOF
CREATE DATABASE IF NOT EXISTS stackbill;
CREATE USER IF NOT EXISTS 'stackbill'@'%' IDENTIFIED BY '${MYSQL_PASSWORD}';
CREATE USER IF NOT EXISTS 'stackbill'@'localhost' IDENTIFIED BY '${MYSQL_PASSWORD}';
GRANT ALL PRIVILEGES ON *.* TO 'stackbill'@'%' WITH GRANT OPTION;
GRANT ALL PRIVILEGES ON *.* TO 'stackbill'@'localhost' WITH GRANT OPTION;
FLUSH PRIVILEGES;
MYSQL_EOF

    # Configure MySQL to allow remote connections
    log_info "Configuring MySQL for remote access..."
    sed -i 's/bind-address\s*=\s*127.0.0.1/bind-address = 0.0.0.0/' /etc/mysql/mysql.conf.d/mysqld.cnf 2>/dev/null || true
    systemctl restart mysql

    # Verify
    if systemctl is-active --quiet mysql; then
        log_info "MySQL installed and configured successfully"
        log_info "  User: stackbill"
        log_info "  Database: stackbill"
    else
        log_error "MySQL installation failed"
        return 1
    fi
}

# Install MongoDB - FULLY AUTOMATED (no interactive prompts)
install_mongodb() {
    if [[ "$SKIP_DB_INSTALL" == "true" ]]; then
        log_info "Skipping MongoDB installation (--skip-db-install)"
        return
    fi

    log_step "Installing MongoDB (Fully Automated)"

    # Check if MongoDB already running
    if systemctl is-active --quiet mongod 2>/dev/null; then
        log_info "MongoDB is already running"
        return 0
    fi

    # Wait for any apt locks to be released
    wait_for_apt_lock || return 1

    log_info "Installing MongoDB 7.0 via apt (non-interactive)..."

    # Set non-interactive mode
    export DEBIAN_FRONTEND=noninteractive

    # Install prerequisites
    apt-get update -qq
    apt-get install -y -qq gnupg curl

    # Add MongoDB GPG key and repository
    curl -fsSL https://www.mongodb.org/static/pgp/server-7.0.asc | gpg --dearmor -o /usr/share/keyrings/mongodb-server-7.0.gpg 2>/dev/null || true
    echo "deb [ arch=amd64,arm64 signed-by=/usr/share/keyrings/mongodb-server-7.0.gpg ] https://repo.mongodb.org/apt/ubuntu jammy/mongodb-org/7.0 multiverse" | tee /etc/apt/sources.list.d/mongodb-org-7.0.list

    # Install MongoDB
    apt-get update -qq
    apt-get install -y -qq mongodb-org

    # Configure MongoDB for remote access (bind to all interfaces)
    log_info "Configuring MongoDB for remote access..."
    cat > /etc/mongod.conf << 'MONGOD_CONF'
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
security:
  authorization: enabled
MONGOD_CONF

    # Create data directory
    mkdir -p /var/lib/mongodb
    chown -R mongodb:mongodb /var/lib/mongodb

    # Start MongoDB WITHOUT auth first to create user
    log_info "Starting MongoDB to create admin user..."
    sed -i 's/authorization: enabled/authorization: disabled/' /etc/mongod.conf
    systemctl start mongod
    systemctl enable mongod

    # Wait for MongoDB to be ready
    local retries=30
    while ! mongosh --quiet --eval "db.runCommand('ping').ok" 2>/dev/null; do
        retries=$((retries - 1))
        if [[ $retries -le 0 ]]; then
            log_error "MongoDB failed to start"
            return 1
        fi
        sleep 2
    done

    # Create admin user
    log_info "Creating MongoDB user: stackbill"
    mongosh --quiet << MONGO_EOF
use admin
db.createUser({
  user: "stackbill",
  pwd: "${MONGODB_PASSWORD}",
  roles: [
    { role: "root", db: "admin" },
    { role: "readWriteAnyDatabase", db: "admin" }
  ]
})
use stackbill_usage
db.createUser({
  user: "stackbill",
  pwd: "${MONGODB_PASSWORD}",
  roles: [
    { role: "readWrite", db: "stackbill_usage" }
  ]
})
MONGO_EOF

    # Re-enable authentication and restart
    log_info "Enabling MongoDB authentication..."
    sed -i 's/authorization: disabled/authorization: enabled/' /etc/mongod.conf
    systemctl restart mongod

    # Wait for restart
    sleep 5

    # Verify
    if systemctl is-active --quiet mongod; then
        log_info "MongoDB installed and configured successfully"
        log_info "  User: stackbill"
        log_info "  Database: stackbill_usage"
    else
        log_error "MongoDB installation failed"
        return 1
    fi
}

# Install RabbitMQ - FULLY AUTOMATED (no interactive prompts)
install_rabbitmq() {
    if [[ "$SKIP_DB_INSTALL" == "true" ]]; then
        log_info "Skipping RabbitMQ installation (--skip-db-install)"
        return
    fi

    log_step "Installing RabbitMQ (Fully Automated)"

    # Check if RabbitMQ already running
    if systemctl is-active --quiet rabbitmq-server 2>/dev/null; then
        log_info "RabbitMQ is already running"
        # Ensure user exists
        rabbitmqctl add_user stackbill "${RABBITMQ_PASSWORD}" 2>/dev/null || rabbitmqctl change_password stackbill "${RABBITMQ_PASSWORD}" 2>/dev/null || true
        rabbitmqctl set_user_tags stackbill administrator 2>/dev/null || true
        rabbitmqctl set_permissions -p / stackbill ".*" ".*" ".*" 2>/dev/null || true
        return 0
    fi

    # Wait for any apt locks to be released
    wait_for_apt_lock || return 1

    log_info "Installing RabbitMQ via apt (non-interactive)..."

    # Set non-interactive mode
    export DEBIAN_FRONTEND=noninteractive

    # Remove any old repository files that might cause issues
    rm -f /etc/apt/sources.list.d/rabbitmq*.list 2>/dev/null || true

    # Install RabbitMQ from Ubuntu's default repository (simpler, more reliable)
    apt-get update -qq
    apt-get install -y -qq rabbitmq-server

    # Start and enable RabbitMQ
    systemctl start rabbitmq-server
    systemctl enable rabbitmq-server

    # Wait for RabbitMQ to be ready
    log_info "Waiting for RabbitMQ to be ready..."
    local retries=30
    while ! rabbitmqctl status &>/dev/null; do
        retries=$((retries - 1))
        if [[ $retries -le 0 ]]; then
            log_error "RabbitMQ failed to start"
            return 1
        fi
        sleep 2
    done

    # Enable management plugin
    log_info "Enabling RabbitMQ management plugin..."
    rabbitmq-plugins enable rabbitmq_management

    # Create user
    log_info "Creating RabbitMQ user: stackbill"
    rabbitmqctl add_user stackbill "${RABBITMQ_PASSWORD}" 2>/dev/null || rabbitmqctl change_password stackbill "${RABBITMQ_PASSWORD}"
    rabbitmqctl set_user_tags stackbill administrator
    rabbitmqctl set_permissions -p / stackbill ".*" ".*" ".*"

    # Delete default guest user for security
    rabbitmqctl delete_user guest 2>/dev/null || true

    # Verify
    if systemctl is-active --quiet rabbitmq-server; then
        log_info "RabbitMQ installed and configured successfully"
        log_info "  User: stackbill"
        log_info "  Management UI: http://${SERVER_IP}:15672"
    else
        log_error "RabbitMQ installation failed"
        return 1
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

# Create TLS Secret for SSL
create_tls_secret() {
    log_step "Creating TLS Secret for SSL"

    # Create TLS secret from certificate files
    kubectl create secret tls stackbill-tls \
        --cert="$SSL_CERT" \
        --key="$SSL_KEY" \
        --namespace=$NAMESPACE \
        --dry-run=client -o yaml | kubectl apply -f -

    log_info "TLS secret 'stackbill-tls' created"
}

# Create Istio Gateway and VirtualService
create_istio_routing() {
    log_step "Creating Istio Gateway and VirtualService"

    # Create Gateway
    cat <<EOF | kubectl apply -f -
apiVersion: networking.istio.io/v1beta1
kind: Gateway
metadata:
  name: stackbill-gateway
  namespace: $NAMESPACE
spec:
  selector:
    istio: ingressgateway
  servers:
  - port:
      number: 80
      name: http
      protocol: HTTP
    hosts:
    - "$DOMAIN"
    - "*"
  - port:
      number: 443
      name: https
      protocol: HTTPS
    tls:
      mode: SIMPLE
      credentialName: stackbill-tls
    hosts:
    - "$DOMAIN"
    - "*"
EOF

    # Create VirtualService - will be updated after we know service names
    log_info "Istio Gateway created"
}

# Deploy StackBill using LOCAL chart with external database configuration
deploy_stackbill_local() {
    log_step "Deploying StackBill (LOCAL Chart with External Databases)"

    log_info "Using LOCAL chart at: $CHART_DIR"
    log_info "This deploys the sb-deployment-controller with AUTO_CONFIG enabled"
    log_info "Databases will be accessed directly via host IP: $SERVER_IP"

    # Create required namespaces
    log_info "Creating required namespaces..."
    for ns in sb-apps sb-system; do
        if ! kubectl get namespace $ns &> /dev/null; then
            kubectl create namespace $ns
            log_info "Namespace $ns created"
        fi
        kubectl label namespace $ns istio-injection=enabled --overwrite 2>/dev/null || true
    done

    # Add Helm ownership labels to namespace
    kubectl label namespace $NAMESPACE app.kubernetes.io/managed-by=Helm --overwrite
    kubectl annotate namespace $NAMESPACE meta.helm.sh/release-name=stackbill --overwrite
    kubectl annotate namespace $NAMESPACE meta.helm.sh/release-namespace=$NAMESPACE --overwrite

    # Update Helm dependencies
    log_info "Updating Helm chart dependencies..."
    cd "$CHART_DIR"
    helm dependency update . 2>/dev/null || helm dependency build .

    # Deploy using LOCAL chart with EXTERNAL database settings
    # Key settings:
    # - mysql.enabled=false (don't deploy MySQL in K8s)
    # - mongodb.enabled=false (don't deploy MongoDB in K8s)
    # - rabbitmq.enabled=false (don't deploy RabbitMQ in K8s)
    # - external.mysql.host=SERVER_IP (use host-installed MySQL)
    # - external.mongodb.host=SERVER_IP (use host-installed MongoDB)
    # - external.rabbitmq.host=SERVER_IP (use host-installed RabbitMQ)

    log_info "Deploying with external database configuration..."

    helm upgrade --install stackbill . \
        --namespace $NAMESPACE \
        --timeout 600s \
        --set global.mode=poc \
        --set domain.name="$DOMAIN" \
        --set-file ssl.certificate="$SSL_CERT" \
        --set-file ssl.privateKey="$SSL_KEY" \
        --set mysql.enabled=false \
        --set mongodb.enabled=false \
        --set rabbitmq.enabled=false \
        --set external.mysql.host="$SERVER_IP" \
        --set external.mysql.port=3306 \
        --set external.mysql.database=stackbill \
        --set external.mysql.username=stackbill \
        --set external.mysql.password="$MYSQL_PASSWORD" \
        --set external.mongodb.host="$SERVER_IP" \
        --set external.mongodb.port=27017 \
        --set external.mongodb.database=stackbill_usage \
        --set external.mongodb.username=stackbill \
        --set external.mongodb.password="$MONGODB_PASSWORD" \
        --set external.rabbitmq.host="$SERVER_IP" \
        --set external.rabbitmq.port=5672 \
        --set external.rabbitmq.username=stackbill \
        --set external.rabbitmq.password="$RABBITMQ_PASSWORD" \
        --set external.nfs.server="$SERVER_IP" \
        --set external.nfs.path="/data/stackbill" \
        --set nfs.provisioner.enabled=false

    log_info "StackBill deployment initiated with external databases"

    # Show what was created
    log_info "Checking created resources..."
    kubectl get configmap -n $NAMESPACE -l app.kubernetes.io/name=stackbill 2>/dev/null || true
    kubectl get secret -n $NAMESPACE -l app.kubernetes.io/name=stackbill 2>/dev/null || true
}

# Wait for pods
wait_for_pods() {
    log_step "Waiting for sb-deployment-controller to be ready"

    local timeout=180
    local elapsed=0

    # Wait specifically for the deployment controller pod
    log_info "Waiting for sb-deployment-controller pod..."

    while [[ $elapsed -lt $timeout ]]; do
        local status=$(kubectl get pods -n $NAMESPACE -l app=sb-deployment-controller -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "")

        if [[ "$status" == "Running" ]]; then
            # Check if containers are ready
            local ready=$(kubectl get pods -n $NAMESPACE -l app=sb-deployment-controller -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null || echo "false")
            if [[ "$ready" == "true" ]]; then
                echo ""
                log_info "sb-deployment-controller is ready!"
                kubectl get pods -n $NAMESPACE -l app=sb-deployment-controller
                return 0
            fi
        fi

        printf "\r${YELLOW}[WAIT]${NC} Controller status: %s (%ds)" "$status" "$elapsed"
        sleep 5
        elapsed=$((elapsed + 5))
    done

    echo ""
    log_warn "Timeout waiting for controller. Current status:"
    kubectl get pods -n $NAMESPACE -l app=sb-deployment-controller
    kubectl describe pod -n $NAMESPACE -l app=sb-deployment-controller | tail -20
}

# ============================================
# AUTO-CONFIGURE DEPLOYMENT CONTROLLER
# ============================================

# Verify deployment worked correctly
verify_deployment() {
    log_step "Verifying Deployment"

    local all_ok=true

    # Check if configmaps were created
    log_info "Checking ConfigMaps..."
    if kubectl get configmap stackbill-app-config -n $NAMESPACE &>/dev/null; then
        echo -e "  stackbill-app-config:       ${GREEN}OK${NC}"

        # Show config content (first 10 lines)
        log_info "Config content (sample):"
        kubectl get configmap stackbill-app-config -n $NAMESPACE -o jsonpath='{.data.config\.json}' 2>/dev/null | head -c 500
        echo ""
    else
        echo -e "  stackbill-app-config:       ${RED}MISSING${NC}"
        all_ok=false
    fi

    if kubectl get configmap stackbill-poc-config -n $NAMESPACE &>/dev/null; then
        echo -e "  stackbill-poc-config:       ${GREEN}OK${NC}"
    else
        echo -e "  stackbill-poc-config:       ${YELLOW}NOT CREATED (OK if not POC mode)${NC}"
    fi

    # Check if secrets were created
    log_info "Checking Secrets..."
    if kubectl get secret stackbill-auto-credentials -n $NAMESPACE &>/dev/null; then
        echo -e "  stackbill-auto-credentials: ${GREEN}OK${NC}"

        # Verify it contains external IPs, not service names
        local mysql_host=$(kubectl get secret stackbill-auto-credentials -n $NAMESPACE -o jsonpath='{.data.MYSQL_HOST}' | base64 -d 2>/dev/null)
        if [[ "$mysql_host" == "$SERVER_IP" ]]; then
            echo -e "  MySQL Host in secret:       ${GREEN}$mysql_host (correct)${NC}"
        else
            echo -e "  MySQL Host in secret:       ${YELLOW}$mysql_host (expected $SERVER_IP)${NC}"
        fi
    else
        echo -e "  stackbill-auto-credentials: ${RED}MISSING${NC}"
        all_ok=false
    fi

    # Check if controller pod is running
    log_info "Checking Controller Pod..."
    if kubectl get pods -n $NAMESPACE -l app=sb-deployment-controller --no-headers 2>/dev/null | grep -q "Running"; then
        echo -e "  sb-deployment-controller:   ${GREEN}RUNNING${NC}"

        # Check if it has the config mounted
        local pod_name=$(kubectl get pods -n $NAMESPACE -l app=sb-deployment-controller -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
        if [[ -n "$pod_name" ]]; then
            log_info "Checking controller configuration..."

            # Check environment variables
            local auto_config=$(kubectl exec -n $NAMESPACE "$pod_name" -- printenv AUTO_CONFIG 2>/dev/null || echo "")
            local skip_wizard=$(kubectl exec -n $NAMESPACE "$pod_name" -- printenv SKIP_WIZARD 2>/dev/null || echo "")
            local mysql_host=$(kubectl exec -n $NAMESPACE "$pod_name" -- printenv MYSQL_HOST 2>/dev/null || echo "")

            echo "  AUTO_CONFIG=$auto_config"
            echo "  SKIP_WIZARD=$skip_wizard"
            echo "  MYSQL_HOST=$mysql_host"

            # Check if config file exists
            if kubectl exec -n $NAMESPACE "$pod_name" -- test -f /app/config/config.json 2>/dev/null; then
                echo -e "  Config file mounted:        ${GREEN}YES${NC}"
            else
                echo -e "  Config file mounted:        ${YELLOW}NO${NC}"
            fi
        fi
    else
        echo -e "  sb-deployment-controller:   ${RED}NOT RUNNING${NC}"
        all_ok=false
    fi

    # Summary
    echo ""
    if $all_ok; then
        log_info "Deployment verification PASSED"
        log_info "The controller should auto-configure using the mounted credentials"
    else
        log_warn "Deployment verification had issues - check above"
    fi
}

# Auto-configure the deployment controller via API
auto_configure_controller() {
    log_step "Auto-configuring StackBill Deployment Controller via API"

    # Wait for pod to be fully ready
    log_info "Waiting for sb-deployment-controller to be fully ready..."
    kubectl wait --for=condition=ready pod -l app=sb-deployment-controller -n $NAMESPACE --timeout=120s

    # Get pod name
    local POD_NAME=$(kubectl get pods -n $NAMESPACE -l app=sb-deployment-controller -o jsonpath='{.items[0].metadata.name}')
    log_info "Pod: $POD_NAME"

    # Try to discover API routes from container filesystem
    log_info "Discovering API endpoints from container..."

    # Look for route definitions in the Node.js app
    local api_routes=$(kubectl exec -n $NAMESPACE "$POD_NAME" -- sh -c "grep -r 'app\.\(get\|post\|put\)' /app/*.js /app/routes/*.js 2>/dev/null | head -20" 2>/dev/null || echo "")
    if [[ -n "$api_routes" ]]; then
        log_info "Found API routes in container:"
        echo "$api_routes" | head -10
    fi

    # Look for any package.json or server entry point
    local server_files=$(kubectl exec -n $NAMESPACE "$POD_NAME" -- sh -c "ls -la /app/*.js /app/routes/ 2>/dev/null" 2>/dev/null || echo "")
    if [[ -n "$server_files" ]]; then
        log_info "Container app files:"
        echo "$server_files" | head -5
    fi

    # Start port-forward in background
    log_info "Setting up port-forward to controller..."
    kubectl port-forward "pod/$POD_NAME" 8888:3000 -n $NAMESPACE &
    local PF_PID=$!
    sleep 5

    # Check if port-forward is working
    if ! curl -s -o /dev/null -w "" http://localhost:8888/ &>/dev/null; then
        log_warn "Port-forward may not be working. Trying service..."
        kill $PF_PID 2>/dev/null || true

        kubectl port-forward "svc/sb-deployment-controller" 8888:80 -n $NAMESPACE &
        PF_PID=$!
        sleep 5
    fi

    # Prepare configuration payload (matching the expected format from the UI)
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
    "domain": "$DOMAIN",
    "ssl": {
        "certificate": "$(cat $SSL_CERT | base64 -w0)",
        "privateKey": "$(cat $SSL_KEY | base64 -w0)"
    }
}
EOF
)

    # Also prepare a simpler form-like payload
    local FORM_PAYLOAD=$(cat <<EOF
{
    "mysqlHost": "$SERVER_IP",
    "mysqlPort": "3306",
    "mysqlDatabase": "stackbill",
    "mysqlUsername": "stackbill",
    "mysqlPassword": "$MYSQL_PASSWORD",
    "mongodbHost": "$SERVER_IP",
    "mongodbPort": "27017",
    "mongodbDatabase": "stackbill_usage",
    "mongodbUsername": "stackbill",
    "mongodbPassword": "$MONGODB_PASSWORD",
    "rabbitmqHost": "$SERVER_IP",
    "rabbitmqPort": "5672",
    "rabbitmqUsername": "stackbill",
    "rabbitmqPassword": "$RABBITMQ_PASSWORD",
    "nfsServer": "$SERVER_IP",
    "nfsPath": "/data/stackbill",
    "domain": "$DOMAIN"
}
EOF
)

    # Try to configure via API
    log_info "Sending configuration to controller API..."

    # Common API endpoints to try
    local ENDPOINTS=(
        "/api/configuration"
        "/api/setup"
        "/api/config"
        "/api/deploy"
        "/api/install"
        "/api/v1/configuration"
        "/api/v1/setup"
        "/api/v1/config"
        "/api/v1/deploy"
        "/configuration"
        "/setup"
        "/deploy"
        "/config"
    )

    local CONFIG_SUCCESS=false

    # First, probe GET endpoints to understand the API
    log_info "Probing API endpoints..."
    for probe in "/" "/api" "/health" "/status" "/api/status"; do
        local probe_http=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:8888$probe" 2>/dev/null || echo "000")
        local probe_response=$(curl -s "http://localhost:8888$probe" 2>/dev/null | head -c 300 || echo "")

        if [[ "$probe_http" != "000" && "$probe_http" != "404" ]]; then
            log_info "  $probe -> HTTP $probe_http"
            if [[ -n "$probe_response" && ! "$probe_response" =~ "<!DOCTYPE" ]]; then
                echo "    Response: ${probe_response:0:150}..."
            fi
        fi
    done

    # Try POST with JSON payload
    for endpoint in "${ENDPOINTS[@]}"; do
        log_info "Trying POST $endpoint with JSON..."

        local response=$(curl -s -w "\n%{http_code}" \
            -X POST "http://localhost:8888$endpoint" \
            -H "Content-Type: application/json" \
            -d "$CONFIG_PAYLOAD" 2>/dev/null || echo -e "\n000")

        local body=$(echo "$response" | head -n -1)
        local http_code=$(echo "$response" | tail -n 1)

        if [[ "$http_code" == "200" || "$http_code" == "201" || "$http_code" == "202" ]]; then
            log_info "SUCCESS! Configuration sent via $endpoint (HTTP $http_code)"
            log_info "Response: $body"
            CONFIG_SUCCESS=true
            break
        elif [[ "$http_code" != "404" && "$http_code" != "000" && "$http_code" != "405" ]]; then
            log_info "  $endpoint -> HTTP $http_code: ${body:0:100}"
        fi
    done

    # Try with form-style payload if JSON didn't work
    if [[ "$CONFIG_SUCCESS" == "false" ]]; then
        log_info "Trying with alternative payload format..."
        for endpoint in "${ENDPOINTS[@]}"; do
            local response=$(curl -s -w "\n%{http_code}" \
                -X POST "http://localhost:8888$endpoint" \
                -H "Content-Type: application/json" \
                -d "$FORM_PAYLOAD" 2>/dev/null || echo -e "\n000")

            local http_code=$(echo "$response" | tail -n 1)

            if [[ "$http_code" == "200" || "$http_code" == "201" || "$http_code" == "202" ]]; then
                log_info "SUCCESS with form payload! via $endpoint (HTTP $http_code)"
                CONFIG_SUCCESS=true
                break
            fi
        done
    fi

    # Stop port-forward
    kill $PF_PID 2>/dev/null || true
    wait $PF_PID 2>/dev/null || true

    if [[ "$CONFIG_SUCCESS" == "true" ]]; then
        log_info "Auto-configuration completed successfully!"
        log_info "The controller should now deploy StackBill applications."

        # Wait a bit and check for new pods
        log_info "Waiting for StackBill applications to be deployed..."
        sleep 30

        log_info "Checking for deployed applications:"
        kubectl get pods -n sb-apps 2>/dev/null || true
        kubectl get pods -n $NAMESPACE 2>/dev/null || true
    else
        log_warn "Auto-configuration via API was not successful."
        log_warn "This is expected if the controller requires UI interaction."
        log_info ""
        log_info "============================================================"
        log_info "MANUAL CONFIGURATION REQUIRED"
        log_info "============================================================"
        log_info ""
        log_info "Access the controller UI at:"
        log_info "  http://$SERVER_IP:31331"
        log_info ""
        log_info "Or use port-forward:"
        log_info "  kubectl port-forward svc/sb-deployment-controller 8080:80 -n $NAMESPACE"
        log_info "  Then open: http://localhost:8080"
        log_info ""
        log_info "Enter these credentials in the wizard:"
        log_info "  Domain: $DOMAIN"
        log_info "  MySQL: $SERVER_IP:3306 | stackbill | $MYSQL_PASSWORD"
        log_info "  MongoDB: $SERVER_IP:27017 | stackbill | $MONGODB_PASSWORD"
        log_info "  RabbitMQ: $SERVER_IP:5672 | stackbill | $RABBITMQ_PASSWORD"
        log_info "  NFS Server: $SERVER_IP | Path: /data/stackbill"
        log_info ""
        log_info "These credentials are saved in: $HOME/stackbill-credentials.txt"
        log_info "============================================================"
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
    echo -e "${CYAN}WHAT WAS DEPLOYED:${NC}"
    echo "  - K3s Kubernetes cluster"
    echo "  - Istio service mesh"
    echo "  - MySQL on host ($SERVER_IP:3306)"
    echo "  - MongoDB on host ($SERVER_IP:27017)"
    echo "  - RabbitMQ on host ($SERVER_IP:5672)"
    echo "  - NFS storage at /data/stackbill"
    echo "  - sb-deployment-controller (with AUTO_CONFIG enabled)"
    echo ""
    echo -e "${CYAN}CONFIGURATION STATUS:${NC}"
    echo "  The controller has been deployed with:"
    echo "  - AUTO_CONFIG=true"
    echo "  - SKIP_WIZARD=true"
    echo "  - Database credentials pre-configured (using host IPs)"
    echo ""
    echo -e "${CYAN}ACCESS THE CONTROLLER:${NC}"
    echo ""
    echo -e "  1. Via Istio Ingress (NodePort):"
    echo -e "     ${CYAN}http://$SERVER_IP:31331${NC}"
    echo ""
    echo -e "  2. Via Domain (after DNS setup):"
    echo -e "     ${CYAN}https://$DOMAIN${NC}"
    echo ""
    echo -e "  3. Via port-forward (for testing):"
    echo "     kubectl port-forward svc/sb-deployment-controller 8080:80 -n $NAMESPACE"
    echo -e "     Then access: ${CYAN}http://localhost:8080${NC}"
    echo ""
    echo -e "${YELLOW}IMPORTANT: Save these credentials!${NC}"
    echo "Credentials file: $HOME/stackbill-credentials.txt"
    echo ""
    echo "Database connection details (pre-configured in controller):"
    echo "  MySQL:    $SERVER_IP:3306 | stackbill / $MYSQL_PASSWORD"
    echo "  MongoDB:  $SERVER_IP:27017 | stackbill / $MONGODB_PASSWORD"
    echo "  RabbitMQ: $SERVER_IP:5672 | stackbill / $RABBITMQ_PASSWORD"
    echo "            Management: http://$SERVER_IP:15672"
    echo ""
    echo "Useful commands:"
    echo "  kubectl get pods -n $NAMESPACE"
    echo "  kubectl logs -f -l app=sb-deployment-controller -n $NAMESPACE"
    echo "  kubectl get configmap stackbill-app-config -n $NAMESPACE -o yaml"
    echo ""
    echo "Controller Pod Status:"
    kubectl get pods -n $NAMESPACE -l app=sb-deployment-controller 2>/dev/null || true
    echo ""
    echo "All ConfigMaps and Secrets:"
    kubectl get configmap,secret -n $NAMESPACE -l app.kubernetes.io/name=stackbill 2>/dev/null || true
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
    create_tls_secret
    create_istio_routing
    setup_nodeport_access

    # Phase 5: AWS ECR Authentication (for StackBill app images)
    # This creates the image pull secret that the controller will use
    if load_aws_credentials 2>/dev/null; then
        create_ecr_secret
    else
        log_warn "AWS ECR credentials not found - skipping ECR secret creation"
        log_warn "If StackBill apps need ECR images, deployment may fail"
    fi

    # Phase 6: Deploy using LOCAL chart with external databases
    # This deploys sb-deployment-controller with AUTO_CONFIG enabled
    deploy_stackbill_local
    wait_for_pods

    # Phase 7: Verify deployment
    verify_deployment

    # Phase 8: Call controller API to submit credentials and trigger deployment
    # This is the key step - we send the database details via API like the frontend would
    auto_configure_controller

    # Finish
    save_credentials
    print_summary
}

# Run main
main "$@"
