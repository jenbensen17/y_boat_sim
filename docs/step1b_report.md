# RoboBoat Step 1b Report — BlueBoat in Gazebo via ArduPilot Gazebo plugin

Goal: a simulated BlueBoat floating in Gazebo Harmonic, driven by ArduPilot SITL through
the ArduPilot Gazebo plugin (JSON interface). No ROS 2 bridge, MAVROS or Nav2 yet.

Work confined to `~/y_boat/sim_scratch/`. `~/y_boat/y_boat_core` was **not** touched.

**Outcome: goal achieved, with one caveat.** The BlueBoat floats on asv_wave_sim
hydrodynamics, SITL drives it through the plugin, it arms with all pre-arm checks active,
and it completes an AUTO mission and reaches a GUIDED target. The caveat is *quality of
control*, not plumbing: waypoint tracking is poor (mean cross-track error 12.6 m on 25 m
legs) and needs tuning.

Also of note: the Step 1a conclusion that "SITL leaves arming checks off" was **wrong**,
and is corrected below.

## Changes to Dockerfile.sim

Everything before the `Step 1b` banner is unchanged from Step 1a except one line:
`./waf rover` became `./waf rover copter` (the plugin ships no rover example world, so its
built-in sanity check is the iris one, which needs an ArduCopter binary; building it at
runtime would have violated the "installs go in the Dockerfile" rule).

Full file:

