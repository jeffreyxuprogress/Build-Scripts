@echo off
REM OpenSSL Build Automation Script for Windows
REM This script automates the process of building OpenSSL with FIPS support on Windows
REM Usage: openssl_build_winnt.bat [options] [branch] [work_directory] [marklogic_directory]
REM Example: openssl_build_winnt.bat --arch 64 develop-11 c:\work c:\code\xdmp

setlocal enabledelayedexpansion

REM Default values
set "BUILD_ARCH=64"
set "SKIP_FIPS=0"
set "BUILD_ML=0"
set "VS_ARCH=amd64"

REM ============================================================================
REM Environment Setup - Will be initialized after parsing arguments
REM ============================================================================

REM Configuration
set "FIPS_VERSION=2.0.5"
set "PATCH_FILE=win32-1.0.2g.diff"

REM MSVC compiler versions to create directories for
set "MSVC_VERSIONS=msvc14 msvc15"

REM Parse command line arguments
:parse_args
if "%~1"=="" goto :args_done
if "%~1"=="-h" goto :show_help
if "%~1"=="--help" goto :show_help

if "%~1"=="--arch" (
    set "BUILD_ARCH=%~2"
    shift
    shift
    goto :parse_args
)

if "%~1"=="--skip-fips" (
    set "SKIP_FIPS=1"
    shift
    goto :parse_args
)

if "%~1"=="--build-ml" (
    set "BUILD_ML=1"
    shift
    goto :parse_args
)

if "%~1"=="--skip-git-update" (
    set "SKIP_GIT_UPDATE=1"
    shift
    goto :parse_args
)

if "%~1"=="--clean" (
    set "CLEAN_MODE=1"
    set "WORK_DIR=%~2"
    set "ML_DIR=%~3"
    goto :init_environment
)

if "%~1"=="--copy-only" (
    set "COPY_ONLY_MODE=1"
    set "WORK_DIR=%~2"
    set "ML_DIR=%~3"
    goto :init_environment
)

REM First positional arg is branch
if not defined TARGET_BRANCH (
    set "TARGET_BRANCH=%~1"
    shift
    goto :parse_args
)

REM Second positional arg is work_dir
if not defined WORK_DIR (
    set "WORK_DIR=%~1"
    shift
    goto :parse_args
)

REM Third positional arg is ml_dir
if not defined ML_DIR (
    set "ML_DIR=%~1"
    shift
    goto :parse_args
)

shift
goto :parse_args

:args_done
if not defined TARGET_BRANCH set "TARGET_BRANCH=develop"
if not defined WORK_DIR set "WORK_DIR=%CD%"

REM Set VS architecture based on BUILD_ARCH
if "%BUILD_ARCH%"=="32" (
    set "VS_ARCH=x86"
) else (
    set "VS_ARCH=amd64"
)

:init_environment
REM ============================================================================
REM Initialize Visual Studio environment with correct architecture
REM ============================================================================
echo [INFO] Initializing Visual Studio 2017 environment for %BUILD_ARCH%-bit builds...

REM Call vcvarsall.bat to set up VS environment
call "C:\Program Files (x86)\Microsoft Visual Studio\2017\Professional\VC\Auxiliary\Build\vcvarsall.bat" %VS_ARCH% >nul 2>&1
if errorlevel 1 (
    echo [ERROR] Failed to initialize Visual Studio environment
    exit /b 1
)
echo [INFO] Visual Studio environment initialized

REM Always set Windows SDK paths to ensure headers are found
set "WINSDK_VERSION=10.0.17763.0"
set "WINSDK_INC=C:\Program Files (x86)\Windows Kits\10\Include\%WINSDK_VERSION%"
set "WINSDK_LIB=C:\Program Files (x86)\Windows Kits\10\Lib\%WINSDK_VERSION%"

REM Set INCLUDE with Windows SDK paths first
set "INCLUDE=%WINSDK_INC%\ucrt;%WINSDK_INC%\um;%WINSDK_INC%\shared;%INCLUDE%"

REM Set LIB based on architecture
if "%BUILD_ARCH%"=="32" (
    set "LIB=%WINSDK_LIB%\ucrt\x86;%WINSDK_LIB%\um\x86;%LIB%"
) else (
    set "LIB=%WINSDK_LIB%\ucrt\x64;%WINSDK_LIB%\um\x64;%LIB%"
)

REM Add required tools to PATH only if not already present
REM Check and add Strawberry Perl
echo ;%PATH%; | %SystemRoot%\System32\find.exe /C /I ";C:\Strawberry\perl\bin;" >nul 2>&1
if errorlevel 1 set "PATH=C:\Strawberry\perl\bin;%PATH%"

REM Check and add Git usr\bin (for tar)
echo ;%PATH%; | %SystemRoot%\System32\find.exe /C /I ";C:\Program Files\Git\usr\bin;" >nul 2>&1
if errorlevel 1 set "PATH=C:\Program Files\Git\usr\bin;%PATH%"

REM Check and add Git bin
echo ;%PATH%; | %SystemRoot%\System32\find.exe /C /I ";C:\Program Files\Git\bin;" >nul 2>&1
if errorlevel 1 set "PATH=C:\Program Files\Git\bin;%PATH%"

echo [INFO] Environment setup complete

REM Handle special modes that skip normal directory setup
if defined CLEAN_MODE goto :clean_all
if defined COPY_ONLY_MODE goto :copy_only

:setup_directories
REM Convert to absolute path
if not defined WORK_DIR set "WORK_DIR=%CD%"
pushd "%WORK_DIR%" 2>nul
if errorlevel 1 (
    echo [ERROR] Work directory does not exist: %WORK_DIR%
    exit /b 1
)
set "WORK_DIR=%CD%"
popd

REM Check if we're in an openssl directory with tarballs
cd /d "%CD%"
for %%f in (openssl-*.tar.gz) do (
    set "HAS_TARBALLS=1"
    goto :found_tarballs
)
:found_tarballs

echo %CD% | %SystemRoot%\System32\find.exe /I "openssl" >nul 2>&1
if not errorlevel 1 if defined HAS_TARBALLS (
    set "TARBALL_DIR=%CD%"
    set "OPENSSL_DIR=%CD%"
    set "BUILD_DIR=%CD%"
    echo [INFO] Detected openssl directory with tarballs: %TARBALL_DIR%
) else (
    set "OPENSSL_DIR=%WORK_DIR%\openssl"
    set "TARBALL_DIR=%OPENSSL_DIR%"
    set "BUILD_DIR=%OPENSSL_DIR%"
)

REM Generate timestamp for directories
for /f "tokens=2-4 delims=/ " %%a in ('date /t') do (set "BUILD_DATE=%%c%%a%%b")
for /f "tokens=1-2 delims=: " %%a in ('time /t') do (set "BUILD_TIME=%%a%%b")
set "BUILD_TIMESTAMP=%BUILD_DATE%_%BUILD_TIME%"

