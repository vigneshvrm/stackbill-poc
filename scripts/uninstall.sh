#!/bin/bash
# ============================================
# STACKBILL POC UNINSTALLER
# ============================================
# Removes StackBill deployment and optionally databases
# ============================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

NAMESPACE="sb-apps"
RELEASE_NAME="stackbill"
DELETE_NAMESPACE=false
DELETE_PVC=false
DELETE_DB=false
FORCE=false

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

show_help() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  -n, --namespace NAME     Kubernetes namespace (default: sb-apps)"
    echo "  -r, --release NAME       Helm release name (default: stackbill)"
    echo "  --delete-pvc             Delete PersistentVolumeClaims"
    echo "  --delete-namespace       Delete the namespace after uninstall"
    echo "  --delete-db              Stop and remove host databases (MySQL, MongoDB, RabbitMQ)"
    echo "  --force                  Skip confirmation prompts"
    echo "  -h, --help               Show this help message"
    echo ""
    echo "Examples:"
    echo "  # Basic uninstall (keeps databases)"
    echo "  $0"
    echo ""
    echo "  # Complete Kubernetes cleanup"
    echo "  $0 --delete-pvc --delete-namespace"
    echo ""
    echo "  # Full cleanup including databases"
    echo "  $0 --delete-pvc --delete-namespace --delete-db --force"
}

confirm_action() {
    if [[ "$FORCE" == "true" ]]; then
        return 0
    fi

    echo ""
    echo -e "${YELLOW}WARNING: This will uninstall StackBill from namespace '$NAMESPACE'${NC}"
    if [[ "$DELETE_PVC" == "true" ]]; then
        echo -e "${RED}WARNING: --delete-pvc flag is set. PVC DATA WILL BE DELETED!${NC}"
    fi
    if [[ "$DELETE_NAMESPACE" == "true" ]]; then
        echo -e "${YELLOW}WARNING: The namespace '$NAMESPACE' will be deleted${NC}"
    fi
    if [[ "$DELETE_DB" == "true" ]]; then
        echo -e "${RED}WARNING: --delete-db flag is set. HOST DATABASES WILL BE REMOVED!${NC}"
    fi
    echo ""
    read -p "Are you sure you want to continue? [y/N] " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Uninstall cancelled."
        exit 0
    fi
}

uninstall_helm_release() {
    log_info "Uninstalling Helm release: $RELEASE_NAME"

    if helm status "$RELEASE_NAME" -n "$NAMESPACE" &>/dev/null; then
        helm uninstall "$RELEASE_NAME" -n "$NAMESPACE"
        log_info "Helm release uninstalled"
    else
        log_warn "Release '$RELEASE_NAME' not found in namespace '$NAMESPACE'"
    fi
}

delete_istio_resources() {
    log_info "Deleting Istio resources..."

    kubectl delete gateway -n "$NAMESPACE" --all 2>/dev/null || true
    kubectl delete virtualservice -n "$NAMESPACE" --all 2>/dev/null || true
    kubectl delete destinationrule -n "$NAMESPACE" --all 2>/dev/null || true

    # Delete TLS secret from istio-system
    kubectl delete secret istio-ingressgateway-certs -n istio-system 2>/dev/null || true

    log_info "Istio resources deleted"
}

delete_pvcs() {
    if [[ "$DELETE_PVC" != "true" ]]; then
        return
    fi

    log_info "Deleting PersistentVolumeClaims..."

    kubectl delete pvc -n "$NAMESPACE" --all 2>/dev/null || true

    log_info "PVCs deleted"
}

delete_namespace_func() {
    if [[ "$DELETE_NAMESPACE" != "true" ]]; then
        return
    fi

    log_info "Deleting namespace: $NAMESPACE"

    kubectl delete namespace "$NAMESPACE" --wait=false 2>/dev/null || true

    log_info "Namespace deletion initiated"
}

delete_host_databases() {
    if [[ "$DELETE_DB" != "true" ]]; then
        return
    fi

    log_info "Stopping and removing host databases..."

    # MySQL
    if systemctl is-active --quiet mysql 2>/dev/null; then
        log_info "Stopping MySQL..."
        systemctl stop mysql
        systemctl disable mysql
        apt-get remove -y mysql-server mysql-client 2>/dev/null || true
        rm -rf /var/lib/mysql
        log_info "MySQL removed"
    fi

    # MongoDB
    if systemctl is-active --quiet mongod 2>/dev/null; then
        log_info "Stopping MongoDB..."
        systemctl stop mongod
        systemctl disable mongod
        apt-get remove -y mongodb-org 2>/dev/null || true
        rm -rf /var/lib/mongodb
        rm -f /etc/apt/sources.list.d/mongodb-org-7.0.list
        log_info "MongoDB removed"
    fi

    # RabbitMQ
    if systemctl is-active --quiet rabbitmq-server 2>/dev/null; then
        log_info "Stopping RabbitMQ..."
        systemctl stop rabbitmq-server
        systemctl disable rabbitmq-server
        apt-get remove -y rabbitmq-server 2>/dev/null || true
        rm -rf /var/lib/rabbitmq
        log_info "RabbitMQ removed"
    fi

    # NFS
    if [[ -d /data/stackbill ]]; then
        log_info "Removing NFS data..."
        rm -rf /data/stackbill
        sed -i '/\/data\/stackbill/d' /etc/exports 2>/dev/null || true
        exportfs -a 2>/dev/null || true
        log_info "NFS data removed"
    fi

    log_info "Host databases removed"
}

show_remaining() {
    if [[ "$DELETE_NAMESPACE" == "true" ]]; then
        return
    fi

    echo ""
    log_info "Remaining resources in namespace '$NAMESPACE':"
    kubectl get all -n "$NAMESPACE" 2>/dev/null || echo "  Namespace may be deleted"
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -n|--namespace) NAMESPACE="$2"; shift 2 ;;
        -r|--release) RELEASE_NAME="$2"; shift 2 ;;
        --delete-pvc) DELETE_PVC=true; shift ;;
        --delete-namespace) DELETE_NAMESPACE=true; shift ;;
        --delete-db) DELETE_DB=true; shift ;;
        --force) FORCE=true; shift ;;
        -h|--help) show_help; exit 0 ;;
        *) log_error "Unknown option: $1"; show_help; exit 1 ;;
    esac
done

# Main
echo ""
echo -e "${BLUE}StackBill POC Uninstaller${NC}"
echo "========================="
echo ""

confirm_action
uninstall_helm_release
delete_istio_resources
delete_pvcs
delete_namespace_func
delete_host_databases
show_remaining

echo ""
log_info "Uninstall completed!"

if [[ "$DELETE_DB" != "true" ]]; then
    echo ""
    log_warn "Host databases (MySQL, MongoDB, RabbitMQ) were preserved."
    log_warn "To remove them, run: $0 --delete-db --force"
fi