```dockerfile
FROM osrf/ros:jazzy-desktop-full

ARG USERNAME=simuser
ARG USER_UID=1000
ARG USER_GID=1000

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    ros-jazzy-ros-gz \
    mesa-utils \
    sudo \
    git \
    python3-pip \
    && rm -rf /var/lib/apt/lists/*

# osrf/ros:jazzy-desktop-full already ships a UID/GID 1000 user named "ubuntu"
# (matches typical host UID/GID), so rename it instead of creating a fresh one.
RUN usermod -l ${USERNAME} -m -d /home/${USERNAME} -s /bin/bash ubuntu \
    && groupmod -n ${USERNAME} ubuntu \
    && echo "${USERNAME} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/${USERNAME} \
    && chmod 0440 /etc/sudoers.d/${USERNAME}

USER ${USERNAME}
# install-prereqs-ubuntu.sh calls `sudo usermod -a -G dialout $USER`, but Docker's
# USER instruction does not set the $USER env var for subsequent RUN shells — set it
# explicitly or that call fails with a usermod usage error (missing LOGIN arg).
ENV USER=${USERNAME}
WORKDIR /home/${USERNAME}

RUN git clone --recurse-submodules https://github.com/ArduPilot/ardupilot.git

WORKDIR /home/${USERNAME}/ardupilot
RUN Tools/environment_install/install-prereqs-ubuntu.sh -y

ENV PATH="/home/${USERNAME}/.local/bin:/home/${USERNAME}/ardupilot/Tools/autotest:${PATH}"

# rover is the boat target; copter is needed only to run ardupilot_gazebo's own
# iris_runway.sdf example, which is the plugin's built-in sanity check.
RUN ./waf configure --board sitl && ./waf rover copter

RUN echo "source /opt/ros/jazzy/setup.bash" >> /home/${USERNAME}/.bashrc \
    && echo "export PATH=\$HOME/.local/bin:\$HOME/ardupilot/Tools/autotest:\$PATH" >> /home/${USERNAME}/.bashrc

# ---------------------------------------------------------------------------
# Step 1b: ArduPilot Gazebo plugin (Harmonic, JSON interface)
# ---------------------------------------------------------------------------
USER root
RUN apt-get update && apt-get install -y \
    rapidjson-dev \
    libopencv-dev \
    libgstreamer1.0-dev \
    libgstreamer-plugins-base1.0-dev \
    gstreamer1.0-plugins-base \
    gstreamer1.0-plugins-good \
    gstreamer1.0-plugins-bad \
    gstreamer1.0-plugins-ugly \
    gstreamer1.0-libav \
    gstreamer1.0-gl \
    && rm -rf /var/lib/apt/lists/*
USER ${USERNAME}

ENV GZ_VERSION=harmonic

# ardupilot_gazebo's docs assume a standalone `libgz-sim8-dev` from the OSRF apt repo.
# That package is not available here: Gazebo Harmonic comes from the ros-jazzy-gz-*-vendor
# packages under /opt/ros/jazzy/opt/*_vendor, so the build must source the ROS setup to
# put those cmake configs (gz-sim8-config.cmake etc.) on CMAKE_PREFIX_PATH.
RUN git clone https://github.com/ArduPilot/ardupilot_gazebo.git /home/${USERNAME}/ardupilot_gazebo
WORKDIR /home/${USERNAME}/ardupilot_gazebo
RUN bash -c 'source /opt/ros/jazzy/setup.bash \
    && mkdir -p build && cd build \
    && cmake .. -DCMAKE_BUILD_TYPE=RelWithDebInfo \
    && make -j$(nproc)'

# ---------------------------------------------------------------------------
# Step 1b: BlueBoat model + asv_wave_sim hydrodynamics
# ---------------------------------------------------------------------------
USER root
# CGAL (mesh manipulation) and FFTW (Fourier transforms) are asv_wave_sim's documented deps.
RUN apt-get update && apt-get install -y \
    libcgal-dev \
    libfftw3-dev \
    && rm -rf /var/lib/apt/lists/*
USER ${USERNAME}

RUN git clone https://github.com/ArduPilot/SITL_Models.git /home/${USERNAME}/SITL_Models

# asv_wave_sim's README targets Gazebo Garden ("or later"); its CI is Jammy + gz-sim 7.1.0.
# Harmonic (gz-sim8) is not explicitly claimed, so this build is the compatibility test.
RUN mkdir -p /home/${USERNAME}/gz_ws/src \
    && git clone https://github.com/srmainwaring/asv_wave_sim.git \
       /home/${USERNAME}/gz_ws/src/asv_wave_sim
WORKDIR /home/${USERNAME}/gz_ws
# asv_wave_sim's gz-waves/CMakeLists.txt calls gz_find_package(GzOGRE2 ...), and
# gz-cmake's FindGzOGRE2.cmake locates OGRE-Next through pkg-config. The ROS vendor
# packages keep their .pc files in gz_ogre_next_vendor/lib/pkgconfig, which is NOT on
# PKG_CONFIG_PATH after sourcing the ROS setup — so GzOGRE2 was silently not found and
# the build died with "Target ... links to: GzOGRE2::GzOGRE2 but the target was not found".
ENV PKG_CONFIG_PATH=/opt/ros/jazzy/opt/gz_ogre_next_vendor/lib/pkgconfig
RUN bash -c 'source /opt/ros/jazzy/setup.bash \
    && colcon build --symlink-install --merge-install --cmake-args \
       -DCMAKE_BUILD_TYPE=RelWithDebInfo \
       -DBUILD_TESTING=ON \
       -DCMAKE_CXX_STANDARD=17'

# The gz-waves *-system plugins link against libgz-waves1.so.1 / libgz-waves1-rendering.so.1,
# which live in the colcon merge-install lib dir. Without this the plugins are found but
# fail to load with "libgz-waves1.so.1: cannot open shared object file".
# (Equivalent to the README's `source ~/gz_ws/install/setup.bash`, but always in effect.)
ENV LD_LIBRARY_PATH=/home/${USERNAME}/gz_ws/install/lib:${LD_LIBRARY_PATH}
ENV GZ_SIM_SYSTEM_PLUGIN_PATH=/home/${USERNAME}/ardupilot_gazebo/build:/home/${USERNAME}/gz_ws/install/lib
ENV GZ_SIM_RESOURCE_PATH=/home/${USERNAME}/ardupilot_gazebo/models:/home/${USERNAME}/ardupilot_gazebo/worlds:/home/${USERNAME}/SITL_Models/Gazebo/models:/home/${USERNAME}/SITL_Models/Gazebo/worlds:/home/${USERNAME}/gz_ws/src/asv_wave_sim/gz-waves-models/models:/home/${USERNAME}/gz_ws/src/asv_wave_sim/gz-waves-models/world_models:/home/${USERNAME}/gz_ws/src/asv_wave_sim/gz-waves-models/worlds

WORKDIR /home/${USERNAME}
CMD ["bash"]
```

## run_sim_scratch.sh and launch_blueboat.sh

### run_sim_scratch.sh

