#!/bin/bash
#===============================================================================
# StackBill POC Installer
#
# Simple installation - User provides ONLY:
#   1. Domain name
#   2. SSL certificate + private key
#
# Everything else (MySQL, MongoDB, RabbitMQ, NFS) is auto-provisioned
#===============================================================================

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
RELEASE_NAME="stackbill"
CHART_PATH="."
TIMEOUT="900s"

# User inputs
DOMAIN=""
SSL_CERT_FILE=""
SSL_KEY_FILE=""
SSL_CA_FILE=""

#-------------------------------------------------------------------------------
# Functions
#-------------------------------------------------------------------------------

print_banner() {
    clear
    echo -e "${CYAN}"
    echo "╔═══════════════════════════════════════════════════════════════════════════╗"
    echo "║                                                                           ║"
    echo "║     ███████╗████████╗ █████╗  ██████╗██╗  ██╗██████╗ ██╗██╗     ██╗      ║"
    echo "║     ██╔════╝╚══██╔══╝██╔══██╗██╔════╝██║ ██╔╝██╔══██╗██║██║     ██║      ║"
    echo "║     ███████╗   ██║   ███████║██║     █████╔╝ ██████╔╝██║██║     ██║      ║"
    echo "║     ╚════██║   ██║   ██╔══██║██║     ██╔═██╗ ██╔══██╗██║██║     ██║      ║"
    echo "║     ███████║   ██║   ██║  ██║╚██████╗██║  ██╗██████╔╝██║███████╗███████╗ ║"
    echo "║     ╚══════╝   ╚═╝   ╚═╝  ╚═╝ ╚═════╝╚═╝  ╚═╝╚═════╝ ╚═╝╚══════╝╚══════╝ ║"
    echo "║                                                                           ║"
    echo "║                      POC / Sandbox Installer                              ║"
    echo "║                                                                           ║"
    echo "╚═══════════════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    echo ""
}

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_step() {
    echo -e "\n${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
}

show_help() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "StackBill POC Installer - Simplified deployment for sandbox/demo"
    echo ""
    echo "Required:"
    echo "  --domain DOMAIN          Domain name (e.g., stackbill.example.com)"
    echo "  --ssl-cert FILE          Path to SSL certificate file"
    echo "  --ssl-key FILE           Path to SSL private key file"
    echo ""
    echo "Optional:"
    echo "  --ssl-ca FILE            Path to CA bundle file"
    echo "  -n, --namespace NAME     Kubernetes namespace (default: sb-system)"
    echo "  -h, --help               Show this help"
    echo ""
    echo "Example:"
    echo "  $0 --domain portal.example.com --ssl-cert cert.pem --ssl-key key.pem"
    echo ""
    echo "What gets auto-installed:"
    echo "  - MySQL 8.0 (for application data)"
    echo "  - MongoDB 7.0 (for usage statistics)"
    echo "  - RabbitMQ 3.13 (for messaging)"
    echo "  - NFS storage provisioner"
    echo "  - StackBill Deployment Controller"
}

validate_inputs() {
    local errors=0

    if [ -z "$DOMAIN" ]; then
        log_error "Domain name is required (--domain)"
        errors=$((errors + 1))
    fi

    if [ -z "$SSL_CERT_FILE" ]; then
        log_error "SSL certificate file is required (--ssl-cert)"
        errors=$((errors + 1))
    elif [ ! -f "$SSL_CERT_FILE" ]; then
        log_error "SSL certificate file not found: $SSL_CERT_FILE"
        errors=$((errors + 1))
    fi

    if [ -z "$SSL_KEY_FILE" ]; then
        log_error "SSL private key file is required (--ssl-key)"
        errors=$((errors + 1))
    elif [ ! -f "$SSL_KEY_FILE" ]; then
        log_error "SSL private key file not found: $SSL_KEY_FILE"
        errors=$((errors + 1))
    fi

    if [ -n "$SSL_CA_FILE" ] && [ ! -f "$SSL_CA_FILE" ]; then
        log_error "CA bundle file not found: $SSL_CA_FILE"
        errors=$((errors + 1))
    fi

    if [ $errors -gt 0 ]; then
        echo ""
        log_error "Please fix the errors above and try again."
        echo ""
        show_help
        exit 1
    fi
}

