#!/usr/bin/env bash
# Build script for the BlueBoat simulation Docker image (y_boat_sim_scratch:1c)
#
# Works across Linux, macOS, and Windows (WSL2).
# On ARM64 (e.g. Apple Silicon Macs), automatically builds for linux/amd64 via Rosetta/QEMU
# to ensure binary compatibility with all pinned packages and QGroundControl.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE="${IMAGE:-y_boat_sim_scratch:1c}"

PLATFORM_ARG=""
ARCH="$(uname -m)"
if [ "${ARCH}" = "arm64" ] || [ "${ARCH}" = "aarch64" ]; then
    echo "[build] Detected ARM64 architecture (${ARCH})."
    echo "[build] Enforcing --platform linux/amd64 for full compatibility with pinned x86_64 QGC."
    PLATFORM_ARG="--platform linux/amd64"
fi

echo "======================================================================"
echo "[build] Building simulation image: ${IMAGE}"
echo "[build] Dockerfile: ${SCRIPT_DIR}/Dockerfile.sim"
echo "[build] Context:    ${SCRIPT_DIR}"
echo "======================================================================"

DOCKER_BUILDKIT=1 docker build ${PLATFORM_ARG} -t "${IMAGE}" -f "${SCRIPT_DIR}/Dockerfile.sim" "${SCRIPT_DIR}"

# Ensure both Docker Hub and local scratch tags exist
if [ "${IMAGE}" = "y_boat_sim_scratch:1c" ]; then
    docker tag "${IMAGE}" yrobotics/y_boat_sim:latest 2>/dev/null || true
    docker tag "${IMAGE}" yrobotics/y_boat_sim:1c 2>/dev/null || true
else
    docker tag "${IMAGE}" y_boat_sim_scratch:1c 2>/dev/null || true
fi

echo ""
echo "======================================================================"
echo "[build] SUCCESS! Image '${IMAGE}' built successfully."
echo "[build] You can now launch the simulator with:"
echo "        ./sim_scratch/run_sim_scratch.sh"
echo "======================================================================"
