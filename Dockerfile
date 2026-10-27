# --- ArduPilot SITL build stage ---
# Builds the same ArduRover the real boat runs, compiled to run on a PC.
FROM ubuntu:24.04 AS ardupilot
ARG ARDUPILOT_VERSION=Rover-4.7.1
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates g++ git python3 python3-empy python3-pexpect \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /ardupilot
RUN git clone --depth 1 --branch "${ARDUPILOT_VERSION}" --recurse-submodules --shallow-submodules \
      https://github.com/ArduPilot/ardupilot.git . \
    && ./waf configure --board sitl \
    && ./waf rover

# --- Browser viewer build stage ---
# Bundles our viewer page (web/) with gzweb, the library behind
# app.gazebosim.org/visualization, into two static files
FROM node:24.22.1-bookworm-slim AS web
WORKDIR /web
COPY web/package.json web/package-lock.json ./
RUN npm ci --no-audit --no-fund
COPY web/index.html web/main.js ./
RUN npm run build

# --- Simulator image ---
FROM osrf/ros:jazzy-desktop-full

# The ArduPilot plugin reads this to pick which Gazebo version to build against
ENV GZ_VERSION=harmonic

RUN apt-get update && apt-get install -y ros-jazzy-ros-gz python3-vcstool \
    && rm -rf /var/lib/apt/lists/*

# Pre-download the Fuel models the RoboBoat course needs, so running the sim
# never depends on fuel.gazebosim.org being reachable. Fuel sometimes reports
# success without saving anything, so check each model landed and retry.
RUN . /opt/ros/jazzy/setup.sh && for m in \
      openrobotics/models/nathan_benderson_park \
      ngxingyu/models/surmark46104white \
      ngxingyu/models/surmark950400 \
      ngxingyu/models/surmark950410 ; do \
      for try in 1 2 3 4 5 ; do \
        gz fuel download -u "https://fuel.gazebosim.org/1.0/$m" -v 2 ; \
        [ -d "/root/.gz/fuel/fuel.gazebosim.org/$m" ] && break ; \
        sleep 10 ; \
      done ; \
      [ -d "/root/.gz/fuel/fuel.gazebosim.org/$m" ] || { echo "Could not download $m" ; exit 1 ; } ; \
    done

# Download the packages listed in sim.repos into /ws/src
WORKDIR /ws
COPY sim.repos .
RUN mkdir src && vcs import src < sim.repos

# Install what those packages need. gz-cmake3 and gz-sim8 are skipped because
# ROS Jazzy already ships Gazebo Harmonic
RUN apt-get update && rosdep update \
    && rosdep install --from-paths src --ignore-src -y --skip-keys "gz-cmake3 gz-sim8" \
    && rm -rf /var/lib/apt/lists/*

RUN . /opt/ros/jazzy/setup.sh \
    && colcon build --cmake-args -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=OFF \
    && rm -rf build log

# MAVProxy: forwards ArduPilot's MAVLink to QGroundControl, and is the ArduPilot terminal.
# It gets its own Python environment so it can't replace the numpy ROS depends on.
RUN apt-get update && apt-get install -y python3-venv \
    && rm -rf /var/lib/apt/lists/* \
    && python3 -m venv /opt/mavproxy \
    && /opt/mavproxy/bin/pip install --no-cache-dir MAVProxy==1.8.75 \
    && ln -s /opt/mavproxy/bin/mavproxy.py /usr/local/bin/mavproxy.py

# MAVROS: carries ROS messages to and from ArduPilot. GeographicLib's geoid data
# converts between GPS heights and sea level.
RUN apt-get update && apt-get install -y ros-jazzy-mavros \
    && rm -rf /var/lib/apt/lists/* \
    && /opt/ros/jazzy/lib/mavros/install_geographiclib_datasets.sh

# Viewers: the Foxglove bridge (ROS topics in Foxglove) and gz-launch, whose
# websocket server streams the world to the browser viewer
RUN apt-get update && apt-get install -y ros-jazzy-foxglove-bridge ros-jazzy-gz-launch-vendor \
    && rm -rf /var/lib/apt/lists/*

# The browser viewer page from the web stage
COPY --from=web /web/dist /sim/web

# ArduPilot SITL binary from the build stage
COPY --from=ardupilot /ardupilot/build/sitl/bin/ardurover /usr/local/bin/ardurover


# Our launch file and config. coug_gazebo's launch files read $CONFIG_DIR
ENV CONFIG_DIR=/sim/config
COPY config /sim/config
COPY launch /sim/launch
COPY setup.bash entrypoint.sh /sim/

# Interactive shells (docker compose exec sim bash) get the same setup
RUN echo "source /sim/setup.bash" >> /root/.bashrc

# Run through bash so a checkout without the execute bit (Windows) still works
ENTRYPOINT ["/bin/bash", "/sim/entrypoint.sh"]

CMD ["ros2", "launch", "/sim/launch/sim.launch.py"]

# Links the published image to this repo on GitHub
LABEL org.opencontainers.image.source=https://github.com/jenbensen17/y_boat_sim
