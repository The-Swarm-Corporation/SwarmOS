#!/bin/bash
set -e

# Add thread manager to the base system
echo "thread-manager" >> /etc/apk/world

# Enable the service
rc-update add thread-manager default

# Create configuration directory
mkdir -p /etc/thread-manager
