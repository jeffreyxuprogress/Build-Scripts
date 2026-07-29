#!/bin/bash

# OpenSSL Build Automation Script for ARM (aarch64)
# This script automates the process of building OpenSSL on ARM platforms
# Note: FIPS is NOT supported on ARM at this time due to build issues
# Tested on: Amazon Linux EC2 (ARM/Graviton instances)
#
# Usage: ./openssl_build_arm.sh [branch] [work_directory] [marklogic_directory]
# Example: ./openssl_build_arm.sh develop-11 /path/to/work/dir /users/ml/xu/code/xdmp

# Don't exit on error - we'll handle errors gracefully
set +e

# Configuration
OPENSSL_REPO="https://github.bedford.progress.com/marklogic-platform/openssl.git"

# ARM-specific: Use system GCC on Amazon Linux (no gcc-toolset required)
# Amazon Linux 2023 comes with GCC 11.x, Amazon Linux 2 has GCC 7.x
CC_PATH="${CC_PATH:-$(which gcc)}"

# Help function
show_help() {
    echo "OpenSSL Build Automation Script for ARM (aarch64)"
    echo ""
    echo "Usage: $0 [branch|--clean|--copy-only|--build-ml|--skip-git] [work_directory] [marklogic_directory]"
    echo ""
    echo "Platform: ARM/aarch64 (Amazon Linux EC2, Graviton instances)"
    echo "Note: FIPS is NOT supported on ARM at this time due to build issues"
    echo ""
    echo "Parameters:"
    echo "  branch                Target branch: 'develop' (for 12.x/OpenSSL 3.x) or 'develop-11' (for 11.x/OpenSSL 1.x)"
    echo "                        Default: develop"
    echo "  --clean               Clean all build artifacts (INSTALL_DIR and extracted directories)"
    echo "                        If marklogic_directory is provided, also prompts to clean MarkLogic 3rdParty/openssl/"
    echo "  --copy-only           Copy latest build artifacts to MarkLogic without rebuilding"
    echo "  --build-ml            Automatically build MarkLogic after copying OpenSSL files (skips prompt)"
    echo "  --skip-git            Skip git fetch and rebase operations (use current state of repo)"
    echo "  work_directory        Directory to perform build in (default: current directory)"
    echo "  marklogic_directory   Path to MarkLogic directory (e.g., /users/ml/xu/code/xdmp)"
    echo "                        If provided, will copy build artifacts to 3rdParty/openssl/"
    echo ""
    echo "Environment Variables:"
    echo "  CC_PATH               Override the default GCC compiler path (default: system gcc)"
    echo ""
    echo "Examples:"
    echo "  $0                                      # Build for develop branch (OpenSSL 3.x) in current directory"
    echo "  $0 develop-11                          # Build for develop-11 branch (OpenSSL 1.x) in current directory"
    echo "  $0 develop /tmp/build                  # Build for develop branch in /tmp/build"
    echo "  $0 develop-11 . /users/ml/xu/code/xdmp # Build and copy to MarkLogic 3rdParty"
    echo "  $0 --build-ml . /users/ml/xu/code/xdmp # Build OpenSSL and MarkLogic automatically"
    echo "  $0 --skip-git develop-11 .             # Build without updating git repo"
    echo "  $0 --clean                              # Clean all build artifacts in current directory"
    echo "  $0 --clean /tmp/build                  # Clean all build artifacts in /tmp/build"
    echo "  $0 --clean . /users/ml/xu/code/xdmp    # Clean build artifacts AND MarkLogic 3rdParty/openssl/"
    echo "  $0 --copy-only . /users/ml/xu/code/xdmp # Copy latest build to MarkLogic without rebuilding"
    echo ""
    echo "The script will:"
    echo "  1. Locate OpenSSL repository (current dir or ./openssl subdirectory)"
    echo "  2. Update git repository (unless --skip-git is specified)"
    echo "  3. Determine OpenSSL version based on branch and available tar files"
    echo "  4. Build OpenSSL (without FIPS support)"
    echo "  5. Install to ./openssl/INSTALL_DIR/{timestamp}"
    echo "  6. (Optional) Copy artifacts to MarkLogic 3rdParty directory"
    echo "  7. (Optional) Build MarkLogic to test OpenSSL integration"
    echo ""
    echo "ARM-Specific Notes:"
    echo "  - Libraries are installed to linux/aarch64-gcc7.3/ (instead of x86_64-gcc7.3/)"
    echo "  - Uses system GCC by default (no gcc-toolset required on Amazon Linux)"
    echo "  - FIPS is NOT supported on ARM due to build compatibility issues"
    echo "  - Tested on Amazon Linux 2 and Amazon Linux 2023 ARM instances"
    echo ""
    echo "Version Selection Logic:"
    echo "  - develop-11: Uses OpenSSL 1.x (checks for latest 1.0.2.* tar file)"
    echo "  - develop: Uses OpenSSL 3.x (checks for latest 3.* tar file)"
}

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

