#!/bin/bash
# ============================================
# STACKBILL POC INSTALLER - FULLY AUTOMATED
# ============================================
# Installs StackBill directly from AWS ECR
# Interactive mode: prompts for domain and SSL configuration
#
# Usage:
#   export AWS_ECR_TOKEN="your-ecr-token"
#   sudo -E ./install-stackbill-poc.sh
#
# Get ECR token with:
#   aws ecr get-login-password --region ap-south-1
#
# ============================================

set -e
trap 'echo "ERROR: Script failed at line $LINENO with exit code $?" >&2' ERR

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Configuration
STACKBILL_NAMESPACE="sb-apps"
K3S_VERSION="v1.29.0+k3s1"
ISTIO_VERSION="1.20.3"
STACKBILL_CHART="oci://public.ecr.aws/p0g2c5k8/stackbill"
ECR_REGISTRY="730335576030.dkr.ecr.ap-south-1.amazonaws.com"
ECR_REGION="ap-south-1"

# User inputs
DOMAIN=""
SSL_CERT=""
SSL_KEY=""
EMAIL=""
SSL_MODE=""  # "letsencrypt" or "custom"

# CloudStack configuration
CLOUDSTACK_MODE=""  # "existing" or "simulator"
CLOUDSTACK_URL=""
CLOUDSTACK_API_KEY=""
CLOUDSTACK_SECRET_KEY=""
CLOUDSTACK_ADMIN_USER=""
CLOUDSTACK_ADMIN_PASSWORD=""

# Auto-generated passwords
MYSQL_PASSWORD=""
MONGODB_PASSWORD=""
RABBITMQ_PASSWORD=""
SERVER_IP=""

# Flags
SKIP_INFRA=false
SKIP_DB=false

# Logging
log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() {
    echo ""
    echo -e "${BLUE}════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}════════════════════════════════════════════════════════════════${NC}"
}

print_banner() {
    echo ""
    echo -e "${CYAN}"
    echo "╔═══════════════════════════════════════════════════════════════╗"
    echo "║            STACKBILL POC INSTALLER                            ║"
    echo "╠═══════════════════════════════════════════════════════════════╣"
    echo "║  This script will install:                                    ║"
    echo "║    • K3s Kubernetes with Istio service mesh                   ║"
    echo "║    • MariaDB, MongoDB, RabbitMQ databases                     ║"
    echo "║    • StackBill Cloud Management Platform                      ║"
    echo "║    • CloudStack Simulator (optional, for POC)                 ║"
    echo "║                                                               ║"
    echo "║  You will be prompted for:                                    ║"
    echo "║    • Domain name                                              ║"
    echo "║    • SSL certificate (Let's Encrypt or custom)                ║"
    echo "║    • CloudStack configuration                                 ║"
    echo "║    • AWS ECR token (for pulling images)                       ║"
    echo "╚═══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

generate_password() {
    openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 16
}

CREDENTIALS_FILE="/root/stackbill-credentials.txt"

load_or_generate_passwords() {
    # Check if credentials file exists from a previous installation
    if [[ -f "$CREDENTIALS_FILE" ]]; then
        log_info "Found existing credentials file: $CREDENTIALS_FILE"

        # Extract passwords from credentials file
        local mysql_pw=$(grep -A5 "^MYSQL:" "$CREDENTIALS_FILE" | grep "Password:" | awk '{print $2}')
        local mongo_pw=$(grep -A5 "^MONGODB:" "$CREDENTIALS_FILE" | grep "Password:" | awk '{print $2}')
        local rabbit_pw=$(grep -A5 "^RABBITMQ:" "$CREDENTIALS_FILE" | grep "Password:" | awk '{print $2}')

        # Use existing passwords if found, otherwise generate new
        if [[ -n "$mysql_pw" && -n "$mongo_pw" && -n "$rabbit_pw" ]]; then
            MYSQL_PASSWORD="$mysql_pw"
            MONGODB_PASSWORD="$mongo_pw"
            RABBITMQ_PASSWORD="$rabbit_pw"
            log_info "Loaded existing passwords from credentials file"
            log_info "  (To generate new passwords, delete $CREDENTIALS_FILE and re-run)"
            return 0
        else
            log_warn "Credentials file incomplete, generating new passwords"
        fi
    fi

    # Generate new passwords
    log_info "Generating new passwords..."
    MYSQL_PASSWORD=$(generate_password)
    MONGODB_PASSWORD=$(generate_password)
    RABBITMQ_PASSWORD=$(generate_password)
    log_info "New passwords generated"
}

# ============================================
# INTERACTIVE INPUT FUNCTIONS
# ============================================

prompt_domain() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  STEP 1: Domain Configuration${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo "Enter the domain name for your StackBill portal."
    echo "Example: stackbill.example.com"
    echo ""

    while [[ -z "$DOMAIN" ]]; do
        echo -n "Domain name: "
        read DOMAIN < /dev/tty

        # Basic validation
        if [[ -z "$DOMAIN" ]]; then
            echo -e "${RED}Domain name cannot be empty. Please try again.${NC}"
        elif [[ ! "$DOMAIN" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
            echo -e "${YELLOW}Warning: '$DOMAIN' may not be a valid domain format.${NC}"
            echo -n "Continue with this domain? [y/N]: "
            read confirm < /dev/tty
            if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
                DOMAIN=""
            fi
        fi
    done

    echo ""
    log_info "Domain set to: $DOMAIN"
}

prompt_ssl_option() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  STEP 2: SSL Certificate Configuration${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo "How would you like to configure SSL?"
    echo ""
    echo -e "  ${GREEN}1)${NC} Let's Encrypt (Automatic) - FREE certificate, auto-renewed"
    echo "     Requires: Domain DNS must point to this server"
    echo ""
    echo -e "  ${GREEN}2)${NC} Custom Certificate - Provide your own certificate files"
    echo "     Requires: fullchain.pem and privatekey.pem files"
    echo ""

    while [[ -z "$SSL_MODE" ]]; do
        echo -n "Select option [1 or 2]: "
        read ssl_choice < /dev/tty

        case $ssl_choice in
            1)
                SSL_MODE="letsencrypt"
                prompt_letsencrypt_email
                ;;
            2)
                SSL_MODE="custom"
                prompt_custom_certificates
                ;;
            *)
                echo -e "${RED}Invalid option. Please enter 1 or 2.${NC}"
                ;;
        esac
    done
}

