#!/usr/bin/env bash
# One-command bringup of the BlueBoat scratch sim:
#   Gazebo (BlueBoat + calm-water hydrodynamics)
#   ArduPilot Rover SITL  (via ardupilot_gazebo JSON interface)
#   ros_gz_bridge         (/clock + /sim/ground_truth/odom)
#   MAVROS                (udp://127.0.0.1:14551@, use_sim_time:=true)
#
# Run this INSIDE the sim container. On the host you never call it directly --
# ./run_sim.sh starts the container and runs this as its command.
#
#   ./launch_blueboat.sh              # DEFAULT: Gazebo GUI + ArduPilot/MAVProxy console
#                                     #          + ros_gz_bridge + MAVROS + QGroundControl
#   QGC=0 ./launch_blueboat.sh        # same, without QGroundControl
#   HEADLESS=1 ./launch_blueboat.sh   # no GUI at all (implies no QGC, no console/map)
#   WITH_ROS=0 ./launch_blueboat.sh   # Gazebo + SITL only (pre-Step-1c behaviour)
#
# Ctrl+C shuts all of it down.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

WORLD="${WORLD:-${SCRIPT_DIR}/blueboat_waves.sdf}"
PARAM_FILE="${PARAM_FILE:-${SCRIPT_DIR}/blueboat.parm}"
# Open water on Utah Lake (~5.5 km west of Utah Lake State Park, Provo UT):
# lat,lon,alt,heading. MUST match <spherical_coordinates> in the world file.
HOME_LOCATION="${HOME_LOCATION:-40.2386,-111.8000,1368,0}"
# 14550 = general GCS output, 14551 = dedicated MAVROS endpoint.
MAVLINK_OUTS="${MAVLINK_OUTS:-127.0.0.1:14550 127.0.0.1:14551}"
MAVROS_FCU_URL="${MAVROS_FCU_URL:-udp://127.0.0.1:14551@}"
HEADLESS="${HEADLESS:-0}"
WITH_ROS="${WITH_ROS:-1}"
# QGroundControl is ON by default: the intended default experience is Gazebo + the
# ArduPilot/MAVProxy console + QGC showing the boat on the map. It auto-connects to
# UDP 14550 (MAVProxy's GCS output); MAVROS keeps 14551. Needs a display, so it is
# skipped automatically when HEADLESS=1. Set QGC=0 to leave it out.
QGC="${QGC:-1}"

# ROS's setup.bash references unbound variables (AMENT_TRACE_SETUP_FILES), so `set -u`
# must be relaxed across the source or the script dies immediately.
set +u
source /opt/ros/jazzy/setup.bash
set -u

GZ_PID=""
SITL_PID=""
BRIDGE_PID=""
MAVROS_PID=""
QGC_PID=""

cleanup() {
    echo ""
    echo "[launch] shutting down..."
    # 1. Graceful SIGTERM
    for pid in "${QGC_PID}" "${MAVROS_PID}" "${BRIDGE_PID}" "${SITL_PID}" "${GZ_PID}"; do
        [ -n "${pid}" ] && kill -TERM "${pid}" 2>/dev/null || true
    done
    pkill -TERM -f 'bin/ardurover'     2>/dev/null || true
    pkill -TERM -f 'mavproxy.py'       2>/dev/null || true
    pkill -TERM -f 'sim_vehicle.py'    2>/dev/null || true
    pkill -TERM -f 'mavros_node'       2>/dev/null || true
    pkill -TERM -f 'parameter_bridge'  2>/dev/null || true
    pkill -TERM -f 'QGroundControl'    2>/dev/null || true
    pkill -TERM -f 'qgroundcontrol'    2>/dev/null || true
    pkill -TERM -f 'gz sim'            2>/dev/null || true

    sleep 1

    # 2. Force kill (-9) anything that hung (QGC MAVLink/GStreamer threads often ignore SIGTERM)
    for pid in "${QGC_PID}" "${MAVROS_PID}" "${BRIDGE_PID}" "${SITL_PID}" "${GZ_PID}"; do
        [ -n "${pid}" ] && kill -9 "${pid}" 2>/dev/null || true
    done
    pkill -9 -f 'QGroundControl'    2>/dev/null || true
    pkill -9 -f 'qgroundcontrol'    2>/dev/null || true
    pkill -9 -f 'bin/ardurover'     2>/dev/null || true
    pkill -9 -f 'mavproxy.py'       2>/dev/null || true
    pkill -9 -f 'sim_vehicle.py'    2>/dev/null || true
    pkill -9 -f 'mavros_node'       2>/dev/null || true
    pkill -9 -f 'parameter_bridge'  2>/dev/null || true
    pkill -9 -f 'gz sim'            2>/dev/null || true
    pkill -9 -f 'xterm'             2>/dev/null || true

    echo "[launch] done."
    exit 0
}
trap cleanup EXIT INT TERM

