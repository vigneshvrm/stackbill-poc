#!/bin/bash
#===============================================================================
# StackBill POC - Step 1: Prerequisites Setup
#
# This script prepares the environment for StackBill deployment:
#   1. Installs K3s (lightweight Kubernetes) - OR connects to existing cluster
#   2. Installs Istio service mesh
#   3. Configures storage class
#   4. Verifies all components ready
#
# Run this BEFORE install-poc.sh
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
K3S_VERSION="v1.29.0+k3s1"
ISTIO_VERSION="1.20.3"
INSTALL_K3S=false
INSTALL_ISTIO=true
SKIP_CONFIRM=false

#-------------------------------------------------------------------------------
# Functions
#-------------------------------------------------------------------------------

print_banner() {
    echo -e "${CYAN}"
    echo "╔═══════════════════════════════════════════════════════════════════════════╗"
    echo "║                                                                           ║"
    echo "║     StackBill POC - Prerequisites Setup (Step 1)                          ║"
    echo "║                                                                           ║"
    echo "║     This script will:                                                     ║"
    echo "║       • Install/verify Kubernetes cluster                                 ║"
    echo "║       • Install Istio service mesh                                        ║"
    echo "║       • Configure storage                                                 ║"
    echo "║       • Verify all prerequisites                                          ║"
    echo "║                                                                           ║"
    echo "╚═══════════════════════════════════════════════════════════════════════════╝"
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

log_step() {
    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}  STEP: $1${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

show_help() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "StackBill POC Prerequisites Setup Script"
    echo ""
    echo "Options:"
    echo "  --install-k3s          Install K3s Kubernetes (skip if cluster exists)"
    echo "  --skip-istio           Skip Istio installation"
    echo "  --istio-version VER    Istio version (default: $ISTIO_VERSION)"
    echo "  --k3s-version VER      K3s version (default: $K3S_VERSION)"
    echo "  -y, --yes              Skip confirmation prompts"
    echo "  -h, --help             Show this help"
    echo ""
    echo "Examples:"
    echo "  # Check existing cluster and install Istio"
    echo "  $0"
    echo ""
    echo "  # Install K3s + Istio (fresh setup)"
    echo "  $0 --install-k3s"
    echo ""
    echo "  # Only verify prerequisites (no installation)"
    echo "  $0 --skip-istio"
}

check_root() {
    if [ "$EUID" -ne 0 ]; then
        log_warn "Not running as root. Some operations may require sudo."
    fi
}

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
        log_info "✓ CPU cores OK"
    fi

    # Check RAM
    TOTAL_RAM=$(free -g | awk '/^Mem:/{print $2}')
    log_info "Total RAM: ${TOTAL_RAM}GB"
    if [ "$TOTAL_RAM" -lt 8 ]; then
        log_warn "Minimum 8GB RAM recommended. Current: ${TOTAL_RAM}GB"
    else
        log_info "✓ RAM OK"
    fi

    # Check Disk
    DISK_FREE=$(df -BG / | awk 'NR==2 {print $4}' | tr -d 'G')
    log_info "Free Disk: ${DISK_FREE}GB"
    if [ "$DISK_FREE" -lt 50 ]; then
        log_warn "Minimum 50GB free disk recommended. Current: ${DISK_FREE}GB"
    else
        log_info "✓ Disk space OK"
    fi
}

check_existing_kubernetes() {
    log_step "Checking Kubernetes Cluster"

    if command -v kubectl &> /dev/null; then
        log_info "✓ kubectl found"

        if kubectl cluster-info &> /dev/null 2>&1; then
            log_info "✓ Kubernetes cluster is accessible"

            # Get cluster info
            K8S_VERSION=$(kubectl version --short 2>/dev/null | grep "Server" | awk '{print $3}' || echo "unknown")
            log_info "  Kubernetes Version: $K8S_VERSION"

            # Get nodes
            NODE_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
            log_info "  Node Count: $NODE_COUNT"

            kubectl get nodes

            INSTALL_K3S=false
            return 0
        else
            log_warn "kubectl found but cannot connect to cluster"
            return 1
        fi
    else
        log_warn "kubectl not found"
        return 1
    fi
}

install_kubectl() {
    log_info "Installing kubectl..."

    if command -v kubectl &> /dev/null; then
        log_info "kubectl already installed"
        return 0
    fi

    # Download kubectl
    curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
    chmod +x kubectl
    sudo mv kubectl /usr/local/bin/

    log_info "✓ kubectl installed"
}

install_helm() {
    log_step "Installing Helm"

    if command -v helm &> /dev/null; then
        HELM_VER=$(helm version --short 2>/dev/null)
        log_info "✓ Helm already installed: $HELM_VER"
        return 0
    fi

    log_info "Installing Helm..."

    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

    log_info "✓ Helm installed"
    helm version --short
}

