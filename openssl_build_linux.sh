#!/bin/bash

# OpenSSL Build Automation Script
# This script automates the process of building OpenSSL with FIPS support
# Usage: ./openssl_build.sh [branch] [work_directory] [marklogic_directory]
# Example: ./openssl_build.sh develop-11 /path/to/work/dir /users/ml/xu/code/xdmp

# Don't exit on error - we'll handle errors gracefully
set +e

# Configuration
OPENSSL_REPO="https://github.bedford.progress.com/marklogic-platform/openssl.git"
FIPS_VERSION="2.0.5"
CC_PATH="/opt/rh/gcc-toolset-12/root/bin/gcc"

# GCC versions to create symlinks for
GCC_VERSIONS=("4.8" "4.9" "5.3" "5.4" "6.1" "6.2" "6.3" "6.4" "7.2" "7.4" "8.1" "8.2" "8.3" "8.5" "9.0" "9.1" "9.2" "9.3" "12.2")

# Parse command line arguments
TARGET_BRANCH="${1:-develop}"        # Default to develop (latest/12.x) if not specified
WORK_DIR="${2:-$(pwd)}"             # Default work directory is current directory
ML_DIR="${3:-}"                      # MarkLogic directory (optional)
BUILD_ML_FLAG=false                  # Flag to automatically build MarkLogic
SKIP_FIPS_FLAG=false                 # Flag to skip FIPS build and use existing installation

# Convert WORK_DIR to absolute path
WORK_DIR="$(cd "$WORK_DIR" && pwd)"

# Separate git repo directory from tarball directory
# If we're already in an openssl directory with tarballs, use it directly
if [[ "$(basename "$(pwd)")" == "openssl" ]] && ls openssl-*.tar.gz 1> /dev/null 2>&1; then
    # We're in an openssl directory with tarballs - use current directory
    TARBALL_DIR="$(pwd)"
    OPENSSL_DIR="$TARBALL_DIR"  # Same location for git repo
    BUILD_DIR="$TARBALL_DIR"    # Build artifacts go here
    log_info() { echo -e "\033[0;32m[INFO]\033[0m $1"; }
    log_info "Detected openssl directory with tarballs: $TARBALL_DIR"
else
    # Normal mode - work directory contains openssl subdirectory
    OPENSSL_DIR="$WORK_DIR/openssl"
    TARBALL_DIR="$OPENSSL_DIR"
    BUILD_DIR="$OPENSSL_DIR"  # Build artifacts go in openssl directory
fi

# Generate timestamp for log files and install directory
BUILD_DATE=$(date +%Y%m%d_%H%M%S)

# Install directory with timestamp subdirectory
INSTALL_DIR="$BUILD_DIR/INSTALL_DIR/$BUILD_DATE"
LOGS_DIR="$BUILD_DIR/logs"

# Determine OpenSSL version based on branch
if [[ "$TARGET_BRANCH" == "develop-11" ]]; then
    OPENSSL_MAJOR_VERSION="1.0.2"
    DEFAULT_OPENSSL_VERSION="1.0.2zm"  # Current latest 1.x version
else
    OPENSSL_MAJOR_VERSION="3"
    DEFAULT_OPENSSL_VERSION="3.0.15"   # Current latest 3.x version
fi

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Help function
show_help() {
    echo "OpenSSL Build Automation Script"
    echo ""
    echo "Usage: $0 [branch|--clean|--copy-only|--build-ml|--skip-fips] [work_directory] [marklogic_directory]"
    echo ""
    echo "Parameters:"
    echo "  branch                Target branch: 'develop' (for 12.x/OpenSSL 3.x) or 'develop-11' (for 11.x/OpenSSL 1.x)"
    echo "                        Default: develop"
    echo "  --clean               Clean all build artifacts (INSTALL_DIR and extracted directories)"
    echo "                        If marklogic_directory is provided, also prompts to clean MarkLogic 3rdParty/openssl/"
    echo "  --copy-only           Copy latest build artifacts to MarkLogic without rebuilding"
    echo "  --build-ml            Automatically build MarkLogic after copying OpenSSL files (skips prompt)"
    echo "  --skip-fips           Skip FIPS build and use existing FIPS installation from previous build"
    echo "  work_directory        Directory to perform build in (default: current directory)"
    echo "  marklogic_directory   Path to MarkLogic directory (e.g., /users/ml/xu/code/xdmp)"
    echo "                        If provided, will copy build artifacts to 3rdParty/openssl/"
    echo ""
    echo "Examples:"
    echo "  $0                                      # Build for develop branch (OpenSSL 3.x) in current directory"
    echo "  $0 develop-11                          # Build for develop-11 branch (OpenSSL 1.x) in current directory"
    echo "  $0 develop /tmp/build                  # Build for develop branch in /tmp/build"
    echo "  $0 develop-11 . /users/ml/xu/code/xdmp # Build and copy to MarkLogic 3rdParty"
    echo "  $0 --build-ml . /users/ml/xu/code/xdmp # Build OpenSSL and MarkLogic automatically"
    echo "  $0 --skip-fips develop-11 .            # Rebuild OpenSSL without rebuilding FIPS"
    echo "  $0 --clean                              # Clean all build artifacts in current directory"
    echo "  $0 --clean /tmp/build                  # Clean all build artifacts in /tmp/build"
    echo "  $0 --clean . /users/ml/xu/code/xdmp    # Clean build artifacts AND MarkLogic 3rdParty/openssl/"
    echo "  $0 --copy-only . /users/ml/xu/code/xdmp # Copy latest build to MarkLogic without rebuilding"
    echo ""
    echo "The script will:"
    echo "  1. Clone/update OpenSSL repository"
    echo "  2. Determine OpenSSL version based on branch and available tar files"
    echo "  3. Build FIPS $FIPS_VERSION"
    echo "  4. Build OpenSSL with FIPS support"
    echo "  5. Install to ./openssl/INSTALL_DIR/{timestamp}"
    echo "  6. (Optional) Copy artifacts to MarkLogic 3rdParty directory"
    echo "  7. (Optional) Build MarkLogic to test OpenSSL integration"
    echo ""
    echo "Version Selection Logic:"
    echo "  - develop-11: Uses OpenSSL 1.x (checks for latest 1.0.2.* tar file, defaults to $DEFAULT_OPENSSL_VERSION if none found)"
    echo "  - develop: Uses OpenSSL 3.x (checks for latest 3.* tar file, defaults to $DEFAULT_OPENSSL_VERSION if none found)"
    echo ""
    echo "Copy-Only Smart Matching:"
    echo "  When using --copy-only with a MarkLogic directory, the script will:"
    echo "  - Detect the MarkLogic branch (e.g., develop-11.1, develop-12.0)"
    echo "  - Match it to the required OpenSSL major version (1.x for 11.x branches, 3.x for 12.x/develop)"
    echo "  - Find the latest build matching that major version"
    echo "  - Copy only the appropriate version to avoid mismatches"
}

