@echo off
REM ===============================================================================
REM StackBill POC Installer (Windows)
REM
REM User provides ONLY: Domain + SSL certificate
REM Everything else is auto-provisioned
REM ===============================================================================

setlocal enabledelayedexpansion

set NAMESPACE=sb-system
set RELEASE_NAME=stackbill
set CHART_PATH=.
set TIMEOUT=900s

echo.
echo ===============================================================================
echo      StackBill POC Installer (Windows)
echo ===============================================================================
echo.
echo   This installer will automatically provision:
echo     - MySQL 8.0
echo     - MongoDB 7.0
echo     - RabbitMQ 3.13
echo     - NFS Storage
echo     - Deployment Controller
echo.
echo   You only need to provide:
echo     1. Domain name
echo     2. SSL certificate and private key
echo.
echo ===============================================================================
echo.

REM Parse arguments
:parse_args
if "%~1"=="" goto check_inputs
if /i "%~1"=="--domain" set DOMAIN=%~2& shift & shift & goto parse_args
if /i "%~1"=="--ssl-cert" set SSL_CERT=%~2& shift & shift & goto parse_args
if /i "%~1"=="--ssl-key" set SSL_KEY=%~2& shift & shift & goto parse_args
if /i "%~1"=="--ssl-ca" set SSL_CA=%~2& shift & shift & goto parse_args
if /i "%~1"=="-n" set NAMESPACE=%~2& shift & shift & goto parse_args
if /i "%~1"=="--namespace" set NAMESPACE=%~2& shift & shift & goto parse_args
if /i "%~1"=="-h" goto show_help
if /i "%~1"=="--help" goto show_help
shift
goto parse_args

:show_help
echo Usage: install-poc.bat [OPTIONS]
echo.
echo Required:
echo   --domain DOMAIN       Domain name (e.g., stackbill.example.com)
echo   --ssl-cert FILE       Path to SSL certificate file
echo   --ssl-key FILE        Path to SSL private key file
echo.
echo Optional:
echo   --ssl-ca FILE         Path to CA bundle file
echo   -n, --namespace NAME  Kubernetes namespace (default: sb-system)
echo   -h, --help            Show this help
echo.
echo Example:
echo   install-poc.bat --domain portal.example.com --ssl-cert cert.pem --ssl-key key.pem
exit /b 0

:check_inputs
if "%DOMAIN%"=="" (
    echo [ERROR] Domain name is required ^(--domain^)
    goto show_help
)
if "%SSL_CERT%"=="" (
    echo [ERROR] SSL certificate file is required ^(--ssl-cert^)
    goto show_help
)
if "%SSL_KEY%"=="" (
    echo [ERROR] SSL private key file is required ^(--ssl-key^)
    goto show_help
)
if not exist "%SSL_CERT%" (
    echo [ERROR] SSL certificate file not found: %SSL_CERT%
    exit /b 1
)
if not exist "%SSL_KEY%" (
    echo [ERROR] SSL private key file not found: %SSL_KEY%
    exit /b 1
)

:check_prereqs
echo [INFO] Checking prerequisites...

where kubectl >nul 2>nul
if %errorlevel% neq 0 (
    echo [ERROR] kubectl not found. Please install kubectl.
    exit /b 1
)
echo   [OK] kubectl found

where helm >nul 2>nul
if %errorlevel% neq 0 (
    echo [ERROR] helm not found. Please install helm.
    exit /b 1
)
echo   [OK] helm found

kubectl cluster-info >nul 2>nul
if %errorlevel% neq 0 (
    echo [ERROR] Cannot connect to Kubernetes cluster
    exit /b 1
)
echo   [OK] Kubernetes cluster accessible

:setup_namespace
echo.
echo [INFO] Setting up namespace: %NAMESPACE%
kubectl get namespace %NAMESPACE% >nul 2>nul
if %errorlevel% neq 0 (
    kubectl create namespace %NAMESPACE%
)
kubectl label namespace %NAMESPACE% istio-injection=enabled --overwrite 2>nul
echo   [OK] Namespace ready

:add_repos
echo.
echo [INFO] Adding Helm repositories...
helm repo add bitnami https://charts.bitnami.com/bitnami 2>nul
helm repo add nfs-provisioner https://kubernetes-sigs.github.io/nfs-subdir-external-provisioner 2>nul
helm repo update
echo   [OK] Repositories updated

:update_deps
echo.
echo [INFO] Updating chart dependencies...
helm dependency update %CHART_PATH%
echo   [OK] Dependencies updated

:generate_passwords
echo.
echo [INFO] Generating secure passwords...
REM Generate random passwords (simplified for Windows)
set MYSQL_PASS=SBMysql%RANDOM%%RANDOM%
set MONGODB_PASS=SBMongo%RANDOM%%RANDOM%
set RABBITMQ_PASS=SBRabbit%RANDOM%%RANDOM%
echo   [OK] Passwords generated

