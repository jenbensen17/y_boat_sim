#!/usr/bin/env bash
# Universal launcher for the BlueBoat simulation environment.
#
# Automatically detects and configures:
#   - Operating System: Native Linux, Windows WSL2 (with WSLg), or macOS
#   - Hardware Architecture: x86_64, or ARM64 (Apple Silicon via --platform linux/amd64)
#   - GPU Acceleration: NVIDIA (via nvidia-container-toolkit), Intel/AMD (via /dev/dri),
#                       DirectX/D3D12 (on WSL2 via /dev/dxg), or Mesa software rendering
#   - Display: GUI windows (via X11/XWayland/WSLg) or automatic HEADLESS fallback
#
set -euo pipefail

# Pick the first image already present locally; fall back to the published one.
DEFAULT_IMAGE="jenbensen17/y_boat_sim:latest"
if [ -z "${IMAGE:-}" ]; then
    IMAGE="${DEFAULT_IMAGE}"
    for candidate in "${DEFAULT_IMAGE}" jenbensen17/y_boat_sim:1c y_boat_sim_scratch:1c; do
        if docker image inspect "${candidate}" >/dev/null 2>&1; then
            IMAGE="${candidate}"
            break
        fi
    done
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Parse optional convenience flags
GZ_GUI="${GZ_GUI:-1}"
GZ_HEADLESS="${GZ_HEADLESS:-0}"
QGC="${QGC:-1}"
HEADLESS="${HEADLESS:-0}"
PASSTHROUGH_ARGS=()

for arg in "$@"; do
    case "${arg}" in
        --no-gz-gui|--no-gui-gz|--gz-headless)
            GZ_GUI=0
            GZ_HEADLESS=1
            echo "[config] Gazebo 3D GUI disabled (--no-gz-gui). Running physics headless for max speed."
            ;;
        --headless)
            HEADLESS=1
            echo "[config] Running fully headless (no GUI windows)."
            ;;
        --no-qgc)
            QGC=0
            echo "[config] QGroundControl disabled (--no-qgc)."
            ;;
        *)
            PASSTHROUGH_ARGS+=("${arg}")
            ;;
    esac
done

# --- 1. OS & Architecture Detection ---------------------------------------
OS="$(uname -s)"
ARCH="$(uname -m)"
IS_WSL=0
IS_DARWIN=0

if [ "${OS}" = "Darwin" ]; then
    IS_DARWIN=1
    echo "[env] Detected macOS (Darwin)."
elif grep -qiE "microsoft|wsl" /proc/version 2>/dev/null || [ -d "/mnt/wslg" ]; then
    IS_WSL=1
    echo "[env] Detected Windows Subsystem for Linux (WSL2/WSLg)."
else
    echo "[env] Detected Linux (${OS})."
fi

PLATFORM_ARG=""
if [ "${ARCH}" = "arm64" ] || [ "${ARCH}" = "aarch64" ]; then
    echo "[env] Detected ARM64 architecture (${ARCH}); enforcing --platform linux/amd64."
    PLATFORM_ARG="--platform linux/amd64"
fi

HEADLESS="${HEADLESS:-0}"
if [ -z "${DISPLAY:-}" ]; then
    if [ "${IS_WSL}" = "1" ] && [ -d "/mnt/wslg" ]; then
        echo "[display] Windows WSLg detected with empty DISPLAY; auto-setting DISPLAY=':0'."
        DISPLAY=":0"
    else
        echo "[display] No DISPLAY variable found; running in HEADLESS mode (no GUI)."
        HEADLESS=1
    fi
elif [ "${IS_DARWIN}" = "1" ]; then
    if [ "${DISPLAY}" = ":0" ] || [ "${DISPLAY}" = "0" ]; then
        echo "[display] macOS detected: mapping DISPLAY to 'host.docker.internal:0' for XQuartz."
        DISPLAY="host.docker.internal:0"
    fi
fi

QT_PLATFORM="${QT_PLATFORM:-xcb}"
GZ_IP_ADDR="${GZ_IP_ADDR:-127.0.0.1}"
XHOST_MODE="${XHOST_MODE:-si}"
XHOST_ENTRY=""
XHOST_ADDED_BY_US=0

grant_xhost() {
    if ! command -v xhost >/dev/null 2>&1; then
        echo "[xhost] 'xhost' not found (normal on WSL2/WSLg/macOS); skipping X11 grant."
        XHOST_ADDED_BY_US=0
        return 0
    fi

    local entry
    if [ "${XHOST_MODE}" = "fallback" ]; then
        entry="local:"
    else
        entry="SI:localuser:$(id -un)"
    fi
    XHOST_ENTRY="${entry}"

    if xhost 2>/dev/null | grep -qF -- "${entry}"; then
        echo "[xhost] '${entry}' already granted by the session; leaving it alone."
        XHOST_ADDED_BY_US=0
    else
        echo "[xhost] granting '+${entry}' (mode=${XHOST_MODE})"
        xhost "+${entry}" >/dev/null 2>&1 || true
        XHOST_ADDED_BY_US=1
    fi
}