prompt_letsencrypt_email() {
    echo ""
    echo "Let's Encrypt requires an email address for certificate notifications."
    echo ""

    while [[ -z "$EMAIL" ]]; do
        echo -n "Email address: "
        read EMAIL < /dev/tty

        if [[ -z "$EMAIL" ]]; then
            echo -e "${RED}Email cannot be empty for Let's Encrypt.${NC}"
        elif [[ ! "$EMAIL" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then
            echo -e "${YELLOW}Warning: '$EMAIL' may not be a valid email format.${NC}"
            echo -n "Continue with this email? [y/N]: "
            read confirm < /dev/tty
            if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
                EMAIL=""
            fi
        fi
    done

    echo ""
    log_info "Email set to: $EMAIL"
    log_info "SSL Mode: Let's Encrypt (automatic)"
}

prompt_custom_certificates() {
    echo ""
    echo "Please provide the paths to your SSL certificate files."
    echo ""

    # Get certificate path
    while [[ -z "$SSL_CERT" || ! -f "$SSL_CERT" ]]; do
        echo -n "Path to SSL certificate (fullchain.pem): "
        read SSL_CERT < /dev/tty

        if [[ -z "$SSL_CERT" ]]; then
            echo -e "${RED}Path cannot be empty.${NC}"
        elif [[ ! -f "$SSL_CERT" ]]; then
            echo -e "${RED}File not found: $SSL_CERT${NC}"
            SSL_CERT=""
        fi
    done

    # Get private key path
    while [[ -z "$SSL_KEY" || ! -f "$SSL_KEY" ]]; do
        echo -n "Path to private key (privatekey.pem): "
        read SSL_KEY < /dev/tty

        if [[ -z "$SSL_KEY" ]]; then
            echo -e "${RED}Path cannot be empty.${NC}"
        elif [[ ! -f "$SSL_KEY" ]]; then
            echo -e "${RED}File not found: $SSL_KEY${NC}"
            SSL_KEY=""
        fi
    done

    # Set a default email for custom certs
    EMAIL="admin@${DOMAIN}"

    echo ""
    log_info "SSL Certificate: $SSL_CERT"
    log_info "SSL Private Key: $SSL_KEY"
    log_info "SSL Mode: Custom certificate"
}

prompt_cloudstack_option() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  STEP 3: CloudStack Configuration${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo "StackBill requires CloudStack to manage cloud infrastructure."
    echo ""
    echo -e "  ${GREEN}1)${NC} I have an existing CloudStack deployment"
    echo "     You will configure CloudStack connection after installation"
    echo ""
    echo -e "  ${GREEN}2)${NC} Deploy CloudStack Simulator for POC/Testing"
    echo "     We will deploy Apache CloudStack Simulator using Podman"
    echo "     (Recommended for POC and testing environments)"
    echo ""

    while [[ -z "$CLOUDSTACK_MODE" ]]; do
        echo -n "Select option [1 or 2]: "
        read cs_choice < /dev/tty

        case $cs_choice in
            1)
                CLOUDSTACK_MODE="existing"
                log_info "CloudStack Mode: Use existing deployment"
                ;;
            2)
                CLOUDSTACK_MODE="simulator"
                log_info "CloudStack Mode: Deploy CloudStack Simulator"
                ;;
            *)
                echo -e "${RED}Invalid option. Please enter 1 or 2.${NC}"
                ;;
        esac
    done
}

prompt_ecr_token() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  STEP 4: AWS ECR Token${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo "An AWS ECR token is required to pull StackBill images."
    echo ""
    echo "To get a token, run this command on a machine with AWS CLI configured:"
    echo -e "  ${GREEN}aws ecr get-login-password --region ap-south-1${NC}"
    echo ""
    echo "The token is a long base64 string (usually 1000+ characters)."
    echo ""

    while [[ -z "$AWS_ECR_TOKEN" ]]; do
        echo -n "Paste your ECR token: "
        read -s AWS_ECR_TOKEN < /dev/tty
        echo ""

        if [[ -z "$AWS_ECR_TOKEN" ]]; then
            echo -e "${RED}ECR token cannot be empty. Please try again.${NC}"
        elif [[ ${#AWS_ECR_TOKEN} -lt 100 ]]; then
            echo -e "${YELLOW}Warning: Token seems too short (${#AWS_ECR_TOKEN} chars). ECR tokens are usually 1000+ characters.${NC}"
            echo -n "Continue with this token? [y/N]: "
            read confirm < /dev/tty
            if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
                AWS_ECR_TOKEN=""
            fi
        fi
    done

    export AWS_ECR_TOKEN
    echo ""
    log_info "ECR Token: provided (${#AWS_ECR_TOKEN} chars)"
}

run_interactive_setup() {
    # Only run interactive setup if domain is not already set via args
    if [[ -z "$DOMAIN" ]]; then
        prompt_domain
    fi

    # Only run SSL setup if not already configured via args
    if [[ -z "$SSL_MODE" ]]; then
        if [[ -n "$SSL_CERT" && -n "$SSL_KEY" ]]; then
            # User provided certs via command line
            SSL_MODE="custom"
            EMAIL="${EMAIL:-admin@${DOMAIN}}"
        else
            prompt_ssl_option
        fi
    fi

    # CloudStack configuration
    if [[ -z "$CLOUDSTACK_MODE" ]]; then
        prompt_cloudstack_option
    fi

    # ECR token - prompt if not provided via environment variable
    if [[ -z "$AWS_ECR_TOKEN" ]]; then
        prompt_ecr_token
    fi
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --domain) DOMAIN="$2"; shift 2 ;;
            --ssl-cert) SSL_CERT="$2"; shift 2 ;;
            --ssl-key) SSL_KEY="$2"; shift 2 ;;
            --letsencrypt) SSL_MODE="letsencrypt"; shift ;;
            --email) EMAIL="$2"; shift 2 ;;
            --skip-infra) SKIP_INFRA=true; shift ;;
            --skip-db) SKIP_DB=true; shift ;;
            -h|--help) show_help; exit 0 ;;
            *) log_error "Unknown option: $1"; exit 1 ;;
        esac
    done
    return 0
}