:install
echo.
echo [INFO] Installing StackBill POC...
echo   Domain:    %DOMAIN%
echo   Namespace: %NAMESPACE%
echo   Release:   %RELEASE_NAME%
echo.
echo   Auto-provisioning: MySQL, MongoDB, RabbitMQ, NFS
echo.

set HELM_CMD=helm upgrade --install %RELEASE_NAME% %CHART_PATH%
set HELM_CMD=%HELM_CMD% --namespace %NAMESPACE%
set HELM_CMD=%HELM_CMD% --timeout %TIMEOUT%
set HELM_CMD=%HELM_CMD% --wait
set HELM_CMD=%HELM_CMD% --set domain.name=%DOMAIN%
set HELM_CMD=%HELM_CMD% --set-file ssl.certificate=%SSL_CERT%
set HELM_CMD=%HELM_CMD% --set-file ssl.privateKey=%SSL_KEY%

if not "%SSL_CA%"=="" (
    set HELM_CMD=%HELM_CMD% --set-file ssl.caBundle=%SSL_CA%
)

set HELM_CMD=%HELM_CMD% --set mysql.auth.rootPassword=%MYSQL_PASS%
set HELM_CMD=%HELM_CMD% --set mysql.auth.password=%MYSQL_PASS%
set HELM_CMD=%HELM_CMD% --set mongodb.auth.rootPassword=%MONGODB_PASS%
set HELM_CMD=%HELM_CMD% --set mongodb.auth.password=%MONGODB_PASS%
set HELM_CMD=%HELM_CMD% --set rabbitmq.auth.password=%RABBITMQ_PASS%

echo [INFO] Deploying... (this may take 5-10 minutes)
%HELM_CMD%

if %errorlevel% neq 0 (
    echo [ERROR] Installation failed
    exit /b 1
)

:save_creds
echo.
echo [INFO] Saving credentials...

set CREDS_FILE=%USERPROFILE%\stackbill-poc-credentials.txt

echo =============================================================================== > "%CREDS_FILE%"
echo STACKBILL POC - CREDENTIALS >> "%CREDS_FILE%"
echo =============================================================================== >> "%CREDS_FILE%"
echo Generated: %DATE% %TIME% >> "%CREDS_FILE%"
echo Domain: %DOMAIN% >> "%CREDS_FILE%"
echo. >> "%CREDS_FILE%"
echo MYSQL >> "%CREDS_FILE%"
echo ----- >> "%CREDS_FILE%"
echo Host: %RELEASE_NAME%-mysql.%NAMESPACE%.svc.cluster.local >> "%CREDS_FILE%"
echo Port: 3306 >> "%CREDS_FILE%"
echo Database: stackbill >> "%CREDS_FILE%"
echo Username: stackbill >> "%CREDS_FILE%"
echo Password: %MYSQL_PASS% >> "%CREDS_FILE%"
echo. >> "%CREDS_FILE%"
echo MONGODB >> "%CREDS_FILE%"
echo ------- >> "%CREDS_FILE%"
echo Host: %RELEASE_NAME%-mongodb.%NAMESPACE%.svc.cluster.local >> "%CREDS_FILE%"
echo Port: 27017 >> "%CREDS_FILE%"
echo Database: stackbill_usage >> "%CREDS_FILE%"
echo Username: stackbill >> "%CREDS_FILE%"
echo Password: %MONGODB_PASS% >> "%CREDS_FILE%"
echo. >> "%CREDS_FILE%"
echo RABBITMQ >> "%CREDS_FILE%"
echo -------- >> "%CREDS_FILE%"
echo Host: %RELEASE_NAME%-rabbitmq.%NAMESPACE%.svc.cluster.local >> "%CREDS_FILE%"
echo Port: 5672 >> "%CREDS_FILE%"
echo Management Port: 15672 >> "%CREDS_FILE%"
echo Username: stackbill >> "%CREDS_FILE%"
echo Password: %RABBITMQ_PASS% >> "%CREDS_FILE%"
echo. >> "%CREDS_FILE%"
echo =============================================================================== >> "%CREDS_FILE%"

echo   [OK] Credentials saved to: %CREDS_FILE%

:success
echo.
echo ===============================================================================
echo                       INSTALLATION COMPLETE!
echo ===============================================================================
echo.
echo Access StackBill: https://%DOMAIN%
echo.
echo Credentials saved to: %CREDS_FILE%
echo.
echo Useful Commands:
echo   kubectl get pods -n %NAMESPACE%
echo   kubectl logs -f -l app=sb-deployment-controller -n %NAMESPACE%
echo   kubectl port-forward svc/sb-deployment-controller 8080:80 -n %NAMESPACE%
echo.
echo NOTE: Configure DNS to point %DOMAIN% to your cluster.
echo.

endlocal
