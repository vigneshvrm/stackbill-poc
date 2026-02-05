#!/bin/bash
# ============================================
# STACKBILL POC INSTALLER - FULLY AUTOMATED
# ============================================
# Installs StackBill directly from AWS ECR
# Interactive mode: prompts for domain and SSL configuration
#
# Usage:
#   sudo ./install-stackbill-poc.sh
#
# One-liner:
#   curl -sfL https://raw.githubusercontent.com/vigneshvrm/stackbill-poc/main/scripts/install-stackbill-poc.sh | sudo bash
#
# ECR authentication is handled automatically via secure token fetch.
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

# Encrypted ECR Credentials (AES-256-CBC, PBKDF2 with 100k iterations)
# These are pull-only credentials - can only read from ECR, not write/delete
_EK1="U2FsdGVkX1/SDUAMN8jY/1UCaCuZKwIVDZME0Y4/VS8qaSNiq/e/fl1fSz9O9R9h"
_EK2="U2FsdGVkX1/Y/wF1gsFA/bA2iKXpJ/inJOCKBogLL1JyEGU4OCDMfpyfnZJCixegDSx6SzxAiPs+IV+pYRU2Dg=="

# User inputs
DOMAIN=""
SSL_CERT=""
SSL_KEY=""
EMAIL=""
SSL_MODE=""  # "letsencrypt" or "custom"

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
    echo "║    • MySQL, MongoDB, RabbitMQ databases                       ║"
    echo "║    • StackBill Cloud Management Platform                      ║"
    echo "║                                                               ║"
    echo "║  SSL Options:                                                 ║"
    echo "║    • Let's Encrypt (free, automatic)                          ║"
    echo "║    • Custom certificate (bring your own)                      ║"
    echo "║                                                               ║"
    echo "║  ECR authentication is handled automatically                  ║"
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
    echo "  sudo $0                       # Interactive mode (recommended)"
    echo "  sudo $0 [OPTIONS]             # Non-interactive mode"
    echo ""
    echo "Interactive Mode:"
    echo "  Run without arguments to be guided through the setup:"
    echo "    1. Enter your domain name"
    echo "    2. Choose SSL option:"
    echo "       - Let's Encrypt (free, automatic)"
    echo "       - Custom certificate (provide your own files)"
    echo ""
    echo "  ECR authentication is handled automatically - no token needed!"
    echo ""
    echo "Non-Interactive Options:"
    echo "  --domain       Domain name for StackBill (e.g., stackbill.example.com)"
    echo "  --ssl-cert     Path to SSL certificate file (fullchain.pem)"
    echo "  --ssl-key      Path to SSL private key file (privatekey.pem)"
    echo "  --letsencrypt  Use Let's Encrypt for SSL (requires --email)"
    echo "  --email        Email for Let's Encrypt notifications"
    echo "  --skip-infra   Skip K3s/Istio installation (use existing cluster)"
    echo "  --skip-db      Skip database installation (use existing databases)"
    echo "  -h, --help     Show this help message"
    echo ""
    echo "Examples:"
    echo "  # Interactive (recommended)"
    echo "  sudo $0"
    echo ""
    echo "  # With custom certificate"
    echo "  sudo $0 --domain example.com --ssl-cert /path/to/cert.pem --ssl-key /path/to/key.pem"
    echo ""
    echo "  # With Let's Encrypt"
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
# ECR TOKEN FETCH (AWS CLI Method)
# ============================================

install_aws_cli() {
    log_step "Installing AWS CLI"

    if command -v aws &>/dev/null; then
        log_info "AWS CLI already installed: $(aws --version 2>&1 | head -1)"
        return 0
    fi

    # Install unzip if not present
    if ! command -v unzip &>/dev/null; then
        log_info "Installing unzip..."
        apt-get update -qq
        apt-get install -y -qq unzip
    fi

    log_info "Downloading AWS CLI..."
    curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip

    log_info "Installing AWS CLI..."
    unzip -q /tmp/awscliv2.zip -d /tmp
    /tmp/aws/install --update

    # Cleanup
    rm -rf /tmp/aws /tmp/awscliv2.zip

    log_info "AWS CLI installed: $(aws --version 2>&1 | head -1)"
}