show_help() {
    echo "StackBill POC Installer"
    echo ""
    echo "Usage:"
    echo "  sudo $0                       # Fully interactive mode (recommended)"
    echo "  sudo $0 [OPTIONS]             # Semi-interactive mode"
    echo ""
    echo "Interactive Mode (recommended):"
    echo "  Run without arguments to be guided through the setup:"
    echo "    1. Enter your domain name"
    echo "    2. Choose SSL option:"
    echo "       - Let's Encrypt (free, automatic)"
    echo "       - Custom certificate (provide your own files)"
    echo "    3. Choose CloudStack option:"
    echo "       - Use existing CloudStack deployment"
    echo "       - Deploy CloudStack Simulator for POC/testing"
    echo "    4. Enter AWS ECR token (for pulling StackBill images)"
    echo ""
    echo "  To get an ECR token, run on a machine with AWS CLI:"
    echo "    aws ecr get-login-password --region ap-south-1"
    echo ""
    echo "Command Line Options (optional):"
    echo "  --domain       Domain name for StackBill (e.g., stackbill.example.com)"
    echo "  --ssl-cert     Path to SSL certificate file (fullchain.pem)"
    echo "  --ssl-key      Path to SSL private key file (privatekey.pem)"
    echo "  --letsencrypt  Use Let's Encrypt for SSL (requires --email)"
    echo "  --email        Email for Let's Encrypt notifications"
    echo "  --skip-infra   Skip K3s/Istio installation (use existing cluster)"
    echo "  --skip-db      Skip database installation (use existing databases)"
    echo "  -h, --help     Show this help message"
    echo ""
    echo "Note: CloudStack and ECR token are always prompted interactively."
    echo "      You can also set AWS_ECR_TOKEN environment variable before running."
    echo ""
    echo "Examples:"
    echo "  # Fully interactive (recommended)"
    echo "  sudo $0"
    echo ""
    echo "  # With custom certificate (CloudStack and ECR token will be prompted)"
    echo "  sudo $0 --domain example.com --ssl-cert /path/to/cert.pem --ssl-key /path/to/key.pem"
    echo ""
    echo "  # With Let's Encrypt (CloudStack and ECR token will be prompted)"
    echo "  sudo $0 --domain example.com --letsencrypt --email admin@example.com"
}

validate_inputs() {
    log_info "Validating inputs..."

    # Check root first
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root (use sudo)"
        exit 1
    fi
    log_info "  Running as root: yes"

    # Check for AWS_ECR_TOKEN (should have been provided via env or interactive prompt)
    if [[ -z "$AWS_ECR_TOKEN" ]]; then
        log_error "AWS_ECR_TOKEN is required but not provided"
        exit 1
    fi
    log_info "  AWS ECR Token: provided (${#AWS_ECR_TOKEN} chars)"

    # Domain is always required
    if [[ -z "$DOMAIN" ]]; then
        log_error "Domain is required"
        exit 1
    fi
    log_info "  Domain: $DOMAIN"

    # Validate SSL configuration
    if [[ "$SSL_MODE" == "letsencrypt" ]]; then
        # Let's Encrypt mode - need email
        if [[ -z "$EMAIL" ]]; then
            log_error "Email is required for Let's Encrypt (--email)"
            exit 1
        fi
        log_info "  SSL Mode: Let's Encrypt"
        log_info "  Email: $EMAIL"
    elif [[ "$SSL_MODE" == "custom" ]]; then
        # Custom certificate mode - need cert files
        if [[ -z "$SSL_CERT" || ! -f "$SSL_CERT" ]]; then
            log_error "SSL certificate file not found: $SSL_CERT"
            exit 1
        fi
        if [[ -z "$SSL_KEY" || ! -f "$SSL_KEY" ]]; then
            log_error "SSL key file not found: $SSL_KEY"
            exit 1
        fi
        log_info "  SSL Mode: Custom certificate"
        log_info "  SSL Cert: $SSL_CERT"
        log_info "  SSL Key: $SSL_KEY"
    else
        log_error "SSL mode not configured"
        exit 1
    fi

    log_info "Validation passed!"
    return 0
}

get_server_ip() {
    SERVER_IP=$(hostname -I | awk '{print $1}')
    log_info "Server IP: $SERVER_IP"
}

# ============================================
# SSL CERTIFICATE SETUP
# ============================================

install_certbot() {
    log_step "Installing Certbot for Let's Encrypt"

    if command -v certbot &>/dev/null; then
        log_info "Certbot already installed: $(certbot --version 2>&1 | head -1)"
        return 0
    fi

    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq certbot

    log_info "Certbot installed successfully"
}

generate_letsencrypt_cert() {
    log_step "Generating Let's Encrypt SSL Certificate"

    # Certificate paths
    SSL_CERT="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
    SSL_KEY="/etc/letsencrypt/live/$DOMAIN/privkey.pem"

    # Check if certificate already exists and is valid
    if [[ -f "$SSL_CERT" && -f "$SSL_KEY" ]]; then
        log_info "Existing Let's Encrypt certificate found"

        # Check if certificate is still valid (not expiring in next 7 days)
        if openssl x509 -checkend 604800 -noout -in "$SSL_CERT" 2>/dev/null; then
            log_info "Certificate is still valid, using existing certificate"
            return 0
        else
            log_warn "Certificate is expiring soon, renewing..."
        fi
    fi

    log_info "Requesting certificate for: $DOMAIN"
    log_info "Email: $EMAIL"
    echo ""
    echo -e "${YELLOW}IMPORTANT: Make sure DNS for $DOMAIN points to this server!${NC}"
    echo -e "${YELLOW}The certificate request will fail if DNS is not configured.${NC}"
    echo ""

    # Stop any service using port 80 temporarily
    local port80_pid=$(lsof -ti:80 2>/dev/null || true)
    if [[ -n "$port80_pid" ]]; then
        log_warn "Port 80 is in use. Attempting to proceed with webroot method..."
    fi

    # Try standalone mode first (works if port 80 is free)
    if certbot certonly \
        --standalone \
        --non-interactive \
        --agree-tos \
        --email "$EMAIL" \
        --domain "$DOMAIN" \
        --preferred-challenges http \
        2>/dev/null; then
        log_info "Certificate generated successfully!"
    else
        log_error "Failed to generate Let's Encrypt certificate"
        echo ""
        echo -e "${RED}Possible causes:${NC}"
        echo "  1. DNS for $DOMAIN does not point to this server"
        echo "  2. Port 80 is blocked by firewall"
        echo "  3. Rate limit exceeded (try again later)"
        echo ""
        echo "You can:"
        echo "  - Fix the issue and re-run the installer"
        echo "  - Use option 2 (custom certificate) instead"
        exit 1
    fi

    log_info "SSL Certificate: $SSL_CERT"
    log_info "SSL Private Key: $SSL_KEY"
}

