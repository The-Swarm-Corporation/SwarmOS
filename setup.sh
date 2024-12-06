#!/bin/bash

# SwarmOS Setup Script for macOS
# This script sets up a development environment for SwarmOS on macOS

# Error handling
set -e
trap 'echo "An error occurred. Exiting..."; exit 1' ERR

# Configuration variables
ALPINE_VERSION="3.19"
ALPINE_MIRROR="https://dl-cdn.alpinelinux.org/alpine"
BUILD_DIR="custom-alpine-build"
CUSTOM_NAME="swarm-os"

# Check for and install required tools using Homebrew
echo "Checking and installing required tools..."
if ! command -v brew &> /dev/null; then
    echo "Installing Homebrew..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi

# Install required packages
echo "Installing required packages..."
brew install wget qemu docker virtualbox

# Create build directory structure
echo "Creating build environment..."
mkdir -p "${BUILD_DIR}/iso"
mkdir -p "${BUILD_DIR}/custom"
cd "${BUILD_DIR}"

# Download Alpine Linux base system
echo "Downloading Alpine Linux base system..."
wget "${ALPINE_MIRROR}/v${ALPINE_VERSION}/releases/x86_64/alpine-minirootfs-${ALPINE_VERSION}.0-x86_64.tar.gz"

# Extract the root filesystem
echo "Extracting root filesystem..."
cd custom
tar xzf "../alpine-minirootfs-${ALPINE_VERSION}.0-x86_64.tar.gz"

# Set up development environment
echo "Setting up development environment..."
docker pull alpine:${ALPINE_VERSION}

# Create a Docker container for building
echo "Creating build container..."
docker run -d --name swarm-os-build \
    -v "$(pwd):/work" \
    alpine:${ALPINE_VERSION} \
    tail -f /dev/null

# Install build tools in container
echo "Installing build tools in container..."
docker exec swarm-os-build apk add --no-cache \
    alpine-sdk \
    build-base \
    gcc \
    musl-dev \
    linux-headers \
    git

# Create helper script for building inside container
cat > build-helper.sh << 'EOF'
#!/bin/bash
# Helper script to build SwarmOS components inside Docker container
docker exec -it swarm-os-build /bin/sh -c "cd /work && $*"
EOF
chmod +x build-helper.sh

# Set up QEMU for testing
echo "Setting up QEMU test environment..."
cat > test-swarm-os.sh << 'EOF'
#!/bin/bash
# Script to test SwarmOS in QEMU
qemu-system-x86_64 \
    -m 1024 \
    -boot d \
    -cdrom swarm-os.iso \
    -net nic \
    -net user
EOF
chmod +x test-swarm-os.sh

echo "SwarmOS development environment setup complete!"
echo ""
echo "To build components, use: ./build-helper.sh [command]"
echo "To test the system, use: ./test-swarm-os.sh"
echo ""
echo "Build directory: $(pwd)"