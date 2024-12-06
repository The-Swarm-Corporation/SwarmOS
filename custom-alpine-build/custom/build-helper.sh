#!/bin/bash
# Helper script to build SwarmOS components inside Docker container
docker exec -it swarm-os-build /bin/sh -c "cd /work && $*"