setup_certificate_renewal() {
    log_info "Setting up automatic certificate renewal..."

    # Create renewal hook to reload Istio
    mkdir -p /etc/letsencrypt/renewal-hooks/deploy
    cat > /etc/letsencrypt/renewal-hooks/deploy/reload-istio.sh <<'EOF'
#!/bin/bash
# Reload Istio TLS secret after certificate renewal
DOMAIN=$(basename $(dirname $RENEWED_LINEAGE))
kubectl create secret tls istio-ingressgateway-certs \
    --cert="$RENEWED_LINEAGE/fullchain.pem" \
    --key="$RENEWED_LINEAGE/privkey.pem" \
    -n istio-system \
    --dry-run=client -o yaml | kubectl apply -f -
echo "Istio TLS secret updated for $DOMAIN"
EOF
    chmod +x /etc/letsencrypt/renewal-hooks/deploy/reload-istio.sh

    # Enable certbot timer for automatic renewal
    systemctl enable certbot.timer 2>/dev/null || true
    systemctl start certbot.timer 2>/dev/null || true

    log_info "Automatic certificate renewal configured"
}

# ============================================
# INFRASTRUCTURE
# ============================================

install_k3s() {
    log_step "Installing K3s Kubernetes"

    if command -v k3s &>/dev/null && kubectl cluster-info &>/dev/null 2>&1; then
        log_info "K3s already installed and running"
        return 0
    fi

    curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="$K3S_VERSION" sh -s - \
        --write-kubeconfig-mode 644 \
        --disable traefik \
        --disable servicelb

    sleep 10
    mkdir -p ~/.kube
    cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
    chmod 600 ~/.kube/config
    export KUBECONFIG=~/.kube/config

    kubectl wait --for=condition=ready node --all --timeout=120s
    log_info "K3s installed successfully"
}

install_helm() {
    log_step "Installing Helm"

    if command -v helm &>/dev/null; then
        log_info "Helm already installed"
        return 0
    fi

    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
    log_info "Helm installed successfully"
}

install_istio() {
    log_step "Installing Istio Service Mesh"

    if kubectl get namespace istio-system &>/dev/null 2>&1; then
        if kubectl get pods -n istio-system -l app=istiod --no-headers 2>/dev/null | grep -q Running; then
            log_info "Istio already running"
            return 0
        fi
    fi

    if ! command -v istioctl &>/dev/null; then
        pushd /tmp > /dev/null
        curl -L https://istio.io/downloadIstio | ISTIO_VERSION=$ISTIO_VERSION sh -
        mv istio-$ISTIO_VERSION/bin/istioctl /usr/local/bin/
        rm -rf istio-$ISTIO_VERSION
        popd > /dev/null
    fi

    istioctl install --set profile=demo -y
    kubectl wait --for=condition=ready pod -l app=istiod -n istio-system --timeout=300s
    log_info "Istio installed successfully"
}

# ============================================
# DATABASES ON HOST
# ============================================

install_mariadb() {
    log_step "Installing MariaDB"

    if systemctl is-active --quiet mariadb 2>/dev/null; then
        log_info "MariaDB already running"
        # Update user password if needed
        mysql -u root <<EOF || true
ALTER USER 'stackbill'@'%' IDENTIFIED BY '${MYSQL_PASSWORD}';
ALTER USER 'stackbill'@'localhost' IDENTIFIED BY '${MYSQL_PASSWORD}';
GRANT ALL PRIVILEGES ON *.* TO 'stackbill'@'%' WITH GRANT OPTION;
GRANT ALL PRIVILEGES ON *.* TO 'stackbill'@'localhost' WITH GRANT OPTION;
FLUSH PRIVILEGES;
EOF
        return 0
    fi

    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq mariadb-server mariadb-client

    systemctl start mariadb
    systemctl enable mariadb

    for i in {1..30}; do
        mysqladmin ping -h localhost --silent 2>/dev/null && break
        sleep 2
    done

    # Configure MariaDB for StackBill
    cat > /etc/mysql/mariadb.conf.d/99-stackbill.cnf <<'MARIACONF'
[mysqld]
bind-address = 0.0.0.0
sql_mode = NO_ENGINE_SUBSTITUTION,STRICT_TRANS_TABLES
wait_timeout = 28800
interactive_timeout = 230400
connect_timeout = 36000
max_connections = 1000
max_connect_errors = 100000
skip-host-cache
skip-name-resolve
log_bin_trust_function_creators = 1
MARIACONF

    systemctl restart mariadb

    for i in {1..30}; do
        mysqladmin ping -h localhost --silent 2>/dev/null && break
        sleep 2
    done

    # Create databases and users
    mysql -u root <<EOF
CREATE DATABASE IF NOT EXISTS stackbill;
CREATE DATABASE IF NOT EXISTS configuration;
CREATE USER IF NOT EXISTS 'stackbill'@'%' IDENTIFIED BY '${MYSQL_PASSWORD}';
CREATE USER IF NOT EXISTS 'stackbill'@'localhost' IDENTIFIED BY '${MYSQL_PASSWORD}';
GRANT ALL PRIVILEGES ON *.* TO 'stackbill'@'%' WITH GRANT OPTION;
GRANT ALL PRIVILEGES ON *.* TO 'stackbill'@'localhost' WITH GRANT OPTION;
SET GLOBAL log_bin_trust_function_creators = 1;
SET GLOBAL max_connect_errors = 100000;
FLUSH PRIVILEGES;
EOF

    log_info "MariaDB installed with StackBill configuration - User: stackbill"
}