REM Install and logs directories
set "INSTALL_DIR=%BUILD_DIR%\INSTALL_DIR\%BUILD_TIMESTAMP%"
set "LOGS_DIR=%BUILD_DIR%\logs"

REM Determine OpenSSL version based on branch
if "%TARGET_BRANCH%"=="develop-11" (
    set "OPENSSL_MAJOR_VERSION=1.0.2"
    set "DEFAULT_OPENSSL_VERSION=1.0.2zm"
    set "BUILD_OPENSSL3=0"
) else (
    set "OPENSSL_MAJOR_VERSION=3"
    set "DEFAULT_OPENSSL_VERSION=3.3.5"
    set "OPENSSL3_FIPS_VERSION=3.1.2"
    set "BUILD_OPENSSL3=1"
)

REM Handle special modes
if defined CLEAN_MODE goto :clean_all
if defined COPY_ONLY_MODE goto :copy_only

echo [INFO] Starting OpenSSL build automation for Windows...
echo [INFO] Target branch: %TARGET_BRANCH%
echo [INFO] Work directory: %WORK_DIR%

REM Main execution
call :check_prerequisites
if errorlevel 1 exit /b 1

call :setup_openssl_repo
if errorlevel 1 exit /b 1

REM After setup_openssl_repo, we should be in the openssl directory
REM Set all directory variables based on current location
set "OPENSSL_DIR=%CD%"
set "TARBALL_DIR=%OPENSSL_DIR%"
set "BUILD_DIR=%OPENSSL_DIR%"

REM Generate timestamp for directories
for /f "tokens=2-4 delims=/ " %%a in ('date /t') do (set "BUILD_DATE=%%c%%a%%b")
for /f "tokens=1-2 delims=: " %%a in ('time /t') do (set "BUILD_TIME=%%a%%b")
set "BUILD_TIMESTAMP=%BUILD_DATE%_%BUILD_TIME%"

set "INSTALL_DIR=%BUILD_DIR%\INSTALL_DIR\%BUILD_TIMESTAMP%"
set "LOGS_DIR=%BUILD_DIR%\logs"

call :detect_openssl_version
if errorlevel 1 exit /b 1

echo [INFO] Building OpenSSL version: %OPENSSL_VERSION%

echo [INFO] Cleaning up old extracted build directories...
call :cleanup_old_builds
if errorlevel 1 exit /b 1

echo [DEBUG] BUILD_ARCH=%BUILD_ARCH%, BUILD_OPENSSL3=%BUILD_OPENSSL3%, SKIP_FIPS=%SKIP_FIPS%

if "%BUILD_OPENSSL3%"=="1" (
    call :build_openssl3
    if errorlevel 1 exit /b 1
) else (
    REM OpenSSL 1.x builds
    if /i "%BUILD_ARCH%"=="64" (
        if "%SKIP_FIPS%"=="0" (
            call :build_fips
            if errorlevel 1 exit /b 1
        ) else (
            echo [INFO] Skipping FIPS build, using existing FIPS installation
        )
        
        call :build_openssl_64bit
        if errorlevel 1 exit /b 1
    ) else (
        echo [INFO] BUILD_ARCH is not 64, it is: %BUILD_ARCH%
        echo [INFO] Building 32-bit OpenSSL without FIPS support
        call :build_openssl_32bit
        if errorlevel 1 exit /b 1
    )
)

call :copy_to_marklogic
if errorlevel 1 exit /b 1

call :display_summary
echo [INFO] OpenSSL build automation completed successfully!
exit /b 0

REM ============================================================================
REM Help Function
REM ============================================================================
:show_help
echo OpenSSL Build Automation Script for Windows
echo.
echo Usage: %~nx0 [options] [branch] [work_directory] [marklogic_directory]
echo.
echo Options:
echo   -h, --help            Show this help message
echo   --arch ^<32^|64^>        Build architecture: 32-bit or 64-bit (default: 64)
echo                         Note: 32-bit builds should be run in a separate terminal
echo   --skip-fips           Skip FIPS build and use existing FIPS installation
echo                         Only applicable for 64-bit builds
echo   --build-ml            Build MarkLogic after copying OpenSSL files
echo                         Runs: make clean, make keyed, make optimize, make -j8
echo   --clean               Clean all build artifacts (INSTALL_DIR and extracted directories)
echo   --copy-only           Copy latest build artifacts to MarkLogic without rebuilding
echo.
echo Arguments:
echo   branch                Branch to build: develop (OpenSSL 3.x) or develop-11 (OpenSSL 1.x)
echo                         Default: develop
echo   work_directory        Directory to perform build in (default: current directory)
echo   marklogic_directory   Path to MarkLogic directory (e.g., c:\code\xdmp)
echo.
echo Examples:
echo   %~nx0 --arch 64 develop-11                        # Build 64-bit OpenSSL 1.x with FIPS
echo   %~nx0 --arch 64 --skip-fips develop-11            # Build 64-bit using existing FIPS
echo   %~nx0 --arch 32 develop-11                        # Build 32-bit OpenSSL 1.x (no FIPS)
echo   %~nx0 --arch 64 develop-11 . c:\code\xdmp         # Build and copy to MarkLogic
echo   %~nx0 --arch 64 --build-ml develop-11 . c:\code\xdmp  # Build, copy, and build MarkLogic
echo   %~nx0 --clean                                     # Clean all build artifacts
echo   %~nx0 --copy-only . c:\code\xdmp                  # Copy latest build without rebuilding
echo.
echo Build Details:
echo   For OpenSSL 1.x (develop-11):
echo     --arch 64: Build FIPS (unless --skip-fips) + OpenSSL 64-bit with FIPS
echo     --arch 32: Build OpenSSL 32-bit only (no FIPS support)
echo.
echo   For OpenSSL 3.x (develop):
echo     Build OpenSSL 3.1.2 (FIPS module) + OpenSSL 3.3.5 (libraries)
echo.
echo Note: Run 32-bit and 64-bit builds in separate command prompts to avoid
echo       environment conflicts. The script initializes the correct VS environment
echo       automatically based on --arch.
echo.
echo Requirements:
echo   - Strawberry Perl, Git, tar in PATH (automatically configured)
echo   - Visual Studio 2017 with Windows SDK
echo.
exit /b 0

REM ============================================================================
REM Check Prerequisites
REM ============================================================================
:check_prerequisites
echo [INFO] Checking prerequisites...
echo [INFO] Assuming perl, tar, and git are in PATH (set at top of script)
echo [INFO] Assuming Visual Studio build tools (nmake, cl) are available

