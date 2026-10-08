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

# Same DDS setup the team code expects (UDP only, domain 10).
export ROS_DOMAIN_ID="${ROS_DOMAIN_ID:-10}"
export FASTRTPS_DEFAULT_PROFILES_FILE="${SCRIPT_DIR}/sim/fastdds_udp.xml"
export RMW_FASTRTPS_USE_QOS_FROM_XML=1

exec "${SCRIPT_DIR}/sim/launch_blueboat.sh" "$@"