# Flags
SKIP_GIT_FLAG=false
BUILD_ML_FLAG=false

# Parse command line arguments - handle flags first
parse_args() {
    # Reset flags
    SKIP_GIT_FLAG=false
    BUILD_ML_FLAG=false
    COPY_ONLY_FLAG=false
    CLEAN_FLAG=false
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --skip-git)
                SKIP_GIT_FLAG=true
                shift
                ;;
            --build-ml)
                BUILD_ML_FLAG=true
                shift
                ;;
            --copy-only)
                COPY_ONLY_FLAG=true
                shift
                ;;
            --clean)
                CLEAN_FLAG=true
                shift
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                # Not a flag, stop parsing flags
                break
                ;;
        esac
    done
    
    # Remaining args are positional: [branch] [work_directory] [marklogic_directory]
    TARGET_BRANCH="${1:-develop}"
    WORK_DIR="${2:-$(pwd)}"
    ML_DIR="${3:-}"
}

# Function to check if we're in the openssl git repo
is_openssl_repo() {
    local dir="$1"
    
    # Check if it's a git repo
    if [[ ! -d "$dir/.git" ]]; then
        return 1
    fi
    
    # Check if remote matches our openssl repo
    local remote_url=$(cd "$dir" && git remote get-url origin 2>/dev/null)
    if [[ "$remote_url" == *"openssl"* ]]; then
        return 0
    fi
    
    return 1
}

# Function to setup or update OpenSSL repository
setup_openssl_repo() {
    log_info "Setting up OpenSSL repository..."
    
    local openssl_dir=""
    
    # Check if current directory is the openssl repo
    if is_openssl_repo "$(pwd)"; then
        openssl_dir="$(pwd)"
        log_info "Current directory is the OpenSSL repository: $openssl_dir"
    # Check if ./openssl subdirectory exists and is the repo
    elif [[ -d "./openssl" ]] && is_openssl_repo "./openssl"; then
        openssl_dir="$(cd ./openssl && pwd)"
        log_info "Found OpenSSL repository at: $openssl_dir"
        cd "$openssl_dir"
    else
        log_error "OpenSSL repository not found!"
        log_error "Please either:"
        log_error "  1. Run this script from within the openssl git repository"
        log_error "  2. Run this script from a directory containing an 'openssl' subdirectory with the repo"
        return 1
    fi
    
    # Export for use by other functions
    OPENSSL_DIR="$openssl_dir"
    TARBALL_DIR="$openssl_dir"
    BUILD_DIR="$openssl_dir"
    
    # Skip git operations if flag is set
    if [[ "$SKIP_GIT_FLAG" == true ]]; then
        log_info "Skipping git updates (--skip-git flag detected)"
        log_info "Using current state of repository"
        return 0
    fi
    
    # Perform git fetch and rebase
    log_info "Fetching latest changes from origin..."
    if ! git fetch origin; then
        log_error "Failed to fetch from origin"
        return 1
    fi
    
    # Get current branch
    local current_branch=$(git rev-parse --abbrev-ref HEAD)
    log_info "Current branch: $current_branch"
    
    # Rebase current branch
    log_info "Rebasing $current_branch onto origin/$current_branch..."
    if ! git rebase origin/$current_branch; then
        log_warn "Rebase failed - you may need to resolve conflicts manually"
        log_warn "After resolving, run the script again with --skip-git"
        return 1
    fi
    
    log_info "Git repository is up to date"
    return 0
}

