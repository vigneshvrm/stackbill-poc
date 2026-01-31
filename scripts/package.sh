#!/bin/bash
#===============================================================================
# StackBill Helm Chart - Packaging Script
#
# Creates a distributable package for client deployment
#===============================================================================

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART_DIR="$(dirname "$SCRIPT_DIR")"
PACKAGE_NAME="stackbill-installer"
VERSION=$(grep "^version:" "$CHART_DIR/Chart.yaml" | awk '{print $2}')
OUTPUT_DIR="$CHART_DIR/dist"

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

print_banner() {
    echo -e "${BLUE}"
    echo "==============================================================================="
    echo "  StackBill Helm Chart Packager"
    echo "  Version: $VERSION"
    echo "==============================================================================="
    echo -e "${NC}"
}

clean_dist() {
    log_info "Cleaning previous builds..."
    rm -rf "$OUTPUT_DIR"
    mkdir -p "$OUTPUT_DIR"
}

update_dependencies() {
    log_info "Updating Helm dependencies..."
    cd "$CHART_DIR"
    helm dependency update .
    cd - > /dev/null
}

lint_chart() {
    log_info "Linting Helm chart..."
    cd "$CHART_DIR"
    helm lint . -f values-sandbox.yaml
    cd - > /dev/null
    log_info "  ✓ Chart passed linting"
}

package_helm_chart() {
    log_info "Packaging Helm chart..."
    cd "$CHART_DIR"
    helm package . -d "$OUTPUT_DIR"
    cd - > /dev/null
    log_info "  ✓ Helm chart packaged"
}

create_installer_archive() {
    log_info "Creating installer archive..."

    ARCHIVE_NAME="${PACKAGE_NAME}-${VERSION}"
    ARCHIVE_DIR="$OUTPUT_DIR/$ARCHIVE_NAME"

    # Create archive structure
    mkdir -p "$ARCHIVE_DIR"
    mkdir -p "$ARCHIVE_DIR/chart"
    mkdir -p "$ARCHIVE_DIR/scripts"
    mkdir -p "$ARCHIVE_DIR/docs"

    # Copy Helm chart
    cp -r "$CHART_DIR/Chart.yaml" "$ARCHIVE_DIR/chart/"
    cp -r "$CHART_DIR/values.yaml" "$ARCHIVE_DIR/chart/"
    cp -r "$CHART_DIR/values-sandbox.yaml" "$ARCHIVE_DIR/chart/"
    cp -r "$CHART_DIR/values-production.yaml" "$ARCHIVE_DIR/chart/"
    cp -r "$CHART_DIR/templates" "$ARCHIVE_DIR/chart/"
    cp -r "$CHART_DIR/charts" "$ARCHIVE_DIR/chart/" 2>/dev/null || true

    # Copy scripts
    cp "$CHART_DIR/scripts/install.sh" "$ARCHIVE_DIR/scripts/"
    cp "$CHART_DIR/scripts/uninstall.sh" "$ARCHIVE_DIR/scripts/"
    chmod +x "$ARCHIVE_DIR/scripts/"*.sh

    # Create quick-start script
    cat > "$ARCHIVE_DIR/quick-install.sh" << 'QUICKINSTALL'
#!/bin/bash
#===============================================================================
# StackBill Quick Install
# Run this script to quickly deploy StackBill in sandbox mode
#===============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo ""
echo "================================================"
echo "  StackBill Quick Install"
echo "================================================"
echo ""

# Check prerequisites
echo "Checking prerequisites..."

if ! command -v kubectl &> /dev/null; then
    echo "ERROR: kubectl is not installed"
    exit 1
fi

if ! command -v helm &> /dev/null; then
    echo "ERROR: helm is not installed"
    exit 1
fi

echo "  ✓ All prerequisites met"
echo ""

# Run installer
cd "$SCRIPT_DIR"
./scripts/install.sh -e sandbox --chart-path ./chart "$@"
QUICKINSTALL
    chmod +x "$ARCHIVE_DIR/quick-install.sh"

    # Create README
    cat > "$ARCHIVE_DIR/README.md" << 'README'
# StackBill Kubernetes Installer

## Quick Start (Sandbox)

```bash
# Make scripts executable
chmod +x quick-install.sh scripts/*.sh

# Run quick install
./quick-install.sh
```

## Custom Installation

```bash
# Sandbox environment
./scripts/install.sh -e sandbox

# Production environment
./scripts/install.sh -e production --domain portal.example.com

# With custom passwords
./scripts/install.sh \
  --mysql-password 'YourSecurePassword' \
  --mongodb-password 'YourSecurePassword' \
  --rabbitmq-password 'YourSecurePassword'
```

## Prerequisites

- Kubernetes cluster (1.29+)
- kubectl configured
- Helm 3.x installed
- Storage class available

## Minimum Requirements

### Sandbox
- 8 vCPU, 16GB RAM, 100GB storage

### Production
- 3 Kubernetes nodes
- 16 vCPU, 32GB RAM, 500GB storage

## Uninstall

```bash
# Keep data
./scripts/uninstall.sh

# Delete everything
./scripts/uninstall.sh --delete-pvc --delete-namespace
```

## Support

- Documentation: https://docs.stackbill.com
- Support: support@stackbill.com
README

    # Create tarball
    cd "$OUTPUT_DIR"
    tar -czvf "${ARCHIVE_NAME}.tar.gz" "$ARCHIVE_NAME"

    # Create zip for Windows users
    if command -v zip &> /dev/null; then
        zip -r "${ARCHIVE_NAME}.zip" "$ARCHIVE_NAME"
    fi

    # Cleanup
    rm -rf "$ARCHIVE_NAME"

    cd - > /dev/null
    log_info "  ✓ Installer archive created"
}

generate_checksums() {
    log_info "Generating checksums..."

    cd "$OUTPUT_DIR"

    if command -v sha256sum &> /dev/null; then
        sha256sum *.tar.gz *.tgz > SHA256SUMS.txt 2>/dev/null || true
        sha256sum *.zip >> SHA256SUMS.txt 2>/dev/null || true
    elif command -v shasum &> /dev/null; then
        shasum -a 256 *.tar.gz *.tgz > SHA256SUMS.txt 2>/dev/null || true
        shasum -a 256 *.zip >> SHA256SUMS.txt 2>/dev/null || true
    fi

    cd - > /dev/null
    log_info "  ✓ Checksums generated"
}

show_output() {
    echo ""
    echo -e "${BLUE}===============================================================================${NC}"
    echo -e "${BLUE}                          PACKAGING COMPLETE${NC}"
    echo -e "${BLUE}===============================================================================${NC}"
    echo ""
    echo "Output directory: $OUTPUT_DIR"
    echo ""
    echo "Files created:"
    ls -lh "$OUTPUT_DIR"
    echo ""
    echo "Distribution files:"
    echo "  - ${PACKAGE_NAME}-${VERSION}.tar.gz (Linux/Mac)"
    if [ -f "$OUTPUT_DIR/${PACKAGE_NAME}-${VERSION}.zip" ]; then
        echo "  - ${PACKAGE_NAME}-${VERSION}.zip (Windows)"
    fi
    echo "  - stackbill-${VERSION}.tgz (Helm chart only)"
    echo ""
    echo "Upload these files to your distribution server or send to clients."
    echo ""
}

#-------------------------------------------------------------------------------
# Main Execution
#-------------------------------------------------------------------------------

print_banner
clean_dist
update_dependencies
lint_chart
package_helm_chart
create_installer_archive
generate_checksums
show_output

log_info "Packaging completed successfully!"
