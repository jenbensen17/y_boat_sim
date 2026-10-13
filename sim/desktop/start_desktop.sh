#!/usr/bin/env bash
# Container entrypoint: starts a virtual display with a window manager, shares it over
# VNC, serves noVNC on :6080 (Gazebo in the browser), then runs the sim on it.
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

# Gazebo fills the virtual screen once its window appears.
arrange_windows() {
    local w
    for _ in $(seq 180); do
        w="$(xdotool search --onlyvisible --name '^Gazebo.Sim' 2>/dev/null | head -1)" || true
        if [ -n "${w}" ]; then
            sleep 2
            xdotool windowmove "${w}" 0 0 windowsize "${w}" 100% 100% 2>/dev/null || true
            return
        fi
        sleep 1
    done
}
arrange_windows &

# VNC stays inside the container (-localhost); only noVNC's port is published.
x11vnc -display :1 -localhost -forever -shared -nopw -quiet -rfbport 5900 > /tmp/x11vnc.log 2>&1 &
websockify --web /usr/share/novnc 6080 localhost:5900 > /tmp/novnc.log 2>&1 &

echo "[desktop] Browser desktop: http://localhost:6080/vnc.html?autoconnect=1&resize=scale"
exec "${SIM_DIR}/launch_blueboat.sh"
