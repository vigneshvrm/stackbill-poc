#!/bin/bash
# ============================================
# STACKBILL POC - FULL AUTOMATION INSTALLER
# ============================================
# This script performs a complete automated deployment:
# 1. Installs MySQL, MongoDB, RabbitMQ on the host
# 2. Sets up NFS storage
# 3. Deploys sb-deployment-controller to Kubernetes
# 4. Auto-configures with all credentials
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
NC='\033[0m' # No Color

# Default passwords
MYSQL_PASSWORD="StackB1ll2024Mysql"
MONGODB_PASSWORD="StackB1ll2024Mongo"
RABBITMQ_PASSWORD="StackB1ll2024Rmq"

# Namespace
NAMESPACE="sb-system"

# Banner
print_banner() {
    echo -e "${BLUE}"
    echo "============================================"
    echo "  StackBill POC - Full Automation Installer"
    echo "============================================"
    echo -e "${NC}"
}

# Logging functions
log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "${BLUE}[STEP]${NC} $1"; }

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

# Check prerequisites
check_prerequisites() {
    log_step "Checking prerequisites..."

    # Check if running as root
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root (sudo)"
        exit 1
    fi

    # Check kubectl
    if ! command -v kubectl &> /dev/null; then
        log_error "kubectl is not installed"
        exit 1
    fi
    log_info "kubectl: OK"

    # Check helm
    if ! command -v helm &> /dev/null; then
        log_error "helm is not installed"
        exit 1
    fi
    log_info "helm: OK"

    # Check Kubernetes connectivity
    if ! kubectl cluster-info &> /dev/null; then
        log_error "Cannot connect to Kubernetes cluster"
        exit 1
    fi
    log_info "Kubernetes: OK"

    # Check Istio
    if ! kubectl get namespace istio-system &> /dev/null; then
        log_warn "Istio namespace not found. Make sure Istio is installed."
    else
        log_info "Istio: OK"
    fi
}

# Get server IP
get_server_ip() {
    SERVER_IP=$(hostname -I | awk '{print $1}')
    log_info "Server IP detected: $SERVER_IP"
}

# Install MySQL
install_mysql() {
    if [[ "$SKIP_DB_INSTALL" == "true" ]]; then
        log_info "Skipping MySQL installation (--skip-db-install)"
        return
    fi

    log_step "Installing MySQL..."

    cd /usr/local/src

    # Download StackBill MySQL script
    if [[ ! -f "Mysql.sh" ]]; then
        wget -q https://stacbilldeploy.s3.us-east-1.amazonaws.com/Mysql/Mysql.sh
        chmod +x Mysql.sh
    fi

    # Run MySQL installation (non-interactive)
    # Note: You may need to modify this for non-interactive installation
    log_warn "MySQL installation may require interactive input..."
    log_warn "When prompted, use username: stackbill, password: $MYSQL_PASSWORD"

    ./Mysql.sh || true

    # Verify MySQL is running
    if systemctl is-active --quiet mysql; then
        log_info "MySQL installed successfully"
    else
        log_error "MySQL installation failed"
        exit 1
    fi
}

# Install MongoDB
install_mongodb() {
    if [[ "$SKIP_DB_INSTALL" == "true" ]]; then
        log_info "Skipping MongoDB installation (--skip-db-install)"
        return
    fi

    log_step "Installing MongoDB..."

    cd /usr/local/src

    # Download StackBill MongoDB script
    if [[ ! -f "Mongodb.sh" ]]; then
        wget -q https://stacbilldeploy.s3.us-east-1.amazonaws.com/MongoDB/Mongodb.sh
        chmod +x Mongodb.sh
    fi

    # Run MongoDB installation
    log_warn "MongoDB installation may require interactive input..."
    log_warn "When prompted, use username: stackbill, password: $MONGODB_PASSWORD"

    ./Mongodb.sh || true

    # Verify MongoDB is running
    if systemctl is-active --quiet mongod; then
        log_info "MongoDB installed successfully"
    else
        log_error "MongoDB installation failed"
        exit 1
    fi
}

# Install RabbitMQ
install_rabbitmq() {
    if [[ "$SKIP_DB_INSTALL" == "true" ]]; then
        log_info "Skipping RabbitMQ installation (--skip-db-install)"
        return
    fi

    log_step "Installing RabbitMQ..."

    cd /usr/local/src

    # Download StackBill RabbitMQ script
    if [[ ! -f "rabbitmq.sh" ]]; then
        wget -q https://stacbilldeploy.s3.us-east-1.amazonaws.com/RabbitMQ/rabbitmq.sh
        chmod +x rabbitmq.sh
    fi

    # Run RabbitMQ installation
    log_warn "RabbitMQ installation may require interactive input..."
    log_warn "When prompted, use username: stackbill, password: $RABBITMQ_PASSWORD"

    ./rabbitmq.sh || true

    # Verify RabbitMQ is running
    if systemctl is-active --quiet rabbitmq-server; then
        log_info "RabbitMQ installed successfully"
    else
        log_error "RabbitMQ installation failed"
        exit 1
    fi
}

# Setup NFS
setup_nfs() {
    log_step "Setting up NFS storage..."

    # Install NFS server
    apt-get update -qq
    apt-get install -y -qq nfs-kernel-server

    # Create storage directory
    mkdir -p /data/stackbill
    chmod 777 /data/stackbill

    # Add export if not exists
    if ! grep -q "/data/stackbill" /etc/exports; then
        echo "/data/stackbill *(rw,sync,no_subtree_check,no_root_squash)" >> /etc/exports
    fi

    # Apply exports
    exportfs -a
    systemctl restart nfs-kernel-server

    log_info "NFS storage configured at /data/stackbill"
}

# Setup Kubernetes namespace
setup_namespace() {
    log_step "Setting up Kubernetes namespace..."

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
    log_step "Deploying StackBill Helm chart..."

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
    log_step "Waiting for pods to be ready..."

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
    log_step "Saving credentials..."

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
    echo -e "${GREEN}============================================${NC}"
    echo -e "${GREEN}  DEPLOYMENT COMPLETE!${NC}"
    echo -e "${GREEN}============================================${NC}"
    echo ""
    echo -e "Access StackBill at: ${BLUE}https://$DOMAIN${NC}"
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
}

# Main function
main() {
    print_banner
    parse_args "$@"
    validate_inputs
    check_prerequisites
    get_server_ip

    # Install databases
    install_mysql
    install_mongodb
    install_rabbitmq

    # Setup storage
    setup_nfs

    # Deploy to Kubernetes
    setup_namespace
    deploy_helm
    wait_for_pods

    # Finish
    save_credentials
    print_summary
}

# Run main
main "$@"