check_prerequisites() {
    log_step "Checking Prerequisites"

    local prereq_ok=true

    # Check kubectl
    if command -v kubectl &> /dev/null; then
        local k8s_version=$(kubectl version --client -o json 2>/dev/null | grep -o '"gitVersion": "[^"]*"' | head -1 | cut -d'"' -f4)
        log_info "✓ kubectl found ($k8s_version)"
    else
        log_error "✗ kubectl not found"
        prereq_ok=false
    fi

    # Check helm
    if command -v helm &> /dev/null; then
        local helm_version=$(helm version --short 2>/dev/null)
        log_info "✓ helm found ($helm_version)"
    else
        log_error "✗ helm not found"
        prereq_ok=false
    fi

    # Check cluster connectivity
    if kubectl cluster-info &> /dev/null; then
        log_info "✓ Kubernetes cluster accessible"
    else
        log_error "✗ Cannot connect to Kubernetes cluster"
        prereq_ok=false
    fi

    # Check Istio
    if kubectl get namespace istio-system &> /dev/null; then
        log_info "✓ Istio namespace found"
    else
        log_warn "⚠ Istio not detected - will need to be installed"
    fi

    # Check storage class
    local default_sc=$(kubectl get storageclass -o jsonpath='{.items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")].metadata.name}' 2>/dev/null)
    if [ -n "$default_sc" ]; then
        log_info "✓ Default storage class: $default_sc"
    else
        log_warn "⚠ No default storage class found"
    fi

    if [ "$prereq_ok" = false ]; then
        log_error "Prerequisites check failed. Please install missing components."
        exit 1
    fi

    echo ""
    log_info "All prerequisites satisfied!"
}

setup_namespace() {
    log_step "Setting Up Namespace"

    if kubectl get namespace "$NAMESPACE" &> /dev/null; then
        log_info "Namespace '$NAMESPACE' already exists"
    else
        log_info "Creating namespace: $NAMESPACE"
        kubectl create namespace "$NAMESPACE"
        log_info "✓ Namespace created"
    fi

    # Add Helm ownership labels/annotations (required for Helm to manage the namespace)
    log_info "Adding Helm ownership labels..."
    kubectl label namespace "$NAMESPACE" app.kubernetes.io/managed-by=Helm --overwrite
    kubectl annotate namespace "$NAMESPACE" meta.helm.sh/release-name="$RELEASE_NAME" --overwrite
    kubectl annotate namespace "$NAMESPACE" meta.helm.sh/release-namespace="$NAMESPACE" --overwrite

    # Label namespace for Istio injection
    kubectl label namespace "$NAMESPACE" istio-injection=enabled --overwrite 2>/dev/null || true

    log_info "✓ Namespace configured for Helm"
}

add_helm_repos() {
    log_step "Adding Helm Repositories"

    helm repo add bitnami https://charts.bitnami.com/bitnami 2>/dev/null || true
    helm repo add nfs-provisioner https://kubernetes-sigs.github.io/nfs-subdir-external-provisioner 2>/dev/null || true
    helm repo update

    log_info "✓ Helm repositories updated"
}

update_dependencies() {
    log_step "Updating Chart Dependencies"

    cd "$CHART_PATH"
    helm dependency update .
    cd - > /dev/null

    log_info "✓ Dependencies updated"
}

read_ssl_files() {
    log_step "Processing SSL Certificates"

    # Read and encode SSL certificate
    SSL_CERT_CONTENT=$(cat "$SSL_CERT_FILE")
    log_info "✓ SSL certificate loaded"

    # Read and encode SSL private key
    SSL_KEY_CONTENT=$(cat "$SSL_KEY_FILE")
    log_info "✓ SSL private key loaded"

    # Read CA bundle if provided
    if [ -n "$SSL_CA_FILE" ]; then
        SSL_CA_CONTENT=$(cat "$SSL_CA_FILE")
        log_info "✓ CA bundle loaded"
    fi
}

install_stackbill() {
    log_step "Installing StackBill POC"

    echo ""
    log_info "Configuration Summary:"
    echo "  ┌─────────────────────────────────────────────────────────────┐"
    echo "  │  Domain:        $DOMAIN"
    echo "  │  Namespace:     $NAMESPACE"
    echo "  │  Release:       $RELEASE_NAME"
    echo "  │  Mode:          POC (Auto-provisioned)"
    echo "  │                                                             │"
    echo "  │  Auto-installing:                                           │"
    echo "  │    • MySQL 8.0                                              │"
    echo "  │    • MongoDB 7.0                                            │"
    echo "  │    • RabbitMQ 3.13                                          │"
    echo "  │    • NFS Storage                                            │"
    echo "  │    • Deployment Controller                                  │"
    echo "  └─────────────────────────────────────────────────────────────┘"
    echo ""

    # Generate random passwords
    MYSQL_PASSWORD=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 16)
    MONGODB_PASSWORD=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 16)
    RABBITMQ_PASSWORD=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 16)

    log_info "Generated secure passwords for all services"

    # Build helm install command
    HELM_CMD="helm upgrade --install $RELEASE_NAME $CHART_PATH"
    HELM_CMD="$HELM_CMD --namespace $NAMESPACE"
    HELM_CMD="$HELM_CMD --timeout $TIMEOUT"
    HELM_CMD="$HELM_CMD --wait"

    # Set domain
    HELM_CMD="$HELM_CMD --set domain.name=$DOMAIN"

    # Set SSL (using file contents)
    HELM_CMD="$HELM_CMD --set-file ssl.certificate=$SSL_CERT_FILE"
    HELM_CMD="$HELM_CMD --set-file ssl.privateKey=$SSL_KEY_FILE"
    if [ -n "$SSL_CA_FILE" ]; then
        HELM_CMD="$HELM_CMD --set-file ssl.caBundle=$SSL_CA_FILE"
    fi

    # Set auto-generated passwords
    HELM_CMD="$HELM_CMD --set mysql.auth.rootPassword=$MYSQL_PASSWORD"
    HELM_CMD="$HELM_CMD --set mysql.auth.password=$MYSQL_PASSWORD"
    HELM_CMD="$HELM_CMD --set mongodb.auth.rootPassword=$MONGODB_PASSWORD"
    HELM_CMD="$HELM_CMD --set mongodb.auth.password=$MONGODB_PASSWORD"
    HELM_CMD="$HELM_CMD --set rabbitmq.auth.password=$RABBITMQ_PASSWORD"

    # Execute
    log_info "Deploying StackBill POC (this may take 5-10 minutes)..."
    echo ""

    eval "$HELM_CMD"

    echo ""
    log_info "✓ StackBill POC deployed successfully!"
}