# Refuse to start on top of a previous run rather than failing confusingly later.
# (iproute2 is installed as of Step 1c, so `ss` actually exists in the container now.)
if ! command -v ss >/dev/null 2>&1; then
    echo "[launch] WARNING: 'ss' not found - skipping the port pre-flight check."
else
    for port in 5760 5762 5763; do
        if ss -ltn 2>/dev/null | grep -qE "[:.]${port}[[:space:]]"; then
            echo "[launch] ERROR: port ${port} already in use - a previous SITL is still running."
            ss -ltnp 2>/dev/null | grep -E "[:.]${port}[[:space:]]"
            exit 1
        fi
    done
fi

echo "[launch] world:    ${WORLD}"
echo "[launch] params:   ${PARAM_FILE}"
echo "[launch] home:     ${HOME_LOCATION}"
GZ_GUI="${GZ_GUI:-1}"
GZ_HEADLESS="${GZ_HEADLESS:-0}"
if [ "${GZ_GUI}" = "0" ] || [ "${GZ_HEADLESS}" = "1" ] || [ "${HEADLESS}" = "1" ]; then
    GZ_SERVER_ONLY=1
else
    GZ_SERVER_ONLY=0
fi

echo "[launch] headless: ${HEADLESS}   gz_gui: ${GZ_GUI}   with_ros: ${WITH_ROS}"

# --- Gazebo ---------------------------------------------------------------
if [ "${GZ_SERVER_ONLY}" = "1" ]; then
    echo "[launch] Starting Gazebo in SERVER-ONLY mode (physics headless, no 3D GUI lag)..."
    gz sim -v4 -r -s "${WORLD}" > /tmp/gz_blueboat.log 2>&1 &
else
    echo "[launch] Starting Gazebo in full 3D GUI mode..."
    gz sim -v4 -r "${WORLD}" > /tmp/gz_blueboat.log 2>&1 &
fi
GZ_PID=$!
echo "[launch] Gazebo started (pid ${GZ_PID}), log: /tmp/gz_blueboat.log"

# Wait for the ArduPilot plugin before starting SITL so its first JSON packets land.
for _ in $(seq 1 60); do
    grep -q "ArduPilotPlugin" /tmp/gz_blueboat.log 2>/dev/null && break
    sleep 1
done
echo "[launch] ArduPilot plugin loaded."

# --- ArduPilot SITL -------------------------------------------------------
OUT_ARGS=()
for out in ${MAVLINK_OUTS}; do
    OUT_ARGS+=(--out "${out}")
done

SITL_ARGS=(
    -v Rover
    -f rover-skid
    --model JSON
    --no-rebuild
    --add-param-file="${PARAM_FILE}"
    --custom-location="${HOME_LOCATION}"
    "${OUT_ARGS[@]}"
)

if [ "${HEADLESS}" = "1" ]; then
    # --daemon is essential: with no terminal (cron, `docker exec -d`, CI) MAVProxy's
    # console reads stdin, hits immediate EOF, exits, and sim_vehicle.py then tears down
    # the vehicle binary too. --daemon runs MAVProxy with no console so it survives.
    ( cd "${HOME}/ardupilot" && unset DISPLAY && \
        sim_vehicle.py "${SITL_ARGS[@]}" --mavproxy-args="--daemon" ) &
    SITL_PID=$!