install_mongodb() {
    log_step "Installing MongoDB"

    if systemctl is-active --quiet mongod 2>/dev/null; then
        log_info "MongoDB already running"
        return 0
    fi

    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y -qq gnupg curl

    curl -fsSL https://www.mongodb.org/static/pgp/server-7.0.asc | gpg --dearmor -o /usr/share/keyrings/mongodb-server-7.0.gpg 2>/dev/null || true
    echo "deb [ arch=amd64,arm64 signed-by=/usr/share/keyrings/mongodb-server-7.0.gpg ] https://repo.mongodb.org/apt/ubuntu jammy/mongodb-org/7.0 multiverse" | tee /etc/apt/sources.list.d/mongodb-org-7.0.list

    apt-get update -qq
    apt-get install -y -qq mongodb-org

    # Create directories
    mkdir -p /var/lib/mongodb
    mkdir -p /var/log/mongodb
    chown -R mongodb:mongodb /var/lib/mongodb
    chown -R mongodb:mongodb /var/log/mongodb

    # Generate encryption keyFile
    log_info "Generating MongoDB encryption keyFile..."
    openssl rand -base64 32 | head -c 64 > /var/lib/mongodb/encryption
    chown mongodb:mongodb /var/lib/mongodb/encryption
    chmod 600 /var/lib/mongodb/encryption

    # Create MongoDB configuration
    cat > /etc/mongod.conf <<'EOF'
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
EOF

    systemctl start mongod
    systemctl enable mongod

    for i in {1..30}; do
        mongosh --quiet --eval "db.runCommand('ping').ok" 2>/dev/null && break
        sleep 2
    done

    # Create admin user
    mongosh --quiet <<EOF || true
use admin
db.createUser({
  user: "stackbill",
  pwd: "${MONGODB_PASSWORD}",
  roles: [
    { role: "root", db: "admin" },
    { role: "readWriteAnyDatabase", db: "admin" }
  ]
})
EOF

    # Enable security settings
    cat >> /etc/mongod.conf <<'EOF'

# Security settings
security:
  authorization: enabled
EOF

    systemctl restart mongod

    for i in {1..30}; do
        mongosh --quiet -u stackbill -p "${MONGODB_PASSWORD}" --authenticationDatabase admin --eval "db.runCommand('ping').ok" 2>/dev/null && break
        sleep 2
    done

    log_info "MongoDB installed with security enabled - User: stackbill"
}

install_rabbitmq() {
    log_step "Installing RabbitMQ"

    if systemctl is-active --quiet rabbitmq-server 2>/dev/null; then
        log_info "RabbitMQ already running"
        rabbitmqctl add_user stackbill "${RABBITMQ_PASSWORD}" 2>/dev/null || \
            rabbitmqctl change_password stackbill "${RABBITMQ_PASSWORD}" 2>/dev/null || true
        rabbitmqctl set_user_tags stackbill administrator 2>/dev/null || true
        rabbitmqctl set_permissions -p / stackbill ".*" ".*" ".*" 2>/dev/null || true
        return 0
    fi

    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq rabbitmq-server

    systemctl start rabbitmq-server
    systemctl enable rabbitmq-server

    for i in {1..30}; do
        rabbitmqctl status &>/dev/null && break
        sleep 2
    done

    rabbitmq-plugins enable rabbitmq_management
    rabbitmqctl add_user stackbill "${RABBITMQ_PASSWORD}" 2>/dev/null || \
        rabbitmqctl change_password stackbill "${RABBITMQ_PASSWORD}"
    rabbitmqctl set_user_tags stackbill administrator
    rabbitmqctl set_permissions -p / stackbill ".*" ".*" ".*"
    rabbitmqctl delete_user guest 2>/dev/null || true

    log_info "RabbitMQ installed - User: stackbill"
}

setup_nfs() {
    log_step "Setting up NFS Storage"

    apt-get install -y -qq nfs-kernel-server nfs-common
    mkdir -p /data/stackbill
    chmod 777 /data/stackbill

    if ! grep -q "/data/stackbill" /etc/exports 2>/dev/null; then
        echo "/data/stackbill *(rw,sync,no_subtree_check,no_root_squash)" >> /etc/exports
    fi

    exportfs -a
    systemctl restart nfs-kernel-server
    log_info "NFS configured at /data/stackbill"
}

# ============================================
# CLOUDSTACK SIMULATOR
# ============================================

install_podman() {
    log_step "Installing Podman"

    if command -v podman &>/dev/null; then
        log_info "Podman already installed: $(podman --version)"
    else
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq
        apt-get install -y -qq podman
    fi

    # Configure Podman to allow pulling from Docker Hub (new TOML format)
    mkdir -p /etc/containers
    cat > /etc/containers/registries.conf <<'EOF'
unqualified-search-registries = ["docker.io"]

[[registry]]
location = "docker.io"
EOF

    log_info "Podman installed and configured for Docker Hub"
}

install_cloudstack_simulator() {
    log_step "Deploying CloudStack Simulator"

    # Check if simulator is already running
    if podman ps --filter "name=cloudstack-simulator" --format "{{.Names}}" 2>/dev/null | grep -q "cloudstack-simulator"; then
        log_info "CloudStack Simulator is already running"
        CLOUDSTACK_URL="http://$SERVER_IP:8080/client"
        return 0
    fi

    # Remove any existing stopped container
    podman rm -f cloudstack-simulator 2>/dev/null || true

    log_info "Pulling CloudStack Simulator image..."
    podman pull docker.io/apache/cloudstack-simulator

    log_info "Starting CloudStack Simulator container..."
    podman run --name cloudstack-simulator \
        -p 8080:5050 \
        -d \
        docker.io/apache/cloudstack-simulator

    # Wait for CloudStack management server to be ready BEFORE deploying data center
    log_info "Waiting for CloudStack Management Server to start (this may take 2-3 minutes)..."
    local max_wait=300
    local waited=0
    while [[ $waited -lt $max_wait ]]; do
        # Check if CloudStack API is responding
        if curl -s "http://localhost:8080/client/api?command=listCapabilities&response=json" 2>/dev/null | grep -q "capability"; then
            log_info "CloudStack Management Server is ready!"
            break
        fi
        sleep 10
        waited=$((waited + 10))
        log_info "  Waiting for CloudStack to start... ($waited seconds)"
    done

    if [[ $waited -ge $max_wait ]]; then
        log_error "CloudStack failed to start within $max_wait seconds"
        log_info "Check logs: podman logs cloudstack-simulator"
        return 1
    fi

    # Additional wait to ensure all services are fully initialized
    log_info "Giving CloudStack 30 more seconds to fully initialize..."
    sleep 30

    log_info "Deploying CloudStack Data Center (this may take several minutes)..."
    # Run deployDataCenter with retry logic
    local deploy_attempts=0
    local max_deploy_attempts=3
    while [[ $deploy_attempts -lt $max_deploy_attempts ]]; do
        deploy_attempts=$((deploy_attempts + 1))
        log_info "Deploy attempt $deploy_attempts of $max_deploy_attempts..."

        if podman exec cloudstack-simulator \
            python /root/tools/marvin/marvin/deployDataCenter.py \
            -i /root/setup/dev/advanced.cfg 2>&1; then
            log_info "Data Center deployed successfully!"
            break
        else
            if [[ $deploy_attempts -lt $max_deploy_attempts ]]; then
                log_warn "Deploy failed, waiting 30 seconds before retry..."
                sleep 30
            else
                log_warn "Data Center deployment failed after $max_deploy_attempts attempts"
                log_info "CloudStack Simulator is running but may need manual configuration"
                log_info "Access CloudStack UI at: http://$SERVER_IP:8080/client"
            fi
        fi
    done

    # Verify zones are available
    log_info "Verifying CloudStack zones..."
    waited=0
    while [[ $waited -lt 120 ]]; do
        if curl -s "http://localhost:8080/client/api?command=listZones&response=json" 2>/dev/null | grep -q "zone"; then
            log_info "CloudStack zones are available!"
            break
        fi
        sleep 10
        waited=$((waited + 10))
    done

    if [[ $waited -ge $max_wait ]]; then
        log_warn "CloudStack may not be fully ready. Please check manually."
    fi

    CLOUDSTACK_URL="http://$SERVER_IP:8080/client"
    log_info "CloudStack Simulator deployed at: $CLOUDSTACK_URL"
}

