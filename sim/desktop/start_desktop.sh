#!/usr/bin/env bash
# Container entrypoint for the browser desktop: starts a virtual display with a window
# manager, shares it over VNC, serves noVNC on :6080, then runs the sim on it.
#
#   http://localhost:6080/vnc.html?autoconnect=1&resize=scale
#
# Rendering uses whatever GALLIUM_DRIVER the launcher picked (d3d12 = GPU on WSL);
# otherwise Mesa renders on the CPU.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SIM_DIR="$(dirname "${SCRIPT_DIR}")"
GEOMETRY="${DESKTOP_GEOMETRY:-1920x1080}"
export DISPLAY=:1

Xvfb :1 -screen 0 "${GEOMETRY}x24" -nolisten tcp > /tmp/xvfb.log 2>&1 &
for _ in $(seq 50); do xdpyinfo >/dev/null 2>&1 && break; sleep 0.1; done

openbox > /tmp/openbox.log 2>&1 &

# Lay the windows out once they appear: Gazebo on the left two-thirds, QGroundControl
# top-right, the ArduPilot console bottom-right (sized for the default 1920x1080).
# QGroundControl is found by window class: its visible window isn't the one xdotool
# matches by name. It also re-centers itself after loading, hence the second pass.
place() {  # <xdotool search args> <x> <y> <w> <h>; succeeds once the window is placed
    local w
    w="$(xdotool search --onlyvisible $1 2>/dev/null | head -1)" || true
    [ -n "${w}" ] && xdotool windowmove "${w}" "$2" "$3" windowsize "${w}" "$4" "$5" 2>/dev/null
}
arrange_windows() {
    local gz="" qgc="" ap=""
    for _ in $(seq 180); do
        [ -n "${gz}" ]  || { place "--name ^Gazebo.Sim" 0 0 1280 1050 && gz=1; }
        [ -n "${qgc}" ] || { place "--class QGroundControl" 1280 0 640 620 && qgc=1; }
        [ -n "${ap}" ]  || { place "--name ^ArduPilot" 1280 640 640 410 && ap=1; }
        [ -n "${gz}${qgc}${ap}" ] && [ "${gz}${qgc}${ap}" = "111" ] && break
        sleep 1
    done
    sleep 15
    place "--name ^Gazebo.Sim" 0 0 1280 1050 || true
    place "--class QGroundControl" 1280 0 640 620 || true
    place "--name ^ArduPilot" 1280 640 640 410 || true
}
arrange_windows &

# VNC stays inside the container (-localhost); only noVNC's port is published.
x11vnc -display :1 -localhost -forever -shared -nopw -quiet -rfbport 5900 > /tmp/x11vnc.log 2>&1 &
websockify --web /usr/share/novnc 6080 localhost:5900 > /tmp/novnc.log 2>&1 &

echo "[desktop] Browser desktop: http://localhost:6080/vnc.html?autoconnect=1&resize=scale"
exec "${SIM_DIR}/launch_blueboat.sh"