else
    # Launch ArduPilot SITL and MAVProxy inside a dedicated xterm window.
    # SITL_RITW_TERMINAL="sh" runs ardurover directly in the background so no extra
    # xterm is spawned for the vehicle binary.
    # --console and --map are omitted so MAVProxy's Tk GUI windows do not appear.
    # Result: exactly 3 GUI windows total (Gazebo, QGroundControl, and ArduPilot terminal).
    export SITL_RITW_TERMINAL="sh"
    xterm -T "ArduPilot (MAVProxy)" -geometry 110x32 -sb -sl 2000 -e bash -c \
        "cd '${HOME}/ardupilot' && python3 '${HOME}/ardupilot/Tools/autotest/sim_vehicle.py' ${SITL_ARGS[*]}" &
    SITL_PID=$!
fi
echo "[launch] SITL started in xterm (pid ${SITL_PID})"

# --- ROS 2: bridge + MAVROS ----------------------------------------------
if [ "${WITH_ROS}" = "1" ]; then
    ros2 launch "${SCRIPT_DIR}/launch/sim_bridge.launch.py" \
        > /tmp/sim_bridge.log 2>&1 &
    BRIDGE_PID=$!
    echo "[launch] ros_gz_bridge started (pid ${BRIDGE_PID}), log: /tmp/sim_bridge.log"

    # Give SITL a moment to be listening before MAVROS starts hunting for a heartbeat.
    sleep 10
    ros2 launch "${SCRIPT_DIR}/launch/mavros_sim.launch.py" \
        fcu_url:="${MAVROS_FCU_URL}" > /tmp/mavros.log 2>&1 &
    MAVROS_PID=$!
    echo "[launch] MAVROS started (pid ${MAVROS_PID}) on ${MAVROS_FCU_URL}, log: /tmp/mavros.log"
fi

# --- QGroundControl -------------------------------------------------------
if [ "${QGC}" = "1" ]; then
    if [ "${HEADLESS}" = "1" ]; then
        echo "[launch] QGC=1 ignored: HEADLESS=1 means there is no display to draw on."
    elif ! command -v qgroundcontrol >/dev/null 2>&1; then
        echo "[launch] QGC=1 requested but 'qgroundcontrol' is not on PATH (rebuild the image)."
    elif [ "$(id -u)" = "0" ]; then
        # QGC hard-refuses to run as root; catch it here with a clear message rather
        # than letting QGC exit with its own.
        echo "[launch] QGC=1 ignored: QGroundControl refuses to run as root."
    else
        # Same display environment as Gazebo (DISPLAY + the X11 socket mount come from
        # run_sim.sh); QT_QPA_PLATFORM=xcb keeps Qt off Wayland under XWayland.
        QT_QPA_PLATFORM="${QT_QPA_PLATFORM:-xcb}" qgroundcontrol \
            > /tmp/qgc.log 2>&1 &
        QGC_PID=$!
        echo "[launch] QGroundControl started (pid ${QGC_PID}), log: /tmp/qgc.log"
        echo "[launch]   QGC auto-connects on UDP 14550; MAVROS holds 14551."
    fi
fi

echo "[launch] MAVLink: tcp:5760 (primary), 5762/5763 (aux), UDP out: ${MAVLINK_OUTS}"
echo ""
echo "======================================================================"
echo "[launch] Simulator is READY!"
echo "[launch] Active components:"
if [ "${GZ_SERVER_ONLY}" = "0" ]; then
    echo "[launch]   1. Gazebo Sim (3D boat in water)"
else
    echo "[launch]   1. Gazebo Sim (server-only physics running at full speed - no 3D GUI)"
fi
if [ "${HEADLESS}" = "0" ] && [ "${QGC}" = "1" ]; then
    echo "[launch]   2. QGroundControl GUI (telemetry & map)"
fi
if [ "${HEADLESS}" = "0" ]; then
    echo "[launch]   3. ArduPilot Terminal (MAVProxy in xterm)"
fi
echo "[launch]"
echo "[launch] To run the ROS 2 verification test from another host terminal:"
echo "[launch]   ./test_ros.sh"
echo "[launch] Or to open a bash shell in the running container:"
echo "[launch]   docker exec -it y_boat_sim bash"
echo "======================================================================"
echo "[launch] Press Ctrl+C to stop all simulator components."

wait
