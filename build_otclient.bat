@echo off
setlocal EnableDelayedExpansion

set "BUILDDIR=C:\Users\renan\Desktop\OT\otclient"
set "VCPKG_ROOT=C:\vcpkg"
set "CMAKE=C:\Program Files\Microsoft Visual Studio\18\Community\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe"
set "VCVARS=C:\Program Files\Microsoft Visual Studio\18\Community\VC\Auxiliary\Build\vcvars64.bat"

cd /d "%BUILDDIR%"

echo BUILD_RUNNING > "%BUILDDIR%\build_status.txt"

call "%VCVARS%"

echo ==================================================
echo OTClient build started at %DATE% %TIME%
echo ==================================================

echo === STEP 1/2: cmake configure (--preset windows-release) ===
"%CMAKE%" --preset windows-release
set "CFG_RC=%ERRORLEVEL%"
echo Configure exit code: %CFG_RC%
if not "%CFG_RC%"=="0" (
    echo [FATAL] cmake configure failed
    echo BUILD_FAILED_CONFIGURE > "%BUILDDIR%\build_status.txt"
    exit /b %CFG_RC%
)

echo === STEP 2/2: cmake build ===
"%CMAKE%" --build build\windows-release --config RelWithDebInfo
set "BLD_RC=%ERRORLEVEL%"
echo Build exit code: %BLD_RC%
if not "%BLD_RC%"=="0" (
    echo [FATAL] cmake build failed
    echo BUILD_FAILED_COMPILE > "%BUILDDIR%\build_status.txt"
    exit /b %BLD_RC%
)

echo ==================================================
echo OTClient build COMPLETED at %DATE% %TIME%
echo ==================================================
echo BUILD_OK > "%BUILDDIR%\build_status.txt"
exit /b 0
