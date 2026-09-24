#!/usr/bin/env bash
# Test ROS 2 Vehicle Control for the BlueBoat Simulation
#
# This script executes the automated verification test (`test_boat_drive.py`),
# which connects to MAVROS, sets mode to GUIDED, arms the boat, drives forward
# using body-frame velocity, and verifies odometry movement.
#
# Run it from the host machine, in a second terminal, while the sim is up:
#   ./test_ros.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTAINER_NAME="${CONTAINER_NAME:-y_boat_sim}"

if [ -f "/.dockerenv" ]; then
    # We are inside the container: run the test python script directly
    source /opt/ros/jazzy/setup.bash
    export ROS_DOMAIN_ID="${ROS_DOMAIN_ID:-10}"
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