install_k3s() {
    log_step "Installing K3s Kubernetes"

    if ! $INSTALL_K3S; then
        log_info "Skipping K3s installation (existing cluster found or --install-k3s not specified)"
        return 0
    fi

    if command -v k3s &> /dev/null; then
        log_info "K3s already installed"
        K3S_VER=$(k3s --version | head -1)
        log_info "  Version: $K3S_VER"
        return 0
    fi

    log_info "Installing K3s version: $K3S_VERSION"
    log_info "This will take a few minutes..."

    # Install K3s with required features
    curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="$K3S_VERSION" sh -s - \
        --write-kubeconfig-mode 644 \
        --disable traefik \
        --disable servicelb

    # Wait for K3s to be ready
    log_info "Waiting for K3s to start..."
    sleep 10

    # Setup kubeconfig
    mkdir -p ~/.kube
    sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
    sudo chown $(id -u):$(id -g) ~/.kube/config
    export KUBECONFIG=~/.kube/config

    # Verify
    kubectl get nodes

    log_info "✓ K3s installed successfully"
}

install_istio() {
    log_step "Installing Istio Service Mesh"

    if ! $INSTALL_ISTIO; then
        log_info "Skipping Istio installation (--skip-istio specified)"
        return 0
    fi

    # Check if Istio already installed
    if kubectl get namespace istio-system &> /dev/null 2>&1; then
        log_info "Istio namespace exists, checking installation..."

        if kubectl get pods -n istio-system -l app=istiod --no-headers 2>/dev/null | grep -q "Running"; then
            log_info "✓ Istio is already installed and running"
            kubectl get pods -n istio-system
            return 0
        fi
    fi

    log_info "Installing Istio version: $ISTIO_VERSION"

    # Download istioctl
    if ! command -v istioctl &> /dev/null; then
        log_info "Downloading istioctl..."
        curl -L https://istio.io/downloadIstio | ISTIO_VERSION=$ISTIO_VERSION sh -
        sudo mv istio-$ISTIO_VERSION/bin/istioctl /usr/local/bin/
        rm -rf istio-$ISTIO_VERSION
    fi

    # Install Istio with demo profile (good for POC)
    log_info "Installing Istio with demo profile..."
    istioctl install --set profile=demo -y

    # Wait for Istio to be ready
    log_info "Waiting for Istio pods to be ready..."
    kubectl wait --for=condition=ready pod -l app=istiod -n istio-system --timeout=300s
    kubectl wait --for=condition=ready pod -l app=istio-ingressgateway -n istio-system --timeout=300s

    # Get Istio ingress gateway IP
    log_info "Istio Ingress Gateway:"
    kubectl get svc istio-ingressgateway -n istio-system

    log_info "✓ Istio installed successfully"
}

setup_storage_class() {
    log_step "Setting Up Storage Class"

    # Check existing storage classes
    log_info "Existing storage classes:"
    kubectl get storageclass

    # Check for default storage class
    DEFAULT_SC=$(kubectl get storageclass -o jsonpath='{.items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")].metadata.name}' 2>/dev/null)

    if [ -n "$DEFAULT_SC" ]; then
        log_info "✓ Default storage class found: $DEFAULT_SC"
    else
        log_warn "No default storage class found"

        # For K3s, local-path is usually available
        if kubectl get storageclass local-path &> /dev/null 2>&1; then
            log_info "Setting local-path as default storage class..."
            kubectl patch storageclass local-path -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
            log_info "✓ local-path set as default"
        else
            log_warn "Please configure a default storage class manually"
        fi
    fi
}

create_namespace() {
    log_step "Creating StackBill Namespace"

    if kubectl get namespace sb-system &> /dev/null 2>&1; then
        log_info "Namespace sb-system already exists"
    else
        kubectl create namespace sb-system
        log_info "✓ Namespace sb-system created"
    fi

    # Enable Istio injection
    kubectl label namespace sb-system istio-injection=enabled --overwrite
    log_info "✓ Istio injection enabled for sb-system"
}