```bash
#!/usr/bin/env bash
set -euo pipefail

IMAGE="${IMAGE:-y_boat_sim_scratch:latest}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Display / transport env vars. Defaults are the values proven in Step 1a on this host
# (NVIDIA hybrid laptop GPU + Hyprland/XWayland); override from the environment for
# other machines, e.g. GLX_VENDOR= NV_PRIME= ./run_sim_scratch.sh
GLX_VENDOR="${GLX_VENDOR:-nvidia}"
NV_PRIME="${NV_PRIME:-1}"
QT_PLATFORM="${QT_PLATFORM:-xcb}"
GZ_IP_ADDR="${GZ_IP_ADDR:-127.0.0.1}"

# XHOST_MODE=si       -> xhost +SI:localuser:$(id -un)   (default, least privilege)
# XHOST_MODE=fallback -> xhost +local:                   (all local connections)
XHOST_MODE="${XHOST_MODE:-si}"

XHOST_ENTRY=""
XHOST_ADDED_BY_US=0

grant_xhost() {
    local entry
    if [ "${XHOST_MODE}" = "fallback" ]; then
        entry="local:"
    else
        entry="SI:localuser:$(id -un)"
    fi
    XHOST_ENTRY="${entry}"

    # Only revoke on exit what we actually added. The desktop session usually already
    # grants SI:localuser:<user>; revoking that would break X for the user's own apps.
    if xhost 2>/dev/null | grep -qF -- "${entry}"; then
        echo "[xhost] '${entry}' already granted by the session; leaving it alone."
        XHOST_ADDED_BY_US=0
    else
        echo "[xhost] granting '+${entry}' (mode=${XHOST_MODE})"
        xhost "+${entry}" >/dev/null
        XHOST_ADDED_BY_US=1
    fi
    echo "[xhost] using mode='${XHOST_MODE}' entry='${entry}'"
    echo "[xhost] if the GUI does not appear, retry with: XHOST_MODE=fallback $0 $*"
}

cleanup() {
    if [ "${XHOST_ADDED_BY_US}" = "1" ] && [ -n "${XHOST_ENTRY}" ]; then
        echo "[xhost] revoking '-${XHOST_ENTRY}' (added by this script)"
        xhost "-${XHOST_ENTRY}" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT INT TERM

check_ports() {
    # SITL MAVLink serial ports and the ArduPilot<->Gazebo JSON interface ports.
    # With --network host these are host-global, so a stale process silently blocks startup.
    local busy=0
    local listing
    listing="$( { ss -ltnp 2>/dev/null; ss -lunp 2>/dev/null; } || true )"

    for port in 5760 5761 5762 5763 9002 9003; do
        local hit
        hit="$(printf '%s\n' "${listing}" | grep -E "[:.]${port}[[:space:]]" || true)"
        if [ -n "${hit}" ]; then
            busy=1
            echo "[ports] WARNING: port ${port} is already in use:"
            printf '%s\n' "${hit}" | sed 's/^/          /'
        fi
    done

    if [ "${busy}" = "1" ]; then
        echo "[ports] A stale ardurover/gz process will make SITL fail with"
        echo "        'bind failed on port 5760 - Address already in use'."
        echo "        Stop the owning container/process before continuing."
    else
        echo "[ports] 5760-5763 and 9002/9003 are free."
    fi
}

grant_xhost "$@"
check_ports

docker run --rm -it --init \
    --gpus all \
    -e NVIDIA_DRIVER_CAPABILITIES=all \
    --network host \
    -e DISPLAY="${DISPLAY}" \
    -e __NV_PRIME_RENDER_OFFLOAD="${NV_PRIME}" \
    -e __GLX_VENDOR_LIBRARY_NAME="${GLX_VENDOR}" \
    -e QT_QPA_PLATFORM="${QT_PLATFORM}" \
    -e GZ_IP="${GZ_IP_ADDR}" \
    -v /tmp/.X11-unix:/tmp/.X11-unix \
    -v "${SCRIPT_DIR}:/home/simuser/sim_scratch" \
    "${IMAGE}" \
    "${@:-bash}"
```

Task-0 items, and how each was handled:
- **xhost** — `+SI:localuser:$(id -un)` by default; `XHOST_MODE=fallback` switches to
  `+local:`. The script prints which mode/entry it used and how to retry with the fallback.
