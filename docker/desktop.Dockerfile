# Browser desktop on top of the sim image: Gazebo, QGroundControl and the ArduPilot
# console run on a virtual display inside the container, viewed at
# http://localhost:6080 through noVNC. No display or input passthrough to the host,
# so it behaves the same on Windows, macOS and Linux.
#
# Thin layer for now; fold it into Dockerfile.sim when the image is next rebuilt.
ARG BASE_IMAGE=jenbensen17/y_boat_sim:latest
FROM ${BASE_IMAGE}

USER root
RUN apt-get update && apt-get install -y --no-install-recommends \
        xvfb x11vnc novnc websockify openbox x11-utils xdotool \
        ros-jazzy-foxglove-bridge \
    && rm -rf /var/lib/apt/lists/*
USER simuser
# Exists in the image so the qgc-config volume mounted here is owned by simuser.
RUN mkdir -p /home/simuser/.config/QGroundControl
