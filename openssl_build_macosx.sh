#!/bin/bash

# OpenSSL Build Automation Script for macOS
# This script automates the process of building OpenSSL with FIPS support on macOS
# Usage: ./openssl_build_macosx.sh [branch] [work_directory] [marklogic_directory]
# Example: ./openssl_build_macosx.sh develop-11 /path/to/work/dir /Users/xu/code/xdmp

# Don't exit on error - we'll handle errors gracefully
set +e

# Configuration
OPENSSL_REPO="https://github.bedford.progress.com/marklogic-platform/openssl.git"
FIPS_VERSION="2.0.5"

# Parse command line arguments
# Note: These are defaults, will be overridden in main() when flags are processed
WORK_DIR="${1:-$(pwd)}"             # Default work directory is current directory
ML_DIR="${2:-}"                      # MarkLogic directory (optional)
BUILD_ML_FLAG=false                  # Flag to automatically build MarkLogic
SKIP_FIPS_FLAG=false                 # Flag to skip FIPS build and use existing installation
SKIP_OPENSSL_FLAG=false              # Flag to skip OpenSSL build and use existing installation
SKIP_DYLIB_FIX_FLAG=false            # Flag to skip fixing dynamic library paths
NO_UPDATE_FLAG=false                 # Flag to skip git fetch/rebase

# Don't convert WORK_DIR to absolute path here - do it in main() after parsing flags

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

# OpenSSL version settings (macOS only builds 1.0.2.x for develop-11)
OPENSSL_MAJOR_VERSION="1.0.2"
DEFAULT_OPENSSL_VERSION="1.0.2zm"  # Current latest 1.x version

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
    echo "OpenSSL Build Automation Script for macOS (OpenSSL 1.0.2.x only)"
    echo ""
    echo "Usage: $0 [flags] [work_directory] [marklogic_directory]"
    echo ""
    echo "Note: macOS builds only support OpenSSL 1.0.2.x (develop-11 branch)"
    echo ""
    echo "Flags:"
    echo "  --skip-fips           Skip FIPS build and use existing FIPS installation from previous build"
    echo "  --skip-openssl        Skip OpenSSL build and use existing OpenSSL installation from previous build"
    echo "  --skip-dylib-fix      Skip fixing dynamic library paths (use if already fixed)"
    echo "  --no-update           Skip git fetch/rebase (use existing repo state without updating)"
    echo "  --build-ml            Automatically build MarkLogic after copying OpenSSL files (skips prompt)"
    echo ""
    echo "Parameters:"
    echo "  work_directory        Directory to perform build in (default: current directory)"
    echo "  marklogic_directory   Path to MarkLogic directory (e.g., /space/xu/code/xdmp)"
    echo "                        If provided, will copy build artifacts to 3rdParty/openssl/"
    echo ""
    echo "Examples:"
    echo "  $0                                      # Build OpenSSL 1.0.2.x in current directory"
    echo "  $0 . /space/xu/code/xdmp               # Build and copy to MarkLogic 3rdParty"
    echo "  $0 --no-update .                        # Build without updating git repo"
    echo "  $0 --skip-fips .                        # Rebuild OpenSSL without rebuilding FIPS"
    echo "  $0 --skip-fips --skip-openssl .         # Skip both builds, just fix dylib paths"
    echo "  $0 --skip-fips --skip-openssl --skip-dylib-fix . /space/xu/code/xdmp"
    echo "                                          # Skip all builds, just copy to MarkLogic"
    echo ""
    echo "The script will:"
    echo "  1. Clone/update OpenSSL repository"
    echo "  2. Find latest OpenSSL 1.0.2.x tarball (defaults to $DEFAULT_OPENSSL_VERSION)"
    echo "  3. Build FIPS $FIPS_VERSION"
    echo "  4. Build OpenSSL with FIPS support"
    echo "  5. Fix dynamic library paths with install_name_tool"
    echo "  6. Install to ./openssl/INSTALL_DIR/{timestamp}"
    echo "  7. (Optional) Copy artifacts to MarkLogic 3rdParty directory"
    echo ""
    echo "macOS Specific Notes:"
    echo "  - Only builds OpenSSL 1.0.2.x (for develop-11 branch)"
    echo "  - Uses system clang compiler (darwin64-x86_64-cc)"
    echo "  - Creates .dylib files (not .so files)"
    echo "  - Fixes library paths with install_name_tool for @executable_path"
    echo "  - Copies to macosx/x86_64-gcc4.2/ directory in MarkLogic 3rdParty"
}