wait_for_pods() {
    log_step "Waiting for All Services to Start"

    log_info "Waiting for MySQL..."
    kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=mysql -n "$NAMESPACE" --timeout=300s 2>/dev/null || true

    log_info "Waiting for MongoDB..."
    kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=mongodb -n "$NAMESPACE" --timeout=300s 2>/dev/null || true

    log_info "Waiting for RabbitMQ..."
    kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=rabbitmq -n "$NAMESPACE" --timeout=300s 2>/dev/null || true

    log_info "Waiting for Deployment Controller..."
    kubectl wait --for=condition=ready pod -l app=sb-deployment-controller -n "$NAMESPACE" --timeout=300s 2>/dev/null || true

    echo ""
    log_info "✓ All services are running!"
}

save_credentials() {
    log_step "Saving Credentials"

    CREDS_FILE="$HOME/stackbill-poc-credentials.txt"

    cat > "$CREDS_FILE" << EOF
================================================================================
STACKBILL POC - CREDENTIALS
================================================================================
Generated: $(date)
Domain: $DOMAIN

MYSQL
-----
Host: $RELEASE_NAME-mysql.$NAMESPACE.svc.cluster.local
Port: 3306
Database: stackbill
Username: stackbill
Password: $MYSQL_PASSWORD

MONGODB
-------
Host: $RELEASE_NAME-mongodb.$NAMESPACE.svc.cluster.local
Port: 27017
Database: stackbill_usage
Username: stackbill
Password: $MONGODB_PASSWORD

RABBITMQ
--------
Host: $RELEASE_NAME-rabbitmq.$NAMESPACE.svc.cluster.local
Port: 5672
Management Port: 15672
Username: stackbill
Password: $RABBITMQ_PASSWORD

================================================================================
IMPORTANT: Keep this file secure! Delete after noting down credentials.
================================================================================
EOF

    chmod 600 "$CREDS_FILE"
    log_info "✓ Credentials saved to: $CREDS_FILE"
}

show_completion() {
    echo ""
    echo -e "${GREEN}"
    echo "╔═══════════════════════════════════════════════════════════════════════════╗"
    echo "║                                                                           ║"
    echo "║                    INSTALLATION COMPLETE!                                 ║"
    echo "║                                                                           ║"
    echo "╚═══════════════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    echo ""
    echo -e "${CYAN}Access StackBill:${NC}"
    echo "  URL: https://$DOMAIN"
    echo ""
    echo -e "${CYAN}Credentials saved to:${NC}"
    echo "  $HOME/stackbill-poc-credentials.txt"
    echo ""
    echo -e "${CYAN}Useful Commands:${NC}"
    echo "  # Check pod status"
    echo "  kubectl get pods -n $NAMESPACE"
    echo ""
    echo "  # View deployment controller logs"
    echo "  kubectl logs -f -l app=sb-deployment-controller -n $NAMESPACE"
    echo ""
    echo "  # Port forward for local access"
    echo "  kubectl port-forward svc/sb-deployment-controller 8080:80 -n $NAMESPACE"
    echo ""
    echo -e "${CYAN}Uninstall:${NC}"
    echo "  ./scripts/uninstall.sh -n $NAMESPACE -r $RELEASE_NAME --delete-pvc"
    echo ""
    echo -e "${YELLOW}NOTE: DNS must be configured to point $DOMAIN to your cluster.${NC}"
    echo ""
}

#-------------------------------------------------------------------------------
# Parse Arguments
#-------------------------------------------------------------------------------

while [[ $# -gt 0 ]]; do
    case $1 in
        --domain)
            DOMAIN="$2"
            shift 2
            ;;
        --ssl-cert)
            SSL_CERT_FILE="$2"
            shift 2
            ;;
        --ssl-key)
            SSL_KEY_FILE="$2"
            shift 2
            ;;
        --ssl-ca)
            SSL_CA_FILE="$2"
            shift 2
            ;;
        -n|--namespace)
            NAMESPACE="$2"
            shift 2
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
done

#-------------------------------------------------------------------------------
# Main Execution
#-------------------------------------------------------------------------------

print_banner
validate_inputs
check_prerequisites
setup_namespace
add_helm_repos
update_dependencies
read_ssl_files
install_stackbill
wait_for_pods
save_credentials
show_completion
