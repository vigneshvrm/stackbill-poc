@echo off
REM ===============================================================================
REM StackBill Helm Chart - Windows Installation Script
REM ===============================================================================

setlocal enabledelayedexpansion

set NAMESPACE=sb-apps
set RELEASE_NAME=stackbill
set ENVIRONMENT=sandbox
set CHART_PATH=.

echo.
echo ===============================================================================
echo      StackBill Kubernetes Installer (Windows)
echo ===============================================================================
echo.

REM Parse arguments
:parse_args
if "%~1"=="" goto check_prereq
if /i "%~1"=="-n" set NAMESPACE=%~2& shift & shift & goto parse_args
if /i "%~1"=="--namespace" set NAMESPACE=%~2& shift & shift & goto parse_args
if /i "%~1"=="-e" set ENVIRONMENT=%~2& shift & shift & goto parse_args
if /i "%~1"=="--environment" set ENVIRONMENT=%~2& shift & shift & goto parse_args
if /i "%~1"=="--domain" set DOMAIN=%~2& shift & shift & goto parse_args
if /i "%~1"=="--mysql-password" set MYSQL_PASSWORD=%~2& shift & shift & goto parse_args
if /i "%~1"=="--mongodb-password" set MONGODB_PASSWORD=%~2& shift & shift & goto parse_args
if /i "%~1"=="--rabbitmq-password" set RABBITMQ_PASSWORD=%~2& shift & shift & goto parse_args
if /i "%~1"=="-h" goto show_help
if /i "%~1"=="--help" goto show_help
shift
goto parse_args

:show_help
echo Usage: install.bat [OPTIONS]
echo.
echo Options:
echo   -n, --namespace NAME       Kubernetes namespace (default: sb-apps)
echo   -e, --environment ENV      Environment: sandbox^|production (default: sandbox)
echo   --domain DOMAIN            Domain name for ingress
echo   --mysql-password PASS      MySQL password
echo   --mongodb-password PASS    MongoDB password
echo   --rabbitmq-password PASS   RabbitMQ password
echo   -h, --help                 Show this help
echo.
echo Examples:
echo   install.bat -e sandbox
echo   install.bat -e production --domain portal.example.com
exit /b 0

:check_prereq
echo [INFO] Checking prerequisites...

REM Check kubectl
where kubectl >nul 2>nul
if %errorlevel% neq 0 (
    echo [ERROR] kubectl is not installed
    exit /b 1
)
echo   [OK] kubectl found

REM Check helm
where helm >nul 2>nul
if %errorlevel% neq 0 (
    echo [ERROR] helm is not installed
    exit /b 1
)
echo   [OK] helm found

REM Check cluster
kubectl cluster-info >nul 2>nul
if %errorlevel% neq 0 (
    echo [ERROR] Cannot connect to Kubernetes cluster
    exit /b 1
)
echo   [OK] Kubernetes cluster accessible

REM Create namespace if needed
kubectl get namespace %NAMESPACE% >nul 2>nul
if %errorlevel% neq 0 (
    echo [INFO] Creating namespace: %NAMESPACE%
    kubectl create namespace %NAMESPACE%
)
echo   [OK] Namespace %NAMESPACE% ready

:add_repos
echo.
echo [INFO] Adding Helm repositories...
helm repo add bitnami https://charts.bitnami.com/bitnami 2>nul
helm repo update
echo   [OK] Repositories updated

:update_deps
echo.
echo [INFO] Updating dependencies...
helm dependency update %CHART_PATH%
echo   [OK] Dependencies updated

:install
echo.
echo [INFO] Installing StackBill...
echo   Release:     %RELEASE_NAME%
echo   Namespace:   %NAMESPACE%
echo   Environment: %ENVIRONMENT%

REM Generate passwords if not set
if "%MYSQL_PASSWORD%"=="" set MYSQL_PASSWORD=StackBill123!
if "%MONGODB_PASSWORD%"=="" set MONGODB_PASSWORD=StackBill123!
if "%RABBITMQ_PASSWORD%"=="" set RABBITMQ_PASSWORD=StackBill123!

REM Build command
set HELM_CMD=helm upgrade --install %RELEASE_NAME% %CHART_PATH%
set HELM_CMD=%HELM_CMD% --namespace %NAMESPACE%
set HELM_CMD=%HELM_CMD% --timeout 600s
set HELM_CMD=%HELM_CMD% --wait

if "%ENVIRONMENT%"=="sandbox" set HELM_CMD=%HELM_CMD% -f values-sandbox.yaml
if "%ENVIRONMENT%"=="production" set HELM_CMD=%HELM_CMD% -f values-production.yaml

set HELM_CMD=%HELM_CMD% --set mysql.auth.rootPassword=%MYSQL_PASSWORD%
set HELM_CMD=%HELM_CMD% --set mysql.auth.password=%MYSQL_PASSWORD%
set HELM_CMD=%HELM_CMD% --set mongodb.auth.rootPassword=%MONGODB_PASSWORD%
set HELM_CMD=%HELM_CMD% --set mongodb.auth.password=%MONGODB_PASSWORD%
set HELM_CMD=%HELM_CMD% --set rabbitmq.auth.password=%RABBITMQ_PASSWORD%

if not "%DOMAIN%"=="" (
    set HELM_CMD=%HELM_CMD% --set ingress.hosts[0].host=%DOMAIN%
)

echo.
echo [INFO] Executing Helm install...
%HELM_CMD%

if %errorlevel% neq 0 (
    echo [ERROR] Installation failed
    exit /b 1
)

:success
echo.
echo ===============================================================================
echo                          INSTALLATION COMPLETE
echo ===============================================================================
echo.
echo Credentials (SAVE THESE!):
echo   MySQL Password:    %MYSQL_PASSWORD%
echo   MongoDB Password:  %MONGODB_PASSWORD%
echo   RabbitMQ Password: %RABBITMQ_PASSWORD%
echo.
echo ===============================================================================
echo.
echo Next Steps:
echo   1. Check pods:
echo      kubectl get pods -n %NAMESPACE%
echo.
echo   2. Access application:
echo      kubectl port-forward svc/%RELEASE_NAME% 8080:80 -n %NAMESPACE%
echo      Then open: http://localhost:8080
echo.
echo   3. View logs:
echo      kubectl logs -f -l app.kubernetes.io/name=stackbill -n %NAMESPACE%
echo.
echo [INFO] Installation completed successfully!

endlocal
