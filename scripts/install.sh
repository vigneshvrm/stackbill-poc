#!/bin/bash
#===============================================================================
# StackBill Helm Chart - Installation Script
#
# This script automates the deployment of StackBill on Kubernetes
# Supports: Sandbox, Staging, and Production environments
#===============================================================================

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default values
NAMESPACE="sb-apps"
RELEASE_NAME="stackbill"
ENVIRONMENT="sandbox"
CHART_PATH="."
TIMEOUT="600s"
WAIT=true

# Generated passwords (if not provided)
MYSQL_PASSWORD=""
MONGODB_PASSWORD=""
RABBITMQ_PASSWORD=""

#-------------------------------------------------------------------------------
# Functions
#-------------------------------------------------------------------------------

print_banner() {
    echo -e "${BLUE}"
    echo "==============================================================================="
    echo "     _____ _             _    ____  _ _ _"
    echo "    / ____| |           | |  |  _ \(_) | |"
    echo "   | (___ | |_ __ _  ___| | _| |_) |_| | |"
    echo "    \___ \| __/ _\` |/ __| |/ /  _ <| | | |"
    echo "    ____) | || (_| | (__|   <| |_) | | | |"
    echo "   |_____/ \__\__,_|\___|_|\_\____/|_|_|_|"
    echo ""
    echo "   Kubernetes Deployment Script"
    echo "==============================================================================="
    echo -e "${NC}"
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

show_help() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  -n, --namespace NAME     Kubernetes namespace (default: sb-apps)"
    echo "  -r, --release NAME       Helm release name (default: stackbill)"
    echo "  -e, --environment ENV    Environment: sandbox|staging|production (default: sandbox)"
    echo "  -f, --values FILE        Additional values file"
    echo "  --mysql-password PASS    MySQL root password"
    echo "  --mongodb-password PASS  MongoDB root password"
    echo "  --rabbitmq-password PASS RabbitMQ password"
    echo "  --domain DOMAIN          Domain name for ingress"
    echo "  --no-wait                Don't wait for deployment to complete"
    echo "  --dry-run                Show what would be installed without installing"
    echo "  -h, --help               Show this help message"
    echo ""
    echo "Examples:"
    echo "  # Install sandbox environment"
    echo "  $0 -e sandbox"
    echo ""
    echo "  # Install production with custom domain"
    echo "  $0 -e production --domain portal.example.com"
    echo ""
    echo "  # Install with custom passwords"
    echo "  $0 --mysql-password 'SecurePass123' --mongodb-password 'SecurePass456'"
}

generate_password() {
    openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 16
}

check_prerequisites() {
    log_info "Checking prerequisites..."

    # Check kubectl
    if ! command -v kubectl &> /dev/null; then
        log_error "kubectl is not installed. Please install kubectl first."
        exit 1
    fi
    log_info "  ✓ kubectl found"

    # Check helm
    if ! command -v helm &> /dev/null; then
        log_error "helm is not installed. Please install helm first."
        exit 1
    fi
    log_info "  ✓ helm found"

    # Check cluster connectivity
    if ! kubectl cluster-info &> /dev/null; then
        log_error "Cannot connect to Kubernetes cluster. Please check your kubeconfig."
        exit 1
    fi
    log_info "  ✓ Kubernetes cluster accessible"

    # Check if namespace exists
    if ! kubectl get namespace "$NAMESPACE" &> /dev/null; then
        log_info "  Creating namespace: $NAMESPACE"
        kubectl create namespace "$NAMESPACE"
    fi
    log_info "  ✓ Namespace $NAMESPACE ready"
}

add_helm_repos() {
    log_info "Adding Helm repositories..."

    helm repo add bitnami https://charts.bitnami.com/bitnami 2>/dev/null || true
    helm repo update

    log_info "  ✓ Helm repositories updated"
}

update_dependencies() {
    log_info "Updating Helm chart dependencies..."

    helm dependency update "$CHART_PATH"

    log_info "  ✓ Dependencies updated"
}

create_registry_secret() {
    log_info "Checking image pull secrets..."

    if ! kubectl get secret stackbill-regcred -n "$NAMESPACE" &> /dev/null; then
        log_warn "Image pull secret 'stackbill-regcred' not found."
        log_info "If using a private registry, create it with:"
        echo ""
        echo "  kubectl create secret docker-registry stackbill-regcred \\"
        echo "    --namespace $NAMESPACE \\"
        echo "    --docker-server=<your-registry> \\"
        echo "    --docker-username=<username> \\"
        echo "    --docker-password=<password>"
        echo ""
    else
        log_info "  ✓ Image pull secret exists"
    fi
}

