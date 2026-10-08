#!/usr/bin/env bash
# Test ROS 2 Vehicle Control for the BlueBoat Simulation
#
# This script executes the automated verification test (`test_boat_drive.py`),
# which connects to MAVROS, sets mode to GUIDED, arms the boat, drives forward
# using body-frame velocity, and verifies odometry movement.
#
# Run it in a second terminal while the sim is up (native install or Docker):
#   ./test_ros.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTAINER_NAME="${CONTAINER_NAME:-y_boat_sim}"

if [ -f "/opt/ros/jazzy/setup.bash" ]; then
    # ROS 2 Jazzy is installed here (native install via setup_native.sh, or inside the
    # sim container): run the test directly, with the same DDS settings as the sim.
    # ROS's setup.bash references unset variables, so relax `set -u` across it.
    set +u; source /opt/ros/jazzy/setup.bash; set -u
    export ROS_DOMAIN_ID="${ROS_DOMAIN_ID:-10}"
    export FASTRTPS_DEFAULT_PROFILES_FILE="${FASTRTPS_DEFAULT_PROFILES_FILE:-${SCRIPT_DIR}/sim/fastdds_udp.xml}"
    export RMW_FASTRTPS_USE_QOS_FROM_XML=1
    python3 "${SCRIPT_DIR}/tests/test_boat_drive.py" "$@"
else
    # We are on the host: check if the simulation container is running
    if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        echo "[ERROR] Simulation container '${CONTAINER_NAME}' is not running!"
        echo ""
        echo "Please start the simulator first with:"
        echo "  ./run_sim.sh"
        echo ""
        echo "Once the windows (Gazebo, QGroundControl, ArduPilot terminal) appear,"
        echo "re-run this script in another terminal:"
        echo "  ./test_ros.sh"
        exit 1
    fi

    EXEC_TTY=""
    if [ -t 0 ] && [ -t 1 ]; then
        EXEC_TTY="-it"
    else
        EXEC_TTY="-i"
    fi

    echo "[test_ros] Running verification test inside container '${CONTAINER_NAME}'..."
    docker exec ${EXEC_TTY} "${CONTAINER_NAME}" bash -c \
        "source /opt/ros/jazzy/setup.bash && export ROS_DOMAIN_ID=\"\${ROS_DOMAIN_ID:-10}\" && python3 /home/simuser/sim_scratch/tests/test_boat_drive.py $*"
fi