# Function to setup or update OpenSSL repository
setup_openssl_repo() {
    log_info "=========================================="
    log_info "Setting up OpenSSL repository..."
    log_info "=========================================="
    log_info "Current directory: $(pwd)"
    
    if [[ "$NO_UPDATE_FLAG" == true ]]; then
        log_info "  -> --no-update flag set, skipping git fetch/rebase"
    fi
    
    # Check if we're already in the openssl git repo
    log_info "Checking if current directory is a git repository..."
    if [[ -d ".git" ]]; then
        log_info "  -> Found .git directory"
        
        # Verify it's the openssl repo by checking remote URL
        local remote_url=$(git remote get-url origin 2>/dev/null)
        log_info "  -> Remote URL: $remote_url"
        
        if [[ "$remote_url" == *"openssl"* ]]; then
            log_info "  -> Confirmed: This is the OpenSSL repository"
            
            # Skip update if --no-update flag is set
            if [[ "$NO_UPDATE_FLAG" == true ]]; then
                log_info ""
                log_info "Skipping repository update (--no-update flag)"
                local current_branch=$(git rev-parse --abbrev-ref HEAD)
                log_info "  -> Current branch: $current_branch"
            else
                log_info ""
                log_info "Updating existing repository..."
                
                # Fetch latest changes
                log_info "  Step 1: Fetching latest changes..."
                if ! git fetch origin; then
                    log_error "Failed to fetch from origin"
                    return 1
                fi
                log_info "  -> Fetch complete"
                
                # Get current branch
                local current_branch=$(git rev-parse --abbrev-ref HEAD)
                log_info "  Step 2: Current branch is '$current_branch'"
                
                # Rebase current branch
                log_info "  Step 3: Rebasing $current_branch onto origin/$current_branch..."
                if ! git rebase origin/$current_branch; then
                    log_warn "Rebase failed, you may need to resolve conflicts manually"
                    return 1
                fi
                log_info "  -> Rebase complete"
            fi
            
            # Update directory variables to current location
            OPENSSL_DIR="$(pwd)"
            TARBALL_DIR="$OPENSSL_DIR"
            BUILD_DIR="$OPENSSL_DIR"
            INSTALL_DIR="$BUILD_DIR/INSTALL_DIR/$BUILD_DATE"
            LOGS_DIR="$BUILD_DIR/logs"
            
            log_info ""
            log_info "Directory variables updated:"
            log_info "  OPENSSL_DIR: $OPENSSL_DIR"
            log_info "  INSTALL_DIR: $INSTALL_DIR"
            log_info "  LOGS_DIR:    $LOGS_DIR"
            log_info ""
            log_info "OpenSSL repository ready!"
            return 0
        else
            log_info "  -> This is a git repo but NOT the OpenSSL repository"
        fi
    else
        log_info "  -> No .git directory found"
    fi
    
    # Check if current directory has an openssl subdirectory with git repo
    log_info ""
    log_info "Checking for 'openssl' subdirectory..."
    if [[ -d "openssl/.git" ]]; then
        log_info "  -> Found openssl/.git directory"
        log_info "  -> Changing into openssl directory..."
        cd openssl
        log_info "  -> Now in: $(pwd)"
        
        # Verify it's the openssl repo
        local remote_url=$(git remote get-url origin 2>/dev/null)
        log_info "  -> Remote URL: $remote_url"
        
        if [[ "$remote_url" == *"openssl"* ]]; then
            log_info "  -> Confirmed: This is the OpenSSL repository"
            
            # Skip update if --no-update flag is set
            if [[ "$NO_UPDATE_FLAG" == true ]]; then
                log_info ""
                log_info "Skipping repository update (--no-update flag)"
                local current_branch=$(git rev-parse --abbrev-ref HEAD)
                log_info "  -> Current branch: $current_branch"
            else
                log_info ""
                log_info "Updating existing repository..."
                
                # Fetch latest changes
                log_info "  Step 1: Fetching latest changes..."
                if ! git fetch origin; then
                    log_error "Failed to fetch from origin"
                    return 1
                fi
                log_info "  -> Fetch complete"
                
                # Get current branch
                local current_branch=$(git rev-parse --abbrev-ref HEAD)
                log_info "  Step 2: Current branch is '$current_branch'"
                
                # Rebase current branch
                log_info "  Step 3: Rebasing $current_branch onto origin/$current_branch..."
                if ! git rebase origin/$current_branch; then
                    log_warn "Rebase failed, you may need to resolve conflicts manually"
                    return 1
                fi
                log_info "  -> Rebase complete"
            fi
            
            # Update directory variables
            OPENSSL_DIR="$(pwd)"
            TARBALL_DIR="$OPENSSL_DIR"
            BUILD_DIR="$OPENSSL_DIR"
            INSTALL_DIR="$BUILD_DIR/INSTALL_DIR/$BUILD_DATE"
            LOGS_DIR="$BUILD_DIR/logs"
            
            log_info ""
            log_info "Directory variables updated:"
            log_info "  OPENSSL_DIR: $OPENSSL_DIR"
            log_info "  INSTALL_DIR: $INSTALL_DIR"
            log_info "  LOGS_DIR:    $LOGS_DIR"
            log_info ""
            log_info "OpenSSL repository ready!"
            return 0
        else
            log_error "openssl directory exists but is not the expected repository"
            return 1
        fi
    else
        log_info "  -> No openssl subdirectory found"
    fi
    
    # No existing repo found, need to clone
    if [[ "$NO_UPDATE_FLAG" == true ]]; then
        log_error "No OpenSSL repository found and --no-update flag is set"
        log_error "Cannot clone repository with --no-update flag"
        log_error "Please clone the repository manually or run without --no-update"
        return 1
    fi
    
    log_info ""
    log_info "No OpenSSL repository found, need to clone..."
    log_info "  Repository URL: $OPENSSL_REPO"
    log_info "  Cloning into 'openssl' directory..."
    
    if ! git clone "$OPENSSL_REPO" openssl; then
        log_error "Failed to clone OpenSSL repository"
        return 1
    fi
    log_info "  -> Clone complete"
    
    log_info "  -> Changing into openssl directory..."
    cd openssl
    log_info "  -> Now in: $(pwd)"
    
    # Update directory variables
    OPENSSL_DIR="$(pwd)"
    TARBALL_DIR="$OPENSSL_DIR"
    BUILD_DIR="$OPENSSL_DIR"
    INSTALL_DIR="$BUILD_DIR/INSTALL_DIR/$BUILD_DATE"
    LOGS_DIR="$BUILD_DIR/logs"
    
    log_info ""
    log_info "Directory variables set:"
    log_info "  OPENSSL_DIR: $OPENSSL_DIR"
    log_info "  INSTALL_DIR: $INSTALL_DIR"
    log_info "  LOGS_DIR:    $LOGS_DIR"
    log_info ""
    log_info "OpenSSL repository cloned successfully!"
    return 0
}