# Function to detect the latest OpenSSL version from available tarballs
detect_openssl_version() {
    log_info "Detecting OpenSSL version for branch: $TARGET_BRANCH"
    
    cd "$TARBALL_DIR"
    
    # Determine which version pattern to look for based on branch
    local pattern=""
    local default_version=""
    
    if [[ "$TARGET_BRANCH" == "develop-11" ]]; then
        pattern="openssl-1.0.2*.tar.gz"
        default_version="1.0.2zm"
    else
        pattern="openssl-3.*.tar.gz"
        default_version="3.3.3"
    fi
    
    # Find the latest version from existing tar files
    if ls $pattern 1> /dev/null 2>&1; then
        # Get the latest tar file (sort by version)
        local latest_tar=$(ls $pattern | sort -V | tail -1)
        # Extract version from filename (remove openssl- prefix and .tar.gz suffix)
        OPENSSL_VERSION=$(echo "$latest_tar" | sed 's/openssl-\(.*\)\.tar\.gz/\1/')
        log_info "Found existing tar file: $latest_tar"
        log_info "Using OpenSSL version: $OPENSSL_VERSION"
    else
        # Use default version
        OPENSSL_VERSION="$default_version"
        log_warn "No existing tar files matching '$pattern' found"
        log_warn "Using default version: $OPENSSL_VERSION"
    fi
    
    # Verify the tarball exists
    if [[ ! -f "$TARBALL_DIR/openssl-$OPENSSL_VERSION.tar.gz" ]]; then
        log_error "OpenSSL tarball not found: $TARBALL_DIR/openssl-$OPENSSL_VERSION.tar.gz"
        return 1
    fi
    
    return 0
}

# Function to clean up old extracted build directories
cleanup_old_builds() {
    log_info "Cleaning up old extracted build directories..."
    
    cd "$TARBALL_DIR"
    
    # Remove only extracted openssl directories (not tarballs or INSTALL_DIR)
    for dir in openssl-*/; do
        if [[ -d "$dir" ]]; then
            log_info "  Removing old directory: $dir"
            rm -rf "$dir"
        fi
    done
    
    log_info "Cleanup complete"
    return 0
}

# Function to build OpenSSL
build_openssl() {
    log_info "Building OpenSSL $OPENSSL_VERSION for ARM (aarch64)..."
    
    cd "$TARBALL_DIR"
    
    # Extract tarball first
    log_info "Extracting openssl-$OPENSSL_VERSION.tar.gz..."
    if ! tar xzf "openssl-$OPENSSL_VERSION.tar.gz"; then
        log_error "Failed to extract OpenSSL tarball"
        return 1
    fi
    
    # Set INSTALL_DIR inside the extracted openssl directory
    local openssl_src_dir="$TARBALL_DIR/openssl-$OPENSSL_VERSION"
    INSTALL_DIR="$openssl_src_dir/INSTALL_DIR"
    LOGS_DIR="$openssl_src_dir/logs"
    
    # Create directories
    mkdir -p "$INSTALL_DIR"
    mkdir -p "$LOGS_DIR"
    
    local build_timestamp=$(date +%Y%m%d_%H%M%S)
    local build_log="$LOGS_DIR/openssl_build_${build_timestamp}.txt"
    log_info "Build output will be logged to: $build_log"
    
    # Change to extracted directory
    cd "$TARBALL_DIR/openssl-$OPENSSL_VERSION"
    log_info "Working in: $(pwd)"
    
    # Configure OpenSSL (without FIPS for ARM)
    log_info "Configuring OpenSSL..."
    if ! CC="$CC_PATH" ./config shared --api=1.0.2 >> "$build_log" 2>&1; then
        log_error "OpenSSL configuration failed. Check log: $build_log"
        return 1
    fi
    
    # Build OpenSSL
    log_info "Building OpenSSL (this may take a while)..."
    if ! make >> "$build_log" 2>&1; then
        log_error "OpenSSL build failed. Check log: $build_log"
        return 1
    fi
    
    # Install OpenSSL
    log_info "Installing OpenSSL to $INSTALL_DIR..."
    if ! make install INSTALL_PREFIX="$INSTALL_DIR" >> "$build_log" 2>&1; then
        log_error "OpenSSL installation failed. Check log: $build_log"
        return 1
    fi
    
    log_info "OpenSSL build complete!"
    log_info "Build log: $build_log"
    log_info "Install directory: $INSTALL_DIR"
    
    return 0
}