fetch_ecr_token() {
    log_step "Fetching ECR Authentication Token"

    # Install AWS CLI if needed
    install_aws_cli

    # Decrypt credentials
    local _p="sb-ecr-2024-poc-install"
    local _ak=$(echo "$_EK1" | openssl enc -aes-256-cbc -d -a -pbkdf2 -iter 100000 -pass pass:$_p 2>/dev/null)
    local _sk=$(echo "$_EK2" | openssl enc -aes-256-cbc -d -a -pbkdf2 -iter 100000 -pass pass:$_p 2>/dev/null)

    if [[ -z "$_ak" || -z "$_sk" ]]; then
        log_error "Failed to decrypt ECR credentials"
        exit 1
    fi

    log_info "Authenticating with AWS ECR..."

    # Set credentials temporarily for AWS CLI
    export AWS_ACCESS_KEY_ID="$_ak"
    export AWS_SECRET_ACCESS_KEY="$_sk"
    export AWS_DEFAULT_REGION="$ECR_REGION"

    # Fetch ECR token
    set +e
    AWS_ECR_TOKEN=$(aws ecr get-login-password --region "$ECR_REGION" 2>&1)
    local exit_code=$?
    set -e

    # Immediately clear credentials from environment
    unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION
    _ak=""
    _sk=""
    unset _ak _sk _p

    # Verify token was retrieved
    if [[ $exit_code -ne 0 ]] || [[ -z "$AWS_ECR_TOKEN" ]] || [[ "$AWS_ECR_TOKEN" == *"error"* ]] || [[ "$AWS_ECR_TOKEN" == *"Error"* ]]; then
        log_error "Failed to fetch ECR token (exit code: $exit_code)"
        log_error "Response: $AWS_ECR_TOKEN"
        exit 1
    fi

    log_info "ECR token fetched successfully (length: ${#AWS_ECR_TOKEN} characters)"
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

install_mysql() {
    log_step "Installing MySQL"

    if systemctl is-active --quiet mysql 2>/dev/null; then
        log_info "MySQL already running"
        # Update user with native password authentication
        mysql -u root <<EOF || true
ALTER USER 'stackbill'@'%' IDENTIFIED WITH mysql_native_password BY '${MYSQL_PASSWORD}';
ALTER USER 'stackbill'@'localhost' IDENTIFIED WITH mysql_native_password BY '${MYSQL_PASSWORD}';
GRANT ALL PRIVILEGES ON *.* TO 'stackbill'@'%' WITH GRANT OPTION;
GRANT ALL PRIVILEGES ON *.* TO 'stackbill'@'localhost' WITH GRANT OPTION;
FLUSH PRIVILEGES;
EOF
        return 0
    fi

    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq mysql-server mysql-client

    systemctl start mysql
    systemctl enable mysql

    for i in {1..30}; do
        mysqladmin ping -h localhost --silent 2>/dev/null && break
        sleep 2
    done

    # Configure MySQL for StackBill
    cat > /etc/mysql/mysql.conf.d/stackbill.cnf <<'MYSQLCONF'
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
MYSQLCONF

    systemctl restart mysql

    for i in {1..30}; do
        mysqladmin ping -h localhost --silent 2>/dev/null && break
        sleep 2
    done

    # Create databases and users with native password authentication
    mysql -u root <<EOF
CREATE DATABASE IF NOT EXISTS stackbill;
CREATE DATABASE IF NOT EXISTS configuration;
CREATE USER IF NOT EXISTS 'stackbill'@'%' IDENTIFIED WITH mysql_native_password BY '${MYSQL_PASSWORD}';
CREATE USER IF NOT EXISTS 'stackbill'@'localhost' IDENTIFIED WITH mysql_native_password BY '${MYSQL_PASSWORD}';
GRANT ALL PRIVILEGES ON *.* TO 'stackbill'@'%' WITH GRANT OPTION;
GRANT ALL PRIVILEGES ON *.* TO 'stackbill'@'localhost' WITH GRANT OPTION;
SET GLOBAL log_bin_trust_function_creators = 1;
SET GLOBAL max_connect_errors = 100000;
FLUSH PRIVILEGES;
EOF

    log_info "MySQL installed with StackBill configuration - User: stackbill"
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
    echo ""
    echo -e "${CYAN}SERVICE CREDENTIALS:${NC}"
    echo "  MySQL:    stackbill / $MYSQL_PASSWORD"
    echo "  MongoDB:  stackbill / $MONGODB_PASSWORD"
    echo "  RabbitMQ: stackbill / $RABBITMQ_PASSWORD"
    echo ""
    echo -e "${YELLOW}Credentials saved to: /root/stackbill-credentials.txt${NC}"
    echo ""
    echo -e "${CYAN}USEFUL COMMANDS:${NC}"
    echo "  kubectl get pods -n $STACKBILL_NAMESPACE"
    echo "  kubectl logs -f <pod-name> -n $STACKBILL_NAMESPACE"
    echo "  cat /root/stackbill-credentials.txt"
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
    echo "  Domain:     $DOMAIN"
    echo "  SSL Mode:   $SSL_MODE"
    if [[ "$SSL_MODE" == "letsencrypt" ]]; then
        echo "  Email:      $EMAIL"
    else
        echo "  SSL Cert:   $SSL_CERT"
        echo "  SSL Key:    $SSL_KEY"
    fi
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
        install_mysql
        install_mongodb
        install_rabbitmq
        setup_nfs
    fi

    # Fetch ECR token using secure container method
    fetch_ecr_token

    # Deploy StackBill directly
    setup_namespace
    setup_ecr_credentials
    setup_tls_secret
    deploy_stackbill
    setup_istio_gateway
    wait_for_pods

    # Save and summarize
    save_credentials
    print_summary
}

main "$@"