cleanup() {
    docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true
    if [ "${XHOST_ADDED_BY_US}" = "1" ] && [ -n "${XHOST_ENTRY}" ] && command -v xhost >/dev/null 2>&1; then
        echo "[xhost] revoking '-${XHOST_ENTRY}'"
        xhost "-${XHOST_ENTRY}" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT INT TERM

DISPLAY_MOUNTS=()
if [ "${HEADLESS}" = "0" ]; then
    grant_xhost "$@"
    if [ -d "/tmp/.X11-unix" ]; then
        DISPLAY_MOUNTS+=(-v "/tmp/.X11-unix:/tmp/.X11-unix")
    fi
fi

# --- 3. GPU Acceleration Auto-Detection -----------------------------------
GPU_ARGS=()
GLX_VENDOR="${GLX_VENDOR:-}"
NV_PRIME="${NV_PRIME:-}"

# A registered 'nvidia' Docker runtime does NOT mean this machine has an NVIDIA
# GPU (the toolkit is often installed on machines that have none, and the WSL
# nvidia-smi shim exists regardless). Passing --gpus all without a usable GPU
# makes `docker run` fail outright, so require the driver to actually enumerate
# a device before going down the NVIDIA path.
has_nvidia_gpu() {
    if command -v nvidia-smi >/dev/null 2>&1 && \
       nvidia-smi -L 2>/dev/null | grep -qE "^GPU [0-9]+:"; then
        return 0
    fi
    # Fall back to the driver device nodes (nvidia-smi may be absent in a
    # minimal install); these do not exist on WSL2, which uses /dev/dxg.
    [ "${IS_WSL}" = "0" ] && [ -e "/dev/nvidiactl" ]
}

# Confirm the container runtime can really hand the GPU through, using an image
# that is already local so this probe never triggers a pull.
nvidia_docker_works() {
    docker info 2>/dev/null | grep -iE "runtimes:.*nvidia" >/dev/null 2>&1 || return 1
    local probe
    for probe in "${IMAGE}" ubuntu:latest; do
        if docker image inspect "${probe}" >/dev/null 2>&1; then
            docker run --rm --gpus all "${probe}" true >/dev/null 2>&1
            return $?
        fi
    done
    # Nothing local to probe with: the driver reports a GPU and the runtime is
    # registered, so trust it.
    return 0
}

if has_nvidia_gpu && nvidia_docker_works; then
    echo "[gpu] NVIDIA GPU runtime available. Enabling NVIDIA GPU acceleration."
    GPU_ARGS+=(--gpus all -e NVIDIA_DRIVER_CAPABILITIES=all)
    if [ "${IS_WSL}" = "0" ]; then
        # Native Linux hybrid laptop GPUs require explicit vendor selection
        [ -z "${GLX_VENDOR}" ] && GLX_VENDOR="nvidia"
        [ -z "${NV_PRIME}" ] && NV_PRIME="1"
    fi
elif [ -d "/dev/dri" ]; then
    echo "[gpu] DRI device (/dev/dri) found. Enabling Intel/AMD GPU acceleration."
    GPU_ARGS+=(--device "/dev/dri")
elif [ "${IS_WSL}" = "1" ] && [ -e "/dev/dxg" ]; then
    echo "[gpu] WSL2 DirectX (/dev/dxg) found. Enabling WSLg GPU acceleration."
    GPU_ARGS+=(--device "/dev/dxg")
else
    echo "[gpu] No discrete GPU acceleration detected. Using Mesa software rendering."
fi

# --- 4. Network & Port Verification ---------------------------------------
check_ports() {
    local busy=0
    local listing
    listing="$( { ss -ltnp 2>/dev/null || netstat -ltnp 2>/dev/null; } || true )"

    if [ -n "${listing}" ]; then
        for port in 5760 5761 5762 5763 9002 9003; do
            local hit
            hit="$(printf '%s\n' "${listing}" | grep -E "[:.]${port}[[:space:]]" || true)"
            if [ -n "${hit}" ]; then
                busy=1
                echo "[ports] WARNING: port ${port} is in use:"
                printf '%s\n' "${hit}" | sed 's/^/          /'
            fi
        done
    fi

    if [ "${busy}" = "1" ]; then
        echo "[ports] A stale ardurover/gz process may block SITL. Stop it before continuing."
    fi
}
check_ports

# --- 5. Container Lifecycle & Image Verification --------------------------
CONTAINER_NAME="${CONTAINER_NAME:-y_boat_sim}"
docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true

if ! docker image inspect "${IMAGE}" >/dev/null 2>&1; then
    echo "[image] Simulation image '${IMAGE}' is not present locally."
    if [[ "${IMAGE}" == *"/"* ]]; then
        echo "[image] Remote image specified; attempting to pull '${IMAGE}'..."
        if docker pull "${IMAGE}"; then
            echo "[image] Successfully pulled '${IMAGE}'!"
        elif [ "${IMAGE}" != "${DEFAULT_IMAGE}" ] && docker pull "${DEFAULT_IMAGE}"; then
            IMAGE="${DEFAULT_IMAGE}"
            echo "[image] Successfully pulled fallback '${IMAGE}'!"
        fi
    fi
fi

if ! docker image inspect "${IMAGE}" >/dev/null 2>&1; then
    if [ "${BUILD_IF_MISSING:-0}" = "1" ]; then
        echo "[image] BUILD_IF_MISSING=1 set: Building image now..."
        "${SCRIPT_DIR}/build_sim.sh"
    else
        echo "----------------------------------------------------------------------"
        echo "[image] Image '${IMAGE}' not found locally or failed to pull."
        echo "Quick options to get it:"
        echo "  1) Pull prebuilt from Docker Hub (fastest, ~1-2 min):"
        echo "     docker pull ${DEFAULT_IMAGE}"
        echo "     ./run_sim.sh"
        echo "  2) Load from offline USB / network tarball (~1 min):"
        echo "     docker load < y_boat_sim.tar.gz"
        echo "  3) Build locally from source (~5-7 min):"
        echo "     ./build_sim.sh"
        echo "     (or re-run with: BUILD_IF_MISSING=1 $0 $*)"
        echo "----------------------------------------------------------------------"
        exit 1
    fi
fi

# Allocate TTY conditionally
DOCKER_TTY=""
if [ -t 0 ] && [ -t 1 ]; then
    DOCKER_TTY="-t"
fi

NETWORK_ARGS=()
if [ "${IS_DARWIN}" = "1" ]; then
    # On macOS, Docker Desktop runs in a Linux VM. Bridge network with published ports
    # allows native Mac apps (like native QGroundControl or MAVProxy) to reach the sim on localhost.
    NETWORK_ARGS=(-p 14550:14550/udp -p 14551:14551/udp -p 5760:5760 -p 5762:5762 -p 5763:5763)
else
    NETWORK_ARGS=(--network host --ipc host)
fi

# Only forward the NVIDIA GLX hints when we actually selected the NVIDIA path;
# an empty __GLX_VENDOR_LIBRARY_NAME sends libglvnd looking for "libGLX_.so.0".
NV_ENV_ARGS=()
[ -n "${NV_PRIME}" ] && NV_ENV_ARGS+=(-e __NV_PRIME_RENDER_OFFLOAD="${NV_PRIME}")
[ -n "${GLX_VENDOR}" ] && NV_ENV_ARGS+=(-e __GLX_VENDOR_LIBRARY_NAME="${GLX_VENDOR}")

echo "[launch] Starting container '${CONTAINER_NAME}'..."
docker run --rm -i ${DOCKER_TTY} --init \
    ${PLATFORM_ARG} \
    --name "${CONTAINER_NAME}" \
    "${GPU_ARGS[@]}" \
    "${NETWORK_ARGS[@]}" \
    -e DISPLAY="${DISPLAY:-}" \
    "${NV_ENV_ARGS[@]}" \
    -e QT_QPA_PLATFORM="${QT_PLATFORM}" \
    -e GZ_IP="${GZ_IP_ADDR}" \
    -e HEADLESS="${HEADLESS}" \
    -e GZ_GUI="${GZ_GUI}" \
    -e GZ_HEADLESS="${GZ_HEADLESS}" \
    -e WITH_ROS="${WITH_ROS:-1}" \
    -e QGC="${QGC}" \
    -e HOME_LOCATION="${HOME_LOCATION:-}" \
    -e ROS_DOMAIN_ID="${ROS_DOMAIN_ID:-10}" \
    -e FASTRTPS_DEFAULT_PROFILES_FILE="/home/simuser/sim_scratch/sim/fastdds_udp.xml" \
    -e RMW_FASTRTPS_USE_QOS_FROM_XML=1 \
    "${DISPLAY_MOUNTS[@]}" \
    -v "${SCRIPT_DIR}:/home/simuser/sim_scratch" \
    "${IMAGE}" \
    "${PASSTHROUGH_ARGS[@]:-/home/simuser/sim_scratch/sim/launch_blueboat.sh}"
