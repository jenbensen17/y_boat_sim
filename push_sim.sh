#!/usr/bin/env bash
# Push the BlueBoat simulation Docker image to Docker Hub (yrobotics/y_boat_sim)
#
# Usage:
#   ./sim_scratch/push_sim.sh
#   IMAGE=myorg/my_sim ./sim_scratch/push_sim.sh
#
set -euo pipefail

IMAGE="${IMAGE:-yrobotics/y_boat_sim}"
SOURCE_IMAGE="${SOURCE_IMAGE:-y_boat_sim_scratch:1c}"

echo "======================================================================"
echo "[push] Preparing to push simulation image to Docker Hub"
echo "[push] Source: ${SOURCE_IMAGE}"
echo "[push] Target: ${IMAGE}:latest and ${IMAGE}:1c"
echo "======================================================================"

# Ensure source image exists locally
if ! docker image inspect "${SOURCE_IMAGE}" >/dev/null 2>&1; then
    echo "[push] ERROR: Source image '${SOURCE_IMAGE}' not found locally."
    echo "[push] Please build it first with: ./sim_scratch/build_sim.sh"
    exit 1
fi

# Tag target images
echo "[push] Tagging images..."
docker tag "${SOURCE_IMAGE}" "${IMAGE}:latest"
docker tag "${SOURCE_IMAGE}" "${IMAGE}:1c"

# Verify user is logged into Docker Hub
if ! docker info 2>/dev/null | grep -i "Username" >/dev/null 2>&1; then
    echo ""
    echo "[push] You must log in to Docker Hub first."
    echo "[push] Please enter your Docker Hub username and password/token:"
    docker login
fi

echo ""
echo "[push] Pushing ${IMAGE}:latest..."
docker push "${IMAGE}:latest"

echo ""
echo "[push] Pushing ${IMAGE}:1c..."
docker push "${IMAGE}:1c"

echo ""
echo "======================================================================"
echo "[push] SUCCESS! Images published to Docker Hub:"
echo "       - https://hub.docker.com/r/${IMAGE}"
echo ""
echo "[push] Any teammate on any computer can now run:"
echo "       ./run_sim.sh"
echo "       (It will automatically pull ${IMAGE}:latest from Docker Hub in ~1 min)"
echo "======================================================================"