# Function to display build summary
display_summary() {
    echo ""
    log_info "=========================================="
    log_info "Build Summary"
    log_info "=========================================="
    echo "  OpenSSL Version:  $OPENSSL_VERSION"
    echo "  Target Branch:    $TARGET_BRANCH"
    echo "  Architecture:     ARM (aarch64)"
    echo "  OpenSSL Dir:      $OPENSSL_DIR"
    echo "  Install Dir:      $INSTALL_DIR"
    echo "  Logs Dir:         $LOGS_DIR"
    echo ""
    
    # Show what was installed
    if [[ -d "$INSTALL_DIR/usr/local/ssl" ]]; then
        log_info "Build artifacts (OpenSSL 1.x layout):"
        echo "  Headers:    $INSTALL_DIR/usr/local/ssl/include/"
        echo "  Libraries:  $INSTALL_DIR/usr/local/ssl/lib/"
        echo "  Binaries:   $INSTALL_DIR/usr/local/ssl/bin/"
    elif [[ -d "$INSTALL_DIR/usr/local" ]]; then
        log_info "Build artifacts (OpenSSL 3.x layout):"
        echo "  Headers:    $INSTALL_DIR/usr/local/include/"
        echo "  Libraries:  $INSTALL_DIR/usr/local/lib/"
        echo "  Binaries:   $INSTALL_DIR/usr/local/bin/"
    fi
    echo ""
}

