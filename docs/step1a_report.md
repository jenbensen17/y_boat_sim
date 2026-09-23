# RoboBoat Step 1a Report — Scratch Sim Environment

Goal: in a scratch Docker environment outside the team repo, prove (1) Gazebo Harmonic
renders a GUI on the Wayland desktop using the NVIDIA GPU, and (2) ArduPilot SITL (Rover)
builds and runs. No BlueBoat model, no Gazebo↔ArduPilot connection yet.

Workdir: `~/y_boat/sim_scratch/`. `~/y_boat/y_boat_core` was **not** touched.

**Both goals achieved.** Gazebo Harmonic renders on the RTX 4060 (visually confirmed,
plus `nvidia-smi` shows the GUI holding GPU memory), and ArduPilot Rover SITL builds,
runs, gets GPS/EKF lock, and arms in GUIDED mode.

## Dockerfile.sim

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

RUN ./waf configure --board sitl && ./waf rover

RUN echo "source /opt/ros/jazzy/setup.bash" >> /home/${USERNAME}/.bashrc \
    && echo "export PATH=\$HOME/.local/bin:\$HOME/ardupilot/Tools/autotest:\$PATH" >> /home/${USERNAME}/.bashrc

WORKDIR /home/${USERNAME}
CMD ["bash"]
```

## run_sim_scratch.sh

```bash
#!/usr/bin/env bash
set -euo pipefail

IMAGE="y_boat_sim_scratch:latest"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Granting local Docker containers access to the X server (xhost +local:docker)..."
xhost +local:docker

docker run --rm -it \
    --gpus all \
    -e NVIDIA_DRIVER_CAPABILITIES=all \
    --network host \
    -e DISPLAY="${DISPLAY}" \
    -e __NV_PRIME_RENDER_OFFLOAD=1 \
    -e __GLX_VENDOR_LIBRARY_NAME=nvidia \
    -e QT_QPA_PLATFORM=xcb \
    -e GZ_IP=127.0.0.1 \
    -v /tmp/.X11-unix:/tmp/.X11-unix \
    -v "${SCRIPT_DIR}:/home/simuser/sim_scratch" \
    "${IMAGE}" \
    "${@:-bash}"