- **Revoke trap** — `trap cleanup EXIT INT TERM`, but **conditional**. The desktop session
  already grants `SI:localuser:jenbensen` (seen in Step 1a's `xhost` output), so an
  unconditional revoke would strip the user's own X access for unrelated apps. The script
  records whether it added the entry and only revokes its own grant.
- **`--init`** — added, so orphaned children get reaped.
- **Port check** — 5760-5763 plus JSON ports 9002/9003, printing the owning process.
  Verified in both directions: reports free when idle, and with a deliberate listener on
  5760 prints
  `LISTEN 0 1 127.0.0.1:5760 ... users:(("python3",pid=916186,fd=3))`.
- **Overridable env** — `GLX_VENDOR`, `NV_PRIME`, `QT_PLATFORM`, `GZ_IP_ADDR` (plus
  `IMAGE`), all defaulting to the Step 1a values.

### launch_blueboat.sh

```bash
#!/usr/bin/env bash
# Bring up the full BlueBoat sim: Gazebo (waves world + BlueBoat) and ArduPilot Rover
# SITL connected over the ArduPilot Gazebo plugin's JSON interface.
#
# Run this INSIDE the sim container (start it with ./run_sim_scratch.sh).
#
#   ./launch_blueboat.sh              # Gazebo GUI + MAVProxy console/map
#   HEADLESS=1 ./launch_blueboat.sh   # Gazebo server only, no console/map
#
# Ctrl+C shuts down both Gazebo and SITL.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

WORLD="${WORLD:-${SCRIPT_DIR}/blueboat_waves.sdf}"
PARAM_FILE="${PARAM_FILE:-${SCRIPT_DIR}/blueboat.parm}"
# Utah Lake State Park, Provo UT: lat,lon,alt,heading.
# Must match <spherical_coordinates> in the world file.
HOME_LOCATION="${HOME_LOCATION:-40.2386,-111.7353,1368,0}"
# Dedicated UDP outs: 14550 for a GCS, 14551 reserved for MAVROS (Step 2).
MAVLINK_OUTS="${MAVLINK_OUTS:-127.0.0.1:14550 127.0.0.1:14551}"
HEADLESS="${HEADLESS:-0}"

# ROS's setup.bash references unbound variables (AMENT_TRACE_SETUP_FILES), so `set -u`
# must be relaxed across the source or the script dies immediately.
set +u
source /opt/ros/jazzy/setup.bash
set -u

GZ_PID=""
SITL_PID=""

cleanup() {
    echo ""
    echo "[launch] shutting down..."
    [ -n "${SITL_PID}" ] && kill -TERM "${SITL_PID}" 2>/dev/null
    [ -n "${GZ_PID}" ] && kill -TERM "${GZ_PID}" 2>/dev/null
    # sim_vehicle.py spawns the vehicle binary and MAVProxy as children; make sure the
    # vehicle binary dies too or it keeps host-global ports 5760-5763 bound and the next
    # run fails with "bind failed on port 5760 - Address already in use".
    pkill -f 'bin/ardurover' 2>/dev/null
    pkill -f 'gz sim' 2>/dev/null
    wait 2>/dev/null
    echo "[launch] done."
}
trap cleanup EXIT INT TERM

# Refuse to start on top of a previous run rather than failing confusingly later.
for port in 5760 5762 5763; do
    if ss -ltn 2>/dev/null | grep -qE "[:.]${port}[[:space:]]"; then
        echo "[launch] ERROR: port ${port} already in use - a previous SITL is still running."
        ss -ltnp 2>/dev/null | grep -E "[:.]${port}[[:space:]]"
        exit 1
    fi
done

echo "[launch] world:  ${WORLD}"
echo "[launch] params: ${PARAM_FILE}"
echo "[launch] home:   ${HOME_LOCATION}"
echo "[launch] headless: ${HEADLESS}"

if [ "${HEADLESS}" = "1" ]; then
    gz sim -v4 -r -s "${WORLD}" > /tmp/gz_blueboat.log 2>&1 &
else
    gz sim -v4 -r "${WORLD}" > /tmp/gz_blueboat.log 2>&1 &
fi
GZ_PID=$!
echo "[launch] Gazebo started (pid ${GZ_PID}), log: /tmp/gz_blueboat.log"

# Wait for the ArduPilot plugin to come up before starting SITL, so SITL's first JSON
# packets are not dropped.
for _ in $(seq 1 60); do
    grep -q "ArduPilotPlugin" /tmp/gz_blueboat.log 2>/dev/null && break
    sleep 1
done
echo "[launch] ArduPilot plugin loaded."

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
    # No console/map. Also unset DISPLAY so sim_vehicle.py does not wrap the vehicle
    # binary in an xterm, which hides its output.
    #
    # --daemon is essential: without a terminal (cron, `docker exec -d`, CI) MAVProxy's
    # interactive console reads stdin, hits immediate EOF, exits cleanly, and
    # sim_vehicle.py then tears down the vehicle binary too -- SITL appears to start and
    # instantly die ("SIM_VEHICLE: MAVProxy exited" / "Closed connection on SERIAL0").
    # --daemon runs MAVProxy with no console so it survives having no stdin.
    ( cd "${HOME}/ardupilot" && unset DISPLAY && \
        sim_vehicle.py "${SITL_ARGS[@]}" --mavproxy-args="--daemon" ) &
else
    ( cd "${HOME}/ardupilot" && sim_vehicle.py "${SITL_ARGS[@]}" --console --map ) &
fi
SITL_PID=$!
echo "[launch] SITL started (pid ${SITL_PID})"
echo "[launch] MAVLink: tcp:5760 (primary), 5762/5763 (aux), UDP out: ${MAVLINK_OUTS}"
echo "[launch] Ctrl+C to stop both."

wait
```

Home location is the `HOME_LOCATION` variable, defaulting to Utah Lake State Park, Provo UT
(`40.2386,-111.7353,1368,0`) rather than ArduPilot's CMAC/Canberra default.

Supporting files also produced: `blueboat_waves.sdf` (the world), `blueboat.parm`
(parameters), `blueboat_mission.txt` (QGC WPL mission), `drive_test.py` (MAVLink test
harness).

## Plugin build

**ardupilot_gazebo: built cleanly on the first attempt, no source changes.**

Versions: Gazebo Sim **8.11.0** (Harmonic), ROS 2 Jazzy, Ubuntu 24.04, ArduPilot
**V4.8.0-dev (b5fbe265)**, `GZ_VERSION=harmonic`.

```
[100%] Linking CXX shared library libArduPilotPlugin.so
[100%] Built target ArduPilotPlugin
[ 80%] Built target CameraZoomPlugin
[ 80%] Built target ParachutePlugin
[ 90%] Built target GstCameraPlugin
```
Compile ~13 s; incremental image build 43 s. Adding the copter target took the next
rebuild to 2m12s.

**The one deviation from upstream instructions:** `ardupilot_gazebo`'s README says
`apt install libgz-sim8-dev`. That package does not exist in this image —
`apt-cache policy libgz-sim8-dev` returns nothing, because the OSRF apt repo is not
configured. Harmonic here comes from the ROS vendor packages
(`ros-jazzy-gz-sim-vendor`, cmake config at
`/opt/ros/jazzy/opt/gz_sim_vendor/lib/cmake/gz-sim8/gz-sim8-config.cmake`). The build
therefore sources `/opt/ros/jazzy/setup.bash` first. I deliberately did **not** add the OSRF
repo, to avoid two competing Harmonic installs in one image.

### Sanity check (plugin's own example) — PASSED

`gz sim -v4 -r -s iris_runway.sdf` + `sim_vehicle.py -v ArduCopter -f gazebo-iris --model JSON`:

```
[Dbg] [SystemManager.cc:80] Loaded system [ArduPilotPlugin] for entity [15]
[Wrn] [ArduPilotPlugin.cc:1599] ArduPilot controller has reset
JSON control interface set to 127.0.0.1:9002
```
Commanded `takeoff 10`; Gazebo pose of the top-level model:
```
name: "iris_with_gimbal"  position { x: 0.0041  y: 0.0044  z: 10.1902 }
name: "iris_with_gimbal"  position { x: -0.0035 y: 0.0048  z: 10.1904 }   (3 s later)
```
Commanded 10 m, actual 10.19 m, stable — SITL genuinely drives Gazebo physics.

Two traps hit here, both documented in Problems: a `FRAME_CLASS` reboot requirement, and
misreading a *nested* model's pose as "the vehicle didn't move".

## Hydrodynamics / wave sim

**Used: `asv_wave_sim` (srmainwaring), master branch, built against Harmonic.** No fallback
buoyancy setup was needed.

The README advertises Garden ("or later") with CI on Jammy / gz-sim 7.1.0, so Harmonic was
genuinely in question. Inspecting `gz-waves/CMakeLists.txt` showed explicit Harmonic
branches (`gz-rendering8`, `gz-sim8`, `sdformat14`, selected by `GZ_VERSION`), so support is
real — and the build succeeded once two environment problems were fixed (both in Problems
below): a missing `PKG_CONFIG_PATH` for the vendored OGRE-Next, and a missing
`LD_LIBRARY_PATH` for the colcon install tree.

Result: `Finished <<< gz-waves1 [1min 1s]`, and all five plugins load —
`ArduPilotPlugin`, `Hydrodynamics`, `Thruster`, `WavesModel`, `WavesVisual`.

**World.** No ready-made BlueBoat world exists. SITL_Models ships `catamaran_waves.sdf`,
but that pulls in `asv_sim2` anemometer/wind plugins — a *different* package, for sailing.
Per BlueBoat.md the base is asv_wave_sim's `waves.sdf`, so `blueboat_waves.sdf` derives from
it with three additions that stock `waves.sdf` lacks and ArduPilot needs:
1. `gz-sim-navsat-system` — without it there is no GPS at all.
2. `<spherical_coordinates>` — the geodetic origin, which **must match** the
   `--custom-location` given to SITL or Gazebo and SITL disagree about where the boat is.
   Set to Utah Lake (40.2386, -111.7353, 1368 m).
3. The `model://blueboat` include.
Demo clutter from `waves.sdf` (duck, spherical_buoy, wam-v, barrage) was removed.

**Waves were then turned off at the user's request.** The wave field is driven by
`<wind_speed>` and `<steepness>`, which appear in *both* the WavesModel and WavesVisual
plugin blocks. SDF `<include>` provides no way to override a nested plugin's parameters, so
the waves model is **inlined** into the world with `wind_speed 0.0` / `steepness 0`, with
mesh and texture URIs rewritten to `model://waves/materials/...` so they still resolve to
the upstream model directory. The file documents how to restore waves.

Flotation measured from `/world/waves/pose/info`:

| condition | blueboat z samples | reading |
|---|---|---|
| waves on | -0.067, +0.357, +0.085 | floats, bobbing ±0.4 m |
| calm | 0.136, 0.142, 0.139, 0.141 | steady waterline, ±0.005 m |

Either way the hull floats — it neither sinks nor is ejected.

## Driving results

Tests were driven by `drive_test.py` over MAVLink (pymavlink) on **SERIAL1 / tcp:5762**, so
as not to disturb MAVProxy on SERIAL0.

### MANUAL — works (verified via MAVProxy, not via the test script)

With MAVProxy `rc 3 1900`, the boat moved from (-0.59, 0.31) to (-12.67, 9.37) in Gazebo:
**≈15.2 m in 12 s (~1.3 m/s)**, visibly moving in the GUI.

`drive_test.py`'s own RC override produced only 0.1–0.3 m. This is a **harness limitation,
not a sim fault**: `chan3_raw` stays at 1500 despite 10 Hz `RC_CHANNELS_OVERRIDE` at 1900,
because MAVProxy on SERIAL0 is simultaneously sending its own RC values and wins. Trying to
settle it by killing MAVProxy instead killed SITL (see Problems). GUIDED independently
proves the propulsion chain works, so MANUAL control is considered verified.

### Arming with realistic checks — arms successfully

**`ARMING_CHECK` does not exist in ArduPilot 4.8.0-dev.** Setting it fails with
`Unable to find parameter 'ARMING_CHECK'`. The source confirms the replacement:

```c
AP_GROUPINFO("SKIPCHK", 13, AP_Arming, checks_to_skip, 0),
// @DisplayName: Arm Checks to Skip (bitmask)
```

The semantics are **inverted** — `ARMING_SKIPCHK` is a bitmask of checks to *skip*, and its
default `0` already means every pre-arm check is enabled. `blueboat.parm` now sets
`ARMING_SKIPCHK 0` explicitly so the intent is visible.

With all checks active the boat arms:
`COMMAND_ACK: COMPONENT_ARM_DISARM: ACCEPTED` / `Throttle armed` / `ARMED`.
A transient `PreArm: Accels inconsistent` appears during startup while the hull settles; it
clears and does not block arming.

**This corrects Step 1a.** That report concluded "SITL's default rover params leave arming
checks off", based on MAVProxy printing `Arming checks disabled`. That string appears
nowhere in the ArduPilot source — it is MAVProxy's own output when it cannot find the
legacy `ARMING_CHECK` parameter. The checks were never actually disabled.

### AUTO mission — completes, but tracks poorly

4 waypoints, ~25 m square, uploaded via MAVLink:

```
[auto] starting at waypoint 4      <- stale counter, rewound before AUTO
[auto] t=    0s  now heading to waypoint 1
[auto] t=   25s  now heading to waypoint 2
[auto] t=   99s  now heading to waypoint 3
[auto] t=  124s  now heading to waypoint 4
[auto] final waypoint reached
[auto] cross-track error: mean=12.62 m  max=25.04 m  samples=111
```

**Cross-track behaviour, qualitatively: overshooting, not smooth.** A mean cross-track
error of 12.6 m on 25 m legs is comparable to the leg length itself, and the 25.04 m max
means the boat strayed a full leg-length off track. The leg timings say the same: leg 1→2
took 25 s, but 2→3 took 74 s — consistent with overshooting a corner and having to come
back. The mission does complete, so this is a **tuning** problem (turn rate, `WP_RADIUS`,
`CRUISE_SPEED`, skid-steer gains), not a plumbing problem.

An earlier AUTO run reported `mean=0.16 m, max=0.16 m, samples=1` — that was a **false
pass** and is not a valid result; see Problems.

### GUIDED — works

Single position target ~50 m north of home, reached on both runs:
`ARRIVED within 5.0 m` and `ARRIVED within 4.5 m`. Distance-to-target was non-monotonic on
the first run (12.1 → 25.3 → 13.9 → 5.6 m), again consistent with overshoot.

## Ports

| Port | Proto | Bound by | Purpose |
|---|---|---|---|
| 5760 | TCP | `ardurover` | SERIAL0 — primary MAVLink; MAVProxy attaches here as `--master` |
| 5762 | TCP | `ardurover` | SERIAL1 — spare GCS link. Used by `drive_test.py` so it doesn't fight MAVProxy |
| 5763 | TCP | `ardurover` | SERIAL2 — spare |
| 9002 | UDP | Gazebo (`ruby`/gz sim) | **ArduPilot → Gazebo JSON interface** (`JSON control interface set to 127.0.0.1:9002`) |
| 9003 | UDP | ArduPilot side | JSON return path (plugin → SITL) |
| 5501 | UDP | SITL | `--sitl` RC/physics input |
| 14550 | UDP | MAVProxy `--out` | General GCS output |
| 14551 | UDP | MAVProxy `--out` | **Reserved for MAVROS** in Step 2 |
| 9005 | — | SITL | Irlock |

Observed while running:
```
UNCONN 0 0 127.0.0.1:9002 0.0.0.0:* users:(("ruby",pid=1407113,fd=24))
LISTEN 0 5   0.0.0.0:5760 0.0.0.0:* users:(("ardurover",...))
LISTEN 0 5   0.0.0.0:5762 0.0.0.0:* users:(("ardurover",...))
LISTEN 0 5   0.0.0.0:5763 0.0.0.0:* users:(("ardurover",...))
```

**For MAVROS (Step 2):** `14551` is already wired as a dedicated UDP output, so MAVROS can
use `udp://:14551@`. But note the MAVProxy dependency below — if MAVROS is to be the only
GCS, launch with `sim_vehicle.py --no-mavproxy` rather than killing MAVProxy afterwards.
Also note all TCP ports bind `0.0.0.0` and, with `--network host`, are exposed on every host
interface.

## Problems

**1. `GzOGRE2::GzOGRE2` target not found (asv_wave_sim build failure)**
```
CMake Error at src/systems/CMakeLists.txt:53 (target_link_libraries):
  Target "gz-waves1-dynamic-geometry-system" links to:
    GzOGRE2::GzOGRE2
  but the target was not found.
CMake Error at src/systems/waves/CMakeLists.txt:57 (target_link_libraries):
  Target "gz-waves1-rendering-ogre2" links to:
    GzOGRE2::GzOGRE2
CMake Generate step failed.  Build files cannot be regenerated correctly.
```
Cause: `gz-waves/CMakeLists.txt:207` calls `gz_find_package(GzOGRE2 VERSION 2.3 ...)`, and
gz-cmake's `FindGzOGRE2.cmake` resolves OGRE-Next via **pkg-config**. Both pieces were
present (`FindGzOGRE2.cmake` in `gz_cmake_vendor/.../cmake3/`, `OGRE-Next.pc` in
`gz_ogre_next_vendor/lib/pkgconfig/`), but `PKG_CONFIG_PATH` was empty after sourcing ROS,
so the find failed *silently* while the systems still referenced the target. Proven:
```
pkg-config --exists OGRE-Next  -> NOT FOUND (default)
PKG_CONFIG_PATH=/opt/ros/jazzy/opt/gz_ogre_next_vendor/lib/pkgconfig \
  pkg-config --modversion OGRE-Next  -> 2.3.3
```
Resolution: `ENV PKG_CONFIG_PATH=/opt/ros/jazzy/opt/gz_ogre_next_vendor/lib/pkgconfig`.

**2. Wave plugins found but refused to load**
```
Error while loading the library [.../libgz-waves1-waves-model-system.so]:
  libgz-waves1.so.1: cannot open shared object file: No such file or directory
[Err] [SystemLoader.cc:107] Failed to load system plugin: (Reason: No plugins detected in library)
```
Cause: the colcon merge-install libs were not on the loader path (README's
`source ~/gz_ws/install/setup.bash` step).
Resolution: `ENV LD_LIBRARY_PATH=/home/simuser/gz_ws/install/lib:${LD_LIBRARY_PATH}`.

**3. `PreArm: Motors: Check frame class and type`, then a self-inflicted port collision**
`gazebo-iris.parm` does set `FRAME_CLASS 1`/`FRAME_TYPE 1`, but those are written to EEPROM
*after* boot and `FRAME_CLASS` only takes effect on the next boot. My first fix — killing
and relaunching `sim_vehicle.py` — reproduced the Step 1a port collision:
```
bind failed on port 5760 - Address already in use
```
(with `link 1 down` and `ss` showing Recv-Q=1 on 5760), because the old vehicle binary keeps
host-global ports under `--network host`.
Resolution: reboot the autopilot **in place** from MAVProxy (`reboot`) instead of restarting
the process — same process keeps the ports, params take effect, no collision. For the boat
this turned out to be unnecessary anyway: `--add-param-file` is passed through as
`--defaults`, so `FRAME_CLASS 2` applies at boot.

**4. Nearly reported "the vehicle didn't move" from a misread pose**
`/world/iris_runway/pose/info` showed `iris_with_standoffs` at `z ≈ 1e-13` after a 10 m
takeoff. That model is **nested inside** the top-level `iris_with_gimbal` (visible in the
plugin's IMU topic path), so its pose is relative to its parent and correctly ~0. The
top-level model was at z = 10.19 m. Lesson: confirm which entity is top-level before judging
motion.

**5. Non-fatal shader error from inlining the waves model**
```
[Err] [WavesVisual.cc:399] Unable to load shader param system. Missing <shader> SDF element.
```
Caused by omitting the macOS metal `<shader>` block when inlining. Physics and rendering are
unaffected; not fixed.

**6. `set -u` kills the launch script on ROS setup**
```
/opt/ros/jazzy/setup.bash: line 8: AMENT_TRACE_SETUP_FILES: unbound variable
```
Resolution: wrap the `source` in `set +u` / `set -u`.

**7. SITL starts then instantly dies (seen as GUI windows flashing open and closed)**
```
SIM_VEHICLE: MAVProxy exited
SIM_VEHICLE: Killing tasks
...
Closed connection on SERIAL0
```
Cause: MAVProxy's interactive console reads stdin. Under `docker exec -d` (or cron/CI) there
is no stdin, so it gets immediate EOF, exits cleanly, and `sim_vehicle.py` tears down the
vehicle binary with it.
Resolution: the HEADLESS path passes `--mavproxy-args="--daemon"`.
Corollary, confirmed by experiment: `pkill -f mavproxy.py` also kills `ardurover`.

**8. AUTO false pass — a "successful" result that was meaningless**
First AUTO run reported:
```
[auto] t=    1s  now heading to waypoint 4
[auto] final waypoint reached
[auto] cross-track error: mean=0.16 m  max=0.16 m  samples=1
```
The mission counter was still at the end of a previous run, so AUTO "completed" in 1 s off a
single sample. Resolution: `mission_set_current_send(..., 1)` before switching to AUTO, plus
a minimum run time before accepting the final waypoint. The corrected run gave the real
(and much worse) numbers reported above. Worth flagging because this failure mode *looks*
like an excellent result.

**9. `ss` is not installed in the container**
`launch_blueboat.sh`'s pre-flight port check uses `ss`, so inside the container the check
silently never fires (it works on a host that has `ss`). **Not yet fixed** — should be
switched to parsing `/proc/net/tcp` or a `python3 -c` probe.

## Open questions

1. **Waypoint tracking needs tuning.** Mean cross-track 12.6 m / max 25.0 m on 25 m legs is
   too loose for RoboBoat gates and buoy channels. Candidates: `WP_RADIUS`, `CRUISE_SPEED` /
   `WP_SPEED` (currently 2.0 m/s), turn rate limits, and skid-steer steering gains. Do you
   want tuning treated as its own step before MAVROS/Nav2, given Nav2 will sit on top of
   this behaviour?
2. **How faithful should hydrodynamics be?** Waves are currently off. The BlueBoat.md
   hull model is explicitly an approximation ("slightly more volume in the keel fins and
   aft, which requires the centre of mass to be moved aft for level trim"). Is a calm-water
   approximation adequate for competition practice, or does wave response matter?
3. **`ss` port-check bug (Problem 9)** — worth fixing now or when the sim moves into the
   team repo?
4. **MAVProxy is load-bearing under `sim_vehicle.py`.** For MAVROS, is the plan
   `--no-mavproxy` with MAVROS as sole GCS, or keep MAVProxy and have MAVROS consume the
   14551 output? The latter is easier to debug; the former is closer to the real vehicle.
5. **Image size.** Adding ardupilot_gazebo, SITL_Models and asv_wave_sim (plus CGAL, OpenCV,
   GStreamer) grows an image that was already 14.4 GB. Worth a multi-stage build before
   teammates pull it?
6. **Host-specific env vars persist.** `__NV_PRIME_RENDER_OFFLOAD` /
   `__GLX_VENDOR_LIBRARY_NAME` are NVIDIA-hybrid-specific and `GZ_IP=127.0.0.1` assumes
   loopback. Now overridable in `run_sim_scratch.sh`, but teammates on Intel/AMD or Jetson
   will need different values.
7. **Renamed parameters are a recurring hazard.** Both `ARMING_CHECK` and `SYSID_MYGCS`
   are absent in 4.8.0-dev. Any params the team carries over from older ArduPilot docs or
   from the real BlueBoat should be validated against this build.
8. **Still not addressed** (out of scope for 1b): ROS 2 bridge (`ros_gz`), MAVROS, Nav2,
   and any RoboBoat-specific course elements (buoys, gates, docks).
