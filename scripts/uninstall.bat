@echo off
REM ===============================================================================
REM StackBill Helm Chart - Windows Uninstallation Script
REM ===============================================================================

setlocal enabledelayedexpansion

set NAMESPACE=sb-apps
set RELEASE_NAME=stackbill
set DELETE_PVC=0
set DELETE_NS=0

echo.
echo ===============================================================================
echo      StackBill Uninstaller (Windows)
echo ===============================================================================
echo.

REM Parse arguments
:parse_args
if "%~1"=="" goto confirm
if /i "%~1"=="-n" set NAMESPACE=%~2& shift & shift & goto parse_args
if /i "%~1"=="--namespace" set NAMESPACE=%~2& shift & shift & goto parse_args
if /i "%~1"=="-r" set RELEASE_NAME=%~2& shift & shift & goto parse_args
if /i "%~1"=="--release" set RELEASE_NAME=%~2& shift & shift & goto parse_args
if /i "%~1"=="--delete-pvc" set DELETE_PVC=1& shift & goto parse_args
if /i "%~1"=="--delete-namespace" set DELETE_NS=1& shift & goto parse_args
if /i "%~1"=="--force" set FORCE=1& shift & goto parse_args
if /i "%~1"=="-h" goto show_help
if /i "%~1"=="--help" goto show_help
shift
goto parse_args

:show_help
echo Usage: uninstall.bat [OPTIONS]
echo.
echo Options:
echo   -n, --namespace NAME     Kubernetes namespace (default: sb-apps)
echo   -r, --release NAME       Helm release name (default: stackbill)
echo   --delete-pvc             Delete PersistentVolumeClaims (DATA LOSS!)
echo   --delete-namespace       Delete the namespace
echo   --force                  Skip confirmation
echo   -h, --help               Show this help
exit /b 0

:confirm
if "%FORCE%"=="1" goto uninstall

echo WARNING: This will uninstall StackBill from namespace '%NAMESPACE%'
if "%DELETE_PVC%"=="1" echo WARNING: --delete-pvc is set. ALL DATA WILL BE LOST!
if "%DELETE_NS%"=="1" echo WARNING: The namespace '%NAMESPACE%' will be deleted
echo.
set /p CONFIRM="Are you sure? [y/N]: "
if /i not "%CONFIRM%"=="y" (
    echo Uninstall cancelled.
    exit /b 0
)

:uninstall
echo.
echo [INFO] Uninstalling Helm release: %RELEASE_NAME%
helm uninstall %RELEASE_NAME% -n %NAMESPACE% 2>nul
if %errorlevel% equ 0 (
    echo   [OK] Release uninstalled
) else (
    echo   [WARN] Release not found or already removed
)

echo.
echo [INFO] Cleaning up resources...
kubectl delete secret -n %NAMESPACE% -l "app.kubernetes.io/name=stackbill" 2>nul
kubectl delete configmap -n %NAMESPACE% -l "app.kubernetes.io/name=stackbill" 2>nul

if "%DELETE_PVC%"=="1" (
    echo.
    echo [INFO] Deleting PersistentVolumeClaims...
    kubectl delete pvc --all -n %NAMESPACE% 2>nul
    echo   [OK] PVCs deleted
)

if "%DELETE_NS%"=="1" (
    echo.
    echo [INFO] Deleting namespace: %NAMESPACE%
    kubectl delete namespace %NAMESPACE% --wait=false 2>nul
    echo   [OK] Namespace deletion initiated
)

echo.
echo [INFO] Uninstall completed!
echo.

if "%DELETE_NS%"=="0" (
    echo Remaining resources in namespace '%NAMESPACE%':
    kubectl get all -n %NAMESPACE% 2>nul
)

endlocal
