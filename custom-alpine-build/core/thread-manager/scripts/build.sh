#!/bin/bash
set -e

# Compile the thread manager with optimizations
gcc -O2 -Wall -Wextra \
    -o thread_manager \
    src/thread_manager.c \
    -pthread \
    -ljson-c \
    -lsqlite3

# Install the binary
install -Dm755 thread_manager /usr/sbin/thread_manager
