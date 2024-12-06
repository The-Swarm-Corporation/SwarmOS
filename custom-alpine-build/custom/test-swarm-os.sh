#!/bin/bash
# Script to test SwarmOS in QEMU
qemu-system-x86_64 \
    -m 1024 \
    -boot d \
    -cdrom swarm-os.iso \
    -net nic \
    -net user