# Function to copy build artifacts to MarkLogic 3rdParty directory
copy_to_marklogic() {
    if [[ -z "$ML_DIR" ]]; then
        log_info "No MarkLogic directory specified, skipping copy to 3rdParty"
        return 0
    fi
    
    if [[ ! -d "$ML_DIR" ]]; then
        log_error "MarkLogic directory does not exist: $ML_DIR"
        return 1
    fi
    
    log_info "Copying build artifacts to MarkLogic 3rdParty directory..."
    
    # Determine source directories based on OpenSSL version
    local include_src=""
    local lib_src=""
    
    if [[ -d "$INSTALL_DIR/usr/local/ssl" ]]; then
        # OpenSSL 1.x layout
        include_src="$INSTALL_DIR/usr/local/ssl/include"
        lib_src="$INSTALL_DIR/usr/local/ssl/lib"
    elif [[ -d "$INSTALL_DIR/usr/local" ]]; then
        # OpenSSL 3.x layout
        include_src="$INSTALL_DIR/usr/local/include"
        lib_src="$INSTALL_DIR/usr/local/lib"
    else
        log_error "Could not find OpenSSL install directories in: $INSTALL_DIR"
        return 1
    fi
    
    # Verify source directories exist
    if [[ ! -d "$include_src" ]]; then
        log_error "Include directory not found: $include_src"
        return 1
    fi
    
    if [[ ! -d "$lib_src" ]]; then
        log_error "Library directory not found: $lib_src"
        return 1
    fi
    
    # Target directory structure
    local openssl_base="$ML_DIR/3rdParty/openssl"
    local version_dir="$openssl_base/$OPENSSL_VERSION"
    
    log_info "Creating directory structure at: $version_dir"
    
    # Create base directories
    mkdir -p "$version_dir/include"
    mkdir -p "$version_dir/linux"
    mkdir -p "$version_dir/winnt"
    
    # Create branch-specific directories
    if [[ "$TARGET_BRANCH" == "develop-11" ]]; then
        mkdir -p "$version_dir/macosx"
        log_info "  Created macosx directory (develop-11 branch)"
    else
        mkdir -p "$version_dir/windows-include"
        log_info "  Created windows-include directory (develop branch)"
    fi
    
    # Copy include headers
    log_info "Copying include headers..."
    if ! cp -r "$include_src"/* "$version_dir/include/" 2>/dev/null; then
        log_error "Failed to copy headers from: $include_src"
        return 1
    fi
    log_info "  Headers copied from: $include_src"
    log_info "  Headers copied to: $version_dir/include/"
    
    # Create ARM GCC directory and copy libraries
    local arm_gcc_dir="$version_dir/linux/aarch64-gcc7.3"
    mkdir -p "$arm_gcc_dir"
    
    log_info "Copying shared libraries (preserving symlinks)..."
    
    # Count .so files first
    local so_count=$(ls "$lib_src"/*.so* 2>/dev/null | wc -l)
    if [[ $so_count -gt 0 ]]; then
        # Use cp -P to preserve symlinks
        if ! cp -P "$lib_src"/*.so* "$arm_gcc_dir/" 2>/dev/null; then
            log_error "Failed to copy libraries from: $lib_src"
            return 1
        fi
        log_info "  Libraries copied from: $lib_src"
        log_info "  Libraries copied to: $arm_gcc_dir"
        log_info "  Copied $so_count library file(s)/symlink(s)"
    else
        log_warn "  No .so files found in: $lib_src"
    fi
    
    # Create GCC version symlink for aarch64-gcc11.5
    log_info "Creating GCC version symlink..."
    cd "$version_dir/linux"
    
    # Create symlink for gcc11.5 (Amazon Linux 2023 default)
    if [[ ! -e "aarch64-gcc11.5" ]]; then
        ln -s aarch64-gcc7.3 aarch64-gcc11.5
        log_info "  Created symlink: aarch64-gcc11.5 -> aarch64-gcc7.3"
    else
        log_info "  Symlink aarch64-gcc11.5 already exists"
    fi
    
    # Display summary
    echo ""
    log_info "MarkLogic 3rdParty Structure:"
    echo "  $version_dir/"
    echo "    ├── include/                (headers)"
    echo "    ├── linux/"
    echo "    │   ├── aarch64-gcc7.3/     (shared libraries)"
    echo "    │   └── aarch64-gcc11.5     (symlink -> aarch64-gcc7.3)"
    echo "    ├── winnt/                  (empty - for Windows)"
    if [[ "$TARGET_BRANCH" == "develop-11" ]]; then
        echo "    └── macosx/                 (empty - for macOS)"
    else
        echo "    └── windows-include/        (empty - for Windows headers)"
    fi
    echo ""
    
    # Update makefile with new OpenSSL version
    log_info "Updating MarkLogic makefile with new OpenSSL version..."
    local makefile="$ML_DIR/src/linux/makefiles/defs"
    
    if [[ ! -f "$makefile" ]]; then
        log_warn "Makefile not found: $makefile"
        log_warn "You may need to manually update OPENSSL_VERSION"
    else
        # Backup the original makefile
        local backup_file="$makefile.bak.$(date +%Y%m%d_%H%M%S)"
        cp "$makefile" "$backup_file"
        log_info "  Created backup: $backup_file"
        
        # Update the OPENSSL_VERSION line
        if grep -q "^OPENSSL_VERSION[[:space:]]*=" "$makefile"; then
            # Get the old version for logging
            local old_version=$(grep "^OPENSSL_VERSION[[:space:]]*=" "$makefile" | sed 's/^OPENSSL_VERSION[[:space:]]*=[[:space:]]*//')
            
            # Replace the version (preserve original spacing style)
            sed -i "s/^OPENSSL_VERSION[[:space:]]*=.*/OPENSSL_VERSION  = $OPENSSL_VERSION/" "$makefile"
            
            log_info "  Updated OPENSSL_VERSION in makefile:"
            log_info "    Old version: $old_version"
            log_info "    New version: $OPENSSL_VERSION"
        else
            log_warn "  OPENSSL_VERSION line not found in makefile"
            log_warn "  You may need to manually add: OPENSSL_VERSION  = $OPENSSL_VERSION"
        fi
    fi
    
    log_info "Copy to MarkLogic 3rdParty complete!"
    return 0
}