# Function to clean all build artifacts
clean_all() {
    log_info "Cleaning all build artifacts..."
    
    # Determine openssl directory location
    local openssl_dir=""
    if [[ -d "$OPENSSL_DIR" ]]; then
        openssl_dir="$OPENSSL_DIR"
    elif [[ -d "openssl" ]]; then
        openssl_dir="$(pwd)/openssl"
    else
        log_error "No openssl directory found at $OPENSSL_DIR or ./openssl"
        return 1
    fi
    
    cd "$openssl_dir" || {
        log_error "Failed to cd to $openssl_dir"
        return 1
    }
    
    log_info "Working in: $(pwd)"
    
    # Count what we're about to delete
    local extracted_count=$(ls -d openssl-*/ 2>/dev/null | wc -l)
    local install_dir_base="INSTALL_DIR"
    
    # Check if there's anything to clean in openssl directory
    local has_openssl_artifacts=false
    if [[ $extracted_count -gt 0 ]] || [[ -d "$install_dir_base" ]]; then
        has_openssl_artifacts=true
    fi
    
    # Check for MarkLogic directories with OpenSSL
    local ml_openssl_dirs=()
    if [[ -n "$ML_DIR" ]] && [[ -d "$ML_DIR/3rdParty/openssl" ]]; then
        while IFS= read -r -d '' dir; do
            ml_openssl_dirs+=("$dir")
        done < <(find "$ML_DIR/3rdParty/openssl" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)
    fi
    
    # Check if there's anything to clean
    if [[ "$has_openssl_artifacts" == false ]] && [[ ${#ml_openssl_dirs[@]} -eq 0 ]]; then
        log_info "Nothing to clean - no build artifacts or MarkLogic OpenSSL directories found"
        return 0
    fi
    
    echo ""
    log_warn "The following will be deleted:"
    echo ""
    
    # Show OpenSSL build artifacts
    if [[ "$has_openssl_artifacts" == true ]]; then
        echo "  OpenSSL Build Directory: $openssl_dir"
        
        # Show extracted directories
        if [[ $extracted_count -gt 0 ]]; then
            echo "    Extracted directories ($extracted_count):"
            ls -d openssl-*/ 2>/dev/null | sed 's/^/      /'
        fi
        
        # Show INSTALL_DIR
        if [[ -d "$install_dir_base" ]]; then
            echo "    Installation directories:"
            echo "      $install_dir_base/"
            # Show subdirectories with timestamps
            local install_count=$(ls -d "$install_dir_base"/*/ 2>/dev/null | wc -l)
            if [[ $install_count -gt 0 ]]; then
                echo "        Contains $install_count timestamped build(s)"
            fi
        fi
        echo ""
    fi
    
    # Show MarkLogic OpenSSL directories
    if [[ ${#ml_openssl_dirs[@]} -gt 0 ]]; then
        echo "  MarkLogic 3rdParty OpenSSL directories (${#ml_openssl_dirs[@]}):"
        for dir in "${ml_openssl_dirs[@]}"; do
            echo "    $dir"
        done
        echo ""
    fi
    
    read -p "Are you sure you want to delete these? (y/N): " -n 1 -r
    echo
    
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Clean cancelled"
        return 0
    fi
    
    # Perform deletion of OpenSSL build artifacts
    if [[ "$has_openssl_artifacts" == true ]]; then
        log_info "Cleaning OpenSSL build artifacts..."
        
        # Delete extracted directories
        for dir in openssl-*/; do
            if [[ -d "$dir" ]]; then
                log_info "  Removing: $dir"
                rm -rf "$dir"
            fi
        done
        
        # Delete INSTALL_DIR
        if [[ -d "$install_dir_base" ]]; then
            log_info "  Removing: $install_dir_base/"
            rm -rf "$install_dir_base"
        fi
    fi
    
    # Perform deletion of MarkLogic OpenSSL directories
    if [[ ${#ml_openssl_dirs[@]} -gt 0 ]]; then
        log_info "Cleaning MarkLogic 3rdParty OpenSSL directories..."
        for dir in "${ml_openssl_dirs[@]}"; do
            log_info "  Removing: $dir"
            rm -rf "$dir"
        done
    fi
    
    log_info "Clean complete!"
    return 0
}

# Function to detect MarkLogic branch and determine required OpenSSL major version
detect_ml_branch() {
    local ml_dir="$1"
    
    if [[ ! -d "$ml_dir" ]]; then
        return 1
    fi
    
    # Try to detect git branch
    if [[ -d "$ml_dir/.git" ]]; then
        local ml_branch=$(cd "$ml_dir" && git rev-parse --abbrev-ref HEAD 2>/dev/null)
        if [[ -n "$ml_branch" ]]; then
            # Map branch to OpenSSL major version
            if [[ "$ml_branch" == develop-11* ]]; then
                echo "$ml_branch:1"  # Return branch:version
            else
                echo "$ml_branch:3"  # Return branch:version
            fi
            return 0
        fi
    fi
    
    # Fallback: check existing OpenSSL version in makefile
    local makefile="$ml_dir/src/linux/makefiles/defs"
    if [[ -f "$makefile" ]]; then
        local current_version=$(grep "^OPENSSL_VERSION[[:space:]]*=" "$makefile" | sed 's/^OPENSSL_VERSION[[:space:]]*=[[:space:]]*//')
        if [[ -n "$current_version" ]]; then
            if [[ "$current_version" == 1.* ]]; then
                echo "makefile:1"
            else
                echo "makefile:3"
            fi
            return 0
        fi
    fi
    
    echo ""
    return 0
}

# Function to copy only (without rebuilding)
copy_only() {
    log_info "Copy-only mode: Finding latest build to copy..."
    
    # Check if MarkLogic directory is provided for branch detection
    local required_major_version=""
    local ml_branch_info=""
    if [[ -n "$ML_DIR" ]]; then
        ml_branch_info=$(detect_ml_branch "$ML_DIR")
        if [[ -n "$ml_branch_info" ]]; then
            local branch_name="${ml_branch_info%%:*}"
            required_major_version="${ml_branch_info##*:}"
            if [[ "$branch_name" == "makefile" ]]; then
                log_info "Detected OpenSSL version from makefile: ${required_major_version}.x"
            else
                log_info "Detected MarkLogic branch: $branch_name → OpenSSL ${required_major_version}.x"
            fi
        fi
    fi
    
    # Determine openssl directory location
    local openssl_dir=""
    if [[ -d "$BUILD_DIR" ]]; then
        openssl_dir="$BUILD_DIR"
    elif [[ -d "$OPENSSL_DIR" ]]; then
        openssl_dir="$OPENSSL_DIR"
    elif [[ -d "openssl" ]]; then
        openssl_dir="$(pwd)/openssl"
    else
        log_error "No openssl directory found at $BUILD_DIR, $OPENSSL_DIR, or ./openssl"
        return 1
    fi
    
    log_info "Looking for builds in: $openssl_dir"
    
    # Find the latest timestamped build
    local install_base="$openssl_dir/INSTALL_DIR"
    if [[ ! -d "$install_base" ]]; then
        log_error "No INSTALL_DIR found at: $install_base"
        log_error "Please build OpenSSL first before using --copy-only"
        return 1
    fi
    
    # Get all build directories sorted by timestamp (newest first)
    local latest_build=""
    
    if [[ -n "$required_major_version" ]]; then
        log_info "Looking for OpenSSL ${required_major_version}.x builds..."
        
        # Filter builds by major version
        for build_dir in $(ls -1dt "$install_base"/*/ 2>/dev/null); do
            # Check version in this build
            local version=""
            if [[ -d "$build_dir/usr/local/ssl/include" ]]; then
                version=$(grep "OPENSSL_VERSION_TEXT" "$build_dir/usr/local/ssl/include/openssl/opensslv.h" 2>/dev/null | head -1 | sed 's/.*OpenSSL \([0-9][^ -]*\).*/\1/')
            elif [[ -d "$build_dir/usr/local/include" ]]; then
                version=$(grep "OPENSSL_VERSION_TEXT" "$build_dir/usr/local/include/openssl/opensslv.h" 2>/dev/null | head -1 | sed 's/.*OpenSSL \([0-9][^ -]*\).*/\1/')
            fi
            
            if [[ -n "$version" ]] && [[ "$version" == ${required_major_version}.* ]]; then
                latest_build="$build_dir"
                log_info "Found matching build: $(basename "$build_dir") (OpenSSL $version)"
                break
            fi
        done
        
        if [[ -z "$latest_build" ]]; then
            log_error "No OpenSSL ${required_major_version}.x builds found in: $install_base"
            log_error "Available builds:"
            for build_dir in $(ls -1dt "$install_base"/*/ 2>/dev/null); do
                local version=""
                if [[ -d "$build_dir/usr/local/ssl/include" ]]; then
                    version=$(grep "OPENSSL_VERSION_TEXT" "$build_dir/usr/local/ssl/include/openssl/opensslv.h" 2>/dev/null | head -1 | sed 's/.*OpenSSL \([0-9][^ -]*\).*/\1/')
                elif [[ -d "$build_dir/usr/local/include" ]]; then
                    version=$(grep "OPENSSL_VERSION_TEXT" "$build_dir/usr/local/include/openssl/opensslv.h" 2>/dev/null | head -1 | sed 's/.*OpenSSL \([0-9][^ -]*\).*/\1/')
                fi
                log_error "  $(basename "$build_dir"): OpenSSL $version"
            done
            log_error "Please build OpenSSL ${required_major_version}.x first"
            return 1
        fi
    else
        # No version filtering - use latest build
        latest_build=$(ls -1dt "$install_base"/*/ 2>/dev/null | head -1)
        if [[ -z "$latest_build" ]]; then
            log_error "No build directories found in: $install_base"
            log_error "Please build OpenSSL first before using --copy-only"
            return 1
        fi
        log_info "Found latest build: $(basename "$latest_build")"
    fi
    
    # Remove trailing slash
    latest_build="${latest_build%/}"
    
    # Detect OpenSSL version from the build directory
    # Check for usr/local/ssl/lib (1.0.2) or usr/local/lib (3.x)
    if [[ -d "$latest_build/usr/local/ssl/lib" ]]; then
        # OpenSSL 1.0.2 - look for version in headers (strip -fips suffix)
        OPENSSL_VERSION=$(grep "OPENSSL_VERSION_TEXT" "$latest_build/usr/local/ssl/include/openssl/opensslv.h" 2>/dev/null | head -1 | sed 's/.*OpenSSL \([0-9][^ -]*\).*/\1/')
    elif [[ -d "$latest_build/usr/local/lib" ]]; then
        # OpenSSL 3.x (strip any suffix)
        OPENSSL_VERSION=$(grep "OPENSSL_VERSION_TEXT" "$latest_build/usr/local/include/openssl/opensslv.h" 2>/dev/null | head -1 | sed 's/.*OpenSSL \([0-9][^ -]*\).*/\1/')
    fi
    
    if [[ -z "$OPENSSL_VERSION" ]]; then
        log_error "Could not detect OpenSSL version from build directory"
        log_error "Please specify the version manually or rebuild"
        return 1
    fi
    
    log_info "Detected OpenSSL version: $OPENSSL_VERSION"
    
    # Check if MarkLogic directory is provided
    if [[ -z "$ML_DIR" ]]; then
        log_error "MarkLogic directory not specified"
        log_error "Usage: $0 --copy-only [work_directory] <marklogic_directory>"
        return 1
    fi
    
    # Set INSTALL_DIR to the latest build and copy
    INSTALL_DIR="$latest_build"
    
    log_info "Copying from: $INSTALL_DIR"
    log_info "Copying to: $ML_DIR/3rdParty/openssl/$OPENSSL_VERSION"
    
    # Call the copy function
    copy_to_marklogic
    
    return $?
}

# Function to detect and choose OpenSSL version
detect_openssl_version() {
    log_info "Detecting OpenSSL version for branch: $TARGET_BRANCH"
    
    cd "$TARBALL_DIR" 2>/dev/null || true  # Don't fail if directory doesn't exist yet
    
    # Look for existing tar files matching the major version
    local pattern=""
    if [[ "$TARGET_BRANCH" == "develop-11" ]]; then
        pattern="openssl-1.0.2*.tar.gz"
    else
        pattern="openssl-3*.tar.gz"
    fi
    
    # Find the latest version from existing tar files
    local latest_tar=""
    if ls $pattern 1> /dev/null 2>&1; then
        # Get the latest tar file (sort by version)
        latest_tar=$(ls $pattern | sort -V | tail -1)
        # Extract version from filename
        OPENSSL_VERSION=$(echo "$latest_tar" | sed 's/openssl-\(.*\)\.tar\.gz/\1/')
        log_info "Found existing tar file: $latest_tar"
        log_info "Using OpenSSL version: $OPENSSL_VERSION"
    else
        # Use default version
        OPENSSL_VERSION="$DEFAULT_OPENSSL_VERSION"
        log_info "No existing tar files found, using default: $OPENSSL_VERSION"
    fi
    
    cd - > /dev/null
}

# Function to check if required tools are available
check_prerequisites() {
    log_info "Checking prerequisites..."
    
    if [[ ! -f "$CC_PATH" ]]; then
        log_error "GCC compiler not found at $CC_PATH"
        log_error "Please ensure gcc-toolset-12 is installed and available"
        return 1
    fi
    
    for tool in git tar make; do
        if ! command -v "$tool" &> /dev/null; then
            log_error "$tool is not installed or not in PATH"
            return 1
        fi
    done
    
    log_info "Prerequisites check passed"
    return 0
}

# Function to setup or update OpenSSL repository
setup_openssl_repo() {
    log_info "Setting up OpenSSL repository..."
    
    # Check if we're already in the openssl directory
    local current_dir=$(basename "$(pwd)")
    local parent_dir=$(basename "$(dirname "$(pwd)")")
    
    if [[ "$current_dir" == "openssl" ]] && [[ -d ".git" ]]; then
        log_info "Already in openssl directory, updating repository..."
        
        # Fetch latest changes and rebase
        log_info "Fetching latest changes..."
        if ! git fetch origin; then
            log_error "Failed to fetch from origin"
            return 1
        fi
        
        # Get current branch
        current_branch=$(git rev-parse --abbrev-ref HEAD)
        log_info "Current branch: $current_branch"
        
        # Rebase current branch
        log_info "Rebasing $current_branch..."
        if ! git rebase origin/$current_branch; then
            log_warn "Rebase failed, you may need to resolve conflicts manually"
            return 1
        fi
        
        # Update OPENSSL_DIR to current directory
        OPENSSL_DIR="$(pwd)"
        INSTALL_DIR="$OPENSSL_DIR/INSTALL_DIR/$BUILD_DATE"
        LOGS_DIR="$OPENSSL_DIR/logs"
        
    else
        # Not in openssl directory, proceed with normal logic
        cd "$WORK_DIR"
        
        if [[ -d "openssl" ]]; then
            log_info "OpenSSL directory exists, updating repository..."
            cd openssl
            
            # Check if it's a valid git repository
            if [[ ! -d ".git" ]]; then
                log_error "openssl directory exists but is not a git repository"
                log_error "Please remove the directory or specify a different work directory"
                return 1
            fi
            
            # Fetch latest changes and rebase
            log_info "Fetching latest changes..."
            if ! git fetch origin; then
                log_error "Failed to fetch from origin"
                return 1
            fi
            
            # Get current branch
            current_branch=$(git rev-parse --abbrev-ref HEAD)
            log_info "Current branch: $current_branch"
            
            # Rebase current branch
            log_info "Rebasing $current_branch..."
            if ! git rebase origin/$current_branch; then
                log_warn "Rebase failed, you may need to resolve conflicts manually"
                return 1
            fi
            
        else
            log_info "Cloning OpenSSL repository..."
            if ! git clone "$OPENSSL_REPO" openssl; then
                log_error "Failed to clone repository"
                return 1
            fi
            cd openssl
        fi
    fi
    
    log_info "OpenSSL repository setup complete"
    return 0
}

# Function to clean up old build directories
cleanup_old_builds() {
    log_info "Cleaning up old extracted build directories..."
    
    cd "$TARBALL_DIR"
    
    # Remove only extracted openssl directories (keep INSTALL_DIR for history)
    for dir in openssl-*/; do
        if [[ -d "$dir" ]]; then
            log_info "Removing old directory: $dir"
            rm -rf "$dir"
        fi
    done
    
    log_info "Cleanup complete"
}

# Function to build FIPS module
build_fips() {
    # Check if --skip-fips flag is set
    # OpenSSL 3.x has built-in FIPS provider, skip external FIPS module build
    if [[ "$OPENSSL_VERSION" == 3.* ]]; then
        log_info "OpenSSL 3.x detected - skipping external FIPS 2.0 module build"
        log_info "OpenSSL 3.x uses built-in FIPS provider (enable-fips)"
        return 0
    fi

    if [[ "$SKIP_FIPS_FLAG" == true ]]; then
        log_info "Skipping FIPS build (--skip-fips flag detected)"
        
        # Look for existing FIPS installation in previous builds
        local install_base="$BUILD_DIR/INSTALL_DIR"
        if [[ ! -d "$install_base" ]]; then
            log_error "No previous builds found in: $install_base"
            log_error "Cannot skip FIPS build without an existing FIPS installation"
            log_error "Please run a full build first without --skip-fips"
            return 1
        fi
        
        # Find the most recent FIPS installation
        local latest_fips_dir=""
        for build_dir in $(ls -1dt "$install_base"/*/ 2>/dev/null); do
            local fips_path="$build_dir/usr/local/ssl/fips-2.0"
            if [[ -d "$fips_path" ]]; then
                latest_fips_dir="$fips_path"
                log_info "Found existing FIPS installation: $fips_path"
                break
            fi
        done
        
        if [[ -z "$latest_fips_dir" ]]; then
            log_error "No existing FIPS installation found in previous builds"
            log_error "Please run a full build first without --skip-fips"
            return 1
        fi
        
        # Copy the existing FIPS installation to the new INSTALL_DIR
        log_info "Copying existing FIPS installation to: $INSTALL_DIR/usr/local/ssl/fips-2.0"
        mkdir -p "$INSTALL_DIR/usr/local/ssl"
        cp -r "$latest_fips_dir" "$INSTALL_DIR/usr/local/ssl/fips-2.0"
        
        if [[ ! -d "$INSTALL_DIR/usr/local/ssl/fips-2.0" ]]; then
            log_error "Failed to copy FIPS installation"
            return 1
        fi
        
        log_info "FIPS installation reused successfully"
        return 0
    fi
    
    log_info "Building OpenSSL FIPS module..."
    
    # Create logs directory if it doesn't exist
    mkdir -p "$LOGS_DIR"
    
    local fips_log="$LOGS_DIR/openssl_fips_${BUILD_DATE}.txt"
    log_info "FIPS build output will be logged to: $fips_log"
    log_info "Looking for FIPS tarball in: $TARBALL_DIR"
    
    cd "$TARBALL_DIR"
    
    if [[ ! -f "openssl-fips-$FIPS_VERSION.tar.gz" ]]; then
        log_error "FIPS tarball not found: $TARBALL_DIR/openssl-fips-$FIPS_VERSION.tar.gz"
        return 1
    fi
    
    if ! tar -xzf "openssl-fips-$FIPS_VERSION.tar.gz" 2>> "$fips_log"; then
        log_error "Failed to extract FIPS tarball"
        return 1
    fi
    
    cd "$TARBALL_DIR/openssl-fips-$FIPS_VERSION"
    
    # Configure FIPS build
    log_info "Configuring FIPS build..."
    if ! CC="$CC_PATH" ./config >> "$fips_log" 2>&1; then
        log_error "FIPS configuration failed. Check log: $fips_log"
        return 1
    fi
    
    # Build FIPS
    log_info "Building FIPS (this may take a while)..."
    if ! make >> "$fips_log" 2>&1; then
        log_error "FIPS build failed. Check log: $fips_log"
        return 1
    fi
    
    # Install FIPS
    log_info "Installing FIPS to $INSTALL_DIR..."
    if ! make install INSTALL_PREFIX="$INSTALL_DIR" >> "$fips_log" 2>&1; then
        log_error "FIPS installation failed. Check log: $fips_log"
        return 1
    fi
    
    log_info "FIPS build complete. Log: $fips_log"
    return 0
}

# Function to build OpenSSL
build_openssl() {
    log_info "Building OpenSSL with FIPS support..."
    
    local openssl_log="$LOGS_DIR/openssl_${BUILD_DATE}.txt"
    log_info "OpenSSL build output will be logged to: $openssl_log"
    log_info "Looking for OpenSSL tarball in: $TARBALL_DIR"
    
    cd "$TARBALL_DIR"
    
    if [[ ! -f "openssl-$OPENSSL_VERSION.tar.gz" ]]; then
        log_error "OpenSSL tarball not found: $TARBALL_DIR/openssl-$OPENSSL_VERSION.tar.gz"
        return 1
    fi
    
    if ! tar -xzf "openssl-$OPENSSL_VERSION.tar.gz" 2>> "$openssl_log"; then
        log_error "Failed to extract OpenSSL tarball"
        return 1
    fi
    
    cd "$TARBALL_DIR/openssl-$OPENSSL_VERSION"
    
    # Configure OpenSSL with FIPS - different options for 1.x vs 3.x
    if [[ "$OPENSSL_VERSION" == 3.* ]]; then
        # OpenSSL 3.x uses built-in FIPS provider
        log_info "Configuring OpenSSL 3.x with built-in FIPS provider..."
        if ! CC="$CC_PATH" ./config enable-fips shared >> "$openssl_log" 2>&1; then
            log_error "OpenSSL configuration failed. Check log: $openssl_log"
            return 1
        fi
    else
        # OpenSSL 1.x uses external FIPS 2.0 module
        local fips_dir="$INSTALL_DIR/usr/local/ssl/fips-2.0"
        log_info "Configuring OpenSSL 1.x with FIPS directory: $fips_dir"
        if ! CC="$CC_PATH" ./config fips shared --with-fipsdir="$fips_dir" >> "$openssl_log" 2>&1; then
            log_error "OpenSSL configuration failed. Check log: $openssl_log"
            return 1
        fi
    fi
    
    # Build OpenSSL
    log_info "Building OpenSSL (this may take a while)..."
    if ! make >> "$openssl_log" 2>&1; then
        log_error "OpenSSL build failed. Check log: $openssl_log"
        return 1
    fi
    
    # Install OpenSSL - use DESTDIR for 3.x, INSTALL_PREFIX for 1.x
    log_info "Installing OpenSSL to $INSTALL_DIR..."
    if [[ "$OPENSSL_VERSION" == 3.* ]]; then
        if ! make install DESTDIR="$INSTALL_DIR" >> "$openssl_log" 2>&1; then
            log_error "OpenSSL installation failed. Check log: $openssl_log"
            return 1
        fi
    else
        if ! make install INSTALL_PREFIX="$INSTALL_DIR" >> "$openssl_log" 2>&1; then
            log_error "OpenSSL installation failed. Check log: $openssl_log"
            return 1
        fi
    fi
    
    log_info "OpenSSL build complete. Log: $openssl_log"
    return 0
}

# Function to copy build artifacts to MarkLogic 3rdParty directory
copy_to_marklogic() {
    log_info "Copying build artifacts to MarkLogic 3rdParty directory..."
    
    if [[ -z "$ML_DIR" ]]; then
        log_info "No MarkLogic directory specified, skipping copy"
        return 0
    fi
    
    if [[ ! -d "$ML_DIR" ]]; then
        log_error "MarkLogic directory does not exist: $ML_DIR"
        return 1
    fi
    
    # Target directory structure
    local ml_3rdparty="$ML_DIR/3rdParty/openssl/$OPENSSL_VERSION"
    
    log_info "Creating directory structure at: $ml_3rdparty"
    
    # Check if there are other OpenSSL versions and warn
    local openssl_base="$ML_DIR/3rdParty/openssl"
    if [[ -d "$openssl_base" ]]; then
        local other_versions=$(ls -d "$openssl_base"/*/ 2>/dev/null | grep -v "$OPENSSL_VERSION" | wc -l)
        if [[ $other_versions -gt 0 ]]; then
            log_warn "Found $other_versions other OpenSSL version(s) in $openssl_base:"
            ls -d "$openssl_base"/*/ 2>/dev/null | grep -v "$OPENSSL_VERSION" | while read -r version_path; do
                echo "      $(basename "$version_path")"
            done
            log_warn "You may want to remove old versions to keep only $OPENSSL_VERSION"
        fi
    fi
    
    # Create base directories
    mkdir -p "$ml_3rdparty"/{include,linux,winnt}
    
    # Create macosx directory only for develop-11
    if [[ "$TARGET_BRANCH" == "develop-11" ]]; then
        mkdir -p "$ml_3rdparty/macosx"
        log_info "Created macosx directory (develop-11 branch)"
    fi
    
    # Copy include headers - check both possible locations
    log_info "Copying include headers..."
    local include_src=""
    if [[ -d "$INSTALL_DIR/usr/local/ssl/include" ]]; then
        include_src="$INSTALL_DIR/usr/local/ssl/include"
    elif [[ -d "$INSTALL_DIR/usr/local/include" ]]; then
        include_src="$INSTALL_DIR/usr/local/include"
    else
        log_error "Include directory not found in:"
        log_error "  $INSTALL_DIR/usr/local/ssl/include"
        log_error "  $INSTALL_DIR/usr/local/include"
        return 1
    fi
    
    cp -r "$include_src" "$ml_3rdparty/"
    log_info "  Headers copied from: $include_src"
    log_info "  Headers copied to: $ml_3rdparty/include"
    
    # Create linux gcc directory and copy libraries - check both possible locations
    local linux_gcc_dir="$ml_3rdparty/linux/x86_64-gcc7.3"
    mkdir -p "$linux_gcc_dir"
    
    log_info "Copying shared libraries (preserving symlinks)..."
    local lib_src=""
    if [[ -d "$INSTALL_DIR/usr/local/ssl/lib" ]]; then
        lib_src="$INSTALL_DIR/usr/local/ssl/lib"
    elif [[ -d "$INSTALL_DIR/usr/local/lib64" ]]; then
        lib_src="$INSTALL_DIR/usr/local/lib64"
    elif [[ -d "$INSTALL_DIR/usr/local/lib" ]]; then
        lib_src="$INSTALL_DIR/usr/local/lib"
    else
        log_error "Library directory not found in:"
        log_error "  $INSTALL_DIR/usr/local/ssl/lib"
        log_error "  $INSTALL_DIR/usr/local/lib64"
        log_error "  $INSTALL_DIR/usr/local/lib"
        return 1
    fi
    
    # Use cp -P to preserve symlinks
    # Count files first to verify
    local so_count=$(ls "$lib_src"/*.so* 2>/dev/null | wc -l)
    if [[ $so_count -gt 0 ]]; then
        cp -P "$lib_src"/*.so* "$linux_gcc_dir/" 2>/dev/null
        log_info "  Libraries copied from: $lib_src"
        log_info "  Libraries copied to: $linux_gcc_dir"
        log_info "  Copied $so_count library file(s)"
    else
        log_warn "  No .so files found in: $lib_src"
    fi
    

    # Copy ossl-modules directory for OpenSSL 3.x (contains fips.so, legacy.so)
    if [[ "$OPENSSL_VERSION" == 3.* ]]; then
        local ossl_modules_src="$lib_src/ossl-modules"
        if [[ -d "$ossl_modules_src" ]]; then
            log_info "Copying ossl-modules directory (OpenSSL 3.x FIPS provider)..."
            mkdir -p "$linux_gcc_dir/ossl-modules"
            cp -P "$ossl_modules_src"/*.so "$linux_gcc_dir/ossl-modules/" 2>/dev/null
            local modules_count=$(ls "$linux_gcc_dir/ossl-modules"/*.so 2>/dev/null | wc -l)
            log_info "  Copied $modules_count module(s) to: $linux_gcc_dir/ossl-modules/"
        else
            log_warn "  ossl-modules directory not found at: $ossl_modules_src"
        fi
    fi
    log_info "Creating GCC version symlinks..."
    cd "$ml_3rdparty/linux"
    
    local symlink_count=0
    for gcc_ver in "${GCC_VERSIONS[@]}"; do
        local symlink_name="x86_64-gcc${gcc_ver}"
        if [[ ! -e "$symlink_name" ]]; then
            ln -s x86_64-gcc7.3 "$symlink_name"
            ((symlink_count++))
        fi
    done
    
    log_info "  Created $symlink_count GCC version symlinks"
    
    # Display summary
    echo ""
    log_info "MarkLogic 3rdParty Structure:"
    echo "  $ml_3rdparty/"
    echo "    ├── include/          (headers)"
    echo "    ├── linux/"
    echo "    │   ├── x86_64-gcc7.3/ (shared libraries)"
    echo "    │   └── x86_64-gcc*.* (symlinks)"
    echo "    ├── winnt/          (empty - for future use)"
    if [[ "$TARGET_BRANCH" == "develop-11" ]]; then
        echo "    └── macosx/           (empty - for future use)"
    else
        echo "    └── winnt/          (empty - for future use)"
    fi
    echo ""
    
    log_info "Copy to MarkLogic 3rdParty complete!"
    
    # Update makefile with new OpenSSL version
    log_info "Updating MarkLogic makefile..."
    local makefile="$ML_DIR/src/linux/makefiles/defs"
    
    if [[ ! -f "$makefile" ]]; then
        log_error "Makefile not found: $makefile"
        return 1
    fi
    
    # Backup the original makefile
    cp "$makefile" "$makefile.bak.$(date +%Y%m%d_%H%M%S)"
    log_info "  Created backup: $makefile.bak.$(date +%Y%m%d_%H%M%S)"
    
    # Update the OPENSSL_VERSION line (handle variable spacing)
    if grep -q "^OPENSSL_VERSION[[:space:]]*=" "$makefile"; then
        # Get the old version for logging
        local old_version=$(grep "^OPENSSL_VERSION[[:space:]]*=" "$makefile" | sed 's/^OPENSSL_VERSION[[:space:]]*=[[:space:]]*//')
        
        # Replace the version (preserve original spacing)
        sed -i "s/^OPENSSL_VERSION[[:space:]]*=.*/OPENSSL_VERSION  = $OPENSSL_VERSION/" "$makefile"
        
        log_info "  Updated OPENSSL_VERSION in makefile"
        log_info "    Old version: $old_version"
        log_info "    New version: $OPENSSL_VERSION"
    else
        log_warn "  OPENSSL_VERSION line not found in makefile"
        log_warn "  You may need to manually add: OPENSSL_VERSION  = $OPENSSL_VERSION"
    fi
    
    # Change to MarkLogic directory
    cd "$ML_DIR"
    log_info "Changed to MarkLogic directory: $(pwd)"
    
    return 0
}

# Function to prompt user to build MarkLogic
prompt_build_marklogic() {
    if [[ -z "$ML_DIR" ]]; then
        return 1  # Don't build if no ML_DIR
    fi
    
    # If --build-ml flag is set, automatically build without prompting
    if [[ "$BUILD_ML_FLAG" == true ]]; then
        log_info "Auto-building MarkLogic (--build-ml flag detected)"
        return 0
    fi
    
    echo ""
    log_info "OpenSSL files have been copied to MarkLogic 3rdParty directory"
    read -p "Do you want to build MarkLogic to test the integration? (y/N): " -n 1 -r
    echo
    
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        return 0  # User wants to build
    else
        log_info "Skipping MarkLogic build"
        return 1  # User doesn't want to build
    fi
}

# Function to build MarkLogic as a test
build_marklogic_test() {
    log_info "Building MarkLogic to test OpenSSL integration..."
    
    if [[ -z "$ML_DIR" ]]; then
        log_info "No MarkLogic directory specified, skipping build test"
        return 0
    fi
    
    if [[ ! -d "$ML_DIR" ]]; then
        log_error "MarkLogic directory does not exist: $ML_DIR"
        return 1
    fi
    
    # Change to MarkLogic src directory for building
    local ml_src_dir="$ML_DIR/src"
    if [[ ! -d "$ml_src_dir" ]]; then
        log_error "MarkLogic src directory does not exist: $ml_src_dir"
        return 1
    fi
    
    cd "$ml_src_dir"
    log_info "Changed to MarkLogic src directory: $(pwd)"
    
    # Check if Makefile exists
    if [[ ! -f "Makefile" ]]; then
        log_error "Makefile not found in MarkLogic src directory"
        log_error "Please ensure you're in the correct MarkLogic source directory"
        return 1
    fi
    
    # Create build log
    local build_log="$LOGS_DIR/marklogic_build_${BUILD_DATE}.txt"
    log_info "MarkLogic build output will be logged to: $build_log"
    
    echo ""
    log_warn "Build started at: $(date)"
    
    # Step 1: make clean
    log_info "Step 1/4: Running 'make clean'..."
    if ! make clean >> "$build_log" 2>&1; then
        log_error "make clean failed!"
        log_error "Check log for details: $build_log"
        return 1
    fi
    
    # Step 2: make keyed
    log_info "Step 2/4: Running 'make keyed'..."
    if ! make keyed >> "$build_log" 2>&1; then
        log_error "make keyed failed!"
        log_error "Check log for details: $build_log"
        echo ""
        log_info "Showing last 50 lines of build log:"
        tail -n 50 "$build_log"
        return 1
    fi
    
    # Step 3: make optimize
    log_info "Step 3/4: Running 'make optimize'..."
    if ! make optimize >> "$build_log" 2>&1; then
        log_error "make optimize failed!"
        log_error "Check log for details: $build_log"
        echo ""
        log_info "Showing last 50 lines of build log:"
        tail -n 50 "$build_log"
        return 1
    fi
    
    # Step 4: make -j8
    log_info "Step 4/4: Running 'make -j8' (this may take a while)..."
    if ! make -j8 >> "$build_log" 2>&1; then
        log_error "make -j8 failed!"
        log_error "Build failed at: $(date)"
        log_error "Check log for details: $build_log"
        echo ""
        log_info "Showing last 50 lines of build log:"
        tail -n 50 "$build_log"
        return 1
    fi
    
    log_info "MarkLogic build completed successfully!"
    log_info "Build finished at: $(date)"
    echo ""
    log_info "Verifying OpenSSL linkage in MarkLogic binary..."
    
    # Check if the MarkLogic binary exists and verify OpenSSL linking
    local ml_binary="bin/MarkLogic"
    if [[ -f "$ml_binary" ]]; then
        log_info "MarkLogic binary found at: $ml_binary"
        
        # Use ldd to check which OpenSSL libraries are linked
        log_info "OpenSSL library dependencies:"
        if ldd "$ml_binary" | grep -i ssl; then
            log_info "OpenSSL libraries are properly linked"
        else
            log_warn "No OpenSSL libraries found in binary dependencies"
        fi
        echo ""
    else
        log_warn "MarkLogic binary not found at: $ml_binary"
    fi
    
    log_info "Build test complete! Check log for details: $build_log"
    return 0
}

# Function to display build summary
display_summary() {
    log_info "Build Summary:"
    echo "======================================"
    echo "Work Directory: $WORK_DIR"
    echo "OpenSSL/Tarball Directory: $OPENSSL_DIR"
    echo "Build Directory: $BUILD_DIR"
    echo "Install Directory: $INSTALL_DIR"
    echo "Logs Directory: $LOGS_DIR"
    echo "FIPS Version: $FIPS_VERSION"
    echo "OpenSSL Version: $OPENSSL_VERSION"
    echo "Build Date: $BUILD_DATE"
    echo "======================================"
    
    if [[ -d "$INSTALL_DIR/usr/local/ssl" ]]; then
        log_info "Build artifacts are available at:"
        echo "  Headers: $INSTALL_DIR/usr/local/ssl/include"
        echo "  Libraries: $INSTALL_DIR/usr/local/ssl/lib"
        echo ""
        log_info "Build logs are available at:"
        echo "  FIPS Log: $LOGS_DIR/openssl_fips_${BUILD_DATE}.txt"
        echo "  OpenSSL Log: $LOGS_DIR/openssl_${BUILD_DATE}.txt"
        echo ""
        log_info "Next steps:"
        echo "  Copy headers and shared libraries from the installed location"
        echo "  to dist/linux/x86_64-gccX.Y as needed"
    elif [[ -d "$INSTALL_DIR/usr/local" ]]; then
        log_info "Build artifacts are available at:"
        echo "  Headers: $INSTALL_DIR/usr/local/include"
        echo "  Libraries: $INSTALL_DIR/usr/local/lib"
        echo ""
        log_info "Build logs are available at:"
        echo "  FIPS Log: $LOGS_DIR/openssl_fips_${BUILD_DATE}.txt"
        echo "  OpenSSL Log: $LOGS_DIR/openssl_${BUILD_DATE}.txt"
        echo ""
        log_info "Next steps:"
        echo "  Copy headers and shared libraries from the installed location"
        echo "  to dist/linux/x86_64-gccX.Y as needed"
    else
        log_error "Build artifacts not found. Build may have failed."
        log_error "Check the log files in $LOGS_DIR for details"
    fi
}

# Main execution
main() {
    # Handle help parameter
    if [[ "$1" == "-h" ]] || [[ "$1" == "--help" ]]; then
        show_help
        return 0
    fi
    
    # Handle build-ml parameter
    if [[ "$1" == "--build-ml" ]]; then
        BUILD_ML_FLAG=true
        shift
        TARGET_BRANCH="${1:-develop}"
        WORK_DIR="${2:-$(pwd)}"
        ML_DIR="${3:-}"
    fi
    
    # Handle skip-fips parameter
    if [[ "$1" == "--skip-fips" ]]; then
        SKIP_FIPS_FLAG=true
        shift
        TARGET_BRANCH="${1:-develop}"
        WORK_DIR="${2:-$(pwd)}"
        ML_DIR="${3:-}"
    fi
    
    # Handle clean parameter
    if [[ "$1" == "--clean" ]]; then
        # Shift parameters to get optional work_dir and ml_dir
        shift
        WORK_DIR="${1:-$(pwd)}"
        ML_DIR="${2:-}"
        
        # Convert WORK_DIR to absolute path
        WORK_DIR="$(cd "$WORK_DIR" && pwd)"
        
        # Set up directories
        if [[ "$(basename "$(pwd)")" == "openssl" ]] && ls openssl-*.tar.gz 1> /dev/null 2>&1; then
            OPENSSL_DIR="$(pwd)"
            BUILD_DIR="$(pwd)"
        else
            OPENSSL_DIR="$WORK_DIR/openssl"
            BUILD_DIR="$OPENSSL_DIR"
        fi
        
        clean_all
        return $?
    fi
    
    # Handle copy-only parameter
    if [[ "$1" == "--copy-only" ]]; then
        # Shift parameters to get work_dir and ml_dir
        shift
        WORK_DIR="${1:-$(pwd)}"
        ML_DIR="${2:-}"
        
        # Convert WORK_DIR to absolute path
        WORK_DIR="$(cd "$WORK_DIR" && pwd)"
        
        # Set up directories
        if [[ "$(basename "$(pwd)")" == "openssl" ]] && ls openssl-*.tar.gz 1> /dev/null 2>&1; then
            OPENSSL_DIR="$(pwd)"
            BUILD_DIR="$(pwd)"
        else
            OPENSSL_DIR="$WORK_DIR/openssl"
            BUILD_DIR="$OPENSSL_DIR"
        fi
        
        copy_only
        return $?
    fi
    
    log_info "Starting OpenSSL build automation..."
    log_info "Target branch: $TARGET_BRANCH"
    log_info "Work directory: $WORK_DIR"
    
    # Track build status
    local build_success=true
    local error_message=""
    
    # Create work directory if it doesn't exist
    mkdir -p "$WORK_DIR"
    
    # Run build steps with error handling
    if ! check_prerequisites; then
        error_message="Prerequisites check failed"
        build_success=false
    elif ! setup_openssl_repo; then
        error_message="Failed to setup OpenSSL repository"
        build_success=false
    elif ! detect_openssl_version; then
        error_message="Failed to detect OpenSSL version"
        build_success=false
    else
        log_info "Building OpenSSL version: $OPENSSL_VERSION"
        
        if ! cleanup_old_builds; then
            error_message="Failed to cleanup old builds"
            build_success=false
        elif ! build_fips; then
            error_message="FIPS build failed"
            build_success=false
        elif ! build_openssl; then
            error_message="OpenSSL build failed"
            build_success=false
        elif ! copy_to_marklogic; then
            error_message="Failed to copy to MarkLogic 3rdParty directory"
            build_success=false
        elif [[ -n "$ML_DIR" ]] && prompt_build_marklogic && ! build_marklogic_test; then
            error_message="MarkLogic build test failed"
            build_success=false
        fi
    fi
    
    # Display results
    if [[ "$build_success" == true ]]; then
        display_summary
        log_info "OpenSSL build automation completed successfully!"
        
        # Navigate to MarkLogic directory if specified, otherwise to install directory
        if [[ -n "$ML_DIR" ]] && [[ -d "$ML_DIR" ]]; then
            cd "$ML_DIR"
            log_info "Current directory: $(pwd)"
        elif [[ -d "$INSTALL_DIR/usr/local" ]]; then
            cd "$INSTALL_DIR/usr/local/ssl"
            log_info "Current directory: $(pwd)"
        else
            cd "$OPENSSL_DIR"
            log_info "Current directory: $(pwd)"
        fi
    else
        log_error "Build failed: $error_message"
        log_error "Check the log files in $LOGS_DIR for details"
        
        # Navigate to MarkLogic directory if specified and exists, otherwise openssl directory
        if [[ -n "$ML_DIR" ]] && [[ -d "$ML_DIR" ]]; then
            cd "$ML_DIR"
            log_info "Current directory: $(pwd)"
        elif [[ -d "$OPENSSL_DIR" ]]; then
            cd "$OPENSSL_DIR"
            log_info "Current directory: $(pwd)"
        fi
        
        return 1
    fi
}

# Run main function with all arguments
main "$@"