create_cloudstack_user() {
    log_step "Creating CloudStack Admin User for StackBill"

    # CloudStack default credentials
    local CS_HOST="http://localhost:8080/client/api"
    local CS_ADMIN_USER="admin"
    local CS_ADMIN_PASS="password"

    # Generate credentials for new user
    CLOUDSTACK_ADMIN_USER="sb-admin@${DOMAIN}"
    CLOUDSTACK_ADMIN_PASSWORD=$(generate_password)

    log_info "Creating user: $CLOUDSTACK_ADMIN_USER"

    # Login and get session key
    local login_response=$(curl -s -c /tmp/cs_cookies.txt \
        "${CS_HOST}?command=login&username=${CS_ADMIN_USER}&password=${CS_ADMIN_PASS}&response=json")

    local sessionkey=$(echo "$login_response" | grep -o '"sessionkey":"[^"]*"' | cut -d'"' -f4)

    if [[ -z "$sessionkey" ]]; then
        log_error "Failed to login to CloudStack. Please create user manually."
        log_info "Default CloudStack credentials: admin / password"
        return 1
    fi

    # Get the ROOT domain ID
    local domain_response=$(curl -s -b /tmp/cs_cookies.txt \
        "${CS_HOST}?command=listDomains&name=ROOT&response=json&sessionkey=${sessionkey}")
    local domain_id=$(echo "$domain_response" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)

    if [[ -z "$domain_id" ]]; then
        log_warn "Could not find ROOT domain, using default"
        domain_id="1"
    fi

    # Get the admin account ID
    local account_response=$(curl -s -b /tmp/cs_cookies.txt \
        "${CS_HOST}?command=listAccounts&name=admin&domainid=${domain_id}&response=json&sessionkey=${sessionkey}")
    local account_id=$(echo "$account_response" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)

    # URL encode the username and email
    local encoded_username=$(echo -n "$CLOUDSTACK_ADMIN_USER" | python3 -c "import sys, urllib.parse; print(urllib.parse.quote(sys.stdin.read()))")
    local encoded_email=$(echo -n "$EMAIL" | python3 -c "import sys, urllib.parse; print(urllib.parse.quote(sys.stdin.read()))")
    local encoded_password=$(echo -n "$CLOUDSTACK_ADMIN_PASSWORD" | python3 -c "import sys, urllib.parse; print(urllib.parse.quote(sys.stdin.read()))")

    # Create user
    log_info "Creating user in CloudStack..."
    local create_response=$(curl -s -b /tmp/cs_cookies.txt \
        "${CS_HOST}?command=createUser&username=${encoded_username}&password=${encoded_password}&firstname=StackBill&lastname=Admin&email=${encoded_email}&account=admin&domainid=${domain_id}&response=json&sessionkey=${sessionkey}")

    local user_id=$(echo "$create_response" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)

    if [[ -z "$user_id" ]]; then
        # User might already exist, try to find it
        log_warn "User creation response: $create_response"
        local users_response=$(curl -s -b /tmp/cs_cookies.txt \
            "${CS_HOST}?command=listUsers&username=${encoded_username}&response=json&sessionkey=${sessionkey}")
        user_id=$(echo "$users_response" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
    fi

    if [[ -z "$user_id" ]]; then
        log_error "Failed to create or find user. Please create manually."
        rm -f /tmp/cs_cookies.txt
        return 1
    fi

    log_info "User ID: $user_id"

    # Enable user (if not already enabled)
    log_info "Enabling user..."
    curl -s -b /tmp/cs_cookies.txt \
        "${CS_HOST}?command=enableUser&id=${user_id}&response=json&sessionkey=${sessionkey}" > /dev/null

    # Register user keys (API key and secret key)
    log_info "Registering API keys..."
    local keys_response=$(curl -s -b /tmp/cs_cookies.txt \
        "${CS_HOST}?command=registerUserKeys&id=${user_id}&response=json&sessionkey=${sessionkey}")

    CLOUDSTACK_API_KEY=$(echo "$keys_response" | grep -o '"apikey":"[^"]*"' | cut -d'"' -f4)
    CLOUDSTACK_SECRET_KEY=$(echo "$keys_response" | grep -o '"secretkey":"[^"]*"' | cut -d'"' -f4)

    if [[ -z "$CLOUDSTACK_API_KEY" || -z "$CLOUDSTACK_SECRET_KEY" ]]; then
        log_warn "Could not retrieve API keys. Keys response: $keys_response"
        log_info "You may need to generate keys manually from CloudStack UI"
    else
        log_info "API keys generated successfully!"
    fi

    # Cleanup
    rm -f /tmp/cs_cookies.txt

    log_info "CloudStack user '$CLOUDSTACK_ADMIN_USER' created and configured"
}

# ============================================
# DEPLOY STACKBILL DIRECTLY FROM ECR
# ============================================

setup_namespace() {
    log_step "Setting up Kubernetes Namespace"

    if ! kubectl get namespace $STACKBILL_NAMESPACE &>/dev/null; then
        kubectl create namespace $STACKBILL_NAMESPACE
    fi
    kubectl label namespace $STACKBILL_NAMESPACE istio-injection=enabled --overwrite

    log_info "Namespace $STACKBILL_NAMESPACE ready"
}

setup_ecr_credentials() {
    log_step "Setting up AWS ECR Credentials"

    # Delete existing secret if present
    kubectl delete secret awscred -n $STACKBILL_NAMESPACE 2>/dev/null || true

    # Create docker-registry secret for AWS ECR
    kubectl create secret docker-registry awscred \
        --docker-server="$ECR_REGISTRY" \
        --docker-username=AWS \
        --docker-password="$AWS_ECR_TOKEN" \
        -n $STACKBILL_NAMESPACE

    log_info "ECR credentials secret 'awscred' created"
}

setup_tls_secret() {
    log_step "Setting up TLS Secret"

    kubectl create secret tls istio-ingressgateway-certs \
        --cert="$SSL_CERT" \
        --key="$SSL_KEY" \
        -n istio-system \
        --dry-run=client -o yaml | kubectl apply -f -

    log_info "TLS secret created in istio-system"
}

deploy_stackbill() {
    log_step "Deploying StackBill from ECR"

    log_info "Pulling chart from: $STACKBILL_CHART"

    # Install StackBill directly from ECR
    helm upgrade --install stackbill "$STACKBILL_CHART" \
        --namespace $STACKBILL_NAMESPACE \
        --set global.domain="$DOMAIN" \
        --set global.nfs.server="$SERVER_IP" \
        --set global.nfs.path="/data/stackbill" \
        --set global.mysql.ip="$SERVER_IP" \
        --set global.mysql.username="stackbill" \
        --set global.mysql.password="$MYSQL_PASSWORD" \
        --set global.mongo.ip="$SERVER_IP" \
        --set global.mongo.username="stackbill" \
        --set global.mongo.password="$MONGODB_PASSWORD" \
        --set global.rabbitmq.ip="$SERVER_IP" \
        --set global.rabbitmq.username="stackbill" \
        --set global.rabbitmq.password="$RABBITMQ_PASSWORD" \
        --timeout 600s \
        --wait

    log_info "StackBill deployed successfully!"
}

setup_istio_gateway() {
    log_step "Setting up Istio Gateway"

    # Create Gateway for HTTPS
    kubectl apply -f - <<EOF
apiVersion: networking.istio.io/v1beta1
kind: Gateway
metadata:
  name: stackbill-gateway
  namespace: $STACKBILL_NAMESPACE
spec:
  selector:
    istio: ingressgateway
  servers:
  - port:
      number: 443
      name: https
      protocol: HTTPS
    tls:
      mode: SIMPLE
      credentialName: istio-ingressgateway-certs
    hosts:
    - "$DOMAIN"
  - port:
      number: 80
      name: http
      protocol: HTTP
    tls:
      httpsRedirect: true
    hosts:
    - "$DOMAIN"
EOF

    # Patch Istio ingress gateway to use NodePort
    kubectl patch svc istio-ingressgateway -n istio-system --type='json' -p='[
        {"op": "replace", "path": "/spec/type", "value": "NodePort"},
        {"op": "replace", "path": "/spec/ports/0/nodePort", "value": 31080},
        {"op": "replace", "path": "/spec/ports/1/nodePort", "value": 31443}
    ]' 2>/dev/null || log_warn "Could not patch ingress gateway ports"

    log_info "Istio Gateway configured"
}