verify_prerequisites() {
    log_step "Verifying All Prerequisites"

    local all_ok=true

    echo ""
    echo "Verification Results:"
    echo "─────────────────────────────────────────────────────────────"

    # Check kubectl
    if command -v kubectl &> /dev/null && kubectl cluster-info &> /dev/null 2>&1; then
        echo -e "  Kubernetes Cluster:  ${GREEN}✓ OK${NC}"
    else
        echo -e "  Kubernetes Cluster:  ${RED}✗ FAILED${NC}"
        all_ok=false
    fi

    # Check Helm
    if command -v helm &> /dev/null; then
        echo -e "  Helm:                ${GREEN}✓ OK${NC}"
    else
        echo -e "  Helm:                ${RED}✗ FAILED${NC}"
        all_ok=false
    fi

    # Check Istio
    if kubectl get namespace istio-system &> /dev/null 2>&1; then
        if kubectl get pods -n istio-system -l app=istiod --no-headers 2>/dev/null | grep -q "Running"; then
            echo -e "  Istio:               ${GREEN}✓ OK${NC}"
        else
            echo -e "  Istio:               ${YELLOW}⚠ Pods not ready${NC}"
            all_ok=false
        fi
    else
        echo -e "  Istio:               ${RED}✗ NOT INSTALLED${NC}"
        all_ok=false
    fi

    # Check storage class
    if kubectl get storageclass -o jsonpath='{.items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")].metadata.name}' 2>/dev/null | grep -q .; then
        echo -e "  Storage Class:       ${GREEN}✓ OK${NC}"
    else
        echo -e "  Storage Class:       ${YELLOW}⚠ No default${NC}"
    fi

    # Check namespace
    if kubectl get namespace sb-system &> /dev/null 2>&1; then
        echo -e "  Namespace sb-system: ${GREEN}✓ OK${NC}"
    else
        echo -e "  Namespace sb-system: ${YELLOW}⚠ Not created${NC}"
    fi

    echo "─────────────────────────────────────────────────────────────"
    echo ""

    if $all_ok; then
        return 0
    else
        return 1
    fi
}

show_next_steps() {
    echo ""
    echo -e "${GREEN}"
    echo "╔═══════════════════════════════════════════════════════════════════════════╗"
    echo "║                                                                           ║"
    echo "║                    PREREQUISITES SETUP COMPLETE!                          ║"
    echo "║                                                                           ║"
    echo "╚═══════════════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    echo ""
    echo -e "${CYAN}Next Step - Run the POC Installer:${NC}"
    echo ""
    echo "  ./scripts/install-poc.sh \\"
    echo "    --domain your-domain.com \\"
    echo "    --ssl-cert /path/to/certificate.pem \\"
    echo "    --ssl-key /path/to/private-key.pem"
    echo ""
    echo -e "${CYAN}Useful Commands:${NC}"
    echo ""
    echo "  # Check cluster status"
    echo "  kubectl get nodes"
    echo ""
    echo "  # Check Istio status"
    echo "  kubectl get pods -n istio-system"
    echo ""
    echo "  # Get Istio Ingress IP (for DNS)"
    echo "  kubectl get svc istio-ingressgateway -n istio-system"
    echo ""
}

#-------------------------------------------------------------------------------
# Parse Arguments
#-------------------------------------------------------------------------------

while [[ $# -gt 0 ]]; do
    case $1 in
        --install-k3s)
            INSTALL_K3S=true
            shift
            ;;
        --skip-istio)
            INSTALL_ISTIO=false
            shift
            ;;
        --istio-version)
            ISTIO_VERSION="$2"
            shift 2
            ;;
        --k3s-version)
            K3S_VERSION="$2"
            shift 2
            ;;
        -y|--yes)
            SKIP_CONFIRM=true
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

print_banner
check_root
check_system_requirements

# Check if Kubernetes exists
if ! check_existing_kubernetes; then
    if ! $INSTALL_K3S; then
        echo ""
        log_warn "No Kubernetes cluster found."
        echo ""
        read -p "Would you like to install K3s? [y/N] " -n 1 -r
        echo ""
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            INSTALL_K3S=true
        else
            log_error "Kubernetes cluster required. Run with --install-k3s or setup cluster manually."
            exit 1
        fi
    fi
fi

# Confirmation
if ! $SKIP_CONFIRM; then
    echo ""
    echo "This script will:"
    if $INSTALL_K3S; then
        echo "  • Install K3s Kubernetes ($K3S_VERSION)"
    fi
    echo "  • Install Helm"
    if $INSTALL_ISTIO; then
        echo "  • Install Istio ($ISTIO_VERSION)"
    fi
    echo "  • Configure storage class"
    echo "  • Create sb-system namespace"
    echo ""
    read -p "Continue? [Y/n] " -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Nn]$ ]]; then
        log_info "Aborted."
        exit 0
    fi
fi

# Run installation steps
install_kubectl
install_k3s
install_helm
install_istio
setup_storage_class
create_namespace

# Verify everything
if verify_prerequisites; then
    show_next_steps
    exit 0
else
    log_error "Some prerequisites failed. Please check the errors above."
    exit 1
fi