REM Check for git availability (optional - won't cause build to fail)
git --version >nul 2>&1
if errorlevel 1 (
    echo [WARN] git not found - will use existing tarballs only
    set "GIT_AVAILABLE=0"
) else (
    set "GIT_AVAILABLE=1"
)

echo [INFO] Prerequisites check passed
exit /b 0

REM ============================================================================
REM Setup or Update OpenSSL Repository
REM ============================================================================
:setup_openssl_repo
echo [INFO] Setting up OpenSSL repository...

REM If git is not available, skip git operations
if "%GIT_AVAILABLE%"=="0" (
    echo [INFO] Skipping git operations - git not available
    set "SKIP_GIT_UPDATE=1"
)

if "%SKIP_GIT_UPDATE%"=="1" (
    echo [INFO] Skipping git update operations (--skip-git-update specified)
    set "GIT_AVAILABLE=0"
    
    REM Check if we're in openssl directory or work_dir/openssl exists
    for %%I in ("%CD%") do set "CURRENT_DIR=%%~nxI"
    echo !CURRENT_DIR! | %SystemRoot%\System32\find.exe /I "openssl" >nul 2>&1
    if not errorlevel 1 (
        echo [INFO] Using current openssl directory: %CD%
        set "OPENSSL_DIR=%CD%"
        set "INSTALL_DIR=%OPENSSL_DIR%\INSTALL_DIR\%BUILD_TIMESTAMP%"
        set "LOGS_DIR=%OPENSSL_DIR%\logs"
        goto :setup_complete
    )
    
    if exist "%WORK_DIR%\openssl" (
        echo [INFO] Using existing openssl directory: %WORK_DIR%\openssl
        cd /d "%WORK_DIR%\openssl"
        set "OPENSSL_DIR=%WORK_DIR%\openssl"
        set "TARBALL_DIR=%WORK_DIR%\openssl"
        set "BUILD_DIR=%WORK_DIR%\openssl"
        set "INSTALL_DIR=%WORK_DIR%\openssl\INSTALL_DIR\%BUILD_TIMESTAMP%"
        set "LOGS_DIR=%WORK_DIR%\openssl\logs"
        goto :setup_complete
    )
    
    echo [ERROR] No openssl directory found and git is not available
    echo [ERROR] Please either:
    echo [ERROR]   1. Install git and add it to PATH
    echo [ERROR]   2. Create openssl directory with tarballs manually
    echo [ERROR]   3. Run from an existing openssl directory
    exit /b 1
)

REM Configuration for git repo
set "OPENSSL_REPO=https://github.bedford.progress.com/marklogic-platform/openssl.git"

REM Check if we're already in the openssl directory
for %%I in ("%CD%") do set "CURRENT_DIR=%%~nxI"

echo !CURRENT_DIR! | %SystemRoot%\System32\find.exe /I "openssl" >nul 2>&1
if not errorlevel 1 (
    if exist ".git" (
        echo [INFO] Already in openssl directory, updating repository...
        
        REM Fetch latest changes
        echo [INFO] Fetching latest changes...
        git fetch origin
        if errorlevel 1 (
            echo [ERROR] Failed to fetch from origin
            exit /b 1
        )
        
        REM Get current branch
        for /f "tokens=*" %%b in ('git rev-parse --abbrev-ref HEAD 2^>nul') do set "CURRENT_BRANCH=%%b"
        echo [INFO] Current branch: !CURRENT_BRANCH!
        
        REM Rebase current branch
        echo [INFO] Rebasing !CURRENT_BRANCH!...
        git rebase origin/!CURRENT_BRANCH!
        if errorlevel 1 (
            echo [WARN] Rebase failed, you may need to resolve conflicts manually
            exit /b 1
        )
        
        REM Update directory variables
        set "OPENSSL_DIR=%CD%"
        set "TARBALL_DIR=%OPENSSL_DIR%"
        set "BUILD_DIR=%OPENSSL_DIR%"
        set "INSTALL_DIR=%OPENSSL_DIR%\INSTALL_DIR\%BUILD_TIMESTAMP%"
        set "LOGS_DIR=%OPENSSL_DIR%\logs"
        
        goto :setup_complete
    )
)

REM Not in openssl directory, proceed with normal logic
cd /d "%WORK_DIR%"

if exist "openssl" (
    echo [INFO] OpenSSL directory exists, updating repository...
    cd openssl
    
    REM Check if it's a valid git repository
    if not exist ".git" (
        echo [ERROR] openssl directory exists but is not a git repository
        echo [ERROR] Please remove the directory or specify a different work directory
        exit /b 1
    )
    
    REM Fetch latest changes
    echo [INFO] Fetching latest changes...
    git fetch origin
    if errorlevel 1 (
        echo [ERROR] Failed to fetch from origin
        exit /b 1
    )
    
    REM Get current branch
    for /f "tokens=*" %%b in ('git rev-parse --abbrev-ref HEAD 2^>nul') do set "CURRENT_BRANCH=%%b"
    echo [INFO] Current branch: !CURRENT_BRANCH!
    
    REM Rebase current branch
    echo [INFO] Rebasing !CURRENT_BRANCH!...
    git rebase origin/!CURRENT_BRANCH!
    if errorlevel 1 (
        echo [WARN] Rebase failed, you may need to resolve conflicts manually
        exit /b 1
    )
    
    REM Set directory variables
    set "OPENSSL_DIR=%CD%"
    set "TARBALL_DIR=%OPENSSL_DIR%"
    set "BUILD_DIR=%OPENSSL_DIR%"
) else (
    echo [INFO] Cloning OpenSSL repository...
    git clone "%OPENSSL_REPO%" openssl
    if errorlevel 1 (
        echo [ERROR] Failed to clone repository
        exit /b 1
    )
    cd openssl
    set "OPENSSL_DIR=%CD%"
    set "TARBALL_DIR=%OPENSSL_DIR%"
    set "BUILD_DIR=%OPENSSL_DIR%"
)

:setup_complete
echo [INFO] OpenSSL repository setup complete
exit /b 0

REM ============================================================================
REM Detect OpenSSL Version
REM ============================================================================
:detect_openssl_version
echo [INFO] Detecting OpenSSL version for branch: %TARGET_BRANCH%

cd /d "%TARBALL_DIR%" 2>nul
if errorlevel 1 (
    echo [ERROR] Failed to change to tarball directory: %TARBALL_DIR%
    exit /b 1
)

REM Look for existing tar files matching the major version
if "%TARGET_BRANCH%"=="develop-11" (
    set "PATTERN=openssl-1.0.2*.tar.gz"
) else (
    set "PATTERN=openssl-3*.tar.gz"
)

REM Find the latest version from existing tar files (sorted in descending order)
set "LATEST_TAR="
for /f "delims=" %%f in ('dir /b /o-n "%PATTERN%" 2^>nul') do (
    set "LATEST_TAR=%%f"
    goto :found_latest
)
:found_latest

if defined LATEST_TAR (
    REM Extract version from filename (openssl-VERSION.tar.gz)
    set "OPENSSL_VERSION=!LATEST_TAR:~8,-7!"
    echo [INFO] Found existing tar file: !LATEST_TAR!
    echo [INFO] Using OpenSSL version: !OPENSSL_VERSION!
) else (
    set "OPENSSL_VERSION=%DEFAULT_OPENSSL_VERSION%"
    echo [INFO] No existing tar files found matching pattern: %PATTERN%
    echo [INFO] Using default version: !OPENSSL_VERSION!
)

REM Verify the tarball exists
if not exist "openssl-!OPENSSL_VERSION!.tar.gz" (
    echo [WARN] Tarball not found: openssl-!OPENSSL_VERSION!.tar.gz
    echo [WARN] Available tarballs in %TARBALL_DIR%:
    dir /b openssl-*.tar.gz 2>nul
    echo [ERROR] Please ensure the correct OpenSSL tarball is present
    exit /b 1
)

exit /b 0

REM ============================================================================
REM Cleanup Old Builds
REM ============================================================================
:cleanup_old_builds
echo [INFO] Cleaning up old extracted build directories...

cd /d "%TARBALL_DIR%"

for /d %%d in (openssl-*) do (
    if exist "%%d" (
        echo [INFO] Removing old directory: %%d
        rmdir /s /q "%%d"
    )
)

for /d %%d in (openssl-fips-*) do (
    if exist "%%d" (
        echo [INFO] Removing old directory: %%d
        rmdir /s /q "%%d"
    )
)

echo [INFO] Cleanup complete
exit /b 0

REM ============================================================================
REM Clean All Build Artifacts
REM ============================================================================
:clean_all
echo [INFO] Cleaning all build artifacts...

if not exist "%OPENSSL_DIR%" (
    if not exist "openssl" (
        echo [ERROR] No openssl directory found at %OPENSSL_DIR% or .\openssl
        exit /b 1
    )
    set "OPENSSL_DIR=%CD%\openssl"
)

cd /d "%OPENSSL_DIR%"
echo [INFO] Working in: %CD%

REM Count what we're about to delete
set "EXTRACTED_COUNT=0"
for /d %%d in (openssl-*) do set /a EXTRACTED_COUNT+=1
for /d %%d in (openssl-fips-*) do set /a EXTRACTED_COUNT+=1

set "HAS_OPENSSL_ARTIFACTS=0"
if %EXTRACTED_COUNT% gtr 0 set "HAS_OPENSSL_ARTIFACTS=1"
if exist "INSTALL_DIR" set "HAS_OPENSSL_ARTIFACTS=1"

REM Check for MarkLogic directories with OpenSSL
set "ML_OPENSSL_COUNT=0"
if defined ML_DIR (
    if exist "%ML_DIR%\3rdParty\openssl" (
        for /d %%d in ("%ML_DIR%\3rdParty\openssl\*") do set /a ML_OPENSSL_COUNT+=1
    )
)

REM Check if there's anything to clean
if %HAS_OPENSSL_ARTIFACTS%==0 if %ML_OPENSSL_COUNT%==0 (
    echo [INFO] Nothing to clean - no build artifacts or MarkLogic OpenSSL directories found
    exit /b 0
)

echo.
echo [WARN] The following will be deleted:
echo.

if %HAS_OPENSSL_ARTIFACTS%==1 (
    echo   OpenSSL Build Directory: %OPENSSL_DIR%
    
    if %EXTRACTED_COUNT% gtr 0 (
        echo     Extracted directories: %EXTRACTED_COUNT%
        for /d %%d in (openssl-*) do echo       %%d
        for /d %%d in (openssl-fips-*) do echo       %%d
    )
    
    if exist "INSTALL_DIR" (
        echo     Installation directories:
        echo       INSTALL_DIR\
        set "INSTALL_COUNT=0"
        for /d %%d in (INSTALL_DIR\*) do set /a INSTALL_COUNT+=1
        if !INSTALL_COUNT! gtr 0 echo         Contains !INSTALL_COUNT! timestamped builds
    )
    echo.
)

if %ML_OPENSSL_COUNT% gtr 0 (
    echo   MarkLogic 3rdParty OpenSSL directories: %ML_OPENSSL_COUNT%
    for /d %%d in ("%ML_DIR%\3rdParty\openssl\*") do echo     %%d
    echo.
)

set /p "CONFIRM=Are you sure you want to delete these? (y/N): "
if /i not "%CONFIRM%"=="y" (
    echo [INFO] Clean cancelled
    exit /b 0
)

REM Perform deletion of OpenSSL build artifacts
if %HAS_OPENSSL_ARTIFACTS%==1 (
    echo [INFO] Cleaning OpenSSL build artifacts...
    
    for /d %%d in (openssl-*) do (
        if exist "%%d" (
            echo [INFO]   Removing: %%d
            rmdir /s /q "%%d"
        )
    )
    
    for /d %%d in (openssl-fips-*) do (
        if exist "%%d" (
            echo [INFO]   Removing: %%d
            rmdir /s /q "%%d"
        )
    )
    
    if exist "INSTALL_DIR" (
        echo [INFO]   Removing: INSTALL_DIR\
        rmdir /s /q "INSTALL_DIR"
    )
)

REM Perform deletion of MarkLogic OpenSSL directories
if %ML_OPENSSL_COUNT% gtr 0 (
    echo [INFO] Cleaning MarkLogic 3rdParty OpenSSL directories...
    for /d %%d in ("%ML_DIR%\3rdParty\openssl\*") do (
        echo [INFO]   Removing: %%d
        rmdir /s /q "%%d"
    )
)

echo [INFO] Clean complete!
exit /b 0

REM ============================================================================
REM Build FIPS Module (OpenSSL 1.x only)
REM ============================================================================
:build_fips
echo [INFO] Building OpenSSL FIPS module...

REM Create logs directory
if not exist "%LOGS_DIR%" mkdir "%LOGS_DIR%"

set "FIPS_LOG=%LOGS_DIR%\openssl_fips_%BUILD_TIMESTAMP%.txt"
echo [INFO] FIPS build output will be logged to: %FIPS_LOG%
echo [INFO] Looking for FIPS tarball in: %TARBALL_DIR%

cd /d "%TARBALL_DIR%"

if not exist "openssl-fips-%FIPS_VERSION%.tar.gz" (
    echo [ERROR] FIPS tarball not found: %TARBALL_DIR%\openssl-fips-%FIPS_VERSION%.tar.gz
    exit /b 1
)

echo [INFO] Extracting FIPS tarball...
tar -xzf "openssl-fips-%FIPS_VERSION%.tar.gz" >> "%FIPS_LOG%" 2>&1
if errorlevel 1 (
    echo [ERROR] Failed to extract FIPS tarball
    exit /b 1
)

cd "%TARBALL_DIR%\openssl-fips-%FIPS_VERSION%"

echo [INFO] Building FIPS (this may take a while)...
echo. | call ms\do_fips.bat no-asm >> "%FIPS_LOG%" 2>&1
if errorlevel 1 (
    echo [ERROR] FIPS build failed. Check log: %FIPS_LOG%
    exit /b 1
)

echo [INFO] FIPS build complete. Log: %FIPS_LOG%
exit /b 0

REM ============================================================================
REM Build OpenSSL 64-bit (OpenSSL 1.x only)
REM ============================================================================
:build_openssl_64bit
echo [INFO] Building OpenSSL 64-bit with FIPS support...

set "OPENSSL_LOG=%LOGS_DIR%\openssl_64bit_%BUILD_TIMESTAMP%.txt"
echo [INFO] OpenSSL 64-bit build output will be logged to: %OPENSSL_LOG%
echo [INFO] Looking for OpenSSL tarball in: %TARBALL_DIR%

cd /d "%TARBALL_DIR%"

if not exist "openssl-%OPENSSL_VERSION%.tar.gz" (
    echo [ERROR] OpenSSL tarball not found: %TARBALL_DIR%\openssl-%OPENSSL_VERSION%.tar.gz
    exit /b 1
)

echo [INFO] Extracting OpenSSL tarball...
tar -xzf "openssl-%OPENSSL_VERSION%.tar.gz" >> "%OPENSSL_LOG%" 2>&1
if errorlevel 1 (
    echo [ERROR] Failed to extract OpenSSL tarball
    exit /b 1
)

cd "%TARBALL_DIR%\openssl-%OPENSSL_VERSION%"

REM Configure OpenSSL with FIPS
set "FIPS_DIR=\usr\local\ssl\fips-2.0"
echo [INFO] Configuring OpenSSL 64-bit with FIPS directory: %FIPS_DIR%
perl Configure VC-WIN64A fips --with-fipsdir=%FIPS_DIR% >> "%OPENSSL_LOG%" 2>&1
if errorlevel 1 (
    echo [ERROR] OpenSSL 64-bit configuration failed. Check log: %OPENSSL_LOG%
    exit /b 1
)

echo [INFO] Running do_win64a...
call ms\do_win64a >> "%OPENSSL_LOG%" 2>&1
if errorlevel 1 (
    echo [ERROR] do_win64a failed. Check log: %OPENSSL_LOG%
    exit /b 1
)

echo [INFO] Building OpenSSL 64-bit (this may take a while)...
nmake -f ms\ntdll.mak >> "%OPENSSL_LOG%" 2>&1
if errorlevel 1 (
    echo [ERROR] OpenSSL 64-bit build failed. Check log: %OPENSSL_LOG%
    exit /b 1
)

REM Create install directory structure
echo [INFO] Installing OpenSSL 64-bit to %INSTALL_DIR%...
if not exist "%INSTALL_DIR%\winnt\amd64" mkdir "%INSTALL_DIR%\winnt\amd64"
if not exist "%INSTALL_DIR%\include" mkdir "%INSTALL_DIR%\include"

REM Copy build artifacts
copy /y out32dll\libeay32.lib "%INSTALL_DIR%\winnt\amd64\" >> "%OPENSSL_LOG%" 2>&1
copy /y out32dll\libeay32.dll "%INSTALL_DIR%\winnt\amd64\" >> "%OPENSSL_LOG%" 2>&1
copy /y out32dll\ssleay32.lib "%INSTALL_DIR%\winnt\amd64\" >> "%OPENSSL_LOG%" 2>&1
copy /y out32dll\ssleay32.dll "%INSTALL_DIR%\winnt\amd64\" >> "%OPENSSL_LOG%" 2>&1

REM Copy headers
%SystemRoot%\System32\xcopy.exe /s /y /i inc32\openssl "%INSTALL_DIR%\include\openssl\" >> "%OPENSSL_LOG%" 2>&1

echo [INFO] OpenSSL 64-bit build complete. Log: %OPENSSL_LOG%
exit /b 0

REM ============================================================================
REM Build OpenSSL 32-bit (OpenSSL 1.x only)
REM ============================================================================
:build_openssl_32bit
echo [INFO] Building OpenSSL 32-bit (no FIPS)...

set "OPENSSL32_LOG=%LOGS_DIR%\openssl_32bit_%BUILD_TIMESTAMP%.txt"
echo [INFO] OpenSSL 32-bit build output will be logged to: %OPENSSL32_LOG%

cd /d "%TARBALL_DIR%"

REM Extract a fresh copy for 32-bit build
if exist "openssl-%OPENSSL_VERSION%-32bit" (
    echo [INFO] Removing old 32-bit directory...
    rmdir /s /q "openssl-%OPENSSL_VERSION%-32bit"
)

echo [INFO] Extracting OpenSSL tarball for 32-bit build...
tar -xzf "openssl-%OPENSSL_VERSION%.tar.gz" >> "%OPENSSL32_LOG%" 2>&1
if errorlevel 1 (
    echo [ERROR] Failed to extract OpenSSL tarball
    exit /b 1
)

REM Rename to distinguish from 64-bit
ren "openssl-%OPENSSL_VERSION%" "openssl-%OPENSSL_VERSION%-32bit"
cd "%TARBALL_DIR%\openssl-%OPENSSL_VERSION%-32bit"

REM Apply 32-bit patch
if exist "%TARBALL_DIR%\patches\%PATCH_FILE%" (
    echo [INFO] Applying 32-bit patch: %PATCH_FILE%
    patch -p0 < "%TARBALL_DIR%\patches\%PATCH_FILE%" >> "%OPENSSL32_LOG%" 2>&1
    if errorlevel 1 (
        echo [WARN] Patch application failed, continuing anyway...
    )
) else (
    echo [WARN] 32-bit patch not found: %TARBALL_DIR%\patches\%PATCH_FILE%
)

echo [INFO] Configuring OpenSSL 32-bit...
perl Configure VC-WIN32 >> "%OPENSSL32_LOG%" 2>&1
if errorlevel 1 (
    echo [ERROR] OpenSSL 32-bit configuration failed. Check log: %OPENSSL32_LOG%
    exit /b 1
)

echo [INFO] Running do_nt...
call ms\do_nt no-asm >> "%OPENSSL32_LOG%" 2>&1
if errorlevel 1 (
    echo [ERROR] do_nt failed. Check log: %OPENSSL32_LOG%
    exit /b 1
)

echo [INFO] Building OpenSSL 32-bit (this may take a while)...
nmake -f ms\ntdll.mak >> "%OPENSSL32_LOG%" 2>&1
if errorlevel 1 (
    echo [ERROR] OpenSSL 32-bit build failed. Check log: %OPENSSL32_LOG%
    exit /b 1
)

REM Create install directory structure
echo [INFO] Installing OpenSSL 32-bit to %INSTALL_DIR%...
if not exist "%INSTALL_DIR%\winnt\i686" mkdir "%INSTALL_DIR%\winnt\i686"

REM Copy build artifacts
copy /y out32dll\libeay32.lib "%INSTALL_DIR%\winnt\i686\" >> "%OPENSSL32_LOG%" 2>&1
copy /y out32dll\libeay32.dll "%INSTALL_DIR%\winnt\i686\" >> "%OPENSSL32_LOG%" 2>&1
copy /y out32dll\ssleay32.lib "%INSTALL_DIR%\winnt\i686\" >> "%OPENSSL32_LOG%" 2>&1
copy /y out32dll\ssleay32.dll "%INSTALL_DIR%\winnt\i686\" >> "%OPENSSL32_LOG%" 2>&1

echo [INFO] OpenSSL 32-bit build complete. Log: %OPENSSL32_LOG%
exit /b 0

REM ============================================================================
REM Build OpenSSL 3.x
REM ============================================================================
:build_openssl3
echo [INFO] Building OpenSSL 3.x (FIPS from 3.1.2, libraries from 3.3.5)...

REM TODO: Implement OpenSSL 3.x build
echo [ERROR] OpenSSL 3.x build not yet implemented
exit /b 1

REM ============================================================================
REM Copy to MarkLogic 3rdParty Directory
REM ============================================================================
:copy_to_marklogic
echo [INFO] Copying build artifacts to MarkLogic 3rdParty directory...

if not defined ML_DIR (
    echo [INFO] No MarkLogic directory specified, skipping copy
    exit /b 0
)

if not exist "%ML_DIR%" (
    echo [ERROR] MarkLogic directory does not exist: %ML_DIR%
    exit /b 1
)

REM Target directory structure
set "ML_3RDPARTY=%ML_DIR%\3rdParty\openssl\%OPENSSL_VERSION%"

echo [INFO] Creating directory structure at: %ML_3RDPARTY%

REM Check if there are other OpenSSL versions and warn
if exist "%ML_DIR%\3rdParty\openssl" (
    set "OTHER_VERSIONS=0"
    for /d %%d in ("%ML_DIR%\3rdParty\openssl\*") do (
        if not "%%~nxd"=="%OPENSSL_VERSION%" set /a OTHER_VERSIONS+=1
    )
    if !OTHER_VERSIONS! gtr 0 (
        echo [WARN] Found !OTHER_VERSIONS! other OpenSSL versions in %ML_DIR%\3rdParty\openssl:
        for /d %%d in ("%ML_DIR%\3rdParty\openssl\*") do (
            if not "%%~nxd"=="%OPENSSL_VERSION%" echo       %%~nxd
        )
        echo [WARN] You may want to remove old versions to keep only %OPENSSL_VERSION%
    )
)

REM Create base directories (common for both develop and develop-11)
if not exist "%ML_3RDPARTY%" mkdir "%ML_3RDPARTY%"
if not exist "%ML_3RDPARTY%\include" mkdir "%ML_3RDPARTY%\include"
if not exist "%ML_3RDPARTY%\linux" mkdir "%ML_3RDPARTY%\linux"
if not exist "%ML_3RDPARTY%\winnt" mkdir "%ML_3RDPARTY%\winnt"

REM Create branch-specific directories
if "%TARGET_BRANCH%"=="develop-11" (
    if not exist "%ML_3RDPARTY%\macosx" mkdir "%ML_3RDPARTY%\macosx"
    echo [INFO] Created directory structure for develop-11: include, linux, winnt, macosx
) else (
    if not exist "%ML_3RDPARTY%\windows-include" mkdir "%ML_3RDPARTY%\windows-include"
    echo [INFO] Created directory structure for develop: include, linux, winnt, windows-include
)

REM Copy include headers
echo [INFO] Looking for OpenSSL include headers...

REM First try INSTALL_DIR (preferred location)
if exist "%INSTALL_DIR%\include\openssl" (
    echo [INFO] Found headers in INSTALL_DIR
    echo [INFO] Copying from: %INSTALL_DIR%\include\openssl
    echo [INFO] Copying to: %ML_3RDPARTY%\include\openssl\
    %SystemRoot%\System32\xcopy.exe /s /y /i /q "%INSTALL_DIR%\include\openssl" "%ML_3RDPARTY%\include\openssl\" >nul
    if errorlevel 1 (
        echo [ERROR] Failed to copy include headers
        exit /b 1
    )
    echo [INFO]   Headers copied successfully
) else (
    REM If not in INSTALL_DIR, look for the extracted build directory
    echo [WARN] Headers not found in INSTALL_DIR, searching build directories...
    
    REM Try to find the openssl source directory
    set "SOURCE_HEADERS="
    if exist "%OPENSSL_DIR%\openssl-!OPENSSL_VERSION!\inc32\openssl" (
        set "SOURCE_HEADERS=%OPENSSL_DIR%\openssl-!OPENSSL_VERSION!\inc32\openssl"
        echo [INFO] Found headers in source directory: !SOURCE_HEADERS!
    ) else (
        REM Source directory doesn't exist, try to extract tarball
        echo [INFO] Source directory not found, checking for tarball...
        if exist "%OPENSSL_DIR%\openssl-!OPENSSL_VERSION!.tar.gz" (
            echo [INFO] Found tarball, extracting headers...
            cd /d "%OPENSSL_DIR%"
            tar -xzf "openssl-!OPENSSL_VERSION!.tar.gz" "openssl-!OPENSSL_VERSION!/inc32/openssl" 2>nul
            if errorlevel 1 (
                REM Try extracting the whole thing if selective extraction fails
                echo [INFO] Extracting entire tarball...
                tar -xzf "openssl-!OPENSSL_VERSION!.tar.gz" >nul 2>&1
            )
            if exist "%OPENSSL_DIR%\openssl-!OPENSSL_VERSION!\inc32\openssl" (
                set "SOURCE_HEADERS=%OPENSSL_DIR%\openssl-!OPENSSL_VERSION!\inc32\openssl"
                echo [INFO] Headers extracted successfully
            )
        )
    )
    
    if defined SOURCE_HEADERS (
        echo [INFO] Copying headers from: !SOURCE_HEADERS!
        echo [INFO] Copying to: %ML_3RDPARTY%\include\openssl\
        %SystemRoot%\System32\xcopy.exe /s /y /i "!SOURCE_HEADERS!" "%ML_3RDPARTY%\include\openssl\"
        if errorlevel 1 (
            echo [ERROR] Failed to copy include headers from source
            exit /b 1
        )
        echo [INFO]   Headers copied successfully
    ) else (
        echo [ERROR] Cannot find OpenSSL include headers
        echo [ERROR] Checked:
        echo [ERROR]   - %INSTALL_DIR%\include\openssl
        echo [ERROR]   - %OPENSSL_DIR%\openssl-!OPENSSL_VERSION!\inc32\openssl
        echo [ERROR]   - %OPENSSL_DIR%\openssl-!OPENSSL_VERSION!.tar.gz
        exit /b 1
    )
)

REM Copy Windows-specific includes for develop branch (OpenSSL 3.x)
if "%TARGET_BRANCH%"=="develop" (
    if exist "%INSTALL_DIR%\include\openssl" (
        echo [INFO] Copying Windows-specific include files...
        %SystemRoot%\System32\xcopy.exe /s /y /i "%INSTALL_DIR%\include\openssl" "%ML_3RDPARTY%\windows-include\openssl\" >nul
        echo [INFO]   Windows includes copied to: %ML_3RDPARTY%\windows-include
    )
)

REM Create Windows architecture directories and copy libraries
for %%m in (%MSVC_VERSIONS%) do (
    if exist "%INSTALL_DIR%\winnt\amd64" (
        echo [INFO] Creating directory: %ML_3RDPARTY%\winnt\amd64-%%m
        if not exist "%ML_3RDPARTY%\winnt\amd64-%%m" mkdir "%ML_3RDPARTY%\winnt\amd64-%%m"
        
        echo [INFO] Copying 64-bit libraries to amd64-%%m...
        copy /y "%INSTALL_DIR%\winnt\amd64\*.*" "%ML_3RDPARTY%\winnt\amd64-%%m\" >nul
    )
    
    if exist "%INSTALL_DIR%\winnt\i686" (
        echo [INFO] Creating directory: %ML_3RDPARTY%\winnt\i686-%%m
        if not exist "%ML_3RDPARTY%\winnt\i686-%%m" mkdir "%ML_3RDPARTY%\winnt\i686-%%m"
        
        echo [INFO] Copying 32-bit libraries to i686-%%m...
        copy /y "%INSTALL_DIR%\winnt\i686\*.*" "%ML_3RDPARTY%\winnt\i686-%%m\" >nul
    )
)

REM Display summary
echo.
echo [INFO] MarkLogic 3rdParty Structure:
echo   %ML_3RDPARTY%\
echo     include\          - headers
echo     linux\            - empty, for Linux builds
if "%TARGET_BRANCH%"=="develop-11" (
    echo     macosx\           - empty, for macOS builds
)
if "%TARGET_BRANCH%"=="develop" (
    echo     windows-include\ - Windows-specific headers
)
echo     winnt\
if exist "%ML_3RDPARTY%\winnt\amd64-msvc14" echo       amd64-msvc14\ - 64-bit libraries
if exist "%ML_3RDPARTY%\winnt\amd64-msvc15" echo       amd64-msvc15\ - 64-bit libraries
if exist "%ML_3RDPARTY%\winnt\i686-msvc14" echo       i686-msvc14\  - 32-bit libraries
if exist "%ML_3RDPARTY%\winnt\i686-msvc15" echo       i686-msvc15\  - 32-bit libraries
echo.

echo [INFO] Copy to MarkLogic 3rdParty complete!

REM Update makefile with new OpenSSL version
echo [INFO] Updating MarkLogic makefile...
set "MAKEFILE=%ML_DIR%\src\winnt\makefiles\defs"

if not exist "%MAKEFILE%" (
    echo [ERROR] Makefile not found: %MAKEFILE%
    exit /b 1
)

REM Backup the original makefile
copy /y "%MAKEFILE%" "%MAKEFILE%.bak.%BUILD_TIMESTAMP%" >nul
echo [INFO]   Created backup: %MAKEFILE%.bak.%BUILD_TIMESTAMP%

REM Update the OPENSSL_VERSION line using batch commands
echo [INFO]   Updating OPENSSL_VERSION in makefile to: %OPENSSL_VERSION%
set "TEMP_FILE=%MAKEFILE%.tmp"
del "%TEMP_FILE%" 2>nul
for /f "usebackq tokens=* delims=" %%i in ("%MAKEFILE%") do (
    set "line=%%i"
    echo !line! | %SystemRoot%\System32\findstr.exe /b /c:"OPENSSL_VERSION" >nul 2>&1
    if errorlevel 1 (
        echo %%i>> "%TEMP_FILE%"
    ) else (
        echo OPENSSL_VERSION = %OPENSSL_VERSION%>> "%TEMP_FILE%"
    )
)
move /y "%TEMP_FILE%" "%MAKEFILE%" >nul 2>&1

REM Build MarkLogic if ML_DIR is provided
call :build_marklogic
if errorlevel 1 exit /b 1

exit /b 0

REM ============================================================================
REM Build MarkLogic
REM ============================================================================
:build_marklogic
if not defined ML_DIR (
    exit /b 0
)

if "%BUILD_ML%"=="0" (
    echo [INFO] Skipping MarkLogic build, use --build-ml to enable
    exit /b 0
)

set "ML_SRC=%ML_DIR%\src"
if not exist "%ML_SRC%" (
    echo [ERROR] MarkLogic src directory does not exist: %ML_SRC%
    exit /b 1
)

echo.
echo [INFO] Building MarkLogic...
echo [INFO] Changing to directory: %ML_SRC%
cd /d "%ML_SRC%"
if errorlevel 1 (
    echo [ERROR] Failed to change to MarkLogic src directory
    exit /b 1
)

echo [INFO] Running: make clean
make clean
if errorlevel 1 (
    echo [ERROR] make clean failed
    exit /b 1
)

echo [INFO] Running: make keyed
make keyed
if errorlevel 1 (
    echo [ERROR] make keyed failed
    exit /b 1
)

echo [INFO] Running: make optimize
make optimize
if errorlevel 1 (
    echo [ERROR] make optimize failed
    exit /b 1
)

echo [INFO] Running: make -j8
make -j8
if errorlevel 1 (
    echo [ERROR] make -j8 failed
    exit /b 1
)

echo [INFO] MarkLogic build complete!
exit /b 0

REM ============================================================================
REM Copy Only Mode
REM ============================================================================
:copy_only
echo [INFO] Copy-only mode: Finding latest build to copy...

if not defined ML_DIR (
    echo [ERROR] MarkLogic directory not specified for copy-only mode
    echo [ERROR] Usage: %~nx0 --copy-only [work_directory] [marklogic_directory]
    exit /b 1
)

REM Setup OPENSSL_DIR if not already set
if not defined OPENSSL_DIR (
    if not defined WORK_DIR set "WORK_DIR=%CD%"
    
    REM Convert WORK_DIR to absolute path
    pushd "%WORK_DIR%" 2>nul
    if errorlevel 1 (
        echo [ERROR] Work directory does not exist: %WORK_DIR%
        exit /b 1
    )
    set "WORK_DIR=%CD%"
    popd
    
    REM Check if we're in an openssl directory
    for %%I in ("%WORK_DIR%") do set "DIR_NAME=%%~nxI"
    if /i "%DIR_NAME%"=="openssl" (
        set "OPENSSL_DIR=%WORK_DIR%"
        echo [INFO] Using openssl directory: %OPENSSL_DIR%
    ) else if exist "%WORK_DIR%\openssl" (
        set "OPENSSL_DIR=%WORK_DIR%\openssl"
        echo [INFO] Using openssl directory: %OPENSSL_DIR%
    ) else (
        echo [ERROR] Cannot find openssl directory
        echo [ERROR] Current directory: %WORK_DIR%
        echo [ERROR] Please run from the openssl directory or specify correct work directory
        exit /b 1
    )
)

REM Find the latest timestamped build in INSTALL_DIR
cd /d "%OPENSSL_DIR%"
if not exist "INSTALL_DIR" (
    echo [ERROR] No INSTALL_DIR found in %OPENSSL_DIR%
    echo [ERROR] Nothing to copy. Build OpenSSL first.
    exit /b 1
)

REM Find the most recent directory (sorted by name descending - timestamps sort correctly)
set "LATEST_BUILD="
for /f "delims=" %%d in ('dir /b /ad /o-n "INSTALL_DIR\*" 2^>nul') do (
    set "LATEST_BUILD=%%d"
    goto :found_latest_build
)
:found_latest_build

if not defined LATEST_BUILD (
    echo [ERROR] No builds found in INSTALL_DIR
    exit /b 1
)

set "INSTALL_DIR=%OPENSSL_DIR%\INSTALL_DIR\%LATEST_BUILD%"
echo [INFO] Found latest build: %LATEST_BUILD%
echo [INFO] Using build directory: %INSTALL_DIR%

REM Check what's in the install directory
echo [INFO] Checking install directory structure...
if exist "%INSTALL_DIR%\include" (
    echo [INFO]   Found: include directory
    if exist "%INSTALL_DIR%\include\openssl" (
        echo [INFO]   Found: include\openssl directory
    ) else (
        echo [WARN]   Missing: include\openssl subdirectory
    )
) else (
    echo [WARN]   Missing: include directory
)

REM Detect OpenSSL version from the build - try multiple methods
set "OPENSSL_VERSION="

REM Method 1: Look for opensslv.h in include\openssl
if exist "%INSTALL_DIR%\include\openssl\opensslv.h" (
    for /f "tokens=3 delims= " %%v in ('%SystemRoot%\System32\findstr.exe /C:"OPENSSL_VERSION_TEXT" "%INSTALL_DIR%\include\openssl\opensslv.h"') do (
        set "VERSION_STRING=%%v"
        goto :parse_version_method1
    )
    :parse_version_method1
    set "OPENSSL_VERSION=!VERSION_STRING:~1,-1!"
    echo [INFO] Detected OpenSSL version from opensslv.h: !OPENSSL_VERSION!
)

REM Method 2: If no version yet, try looking at what's already in MarkLogic 3rdParty
if not defined OPENSSL_VERSION (
    if exist "%ML_DIR%\3rdParty\openssl" (
        echo [INFO] Checking existing MarkLogic OpenSSL installations...
        for /f "delims=" %%d in ('dir /b /ad "%ML_DIR%\3rdParty\openssl\*" 2^>nul') do (
            set "OPENSSL_VERSION=%%d"
            echo [INFO] Using existing version from MarkLogic: !OPENSSL_VERSION!
            goto :version_detected
        )
    )
)

REM Method 3: Ask user to specify version
if not defined OPENSSL_VERSION (
    echo [ERROR] Cannot automatically detect OpenSSL version
    echo [ERROR] Please manually check %INSTALL_DIR%
    set /p "OPENSSL_VERSION=Enter OpenSSL version (e.g., 1.0.2zm): "
    if not defined OPENSSL_VERSION (
        echo [ERROR] No version specified
        exit /b 1
    )
)

:version_detected
echo [INFO] Using OpenSSL version: %OPENSSL_VERSION%

REM Determine branch based on version
echo !OPENSSL_VERSION! | %SystemRoot%\System32\findstr.exe /C:"1.0." >nul
if not errorlevel 1 (
    set "TARGET_BRANCH=develop-11"
    set "BUILD_OPENSSL3=0"
) else (
    set "TARGET_BRANCH=develop"
    set "BUILD_OPENSSL3=1"
)
echo [INFO] Detected branch: %TARGET_BRANCH%

REM Now copy to MarkLogic
call :copy_to_marklogic
if errorlevel 1 exit /b 1

echo [INFO] Copy-only mode completed successfully!
exit /b 0

REM ============================================================================
REM Display Summary
REM ============================================================================
:display_summary
echo.
echo [INFO] Build Summary:
echo ======================================
echo Work Directory: %WORK_DIR%
echo OpenSSL/Tarball Directory: %OPENSSL_DIR%
echo Build Directory: %BUILD_DIR%
echo Install Directory: %INSTALL_DIR%
echo Logs Directory: %LOGS_DIR%
if "%BUILD_OPENSSL3%"=="0" (
    echo FIPS Version: %FIPS_VERSION%
)
echo OpenSSL Version: %OPENSSL_VERSION%
echo Build Timestamp: %BUILD_TIMESTAMP%
echo ======================================
echo.

if exist "%INSTALL_DIR%\winnt" (
    echo [INFO] Build artifacts are available at:
    echo   Headers: %INSTALL_DIR%\include
    if exist "%INSTALL_DIR%\winnt\amd64" echo   64-bit Libraries: %INSTALL_DIR%\winnt\amd64
    if exist "%INSTALL_DIR%\winnt\i686" echo   32-bit Libraries: %INSTALL_DIR%\winnt\i686
    echo.
    echo [INFO] Build logs are available at:
    if exist "%LOGS_DIR%\openssl_fips_%BUILD_TIMESTAMP%.txt" echo   FIPS Log: %LOGS_DIR%\openssl_fips_%BUILD_TIMESTAMP%.txt
    if exist "%LOGS_DIR%\openssl_64bit_%BUILD_TIMESTAMP%.txt" echo   64-bit OpenSSL Log: %LOGS_DIR%\openssl_64bit_%BUILD_TIMESTAMP%.txt
    if exist "%LOGS_DIR%\openssl_32bit_%BUILD_TIMESTAMP%.txt" echo   32-bit OpenSSL Log: %LOGS_DIR%\openssl_32bit_%BUILD_TIMESTAMP%.txt
) else (
    echo [ERROR] Build artifacts not found. Build may have failed.
    echo [ERROR] Check the log files in %LOGS_DIR% for details
)

exit /b 0