# Function to detect and choose OpenSSL version
detect_openssl_version() {
    log_info "=========================================="
    log_info "Detecting OpenSSL version..."
    log_info "=========================================="
    
    cd "$TARBALL_DIR" 2>/dev/null || true
    
    # Look for OpenSSL 1.0.2.x tarballs (only version supported on macOS)
    local pattern="openssl-1.0.2*.tar.gz"
    log_info "Looking for OpenSSL 1.0.2.x tarballs..."
    
    # Find the latest version from existing tar files
    # Note: macOS sort doesn't support -V, so we use a different approach
    local latest_tar=""
    if ls $pattern 1> /dev/null 2>&1; then
        # Get the last one alphabetically (works for version numbers like 1.0.2za, 1.0.2zb, etc.)
        latest_tar=$(ls -1 $pattern 2>/dev/null | tail -1)
        OPENSSL_VERSION=$(echo "$latest_tar" | sed 's/openssl-\(.*\)\.tar\.gz/\1/')
        log_info "  -> Found existing tar file: $latest_tar"
        log_info "  -> Using OpenSSL version: $OPENSSL_VERSION"
    else
        OPENSSL_VERSION="$DEFAULT_OPENSSL_VERSION"
        log_info "  -> No existing tar files found"
        log_info "  -> Using default version: $OPENSSL_VERSION"
    fi
    
    log_info ""
    return 0
}

# Function to build FIPS module
build_fips() {
    log_info "=========================================="
    log_info "Building OpenSSL FIPS module..."
    log_info "=========================================="
    
    # Check if --skip-fips flag is set
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
                log_info "  -> Found existing FIPS installation: $fips_path"
                break
            fi
        done
        
        if [[ -z "$latest_fips_dir" ]]; then
            log_error "No existing FIPS installation found in previous builds"
            log_error "Please run a full build first without --skip-fips"
            return 1
        fi
        
        # Copy the existing FIPS installation to the new INSTALL_DIR
        log_info "  -> Copying existing FIPS to: $INSTALL_DIR/usr/local/ssl/fips-2.0"
        mkdir -p "$INSTALL_DIR/usr/local/ssl"
        cp -r "$latest_fips_dir" "$INSTALL_DIR/usr/local/ssl/fips-2.0"
        
        if [[ ! -d "$INSTALL_DIR/usr/local/ssl/fips-2.0" ]]; then
            log_error "Failed to copy FIPS installation"
            return 1
        fi
        
        log_info "  -> FIPS installation reused successfully!"
        return 0
    fi
    
    # Create logs directory if it doesn't exist
    mkdir -p "$LOGS_DIR"
    
    local fips_log="$LOGS_DIR/fips_build_${BUILD_DATE}.txt"
    log_info "FIPS build log: $fips_log"
    log_info ""
    
    cd "$TARBALL_DIR"
    log_info "Working directory: $(pwd)"
    
    # Check for FIPS tarball
    local fips_tarball="openssl-fips-$FIPS_VERSION.tar.gz"
    if [[ ! -f "$fips_tarball" ]]; then
        log_error "FIPS tarball not found: $fips_tarball"
        return 1
    fi
    log_info "  -> Found FIPS tarball: $fips_tarball"
    
    # Extract FIPS tarball
    log_info ""
    log_info "Step 1: Extracting FIPS tarball..."
    if ! tar xzf "$fips_tarball" >> "$fips_log" 2>&1; then
        log_error "Failed to extract FIPS tarball"
        return 1
    fi
    log_info "  -> Extraction complete"
    
    # Change to FIPS directory
    cd "openssl-fips-$FIPS_VERSION"
    log_info "  -> Changed to: $(pwd)"
    
    # Configure FIPS for macOS
    log_info ""
    log_info "Step 2: Configuring FIPS for macOS (darwin64-x86_64-cc)..."
    if ! ./Configure darwin64-x86_64-cc >> "$fips_log" 2>&1; then
        log_error "FIPS configuration failed. Check log: $fips_log"
        return 1
    fi
    log_info "  -> Configuration complete"
    
    # Build FIPS
    log_info ""
    log_info "Step 3: Building FIPS (this may take a while)..."
    if ! make >> "$fips_log" 2>&1; then
        log_error "FIPS build failed. Check log: $fips_log"
        return 1
    fi
    log_info "  -> Build complete"
    
    # Install FIPS
    log_info ""
    log_info "Step 4: Installing FIPS to $INSTALL_DIR..."
    mkdir -p "$INSTALL_DIR"
    if ! make install INSTALL_PREFIX="$INSTALL_DIR" >> "$fips_log" 2>&1; then
        log_error "FIPS installation failed. Check log: $fips_log"
        return 1
    fi
    log_info "  -> Installation complete"
    
    # Go back to tarball directory
    cd "$TARBALL_DIR"
    
    log_info ""
    log_info "FIPS build completed successfully!"
    log_info "FIPS installed to: $INSTALL_DIR/usr/local/ssl/fips-2.0"
    return 0
}

