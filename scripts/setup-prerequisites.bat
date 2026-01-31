@echo off
REM ===============================================================================
REM StackBill POC - Step 1: Prerequisites Check (Windows)
REM
REM This script verifies prerequisites for StackBill deployment
REM Note: K3s/Istio installation requires Linux. Use WSL or a Linux VM.
REM ===============================================================================

setlocal enabledelayedexpansion

echo.
echo ===============================================================================
echo      StackBill POC - Prerequisites Check (Windows)
echo ===============================================================================
echo.
echo   This script will verify:
echo     - kubectl connectivity
echo     - Helm installation
echo     - Istio installation
echo     - Storage class configuration
echo.
echo   NOTE: For K3s/Istio installation, use a Linux VM or WSL
echo.
echo ===============================================================================
echo.

set ALL_OK=1

REM Check kubectl
echo [CHECK] kubectl...
where kubectl >nul 2>nul
if %errorlevel% neq 0 (
    echo   [FAIL] kubectl not found
    echo   Install from: https://kubernetes.io/docs/tasks/tools/install-kubectl-windows/
    set ALL_OK=0
) else (
    echo   [OK] kubectl found
    kubectl version --client --short 2>nul
)

REM Check cluster connectivity
echo.
echo [CHECK] Kubernetes cluster connectivity...
kubectl cluster-info >nul 2>nul
if %errorlevel% neq 0 (
    echo   [FAIL] Cannot connect to Kubernetes cluster
    echo   Ensure KUBECONFIG is set or ~/.kube/config exists
    set ALL_OK=0
) else (
    echo   [OK] Cluster is accessible
    kubectl get nodes
)

REM Check Helm
echo.
echo [CHECK] Helm...
where helm >nul 2>nul
if %errorlevel% neq 0 (
    echo   [FAIL] Helm not found
    echo   Install from: https://helm.sh/docs/intro/install/
    set ALL_OK=0
) else (
    echo   [OK] Helm found
    helm version --short 2>nul
)

REM Check Istio
echo.
echo [CHECK] Istio...
kubectl get namespace istio-system >nul 2>nul
if %errorlevel% neq 0 (
    echo   [FAIL] Istio not installed
    echo   Install Istio on your Kubernetes cluster first
    set ALL_OK=0
) else (
    echo   [OK] Istio namespace exists
    kubectl get pods -n istio-system --no-headers 2>nul | findstr "Running" >nul
    if %errorlevel% neq 0 (
        echo   [WARN] Istio pods may not be ready
    ) else (
        echo   [OK] Istio pods running
    )
)

REM Check storage class
echo.
echo [CHECK] Storage Class...
kubectl get storageclass >nul 2>nul
if %errorlevel% neq 0 (
    echo   [WARN] Cannot get storage classes
) else (
    echo   [OK] Storage classes:
    kubectl get storageclass
)

REM Check/Create namespace
echo.
echo [CHECK] Namespace sb-system...
kubectl get namespace sb-system >nul 2>nul
if %errorlevel% neq 0 (
    echo   [INFO] Creating namespace sb-system...
    kubectl create namespace sb-system
    kubectl label namespace sb-system istio-injection=enabled --overwrite
    echo   [OK] Namespace created
) else (
    echo   [OK] Namespace exists
)

REM Summary
echo.
echo ===============================================================================
echo                              SUMMARY
echo ===============================================================================
echo.

if %ALL_OK%==1 (
    echo   [SUCCESS] All prerequisites are met!
    echo.
    echo   Next step - Run the POC installer:
    echo.
    echo   scripts\install-poc.bat ^
    echo     --domain your-domain.com ^
    echo     --ssl-cert C:\path\to\certificate.pem ^
    echo     --ssl-key C:\path\to\private-key.pem
) else (
    echo   [FAILED] Some prerequisites are missing.
    echo   Please install the missing components and try again.
)

echo.
echo ===============================================================================
echo.

REM Get Istio Ingress IP for DNS configuration
echo Istio Ingress Gateway IP (use for DNS):
kubectl get svc istio-ingressgateway -n istio-system -o jsonpath="{.status.loadBalancer.ingress[0].ip}" 2>nul
echo.
echo.

endlocal
