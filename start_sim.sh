#!/usr/bin/env bash
# Start the BlueBoat sim on a native install (run ./setup_native.sh once first).
#
#   ./start_sim.sh              # Gazebo + QGroundControl + ArduPilot console + ROS 2
#   QGC=0 ./start_sim.sh        # without QGroundControl
#   GZ_GUI=0 ./start_sim.sh     # physics only, no Gazebo window
#   HEADLESS=1 ./start_sim.sh   # no windows at all
#
# Ctrl+C stops everything.
set -eo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SIM_DEPS="${SIM_DEPS:-${HOME}/blueboat_deps}"

if [ ! -f "${SIM_DEPS}/env.sh" ]; then
    echo "[start_sim] No native install found in ${SIM_DEPS}. Run ./setup_native.sh first."
    exit 1
fi
source "${SIM_DEPS}/env.sh"

# WSL has no /dev/dri, so Mesa silently renders on the CPU (llvmpipe) unless told to
# use the GPU through D3D12. Check it actually works first: a broken Windows GPU
# driver makes every GL app crash under d3d12.
if [ -z "${GALLIUM_DRIVER:-}" ] && [ -e /dev/dxg ] && [ ! -e /dev/dri ]; then
    if GALLIUM_DRIVER=d3d12 timeout 15 glxinfo -B 2>/dev/null | grep -q "renderer string:.*D3D12"; then
        export GALLIUM_DRIVER=d3d12
    fi
fi
RENDERER="$(timeout 15 glxinfo -B 2>/dev/null | sed -n 's/.*renderer string: //p')"
echo "[start_sim] OpenGL renderer: ${RENDERER:-unknown}"
case "${RENDERER}" in
    *llvmpipe*|*softpipe*|"")
        echo "[start_sim] WARNING: no GPU acceleration -- Gazebo will be slow."
        echo "[start_sim]   WSL: run 'wsl --update' in PowerShell and update your Windows GPU driver."
        echo "[start_sim]   Linux: make sure you're in the 'render' and 'video' groups." ;;
esac

# The lite world holds real time far better (the full one's extras stall the physics);
# set WORLD to override.
export WORLD="${WORLD:-${SCRIPT_DIR}/sim/blueboat_waves_lite.sdf}"

# Same DDS setup the team code expects (UDP only, domain 10).
export ROS_DOMAIN_ID="${ROS_DOMAIN_ID:-10}"
export FASTRTPS_DEFAULT_PROFILES_FILE="${SCRIPT_DIR}/sim/fastdds_udp.xml"
export RMW_FASTRTPS_USE_QOS_FROM_XML=1

exec "${SCRIPT_DIR}/sim/launch_blueboat.sh" "$@"