# Function to build OpenSSL
build_openssl() {
    log_info "=========================================="
    log_info "Building OpenSSL with FIPS support..."
    log_info "=========================================="
    
    # Check if --skip-openssl flag is set
    if [[ "$SKIP_OPENSSL_FLAG" == true ]]; then
        log_info "Skipping OpenSSL build (--skip-openssl flag detected)"
        
        # Look for existing OpenSSL installation in previous builds
        local install_base="$BUILD_DIR/INSTALL_DIR"
        if [[ ! -d "$install_base" ]]; then
            log_error "No previous builds found in: $install_base"
            log_error "Cannot skip OpenSSL build without an existing installation"
            log_error "Please run a full build first without --skip-openssl"
            return 1
        fi
        
        # Find the most recent OpenSSL installation
        local latest_ssl_dir=""
        for build_dir in $(ls -1dt "$install_base"/*/ 2>/dev/null); do
            # Remove trailing slash from build_dir
            build_dir="${build_dir%/}"
            local ssl_path="$build_dir/usr/local/ssl"
            if [[ -d "$ssl_path/lib" ]] && [[ -d "$ssl_path/include" ]]; then
                latest_ssl_dir="$ssl_path"
                log_info "  -> Found existing OpenSSL installation: $ssl_path"
                break
            fi
        done
        
        if [[ -z "$latest_ssl_dir" ]]; then
            log_error "No existing OpenSSL installation found in previous builds"
            log_error "Please run a full build first without --skip-openssl"
            return 1
        fi
        
        # Copy the existing OpenSSL installation to the new INSTALL_DIR
        log_info "  -> Copying existing OpenSSL to: $INSTALL_DIR/usr/local/ssl"
        
        # Create the target directory
        mkdir -p "$INSTALL_DIR/usr/local/ssl"
        
        # Copy contents of source directory to target, excluding fips-2.0 (already handled by FIPS step)
        # Use rsync if available, otherwise use a loop with cp
        if command -v rsync &> /dev/null; then
            if ! rsync -a --exclude='fips-2.0' "$latest_ssl_dir/" "$INSTALL_DIR/usr/local/ssl/"; then
                log_error "rsync command failed"
                return 1
            fi
        else
            # Fallback: copy each item except fips-2.0
            for item in "$latest_ssl_dir"/*; do
                local basename=$(basename "$item")
                if [[ "$basename" != "fips-2.0" ]]; then
                    if ! cp -R "$item" "$INSTALL_DIR/usr/local/ssl/"; then
                        log_error "cp command failed for $basename"
                        return 1
                    fi
                fi
            done
        fi
        
        # Verify the copy worked
        if [[ ! -d "$INSTALL_DIR/usr/local/ssl/lib" ]]; then
            log_error "Failed to copy OpenSSL installation - lib directory missing"
            return 1
        fi
        
        log_info "  -> OpenSSL installation reused successfully!"
        return 0
    fi
    
    local openssl_log="$LOGS_DIR/openssl_build_${BUILD_DATE}.txt"
    log_info "OpenSSL build log: $openssl_log"
    log_info ""
    
    cd "$TARBALL_DIR"
    log_info "Working directory: $(pwd)"
    
    # Check for OpenSSL tarball
    local openssl_tarball="openssl-$OPENSSL_VERSION.tar.gz"
    if [[ ! -f "$openssl_tarball" ]]; then
        log_error "OpenSSL tarball not found: $openssl_tarball"
        return 1
    fi
    log_info "  -> Found OpenSSL tarball: $openssl_tarball"
    
    # Extract OpenSSL tarball
    log_info ""
    log_info "Step 1: Extracting OpenSSL tarball..."
    if ! tar xzf "$openssl_tarball" >> "$openssl_log" 2>&1; then
        log_error "Failed to extract OpenSSL tarball"
        return 1
    fi
    log_info "  -> Extraction complete"
    
    # Change to OpenSSL directory
    cd "openssl-$OPENSSL_VERSION"
    log_info "  -> Changed to: $(pwd)"
    
    # Configure OpenSSL for macOS with FIPS
    local fips_dir="$INSTALL_DIR/usr/local/ssl/fips-2.0"
    log_info ""
    log_info "Step 2: Configuring OpenSSL for macOS with FIPS support..."
    log_info "  -> FIPS directory: $fips_dir"
    log_info "  -> Running: ./Configure darwin64-x86_64-cc fips shared --with-fipsdir=$fips_dir"
    
    if ! ./Configure darwin64-x86_64-cc fips shared --with-fipsdir="$fips_dir" >> "$openssl_log" 2>&1; then
        log_error "OpenSSL configuration failed. Check log: $openssl_log"
        return 1
    fi
    log_info "  -> Configuration complete"
    
    # Build OpenSSL
    log_info ""
    log_info "Step 3: Building OpenSSL (this may take a while)..."
    if ! make >> "$openssl_log" 2>&1; then
        log_error "OpenSSL build failed. Check log: $openssl_log"
        return 1
    fi
    log_info "  -> Build complete"
    
    # Install OpenSSL
    log_info ""
    log_info "Step 4: Installing OpenSSL to $INSTALL_DIR..."
    if ! make install INSTALL_PREFIX="$INSTALL_DIR" >> "$openssl_log" 2>&1; then
        log_error "OpenSSL installation failed. Check log: $openssl_log"
        return 1
    fi
    log_info "  -> Installation complete"
    
    # Go back to tarball directory
    cd "$TARBALL_DIR"
    
    log_info ""
    log_info "OpenSSL build completed successfully!"
    log_info "OpenSSL installed to: $INSTALL_DIR/usr/local/ssl"
    return 0
}

# Function to fix dynamic library paths for macOS
fix_dylib_paths() {
    log_info "=========================================="
    log_info "Fixing dynamic library paths for macOS..."
    log_info "=========================================="
    
    # Check if --skip-dylib-fix flag is set
    if [[ "$SKIP_DYLIB_FIX_FLAG" == true ]]; then
        log_info "Skipping dylib fix (--skip-dylib-fix flag detected)"
        return 0
    fi
    
    local lib_dir="$INSTALL_DIR/usr/local/ssl/lib"
    
    if [[ ! -d "$lib_dir" ]]; then
        log_error "Library directory not found: $lib_dir"
        return 1
    fi
    
    cd "$lib_dir"
    log_info "Working directory: $(pwd)"
    log_info ""
    
    # Check if dylib files exist
    if [[ ! -f "libcrypto.1.0.0.dylib" ]]; then
        log_error "libcrypto.1.0.0.dylib not found"
        return 1
    fi
    
    if [[ ! -f "libssl.1.0.0.dylib" ]]; then
        log_error "libssl.1.0.0.dylib not found"
        return 1
    fi
    
    # Make dylib files writable (they may be read-only after make install)
    log_info "Making dylib files writable..."
    chmod u+w libcrypto.1.0.0.dylib libssl.1.0.0.dylib
    log_info "  -> Done"
    log_info ""
    
    log_info "Step 1: Fixing libcrypto identity..."
    log_info "  -> install_name_tool -id \"@executable_path/lib/libcrypto.1.0.0.dylib\" libcrypto.1.0.0.dylib"
    if ! install_name_tool -id "@executable_path/lib/libcrypto.1.0.0.dylib" libcrypto.1.0.0.dylib; then
        log_error "Failed to fix libcrypto identity"
        return 1
    fi
    log_info "  -> Done"
    
    log_info ""
    log_info "Step 2: Fixing libssl identity..."
    log_info "  -> install_name_tool -id \"@executable_path/lib/libssl.1.0.0.dylib\" libssl.1.0.0.dylib"
    if ! install_name_tool -id "@executable_path/lib/libssl.1.0.0.dylib" libssl.1.0.0.dylib; then
        log_error "Failed to fix libssl identity"
        return 1
    fi
    log_info "  -> Done"
    
    log_info ""
    log_info "Step 3: Fixing libssl's reference to libcrypto..."
    log_info "  -> install_name_tool -change \"/usr/local/ssl/lib/libcrypto.1.0.0.dylib\" \"@executable_path/lib/libcrypto.1.0.0.dylib\" libssl.1.0.0.dylib"
    if ! install_name_tool -change "/usr/local/ssl/lib/libcrypto.1.0.0.dylib" "@executable_path/lib/libcrypto.1.0.0.dylib" libssl.1.0.0.dylib; then
        log_error "Failed to fix libssl's reference to libcrypto"
        return 1
    fi
    log_info "  -> Done"
    
    log_info ""
    log_info "Verifying library paths..."
    log_info "libcrypto.1.0.0.dylib:"
    otool -L libcrypto.1.0.0.dylib | head -5
    log_info ""
    log_info "libssl.1.0.0.dylib:"
    otool -L libssl.1.0.0.dylib | head -5
    
    log_info ""
    log_info "Dynamic library paths fixed successfully!"
    return 0
}

# Function to copy build artifacts to MarkLogic 3rdParty directory
copy_to_marklogic() {
    log_info "=========================================="
    log_info "Copying build artifacts to MarkLogic..."
    log_info "=========================================="
    
    if [[ -z "$ML_DIR" ]]; then
        log_info "No MarkLogic directory specified, skipping copy"
        return 0
    fi
    
    if [[ ! -d "$ML_DIR" ]]; then
        log_error "MarkLogic directory does not exist: $ML_DIR"
        return 1
    fi
    
    log_info "MarkLogic directory: $ML_DIR"
    log_info "OpenSSL version: $OPENSSL_VERSION"
    
    # Target directory structure
    local ml_openssl_base="$ML_DIR/3rdParty/openssl/$OPENSSL_VERSION"
    local ml_include_dir="$ml_openssl_base/include"
    local ml_macosx_dir="$ml_openssl_base/macosx/x86_64-gcc4.2"
    local ml_linux_dir="$ml_openssl_base/linux"
    local ml_winnt_dir="$ml_openssl_base/winnt"
    
    # Check if version directory exists
    if [[ -d "$ml_openssl_base" ]]; then
        log_info "  -> OpenSSL version directory exists: $ml_openssl_base"
    else
        log_info "  -> Creating OpenSSL version directory structure..."
        
        # Create all required directories
        mkdir -p "$ml_include_dir"
        mkdir -p "$ml_macosx_dir"
        mkdir -p "$ml_linux_dir"
        mkdir -p "$ml_winnt_dir"
        
        log_info "  -> Created directory structure:"
        log_info "       $ml_openssl_base/"
        log_info "       ├── include/"
        log_info "       ├── linux/"
        log_info "       ├── macosx/x86_64-gcc4.2/"
        log_info "       └── winnt/"
    fi
    
    # Ensure all platform directories exist (in case version dir existed but some platforms didn't)
    mkdir -p "$ml_include_dir"
    mkdir -p "$ml_macosx_dir"
    mkdir -p "$ml_linux_dir"
    mkdir -p "$ml_winnt_dir"
    
    # Source directories
    local src_include="$INSTALL_DIR/usr/local/ssl/include"
    local src_lib="$INSTALL_DIR/usr/local/ssl/lib"
    
    # Copy headers to include directory
    log_info ""
    log_info "Step 1: Copying headers to include directory..."
    if [[ ! -d "$src_include" ]]; then
        log_error "Source include directory not found: $src_include"
        return 1
    fi
    
    # Check if include/openssl exists, if so copy contents
    if [[ -d "$src_include/openssl" ]]; then
        # Copy the openssl directory (contains the headers)
        if ! cp -R "$src_include/openssl" "$ml_include_dir/"; then
            log_error "Failed to copy headers"
            return 1
        fi
        log_info "  -> Copied headers to: $ml_include_dir/openssl/"
    else
        # Copy all include contents
        if ! cp -R "$src_include/"* "$ml_include_dir/"; then
            log_error "Failed to copy headers"
            return 1
        fi
        log_info "  -> Copied headers to: $ml_include_dir/"
    fi
    
    # Copy dylib files to macosx directory
    log_info ""
    log_info "Step 2: Copying dylib files to macosx directory..."
    if [[ ! -d "$src_lib" ]]; then
        log_error "Source lib directory not found: $src_lib"
        return 1
    fi
    
    # Copy only the versioned dylib files (the actual libraries, not symlinks)
    # Then recreate the symlinks
    local libcrypto_versioned="libcrypto.1.0.0.dylib"
    local libssl_versioned="libssl.1.0.0.dylib"
    
    if [[ ! -f "$src_lib/$libcrypto_versioned" ]]; then
        log_error "libcrypto versioned file not found: $src_lib/$libcrypto_versioned"
        return 1
    fi
    
    if [[ ! -f "$src_lib/$libssl_versioned" ]]; then
        log_error "libssl versioned file not found: $src_lib/$libssl_versioned"
        return 1
    fi
    
    # Copy the versioned files
    cp "$src_lib/$libcrypto_versioned" "$ml_macosx_dir/"
    cp "$src_lib/$libssl_versioned" "$ml_macosx_dir/"
    
    # Create symlinks
    cd "$ml_macosx_dir"
    ln -sf "$libcrypto_versioned" "libcrypto.dylib"
    ln -sf "$libssl_versioned" "libssl.dylib"
    
    log_info "  -> Copied versioned dylib files and created symlinks"
    log_info "  -> Destination: $ml_macosx_dir/"
    
    # List what was copied
    log_info ""
    log_info "Files in MarkLogic macosx directory:"
    ls -la "$ml_macosx_dir/"
    
    # Update makefile with new OpenSSL version
    log_info ""
    log_info "Step 3: Updating makefile with OpenSSL version..."
    local makefile="$ML_DIR/src/macosx/makefiles/defs"
    
    if [[ ! -f "$makefile" ]]; then
        log_warn "Makefile not found: $makefile"
        log_warn "You may need to manually update OPENSSL_VERSION"
    else
        # Backup the original makefile
        cp "$makefile" "$makefile.bak.$(date +%Y%m%d_%H%M%S)"
        log_info "  -> Created backup of makefile"
        
        # Get the old version for logging
        local old_version=$(grep "^OPENSSL_VERSION[[:space:]]*=" "$makefile" | sed 's/^OPENSSL_VERSION[[:space:]]*=[[:space:]]*//')
        
        if [[ -n "$old_version" ]]; then
            # Replace the version (preserve original spacing style)
            sed -i '' "s/^OPENSSL_VERSION[[:space:]]*=.*/OPENSSL_VERSION = $OPENSSL_VERSION/" "$makefile"
            
            log_info "  -> Updated OPENSSL_VERSION in makefile"
            log_info "       Old version: $old_version"
            log_info "       New version: $OPENSSL_VERSION"
        else
            log_warn "  -> OPENSSL_VERSION line not found in makefile"
            log_warn "     You may need to manually add: OPENSSL_VERSION = $OPENSSL_VERSION"
        fi
    fi
    
    log_info ""
    log_info "Copy to MarkLogic completed successfully!"
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

# Function to build MarkLogic
build_marklogic() {
    log_info "=========================================="
    log_info "Building MarkLogic..."
    log_info "=========================================="
    
    if [[ -z "$ML_DIR" ]]; then
        log_error "No MarkLogic directory specified"
        return 1
    fi
    
    # Setup JAVA_HOME for macOS if not set or pointing to old JavaVM.framework
    if [[ -z "$JAVA_HOME" ]] || [[ "$JAVA_HOME" == *"JavaVM.framework"* ]]; then
        log_info "Detecting JAVA_HOME..."
        
        # Try /usr/libexec/java_home (standard macOS way)
        if [[ -x /usr/libexec/java_home ]]; then
            export JAVA_HOME=$(/usr/libexec/java_home 2>/dev/null)
            if [[ -n "$JAVA_HOME" ]] && [[ -d "$JAVA_HOME" ]]; then
                log_info "  -> Set JAVA_HOME via java_home: $JAVA_HOME"
            fi
        fi
        
        # If still not set, try common locations
        if [[ -z "$JAVA_HOME" ]] || [[ ! -d "$JAVA_HOME" ]]; then
            local java_paths=(
                "/Library/Java/JavaVirtualMachines/jdk-11.jdk/Contents/Home"
                "/Library/Java/JavaVirtualMachines/jdk-17.jdk/Contents/Home"
                "/Library/Java/JavaVirtualMachines/jdk1.8.0_*.jdk/Contents/Home"
                "/Library/Java/JavaVirtualMachines/adoptopenjdk-11.jdk/Contents/Home"
            )
            for java_path in "${java_paths[@]}"; do
                # Handle glob patterns
                for expanded_path in $java_path; do
                    if [[ -d "$expanded_path" ]]; then
                        export JAVA_HOME="$expanded_path"
                        log_info "  -> Set JAVA_HOME to: $JAVA_HOME"
                        break 2
                    fi
                done
            done
        fi
        
        if [[ -z "$JAVA_HOME" ]] || [[ ! -d "$JAVA_HOME" ]]; then
            log_error "Could not find a valid JAVA_HOME"
            log_error "Please install Java JDK or set JAVA_HOME manually"
            return 1
        fi
    else
        log_info "Using existing JAVA_HOME: $JAVA_HOME"
    fi
    
    # Verify java executable exists
    if [[ ! -x "$JAVA_HOME/bin/java" ]]; then
        log_error "Java executable not found at: $JAVA_HOME/bin/java"
        return 1
    fi
    
    # Change to MarkLogic src directory
    local ml_src_dir="$ML_DIR/src"
    if [[ ! -d "$ml_src_dir" ]]; then
        log_error "MarkLogic src directory not found: $ml_src_dir"
        return 1
    fi
    
    cd "$ml_src_dir"
    log_info "Working directory: $(pwd)"
    
    # Check if Makefile exists
    if [[ ! -f "Makefile" ]]; then
        log_error "Makefile not found in MarkLogic src directory"
        return 1
    fi
    
    # Create build log
    local ml_build_log="$LOGS_DIR/marklogic_build_${BUILD_DATE}.txt"
    log_info "MarkLogic build log: $ml_build_log"
    log_info ""
    
    # Step 1: make clean
    log_info "Step 1/4: Running 'make clean'..."
    if ! make clean >> "$ml_build_log" 2>&1; then
        log_error "make clean failed. Check log: $ml_build_log"
        return 1
    fi
    log_info "  -> Done"
    
    # Step 2: make keyed
    log_info "Step 2/4: Running 'make keyed'..."
    if ! make keyed >> "$ml_build_log" 2>&1; then
        log_error "make keyed failed. Check log: $ml_build_log"
        log_info "Last 50 lines of build log:"
        tail -50 "$ml_build_log"
        return 1
    fi
    log_info "  -> Done"
    
    # Step 3: make optimize
    log_info "Step 3/4: Running 'make optimize'..."
    if ! make optimize >> "$ml_build_log" 2>&1; then
        log_error "make optimize failed. Check log: $ml_build_log"
        log_info "Last 50 lines of build log:"
        tail -50 "$ml_build_log"
        return 1
    fi
    log_info "  -> Done"
    
    # Step 4: make -j8
    log_info "Step 4/4: Running 'make -j8' (this may take a while)..."
    if ! make -j8 >> "$ml_build_log" 2>&1; then
        log_error "make -j8 failed. Check log: $ml_build_log"
        log_info "Last 50 lines of build log:"
        tail -50 "$ml_build_log"
        return 1
    fi
    log_info "  -> Done"
    
    log_info ""
    log_info "MarkLogic build completed successfully!"
    log_info "Build log: $ml_build_log"
    return 0
}

# Function to display build summary
display_summary() {
    log_info "=========================================="
    log_info "Build Summary"
    log_info "=========================================="
    echo "  Work Directory:    $WORK_DIR"
    echo "  OpenSSL Directory: $OPENSSL_DIR"
    echo "  Install Directory: $INSTALL_DIR"
    echo "  Logs Directory:    $LOGS_DIR"
    echo "  FIPS Version:      $FIPS_VERSION"
    echo "  OpenSSL Version:   $OPENSSL_VERSION"
    echo "  Build Date:        $BUILD_DATE"
    echo ""
    log_info "Build artifacts:"
    echo "  Headers:   $INSTALL_DIR/usr/local/ssl/include"
    echo "  Libraries: $INSTALL_DIR/usr/local/ssl/lib"
    echo ""
    log_info "Log files:"
    echo "  FIPS Log:    $LOGS_DIR/fips_build_${BUILD_DATE}.txt"
    echo "  OpenSSL Log: $LOGS_DIR/openssl_build_${BUILD_DATE}.txt"
}

# Main execution
main() {
    # Handle help parameter
    if [[ "$1" == "-h" ]] || [[ "$1" == "--help" ]]; then
        show_help
        return 0
    fi
    
    # Parse all flags first
    while [[ "$1" == --* ]]; do
        case "$1" in
            --build-ml)
                BUILD_ML_FLAG=true
                shift
                ;;
            --skip-fips)
                SKIP_FIPS_FLAG=true
                shift
                ;;
            --skip-openssl)
                SKIP_OPENSSL_FLAG=true
                shift
                ;;
            --skip-dylib-fix)
                SKIP_DYLIB_FIX_FLAG=true
                shift
                ;;
            --no-update)
                NO_UPDATE_FLAG=true
                shift
                ;;
            *)
                log_error "Unknown flag: $1"
                log_error "Use --help to see available options"
                return 1
                ;;
        esac
    done
    
    # Now parse positional arguments (no branch needed - macOS only builds 1.0.2.x)
    WORK_DIR="${1:-$(pwd)}"
    ML_DIR="${2:-}"
    
    # Convert WORK_DIR to absolute path (now that flags are parsed)
    if [[ -n "$WORK_DIR" ]] && [[ -d "$WORK_DIR" ]]; then
        WORK_DIR="$(cd "$WORK_DIR" && pwd)"
    else
        WORK_DIR="$(pwd)"
    fi
    
    log_info "OpenSSL Build Automation Script for macOS"
    log_info "Building OpenSSL 1.0.2.x (develop-11 branch only)"
    log_info "Work directory: $WORK_DIR"
    
    # Show active flags
    if [[ "$SKIP_FIPS_FLAG" == true ]]; then
        log_info "Flag: --skip-fips (will reuse existing FIPS)"
    fi
    if [[ "$SKIP_OPENSSL_FLAG" == true ]]; then
        log_info "Flag: --skip-openssl (will reuse existing OpenSSL)"
    fi
    if [[ "$SKIP_DYLIB_FIX_FLAG" == true ]]; then
        log_info "Flag: --skip-dylib-fix (will skip library path fixes)"
    fi
    if [[ "$NO_UPDATE_FLAG" == true ]]; then
        log_info "Flag: --no-update (will skip git fetch/rebase)"
    fi
    
    if [[ -n "$ML_DIR" ]]; then
        log_info "MarkLogic directory: $ML_DIR"
    fi
    
    # Setup/update the OpenSSL repository
    if ! setup_openssl_repo; then
        log_error "Failed to setup OpenSSL repository"
        return 1
    fi
    
    # Detect OpenSSL version
    if ! detect_openssl_version; then
        log_error "Failed to detect OpenSSL version"
        return 1
    fi
    
    # Build FIPS
    if ! build_fips; then
        log_error "FIPS build failed"
        return 1
    fi
    
    # Build OpenSSL
    if ! build_openssl; then
        log_error "OpenSSL build failed"
        return 1
    fi
    
    # Fix dynamic library paths
    if ! fix_dylib_paths; then
        log_error "Failed to fix dynamic library paths"
        return 1
    fi
    
    # Copy to MarkLogic directory (if specified)
    if ! copy_to_marklogic; then
        log_error "Failed to copy to MarkLogic directory"
        return 1
    fi
    
    # Check if user wants to build MarkLogic
    if prompt_build_marklogic; then
        if ! build_marklogic; then
            log_error "MarkLogic build failed"
            return 1
        fi
    fi
    
    # Display summary
    display_summary
    
    log_info ""
    log_info "OpenSSL build completed successfully!"
    log_info "Current directory: $(pwd)"
}

# Run main function with all arguments
main "$@"