install_stackbill() {
    log_info "Installing StackBill..."
    log_info "  Release:     $RELEASE_NAME"
    log_info "  Namespace:   $NAMESPACE"
    log_info "  Environment: $ENVIRONMENT"

    # Generate passwords if not provided
    if [ -z "$MYSQL_PASSWORD" ]; then
        MYSQL_PASSWORD=$(generate_password)
        log_info "  Generated MySQL password"
    fi
    if [ -z "$MONGODB_PASSWORD" ]; then
        MONGODB_PASSWORD=$(generate_password)
        log_info "  Generated MongoDB password"
    fi
    if [ -z "$RABBITMQ_PASSWORD" ]; then
        RABBITMQ_PASSWORD=$(generate_password)
        log_info "  Generated RabbitMQ password"
    fi

    # Build helm install command
    HELM_CMD="helm upgrade --install $RELEASE_NAME $CHART_PATH"
    HELM_CMD="$HELM_CMD --namespace $NAMESPACE"
    HELM_CMD="$HELM_CMD --timeout $TIMEOUT"

    # Add environment-specific values file
    if [ "$ENVIRONMENT" = "sandbox" ]; then
        HELM_CMD="$HELM_CMD -f values-sandbox.yaml"
    elif [ "$ENVIRONMENT" = "production" ]; then
        HELM_CMD="$HELM_CMD -f values-production.yaml"
    fi

    # Add custom values file if provided
    if [ -n "$CUSTOM_VALUES_FILE" ]; then
        HELM_CMD="$HELM_CMD -f $CUSTOM_VALUES_FILE"
    fi

    # Add password overrides
    HELM_CMD="$HELM_CMD --set mysql.auth.rootPassword=$MYSQL_PASSWORD"
    HELM_CMD="$HELM_CMD --set mysql.auth.password=$MYSQL_PASSWORD"
    HELM_CMD="$HELM_CMD --set mongodb.auth.rootPassword=$MONGODB_PASSWORD"
    HELM_CMD="$HELM_CMD --set mongodb.auth.password=$MONGODB_PASSWORD"
    HELM_CMD="$HELM_CMD --set rabbitmq.auth.password=$RABBITMQ_PASSWORD"

    # Add domain if provided
    if [ -n "$DOMAIN" ]; then
        HELM_CMD="$HELM_CMD --set ingress.hosts[0].host=$DOMAIN"
        HELM_CMD="$HELM_CMD --set ingress.hosts[0].paths[0].path=/"
        HELM_CMD="$HELM_CMD --set ingress.hosts[0].paths[0].pathType=Prefix"
    fi

    # Add wait flag
    if [ "$WAIT" = true ]; then
        HELM_CMD="$HELM_CMD --wait"
    fi

    # Add dry-run flag
    if [ "$DRY_RUN" = true ]; then
        HELM_CMD="$HELM_CMD --dry-run"
        log_info "Running in dry-run mode..."
    fi

    # Execute
    echo ""
    log_info "Executing: helm upgrade --install $RELEASE_NAME ..."
    eval "$HELM_CMD"

    if [ "$DRY_RUN" != true ]; then
        log_info "  ✓ StackBill installed successfully"
    fi
}

show_credentials() {
    if [ "$DRY_RUN" = true ]; then
        return
    fi

    echo ""
    echo -e "${BLUE}===============================================================================${NC}"
    echo -e "${BLUE}                          INSTALLATION COMPLETE${NC}"
    echo -e "${BLUE}===============================================================================${NC}"
    echo ""
    echo -e "${YELLOW}IMPORTANT: Save these credentials securely!${NC}"
    echo ""
    echo "MySQL:"
    echo "  Root Password: $MYSQL_PASSWORD"
    echo ""
    echo "MongoDB:"
    echo "  Root Password: $MONGODB_PASSWORD"
    echo ""
    echo "RabbitMQ:"
    echo "  Password: $RABBITMQ_PASSWORD"
    echo ""
    echo -e "${BLUE}===============================================================================${NC}"
}

show_next_steps() {
    if [ "$DRY_RUN" = true ]; then
        return
    fi

    echo ""
    log_info "Next Steps:"
    echo ""
    echo "1. Check pod status:"
    echo "   kubectl get pods -n $NAMESPACE"
    echo ""
    echo "2. Access the application:"
    if [ -n "$DOMAIN" ]; then
        echo "   https://$DOMAIN"
    else
        echo "   kubectl port-forward svc/$RELEASE_NAME 8080:80 -n $NAMESPACE"
        echo "   Then open: http://localhost:8080"
    fi
    echo ""
    echo "3. View logs:"
    echo "   kubectl logs -f -l app.kubernetes.io/name=stackbill -n $NAMESPACE"
    echo ""
    echo "4. Uninstall (if needed):"
    echo "   ./scripts/uninstall.sh -n $NAMESPACE -r $RELEASE_NAME"
    echo ""
}

#-------------------------------------------------------------------------------
# Parse Arguments
#-------------------------------------------------------------------------------

while [[ $# -gt 0 ]]; do
    case $1 in
        -n|--namespace)
            NAMESPACE="$2"
            shift 2
            ;;
        -r|--release)
            RELEASE_NAME="$2"
            shift 2
            ;;
        -e|--environment)
            ENVIRONMENT="$2"
            shift 2
            ;;
        -f|--values)
            CUSTOM_VALUES_FILE="$2"
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
        --domain)
            DOMAIN="$2"
            shift 2
            ;;
        --no-wait)
            WAIT=false
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
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

# Validate environment
if [[ ! "$ENVIRONMENT" =~ ^(sandbox|staging|production)$ ]]; then
    log_error "Invalid environment: $ENVIRONMENT"
    log_error "Valid options: sandbox, staging, production"
    exit 1
fi

#-------------------------------------------------------------------------------
# Main Execution
#-------------------------------------------------------------------------------

print_banner
check_prerequisites
add_helm_repos
update_dependencies
create_registry_secret
install_stackbill
show_credentials
show_next_steps

echo ""
log_info "Installation completed successfully!"