wait_for_pods() {
    log_step "Waiting for StackBill Pods"

    log_info "Waiting for pods to be ready (this may take several minutes)..."

    # Wait up to 10 minutes for pods
    local timeout=600
    local elapsed=0
    local interval=10

    while [[ $elapsed -lt $timeout ]]; do
        local ready=$(kubectl get pods -n $STACKBILL_NAMESPACE --no-headers 2>/dev/null | grep -c "Running" || echo "0")
        local total=$(kubectl get pods -n $STACKBILL_NAMESPACE --no-headers 2>/dev/null | wc -l || echo "0")

        log_info "  Pods ready: $ready / $total"

        if [[ $total -gt 0 && $ready -eq $total ]]; then
            log_info "All pods are running!"
            break
        fi

        sleep $interval
        elapsed=$((elapsed + interval))
    done

    echo ""
    kubectl get pods -n $STACKBILL_NAMESPACE
}

# ============================================
# SAVE & SUMMARY
# ============================================

save_credentials() {
    cat > "$CREDENTIALS_FILE" <<EOF
================================================================================
STACKBILL POC CREDENTIALS
Generated: $(date)
================================================================================

PORTAL URL: https://$DOMAIN

SERVER IP: $SERVER_IP

MYSQL:
  Host: $SERVER_IP
  Port: 3306
  Database: stackbill
  Username: stackbill
  Password: $MYSQL_PASSWORD

MONGODB:
  Host: $SERVER_IP
  Port: 27017
  Database: admin
  Username: stackbill
  Password: $MONGODB_PASSWORD

RABBITMQ:
  Host: $SERVER_IP
  Port: 5672
  Username: stackbill
  Password: $RABBITMQ_PASSWORD
  Management: http://$SERVER_IP:15672

NFS:
  Server: $SERVER_IP
  Path: /data/stackbill

EOF

    # Add CloudStack section based on mode
    if [[ "$CLOUDSTACK_MODE" == "simulator" ]]; then
        cat >> "$CREDENTIALS_FILE" <<EOF
CLOUDSTACK SIMULATOR:
  URL: $CLOUDSTACK_URL
  Default Admin: admin / password

  StackBill User:
    Username: $CLOUDSTACK_ADMIN_USER
    Password: $CLOUDSTACK_ADMIN_PASSWORD
    API Key: ${CLOUDSTACK_API_KEY:-"(generate from CloudStack UI)"}
    Secret Key: ${CLOUDSTACK_SECRET_KEY:-"(generate from CloudStack UI)"}

EOF
    fi

    cat >> "$CREDENTIALS_FILE" <<EOF
================================================================================
EOF
    chmod 600 "$CREDENTIALS_FILE"
    log_info "Credentials saved to: $CREDENTIALS_FILE"
}