```

Usage: `./run_sim_scratch.sh` opens a shell; `./run_sim_scratch.sh bash -lc 'gz sim shapes.sdf'`
runs a one-off command. The four env vars beyond the spec (`__NV_PRIME_RENDER_OFFLOAD`,
`__GLX_VENDOR_LIBRARY_NAME`, `QT_QPA_PLATFORM`, `GZ_IP`) were each added to fix a specific
failure documented below.

## Build

**Succeeded on the third attempt.** Final build: **15m12s**, image `y_boat_sim_scratch:latest`,
**14.4GB disk usage / 4.14GB content size**.

Slowest step by far: `pip3 install wxpython` inside `install-prereqs-ubuntu.sh`, which had to
compile from source because no prebuilt wheel matched this Python/Ubuntu combination —
**~6m9s** of the 15m total. The installer itself warns about this ("wxpython takes a *VERY*
long time to install (~30 minutes). Be patient."). ArduPilot's Rover SITL build was fast by
comparison: 1379 files compiled and `bin/ardurover` linked in **1m4.9s**.

Two build failures had to be fixed first — see Problems.

One reporting oddity: the harness's background-task tracker reported the successful build as
"exit code -1", while the build log recorded `BUILD_EXIT_CODE=0` and `docker images` showed
the tag present. Treated as a tracker glitch, not a build failure.

## Rendering

**Result: working, GPU-accelerated, visually confirmed.**

First `glxinfo -B` attempt used software rendering:
```
OpenGL vendor string: Mesa
OpenGL renderer string: llvmpipe (LLVM 20.1.2, 256 bits)
```

After adding `__GLX_VENDOR_LIBRARY_NAME=nvidia` and `__NV_PRIME_RENDER_OFFLOAD=1`:
```
OpenGL vendor string: NVIDIA Corporation
OpenGL renderer string: NVIDIA GeForce RTX 4060 Laptop GPU/PCIe/SSE2
OpenGL core profile version string: 4.6.0 NVIDIA 610.57.04
OpenGL core profile shading language version string: 4.60 NVIDIA
OpenGL version string: 4.6.0 NVIDIA 610.57.04
OpenGL ES profile version string: OpenGL ES 3.2 NVIDIA 610.57.04
```

`gz sim shapes.sdf` then still showed no window — but that turned out to be a Gazebo
Transport problem, not a rendering one (see Problems). After adding `GZ_IP=127.0.0.1`, the
window appeared. Compositor confirmation:
```
class: Gazebo GUI
title: Gazebo Sim
xwayland: 1
mapped: 1
```
User visually confirmed the box, sphere, and cylinder render in the 3D view.

Strongest evidence the GPU is actually doing the work — `nvidia-smi` while Gazebo ran:
```
|    0   N/A  N/A          732777      G   gz sim gui                              259MiB |
```
GPU utilization 21%, 352MiB total in use.

**Fixes applied for rendering:** `__GLX_VENDOR_LIBRARY_NAME=nvidia`,
`__NV_PRIME_RENDER_OFFLOAD=1` (hybrid-laptop GPU vendor selection), `QT_QPA_PLATFORM=xcb`
(Qt GUI under XWayland), `GZ_IP=127.0.0.1` (Gazebo Transport discovery).

## ArduPilot SITL

**Built:** yes — `./waf configure --board sitl && ./waf rover` produced
`/home/simuser/ardupilot/build/sitl/bin/ardurover` in 1m4.9s (1379 files).

**Tools on PATH:** `sim_vehicle.py` → `/home/simuser/ardupilot/Tools/autotest/sim_vehicle.py`;
`mavproxy.py` → `/home/simuser/venv-ardupilot/bin/mavproxy.py`. Note the prereqs script put
MAVProxy in a **virtualenv** (`~/venv-ardupilot`) rather than `~/.local/bin`; it resolves on
PATH correctly, but that location is worth knowing for later steps.

**Ran:** yes. Initialization reached full readiness:
```
AP: ArduRover V4.8.0-dev (b5fbe265)
Received 1272 parameters (ftp)
AP: Barometer 1 calibration complete
AP: Beginning INS calibration. Do not move vehicle
AP: ArduPilot Ready
AP: EKF3 IMU0 initialised / EKF3 IMU1 initialised
AP: EKF3 IMU0 tilt alignment complete
AP: EKF3 IMU0 MAG0 initial yaw alignment complete
AP: AHRS: EKF3 active
AP: GPS 1: probing for u-blox at 230400 baud
AP: GPS 1: detected u-blox
AP: Set HOME to -35.36326 149.1652 at 584.00m
AP: EKF3 IMU0 origin set / EKF3 IMU1 origin set
AP: EKF3 IMU0 is using GPS / EKF3 IMU1 is using GPS
```
(Default ArduPilot home location — CMAC, Canberra. Will need changing for a RoboBoat venue.)

**Arming result: success on the first try, no `force` needed.**
```
MANUAL> Got COMMAND_ACK: DO_SET_MODE: ACCEPTED
GUIDED> Mode GUIDED
GUIDED> Got COMMAND_ACK: COMPONENT_ARM_DISARM: ACCEPTED
AP: Throttle armed
ARMED
Arming checks disabled
```
Caveat: the trailing `Arming checks disabled` means SITL's default rover parameters leave
arming checks off, so this did **not** exercise full pre-arm validation.

**MAVLink ports:**

| Port | Proto | Role |
|------|-------|------|
| 5760 | TCP | SERIAL0 — primary MAVLink, MAVProxy `--master` |
| 5762 | TCP | SERIAL1 |
| 5763 | TCP | SERIAL2 |
| 14550 | UDP | MAVProxy `--out` (MAVProxy-side output, not an `ardurover` listener) |
| 5501 | UDP | SITL RC/physics input (`--sitl 127.0.0.1:5501`) |
| 9005 | — | Irlock |

Host-side confirmation:
```
LISTEN 0 5 0.0.0.0:5760 users:(("ardurover",pid=787724,fd=9))
LISTEN 0 5 0.0.0.0:5762 users:(("ardurover",pid=787724,fd=13))
LISTEN 0 5 0.0.0.0:5763 users:(("ardurover",pid=787724,fd=14))
```

**GUI (console + map):** confirmed working. `sim_vehicle.py -v Rover --console --map` with
`DISPLAY` set produced MAVProxy console and map windows that the user visually confirmed.

**How MAVProxy was driven non-interactively:** `mkfifo /tmp/mavcmd` with
`sleep infinity > /tmp/mavcmd &` holding the write end open (so MAVProxy never sees EOF),
`sim_vehicle.py ... < /tmp/mavcmd`, then `echo "mode GUIDED" > /tmp/mavcmd` etc. This is
reusable for scripted SITL testing later.

## Problems

**1. `groupadd: GID '1000' already exists` (build failure, attempt 1)**
```
[ 3/10] RUN groupadd --gid 1000 simuser && useradd --uid 1000 --gid 1000 -m -s /bin/bash simuser ...
groupadd: GID '1000' already exists
ERROR: process ... did not complete successfully: exit code: 4
```
Cause: `osrf/ros:jazzy-desktop-full` already ships `ubuntu:1000:1000` — confirmed with
`docker run --rm osrf/ros:jazzy-desktop-full bash -c 'getent group 1000; getent passwd 1000'`.
Resolution: rename the existing account instead of creating one, preserving UID/GID 1000 so
host-mounted file ownership still matches:
`usermod -l simuser -m -d /home/simuser -s /bin/bash ubuntu && groupmod -n simuser ubuntu`.

**2. `usermod: Usage: usermod [options] LOGIN` (build failure, attempt 2)**
```
[ 7/10] RUN Tools/environment_install/install-prereqs-ubuntu.sh -y
+ sudo usermod -a -G dialout
Usage: usermod [options] LOGIN
ERROR: process ... did not complete successfully: exit code: 2
```
Cause: the script runs `sudo usermod -a -G dialout $USER`, but Docker's `USER` instruction
does not populate `$USER` in later `RUN` shells, so the LOGIN argument was empty.
Resolution: `ENV USER=${USERNAME}`.

**3. `glxinfo` reported llvmpipe instead of the RTX 4060**
```
OpenGL renderer string: llvmpipe (LLVM 20.1.2, 256 bits)
```
Cause: `nvidia-smi` worked inside the container and `libGLX_nvidia.so.0` was present, but
GLX vendor auto-detection selected Mesa — the classic hybrid-laptop-GPU case.
Resolution: `__GLX_VENDOR_LIBRARY_NAME=nvidia` + `__NV_PRIME_RENDER_OFFLOAD=1`.

**4. `gz sim shapes.sdf` opened no window at all**
```
[Wrn] [Gui.cc:283] Waited for 10s for a subscriber to [/gazebo/starting_world] and got none.
[GUI] [Dbg] [Gui.cc:355] GUI requesting list of world names. The server may be busy downloading resources. Please be patient.
```
Investigated before guessing: both `gz sim server` and `gz sim gui` were alive but idle
(`State: S (sleeping)`, `wchan: futex_do_wait`, ~1s CPU over 2 minutes); `hyprctl clients`
showed no Gazebo window and zero XWayland clients; `DISPLAY`/`QT_QPA_PLATFORM` were correctly
set in `/proc/<pid>/environ`; XWayland was running (`1517 Xwayland :0 -rootless ...`).
Verbose mode showed the Qt xcb plugin loading fine (`loaded library ".../libqxcb.so"`,
`Create main window`), which ruled out an X11/GL problem.
Cause: **Gazebo Transport discovery** — `gz sim` runs server and GUI as separate processes
that must find each other, and under `--network host` they did not, so the GUI had no world
to render and never mapped a window.
Resolution: `GZ_IP=127.0.0.1`.

**5. SITL hung at `Waiting for heartbeat from tcp:127.0.0.1:5760`, then `link 1 down`**
Diagnosis was initially blocked because with `DISPLAY` set, `sim_vehicle.py` runs the vehicle
binary inside `xterm -iconic -hold`, hiding its output. `ss -ltnp` showed
`LISTEN 1 5 0.0.0.0:5760` — Recv-Q of 1, i.e. a connection pending and never accepted.
Re-running with `unset DISPLAY` redirected vehicle output to `/tmp/Rover.log`, revealing:
```
bind port 5760 for SERIAL0
bind failed on port 5760 - Address already in use
```
Cause: a stale `ardurover` from the first attempt was still holding port 5760 and had
survived `pkill -f ardurover`. Because containers run with `--network host`, that stale
process occupied the **host's** port 5760, colliding with every subsequent start.
Resolution: stop the container entirely to reap stragglers, and verify
`ss -ltnp | grep 576` is clear before relaunching.

**6. Non-fatal noise on the SITL GUI path** (does not block anything)
```
xterm: cannot load font "10x20"
Gtk-CRITICAL **: gtk_distribute_natural_allocation: assertion 'extra_space >= 0' failed
UserWarning: Unable to import Axes3D. ... the 3D projection is not available.
Failed to download /SRTM3/filelist_python : 'utf-8' codec can't decode byte 0x80 in position 0: invalid start byte
```
The SRTM one means MAVProxy's map module could not fetch terrain elevation tiles.

## Open questions

1. **`--network host` + host-global ports.** SITL binds 5760/5762/5763 on `0.0.0.0`, so they
   are exposed on all host interfaces and collide across container restarts (Problem 5). For
   the eventual `sim` compose service, is a dedicated bridge network with explicit port
   mapping preferable? That would conflict with Gazebo Transport, which is why `GZ_IP` was
   needed — worth deciding deliberately rather than inheriting `network_mode: host` from the
   team's `dev` service.
2. **Arming checks are disabled in SITL defaults.** The arm succeeded but skipped pre-arm
   validation. Should the sim enable realistic arming checks so failures surface in sim
   rather than on the water?
3. **Image size: 14.4GB on disk.** Most of it is `jazzy-desktop-full` plus a full ArduPilot
   source tree and build artifacts. Worth a multi-stage build or `ros-jazzy-desktop` (non-full)
   before this becomes something teammates pull regularly?
4. **wxpython compiles from source (~6 min).** Only needed for MAVProxy's `--console`/`--map`.
   If the sim service runs headless with a separate GCS, that dependency could be dropped.
5. **The four env vars are host-specific.** `__NV_PRIME_RENDER_OFFLOAD`/
   `__GLX_VENDOR_LIBRARY_NAME` are NVIDIA-hybrid-laptop specific and `GZ_IP=127.0.0.1` assumes
   loopback. Teammates on Intel/AMD graphics or a Jetson will need different values — these
   should probably become configurable rather than hardcoded in the run script.
6. **Default home is CMAC, Canberra** (`-35.36326 149.1652`). Needs a RoboBoat-appropriate
   location before any mission testing.
7. **Not yet tested:** Gazebo↔ArduPilot connection, the BlueBoat model, MAVROS, and Nav2 —
   all deliberately out of scope for Step 1a.
