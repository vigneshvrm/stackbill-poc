#!/bin/bash
#===============================================================================
# StackBill Helm Chart - Uninstallation Script
#
# This script removes StackBill deployment from Kubernetes
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
DELETE_NAMESPACE=false
DELETE_PVC=false
FORCE=false

#-------------------------------------------------------------------------------
# Functions
#-------------------------------------------------------------------------------

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
    echo "  --delete-pvc             Delete PersistentVolumeClaims (WARNING: Data loss!)"
    echo "  --delete-namespace       Delete the namespace after uninstall"
    echo "  --force                  Skip confirmation prompts"
    echo "  -h, --help               Show this help message"
    echo ""
    echo "Examples:"
    echo "  # Basic uninstall"
    echo "  $0"
    echo ""
    echo "  # Uninstall with data cleanup"
    echo "  $0 --delete-pvc"
    echo ""
    echo "  # Complete cleanup"
    echo "  $0 --delete-pvc --delete-namespace --force"
}

confirm_action() {
    if [ "$FORCE" = true ]; then
        return 0
    fi

    echo ""
    echo -e "${YELLOW}WARNING: This will uninstall StackBill from namespace '$NAMESPACE'${NC}"
    if [ "$DELETE_PVC" = true ]; then
        echo -e "${RED}WARNING: --delete-pvc flag is set. ALL DATA WILL BE LOST!${NC}"
    fi
    if [ "$DELETE_NAMESPACE" = true ]; then
        echo -e "${YELLOW}WARNING: The namespace '$NAMESPACE' will also be deleted${NC}"
    fi
    echo ""
    read -p "Are you sure you want to continue? [y/N] " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Uninstall cancelled."
        exit 0
    fi
}

uninstall_release() {
    log_info "Uninstalling Helm release: $RELEASE_NAME"

    if helm status "$RELEASE_NAME" -n "$NAMESPACE" &> /dev/null; then
        helm uninstall "$RELEASE_NAME" -n "$NAMESPACE"
        log_info "  ✓ Helm release uninstalled"
    else
        log_warn "  Release '$RELEASE_NAME' not found in namespace '$NAMESPACE'"
    fi
}

delete_pvcs() {
    if [ "$DELETE_PVC" != true ]; then
        return
    fi

    log_info "Deleting PersistentVolumeClaims..."

    # Get all PVCs in namespace
    PVCS=$(kubectl get pvc -n "$NAMESPACE" -o name 2>/dev/null || true)

    if [ -n "$PVCS" ]; then
        echo "$PVCS" | while read -r pvc; do
            log_info "  Deleting $pvc"
            kubectl delete "$pvc" -n "$NAMESPACE" --wait=false
        done
        log_info "  ✓ PVCs deleted"
    else
        log_info "  No PVCs found"
    fi
}

delete_secrets() {
    log_info "Cleaning up secrets..."

    # Delete stackbill-specific secrets
    kubectl delete secret -n "$NAMESPACE" -l "app.kubernetes.io/name=stackbill" 2>/dev/null || true

    log_info "  ✓ Secrets cleaned up"
}

delete_configmaps() {
    log_info "Cleaning up ConfigMaps..."

    # Delete stackbill-specific configmaps
    kubectl delete configmap -n "$NAMESPACE" -l "app.kubernetes.io/name=stackbill" 2>/dev/null || true

    log_info "  ✓ ConfigMaps cleaned up"
}

delete_namespace_func() {
    if [ "$DELETE_NAMESPACE" != true ]; then
        return
    fi

    log_info "Deleting namespace: $NAMESPACE"

    kubectl delete namespace "$NAMESPACE" --wait=false

    log_info "  ✓ Namespace deletion initiated"
}

show_remaining_resources() {
    if [ "$DELETE_NAMESPACE" = true ]; then
        return
    fi

    echo ""
    log_info "Remaining resources in namespace '$NAMESPACE':"
    echo ""

    # Show remaining PVCs
    echo "PersistentVolumeClaims:"
    kubectl get pvc -n "$NAMESPACE" 2>/dev/null || echo "  None"
    echo ""

    # Show remaining secrets
    echo "Secrets:"
    kubectl get secrets -n "$NAMESPACE" 2>/dev/null || echo "  None"
    echo ""

    if [ "$DELETE_PVC" != true ]; then
        log_warn "PVCs were preserved. To delete data, run with --delete-pvc flag"
    fi
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
        --delete-pvc)
            DELETE_PVC=true
            shift
            ;;
        --delete-namespace)
            DELETE_NAMESPACE=true
            shift
            ;;
        --force)
            FORCE=true
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

#-------------------------------------------------------------------------------
# Main Execution
#-------------------------------------------------------------------------------

echo ""
echo -e "${BLUE}StackBill Uninstaller${NC}"
echo "================================"
echo ""

confirm_action
uninstall_release
delete_secrets
delete_configmaps
delete_pvcs
delete_namespace_func
show_remaining_resources

echo ""
log_info "Uninstall completed!"