print_summary() {
    echo ""
    echo -e "${GREEN}════════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}              STACKBILL INSTALLATION COMPLETE!                  ${NC}"
    echo -e "${GREEN}════════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${CYAN}ACCESS STACKBILL:${NC}"
    echo "  Portal: https://$DOMAIN"
    echo "  (Make sure DNS points $DOMAIN to $SERVER_IP)"
    echo ""
    # Get actual NodePorts from istio-ingressgateway
    local HTTPS_NODEPORT=$(kubectl get svc istio-ingressgateway -n istio-system -o jsonpath='{.spec.ports[?(@.port==443)].nodePort}' 2>/dev/null || echo "N/A")
    local HTTP_NODEPORT=$(kubectl get svc istio-ingressgateway -n istio-system -o jsonpath='{.spec.ports[?(@.port==80)].nodePort}' 2>/dev/null || echo "N/A")

    echo -e "${CYAN}DIRECT ACCESS (if DNS not configured):${NC}"
    echo "  HTTP:  http://$SERVER_IP:$HTTP_NODEPORT"
    echo "  HTTPS: https://$SERVER_IP:$HTTPS_NODEPORT"
    echo ""
    echo -e "${CYAN}FIREWALL RULES:${NC}"
    echo "  Open the following ports in your firewall/security group:"
    echo "  - TCP $HTTP_NODEPORT  (HTTP)"
    echo "  - TCP $HTTPS_NODEPORT  (HTTPS)"
    if [[ "$CLOUDSTACK_MODE" == "simulator" ]]; then
        echo "  - TCP 8080  (CloudStack Simulator)"
    fi
    echo ""
    echo -e "${CYAN}SERVICE CREDENTIALS:${NC}"
    echo "  MySQL:    stackbill / $MYSQL_PASSWORD"
    echo "  MongoDB:  stackbill / $MONGODB_PASSWORD"
    echo "  RabbitMQ: stackbill / $RABBITMQ_PASSWORD"
    echo ""

    # CloudStack section
    if [[ "$CLOUDSTACK_MODE" == "simulator" ]]; then
        echo -e "${CYAN}CLOUDSTACK SIMULATOR:${NC}"
        echo "  URL: $CLOUDSTACK_URL"
        echo "  Default Admin: admin / password"
        echo ""
        echo -e "${CYAN}STACKBILL CLOUDSTACK USER:${NC}"
        echo "  Username: $CLOUDSTACK_ADMIN_USER"
        echo "  Password: $CLOUDSTACK_ADMIN_PASSWORD"
        if [[ -n "$CLOUDSTACK_API_KEY" ]]; then
            echo "  API Key: $CLOUDSTACK_API_KEY"
            echo "  Secret Key: $CLOUDSTACK_SECRET_KEY"
        else
            echo "  API Keys: Generate from CloudStack UI"
        fi
        echo ""
    fi

    echo -e "${CYAN}NEXT STEPS - CONFIGURE STACKBILL:${NC}"
    if [[ "$CLOUDSTACK_MODE" == "existing" ]]; then
        echo "  1. Integrate CloudStack with StackBill:"
        echo "     https://docs.stackbill.com/docs/deployment/integrating-stackbill-with-cloudstack"
        echo ""
    else
        echo "  1. CloudStack Simulator is ready at: $CLOUDSTACK_URL"
        echo "     Use the StackBill user credentials above to integrate."
        echo ""
    fi
    echo "  2. Complete StackBill configuration:"
    echo "     https://docs.stackbill.com/docs/deployment/configuring-stackbill"
    echo ""

    echo -e "${YELLOW}Credentials saved to: /root/stackbill-credentials.txt${NC}"
    echo ""
    echo -e "${CYAN}USEFUL COMMANDS:${NC}"
    echo "  kubectl get pods -n $STACKBILL_NAMESPACE"
    echo "  kubectl logs -f <pod-name> -n $STACKBILL_NAMESPACE"
    echo "  cat /root/stackbill-credentials.txt"
    if [[ "$CLOUDSTACK_MODE" == "simulator" ]]; then
        echo "  podman logs cloudstack-simulator"
    fi
    echo ""
}

# ============================================
# MAIN
# ============================================

main() {
    print_banner

    # Parse command-line arguments first
    parse_args "$@"

    # Run interactive setup for any missing configuration
    run_interactive_setup

    # Show configuration summary before proceeding
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  Configuration Summary${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo "  Domain:       $DOMAIN"
    echo "  SSL Mode:     $SSL_MODE"
    if [[ "$SSL_MODE" == "letsencrypt" ]]; then
        echo "  Email:        $EMAIL"
    else
        echo "  SSL Cert:     $SSL_CERT"
        echo "  SSL Key:      $SSL_KEY"
    fi
    echo "  CloudStack:   $CLOUDSTACK_MODE"
    echo "  ECR Token:    provided (${#AWS_ECR_TOKEN} chars)"
    echo ""
    echo -n "Proceed with installation? [Y/n]: "
    read confirm < /dev/tty
    if [[ "$confirm" =~ ^[Nn]$ ]]; then
        log_info "Installation cancelled."
        exit 0
    fi

    log_info "Starting fully automated installation..."

    # Validate inputs
    validate_inputs
    get_server_ip

    # Load existing or generate new passwords
    load_or_generate_passwords

    # Infrastructure
    if [[ "$SKIP_INFRA" != "true" ]]; then
        install_k3s
        install_helm
        install_istio
    fi

    # Generate Let's Encrypt certificate if selected
    if [[ "$SSL_MODE" == "letsencrypt" ]]; then
        install_certbot
        generate_letsencrypt_cert
        setup_certificate_renewal
    fi

    # Databases on host
    if [[ "$SKIP_DB" != "true" ]]; then
        install_mariadb
        install_mongodb
        install_rabbitmq
        setup_nfs
    fi

    # Deploy StackBill directly
    setup_namespace
    setup_ecr_credentials
    setup_tls_secret
    deploy_stackbill
    setup_istio_gateway
    wait_for_pods

    # CloudStack Simulator (if selected)
    if [[ "$CLOUDSTACK_MODE" == "simulator" ]]; then
        install_podman
        install_cloudstack_simulator
        create_cloudstack_user
    fi

    # Save and summarize
    save_credentials
    print_summary
}

main "$@"