# Function for copy-only mode - copies existing build without rebuilding
copy_only_mode() {
    log_info "Copy-only mode: Copying existing build to MarkLogic..."
    
    if [[ -z "$ML_DIR" ]]; then
        log_error "MarkLogic directory not specified"
        log_error "Usage: $0 --copy-only [--skip-git] [branch] [work_directory] <marklogic_directory>"
        return 1
    fi
    
    # Setup OpenSSL repo (respects --skip-git flag)
    if ! setup_openssl_repo; then
        log_error "Failed to setup OpenSSL repository"
        return 1
    fi
    
    # Detect OpenSSL version
    if ! detect_openssl_version; then
        log_error "Failed to detect OpenSSL version"
        return 1
    fi
    
    # Find existing INSTALL_DIR
    local openssl_src_dir="$TARBALL_DIR/openssl-$OPENSSL_VERSION"
    if [[ ! -d "$openssl_src_dir" ]]; then
        log_error "OpenSSL source directory not found: $openssl_src_dir"
        log_error "Please build OpenSSL first before using --copy-only"
        return 1
    fi
    
    INSTALL_DIR="$openssl_src_dir/INSTALL_DIR"
    if [[ ! -d "$INSTALL_DIR" ]]; then
        log_error "Install directory not found: $INSTALL_DIR"
        log_error "Please build OpenSSL first before using --copy-only"
        return 1
    fi
    
    log_info "Found existing build at: $INSTALL_DIR"
    
    # Copy to MarkLogic
    if ! copy_to_marklogic; then
        log_error "Failed to copy to MarkLogic 3rdParty directory"
        return 1
    fi
    
    log_info "Copy-only mode completed successfully!"
    return 0
}

# Main function - wraps all execution to avoid killing terminal on errors
main() {
    # Handle help parameter
    if [[ "$1" == "-h" ]] || [[ "$1" == "--help" ]]; then
        show_help
        return 0
    fi

    # Parse arguments
    parse_args "$@"

    log_info "Starting OpenSSL build automation for ARM (aarch64)..."
    log_info "Using compiler: $CC_PATH"
    log_info "Skip git: $SKIP_GIT_FLAG"
    log_info "Copy only: $COPY_ONLY_FLAG"
    
    # Handle copy-only mode
    if [[ "$COPY_ONLY_FLAG" == true ]]; then
        copy_only_mode
        return $?
    fi

    # Setup/verify OpenSSL repository
    if ! setup_openssl_repo; then
        log_error "Failed to setup OpenSSL repository"
        return 1
    fi

    log_info "OpenSSL directory: $OPENSSL_DIR"
    log_info "Target branch: $TARGET_BRANCH"
    if [[ -n "$ML_DIR" ]]; then
        log_info "MarkLogic directory: $ML_DIR"
    fi

    # Detect OpenSSL version
    if ! detect_openssl_version; then
        log_error "Failed to detect OpenSSL version"
        return 1
    fi

    # Clean up old extracted directories
    cleanup_old_builds

    # Build OpenSSL
    if ! build_openssl; then
        log_error "OpenSSL build failed"
        return 1
    fi

    # Copy to MarkLogic 3rdParty if ML_DIR is specified
    if ! copy_to_marklogic; then
        log_error "Failed to copy to MarkLogic 3rdParty directory"
        return 1
    fi

    # Display summary
    display_summary

    log_info "OpenSSL build automation completed successfully!"
    return 0
}

# Run main function with all arguments
main "$@"